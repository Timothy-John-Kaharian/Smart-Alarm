import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../utils/alarm_formatters.dart';

/// Defines difficulty levels for math questions users must solve to dismiss alarms
enum AlarmDifficulty { easy, medium, hard }

/// Extension to get user-friendly labels and colors for alarm difficulty levels
extension AlarmDifficultyLabel on AlarmDifficulty {
  /// Returns display label (e.g., 'Easy', 'Medium', 'Hard')
  String get label {
    switch (this) {
      case AlarmDifficulty.easy:
        return 'Easy';
      case AlarmDifficulty.medium:
        return 'Medium';
      case AlarmDifficulty.hard:
        return 'Hard';
    }
  }

  Color get color {
    switch (this) {
      case AlarmDifficulty.easy:
        return const Color(0xFF13A54B);
      case AlarmDifficulty.medium:
        return const Color(0xFFF08A00);
      case AlarmDifficulty.hard:
        return const Color(0xFFE11D48);
    }
  }
}

/// Defines priority levels for schedule entries and notes
enum SchedulePriority {
  veryImportant,
  semiImportant,
  leastImportant,
  optional,
  other,
}

/// Extension to get user-friendly labels and colors for schedule priority levels
extension SchedulePriorityLabel on SchedulePriority {
  /// Returns display label (e.g., 'Very Important', 'Optional')
  String get label {
    switch (this) {
      case SchedulePriority.veryImportant:
        return 'Very Important';
      case SchedulePriority.semiImportant:
        return 'Semi-Important';
      case SchedulePriority.leastImportant:
        return 'Least-Important';
      case SchedulePriority.optional:
        return 'Optional';
      case SchedulePriority.other:
        return 'Other';
    }
  }

  /// Returns color associated with this priority level
  Color get color {
    switch (this) {
      case SchedulePriority.veryImportant:
        return const Color(0xFFE11D48);
      case SchedulePriority.semiImportant:
        return const Color(0xFFF59E0B);
      case SchedulePriority.leastImportant:
        return const Color(0xFF22C55E);
      case SchedulePriority.optional:
        return const Color(0xFF6B7280);
      case SchedulePriority.other:
        return const Color(0xFF7C3AED);
    }
  }
}

/// Represents a single math question that appears on the alarm screen
/// Users must answer correctly to dismiss the alarm
class MathQuestion {
  const MathQuestion({required this.question, required this.answer});

  final String question;  // The math problem to display (e.g., "5 + 3 = ?")
  final int answer;       // The correct answer
}

/// Defines types of alarm sounds available
enum AlarmSoundKind { phoneFile }

/// Represents a selected alarm sound with its file path and display name
class AlarmSoundChoice {
  const AlarmSoundChoice._({
    required this.kind,
    required this.displayName,
    this.filePath,
  });

  /// Creates an alarm sound from a phone file
  const AlarmSoundChoice.phoneFile({
    required String displayName,
    required String filePath,
  }) : this._(
         kind: AlarmSoundKind.phoneFile,
         displayName: displayName,
         filePath: filePath,
       );

  final AlarmSoundKind kind;        // Type of sound
  final String displayName;         // Name shown to user
  final String? filePath;           // Path to the sound file

  /// Converts this sound choice to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'kind': kind.name,
      'displayName': displayName,
      'filePath': filePath,
    };
  }

  /// Creates a sound choice from stored JSON data
  factory AlarmSoundChoice.fromJson(Map<String, dynamic>? json) {
    final filePath = json?['filePath'] as String?;
    if (filePath != null && filePath.isNotEmpty) {
      return AlarmSoundChoice.phoneFile(
        displayName: json?['displayName'] as String? ?? fileNameFromPath(filePath),
        filePath: filePath,
      );
    }

    return const AlarmSoundChoice.phoneFile(
      displayName: 'Choose a sound',
      filePath: '',
    );
  }

  /// Converts this sound to an audio source for playback
  Source toAudioSource() {
    if (kind == AlarmSoundKind.phoneFile && filePath != null && filePath!.isNotEmpty) {
      return DeviceFileSource(filePath!);
    }

    throw StateError('A phone sound file must be selected before playback.');
  }
}

