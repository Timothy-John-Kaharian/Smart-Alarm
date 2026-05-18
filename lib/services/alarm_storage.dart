import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/alarm_models.dart';

class AlarmStorage {
  AlarmStorage._();

  static final AlarmStorage instance = AlarmStorage._();
  static const String _alarmsKey = 'saved_alarms';
  static const String _nextAlarmIdKey = 'next_alarm_id';

  Future<List<AlarmEntry>> loadAlarms() async {
    final preferences = await SharedPreferences.getInstance();
    final rawAlarms = preferences.getStringList(_alarmsKey) ?? const [];
    final alarms = rawAlarms
        .map((item) => AlarmEntry.fromJson(jsonDecode(item) as Map<String, dynamic>))
        .toList(growable: false);

    final highestId = alarms.fold<int>(
      0,
      (currentMax, alarm) => max(currentMax, alarm.notificationId),
    );
    final storedNextId = preferences.getInt(_nextAlarmIdKey) ?? 1;
    if (storedNextId <= highestId) {
      await preferences.setInt(_nextAlarmIdKey, highestId + 1);
    }

    return alarms;
  }

  Future<void> saveAlarms(List<AlarmEntry> alarms) async {
    final preferences = await SharedPreferences.getInstance();
    final encodedAlarms = alarms
        .map((alarm) => jsonEncode(alarm.toJson()))
        .toList(growable: false);
    await preferences.setStringList(_alarmsKey, encodedAlarms);

    final highestId = alarms.fold<int>(
      0,
      (currentMax, alarm) => max(currentMax, alarm.notificationId),
    );
    final nextId = max(highestId + 1, preferences.getInt(_nextAlarmIdKey) ?? 1);
    await preferences.setInt(_nextAlarmIdKey, nextId);
  }

  Future<int> allocateAlarmId() async {
    final preferences = await SharedPreferences.getInstance();
    final nextId = preferences.getInt(_nextAlarmIdKey) ?? 1;
    await preferences.setInt(_nextAlarmIdKey, nextId + 1);
    return nextId;
  }
}

class ScheduleStorage {
  ScheduleStorage._();

  static final ScheduleStorage instance = ScheduleStorage._();
  static const String _schedulesKey = 'saved_schedules';

  Future<List<ScheduleEntry>> loadSchedules() async {
    final preferences = await SharedPreferences.getInstance();
    final rawSchedules = preferences.getStringList(_schedulesKey) ?? const [];
    return rawSchedules
        .map((item) => ScheduleEntry.fromJson(jsonDecode(item) as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> saveSchedules(List<ScheduleEntry> schedules) async {
    final preferences = await SharedPreferences.getInstance();
    final encodedSchedules = schedules
        .map((schedule) => jsonEncode(schedule.toJson()))
        .toList(growable: false);
    await preferences.setStringList(_schedulesKey, encodedSchedules);
  }
}

class NoteStorage {
  NoteStorage._();

  static final NoteStorage instance = NoteStorage._();
  static const String _notesKey = 'saved_notes';

  Future<List<NoteEntry>> loadNotes() async {
    final preferences = await SharedPreferences.getInstance();
    final rawNotes = preferences.getStringList(_notesKey) ?? const [];
    return rawNotes
        .map((item) => NoteEntry.fromJson(jsonDecode(item) as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> saveNotes(List<NoteEntry> notes) async {
    final preferences = await SharedPreferences.getInstance();
    final encodedNotes = notes
        .map((note) => jsonEncode(note.toJson()))
        .toList(growable: false);
    await preferences.setStringList(_notesKey, encodedNotes);
  }
}
