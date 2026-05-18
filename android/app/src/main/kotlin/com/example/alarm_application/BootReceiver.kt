package com.example.alarm_application

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.SystemClock
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            try {
                rescheduleFromPrefs(context)
            } catch (e: Exception) {
                Log.e("BootReceiver", "Reschedule failed: ${e.message}")
            }
        }
    }

    private fun rescheduleFromPrefs(context: Context) {
        val prefsName = "FlutterSharedPreferences"
        val prefs: SharedPreferences = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)

        val storedSet = prefs.getStringSet("saved_alarms", null) ?: return

        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val now = System.currentTimeMillis()

        for (raw in storedSet) {
            try {
                val obj = JSONObject(raw)
                val enabled = obj.optBoolean("enabled", true)
                if (!enabled) continue

                val alarmId = obj.optInt("notificationId", obj.optInt("id", 0))
                val hour = obj.optInt("hour", 7)
                val minute = obj.optInt("minute", 30)

                val repeatArr = obj.optJSONArray("repeatDays") ?: JSONArray()
                val repeatDays = BooleanArray(7) { i -> repeatArr.optBoolean(i, false) }

                for (dayIndex in 0..6) {
                    if (!repeatDays[dayIndex]) continue

                    val scheduledMillis = nextWeeklyOccurrenceMillis(hour, minute, dayIndex)

                    // Schedule pre-alarms if they are still in the future
                    for (minutesBefore in intArrayOf(10, 5, 1)) {
                        val preMillis = scheduledMillis - minutesBefore * 60 * 1000L
                        if (preMillis > now) {
                            val preId = notificationIdForDay(alarmId, dayIndex, minutesBefore)
                            schedule(alarmId = preId, triggerAt = preMillis, title = "Alarm in $minutesBefore minute${if (minutesBefore>1) "s" else ""}", body = obj.optString("label", ""), payload = alarmId.toString(), launchAlarmUi = false, am = am, context = context)
                        }
                    }

                    // Schedule main alarm (should be in the future)
                    if (scheduledMillis > now) {
                        val mainId = notificationIdForDay(alarmId, dayIndex)
                        schedule(alarmId = mainId, triggerAt = scheduledMillis, title = "Smart Alarm", body = obj.optString("label", ""), payload = alarmId.toString(), launchAlarmUi = true, am = am, context = context)
                    }
                }

            } catch (e: Exception) {
                Log.w("BootReceiver", "Skipping invalid alarm entry: ${e.message}")
            }
        }
    }

    private fun schedule(alarmId: Int, triggerAt: Long, title: String, body: String, payload: String, launchAlarmUi: Boolean, am: AlarmManager, context: Context) {
        val intent = Intent(context, AlarmReceiver::class.java).apply {
            action = "com.example.alarm_application.ALARM_TRIGGER"
            putExtra("id", alarmId)
            putExtra("title", title)
            putExtra("body", body)
            putExtra("payload", payload)
            putExtra("launchAlarmUi", launchAlarmUi)
        }
        val pi = PendingIntent.getBroadcast(context, alarmId, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
    }

    private fun nextWeeklyOccurrenceMillis(hour: Int, minute: Int, dayIndex: Int): Long {
        val now = Calendar.getInstance()
        val scheduled = Calendar.getInstance()
        scheduled.set(Calendar.HOUR_OF_DAY, hour)
        scheduled.set(Calendar.MINUTE, minute)
        scheduled.set(Calendar.SECOND, 0)
        scheduled.set(Calendar.MILLISECOND, 0)

        val targetWeekday = dayIndex + 1 // Calendar.SUNDAY=1 ... SATURDAY=7; dayIndex 0 => Sunday

        val todayWeekday = scheduled.get(Calendar.DAY_OF_WEEK)
        var daysAhead = (targetWeekday - todayWeekday + 7) % 7
        if (daysAhead == 0 && scheduled.timeInMillis <= now.timeInMillis) {
            daysAhead = 7
        }
        scheduled.add(Calendar.DAY_OF_YEAR, daysAhead)
        return scheduled.timeInMillis
    }

    private fun notificationIdForDay(alarmId: Int, dayIndex: Int, minutesBefore: Int = 0): Int {
        if (minutesBefore == 0) return alarmId * 100 + dayIndex
        val offsetMap = mapOf(10 to 10, 5 to 20, 1 to 30)
        return alarmId * 100 + dayIndex + (offsetMap[minutesBefore] ?: 0)
    }
}