/// Represents a complete alarm configuration with all its settings
class AlarmEntry {
  const AlarmEntry({
    required this.id,
    required this.notificationId,
    required this.timeOfDay,
    required this.label,
    required this.repeatDays,
    required this.difficulty,
    required this.enabled,
    required this.sound,
  });

  final String id;                  // Unique identifier
  final int notificationId;         // ID for system notifications
  final TimeOfDay timeOfDay;        // Time when alarm should trigger
  final String label;               // User-given name (e.g., "Morning Workout")
  final List<bool> repeatDays;      // True for each day to repeat (7 days)
  final AlarmDifficulty difficulty; // Math difficulty to solve
  final bool enabled;               // Whether alarm is active
  final AlarmSoundChoice sound;     // Selected alarm sound

  /// Creates a modified copy of this alarm with selected fields changed
  AlarmEntry copyWith({
    String? id,
    int? notificationId,
    TimeOfDay? timeOfDay,
    String? label,
    List<bool>? repeatDays,
    AlarmDifficulty? difficulty,
    bool? enabled,
    AlarmSoundChoice? sound,
  }) {
    return AlarmEntry(
      id: id ?? this.id,
      notificationId: notificationId ?? this.notificationId,
      timeOfDay: timeOfDay ?? this.timeOfDay,
      label: label ?? this.label,
      repeatDays: repeatDays ?? this.repeatDays,
      difficulty: difficulty ?? this.difficulty,
      enabled: enabled ?? this.enabled,
      sound: sound ?? this.sound,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'notificationId': notificationId,
      'hour': timeOfDay.hour,
      'minute': timeOfDay.minute,
      'label': label,
      'repeatDays': repeatDays,
      'difficulty': difficulty.index,
      'enabled': enabled,
      'sound': sound.toJson(),
    };
  }

  /// Reconstructs an alarm from stored JSON data
  factory AlarmEntry.fromJson(Map<String, dynamic> json) {
    final repeatDays = (json['repeatDays'] as List<dynamic>? ?? const [])
        .map((day) => day == true)
        .toList(growable: false);
    final difficultyIndex = (json['difficulty'] as int?) ?? AlarmDifficulty.medium.index;
    final safeDifficultyIndex = difficultyIndex.clamp(0, AlarmDifficulty.values.length - 1);

    return AlarmEntry(
      id: json['id'] as String? ?? json['notificationId'].toString(),
      notificationId: json['notificationId'] as int? ?? int.parse(json['id'].toString()),
      timeOfDay: TimeOfDay(
        hour: (json['hour'] as int?) ?? 7,
        minute: (json['minute'] as int?) ?? 30,
      ),
      label: json['label'] as String? ?? '',
      repeatDays: repeatDays.length == 7 ? repeatDays : List<bool>.filled(7, false),
      difficulty: AlarmDifficulty.values[safeDifficultyIndex],
      enabled: json['enabled'] as bool? ?? true,
      sound: AlarmSoundChoice.fromJson(json['sound'] as Map<String, dynamic>?),
    );
  }
}

/// Represents a scheduled event (meeting, appointment, etc.)
class ScheduleEntry {
  const ScheduleEntry({
    required this.id,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.title,
    required this.description,
    required this.priority,
  });

  final String id;              // Unique identifier
  final DateTime date;          // Date of the schedule
  final TimeOfDay startTime;    // When it starts
  final TimeOfDay endTime;      // When it ends
  final String title;           // Event title
  final String description;     // Detailed description
  final SchedulePriority priority; // Importance level

  /// Creates a modified copy of this schedule entry
  ScheduleEntry copyWith({
    String? id,
    DateTime? date,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    String? title,
    String? description,
    SchedulePriority? priority,
  }) {
    return ScheduleEntry(
      id: id ?? this.id,
      date: date ?? this.date,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      title: title ?? this.title,
      description: description ?? this.description,
      priority: priority ?? this.priority,
    );
  }

