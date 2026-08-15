package com.mirrorlink.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder

/**
 * Foreground service that owns the [MediaProjection]. Because Android 14+
 * requires the projection token to be created inside a
 * `foregroundServiceType="mediaProjection"` service, the projection is
 * acquired here and handed to the running [RtcEngine] via [RtcEngineHolder].
 */
class ScreenProjectionService : Service() {

    private var projection: MediaProjection? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        val data = intent?.getParcelableExtra(EXTRA_RESULT_DATA) as? android.content.Intent
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }

        if (resultCode == RESULT_OK && data != null) {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            projection = manager.getMediaProjection(resultCode, data)
            RtcEngineHolder.engine?.attachProjection(projection)
        } else {
            RtcEngineHolder.engine?.stop()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Screen mirroring",
            NotificationManager.IMPORTANCE_LOW,
        )
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, ScreenProjectionService::class.java)
            .setAction(ACTION_STOP)

        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_mirrorlink)
            .setContentTitle("MirrorLink")
            .setContentText("Mirroring your screen")
            .setOngoing(true)
            .addAction(
                0,
                "Stop",
                android.app.PendingIntent.getService(
                    this, 1, stopIntent,
                    android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
            .build()
    }

    override fun onDestroy() {
        projection?.stop()
        projection = null
        RtcEngineHolder.engine?.stop()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "mirrorlink_mirroring"
        private const val NOTIFICATION_ID = 1001
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        private const val ACTION_STOP = "com.mirrorlink.android.STOP_MIRRORING"

        fun start(context: Context, resultCode: Int, resultData: android.content.Intent) {
            val intent = Intent(context, ScreenProjectionService::class.java)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_RESULT_DATA, resultData)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}

/** Global holder so the service can reach the active engine. */
object RtcEngineHolder {
    var engine: RtcEngine? = null
}
