package com.example.alarm_application

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.PowerManager
import android.os.Build
import androidx.core.app.NotificationCompat
import kotlin.concurrent.thread

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra("id", 0)
        val title = intent.getStringExtra("title") ?: "Smart Alarm"
        val body = intent.getStringExtra("body") ?: "Alarm"
        val payload = intent.getStringExtra("payload") ?: ""
        val launchAlarmUi = intent.getBooleanExtra("launchAlarmUi", true)

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // For real alarms, wake the device and start native playback (managed by AlarmPlayerManager).
        if (launchAlarmUi) {
            val soundUri = intent.getStringExtra("sound_uri")
            try {
                AlarmPlayerManager.play(context, soundUri)
            } catch (e: Exception) {
                android.util.Log.e("AlarmReceiver", "Failed to start AlarmPlayerManager: ${e.message}")
            }
        }

        val channelId = if (launchAlarmUi) "smart_alarm_channel" else "smart_alarm_reminder_channel_v3"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val importance = if (launchAlarmUi) NotificationManager.IMPORTANCE_HIGH else NotificationManager.IMPORTANCE_HIGH
            val channelName = if (launchAlarmUi) "Smart Alarm" else "Alarm Reminders"
            val channel = NotificationChannel(channelId, channelName, importance)
            channel.description = if (launchAlarmUi) "Scheduled alarms" else "Reminder notifications before alarms"
            channel.enableVibration(true)
            if (launchAlarmUi) {
                channel.enableLights(true)
            }
            nm.createNotificationChannel(channel)
        }

        val defaultSoundUri: Uri = RingtoneManager.getDefaultUri(
            if (launchAlarmUi) RingtoneManager.TYPE_ALARM else RingtoneManager.TYPE_NOTIFICATION
        )

        val streamType = if (launchAlarmUi) AudioManager.STREAM_ALARM else AudioManager.STREAM_NOTIFICATION

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setSound(defaultSoundUri, streamType)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(if (launchAlarmUi) NotificationCompat.CATEGORY_ALARM else NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(!launchAlarmUi)
            .setOngoing(launchAlarmUi)

        if (launchAlarmUi) {
            // Only the real alarm can open the ringing screen.
            val activityIntent = Intent(context, MainActivity::class.java).apply {
                putExtra("alarm_payload", payload)
                putExtra("alarm_launch_ui", true)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val activityPending = PendingIntent.getActivity(
                context,
                id,
                activityIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            builder.setContentIntent(activityPending)

            val fullScreenIntent = Intent(context, MainActivity::class.java).apply {
                putExtra("alarm_payload", payload)
                putExtra("alarm_launch_ui", true)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val fullScreenPending = PendingIntent.getActivity(
                context,
                id + 100000,
                fullScreenIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.setFullScreenIntent(fullScreenPending, true)

            // Try to start activity immediately. If that fails (OEM restrictions, doze, locked state),
            // schedule a few retries on the main looper to improve reliability.
            val tryLaunch = {
                try {
                    context.startActivity(activityIntent)
                    true
                } catch (e: Exception) {
                    android.util.Log.w("AlarmReceiver", "startActivity failed: ${e.message}")
                    false
                }
            }

            if (!tryLaunch()) {
                try {
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ tryLaunch() }, 500)
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ tryLaunch() }, 1500)
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ tryLaunch() }, 3000)
                } catch (_: Exception) {
                    // If scheduling retries fails, rely on the full-screen intent notification.
                }
            }
        }

        nm.notify(id, builder.build())
        
        // Release wake lock after a long delay (it will be held by the main alarm sound thread)
        // Keep it acquired longer so Flutter has time to load and take over
    }
}