  /// Converts this schedule entry to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'startHour': startTime.hour,
      'startMinute': startTime.minute,
      'endHour': endTime.hour,
      'endMinute': endTime.minute,
      'title': title,
      'description': description,
      'priority': priority.index,
    };
  }

  /// Reconstructs a schedule entry from stored JSON data
  factory ScheduleEntry.fromJson(Map<String, dynamic> json) {
    final priorityIndex = (json['priority'] as int?) ?? SchedulePriority.other.index;
    final safePriorityIndex = priorityIndex.clamp(0, SchedulePriority.values.length - 1);

    return ScheduleEntry(
      id: json['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
      date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
      startTime: TimeOfDay(
        hour: (json['startHour'] as int?) ?? 7,
        minute: (json['startMinute'] as int?) ?? 0,
      ),
      endTime: TimeOfDay(
        hour: (json['endHour'] as int?) ?? 9,
        minute: (json['endMinute'] as int?) ?? 0,
      ),
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      priority: SchedulePriority.values[safePriorityIndex],
    );
  }
}

/// Represents a quick note with priority and date
class NoteEntry {
  const NoteEntry({
    required this.id,
    required this.date,
    required this.title,
    required this.description,
    required this.priority,
  });

  final String id;              // Unique identifier
  final DateTime date;          // When note was created
  final String title;           // Note title
  final String description;     // Note content
  final SchedulePriority priority; // Importance level

  /// Creates a modified copy of this note
  NoteEntry copyWith({
    String? id,
    DateTime? date,
    String? title,
    String? description,
    SchedulePriority? priority,
  }) {
    return NoteEntry(
      id: id ?? this.id,
      date: date ?? this.date,
      title: title ?? this.title,
      description: description ?? this.description,
      priority: priority ?? this.priority,
    );
  }

  /// Converts this note to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'title': title,
      'description': description,
      'priority': priority.index,
    };
  }

  /// Reconstructs a note from stored JSON data
  factory NoteEntry.fromJson(Map<String, dynamic> json) {
    final priorityIndex = (json['priority'] as int?) ?? SchedulePriority.other.index;
    final safePriorityIndex = priorityIndex.clamp(0, SchedulePriority.values.length - 1);

    return NoteEntry(
      id: json['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
      date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      priority: SchedulePriority.values[safePriorityIndex],
    );
  }
}

/// Generates random math questions based on difficulty level
/// Used to create wake-up challenge questions
/// - count: Number of questions to generate (default 3)
/// - seed: Optional seed for reproducible questions (for testing)
List<MathQuestion> generateQuestions(
  AlarmDifficulty difficulty, {
  int count = 3,
  int? seed,
}) {
  final random = seed == null ? Random() : Random(seed);
  final questions = <MathQuestion>[];

  for (var index = 0; index < count; index++) {
    final a = _nextNumber(random, difficulty);
    final b = _nextNumber(random, difficulty);
    final c = _nextNumber(random, difficulty);
    final pattern = random.nextInt(3);
    String question;
    int answer;
    switch (difficulty) {
      case AlarmDifficulty.easy:
        if (pattern == 0) {
          question = '$a + $b = ?';
          answer = a + b;
        } else if (pattern == 1) {
          question = '$a - $b = ?';
          answer = a - b;
        } else {
          question = '$a x $b = ?';
          answer = a * b;
        }
        break;
      case AlarmDifficulty.medium:
        if (pattern == 0) {
          question = '($a x $b) + $c = ?';
          answer = (a * b) + c;
        } else if (pattern == 1) {
          question = '($a + $b) x $c = ?';
          answer = (a + b) * c;
        } else {
          question = '($a x $b) - $c = ?';
          answer = (a * b) - c;
        }
        break;
      case AlarmDifficulty.hard:
        if (pattern == 0) {
          question = '($a x $b) + ($b x $c) = ?';
          answer = (a * b) + (b * c);
        } else if (pattern == 1) {
          question = '($a + $b) x ($c - 1) = ?';
          answer = (a + b) * (c - 1);
        } else {
          question = '($a x $b) - ($c + $a) = ?';
          answer = (a * b) - (c + a);
        }
        break;
    }

    questions.add(MathQuestion(question: question, answer: answer));
  }

  return questions;
}

/// Helper function: generates a single random number based on difficulty
/// Easy: 2-9, Medium: 2-10, Hard: 2-20
int _nextNumber(Random random, AlarmDifficulty difficulty) {
  switch (difficulty) {
    case AlarmDifficulty.easy:
      return random.nextInt(8) + 2;
    case AlarmDifficulty.medium:
      return random.nextInt(9) + 2;
    case AlarmDifficulty.hard:
      return random.nextInt(10) + 2;
  }
}
