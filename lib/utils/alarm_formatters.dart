import 'package:flutter/material.dart';

/// Holds formatted time components for display
/// Separates hour, minute, and AM/PM for easy UI rendering
class FormattedAlarmTime {
  const FormattedAlarmTime({
    required this.hour,
    required this.minute,
    required this.period,
  });

  final String hour;    // Hour (1-12)
  final String minute;  // Minute (00-59)
  final String period;  // "AM" or "PM"
}

/// Converts a 24-hour TimeOfDay to 12-hour format with AM/PM
/// Example: 14:30 → "02:30 PM"
FormattedAlarmTime formatAlarmTime(TimeOfDay timeOfDay) {
  final displayHour = timeOfDay.hourOfPeriod == 0 ? 12 : timeOfDay.hourOfPeriod;
  return FormattedAlarmTime(
    hour: displayHour.toString().padLeft(2, '0'),
    minute: timeOfDay.minute.toString().padLeft(2, '0'),
    period: timeOfDay.period == DayPeriod.am ? 'AM' : 'PM',
  );
}

/// Extracts just the filename from a full file path
/// Example: "C:\Users\Music\alarm.mp3" → "alarm.mp3"
String fileNameFromPath(String filePath) {
  final sanitized = filePath.replaceAll('\\', '/');
  final index = sanitized.lastIndexOf('/');
  return index >= 0 ? sanitized.substring(index + 1) : sanitized;
}
