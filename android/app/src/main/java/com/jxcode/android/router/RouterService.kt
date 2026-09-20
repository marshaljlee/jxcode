package com.jxcode.android.router

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process alive while a model or the router matters.
 *
 * Without a foreground service Android may reclaim the process when the UI
 * goes to the background, which takes a loaded GGUF with it — several seconds
 * of reload the user would experience as the app having forgotten everything.
 */
class RouterService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val detail = intent?.getStringExtra(EXTRA_DETAIL) ?: "Router listening on loopback"
        startForeground(NOTIFICATION_ID, buildNotification(detail))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(detail: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Router", NotificationManager.IMPORTANCE_LOW)
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("JXCode")
            .setContentText(detail)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "jxcode_router"
        private const val NOTIFICATION_ID = 5255
        const val EXTRA_DETAIL = "detail"

        fun start(context: Context, detail: String) {
            val intent = Intent(context, RouterService::class.java).putExtra(EXTRA_DETAIL, detail)
            runCatching { ContextCompat.startForegroundService(context, intent) }
        }

        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, RouterService::class.java)) }
        }
    }
}
