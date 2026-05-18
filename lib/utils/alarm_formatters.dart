import 'package:flutter/material.dart';

class FormattedAlarmTime {
  const FormattedAlarmTime({
    required this.hour,
    required this.minute,
    required this.period,
  });

  final String hour;
  final String minute;
  final String period;
}

FormattedAlarmTime formatAlarmTime(TimeOfDay timeOfDay) {
  final displayHour = timeOfDay.hourOfPeriod == 0 ? 12 : timeOfDay.hourOfPeriod;
  return FormattedAlarmTime(
    hour: displayHour.toString().padLeft(2, '0'),
    minute: timeOfDay.minute.toString().padLeft(2, '0'),
    period: timeOfDay.period == DayPeriod.am ? 'AM' : 'PM',
  );
}

String fileNameFromPath(String filePath) {
  final sanitized = filePath.replaceAll('\\', '/');
  final index = sanitized.lastIndexOf('/');
  return index >= 0 ? sanitized.substring(index + 1) : sanitized;
}
