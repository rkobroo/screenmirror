package com.mirrorlink.android

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Hosts the Flutter UI and bridges it to the native media stack. */
class MirrorLinkMainActivity : FlutterActivity(), RtcEngine.Callback {

    companion object {
        private const val CHANNEL = "mirrorlink/device"
        private const val EVENTS = "mirrorlink/device_events"
        private const val REQ_PROJECTION = 4101
        private const val REQ_POST_NOTIFICATIONS = 4102
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var engine: RtcEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getDeviceInfo" -> result.success(
                mapOf(
                    "name" to "${Build.MANUFACTURER} ${Build.MODEL}",
                    "androidVersion" to Build.VERSION.RELEASE,
                    "sdk" to Build.VERSION.SDK_INT,
                ),
            )
            "isAccessibilityEnabled" -> result.success(InputAccessibilityService.isEnabled(this))
            "openAccessibilitySettings" -> {
                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                result.success(null)
            }
            "requestProjection" -> {
                if (Build.VERSION.SDK_INT >= 33) {
                    val granted = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.POST_NOTIFICATIONS,
                    ) == PackageManager.PERMISSION_GRANTED
                    if (!granted) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_POST_NOTIFICATIONS)
                    }
                }
                startProjectionPermissionFlow()
                result.success(null)
            }
            "startSession" -> {
                val width = (call.argument<Number>("width"))?.toInt() ?: 1280
                val height = (call.argument<Number>("height"))?.toInt() ?: 720
                val fps = (call.argument<Number>("fps"))?.toInt() ?: 30
                val bitrate = (call.argument<Number>("bitrate"))?.toInt() ?: 4_000_000
                val autoQuality = call.argument<Boolean>("autoQuality") ?: true
                val nickname = call.argument<String>("nickname") ?: ""
                val clipboardSync = call.argument<Boolean>("clipboardSync") ?: false

                engine = RtcEngine(applicationContext, this)
                RtcEngineHolder.engine = engine
                engine!!.start(
                    RtcEngine.Config(
                        width, height, fps, bitrate, autoQuality, nickname, clipboardSync,
                    ),
                )
                result.success(null)
            }
            "setRemoteAnswer" -> {
                val sdp = call.argument<String>("sdp")
                engine?.setRemoteAnswer(sdp ?: "")
                result.success(null)
            }
            "addIceCandidate" -> {
                engine?.addIceCandidate(
                    call.argument<String>("candidate") ?: "",
                    call.argument<String>("sdpMid"),
                    (call.argument<Number>("sdpMLineIndex"))?.toInt(),
                )
                result.success(null)
            }
            "stopSession" -> {
                engine?.stop()
                engine = null
                RtcEngineHolder.engine = null
                stopScreenService()
                result.success(null)
            }
            "sendData" -> {
                val channel = call.argument<String>("channel") ?: ""
                val payload = call.argument<String>("payload") ?: ""
                android.util.Log.i("MirrorLinkRtc", "methodChannel sendData: channel=$channel payloadLen=${payload.length} engine=${engine != null}")
                engine?.sendData(channel, payload)
                result.success(null)
            }
            "setClipboardWatcher" -> {
                engine?.setClipboardWatcher(call.argument<Boolean>("enabled") ?: false)
                result.success(null)
            }
            "sendFile" -> {
                engine?.sendFile(call.argument<String>("uri") ?: "")
                result.success(null)
            }
            "openFile" -> {
                val path = call.argument<String>("path") ?: ""
                if (path.isNotEmpty()) {
                    try {
                        val file = java.io.File(path)
                        val uri = if (android.os.Build.VERSION.SDK_INT >= 24) {
                            androidx.core.content.FileProvider.getUriForFile(
                                this,
                                "${packageName}.fileprovider",
                                file,
                            )
                        } else {
                            android.net.Uri.fromFile(file)
                        }
                        val ext = path.substringAfterLast('.', "")
                        val mime = android.webkit.MimeTypeMap.getSingleton()
                            .getMimeTypeFromExtension(ext.lowercase()) ?: "*/*"
                        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mime)
                            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(android.content.Intent.createChooser(intent, "Open file"))
                    } catch (e: Throwable) {
                        android.util.Log.e("MirrorLinkRtc", "openFile failed: ${e.message}")
                    }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startProjectionPermissionFlow() {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(manager.createScreenCaptureIntent(), REQ_PROJECTION)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PROJECTION) return
        if (resultCode == RESULT_OK && data != null) {
            ScreenProjectionService.start(this, resultCode, data)
            emit("state", "starting")
        } else {
            emit("state", "permissionDenied")
        }
    }

    private fun stopScreenService() {
        try {
            val intent = Intent(this, ScreenProjectionService::class.java)
                .setAction("com.mirrorlink.android.STOP_MIRRORING")
            startService(intent)
        } catch (_: Throwable) {}
    }

    // ----------------------------------------------------------- engine events

    private fun emit(type: String, value: Any) {
        mainHandler.post {
            eventSink?.success(mapOf("type" to type, "value" to value))
        }
    }

    private fun emit(type: String, map: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(mapOf("type" to type) + map)
        }
    }

    override fun onIceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int) {
        emit(
            "ice",
            mapOf(
                "candidate" to candidate,
                "sdpMid" to sdpMid,
                "sdpMLineIndex" to sdpMLineIndex,
            ),
        )
    }

    override fun onOffer(sdp: String) {
        emit("offer", mapOf("sdp" to sdp))
    }

    override fun onState(state: String) {
        emit("state", state)
    }

    override fun onStats(fps: Int, bps: Long) {
        emit("stats", mapOf("fps" to fps, "bps" to bps))
    }

    override fun onClipboard(text: String) {
        emit("clipboard", mapOf("text" to text))
    }

    override fun onChat(text: String) {
        emit("chat", mapOf("text" to text))
    }

    override fun onFileProgress(id: String, received: Long, total: Long) {
        emit("fileProgress", mapOf("id" to id, "received" to received, "total" to total))
    }

    override fun onFileDone(id: String, name: String, uri: String?) {
        emit("fileDone", mapOf("id" to id, "name" to name, "filePath" to (uri ?: "")))
    }

    override fun onDataChannelOpened(channel: String) {
        emit("dcOpen", channel)
    }

    override fun onDestroy() {
        window.decorView.alpha = 0f
        stopScreenService()
        engine?.stop()
        engine = null
        RtcEngineHolder.engine = null
        super.onDestroy()
    }
}
