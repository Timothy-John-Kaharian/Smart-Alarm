import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/alarm_models.dart';
import 'services/alarm_notification_service.dart';
import 'services/alarm_storage.dart';
import 'theme/app_theme.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
String? _queuedAlarmPayload;
bool _isOpeningAlarmScreen = false;

Future<void> _openAlarmScreenForPayload(String payload) async {
  if (_isOpeningAlarmScreen) {
    _queuedAlarmPayload = payload;
    return;
  }

  final navigator = navigatorKey.currentState;
  if (navigator == null || !navigator.mounted) {
    _queuedAlarmPayload = payload;
    return;
  }

  try {
    final alarms = await AlarmStorage.instance.loadAlarms();
    final matched = alarms.where((alarm) => alarm.id == payload).toList();
    if (matched.isEmpty) {
      return;
    }

    _isOpeningAlarmScreen = true;
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => AlarmRingingScreen(alarm: matched.first),
      ),
    );
  } catch (error) {
    debugPrint('Opening alarm screen failed: $error');
    _queuedAlarmPayload = payload;
  } finally {
    _isOpeningAlarmScreen = false;
  }
}

Future<void> _flushQueuedAlarmScreen() async {
  final payload = _queuedAlarmPayload;
  if (payload == null) {
    return;
  }

  _queuedAlarmPayload = null;
  await _openAlarmScreenForPayload(payload);
}

