import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/alarm_models.dart';
import 'alarm_storage.dart';

/// Manages all alarm scheduling, notifications, and native alarm integration
/// Handles:
/// - Scheduling recurring alarms on specific days/times
/// - Reminder notifications (10, 5, 1 minute before alarm)
/// - Main alarm notification at alarm time
/// - Canceling alarms
/// - Platform-specific native alarm handling
class AlarmNotificationService {
  AlarmNotificationService._();

  static final AlarmNotificationService instance = AlarmNotificationService._();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  static const MethodChannel _platform = MethodChannel('alarm_app/settings');
  Future<void> Function(String payload)? _onAlarmTriggered;

  /// Initializes notification service, time zones, and permission handlers
  /// Should be called once at app startup
  /// - onAlarmTriggered: Callback when alarm is triggered
  Future<void> initialize({Future<void> Function(String payload)? onAlarmTriggered}) async {
    _onAlarmTriggered = onAlarmTriggered ?? _onAlarmTriggered;

    if (_isInitialized) {
      return;
    }

    tzdata.initializeTimeZones();
    try {
      final timeZoneInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timeZoneInfo.identifier));
    } catch (error, stackTrace) {
      debugPrint('Failed to resolve local timezone, using UTC: $error');
      debugPrintStack(stackTrace: stackTrace);
      tz.setLocalLocation(tz.UTC);
    }

    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );

    await _notifications.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        final payload = response.payload;
        if (payload == null) return;

        try {
          await _onAlarmTriggered?.call(payload);
        } catch (e) {
          debugPrint('Failed to handle notification payload: $e');
        }
      },
    );

    final androidImplementation = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      const alarmChannel = AndroidNotificationChannel(
        'smart_alarm_channel',
        'Smart Alarm',
        description: 'Scheduled alarms that keep working when the app is closed.',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );
      const reminderChannel = AndroidNotificationChannel(
        'smart_alarm_reminder_channel_v3',
        'Alarm Reminders',
        description: 'Reminders before alarms go off.',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      );

      await androidImplementation?.createNotificationChannel(alarmChannel);
      await androidImplementation?.createNotificationChannel(reminderChannel);
    } catch (error, stackTrace) {
      debugPrint('Notification channel setup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    _isInitialized = true;
  }

  /// Reschedules all saved alarms (useful after phone reboot)
  Future<void> rescheduleAll(List<AlarmEntry> alarms) async {
    await initialize();

    for (final alarm in alarms) {
      await scheduleAlarm(alarm);
    }
  }

  /// Schedules or updates a single alarm
  /// - Cancels any existing notifications for this alarm
  /// - Schedules reminders (10, 5, 1 minute before)
  /// - Schedules main alarm notification
  /// - Uses native platform alarms for better reliability
  Future<void> scheduleAlarm(AlarmEntry alarm) async {
    await initialize();

    await cancelAlarm(alarm);

    if (!alarm.enabled) {
      return;
    }

    for (var dayIndex = 0; dayIndex < alarm.repeatDays.length; dayIndex++) {
      if (!alarm.repeatDays[dayIndex]) {
        continue;
      }

      final scheduledDate = _nextWeeklyOccurrence(alarm.timeOfDay, dayIndex);
      final now = tz.TZDateTime.now(tz.local);
      for (final minutesBefore in [10, 5, 1]) {
        final preAlarmDate = scheduledDate.subtract(Duration(minutes: minutesBefore));
        if (!preAlarmDate.isAfter(now)) {
          continue;
        }
        final nativeScheduled = await scheduleNativeAlarm(
          _notificationIdForDay(alarm.notificationId, dayIndex, minutesBefore),
          preAlarmDate.toLocal(),
          'Alarm in $minutesBefore minute${minutesBefore > 1 ? 's' : ''}',
          alarm.label,
          payload: alarm.id,
          launchAlarmUi: false,
          soundUri: alarm.sound.filePath,
        );
        if (!nativeScheduled) {
          await _scheduleFallbackNotification(
            _notificationIdForDay(alarm.notificationId, dayIndex, minutesBefore),
            preAlarmDate.toLocal(),
            'Alarm in $minutesBefore minute${minutesBefore > 1 ? 's' : ''}',
            alarm.label,
            payload: alarm.id,
            launchAlarmUi: false,
          );
        }
      }

      final nativeScheduled = await scheduleNativeAlarm(
        _notificationIdForDay(alarm.notificationId, dayIndex),
        scheduledDate.toLocal(),
        'Smart Alarm',
        alarm.label,
        payload: alarm.id,
        launchAlarmUi: true,
        soundUri: alarm.sound.filePath,
      );
      if (!nativeScheduled) {
        await _scheduleFallbackNotification(
          _notificationIdForDay(alarm.notificationId, dayIndex),
          scheduledDate.toLocal(),
          'Smart Alarm',
          alarm.label,
          payload: alarm.id,
          launchAlarmUi: true,
        );
      }
    }
  }

  /// Cancels all notifications and alarms for a specific alarm entry
  /// Removes reminders and main alarm for all repeat days
  Future<void> cancelAlarm(AlarmEntry alarm) async {
    await initialize();

    for (var dayIndex = 0; dayIndex < 7; dayIndex++) {
      for (final minutesBefore in [10, 5, 1]) {
        final id = _notificationIdForDay(alarm.notificationId, dayIndex, minutesBefore);
        try {
          await _notifications.cancel(id: id);
        } catch (e) {
          debugPrint('Flutter cancel pre-alarm failed for $id: $e');
        }
        try {
          await cancelNativeAlarm(id);
        } catch (e) {
          debugPrint('Native cancel pre-alarm failed for $id: $e');
        }
      }

      final mainId = _notificationIdForDay(alarm.notificationId, dayIndex);
      try {
        await _notifications.cancel(id: mainId);
      } catch (e) {
        debugPrint('Flutter cancel main alarm failed for $mainId: $e');
      }
      try {
        await cancelNativeAlarm(mainId);
      } catch (e) {
        debugPrint('Native cancel main alarm failed for $mainId: $e');
      }
    }
  }

  /// Cancels ALL alarms and notifications in the entire app
  /// Used when user clears all alarms or uninstalls
  Future<void> cancelAll() async {
    await initialize();
    try {
      final stored = await AlarmStorage.instance.loadAlarms();
      for (final alarm in stored) {
        await cancelAlarm(alarm);
      }
    } catch (e) {
      debugPrint('Failed to cancel native alarms from storage: $e');
    }

    await _notifications.cancelAll();
  }

  /// Returns list of currently pending notifications
  Future<List<PendingNotificationRequest>> pendingNotifications() async {
    await initialize();
    return _notifications.pendingNotificationRequests();
  }

  /// Shows an immediate test notification (doesn't use scheduling)
  /// Used to test alarm notifications and sounds
  Future<void> showImmediateTestNotification(AlarmEntry alarm) async {
    await initialize();
    await _notifications.show(
      id: alarm.notificationId + 9999,
      title: 'Test Alarm',
      body: alarm.label,
      notificationDetails: _alarmNotificationDetails(alarm.sound),
      payload: alarm.id,
    );
  }

  /// Schedules a test alarm to trigger in 10 seconds (for quick testing)
  Future<void> scheduleQuickZonedTest() async {
    await initialize();
    final now = tz.TZDateTime.now(tz.local);
    final scheduled = now.add(const Duration(seconds: 10));
    try {
      await scheduleNativeAlarm(
        999901,
        scheduled.toLocal(),
        'Scheduled Test Alarm',
        'scheduled test',
        payload: 'scheduled_test',
        launchAlarmUi: true,
      );
    } catch (e) {
      debugPrint('Native quick test schedule failed: $e');
      await _notifications.zonedSchedule(
        id: 999901,
        title: 'Scheduled Test Alarm',
        body: 'scheduled test',
        scheduledDate: scheduled,
        notificationDetails: _alarmNotificationDetails(
          const AlarmSoundChoice.phoneFile(displayName: 'Test', filePath: ''),
        ),
        payload: 'scheduled_test',
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  /// Requests notification permission from user (Android 13+)
  /// Returns true if user grants permission, false if denied
  Future<bool?> requestNotificationPermission() async {
    await initialize();
    final androidImpl = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      return await androidImpl?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('requestNotificationPermission failed: $e');
      return null;
    }
  }

  /// Checks if notifications are currently enabled
  Future<bool?> areNotificationsEnabled() async {
    await initialize();
    final androidImpl = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      return await androidImpl?.areNotificationsEnabled();
    } catch (e) {
      debugPrint('areNotificationsEnabled failed: $e');
      return null;
    }
  }

  /// Requests permission to set exact alarms (Android 12+)
  /// Needed for accurate alarm triggering
  Future<bool?> requestExactAlarmsPermission() async {
    await initialize();
    final androidImpl = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      return await androidImpl?.requestExactAlarmsPermission();
    } catch (e) {
      debugPrint('requestExactAlarmsPermission failed: $e');
      return null;
    }
  }

  /// Checks if app can schedule exact notifications
  Future<bool?> canScheduleExactNotifications() async {
    await initialize();
    final androidImpl = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    try {
      return await androidImpl?.canScheduleExactNotifications();
    } catch (e) {
      debugPrint('canScheduleExactNotifications failed: $e');
      return null;
    }
  }

  /// Opens the app's settings page on the device
  Future<void> openAppSettings() async {
    try {
      await _platform.invokeMethod('openAppSettings');
    } catch (e) {
      debugPrint('openAppSettings failed: $e');
    }
  }

  /// Opens the device's battery optimization settings
  /// Users can add app to battery whitelist for reliable alarms
  Future<void> openBatterySettings() async {
    try {
      await _platform.invokeMethod('openBatterySettings');
    } catch (e) {
      debugPrint('openBatterySettings failed: $e');
    }
  }

  /// Schedules a native Android alarm (more reliable than Flutter notifications)
  /// Platform-specific implementation for critical alarm functionality
  Future<bool> scheduleNativeAlarm(
    int id,
    DateTime dateTime,
    String title,
    String body, {
    String? payload,
    bool launchAlarmUi = true,
    String? soundUri,
  }) async {
    try {
      final scheduled = await _platform.invokeMethod<bool>('scheduleNativeAlarm', {
        'id': id,
        'triggerAt': dateTime.millisecondsSinceEpoch,
        'title': title,
        'body': body,
        'payload': payload ?? id.toString(),
        'launchAlarmUi': launchAlarmUi,
        'soundUri': soundUri,
      });
      return scheduled ?? false;
    } catch (e) {
      debugPrint('scheduleNativeAlarm failed: $e');
      return false;
    }
  }

  Future<void> _scheduleFallbackNotification(
    int id,
    DateTime dateTime,
    String title,
    String body, {
    required String payload,
    required bool launchAlarmUi,
  }) async {
    final scheduledDate = tz.TZDateTime.from(dateTime, tz.local);
    await _notifications.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      notificationDetails: _alarmNotificationDetails(
        const AlarmSoundChoice.phoneFile(displayName: '', filePath: ''),
      ),
      payload: payload,
      androidScheduleMode: launchAlarmUi
          ? AndroidScheduleMode.inexactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Cancels a previously scheduled native alarm
  Future<void> cancelNativeAlarm(int id) async {
    try {
      await _platform.invokeMethod('cancelNativeAlarm', {'id': id});
    } catch (e) {
      debugPrint('cancelNativeAlarm failed: $e');
    }
  }

  /// Stops the alarm sound that's currently playing
  Future<void> stopNativeAlarmSound() async {
    try {
      await _platform.invokeMethod('stopNativeAlarmSound');
    } catch (e) {
      debugPrint('stopNativeAlarmSound failed: $e');
    }
  }

  /// Creates notification details for alarm notifications (title, body, sound, etc.)
  NotificationDetails _alarmNotificationDetails(AlarmSoundChoice sound) {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'smart_alarm_channel',
        'Smart Alarm',
        channelDescription: 'Scheduled alarms that keep working when the app is closed.',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        fullScreenIntent: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        category: AndroidNotificationCategory.alarm,
        ongoing: true,
        autoCancel: false,
      ),
    );
  }
}

