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

/**
 * Owns the native WebRTC stack on the phone: the [PeerConnection], the screen
 * capture pipeline (MediaProjection → ScreenCapturerAndroid → VideoSource) and
 * the two data channels (`control`, `files`) described in docs/PROTOCOL.md.
 *
 * Flutter drives it through [MirrorLinkMainActivity]'s method channel:
 * [start], [setRemoteOffer], [addIceCandidate], [attachProjection], [stop].
 */
class RtcEngine(
    private val context: Context,
    private val callback: Callback,
) {
    /** Events delivered to the Flutter layer. */
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
    private var filesChannel: DataChannel? = null

    private var running = false
    private var clipboardWatcherEnabled = false
    private var clipboardListener: ClipboardManager.OnPrimaryClipChangedListener? = null

    // ---- auto-quality state -------------------------------------------------
    private var lastFpsWindow = 0
    private var lowFpsStreak = 0
    private var highFpsStreak = 0
    private var currentCaptureHeight = 0

    // ---- PC → phone file transfers -------------------------------------------
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
        private const val FILES = "files"
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

    // ------------------------------------------------------------------ public

    /** Create the peer connection and prepare the screen track (no capture yet). */
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

        // Phone and PC are on the same LAN; ALL includes host candidates.
        val rtcConfig = PeerConnection.RTCConfiguration(mutableListOf())
        rtcConfig.iceTransportsType = PeerConnection.IceTransportsType.ALL

        peer = factory.createPeerConnection(rtcConfig, pcObserver)!!

        videoSource = factory.createVideoSource(true)
        videoTrack = factory.createVideoTrack("screen0", videoSource)
        videoTrack.setEnabled(true)
        peer.addTrack(videoTrack, listOf(MediaStreamTrack.VIDEO_TRACK_KIND))

        // Apply the requested bitrate to the video sender so the encoder
        // doesn't fall back to its very low default (~200 kbps).
        // We set this via SDP b=AS attribute in createOffer instead of
        // RtpParameters (which is read-only in this WebRTC SDK version).

        // Phone-owned data channels (docs/PROTOCOL.md §6).
        controlChannel = peer.createDataChannel(CONTROL, DataChannel.Init())
        filesChannel = peer.createDataChannel(FILES, DataChannel.Init())
        controlChannel?.registerObserver(controlObserver)
        filesChannel?.registerObserver(filesObserver)

        // The phone is the offerer: it has the video track + channels.
        createOffer { sdp ->
            if (sdp != null) callback.onOffer(sdp)
        }

        callback.onState(NativeStates.READY)

        setClipboardWatcher(config.clipboardSync)
    }

    /** Hand the MediaProjection result Intent to the capturer and begin streaming frames. */
    fun attachProjection(resultData: Intent) {
        if (!running) return
        val existing = capturer
        if (existing != null) {
            existing.stopCapture()
            existing.dispose()
        }

        // Android 14+ requires a non-null MediaProjection callback, otherwise
        // MediaProjection.registerCallback() throws IllegalArgumentException
        // and the app crashes the moment capture starts. The callback also
        // cleans up when the user stops the projection (status-bar chip etc.).
        val projectionCallback = object : MediaProjection.Callback() {
            override fun onStop() {
                mainHandler.post {
                    val cap = capturer
                    capturer = null
                    if (cap != null) {
                        try {
                            cap.stopCapture()
                        } catch (_: Throwable) {
                        }
                        try {
                            cap.dispose()
                        } catch (_: Throwable) {
                        }
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

        // Send actual capture dimensions to the PC so touch mapping works.
        sendCaptureDimensions(w, h)
    }

    /** Generate the local offer SDP (phone is the offerer). */
    private fun createOffer(done: (String?) -> Unit) {
        peer.createOffer(
            object : SdpObserver {
                override fun onCreateSuccess(offer: SessionDescription?) {
                    // Inject bitrate hint into SDP so the encoder respects it.
                    val modified = injectBitrate(offer?.description)

                    peer.setLocalDescription(
                        object : SdpObserver {
                            override fun onSetSuccess() {
                                done(modified)
                            }

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

    /** Insert b=AS:<kbps> into the video m= line of the SDP offer. */
    private fun injectBitrate(sdp: String?): String {
        if (sdp == null) return ""
        val kbps = (lastConfig?.bitrate ?: 4_000_000) / 1000
        // Insert b=AS right after the m=video line.
        return sdp.replaceFirst(Regex("(m=video\\s+\\d+\\s+[^\r\n]+)"), "$1\r\nb=AS:$kbps")
    }

    /** Apply the PC's SDP answer. */
    fun setRemoteAnswer(sdp: String) {
        if (!running) return
        peer.setRemoteDescription(
            object : SdpObserver {
                override fun onCreateSuccess(sessionDescription: SessionDescription?) = Unit
                override fun onCreateFailure(error: String?) = Unit
                override fun onSetSuccess() = Unit
                override fun onSetFailure(error: String?) = callback.onState(NativeStates.ERROR)
            },
            SessionDescription(SessionDescription.Type.ANSWER, sdp),
        )
    }

    fun addIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        if (!running) return
        val idx = sdpMLineIndex ?: 0
        peer.addIceCandidate(IceCandidate(sdpMid, idx, candidate))
    }

    /** Send a UTF-8 text payload on the named data channel (phone → PC). */
    fun sendData(channel: String, base64Payload: String) {
        val target = if (channel == CONTROL) controlChannel else filesChannel
        if (target == null) {
            android.util.Log.w(TAG, "sendData: $channel channel is null, dropping")
            return
        }
        val bytes = android.util.Base64.decode(base64Payload, android.util.Base64.DEFAULT)
        val decodedText = try { String(bytes, Charsets.UTF_8) } catch (_: Throwable) { "<binary>" }
        android.util.Log.i(TAG, "sendData: $channel state=${target.state()} len=${bytes.size} decoded=$decodedText")
        try {
            target.send(DataChannel.Buffer(ByteBuffer.wrap(bytes), false))
            android.util.Log.i(TAG, "sendData: $channel send() returned OK")
        } catch (e: Throwable) {
            android.util.Log.e(TAG, "sendData: $channel send failed: ${e.message}")
        }
    }

    // ---- clipboard -----------------------------------------------------------

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

    /** Stream a SAF content URI (or file path) to the PC as a file transfer. */
    fun sendFile(contentUri: String) {
        if (!running) return
        val files = filesChannel ?: return
        // Short id that fits the 16-byte chunk header. A full UUID gets
        // truncated in the header and never matches the control-message id,
        // which breaks the PC's completion/bookkeeping (docs/PROTOCOL.md §6).
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
                    // file_picker hands back a cached filesystem path, not a
                    // content:// URI — open it directly (contentResolver rejects
                    // scheme-less paths with IllegalArgumentException).
                    try {
                        val f = java.io.File(contentUri)
                        name = f.name
                        size = f.length()
                        java.io.FileInputStream(f)
                    } catch (_: Exception) {
                        null
                    }
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

                sendControl(
                    JSONObject()
                        .put("type", "file")
                        .put("op", "send")
                        .put("id", id)
                        .put("name", name)
                        .put("size", size)
                        .put("mime", "application/octet-stream")
                        .toString(),
                )

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
                        files.send(DataChannel.Buffer(frame, true))
                        offset += read
                        callback.onFileProgress(id, offset, size)
                    }
                }
                sendControl(
                    JSONObject().put("type", "file").put("op", "done").put("id", id).toString(),
                )
            } catch (e: Exception) {
                sendControl(
                    JSONObject()
                        .put("type", "file").put("op", "error")
                        .put("id", id).put("reason", e.message)
                        .toString(),
                )
            }
        }
    }

    // ------------------------------------------------------------------ teardown

    fun stop() {
        if (!running) return
        running = false

        incomingFiles.values.forEach { it.output?.close() }
        incomingFiles.clear()

        capturer?.let {
            try {
                it.stopCapture()
            } catch (_: Throwable) {
            }
            it.dispose()
        }
        capturer = null

        controlChannel?.close()
        filesChannel?.close()
        controlChannel = null
        filesChannel = null

        try {
            peer.close()
        } catch (_: Throwable) {
        }
        try {
            videoSource.dispose()
        } catch (_: Throwable) {
        }
        try {
            surfaceTextureHelper.dispose()
        } catch (_: Throwable) {
        }
        try {
            eglBase.release()
        } catch (_: Throwable) {
        }
        worker.shutdown()
    }

    // ------------------------------------------------------------------ private

    private val pcObserver = object : PeerConnection.Observer {
        override fun onSignalingChange(state: PeerConnection.SignalingState?) {
            android.util.Log.i(TAG, "signaling state: $state")
        }

        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
            android.util.Log.i(TAG, "ice connection state: $state")
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
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {
            android.util.Log.i(TAG, "ice gathering state: $state")
        }

        override fun onIceCandidate(candidate: IceCandidate?) {
            candidate ?: return
            android.util.Log.i(TAG, "local ice candidate: ${candidate.sdp}")
            callback.onIceCandidate(candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex)
        }

        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) = Unit
        override fun onAddStream(stream: org.webrtc.MediaStream?) = Unit
        override fun onRemoveStream(stream: org.webrtc.MediaStream?) = Unit
        override fun onDataChannel(channel: DataChannel?) {
            channel ?: return
            android.util.Log.i(TAG, "onDataChannel label=${channel.label()}")
            when (channel.label()) {
                CONTROL -> {
                    controlChannel = channel
                    channel.registerObserver(controlObserver)
                    callback.onDataChannelOpened(CONTROL)
                }
                FILES -> {
                    filesChannel = channel
                    channel.registerObserver(filesObserver)
                    callback.onDataChannelOpened(FILES)
                }
            }
        }

        override fun onRenegotiationNeeded() = Unit
        override fun onAddTrack(
            receiver: org.webrtc.RtpReceiver?,
            mediaStreams: Array<out org.webrtc.MediaStream>?,
        ) = Unit

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

    /** Simple auto-quality: adapt capture height to the device's real FPS. */
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

    /** Tell the PC the actual capture resolution so touch coordinates map correctly. */
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
            android.util.Log.i(TAG, "control channel state: ${ch.state()}")
            if (ch.state() == DataChannel.State.OPEN) {
                callback.onDataChannelOpened("control")
                callback.onState(NativeStates.CONNECTED)
            }
        }
        override fun onMessage(buffer: DataChannel.Buffer?) {
            buffer ?: return
            android.util.Log.i(TAG, "control onMessage binary=${buffer.binary}")
            if (buffer.binary) return
            val bytes = ByteArray(buffer.data.remaining())
            buffer.data.get(bytes)
            android.util.Log.i(TAG, "control onMessage text=${String(bytes, Charsets.UTF_8).take(200)}")
            handleControl(bytes)
        }
    }

    private val filesObserver = object : DataChannel.Observer {
        override fun onBufferedAmountChange(previousAmount: Long) = Unit
        override fun onStateChange() {
            android.util.Log.i(TAG, "files channel state: ${filesChannel?.state()}")
        }
        override fun onMessage(buffer: DataChannel.Buffer?) {
            buffer ?: return
            android.util.Log.i("MirrorLinkFile", "filesObserver onMessage binary=${buffer.binary} size=${buffer.data.remaining()}")
            if (!buffer.binary) return
            val bytes = ByteArray(buffer.data.remaining())
            buffer.data.get(bytes)
            handleFileChunk(bytes)
        }
    }

    /** Process inbound `control` channel messages from the PC. */
    private fun handleControl(bytes: ByteArray) {
        val text = String(bytes, Charsets.UTF_8)
        val json = try {
            JSONObject(text)
        } catch (_: Exception) {
            return
        }

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
                if (t.isNotEmpty()) {
                    callback.onChat(t)
                }
            }
            "ping" -> sendControl("""{"type":"pong"}""")
            "input" -> InputAccessibilityService.instance?.handle(json)
            "file" -> handleFileControl(json)
        }
    }

    private fun handleFileControl(json: JSONObject) {
        val id = json.optString("id")
        when (json.optString("op")) {
            "send" -> {
                val sz = json.optLong("size", 0)
                android.util.Log.i("MirrorLinkFile", "SEND id=$id parsedSize=$sz name=${json.optString("name", "file")} rawSize=${json.opt("size")}")
                incomingFiles[id] = IncomingFile(
                    id = id,
                    name = json.optString("name", "file"),
                    size = sz,
                )
            }
            "done" -> {
                val file = incomingFiles[id] ?: return
                file.doneReceived = true
                android.util.Log.i("MirrorLinkFile", "DONE signal id=$id received=${file.received} size=${file.size} name=${file.name}")
                // If we already have all bytes, finalize now
                if (file.size > 0 && file.received >= file.size) {
                    finalizeFile(id, file)
                } else if (file.size <= 0) {
                    // No size reported, finalize immediately on done
                    finalizeFile(id, file)
                } else {
                    // Chunks still in transit — wait, but set a safety timeout
                    android.util.Log.i("MirrorLinkFile", "DONE waiting for ${file.size - file.received} more bytes id=$id")
                    mainHandler.postDelayed({
                        val f = incomingFiles[id] ?: return@postDelayed
                        android.util.Log.i("MirrorLinkFile", "DONE timeout firing id=$id received=${f.received}/${f.size}")
                        if (incomingFiles.containsKey(id)) {
                            finalizeFile(id, f)
                        }
                    }, 5000)
                }
            }
            "error" -> {
                incomingFiles.remove(id)?.output?.close()
            }
        }
    }

    /** Append a chunk received on the `files` channel into MediaStore. */
    private fun handleFileChunk(bytes: ByteArray) {
        if (bytes.size < 24) return
        val header = ByteBuffer.wrap(bytes, 0, 24)
        val idBytes = ByteArray(16)
        header.get(idBytes)
        val id = String(idBytes, Charsets.UTF_8).trim('\u0000')
        val offset = header.long
        if (offset < 0) return
        val payload = bytes.copyOfRange(24, bytes.size)

        android.util.Log.i("MirrorLinkFile", "chunk id=$id offset=$offset payload=${payload.size} receivedBefore=${incomingFiles[id]?.received}")
        val file = incomingFiles[id] ?: return
        val output = file.output ?: (openMediaStoreOutput(file, id)?.also { file.output = it }) ?: return

        try {
            output.write(payload)
            file.received += payload.size
            android.util.Log.i("MirrorLinkFile", "wrote id=$id offset=$offset received=${file.received} size=${file.size} done=${file.doneReceived}")
            callback.onFileProgress(id, file.received, file.size)
            // Finalize when done signal received AND all bytes arrived
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
        android.util.Log.i("MirrorLinkFile", "FINALIZE id=$id received=${file.received} size=${file.size} name=${file.name}")
        try {
            file.output?.flush()
            file.output?.close()
        } catch (_: Throwable) {
        }
        val filePath = file.uri?.let { resolveFilePath(it, file.name) }
        android.util.Log.i("MirrorLinkFile", "FINALIZE path=$filePath")
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
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveFilePath(uri: android.net.Uri, name: String = ""): String? {
        var ext = ""
        // First try the DATA column (works on pre-Q and some Q+ devices).
        try {
            val cursor = context.contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val idx = it.getColumnIndex(android.provider.MediaStore.MediaColumns.DATA)
                    if (idx >= 0) {
                        val path = it.getString(idx)
                        if (path != null && java.io.File(path).exists()) return path
                    }
                    val nameIdx = it.getColumnIndex(android.provider.MediaStore.MediaColumns.DISPLAY_NAME)
                    if (nameIdx >= 0) {
                        val dn = it.getString(nameIdx) ?: ""
                        val dot = dn.lastIndexOf('.')
                        if (dot >= 0) ext = dn.substring(dot).lowercase()
                    }
                }
            }
        } catch (_: Exception) {}
        // Fall back to the known file name, then the URI string.
        if (ext.isEmpty()) {
            val dot = name.lastIndexOf('.')
            if (dot >= 0) ext = name.substring(dot).lowercase()
        }
        if (ext.isEmpty()) {
            ext = when {
                uri.toString().contains(".jpg", true) || uri.toString().contains(".jpeg", true) -> ".jpg"
                uri.toString().contains(".png", true) -> ".png"
                uri.toString().contains(".gif", true) -> ".gif"
                uri.toString().contains(".webp", true) -> ".webp"
                else -> ".tmp"
            }
        }
        // Copy content URI to a temp file with the correct extension so that
        // video players (ExoPlayer) can pick the right extractor.
        return try {
            val tmp = java.io.File.createTempFile("mirrorlink_", ext, context.cacheDir)
            context.contentResolver.openInputStream(uri)?.use { input ->
                tmp.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            android.util.Log.i("MirrorLinkFile", "resolvePath ext=$ext tmp=${tmp.absolutePath} len=${tmp.length()}")
            tmp.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun sendControl(text: String) {
        controlChannel?.send(
            DataChannel.Buffer(ByteBuffer.wrap(text.toByteArray(Charsets.UTF_8)), false),
        )
    }

    /** Fit the display resolution into the configured max height, keeping aspect. */
    private fun fitWithin(screenW: Int, screenH: Int): Pair<Int, Int> {
        var (w, h) = screenW to screenH
        if (w > h) {
            // Landscape display: normalise so height is the smaller dimension.
            val tmp = w; w = h; h = tmp
        }
        val maxH = currentCaptureHeight
        if (h > maxH) {
            val scale = maxH.toDouble() / h
            w = (w * scale).toInt()
            h = maxH
        }
        // Round down to a multiple of 16: hardware encoders reject odd/unusual
        // sizes and silently fall back to slow software encoding.
        w = (w / 16) * 16
        h = (h / 16) * 16
        return maxOf(16, w) to maxOf(16, h)
    }
}

/** State strings shared with the Flutter layer (device_bridge.dart). */
object NativeStates {
    const val READY = "ready"
    const val CONNECTED = "connected"
    const val DISCONNECTED = "disconnected"
    const val ERROR = "error"
}
