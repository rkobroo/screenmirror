package com.mirrorlink.android

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.WindowManager
import org.json.JSONObject
import org.webrtc.CapturerObserver
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.ScreenCapturerAndroid
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoFrame
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ThreadLocalRandom

class RtcEngine(
    private val context: Context,
    private val callback: Callback,
) {
    interface Callback {
        fun onIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int)
        fun onOffer(sdp: String)
        fun onState(state: String)
        fun onStats(fps: Int, bps: Long)
        fun onClipboard(text: String)
        fun onChat(text: String)
        fun onFileProgress(id: String, received: Long, total: Long)
        fun onFileDone(id: String, name: String, uri: String?)
        fun onDataChannelOpened(channel: String)
    }

    class Config(
        val width: Int,
        val height: Int,
        val fps: Int,
        val bitrate: Int,
        val autoQuality: Boolean,
        val nickname: String,
        val clipboardSync: Boolean,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    private lateinit var eglBase: EglBase
    private lateinit var surfaceTextureHelper: SurfaceTextureHelper
    private lateinit var factory: PeerConnectionFactory
    private lateinit var peer: PeerConnection
    private lateinit var videoSource: org.webrtc.VideoSource
    private lateinit var videoTrack: VideoTrack

    private var capturer: ScreenCapturerAndroid? = null
    private var controlChannel: DataChannel? = null

    private var running = false
    private var clipboardWatcherEnabled = false
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null

    private var lastFpsWindow = 0
    private var lowFpsStreak = 0
    private var highFpsStreak = 0
    private var currentCaptureHeight = 0

    // ---- PC → phone file transfers (via control channel binary messages) ----
    private data class IncomingFile(
        val id: String,
        val name: String,
        val size: Long,
        var received: Long = 0,
        var output: java.io.OutputStream? = null,
        var uri: android.net.Uri? = null,
        var doneReceived: Boolean = false,
    )

    private val incomingFiles = ConcurrentHashMap<String, IncomingFile>()

    init {
        ensureInitialized(context)
    }

    companion object {
        private const val CONTROL = "control"
        private const val CHUNK_SIZE = 64 * 1024
        private const val MIN_CAPTURE_HEIGHT = 480
        private const val TAG = "MirrorLinkRtc"

        private var initialized = false

        fun ensureInitialized(context: Context) {
            if (initialized) return
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(context)
                    .setEnableInternalTracer(false)
                    .createInitializationOptions(),
            )
            initialized = true
        }
    }

    fun start(config: Config) {
        if (running) return
        running = true
        lastConfig = config
        currentCaptureHeight = config.height

        eglBase = EglBase.create()
        surfaceTextureHelper =
            SurfaceTextureHelper.create("MirrorLinkCapture", eglBase.eglBaseContext)

        factory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(
                DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true),
            )
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .createPeerConnectionFactory()

        val rtcConfig = PeerConnection.RTCConfiguration(mutableListOf())
        rtcConfig.iceTransportsType = PeerConnection.IceTransportsType.ALL

        peer = factory.createPeerConnection(rtcConfig, pcObserver)!!

        videoSource = factory.createVideoSource(true)
        videoTrack = factory.createVideoTrack("screen0", videoSource)
        videoTrack.setEnabled(true)
        peer.addTrack(videoTrack, listOf(MediaStreamTrack.VIDEO_TRACK_KIND))

        // Single data channel — carries both text (JSON) and binary (file chunks).
        controlChannel = peer.createDataChannel(CONTROL, DataChannel.Init())
        controlChannel?.registerObserver(controlObserver)

        createOffer { sdp ->
            if (sdp != null) callback.onOffer(sdp)
        }

        callback.onState(NativeStates.READY)
        setClipboardWatcher(config.clipboardSync)
    }

    fun attachProjection(resultData: Intent) {
        if (!running) return
        val existing = capturer
        if (existing != null) {
            existing.stopCapture()
            existing.dispose()
        }

        val projectionCallback = object : MediaProjection.Callback() {
            override fun onStop() {
                mainHandler.post {
                    val cap = capturer
                    capturer = null
                    if (cap != null) {
                        try { cap.stopCapture() } catch (_: Throwable) {}
                        try { cap.dispose() } catch (_: Throwable) {}
                    }
                    callback.onState(NativeStates.DISCONNECTED)
                }
            }
        }

        val newCapturer = ScreenCapturerAndroid(resultData, projectionCallback)
        newCapturer.initialize(surfaceTextureHelper, context, capturerObserver)

        val displayMetrics = DisplayMetrics()
        (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
            .defaultDisplay.getRealMetrics(displayMetrics)
        val (w, h) = fitWithin(displayMetrics.widthPixels, displayMetrics.heightPixels)

        val fps = lastConfig?.fps ?: 30
        surfaceTextureHelper.handler.post {
            newCapturer.startCapture(w, h, fps)
        }
        capturer = newCapturer
        sendCaptureDimensions(w, h)
    }

    private fun createOffer(done: (String?) -> Unit) {
        peer.createOffer(
            object : SdpObserver {
                override fun onCreateSuccess(offer: SessionDescription?) {
                    val modified = injectBitrate(offer?.description)
                    peer.setLocalDescription(
                        object : SdpObserver {
                            override fun onSetSuccess() = done(modified)
                            override fun onSetFailure(error: String?) = done(null)
                            override fun onCreateSuccess(d: SessionDescription?) = Unit
                            override fun onCreateFailure(e: String?) = Unit
                        },
                        SessionDescription(SessionDescription.Type.OFFER, modified),
                    )
                }
                override fun onCreateFailure(error: String?) = done(null)
                override fun onSetFailure(error: String?) = done(null)
                override fun onSetSuccess() = Unit
            },
            MediaConstraints(),
        )
    }

    private fun injectBitrate(sdp: String?): String {
        if (sdp == null) return ""
        val kbps = (lastConfig?.bitrate ?: 4_000_000) / 1000
        return sdp.replaceFirst(Regex("(m=video\\s+\\d+\\s+[^\r\n]+)"), "$1\r\nb=AS:$kbps")
    }

    fun setRemoteAnswer(sdp: String) {
        if (!running) return
        peer.setRemoteDescription(
            object : SdpObserver {
                override fun onCreateSuccess(sessionDescription: SessionDescription?) = Unit
                override fun onCreateFailure(error: String?) = Unit
                override fun onSetSuccess() {
                    android.util.Log.e(TAG, "setRemoteAnswer onSetSuccess controlState=${controlChannel?.state()}")
                }
                override fun onSetFailure(error: String?) {
                    android.util.Log.e(TAG, "setRemoteAnswer onSetFailure: $error")
                    callback.onState(NativeStates.ERROR)
                }
            },
            SessionDescription(SessionDescription.Type.ANSWER, sdp),
        )
    }

    fun addIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        if (!running) return
        val idx = sdpMLineIndex ?: 0
        peer.addIceCandidate(IceCandidate(sdpMid, idx, candidate))
    }

    fun sendData(channel: String, base64Payload: String) {
        val ch = controlChannel ?: return
        val bytes = android.util.Base64.decode(base64Payload, android.util.Base64.DEFAULT)
        ch.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), false))
    }

    fun setClipboardWatcher(enabled: Boolean) {
        clipboardWatcherEnabled = enabled
        val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        if (enabled && clipboardListener == null) {
            clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
                val clip = manager.primaryClip ?: return@OnPrimaryClipChangedListener
                if (clip.itemCount == 0) return@OnPrimaryClipChangedListener
                val text = clip.getItemAt(0).coerceToText(context).toString()
                if (text.isNotEmpty()) {
                    sendControl(
                        JSONObject()
                            .put("type", "clipboard")
                            .put("text", text)
                            .toString(),
                    )
                }
            }
            manager.addPrimaryClipChangedListener(clipboardListener)
        } else if (!enabled && clipboardListener != null) {
            manager.removePrimaryClipChangedListener(clipboardListener)
            clipboardListener = null
        }
    }

    // ---- file transfer (phone → PC) via single control channel -----------------

    fun sendFile(contentUri: String) {
        android.util.Log.e(TAG, "sendFile uri=$contentUri running=$running channelState=${controlChannel?.state()}")
        if (!running) return
        val ch = controlChannel ?: return
        val id = Integer.toHexString(ThreadLocalRandom.current().nextInt(Int.MAX_VALUE))
        worker.execute {
            try {
                val resolver = context.contentResolver
                val uri = android.net.Uri.parse(contentUri)
                var name = "file"
                var size = 0L
                val input: java.io.InputStream? = if (uri.scheme == "content") {
                    resolver.query(
                        uri,
                        arrayOf(
                            android.provider.OpenableColumns.DISPLAY_NAME,
                            android.provider.OpenableColumns.SIZE,
                        ),
                        null, null, null,
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameIdx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                            val sizeIdx = cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
                            if (nameIdx >= 0) name = cursor.getString(nameIdx) ?: name
                            if (sizeIdx >= 0) size = cursor.getLong(sizeIdx)
                        }
                    }
                    resolver.openInputStream(uri)
                } else {
                    try {
                        val f = java.io.File(contentUri)
                        name = f.name
                        size = f.length()
                        java.io.FileInputStream(f)
                    } catch (_: Exception) { null }
                }
                if (input == null) {
                    sendControl(
                        JSONObject()
                            .put("type", "file").put("op", "error")
                            .put("id", id).put("reason", "cannot open file")
                            .toString(),
                    )
                    return@execute
                }

                // 1. Send control message announcing the file
                sendControl(
                    JSONObject()
                        .put("type", "file")
                        .put("op", "send")
                        .put("id", id)
                        .put("name", name)
                        .put("size", size)
                        .toString(),
                )

                // 2. Send binary chunks through the same control channel
                val header = ByteBuffer.allocate(24)
                val idBytes = id.toByteArray(Charsets.UTF_8).copyOf(16)
                val buffer = ByteArray(CHUNK_SIZE)
                var offset = 0L
                input.use { stream ->
                    while (true) {
                        val read = stream.read(buffer)
                        if (read <= 0) break
                        header.clear()
                        header.put(idBytes)
                        header.putLong(offset)
                        val payload = ByteArray(read)
                        System.arraycopy(buffer, 0, payload, 0, read)
                        val frame = ByteBuffer.allocate(24 + read)
                        frame.put(header.array())
                        frame.put(payload)
                        frame.flip()
                        ch.send(DataChannel.Buffer(frame, true)) // true = binary
                        offset += read
                        callback.onFileProgress(id, offset, size)
                    }
                }

                // 3. Send done signal
                sendControl(
                    JSONObject().put("type", "file").put("op", "done").put("id", id).toString(),
                )
                android.util.Log.e(TAG, "sendFile done id=$id totalBytes=$offset")
            } catch (e: Exception) {
                android.util.Log.e(TAG, "sendFile error: ${e.message}")
                sendControl(
                    JSONObject()
                        .put("type", "file").put("op", "error")
                        .put("id", id).put("reason", e.message)
                        .toString(),
                )
            }
        }
    }

    // ---- teardown -------------------------------------------------------------

    fun stop() {
        if (!running) return
        running = false

        incomingFiles.values.forEach { it.output?.close() }
        incomingFiles.clear()

        capturer?.let {
            try { it.stopCapture() } catch (_: Throwable) {}
            it.dispose()
        }
        capturer = null

        controlChannel?.close()
        controlChannel = null

        try { peer.close() } catch (_: Throwable) {}
        try { videoSource.dispose() } catch (_: Throwable) {}
        try { surfaceTextureHelper.dispose() } catch (_: Throwable) {}
        try { eglBase.release() } catch (_: Throwable) {}
        worker.shutdown()
    }

    // ---- private --------------------------------------------------------------

    private val pcObserver = object : PeerConnection.Observer {
        override fun onSignalingChange(state: PeerConnection.SignalingState?) = Unit
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
            when (state) {
                PeerConnection.IceConnectionState.CONNECTED -> callback.onState(NativeStates.CONNECTED)
                PeerConnection.IceConnectionState.DISCONNECTED,
                PeerConnection.IceConnectionState.FAILED,
                PeerConnection.IceConnectionState.CLOSED,
                -> callback.onState(NativeStates.DISCONNECTED)
                else -> Unit
            }
        }
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) = Unit
        override fun onIceCandidate(candidate: IceCandidate?) {
            candidate ?: return
            callback.onIceCandidate(candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex)
        }
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) = Unit
        override fun onAddStream(stream: org.webrtc.MediaStream?) = Unit
        override fun onRemoveStream(stream: org.webrtc.MediaStream?) = Unit
        override fun onDataChannel(channel: DataChannel?) {
            channel ?: return
            android.util.Log.e(TAG, "onDataChannel label=${channel.label()}")
            if (channel.label() == CONTROL) {
                controlChannel = channel
                channel.registerObserver(controlObserver)
                callback.onDataChannelOpened(CONTROL)
            }
        }
        override fun onRenegotiationNeeded() = Unit
        override fun onAddTrack(receiver: org.webrtc.RtpReceiver?, mediaStreams: Array<out org.webrtc.MediaStream>?) = Unit
        override fun onRemoveTrack(receiver: org.webrtc.RtpReceiver?) = Unit
    }

    private val capturerObserver = object : CapturerObserver {
        private var frameCount = 0L
        private var windowStart = System.currentTimeMillis()

        override fun onCapturerStarted(success: Boolean) = Unit
        override fun onCapturerStopped() = Unit

        override fun onFrameCaptured(frame: VideoFrame?) {
            frame ?: return
            videoSource.capturerObserver.onFrameCaptured(frame)
            tick()
        }

        private fun tick() {
            frameCount++
            val now = System.currentTimeMillis()
            val elapsed = now - windowStart
            if (elapsed >= 1000) {
                val fps = (frameCount * 1000 / elapsed).toInt()
                frameCount = 0
                windowStart = now
                callback.onStats(fps, 0L)
                maybeAutoAdjust(fps)
            }
        }
    }

    private fun maybeAutoAdjust(fps: Int) {
        val config = lastConfig ?: return
        if (!config.autoQuality) return
        val target = config.height
        if (fps < 15) {
            lowFpsStreak++
            if (lowFpsStreak >= 3 && currentCaptureHeight > MIN_CAPTURE_HEIGHT) {
                currentCaptureHeight = maxOf(MIN_CAPTURE_HEIGHT, currentCaptureHeight / 2)
                lowFpsStreak = 0
                applyCaptureFormat()
            }
        } else if (fps >= 20) {
            highFpsStreak++
            if (highFpsStreak >= 10 && currentCaptureHeight < target) {
                currentCaptureHeight = minOf(target, currentCaptureHeight * 2)
                highFpsStreak = 0
                applyCaptureFormat()
            }
        } else {
            lowFpsStreak = 0
            highFpsStreak = 0
        }
    }

    private fun applyCaptureFormat() {
        val displayMetrics = DisplayMetrics()
        (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
            .defaultDisplay.getRealMetrics(displayMetrics)
        val (w, h) = fitWithin(displayMetrics.widthPixels, displayMetrics.heightPixels)
        val cap = capturer ?: return
        val fps = lastConfig?.fps ?: 30
        surfaceTextureHelper.handler.post {
            cap.changeCaptureFormat(w, h, fps)
        }
        sendCaptureDimensions(w, h)
    }

    private fun sendCaptureDimensions(w: Int, h: Int) {
        sendControl(
            JSONObject()
                .put("type", "dimensions")
                .put("width", w)
                .put("height", h)
                .toString(),
        )
    }

    private var lastConfig: Config? = null

    private val controlObserver = object : DataChannel.Observer {
        override fun onBufferedAmountChange(previousAmount: Long) = Unit
        override fun onStateChange() {
            val ch = controlChannel ?: return
            android.util.Log.e(TAG, "control channel state: ${ch.state()}")
            if (ch.state() == DataChannel.State.OPEN) {
                callback.onDataChannelOpened("control")
                callback.onState(NativeStates.CONNECTED)
            }
        }
        override fun onMessage(buffer: DataChannel.Buffer?) {
            buffer ?: return
            if (buffer.binary) {
                val bytes = ByteArray(buffer.data.remaining())
                buffer.data.get(bytes)
                handleFileChunk(bytes)
            } else {
                val bytes = ByteArray(buffer.data.remaining())
                buffer.data.get(bytes)
                handleControl(bytes)
            }
        }
    }

    private fun handleControl(bytes: ByteArray) {
        val text = String(bytes, Charsets.UTF_8)
        val json = try { JSONObject(text) } catch (_: Exception) { return }

        when (json.optString("type")) {
            "clipboard" -> {
                val t = json.optString("text")
                if (t.isNotEmpty()) {
                    val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    manager.setPrimaryClip(ClipData.newPlainText("mirrorlink", t))
                    callback.onClipboard(t)
                }
            }
            "chat" -> {
                val t = json.optString("text")
                if (t.isNotEmpty()) callback.onChat(t)
            }
            "ping" -> sendControl("""{"type":"pong"}""")
            "input" -> InputAccessibilityService.instance?.handle(json)
            "file" -> handleFileControl(json)
        }
    }

    // ---- incoming file handling (PC → phone) ----------------------------------

    private fun handleFileControl(json: JSONObject) {
        val id = json.optString("id")
        when (json.optString("op")) {
            "send" -> {
                val sz = json.optLong("size", 0)
                incomingFiles[id] = IncomingFile(
                    id = id,
                    name = json.optString("name", "file"),
                    size = sz,
                )
            }
            "done" -> {
                val file = incomingFiles[id] ?: return
                file.doneReceived = true
                if (file.size > 0 && file.received >= file.size) {
                    finalizeFile(id, file)
                } else if (file.size <= 0) {
                    finalizeFile(id, file)
                } else {
                    mainHandler.postDelayed({
                        val f = incomingFiles[id] ?: return@postDelayed
                        if (incomingFiles.containsKey(id)) finalizeFile(id, f)
                    }, 5000)
                }
            }
            "error" -> {
                incomingFiles.remove(id)?.output?.close()
            }
        }
    }

    private fun handleFileChunk(bytes: ByteArray) {
        if (bytes.size < 24) return
        val header = ByteBuffer.wrap(bytes, 0, 24)
        val idBytes = ByteArray(16)
        header.get(idBytes)
        val id = String(idBytes, Charsets.UTF_8).trim('\u0000')
        val offset = header.long
        if (offset < 0) return
        val payload = bytes.copyOfRange(24, bytes.size)

        val file = incomingFiles[id] ?: return
        val output = file.output ?: (openMediaStoreOutput(file, id)?.also { file.output = it }) ?: return

        try {
            output.write(payload)
            file.received += payload.size
            callback.onFileProgress(id, file.received, file.size)
            if (file.doneReceived && file.size > 0 && file.received >= file.size) {
                finalizeFile(id, file)
            }
        } catch (_: Exception) {
            incomingFiles.remove(id)?.output?.close()
        }
    }

    private fun finalizeFile(id: String, file: IncomingFile) {
        if (!incomingFiles.containsKey(id)) return
        incomingFiles.remove(id)
        try {
            file.output?.flush()
            file.output?.close()
        } catch (_: Throwable) {}
        val filePath = file.uri?.let { resolveFilePath(it, file.name) }
        callback.onFileDone(id, file.name, filePath)
        if (file.uri != null) {
            val mime = mimeFromExtension(file.name)
            mainHandler.post {
                try {
                    val openIntent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(file.uri, mime)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    context.startActivity(Intent.createChooser(openIntent, "Open ${file.name}"))
                } catch (_: Exception) {}
                android.widget.Toast.makeText(
                    context,
                    "File received: ${file.name}",
                    android.widget.Toast.LENGTH_SHORT,
                ).show()
            }
        }
    }

    private fun mimeFromExtension(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "mp4" -> "video/mp4"
            "webm" -> "video/webm"
            "mkv" -> "video/x-matroska"
            "avi" -> "video/x-msvideo"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "mp3" -> "audio/mpeg"
            "ogg" -> "audio/ogg"
            "pdf" -> "application/pdf"
            "txt" -> "text/plain"
            "zip" -> "application/zip"
            "apk" -> "application/vnd.android.package-archive"
            else -> "application/octet-stream"
        }
    }

    private fun openMediaStoreOutput(file: IncomingFile, id: String): java.io.OutputStream? {
        val mime = mimeFromExtension(file.name)
        val values = android.content.ContentValues().apply {
            put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime)
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                put(
                    android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                    android.os.Environment.DIRECTORY_DOWNLOADS + "/MirrorLink",
                )
            }
        }
        return try {
            val resolver = context.contentResolver
            val uri = resolver.insert(
                android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values,
            ) ?: return null
            file.uri = uri
            file.output = resolver.openOutputStream(uri)
            file.output
        } catch (_: Exception) { null }
    }

    private fun resolveFilePath(uri: android.net.Uri, name: String = ""): String? {
        var ext = ""
        try {
            val cursor = context.contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val idx = it.getColumnIndex(android.provider.MediaStore.MediaColumns.DATA)
                    if (idx >= 0) {
                        val path = it.getString(idx)
                        if (path != null && java.io.File(path).exists()) return path
                    }
                }
            }
        } catch (_: Exception) {}
        if (ext.isEmpty()) {
            val dot = name.lastIndexOf('.')
            if (dot >= 0) ext = name.substring(dot).lowercase()
        }
        if (ext.isEmpty()) ext = ".tmp"
        return try {
            val tmp = java.io.File.createTempFile("mirrorlink_", ext, context.cacheDir)
            context.contentResolver.openInputStream(uri)?.use { input ->
                tmp.outputStream().use { output -> input.copyTo(output) }
            }
            tmp.absolutePath
        } catch (_: Exception) { null }
    }

    private fun sendControl(text: String) {
        val ch = controlChannel ?: return
        ch.send(
            DataChannel.Buffer(ByteBuffer.wrap(text.toByteArray(Charsets.UTF_8)), false),
        )
    }

    private fun fitWithin(screenW: Int, screenH: Int): Pair<Int, Int> {
        var (w, h) = screenW to screenH
        if (w > h) { val tmp = w; w = h; h = tmp }
        val maxH = currentCaptureHeight
        if (h > maxH) {
            val scale = maxH.toDouble() / h
            w = (w * scale).toInt()
            h = maxH
        }
        w = (w / 16) * 16
        h = (h / 16) * 16
        return maxOf(16, w) to maxOf(16, h)
    }
}

object NativeStates {
    const val READY = "ready"
    const val CONNECTED = "connected"
    const val DISCONNECTED = "disconnected"
    const val ERROR = "error"
}
