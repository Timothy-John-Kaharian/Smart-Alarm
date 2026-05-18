import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/alarm_models.dart';

/// Manages saving and loading alarm data from device storage (persistent)
/// Uses SharedPreferences for local storage
class AlarmStorage {
  AlarmStorage._();

  static final AlarmStorage instance = AlarmStorage._();
  static const String _alarmsKey = 'saved_alarms';
  static const String _nextAlarmIdKey = 'next_alarm_id';

  /// Loads all saved alarms from local storage
  /// Automatically updates next alarm ID to prevent duplicates
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

  /// Saves all alarms to local storage
  /// Also updates the next alarm ID counter to prevent duplicates
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

  /// Generates a unique ID for a new alarm
  /// Ensures no two alarms have the same ID
  Future<int> allocateAlarmId() async {
    final preferences = await SharedPreferences.getInstance();
    final nextId = preferences.getInt(_nextAlarmIdKey) ?? 1;
    await preferences.setInt(_nextAlarmIdKey, nextId + 1);
    return nextId;
  }
}

/// Manages saving and loading scheduled events from local storage
class ScheduleStorage {
  ScheduleStorage._();

  static final ScheduleStorage instance = ScheduleStorage._();
  static const String _schedulesKey = 'saved_schedules';

  /// Loads all saved schedules from local storage
  Future<List<ScheduleEntry>> loadSchedules() async {
    final preferences = await SharedPreferences.getInstance();
    final rawSchedules = preferences.getStringList(_schedulesKey) ?? const [];
    return rawSchedules
        .map((item) => ScheduleEntry.fromJson(jsonDecode(item) as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Saves all schedules to local storage
  Future<void> saveSchedules(List<ScheduleEntry> schedules) async {
    final preferences = await SharedPreferences.getInstance();
    final encodedSchedules = schedules
        .map((schedule) => jsonEncode(schedule.toJson()))
        .toList(growable: false);
    await preferences.setStringList(_schedulesKey, encodedSchedules);
  }
}

/// Manages saving and loading user notes from local storage
class NoteStorage {
  NoteStorage._();

  static final NoteStorage instance = NoteStorage._();
  static const String _notesKey = 'saved_notes';

  /// Loads all saved notes from local storage
  Future<List<NoteEntry>> loadNotes() async {
    final preferences = await SharedPreferences.getInstance();
    final rawNotes = preferences.getStringList(_notesKey) ?? const [];
    return rawNotes
        .map((item) => NoteEntry.fromJson(jsonDecode(item) as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Saves all notes to local storage
  Future<void> saveNotes(List<NoteEntry> notes) async {
    final preferences = await SharedPreferences.getInstance();
    final encodedNotes = notes
        .map((note) => jsonEncode(note.toJson()))
        .toList(growable: false);
    await preferences.setStringList(_notesKey, encodedNotes);
  }
}
