package com.example.alarm_application

import android.content.Context
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.PowerManager
import android.util.Log

object AlarmPlayerManager {
    private var mediaPlayer: MediaPlayer? = null
    private var wakeLock: PowerManager.WakeLock? = null

    @Synchronized
    fun play(context: Context, uriString: String?) {
        stop()

        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "alarm_application:alarm_player"
            )
            try {
                wakeLock?.acquire(30 * 60 * 1000L)
            } catch (_: Exception) {
            }

            mediaPlayer = MediaPlayer().apply {
                setAudioStreamType(AudioManager.STREAM_ALARM)
                try {
                    val uri = if (!uriString.isNullOrEmpty()) Uri.parse(uriString) else null
                    if (uri != null) {
                        setDataSource(context, uri)
                    } else {
                        // fallback to default alarm tone
                        val alarmUri = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_ALARM)
                        setDataSource(context, alarmUri)
                    }
                    isLooping = true
                    prepare()
                    start()
                } catch (e: Exception) {
                    Log.e("AlarmPlayerManager", "Failed to start media player: ${e.message}")
                    try {
                        stop()
                    } catch (_: Exception) {}
                }
            }
        } catch (e: Exception) {
            Log.e("AlarmPlayerManager", "Error preparing alarm player: ${e.message}")
            stop()
        }
    }

    @Synchronized
    fun stop() {
        try {
            mediaPlayer?.let {
                if (it.isPlaying) {
                    try { it.stop() } catch (_: Exception) {}
                }
                try { it.release() } catch (_: Exception) {}
            }
        } catch (e: Exception) {
        } finally {
            mediaPlayer = null
        }

        try {
            wakeLock?.let {
                try { if (it.isHeld) it.release() } catch (_: Exception) {}
            }
        } catch (e: Exception) {
        } finally {
            wakeLock = null
        }
    }
}