Future<void> main() async {
  // Initialize services before the UI starts.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AlarmApp());

  // Do plugin setup in background so startup never blocks first frame.
  AlarmNotificationService.instance.initialize(
    onAlarmTriggered: _openAlarmScreenForPayload,
  ).catchError((
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint('Alarm initialization failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  });

  // Also set up native alarm receive channel handler so native code can notify Flutter directly.
  const receiveChannel = MethodChannel('alarm_app/receive');
  receiveChannel.setMethodCallHandler((call) async {
    if (call.method == 'alarmTrigger') {
      final payload = call.arguments as String?;
      if (payload != null) {
        await _openAlarmScreenForPayload(payload);
      }
    }
  });

  // Ask native side if there was a pending alarm payload that arrived
  // before Dart registered the receive handler (race on cold start).
  try {
    final settingsChannel = const MethodChannel('alarm_app/settings');
    final pending = await settingsChannel.invokeMethod<String?>(
      'fetchPendingAlarmPayload',
    );
    if (pending != null) {
      _queuedAlarmPayload = pending;
    }
  } catch (e) {
    debugPrint('fetchPendingAlarmPayload failed: $e');
  }
}

class AlarmApp extends StatefulWidget {
  const AlarmApp({super.key});

  @override
  State<AlarmApp> createState() => _AlarmAppState();
}

class _AlarmAppState extends State<AlarmApp> {
  Color _seedColor = const Color(0xFF5B33F5);

  @override
  void initState() {
    super.initState();
    _loadThemePreferences();
  }

  Future<void> _loadThemePreferences() async {
    final preferences = await SharedPreferences.getInstance();
    final seedValue =
        preferences.getInt('theme_seed_color') ?? _seedColor.toARGB32();

    if (!mounted) return;
    setState(() {
      _seedColor = Color(seedValue);
    });
  }

  Future<void> _updateSeedColor(Color color) async {
    setState(() {
      _seedColor = color;
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('theme_seed_color', color.toARGB32());
  }

  ThemeData _buildTheme(Brightness brightness) {
    return buildAlarmTheme(_seedColor, brightness);
  }

  @override
  Widget build(BuildContext context) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      title: 'Smart Alarm',
      theme: _buildTheme(Brightness.light),
      home: AlarmShell(
        seedColor: _seedColor,
        onSeedColorChanged: _updateSeedColor,
      ),
    );
  }
}

class AlarmShell extends StatefulWidget {
  const AlarmShell({
    super.key,
    required this.seedColor,
    required this.onSeedColorChanged,
  });

  final Color seedColor;
  final ValueChanged<Color> onSeedColorChanged;

  @override
  State<AlarmShell> createState() => _AlarmShellState();
}

class _AlarmShellState extends State<AlarmShell> {
  int _selectedTab = 2;
  bool _loading = true;
  final List<AlarmEntry> _alarms = [];
  bool? _notificationPermissionGranted;
  bool? _exactAlarmPermissionGranted;
  int _contentRefreshToken = 0;

  @override
  void initState() {
    super.initState();
    _loadAlarms();
    _loadPermissionStatus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushQueuedAlarmScreen();
    });
  }

  bool get _settingsNeedsAttention =>
      _notificationPermissionGranted != true ||
      _exactAlarmPermissionGranted != true;

  void _notifyContentChanged() {
    if (!mounted) {
      return;
    }

    setState(() {
      _contentRefreshToken++;
    });
  }

  Future<void> _loadAlarms() async {
    // Load alarms from storage and restore background schedules.
    final loadedAlarms = await AlarmStorage.instance.loadAlarms();
    await AlarmNotificationService.instance.rescheduleAll(loadedAlarms);

    if (!mounted) {
      return;
    }

    setState(() {
      _alarms
        ..clear()
        ..addAll(loadedAlarms);
      _loading = false;
    });
  }

  Future<void> _loadPermissionStatus() async {
    final notificationPermission =
        await AlarmNotificationService.instance.areNotificationsEnabled();
    final exactAlarmPermission =
        await AlarmNotificationService.instance.canScheduleExactNotifications();

    if (!mounted) {
      return;
    }

    setState(() {
      _notificationPermissionGranted = notificationPermission;
      _exactAlarmPermissionGranted = exactAlarmPermission;
    });
  }

  Future<void> _saveAlarms() async {
    // Keep storage in sync with in-memory state.
    await AlarmStorage.instance.saveAlarms(_alarms);
  }

  Future<void> _openCreateAlarm() async {
    // Open the editor and wait for the new alarm object.
    final created = await Navigator.of(context).push<AlarmEntry>(
      MaterialPageRoute(builder: (_) => const AlarmEditorScreen()),
    );

    if (created == null) {
      return;
    }

    setState(() {
      _alarms.insert(0, created);
      _selectedTab = 3;
    });

    // Schedule it in the OS and persist the updated list.
    await AlarmNotificationService.instance.scheduleAlarm(created);
    await _saveAlarms();
  }

  Future<void> _openEditAlarm(AlarmEntry alarm) async {
    // Reuse the same editor with existing alarm values.
    final updated = await Navigator.of(context).push<AlarmEntry>(
      MaterialPageRoute(builder: (_) => AlarmEditorScreen(initialAlarm: alarm)),
    );

    if (updated == null) {
      return;
    }

    setState(() {
      final index = _alarms.indexWhere((entry) => entry.id == updated.id);
      if (index >= 0) {
        _alarms[index] = updated;
      }
    });

    // Re-schedule in case time, days, label, or enabled state changed.
    await AlarmNotificationService.instance.scheduleAlarm(updated);
    await _saveAlarms();
  }

  Future<void> _deleteAlarm(String id) async {
    // Look up the matching alarm first so we can cancel all its weekday notifications.
    final alarmToRemove = _alarms.cast<AlarmEntry?>().firstWhere(
      (alarm) => alarm?.id == id,
      orElse: () => null,
    );
    if (alarmToRemove != null) {
      await AlarmNotificationService.instance.cancelAlarm(alarmToRemove);
    }

    setState(() {
      _alarms.removeWhere((alarm) => alarm.id == id);
    });

    await _saveAlarms();
  }

  Future<void> _toggleAlarm(String id, bool enabled) async {
    // Update the switch state in memory immediately for quick UI response.
    setState(() {
      final index = _alarms.indexWhere((alarm) => alarm.id == id);
      if (index >= 0) {
        _alarms[index] = _alarms[index].copyWith(enabled: enabled);
      }
    });

    final updatedAlarm = _alarms.firstWhere((alarm) => alarm.id == id);
    if (enabled) {
      await AlarmNotificationService.instance.scheduleAlarm(updatedAlarm);
    } else {
      await AlarmNotificationService.instance.cancelAlarm(updatedAlarm);
    }

    await _saveAlarms();
  }

  Future<void> _testAlarm(AlarmEntry alarm) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AlarmRingingScreen(alarm: alarm)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }
    final pages = [
      ScheduleScreen(onContentChanged: _notifyContentChanged),
      NotesScreen(onContentChanged: _notifyContentChanged),
      HomeScreen(
        alarms: _alarms,
        refreshToken: _contentRefreshToken,
      ),
      AlarmListScreen(
        alarms: _alarms,
        onAddAlarm: _openCreateAlarm,
        onEditAlarm: _openEditAlarm,
        onDeleteAlarm: _deleteAlarm,
        onToggleAlarm: _toggleAlarm,
        onTestAlarm: _testAlarm,
      ),
      SettingsScreen(
        seedColor: widget.seedColor,
        notificationPermissionGranted: _notificationPermissionGranted,
        exactAlarmPermissionGranted: _exactAlarmPermissionGranted,
        onSeedColorChanged: widget.onSeedColorChanged,
        onRefreshPermissions: _loadPermissionStatus,
      ),
    ];

    return Scaffold(
      body: IndexedStack(index: _selectedTab, children: pages),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: _BottomTabButton(
                        icon: Icons.calendar_month,
                        label: 'Calendar',
                        selected: _selectedTab == 0,
                        onTap: () => setState(() => _selectedTab = 0),
                      ),
                    ),
                    Expanded(
                      child: _BottomTabButton(
                        icon: Icons.sticky_note_2_outlined,
                        label: 'Notes',
                        selected: _selectedTab == 1,
                        onTap: () => setState(() => _selectedTab = 1),
                      ),
                    ),
                    Expanded(
                      child: _BottomTabButton(
                        icon: Icons.home_outlined,
                        label: 'Home',
                        selected: _selectedTab == 2,
                        onTap: () => setState(() => _selectedTab = 2),
                      ),
                    ),
                    Expanded(
                      child: _BottomTabButton(
                        icon: Icons.alarm_outlined,
                        label: 'Alarm',
                        selected: _selectedTab == 3,
                        onTap: () => setState(() => _selectedTab = 3),
                      ),
                    ),
                    Expanded(
                      child: _BottomTabButton(
                        icon: Icons.settings_outlined,
                        label: 'Settings',
                        selected: _selectedTab == 4,
                        hasAttention: _settingsNeedsAttention,
                        onTap: () => setState(() => _selectedTab = 4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomTabButton extends StatelessWidget {
  const _BottomTabButton({
    required this.icon,
    required this.label,
    required this.selected,
    this.hasAttention = false,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool hasAttention;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foregroundColor = selected
      ? colorScheme.onSurface
      : hasAttention
        ? colorScheme.error
        : colorScheme.onSurface;
    final backgroundColor = selected ? colorScheme.primaryContainer : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: double.infinity,
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.zero,
          border: Border.symmetric(
            vertical: BorderSide(
              color: selected ? colorScheme.primary.withValues(alpha: 0.12) : Colors.transparent,
              width: 1,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, color: foregroundColor, size: 24),
                if (hasAttention)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                          color: Color(0xFFE11D48),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: foregroundColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AlarmListScreen extends StatelessWidget {
  const AlarmListScreen({
    super.key,
    required this.alarms,
    required this.onAddAlarm,
    required this.onEditAlarm,
    required this.onDeleteAlarm,
    required this.onToggleAlarm,
    required this.onTestAlarm,
  });

  final List<AlarmEntry> alarms;
  final VoidCallback onAddAlarm;
  final ValueChanged<AlarmEntry> onEditAlarm;
  final ValueChanged<String> onDeleteAlarm;
  final void Function(String id, bool enabled) onToggleAlarm;
  final ValueChanged<AlarmEntry> onTestAlarm;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF8738F2), Color(0xFF5B33F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.notifications_none,
                      color: Theme.of(context).colorScheme.surface,
                      size: 30,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Smart Alarm',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.alarm, color: Colors.white, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      'Complete tasks to turn off alarms!',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${alarms.where((alarm) => alarm.enabled).length} Alarms Active',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.84),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: alarms.isEmpty
                ? _EmptyAlarmState(onAddAlarm: onAddAlarm)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 102),
                    itemBuilder: (context, index) {
                      final alarm = alarms[index];
                      return AlarmCard(
                        alarm: alarm,
                        onChanged: (value) => onToggleAlarm(alarm.id, value),
                        onEdit: () => onEditAlarm(alarm),
                        onDelete: () => onDeleteAlarm(alarm.id),
                        onTest: () => onTestAlarm(alarm),
                      );
                    },
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemCount: alarms.length,
                  ),
          ),
          if (alarms.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: onAddAlarm,
                  child: const Text('Add New Alarm'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyAlarmState extends StatelessWidget {
  const _EmptyAlarmState({required this.onAddAlarm});

  final VoidCallback onAddAlarm;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 26),
                    blurRadius: 30,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(
                Icons.notifications_none,
                size: 36,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No Alarms Yet!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Create your alarm first',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 179)),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: onAddAlarm,
              child: const Text('Add New Alarm'),
            ),
          ],
        ),
      ),
    );
  }
}

class AlarmCard extends StatelessWidget {
  const AlarmCard({
    super.key,
    required this.alarm,
    required this.onChanged,
    required this.onEdit,
    required this.onDelete,
    required this.onTest,
  });

  final AlarmEntry alarm;
  final ValueChanged<bool> onChanged;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final time = _formatAlarmTime(alarm.timeOfDay);
    final days = const ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            time.hour,
                            style: const TextStyle(
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                              height: 0.92,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            ':${time.minute}',
                            style: const TextStyle(
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                              height: 0.92,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            time.period,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF868B9A),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        alarm.label,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFF2F3140),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: alarm.enabled,
                  onChanged: onChanged,
                  activeThumbColor: const Color(0xFF6B50E8),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var index = 0; index < days.length; index++)
                  _DayPill(
                    label: days[index],
                    selected: alarm.repeatDays[index],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _DifficultyChip(alarm.difficulty),
                  _SoundChip(alarm.sound),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton(onPressed: onTest, child: const Text('Test Alarm')),
                const Spacer(),
                _ActionIconButton(icon: Icons.edit_outlined, onTap: onEdit),
                const SizedBox(width: 8),
                _ActionIconButton(
                  icon: Icons.delete_outline,
                  onTap: onDelete,
                  destructive: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionIconButton extends StatelessWidget {
  const _ActionIconButton({
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: destructive
              ? const Color(0xFFFFF0F0)
              : const Color(0xFFF4F5F8),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          color: destructive
              ? const Color(0xFFE11D48)
              : const Color(0xFF4E5260),
          size: 18,
        ),
      ),
    );
  }
}

class _DayPill extends StatelessWidget {
  const _DayPill({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: selected ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _DifficultyChip extends StatelessWidget {
  const _DifficultyChip(this.difficulty);

  final AlarmDifficulty difficulty;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: difficulty.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Math - ${difficulty.label}',
        style: TextStyle(
          color: difficulty.color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SoundChip extends StatelessWidget {
  const _SoundChip(this.sound);

  final AlarmSoundChoice sound;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2F3140).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Sound - ${sound.displayName}',
        style: const TextStyle(
          color: Color(0xFF2F3140),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.alarms,
    required this.refreshToken,
  });

  final List<AlarmEntry> alarms;
  final int refreshToken;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loading = true;
  final List<ScheduleEntry> _schedules = [];
  final List<NoteEntry> _notes = [];

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshToken != widget.refreshToken) {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    final schedules = await ScheduleStorage.instance.loadSchedules();
    final notes = await NoteStorage.instance.loadNotes();

    if (!mounted) return;

    setState(() {
      _schedules
        ..clear()
        ..addAll(schedules);
      _notes
        ..clear()
        ..addAll(notes);
      _loading = false;
    });
  }

  int _dayIndexFor(DateTime date) =>
      date.weekday == DateTime.sunday ? 0 : date.weekday;

  List<ScheduleEntry> _getTodaysSchedules() {
    final today = DateUtils.dateOnly(DateTime.now());
    return _schedules
        .where((schedule) => DateUtils.isSameDay(schedule.date, today))
        .toList()
        ..sort((a, b) {
          final aMinutes = a.startTime.hour * 60 + a.startTime.minute;
          final bMinutes = b.startTime.hour * 60 + b.startTime.minute;
          return aMinutes.compareTo(bMinutes);
        });
  }

  List<NoteEntry> _getTodaysNotes() {
    final today = DateUtils.dateOnly(DateTime.now());
    return _notes
        .where((note) => DateUtils.isSameDay(note.date, today))
        .toList()
        ..sort((a, b) => a.priority.index.compareTo(b.priority.index));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    final now = DateTime.now();
    final dayIndex = _dayIndexFor(now);
    final todaysAlarms =
        widget.alarms.where((a) => a.repeatDays[dayIndex]).toList();
    final todaysSchedules = _getTodaysSchedules();
    final todaysNotes = _getTodaysNotes();

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF8738F2), Color(0xFF5B33F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.home_outlined, color: Colors.white, size: 30),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Home',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${now.day} ${_months[now.month - 1]} ${now.year}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.84),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Schedule Section
                  Text(
                    'Today\'s Schedule',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (todaysSchedules.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        'No schedule for today',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 179),
                        ),
                      ),
                    )
                  else
                    Column(
                      children: todaysSchedules.map((schedule) {
                        final priorityColor = schedule.priority.color;
                        final startTime =
                            '${schedule.startTime.hour.toString().padLeft(2, '0')}:${schedule.startTime.minute.toString().padLeft(2, '0')}';
                        final endTime =
                            '${schedule.endTime.hour.toString().padLeft(2, '0')}:${schedule.endTime.minute.toString().padLeft(2, '0')}';

                        return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: priorityColor.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: priorityColor.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: priorityColor,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.schedule_outlined,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            schedule.title,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: priorityColor.withValues(
                                              alpha: 0.18,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            schedule.priority.label,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: priorityColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '$startTime - $endTime',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF515767),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 18),

                  // Notes Section
                  Text(
                    'Today\'s Notes',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (todaysNotes.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        'No notes for today',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 179),
                        ),
                      ),
                    )
                  else
                    Column(
                      children: todaysNotes.map((note) {
                        final priorityColor = note.priority.color;

                        return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: priorityColor.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: priorityColor.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: priorityColor,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(
                                  Icons.sticky_note_2_outlined,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            note.title,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: priorityColor.withValues(
                                              alpha: 0.18,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            note.priority.label,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: priorityColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      note.description,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF515767),
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 18),

                  // Alarms Section
                  Text(
                    'Today\'s Alarms',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (todaysAlarms.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        'No alarms for today',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 179),
                        ),
                      ),
                    )
                  else
                    Column(
                      children: todaysAlarms.map((alarm) {
                        final time = _formatAlarmTime(alarm.timeOfDay);
                        final days = const ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
                        final isEnabled = alarm.enabled;

                        return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isEnabled
                                ? Colors.white
                                : const Color(0xFFF6F7FB),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: isEnabled
                                  ? Colors.transparent
                                  : const Color(0xFFE3E6F2),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          time.hour,
                                          style: const TextStyle(
                                            fontSize: 34,
                                            fontWeight: FontWeight.w800,
                                            height: 0.95,
                                          ),
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          ':${time.minute}',
                                          style: const TextStyle(
                                            fontSize: 34,
                                            fontWeight: FontWeight.w800,
                                            height: 0.95,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          time.period,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF868B9A),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Container(
                                      width: 44,
                                      height: 26,
                                      decoration: BoxDecoration(
                                        color: isEnabled
                                            ? Theme.of(context).colorScheme.primaryContainer
                                            : Theme.of(context).colorScheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: Align(
                                        alignment: isEnabled
                                            ? Alignment.centerRight
                                            : Alignment.centerLeft,
                                        child: Container(
                                          width: 20,
                                          height: 20,
                                          margin: const EdgeInsets.all(3),
                                          decoration: BoxDecoration(
                                            color: isEnabled
                                                ? Theme.of(context).colorScheme.primary
                                                : Theme.of(context).colorScheme.onSurface,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      alarm.label,
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: isEnabled
                                            ? const Color(0xFF2F3140)
                                            : const Color(0xFF8A90A3),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  if (!isEnabled)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE5E7F0),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: const Text(
                                        'Off',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF6C7285),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (
                                    var index = 0;
                                    index < days.length;
                                    index++
                                  )
                                    _DayPill(
                                      label: days[index],
                                      selected: alarm.repeatDays[index],
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _DifficultyChip(alarm.difficulty),
                                  _SoundChip(alarm.sound),
                                ],
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({
    super.key,
    required this.alarms,
    required this.onAddAlarm,
    required this.onEditAlarm,
  });

  final List<AlarmEntry> alarms;
  final VoidCallback onAddAlarm;
  final ValueChanged<AlarmEntry> onEditAlarm;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _displayMonth = DateTime.now();
  DateTime _selectedDate = DateTime.now();

  void _prevMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + 1, 1);
    });
  }

  int _dayIndexFor(DateTime date) =>
      date.weekday == DateTime.sunday ? 0 : date.weekday;

  @override
  Widget build(BuildContext context) {
    final firstDayOfMonth = DateTime(
      _displayMonth.year,
      _displayMonth.month,
      1,
    );
    final offset = firstDayOfMonth.weekday % 7; // Sunday-first
    final daysInMonth = DateTime(
      _displayMonth.year,
      _displayMonth.month + 1,
      0,
    ).day;

    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final selectedDateLabel =
        '${_selectedDate.day} ${months[_selectedDate.month - 1]} ${_selectedDate.year}';
    final selectedDayIndex = _dayIndexFor(_selectedDate);
    final selectedAlarms = widget.alarms
        .where((alarm) => alarm.repeatDays[selectedDayIndex])
        .toList();

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF8738F2), Color(0xFF5B33F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.calendar_month_outlined,
                  color: Colors.white,
                  size: 30,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Calendar',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 5),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconButton(
                              onPressed: _prevMonth,
                              icon: const Icon(Icons.chevron_left),
                            ),
                            Expanded(
                              child: Center(
                                child: Text(
                                  '${months[_displayMonth.month - 1]} ${_displayMonth.year}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: _nextMonth,
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: const [
                            Text(
                              'Su',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF848A9B),
                              ),
                            ),
                            Text(
                              'Mo',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF848A9B),
                              ),
                            ),
                            Text(
                              'Tu',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF848A9B),
                              ),
                            ),
                            Text(
                              'We',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF848A9B),
                              ),
                            ),
                            Text(
                              'Th',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF848A9B),
                              ),
                            ),
                            Text(
                              'Fr',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF848A9B),
                              ),
                            ),
                            Text(
                              'Sa',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF848A9B),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (var week = 0; week < 6; week++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              children: List.generate(7, (dayIdx) {
                                final index = week * 7 + dayIdx;
                                final dayNumber = index - offset + 1;
                                if (dayNumber < 1 || dayNumber > daysInMonth) {
                                  return const Expanded(
                                    child: SizedBox(height: 42),
                                  );
                                }

                                final date = DateTime(
                                  _displayMonth.year,
                                  _displayMonth.month,
                                  dayNumber,
                                );
                                final isSelected =
                                    date.year == _selectedDate.year &&
                                    date.month == _selectedDate.month &&
                                    date.day == _selectedDate.day;
                                final isToday =
                                    date.year == DateTime.now().year &&
                                    date.month == DateTime.now().month &&
                                    date.day == DateTime.now().day;
                                final dayIndex = _dayIndexFor(date);
                                final hasEvent = widget.alarms.any(
                                  (a) => a.repeatDays[dayIndex],
                                );
                                final tileColor = isSelected
                                    ? const Color(0xFF5B33F5)
                                    : hasEvent
                                    ? const Color(0xFFEAE4FF)
                                    : isToday
                                    ? const Color(0xFFF2EFFF)
                                    : Colors.transparent;

                                return Expanded(
                                  child: GestureDetector(
                                    onTap: () =>
                                        setState(() => _selectedDate = date),
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      height: 42,
                                      decoration: BoxDecoration(
                                        color: tileColor,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        dayNumber.toString(),
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: isSelected
                                              ? Colors.white
                                              : hasEvent
                                              ? const Color(0xFF3D2A8C)
                                              : const Color(0xFF2F3140),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Schedule',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 230),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Reminders for $selectedDateLabel',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6C7285),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (selectedAlarms.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text('No reminders for this date.'),
                    )
                  else
                    Column(
                      children: selectedAlarms.map((alarm) {
                        final time = _formatAlarmTime(alarm.timeOfDay);
                        return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: alarm.enabled
                                ? Colors.white
                                : const Color(0xFFF6F7FB),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: alarm.enabled
                                  ? const Color(0xFFE9EAF1)
                                  : const Color(0xFFE3E6F2),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: alarm.enabled
                                      ? const Color(0xFFE42E63)
                                      : const Color(0xFFD8DCE8),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  Icons.alarm,
                                  color: alarm.enabled
                                      ? Colors.white
                                      : const Color(0xFF8A90A3),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      alarm.label.isEmpty
                                          ? 'Alarm'
                                          : alarm.label,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: alarm.enabled
                                            ? const Color(0xFF2F3140)
                                            : const Color(0xFF8A90A3),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${time.hour}:${time.minute} ${time.period}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF6C7285),
                                      ),
                                    ),
                                    if (!alarm.enabled) ...[
                                      const SizedBox(height: 4),
                                      const Text(
                                        'Off',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFFE11D48),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => widget.onEditAlarm(alarm),
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: 'Edit alarm',
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: widget.onAddAlarm,
                      child: const Text('Set schedule'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key, required this.onContentChanged});

  final VoidCallback onContentChanged;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  DateTime _displayMonth = DateTime.now();
  DateTime _selectedDate = DateUtils.dateOnly(DateTime.now());
  bool _loading = true;
  final List<ScheduleEntry> _schedules = [];
  TextEditingController? _searchController;
  String _query = '';
  SchedulePriority? _selectedPriority;

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _loadSchedules();
  }

  TextEditingController get _searchControllerResolved =>
      _searchController ??= TextEditingController();

  @override
  void dispose() {
    _searchController?.dispose();
    super.dispose();
  }

  Future<void> _loadSchedules() async {
    final loadedSchedules = await ScheduleStorage.instance.loadSchedules();
    if (!mounted) {
      return;
    }

    setState(() {
      _schedules
        ..clear()
        ..addAll(loadedSchedules);
      _loading = false;
    });
  }

  Future<void> _saveSchedules() async {
    await ScheduleStorage.instance.saveSchedules(_schedules);
    widget.onContentChanged();
  }

  Future<void> _openCreateSchedule() async {
    final created = await Navigator.of(context).push<ScheduleEntry>(
      MaterialPageRoute(builder: (_) => const ScheduleEditorScreen()),
    );

    if (created == null) {
      return;
    }

    setState(() {
      _schedules.insert(0, created);
      _selectedDate = DateUtils.dateOnly(created.date);
      _displayMonth = DateTime(created.date.year, created.date.month, 1);
    });

    await _saveSchedules();
  }

  Future<void> _openEditSchedule(ScheduleEntry schedule) async {
    final updated = await Navigator.of(context).push<ScheduleEntry>(
      MaterialPageRoute(
        builder: (_) => ScheduleEditorScreen(initialSchedule: schedule),
      ),
    );

    if (updated == null) {
      return;
    }

    setState(() {
      final index = _schedules.indexWhere((entry) => entry.id == updated.id);
      if (index >= 0) {
        _schedules[index] = updated;
      }
      _selectedDate = DateUtils.dateOnly(updated.date);
      _displayMonth = DateTime(updated.date.year, updated.date.month, 1);
    });

    await _saveSchedules();
  }

  Future<void> _deleteSchedule(String id) async {
    setState(() {
      _schedules.removeWhere((entry) => entry.id == id);
    });
    await _saveSchedules();
  }

  void _prevMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + 1, 1);
    });
  }

  List<ScheduleEntry> _selectedSchedules() {
    final selected = DateUtils.dateOnly(_selectedDate);
    final result = _schedules.where((schedule) {
      if (!DateUtils.isSameDay(schedule.date, selected)) {
        return false;
      }
      if (_selectedPriority != null && schedule.priority != _selectedPriority) {
        return false;
      }
      if (_query.isEmpty) {
        return true;
      }
      final lowercaseQuery = _query.toLowerCase();
      return schedule.title.toLowerCase().contains(lowercaseQuery) ||
          schedule.description.toLowerCase().contains(lowercaseQuery);
    }).toList();
    // Sort by priority (enum order: veryImportant first) then by start time
    result.sort((a, b) {
      final p = a.priority.index.compareTo(b.priority.index);
      if (p != 0) return p;
      final aMinutes = a.startTime.hour * 60 + a.startTime.minute;
      final bMinutes = b.startTime.hour * 60 + b.startTime.minute;
      return aMinutes.compareTo(bMinutes);
    });
    return result;
  }

  void _togglePriorityFilter(SchedulePriority? priority) {
    setState(() {
      if (_selectedPriority == priority) {
        _selectedPriority = null;
      } else {
        _selectedPriority = priority;
      }
    });
  }

  Widget _buildPriorityDropdown() {
    return DropdownButtonFormField<SchedulePriority?>(
      initialValue: _selectedPriority,
      isExpanded: true,
      decoration: InputDecoration(
        filled: true,
        fillColor: Theme.of(context).colorScheme.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Theme.of(context).dividerColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      dropdownColor: Theme.of(context).colorScheme.surface,
      items: [
        _priorityDropdownItem(null, 'All', Theme.of(context).colorScheme.primary),
        ...SchedulePriority.values.map(
          (priority) => _priorityDropdownItem(
            priority,
            priority.label,
            priority.color,
          ),
        ),
      ],
      onChanged: _togglePriorityFilter,
      selectedItemBuilder: (context) {
        return [
          _prioritySelectedItem(null, 'All', Theme.of(context).colorScheme.primary),
          ...SchedulePriority.values.map(
            (priority) => _prioritySelectedItem(
              priority,
              priority.label,
              priority.color,
            ),
          ),
        ];
      },
    );
  }

  DropdownMenuItem<SchedulePriority?> _priorityDropdownItem(
    SchedulePriority? priority,
    String label,
    Color color,
  ) {
    return DropdownMenuItem<SchedulePriority?>(
      value: priority,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _prioritySelectedItem(
    SchedulePriority? priority,
    String label,
    Color color,
  ) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    final firstDayOfMonth = DateTime(
      _displayMonth.year,
      _displayMonth.month,
      1,
    );
    final offset = firstDayOfMonth.weekday % 7;
    final daysInMonth = DateTime(
      _displayMonth.year,
      _displayMonth.month + 1,
      0,
    ).day;
    final selectedSchedules = _selectedSchedules();
    final selectedDateLabel =
        '${_selectedDate.day} ${_months[_selectedDate.month - 1]} ${_selectedDate.year}';
    final scheduleCount = selectedSchedules.length;
    final scheduleSubtitle = DateUtils.isSameDay(_selectedDate, DateTime.now())
        ? (scheduleCount == 1
              ? '1 schedule today'
              : '$scheduleCount schedules today')
        : (scheduleCount == 1
              ? '1 schedule on $selectedDateLabel'
              : '$scheduleCount schedules on $selectedDateLabel');

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF8738F2), Color(0xFF5B33F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.schedule_outlined,
                  color: Colors.white,
                  size: 30,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Schedule',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        scheduleSubtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.84),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SearchFilterField(
                  controller: _searchControllerResolved,
                  hintText: 'Search schedules',
                  onChanged: (value) => setState(() => _query = value),
                  onClear: () => setState(() {
                    _query = '';
                    _searchControllerResolved.clear();
                  }),
                ),
                const SizedBox(height: 12),
                _buildPriorityDropdown(),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 104),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4FF),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Select Date:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: Theme.of(context).dividerColor),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  IconButton(
                                    onPressed: _prevMonth,
                                    icon: const Icon(Icons.chevron_left),
                                  ),
                                  DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: _months[_displayMonth.month - 1],
                                      items: _months
                                          .map(
                                            (month) => DropdownMenuItem(
                                              value: month,
                                              child: Text(month),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (value) {
                                        if (value == null) return;
                                        final monthIndex =
                                            _months.indexOf(value) + 1;
                                        setState(() {
                                          _displayMonth = DateTime(
                                            _displayMonth.year,
                                            monthIndex,
                                            1,
                                          );
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  DropdownButtonHideUnderline(
                                    child: DropdownButton<int>(
                                      value: _displayMonth.year,
                                      items:
                                          List.generate(
                                                11,
                                                (index) => 2020 + index,
                                              )
                                              .map(
                                                (year) => DropdownMenuItem(
                                                  value: year,
                                                  child: Text(year.toString()),
                                                ),
                                              )
                                              .toList(),
                                      onChanged: (value) {
                                        if (value == null) return;
                                        setState(() {
                                          _displayMonth = DateTime(
                                            value,
                                            _displayMonth.month,
                                            1,
                                          );
                                        });
                                      },
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    onPressed: _nextMonth,
                                    icon: const Icon(Icons.chevron_right),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: const [
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Su',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Mo',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Tu',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'We',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Th',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Fr',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Sa',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              for (var week = 0; week < 6; week++)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    children: List.generate(7, (dayIdx) {
                                      final index = week * 7 + dayIdx;
                                      final dayNumber = index - offset + 1;
                                      if (dayNumber < 1 ||
                                          dayNumber > daysInMonth) {
                                        return const Expanded(
                                          child: SizedBox(height: 42),
                                        );
                                      }

                                      final date = DateTime(
                                        _displayMonth.year,
                                        _displayMonth.month,
                                        dayNumber,
                                      );
                                      final isSelected = DateUtils.isSameDay(
                                        date,
                                        _selectedDate,
                                      );
                                      final isToday = DateUtils.isSameDay(
                                        date,
                                        DateTime.now(),
                                      );
                                      final hasEvent = _schedules.any(
                                        (schedule) => DateUtils.isSameDay(
                                          schedule.date,
                                          date,
                                        ),
                                      );
                                      final tileColor = isSelected
                                          ? const Color(0xFF5B33F5)
                                          : hasEvent
                                          ? const Color(0xFFEAE4FF)
                                          : isToday
                                          ? const Color(0xFFF2EFFF)
                                          : Colors.transparent;

                                      return Expanded(
                                        child: GestureDetector(
                                          onTap: () => setState(
                                            () => _selectedDate = date,
                                          ),
                                          child: Container(
                                            margin: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                            ),
                                            height: 42,
                                            decoration: BoxDecoration(
                                              color: tileColor,
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            alignment: Alignment.center,
                                            child: Text(
                                              dayNumber.toString(),
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: isSelected
                                                    ? Colors.white
                                                    : hasEvent
                                                    ? const Color(0xFF3D2A8C)
                                                    : const Color(0xFF2F3140),
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Schedule',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 230),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Reminders for $selectedDateLabel',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6C7285),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (selectedSchedules.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text('No notes or schedules for this date.'),
                    )
                  else
                    Column(
                      children: selectedSchedules.map((schedule) {
                        final start = _formatAlarmTime(schedule.startTime);
                        final end = _formatAlarmTime(schedule.endTime);
                        final priorityColor = schedule.priority.color;

                        return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: priorityColor.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: priorityColor.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: priorityColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.event_note,
                                  color: Colors.white,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            schedule.title,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: priorityColor.withValues(
                                              alpha: 0.18,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            schedule.priority.label,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: priorityColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${start.hour}:${start.minute} ${start.period} - ${end.hour}:${end.minute} ${end.period}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF2F3140),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      schedule.description,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF515767),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => _openEditSchedule(schedule),
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: 'Edit schedule',
                              ),
                              IconButton(
                                onPressed: () => _deleteSchedule(schedule.id),
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Delete schedule',
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _openCreateSchedule,
                child: const Text('Add schedule'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.onContentChanged});

  final VoidCallback onContentChanged;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  DateTime _displayMonth = DateTime.now();
  DateTime _selectedDate = DateUtils.dateOnly(DateTime.now());
  bool _loading = true;
  final List<NoteEntry> _notes = [];
  TextEditingController? _searchController;
  String _query = '';
  SchedulePriority? _selectedPriority;

  static const List<String> _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  TextEditingController get _searchControllerResolved =>
      _searchController ??= TextEditingController();

  @override
  void dispose() {
    _searchController?.dispose();
    super.dispose();
  }

  Future<void> _loadNotes() async {
    final loadedNotes = await NoteStorage.instance.loadNotes();
    if (!mounted) return;

    setState(() {
      _notes
        ..clear()
        ..addAll(loadedNotes);
      _loading = false;
    });
  }

  Future<void> _saveNotes() async {
    await NoteStorage.instance.saveNotes(_notes);
    widget.onContentChanged();
  }

  Future<void> _openCreateNote() async {
    final created = await Navigator.of(context).push<NoteEntry>(
      MaterialPageRoute(
        builder: (_) => NoteEditorScreen(initialDate: _selectedDate),
      ),
    );

    if (created == null) {
      return;
    }

    setState(() {
      _notes.insert(0, created);
      _selectedDate = DateUtils.dateOnly(created.date);
    });

    await _saveNotes();
  }

  Future<void> _openEditNote(NoteEntry note) async {
    final updated = await Navigator.of(context).push<NoteEntry>(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(initialNote: note)),
    );

    if (updated == null) {
      return;
    }

    setState(() {
      final index = _notes.indexWhere((entry) => entry.id == updated.id);
      if (index >= 0) {
        _notes[index] = updated;
      }
      _selectedDate = DateUtils.dateOnly(updated.date);
    });

    await _saveNotes();
  }

  Future<void> _deleteNote(String id) async {
    setState(() {
      _notes.removeWhere((entry) => entry.id == id);
    });
    await _saveNotes();
  }

  void _prevMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + 1, 1);
    });
  }

  List<NoteEntry> _selectedNotes() {
    final selected = DateUtils.dateOnly(_selectedDate);
    final result = _notes.where((note) {
      if (!DateUtils.isSameDay(note.date, selected)) {
        return false;
      }
      if (_selectedPriority != null && note.priority != _selectedPriority) {
        return false;
      }
      if (_query.isEmpty) {
        return true;
      }
      final lowercaseQuery = _query.toLowerCase();
      return note.title.toLowerCase().contains(lowercaseQuery) ||
          note.description.toLowerCase().contains(lowercaseQuery);
    }).toList();

    result.sort((a, b) {
      final p = a.priority.index.compareTo(b.priority.index);
      if (p != 0) return p;
      return a.title.compareTo(b.title);
    });
    return result;
  }

  void _togglePriorityFilter(SchedulePriority? priority) {
    setState(() {
      if (_selectedPriority == priority) {
        _selectedPriority = null;
      } else {
        _selectedPriority = priority;
      }
    });
  }

  Widget _buildPriorityDropdown() {
    return DropdownButtonFormField<SchedulePriority?>(
      initialValue: _selectedPriority,
      isExpanded: true,
      decoration: InputDecoration(
        filled: true,
        fillColor: const Color(0xFFF7F8FC),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Theme.of(context).dividerColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      dropdownColor: Colors.white,
      items: [
        _priorityDropdownItem(null, 'All', Theme.of(context).colorScheme.primary),
        ...SchedulePriority.values.map(
          (priority) => _priorityDropdownItem(
            priority,
            priority.label,
            priority.color,
          ),
        ),
      ],
      onChanged: _togglePriorityFilter,
      selectedItemBuilder: (context) {
        return [
          _prioritySelectedItem(null, 'All', Theme.of(context).colorScheme.primary),
          ...SchedulePriority.values.map(
            (priority) => _prioritySelectedItem(
              priority,
              priority.label,
              priority.color,
            ),
          ),
        ];
      },
    );
  }

  DropdownMenuItem<SchedulePriority?> _priorityDropdownItem(
    SchedulePriority? priority,
    String label,
    Color color,
  ) {
    return DropdownMenuItem<SchedulePriority?>(
      value: priority,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _prioritySelectedItem(
    SchedulePriority? priority,
    String label,
    Color color,
  ) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    final selectedNotes = _selectedNotes();
    final noteCount = selectedNotes.length;
    final noteSubtitle = DateUtils.isSameDay(_selectedDate, DateTime.now())
      ? (noteCount == 1 ? '1 note today' : '$noteCount notes today')
      : (noteCount == 1
          ? '1 note on ${_selectedDate.day} ${_months[_selectedDate.month - 1]} ${_selectedDate.year}'
          : '$noteCount notes on ${_selectedDate.day} ${_months[_selectedDate.month - 1]} ${_selectedDate.year}');

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF8738F2), Color(0xFF5B33F5)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.sticky_note_2_outlined,
                  color: Colors.white,
                  size: 30,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Notes',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        noteSubtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.84),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SearchFilterField(
                  controller: _searchControllerResolved,
                  hintText: 'Search notes',
                  onChanged: (value) => setState(() => _query = value),
                  onClear: () => setState(() {
                    _query = '';
                    _searchControllerResolved.clear();
                  }),
                ),
                const SizedBox(height: 12),
                _buildPriorityDropdown(),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4FF),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Select Date:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: Theme.of(context).dividerColor),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  IconButton(
                                    onPressed: _prevMonth,
                                    icon: const Icon(Icons.chevron_left),
                                  ),
                                  DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: _months[_displayMonth.month - 1],
                                      items: _months
                                          .map(
                                            (month) => DropdownMenuItem(
                                              value: month,
                                              child: Text(month),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (value) {
                                        if (value == null) return;
                                        final monthIndex =
                                            _months.indexOf(value) + 1;
                                        setState(() {
                                          _displayMonth = DateTime(
                                            _displayMonth.year,
                                            monthIndex,
                                            1,
                                          );
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  DropdownButtonHideUnderline(
                                    child: DropdownButton<int>(
                                      value: _displayMonth.year,
                                      items: List.generate(
                                        11,
                                        (index) => 2020 + index,
                                      )
                                          .map(
                                            (year) => DropdownMenuItem(
                                              value: year,
                                              child: Text(year.toString()),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (value) {
                                        if (value == null) return;
                                        setState(() {
                                          _displayMonth = DateTime(
                                            value,
                                            _displayMonth.month,
                                            1,
                                          );
                                        });
                                      },
                                    ),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    onPressed: _nextMonth,
                                    icon: const Icon(Icons.chevron_right),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: const [
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Su',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Mo',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Tu',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'We',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Th',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Fr',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Center(
                                      child: Text(
                                        'Sa',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF848A9B),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Builder(
                                builder: (context) {
                                  final firstDayOfMonth = DateTime(
                                    _displayMonth.year,
                                    _displayMonth.month,
                                    1,
                                  );
                                  final offset = firstDayOfMonth.weekday % 7;
                                  final daysInMonth = DateTime(
                                    _displayMonth.year,
                                    _displayMonth.month + 1,
                                    0,
                                  ).day;

                                  return Column(
                                    children: List.generate(6, (week) {
                                      return Padding(
                                        padding: const EdgeInsets.only(bottom: 6),
                                        child: Row(
                                          children: List.generate(7, (dayIdx) {
                                            final index = week * 7 + dayIdx;
                                            final dayNumber = index - offset + 1;
                                            if (dayNumber < 1 ||
                                                dayNumber > daysInMonth) {
                                              return const Expanded(
                                                child: SizedBox(height: 42),
                                              );
                                            }

                                            final date = DateTime(
                                              _displayMonth.year,
                                              _displayMonth.month,
                                              dayNumber,
                                            );
                                            final isSelected =
                                                DateUtils.isSameDay(
                                              date,
                                              _selectedDate,
                                            );
                                            final isToday =
                                                DateUtils.isSameDay(
                                              date,
                                              DateTime.now(),
                                            );
                                            final hasEvent = _notes.any(
                                              (note) => DateUtils.isSameDay(
                                                note.date,
                                                date,
                                              ),
                                            );
                                            final tileColor = isSelected
                                                ? const Color(0xFF5B33F5)
                                                : hasEvent
                                                ? const Color(0xFFEAE4FF)
                                                : isToday
                                                ? const Color(0xFFF2EFFF)
                                                : Colors.transparent;

                                            return Expanded(
                                              child: GestureDetector(
                                                onTap: () => setState(
                                                  () => _selectedDate = date,
                                                ),
                                                child: Container(
                                                  margin: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 4,
                                                  ),
                                                  height: 42,
                                                  decoration: BoxDecoration(
                                                    color: tileColor,
                                                    borderRadius:
                                                        BorderRadius
                                                            .circular(10),
                                                  ),
                                                  alignment: Alignment.center,
                                                  child: Text(
                                                    dayNumber.toString(),
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: isSelected
                                                          ? Colors.white
                                                          : hasEvent
                                                          ? const Color(
                                                              0xFF5B33F5)
                                                          : isToday
                                                          ? const Color(
                                                              0xFF5B33F5)
                                                          : Colors.black87,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          }),
                                        ),
                                      );
                                    }),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Notes',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 230),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Entries for ${_selectedDate.day} ${_months[_selectedDate.month - 1]} ${_selectedDate.year}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6C7285),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (selectedNotes.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text('No notes for this date.'),
                    )
                  else
                    Column(
                      children: selectedNotes.map((note) {
                        final priorityColor = note.priority.color;
                        return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: priorityColor.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: priorityColor.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: priorityColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.sticky_note_2_outlined,
                                  color: Colors.white,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            note.title,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: priorityColor.withValues(
                                              alpha: 0.18,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            note.priority.label,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: priorityColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      note.description,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF515767),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => _openEditNote(note),
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: 'Edit note',
                              ),
                              IconButton(
                                onPressed: () => _deleteNote(note.id),
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Delete note',
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _openCreateNote,
                child: const Text('Add note'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, this.initialNote, this.initialDate});

  final NoteEntry? initialNote;
  final DateTime? initialDate;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late DateTime _selectedDate;
  late DateTime _displayMonth;
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late SchedulePriority _priority;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialNote;
    _selectedDate = DateUtils.dateOnly(
      initial?.date ?? widget.initialDate ?? DateTime.now(),
    );
    _displayMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);
    _titleController = TextEditingController(text: initial?.title ?? '');
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    _priority = initial?.priority ?? SchedulePriority.other;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _prevMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month - 1, 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + 1, 1);
    });
  }

  void _selectDate(DateTime date) {
    setState(() {
      _selectedDate = DateUtils.dateOnly(date);
      _displayMonth = DateTime(date.year, date.month, 1);
    });
  }

  void _save() {
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a note title.')),
      );
      return;
    }

    final note = NoteEntry(
      id:
          widget.initialNote?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      date: _selectedDate,
      title: title,
      description: description,
      priority: _priority,
    );

    if (!mounted) return;
    Navigator.of(context).pop(note);
  }

  Widget _priorityPill(SchedulePriority priority, {bool wide = false}) {
    final selected = _priority == priority;
    final color = priority.color;
    final borderColor = selected ? Theme.of(context).colorScheme.primary : Colors.transparent;

    return InkWell(
      onTap: () => setState(() => _priority = priority),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: wide ? 160 : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.10) : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: borderColor, width: selected ? 2 : 1),
          boxShadow: const [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Text(
              priority.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected
                    ? const Color(0xFF2F3140)
                    : const Color(0xFF2F3140),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialNote != null;
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        title: Text(
          isEditing ? 'Edit Note' : 'New Note',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 104),
          child: Column(
            children: [
              _SectionCard(
                title: 'Select Date',
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            onPressed: _prevMonth,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                '${monthNames[_displayMonth.month - 1]} ${_displayMonth.year}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _nextMonth,
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: const [
                          Text('Su', style: TextStyle(fontSize: 12, color: Color(0xFF848A9B))),
                          Text('Mo', style: TextStyle(fontSize: 12, color: Color(0xFF848A9B))),
                          Text('Tu', style: TextStyle(fontSize: 12, color: Color(0xFF848A9B))),
                          Text('We', style: TextStyle(fontSize: 12, color: Color(0xFF848A9B))),
                          Text('Th', style: TextStyle(fontSize: 12, color: Color(0xFF848A9B))),
                          Text('Fr', style: TextStyle(fontSize: 12, color: Color(0xFF848A9B))),
                          Text('Sa', style: TextStyle(fontSize: 12, color: Color(0xFF848A9B))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Builder(
                        builder: (context) {
                          final firstDayOfMonth = DateTime(
                            _displayMonth.year,
                            _displayMonth.month,
                            1,
                          );
                          final offset = firstDayOfMonth.weekday % 7;
                          final daysInMonth = DateTime(
                            _displayMonth.year,
                            _displayMonth.month + 1,
                            0,
                          ).day;

                          return Column(
                            children: List.generate(6, (week) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: List.generate(7, (dayIdx) {
                                    final index = week * 7 + dayIdx;
                                    final dayNumber = index - offset + 1;
                                    if (dayNumber < 1 || dayNumber > daysInMonth) {
                                      return const Expanded(
                                        child: SizedBox(height: 42),
                                      );
                                    }

                                    final date = DateTime(
                                      _displayMonth.year,
                                      _displayMonth.month,
                                      dayNumber,
                                    );
                                    final isSelected = DateUtils.isSameDay(
                                      date,
                                      _selectedDate,
                                    );
                                    final isToday = DateUtils.isSameDay(
                                      date,
                                      DateTime.now(),
                                    );

                                    return Expanded(
                                      child: GestureDetector(
                                        onTap: () => _selectDate(date),
                                        child: Container(
                                          margin: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          height: 42,
                                          decoration: BoxDecoration(
                                            color: isSelected
                                                ? const Color(0xFF5B33F5)
                                                : isToday
                                                ? const Color(0xFFF2EFFF)
                                                : Colors.transparent,
                                            borderRadius: BorderRadius.circular(10),
                                            border: Border.all(
                                              color: isSelected
                                                  ? const Color(0xFF5B33F5)
                                                  : Colors.transparent,
                                            ),
                                          ),
                                          alignment: Alignment.center,
                                          child: Text(
                                            dayNumber.toString(),
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: isSelected
                                                  ? Colors.white
                                                  : const Color(0xFF2F3140),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }),
                                ),
                              );
                            }),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              _SectionCard(
                title: 'Note Details',
                child: Column(
                  children: [
                    TextField(
                      controller: _titleController,
                      decoration: InputDecoration(
                        hintText: 'Title here',
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: Color(0xFF2F3140)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: Color(0xFF2F3140)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1.4,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _descriptionController,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: 'Description here',
                        alignLabelWithHint: true,
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: Color(0xFF2F3140)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: Color(0xFF2F3140)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1.4,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Priority',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: SchedulePriority.values
                      .map((priority) => _priorityPill(priority))
                      .toList(),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save note'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.seedColor,
    required this.notificationPermissionGranted,
    required this.exactAlarmPermissionGranted,
    required this.onSeedColorChanged,
    required this.onRefreshPermissions,
  });

  final Color seedColor;
  final bool? notificationPermissionGranted;
  final bool? exactAlarmPermissionGranted;
  final ValueChanged<Color> onSeedColorChanged;
  final Future<void> Function() onRefreshPermissions;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {

  static const Map<String, Color> _presetColors = {
    'Purple': Color(0xFF5B33F5),
    'Blue': Color(0xFF1E88E5),
    'Green': Color(0xFF10B981),
    'Orange': Color(0xFFF59E0B),
    'Red': Color(0xFFEF4444),
    'Teal': Color(0xFF0EA5E9),
    'Pink': Color(0xFFEC4899),
    'Indigo': Color(0xFF6366F1),
  };

  Future<void> _showPendingNotifications(BuildContext context) async {
    final pending = await AlarmNotificationService.instance
        .pendingNotifications();
    if (!context.mounted) return;

    if (pending.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Pending Notifications'),
          content: const Text('No pending scheduled notifications found.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final lines = pending
        .map(
          (p) =>
              'id: ${p.id} | title: ${p.title ?? ''} | body: ${p.body ?? ''} | payload: ${p.payload ?? ''}',
        )
        .toList();
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pending Notifications'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines.map((line) => Text(line)).toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _openAppSettings(BuildContext context) async {
    try {
      await AlarmNotificationService.instance.openAppSettings();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open app settings: $error')),
      );
    }
  }

  Future<void> _openBatterySettings(BuildContext context) async {
    try {
      await AlarmNotificationService.instance.openBatterySettings();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open battery settings: $error')),
      );
    }
  }

  Future<void> _checkNotificationPermission(BuildContext context) async {
    try {
      await AlarmNotificationService.instance.requestNotificationPermission();
      await widget.onRefreshPermissions();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to check notification permission: $error'),
        ),
      );
    }
  }

  Future<void> _checkExactAlarmsPermission(BuildContext context) async {
    try {
      await AlarmNotificationService.instance.requestExactAlarmsPermission();
      await widget.onRefreshPermissions();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to check exact alarms permission: $error'),
        ),
      );
    }
  }

  Future<void> _sendImmediateTest(BuildContext context) async {
    final alarms = await AlarmStorage.instance.loadAlarms();
    if (!context.mounted) return;

    if (alarms.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('No alarms'),
          content: const Text('Create an alarm first.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    await AlarmNotificationService.instance.showImmediateTestNotification(
      alarms.first,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Immediate test notification sent')),
    );
  }

  Widget _permissionRow({
    required String title,
    required String subtitle,
    required bool? granted,
    required VoidCallback onTap,
  }) {
    final isGranted = granted == true;
    final isUnknown = granted == null;
    final accentColor = isGranted ? const Color(0xFF16A34A) : const Color(0xFFE11D48);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isGranted
              ? const Color(0xFFEAF8EF)
              : const Color(0xFFFFEEF1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isGranted
                ? const Color(0xFFBFE8C9)
                : const Color(0xFFF5B7C0),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isGranted ? Icons.check_circle_outline : Icons.error_outline,
                color: accentColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        isGranted
                            ? 'Granted'
                            : isUnknown
                            ? 'Check'
                            : 'Needs attention',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: accentColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 179),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              const Icon(Icons.settings_outlined, size: 28),
              const SizedBox(width: 12),
              const Text(
                'Settings',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            'Accent Color',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: _presetColors.values.map((color) {
              final isSelected = color.toARGB32() == widget.seedColor.toARGB32();
              return GestureDetector(
                onTap: () => widget.onSeedColorChanged(color),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 20)
                      : null,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () {
              widget.onSeedColorChanged(const Color(0xFF5B33F5));
            },
            child: const Text('Reset to default theme'),
          ),
          const SizedBox(height: 24),
          const Text(
            'Alarm Settings',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F7FF),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _permissionRow(
                  title: 'Notification permission',
                  subtitle: 'Needed for alarm and schedule notifications.',
                  granted: widget.notificationPermissionGranted,
                  onTap: () => _checkNotificationPermission(context),
                ),
                const SizedBox(height: 10),
                _permissionRow(
                  title: 'Exact alarms permission',
                  subtitle: 'Needed so alarms can trigger at the exact time.',
                  granted: widget.exactAlarmPermissionGranted,
                  onTap: () => _checkExactAlarmsPermission(context),
                ),
                const SizedBox(height: 10),
                FilledButton.tonal(
                  onPressed: () => _showPendingNotifications(context),
                  child: const Text('Show pending notifications'),
                ),
                const SizedBox(height: 10),
                FilledButton.tonal(
                  onPressed: () => _sendImmediateTest(context),
                  child: const Text('Send immediate test notification'),
                ),
                const SizedBox(height: 10),
                FilledButton.tonal(
                  onPressed: () => _openAppSettings(context),
                  child: const Text('Open app settings'),
                ),
                const SizedBox(height: 10),
                FilledButton.tonal(
                  onPressed: () => _openBatterySettings(context),
                  child: const Text('Open battery settings'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Current accent',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Container(
            height: 60,
            decoration: BoxDecoration(
              color: widget.seedColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withValues(alpha: 51),
              ),
            ),
            alignment: Alignment.center,
            child: Builder(
              builder: (context) {
                final selectedTextColor =
                    ThemeData.estimateBrightnessForColor(widget.seedColor) ==
                        Brightness.dark
                    ? Colors.white
                    : Colors.black;
                return Text(
                  'Accent color selected',
                  style: TextStyle(
                    color: selectedTextColor,
                    fontWeight: FontWeight.w700,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchFilterField extends StatelessWidget {
  const _SearchFilterField({
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE0E4F0)),
        boxShadow: const [],
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: TextStyle(color: Colors.grey.shade500),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  onPressed: onClear,
                  icon: const Icon(Icons.close),
                  tooltip: 'Clear search',
                ),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFE0E4F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xFFE0E4F0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
          ),
        ),
      ),
    );
  }
}

class ScheduleEditorScreen extends StatefulWidget {
  const ScheduleEditorScreen({super.key, this.initialSchedule});

  final ScheduleEntry? initialSchedule;

  @override
  State<ScheduleEditorScreen> createState() => _ScheduleEditorScreenState();
}

class _ScheduleEditorScreenState extends State<ScheduleEditorScreen> {
  late DateTime _selectedDate;
  late int _startHour;
  late int _startMinute;
  late bool _startIsPm;
  late int _endHour;
  late int _endMinute;
  late bool _endIsPm;
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late SchedulePriority _priority;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSchedule;
    final now = DateTime.now();
    final defaultStart = TimeOfDay.fromDateTime(now);
    final defaultEnd = TimeOfDay.fromDateTime(
      now.add(const Duration(hours: 1)),
    );

    _selectedDate = DateUtils.dateOnly(initial?.date ?? DateTime.now());
    _startHour = _displayHour((initial?.startTime ?? defaultStart).hour);
    _startMinute = (initial?.startTime ?? defaultStart).minute;
    _startIsPm = (initial?.startTime ?? defaultStart).period == DayPeriod.pm;
    _endHour = _displayHour((initial?.endTime ?? defaultEnd).hour);
    _endMinute = (initial?.endTime ?? defaultEnd).minute;
    _endIsPm = (initial?.endTime ?? defaultEnd).period == DayPeriod.pm;
    _titleController = TextEditingController(text: initial?.title ?? '');
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    _priority = initial?.priority ?? SchedulePriority.other;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );

    if (picked != null) {
      setState(() {
        _selectedDate = DateUtils.dateOnly(picked);
      });
    }
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a schedule title.')),
      );
      return;
    }

    final startMinutes =
        _normalizeHour(_startHour, _startIsPm) * 60 + _startMinute;
    final endMinutes = _normalizeHour(_endHour, _endIsPm) * 60 + _endMinute;
    if (endMinutes <= startMinutes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must be after start time.')),
      );
      return;
    }

    final schedule = ScheduleEntry(
      id:
          widget.initialSchedule?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      date: _selectedDate,
      startTime: TimeOfDay(
        hour: _normalizeHour(_startHour, _startIsPm),
        minute: _startMinute,
      ),
      endTime: TimeOfDay(
        hour: _normalizeHour(_endHour, _endIsPm),
        minute: _endMinute,
      ),
      title: title,
      description: description,
      priority: _priority,
    );

    if (!mounted) return;
    Navigator.of(context).pop(schedule);
  }

  Widget _priorityPill(SchedulePriority priority, {bool wide = false}) {
    final selected = _priority == priority;
    final color = priority.color;
    final borderColor = selected ? const Color(0xFF5B33F5) : Colors.transparent;

    return InkWell(
      onTap: () => setState(() => _priority = priority),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: wide ? 160 : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.10) : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: borderColor, width: selected ? 2 : 1),
          boxShadow: const [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Text(
              priority.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected
                    ? const Color(0xFF2F3140)
                    : const Color(0xFF2F3140),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialSchedule != null;
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        title: Text(
          isEditing ? 'Edit Schedule' : 'New Schedule',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 104),
          child: Column(
            children: [
              _SectionCard(
                title: 'Select Date',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonal(
                        onPressed: _pickDate,
                        child: Text(
                          '${_selectedDate.day} ${monthNames[_selectedDate.month - 1]} ${_selectedDate.year}',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Select Time',
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8F9FC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Theme.of(context).dividerColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              const Text(
                                'From',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF2F3140),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${_startHour.toString().padLeft(2, '0')}:${_startMinute.toString().padLeft(2, '0')} ${_startIsPm ? 'PM' : 'AM'}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _ScrollableNumberPicker(
                                value: _startHour,
                                minValue: 1,
                                maxValue: 12,
                                onChanged: (value) =>
                                    setState(() => _startHour = value),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                ':',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _ScrollableNumberPicker(
                                value: _startMinute,
                                minValue: 0,
                                maxValue: 59,
                                onChanged: (value) =>
                                    setState(() => _startMinute = value),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                children: [
                                  _PeriodButton(
                                    label: 'AM',
                                    selected: !_startIsPm,
                                    onTap: () =>
                                        setState(() => _startIsPm = false),
                                  ),
                                  const SizedBox(height: 6),
                                  _PeriodButton(
                                    label: 'PM',
                                    selected: _startIsPm,
                                    onTap: () =>
                                        setState(() => _startIsPm = true),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8F9FC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Theme.of(context).dividerColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              const Text(
                                'To',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF2F3140),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${_endHour.toString().padLeft(2, '0')}:${_endMinute.toString().padLeft(2, '0')} ${_endIsPm ? 'PM' : 'AM'}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF5B33F5),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _ScrollableNumberPicker(
                                value: _endHour,
                                minValue: 1,
                                maxValue: 12,
                                onChanged: (value) =>
                                    setState(() => _endHour = value),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                ':',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _ScrollableNumberPicker(
                                value: _endMinute,
                                minValue: 0,
                                maxValue: 59,
                                onChanged: (value) =>
                                    setState(() => _endMinute = value),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                children: [
                                  _PeriodButton(
                                    label: 'AM',
                                    selected: !_endIsPm,
                                    onTap: () =>
                                        setState(() => _endIsPm = false),
                                  ),
                                  const SizedBox(height: 6),
                                  _PeriodButton(
                                    label: 'PM',
                                    selected: _endIsPm,
                                    onTap: () =>
                                        setState(() => _endIsPm = true),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Note Title',
                child: TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    hintText: 'Title here',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              _SectionCard(
                title: 'Note Description',
                child: TextField(
                  controller: _descriptionController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'Description here',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox.shrink(),
              _SectionCard(
                title: 'Priority/Importance',
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left column: main priority options (stacked)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _priorityPill(SchedulePriority.veryImportant),
                          const SizedBox(height: 8),
                          _priorityPill(SchedulePriority.semiImportant),
                          const SizedBox(height: 8),
                          _priorityPill(SchedulePriority.leastImportant),
                          const SizedBox(height: 8),
                          _priorityPill(SchedulePriority.optional),
                        ],
                      ),
                    ),
                    const SizedBox(width: 18),
                    // Right column: single 'Other' pill (no plus button)
                    Column(
                      children: [
                        _priorityPill(SchedulePriority.other, wide: true),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed: _save,
              child: Icon(
                isEditing ? Icons.edit : Icons.add_circle_outline,
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AlarmEditorScreen extends StatefulWidget {
  const AlarmEditorScreen({super.key, this.initialAlarm});

  final AlarmEntry? initialAlarm;

  @override
  State<AlarmEditorScreen> createState() => _AlarmEditorScreenState();
}

class _AlarmEditorScreenState extends State<AlarmEditorScreen> {
  late int _hour;
  late int _minute;
  late bool _isPm;
  late final TextEditingController _labelController;
  late final List<bool> _repeatDays;
  late AlarmDifficulty _difficulty;
  late AlarmSoundChoice _soundChoice;
  final AudioPlayer _previewPlayer = AudioPlayer();
  bool _testingSound = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialAlarm;
    final timeOfDay =
        initial?.timeOfDay ?? TimeOfDay.fromDateTime(DateTime.now());

    _hour = _displayHour(timeOfDay.hour);
    _minute = timeOfDay.minute;
    _isPm = timeOfDay.period == DayPeriod.pm;
    _labelController = TextEditingController(text: initial?.label ?? 'Alarm');
    _repeatDays = List<bool>.from(
      initial?.repeatDays ?? [false, true, true, true, true, true, false],
    );
    _difficulty = initial?.difficulty ?? AlarmDifficulty.medium;
    _soundChoice =
        initial?.sound ??
        const AlarmSoundChoice.phoneFile(displayName: '', filePath: '');
    _previewPlayer.setReleaseMode(ReleaseMode.stop);
  }

  @override
  void dispose() {
    _previewPlayer.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final label = _labelController.text.trim();
    if (label.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add an alarm description.')),
      );
      return;
    }

    if (_soundChoice.filePath == null || _soundChoice.filePath!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please choose a sound file first.')),
      );
      return;
    }

    final normalizedHour = _normalizeHour(_hour, _isPm);
    final notificationId =
        widget.initialAlarm?.notificationId ??
        await AlarmStorage.instance.allocateAlarmId();
    final alarm = AlarmEntry(
      id:
          widget.initialAlarm?.id ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      notificationId: notificationId,
      timeOfDay: TimeOfDay(hour: normalizedHour, minute: _minute),
      label: label,
      repeatDays: List<bool>.from(_repeatDays),
      difficulty: _difficulty,
      enabled: widget.initialAlarm?.enabled ?? true,
      sound: _soundChoice,
    );

    if (!mounted) return;
    Navigator.of(context).pop(alarm);
  }

  Future<void> _choosePhoneMusic() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
      allowMultiple: false,
      withData: false,
    );

    final filePath = result?.files.single.path;
    if (filePath == null || filePath.isEmpty) {
      return;
    }

    setState(() {
      _soundChoice = AlarmSoundChoice.phoneFile(
        displayName: _fileNameFromPath(filePath),
        filePath: filePath,
      );
    });
  }

  Future<void> _testSound() async {
    setState(() {
      _testingSound = true;
    });

    try {
      await _previewPlayer.stop();
      await _previewPlayer.play(_soundChoice.toAudioSource());
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not play selected sound: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _testingSound = false;
        });
      }
    }
  }

  void _changeHour(int newHour) {
    setState(() {
      _hour = newHour;
    });
  }

  void _changeMinute(int newMinute) {
    setState(() {
      _minute = newMinute;
    });
  }

  void _togglePeriod(bool isPm) {
    setState(() {
      _isPm = isPm;
    });
  }

  void _toggleDay(int index) {
    setState(() {
      _repeatDays[index] = !_repeatDays[index];
    });
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialAlarm != null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        title: Text(
          isEditing ? 'Edit Alarm' : 'New Alarm',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 104),
          child: Column(
            children: [
              _SectionCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _ScrollableNumberPicker(
                            value: _hour,
                            minValue: 1,
                            maxValue: 12,
                            onChanged: _changeHour,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            ':',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _ScrollableNumberPicker(
                            value: _minute,
                            minValue: 0,
                            maxValue: 59,
                            onChanged: _changeMinute,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      children: [
                        _PeriodButton(
                          label: 'AM',
                          selected: !_isPm,
                          onTap: () => _togglePeriod(false),
                        ),
                        const SizedBox(height: 8),
                        _PeriodButton(
                          label: 'PM',
                          selected: _isPm,
                          onTap: () => _togglePeriod(true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // This is the short note that shows up on the alarm card and notification.
              _SectionCard(
                title: 'Alarm Description',
                child: TextField(
                  controller: _labelController,
                  decoration: const InputDecoration(
                    hintText: 'Input text here',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              // These are the days the alarm should keep repeating on.
              _SectionCard(
                title: 'Repeat Days',
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var index = 0; index < 7; index++)
                      GestureDetector(
                        onTap: () => _toggleDay(index),
                        child: _RepeatDayCircle(
                          label: const [
                            'S',
                            'M',
                            'T',
                            'W',
                            'T',
                            'F',
                            'S',
                          ][index],
                          selected: _repeatDays[index],
                        ),
                      ),
                  ],
                ),
              ),
              // This is the alarm difficulty, which decides the math challenge later.
              _SectionCard(
                title: 'Mission/Task:',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(
                      child: Text(
                        'Math Problem',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // This is where the question level is chosen.
                    SegmentedButton<AlarmDifficulty>(
                      segments: const [
                        ButtonSegment(
                          value: AlarmDifficulty.easy,
                          label: Text('Easy'),
                        ),
                        ButtonSegment(
                          value: AlarmDifficulty.medium,
                          label: Text('Medium'),
                        ),
                        ButtonSegment(
                          value: AlarmDifficulty.hard,
                          label: Text('Hard'),
                        ),
                      ],
                      selected: {_difficulty},
                      onSelectionChanged: (value) {
                        setState(() {
                          _difficulty = value.first;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    // This is the little preview that shows the kind of question you will get.
                    _MathPreviewCard(difficulty: _difficulty),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Choose Alarm Sound',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 44,
                      child: FilledButton.tonal(
                        onPressed: _choosePhoneMusic,
                        child: const Text('Choose Music File'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _soundChoice.filePath == null ||
                              _soundChoice.filePath!.isEmpty
                          ? 'No sound selected yet.'
                          : 'Selected sound: ${_soundChoice.displayName}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Pick an MP3, WAV, or other supported audio file from your phone. The alarm screen will play that file.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 179),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 44,
                      child: FilledButton.icon(
                        onPressed: _testingSound ? null : _testSound,
                        icon: Icon(
                          _testingSound ? Icons.graphic_eq : Icons.play_arrow,
                        ),
                        label: Text(
                          _testingSound ? 'Playing...' : 'Test Selected Sound',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed: _save,
              child: Icon(
                isEditing ? Icons.edit : Icons.add_circle_outline,
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F2FF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4E6FA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(title!, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

class _ScrollableNumberPicker extends StatefulWidget {
  const _ScrollableNumberPicker({
    required this.value,
    required this.onChanged,
    required this.minValue,
    required this.maxValue,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final int minValue;
  final int maxValue;

  @override
  State<_ScrollableNumberPicker> createState() =>
      _ScrollableNumberPickerState();
}

class _ScrollableNumberPickerState extends State<_ScrollableNumberPicker> {
  Future<void> _showInputDialog() async {
    final controller = TextEditingController(text: widget.value.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Enter value'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            maxLength: 2,
            decoration: InputDecoration(
              hintText: 'Between ${widget.minValue} and ${widget.maxValue}',
              border: const OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final parsed = int.tryParse(controller.text.trim());
                if (parsed != null &&
                    parsed >= widget.minValue &&
                    parsed <= widget.maxValue) {
                  Navigator.pop(context, parsed);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Enter a number between ${widget.minValue} and ${widget.maxValue}',
                      ),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
    if (result != null) {
      widget.onChanged(result);
    }
  }

  void _increment() {
    if (widget.value < widget.maxValue) {
      widget.onChanged(widget.value + 1);
    }
  }

  void _decrement() {
    if (widget.value > widget.minValue) {
      widget.onChanged(widget.value - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _showInputDialog,
      child: Column(
        children: [
          IconButton(
            onPressed: _increment,
            icon: const Icon(Icons.keyboard_arrow_up_rounded),
            visualDensity: VisualDensity.standard,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          ),
          Container(
            width: 78,
            height: 74,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFFD7DCE8),
                width: 1.2,
              ),
              boxShadow: const [],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.value.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _decrement,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            visualDensity: VisualDensity.standard,
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          ),
        ],
      ),
    );
  }
}

class _PeriodButton extends StatelessWidget {
  const _PeriodButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 58,
      child: FilledButton.tonal(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: selected ? const Color(0xFF5430E8) : Colors.white,
          foregroundColor: selected ? Colors.white : const Color(0xFF2F3140),
          padding: const EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: BorderSide(
            color: selected ? const Color(0xFF5430E8) : const Color(0xFFE1E3F0),
          ),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _RepeatDayCircle extends StatelessWidget {
  const _RepeatDayCircle({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF5C34F6) : Colors.white,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : const Color(0xFFC3C6D5),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MathPreviewCard extends StatelessWidget {
  const _MathPreviewCard({required this.difficulty});

  final AlarmDifficulty difficulty;

  @override
  Widget build(BuildContext context) {
    final questions = _generateQuestions(difficulty);
    final color = difficulty.color;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(
              difficulty.label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 10),
          for (final question in questions)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                question.question,
                style: const TextStyle(color: Color(0xFF505566), fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

class AlarmRingingScreen extends StatefulWidget {
  const AlarmRingingScreen({super.key, required this.alarm});

  final AlarmEntry alarm;

  @override
  State<AlarmRingingScreen> createState() => _AlarmRingingScreenState();
}

class _AlarmRingingScreenState extends State<AlarmRingingScreen> {
  late final List<MathQuestion> _questions;
  late final TextEditingController _answerController;
  late final AudioPlayer _alarmPlayer;
  late final int _questionSeed;
  int _index = 0;
  String? _errorText;
  String? _soundError;

  @override
  void initState() {
    super.initState();
    _questionSeed = Random().nextInt(1 << 32);
    _questions = _generateQuestions(
      widget.alarm.difficulty,
      count: 5,
      seed: _questionSeed,
    );
    _answerController = TextEditingController();
    _alarmPlayer = AudioPlayer()..setReleaseMode(ReleaseMode.loop);
    // Stop any native playback started while the device was asleep, then
    // start Flutter's player. This avoids duplicate overlapping audio.
    Future.microtask(() async {
      try {
        await AlarmNotificationService.instance.stopNativeAlarmSound();
      } catch (_) {}
      if (mounted) await _playAlarmSound();
    });
  }

  @override
  void dispose() {
    _alarmPlayer.dispose();
    _answerController.dispose();
    super.dispose();
  }

  Future<void> _playAlarmSound() async {
    try {
      await _alarmPlayer.stop();
      await _alarmPlayer.play(widget.alarm.sound.toAudioSource());
    } catch (error) {
      if (!mounted) return;
      setState(() => _soundError = 'Sound playback failed: $error');
    }
  }

  Future<void> _stopAlarmSound() async => await _alarmPlayer.stop();

  Future<void> _submit() async {
    final parsed = int.tryParse(_answerController.text.trim());
    if (parsed == null) {
      setState(() => _errorText = 'Enter a number.');
      return;
    }
    if (parsed != _questions[_index].answer) {
      setState(() => _errorText = 'Try again.');
      return;
    }
    if (_index < _questions.length - 1) {
      setState(() {
        _index += 1;
        _errorText = null;
        _answerController.clear();
      });
    } else {
      await _stopAlarmSound();
      try {
        await AlarmNotificationService.instance.stopNativeAlarmSound();
      } catch (_) {}
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentQuestion = _questions[_index];
    final progress = (_index + 1) / _questions.length;
    final time = _formatAlarmTime(widget.alarm.timeOfDay);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              decoration: const BoxDecoration(
                color: Color(0xFFE42E63),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(26),
                  bottomRight: Radius.circular(26),
                ),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.notifications_none_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${time.hour}:${time.minute} ${time.period}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.alarm.label,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Solve the Math Problem!',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${_index + 1}/${_questions.length}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 15,
                          color: Color(0xFF535867),
                        ),
                      ),
                      if (_soundError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _soundError!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFE11D48),
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 22,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F2FF),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(
                          currentQuestion.question,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _answerController,
                        keyboardType: TextInputType.number,
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          hintText: 'Enter your answer here',
                          errorText: _errorText,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 16,
                          ),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 6,
                          backgroundColor: const Color(0xFFE8E2FA),
                          valueColor: const AlwaysStoppedAnimation(
                            Color(0xFF5B33F5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.center,
                        child: _DifficultyChip(widget.alarm.difficulty),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 54,
                        child: FilledButton(
                          onPressed: _submit,
                          child: const Text('Submit Answer to Stop Alarm!'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FormattedAlarmTime {
  final String hour;
  final String minute;
  final String period;
  const _FormattedAlarmTime({
    required this.hour,
    required this.minute,
    required this.period,
  });
}

_FormattedAlarmTime _formatAlarmTime(TimeOfDay timeOfDay) {
  final displayHour = timeOfDay.hourOfPeriod == 0 ? 12 : timeOfDay.hourOfPeriod;
  return _FormattedAlarmTime(
    hour: displayHour.toString().padLeft(2, '0'),
    minute: timeOfDay.minute.toString().padLeft(2, '0'),
    period: timeOfDay.period == DayPeriod.am ? 'AM' : 'PM',
  );
}

int _displayHour(int hour24) {
  final hour = hour24 % 12;
  return hour == 0 ? 12 : hour;
}

int _normalizeHour(int displayHour, bool isPm) {
  if (displayHour == 12) {
    return isPm ? 12 : 0;
  }
  return isPm ? displayHour + 12 : displayHour;
}

String _fileNameFromPath(String filePath) {
  final sanitized = filePath.replaceAll('\\', '/');
  final index = sanitized.lastIndexOf('/');
  return index >= 0 ? sanitized.substring(index + 1) : sanitized;
}

List<MathQuestion> _generateQuestions(
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