/// Generates unique notification ID based on alarm ID, day, and reminder time
/// Formula ensures no two notifications have the same ID
int _notificationIdForDay(int alarmId, int dayIndex, [int minutesBefore = 0]) {
  if (minutesBefore == 0) {
    return alarmId * 100 + dayIndex;
  }
  final offsetMap = {10: 10, 5: 20, 1: 30};
  return alarmId * 100 + dayIndex + (offsetMap[minutesBefore] ?? 0);
}

/// Calculates the next occurrence of a weekly alarm on a specific day
/// If the scheduled time has already passed today, schedules for next week
tz.TZDateTime _nextWeeklyOccurrence(TimeOfDay timeOfDay, int dayIndex) {
  final now = tz.TZDateTime.now(tz.local);
  var scheduled = tz.TZDateTime(
    tz.local,
    now.year,
    now.month,
    now.day,
    timeOfDay.hour,
    timeOfDay.minute,
  );
  final targetWeekday = dayIndex == 0 ? DateTime.sunday : dayIndex;

  while (scheduled.weekday != targetWeekday) {
    scheduled = scheduled.add(const Duration(days: 1));
  }

  if (scheduled.isBefore(now)) {
    scheduled = scheduled.add(const Duration(days: 7));
  }

  return scheduled;
}
