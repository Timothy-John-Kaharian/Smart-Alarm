package com.example.alarm_application

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	companion object {
		// Hold a pending payload if the activity is started before Dart registers
		// its method channel handler. Dart can fetch and clear this via a
		// MethodChannel call.
		var pendingAlarmPayload: String? = null
	}
	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)

		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
			setShowWhenLocked(true)
			setTurnScreenOn(true)
		} else {
			@Suppress("DEPRECATION")
			window.addFlags(
				WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
					WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
			)
		}
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "alarm_app/settings").setMethodCallHandler { call, result ->
			when (call.method) {
				"openAppSettings" -> {
					val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
					intent.data = Uri.parse("package:$packageName")
					intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
					startActivity(intent)
					result.success(true)
				}
				"openBatterySettings" -> {
					try {
						val intent = Intent()
						intent.action = Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
						intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
						startActivity(intent)
						result.success(true)
					} catch (e: Exception) {
						result.error("ERR", "Could not open battery settings: ${e.message}", null)
					}
				}
				"scheduleNativeAlarm" -> {
					val alarmId = call.argument<Int>("id") ?: 0
					val triggerAt = call.argument<Long>("triggerAt") ?: 0L
					val title = call.argument<String>("title") ?: "Smart Alarm"
					val body = call.argument<String>("body") ?: "Alarm"
					val payload = call.argument<String>("payload") ?: ""
					val launchAlarmUi = call.argument<Boolean>("launchAlarmUi") ?: true
					val soundUri = call.argument<String>("soundUri")
					scheduleNativeAlarm(alarmId, triggerAt, title, body, payload, launchAlarmUi, soundUri)
					result.success(true)
				}
				"cancelNativeAlarm" -> {
					val alarmId = call.argument<Int>("id") ?: 0
					cancelNativeAlarm(alarmId)
					result.success(true)
				}
				"fetchPendingAlarmPayload" -> {
					val payload = pendingAlarmPayload
					pendingAlarmPayload = null
					result.success(payload)
				}
				"stopNativeAlarmSound" -> {
					try {
						AlarmPlayerManager.stop()
						result.success(true)
					} catch (e: Exception) {
						result.error("ERR", "Failed to stop native alarm: ${e.message}", null)
					}
				}
				else -> result.notImplemented()
			}
		}

		// forward initial intent payload if present; store it as pending in case
		// Dart's handler isn't yet registered.
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "alarm_app/receive").let { ch ->
			val launchUi = intent?.getBooleanExtra("alarm_launch_ui", false) ?: false
			if (launchUi) {
				intent?.getStringExtra("alarm_payload")?.let { payload ->
				pendingAlarmPayload = payload
				ch.invokeMethod("alarmTrigger", payload)
				}
			}
		}
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		if (intent.getBooleanExtra("alarm_launch_ui", false)) {
			intent.getStringExtra("alarm_payload")?.let { payload ->
				pendingAlarmPayload = payload
				this.flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
					MethodChannel(messenger, "alarm_app/receive").invokeMethod("alarmTrigger", payload)
				}
			}
		}
	}

	private fun scheduleNativeAlarm(alarmId: Int, triggerAtMillis: Long, title: String, body: String, payload: String, launchAlarmUi: Boolean, soundUri: String?) {
		val am = getSystemService(ALARM_SERVICE) as android.app.AlarmManager
		val intent = Intent(this, AlarmReceiver::class.java).apply {
			action = "com.example.alarm_application.ALARM_TRIGGER"
			putExtra("id", alarmId)
			putExtra("title", title)
			putExtra("body", body)
			putExtra("payload", payload)
			putExtra("launchAlarmUi", launchAlarmUi)
			if (!soundUri.isNullOrEmpty()) putExtra("sound_uri", soundUri)
		}
		val pi = PendingIntent.getBroadcast(this, alarmId, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
		am.setExactAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, triggerAtMillis, pi)
	}

	private fun cancelNativeAlarm(alarmId: Int) {
		val am = getSystemService(ALARM_SERVICE) as android.app.AlarmManager
		val intent = Intent(this, AlarmReceiver::class.java).apply {
			action = "com.example.alarm_application.ALARM_TRIGGER"
		}
		val pi = PendingIntent.getBroadcast(this, alarmId, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
		am.cancel(pi)
	}
}
