import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../bluetooth.dart';
import '../mail/mail_account.dart';
import '../widgets.dart';
import 'help.dart';

/// Choices from 앱 설정, kept in a JSON file in the app's support folder.
class AppSettings {
  const AppSettings({
    this.listSize = 20,
    this.checkMinutes = 0,
    this.screenMode = 'touch',
    this.autoRun = false,
    this.autoDevice,
    this.autoDeviceName,
    this.autoRanOn,
  });

  /// Mails per account in a mail list.
  final int listSize;

  /// How often home checks for new mail; 0 is never.
  final int checkMinutes;

  /// 화면 모드: 'touch' (터치 중심) or 'voice' (음성 중심).
  final String screenMode;

  /// 자동 실행: asks about the unread mail by itself once a day, when the
  /// Bluetooth device [autoDevice] (an ID from lib/bluetooth.dart) connects.
  final bool autoRun;
  final String? autoDevice;
  final String? autoDeviceName;

  /// The day 자동 실행 last asked, from [dayKey].
  final String? autoRanOn;

  /// 자동 실행 is on and hasn't asked yet on [now]'s day.
  bool autoRunDue(DateTime now) =>
      autoRun && autoDevice != null && autoRanOn != dayKey(now);

  static String dayKey(DateTime now) => '${now.year}-${now.month}-${now.day}';

  AppSettings copyWith({
    int? listSize,
    int? checkMinutes,
    String? screenMode,
    bool? autoRun,
    String? autoDevice,
    String? autoDeviceName,
    String? autoRanOn,
  }) => AppSettings(
    listSize: listSize ?? this.listSize,
    checkMinutes: checkMinutes ?? this.checkMinutes,
    screenMode: screenMode ?? this.screenMode,
    autoRun: autoRun ?? this.autoRun,
    autoDevice: autoDevice ?? this.autoDevice,
    autoDeviceName: autoDeviceName ?? this.autoDeviceName,
    autoRanOn: autoRanOn ?? this.autoRanOn,
  );

  static Future<File> get _file async =>
      File('${(await getApplicationSupportDirectory()).path}/settings.json');

  /// The saved settings, or the defaults if there are none yet.
  static Future<AppSettings> load() async {
    try {
      final json = jsonDecode(await (await _file).readAsString());
      return AppSettings(
        listSize: json['listSize'] as int? ?? 20,
        checkMinutes: json['checkMinutes'] as int? ?? 0,
        screenMode: json['screenMode'] as String? ?? 'touch',
        autoRun: json['autoRun'] as bool? ?? false,
        autoDevice: json['autoDevice'] as String?,
        autoDeviceName: json['autoDeviceName'] as String?,
        autoRanOn: json['autoRanOn'] as String?,
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save() async => (await _file).writeAsString(
    jsonEncode({
      'listSize': listSize,
      'checkMinutes': checkMinutes,
      'screenMode': screenMode,
      'autoRun': autoRun,
      'autoDevice': autoDevice,
      'autoDeviceName': autoDeviceName,
      'autoRanOn': autoRanOn,
    }),
  );
}

/// 설정: a menu of 메일 연동, 화면 모드, 음성 설정, 알림 설정 and 도움말.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.from,
    required this.accounts,
    required this.settings,
    required this.onChanged,
    required this.accountsScreen,
    required this.voiceScreen,
  });

  final List<String> from;
  final List<MailAccount> accounts;
  final AppSettings settings;
  final void Function(AppSettings) onChanged;

  /// The account list and 음성 설정 to open, given their breadcrumb.
  final Widget Function(List<String> from) accountsScreen;
  final Widget Function(List<String> from) voiceScreen;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late var _settings = widget.settings;

  void _set(AppSettings settings) {
    setState(() => _settings = settings);
    widget.onChanged(settings);
  }

  /// Picks the device 자동 실행 waits for, and turns it on.
  Future<void> _pickDevice() async {
    final devices = await Bluetooth.devices();
    if (!mounted) return;
    final picked = await showDialog<BluetoothDevice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('어떤 기기에 연결되면 알려 드릴까요?'),
        children: [
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                Platform.isIOS
                    ? '연결된 블루투스 오디오 기기가 없어요. 기기를 먼저 연결해 주세요.'
                    : '페어링된 기기가 없어요. 블루투스를 켜고 권한을 허용해 주세요.',
              ),
            ),
          for (final d in devices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, d),
              child: Text(d.name, style: const TextStyle(fontSize: 17)),
            ),
        ],
      ),
    );
    if (picked != null) {
      _set(
        _settings.copyWith(
          autoRun: true,
          autoDevice: picked.id,
          autoDeviceName: picked.name,
        ),
      );
      await _explainClosedLaunch();
    }
  }

  /// A closed app only opens itself on Android, with 다른 앱 위에 표시
  /// allowed. iOS never lets it, so a Shortcuts automation opens it there.
  Future<void> _explainClosedLaunch() async {
    if (Platform.isAndroid && await Bluetooth.launchAllowed()) return;
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('앱이 꺼져 있을 때도 알려 드릴까요?'),
        content: Text(
          Platform.isIOS
              ? 'iPhone에서는 앱이 스스로 켜지지 않아요. 단축어 앱의 자동화에서 '
                    '새로운 자동화 > 블루투스로 이 기기를 고르고, 즉시 실행으로 '
                    'Alpha Mail 앱을 열도록 해 주세요.'
              : '‘다른 앱 위에 표시’를 허용하면 앱이 꺼져 있어도 기기가 연결될 때 '
                    '앱이 열리고 물어봐요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(Platform.isIOS ? '확인' : '나중에'),
          ),
          if (Platform.isAndroid)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('허용하러 가기'),
            ),
        ],
      ),
    );
    if (go == true) await Bluetooth.allowLaunch();
  }

  void _open(Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final trail = [...widget.from, '설정'];
    return AppPage(
      trail: trail,
      children: [
        const ScreenTitle('', '설정'),
        const SizedBox(height: 20),
        MenuGroup(
          children: [
            MenuRow(
              '메일 연동',
              widget.accounts.isEmpty
                  ? '아직 연결한 메일이 없어요'
                  : [for (final a in widget.accounts) a.address].join('\n'),
              icon: Icons.alternate_email_rounded,
              onTap: () => _open(widget.accountsScreen(trail)),
            ),
            MenuRow(
              '화면 모드',
              _settings.screenMode == 'voice'
                  ? '말로 듣고 답하는 큰 화면'
                  : '눌러서 확인하는 기본 화면',
              icon: Icons.dashboard_customize_outlined,
              trailing: _choices(_settings.screenMode, const [
                ('touch', '터치'),
                ('voice', '음성'),
              ], (v) => _set(_settings.copyWith(screenMode: v))),
            ),
            MenuRow(
              '자동 실행',
              _settings.autoDeviceName == null
                  ? '블루투스 기기에 연결되면 안 읽은 메일을 알려 줘요'
                  : '${_settings.autoDeviceName}에 연결되면 하루 한 번 알려 줘요',
              icon: Icons.bluetooth_rounded,
              onTap: _pickDevice,
              trailing: Switch(
                value: _settings.autoRun,
                onChanged: (on) {
                  if (on && _settings.autoDevice == null) {
                    _pickDevice();
                    return;
                  }
                  _set(_settings.copyWith(autoRun: on));
                  if (on) _explainClosedLaunch();
                },
              ),
            ),
            MenuRow(
              '음성 설정',
              '음성 모델, 목소리 변경',
              icon: Icons.record_voice_over_outlined,
              onTap: () => _open(widget.voiceScreen(trail)),
            ),
            MenuRow(
              '알림 설정',
              '새 메일 확인, 새 메일 알림',
              icon: Icons.notifications_none_rounded,
              onTap: () => _open(
                NotificationSettingsScreen(
                  from: trail,
                  settings: _settings,
                  onChanged: _set,
                ),
              ),
            ),
            MenuRow(
              '도움말',
              '오류 코드별 해결 방법',
              icon: Icons.help_outline_rounded,
              onTap: () => _open(HelpScreen(from: trail)),
            ),
          ],
        ),
      ],
    );
  }
}

/// 알림 설정: how often home checks for new mail, and alerts to come.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({
    super.key,
    required this.from,
    required this.settings,
    required this.onChanged,
  });

  final List<String> from;
  final AppSettings settings;
  final void Function(AppSettings) onChanged;

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  late var _settings = widget.settings;

  @override
  Widget build(BuildContext context) => AppPage(
    trail: [...widget.from, '알림 설정'],
    children: [
      const ScreenTitle('알림 설정', '새 메일을 언제 알려 드릴까요?'),
      const SizedBox(height: 20),
      MenuGroup(
        children: [
          MenuRow(
            '새 메일 확인',
            '홈의 안 읽은 메일 수를 다시 불러와요',
            trailing: _choices(
              _settings.checkMinutes,
              const [(0, '끄기'), (5, '5분'), (15, '15분')],
              (v) {
                setState(() => _settings = _settings.copyWith(checkMinutes: v));
                widget.onChanged(_settings);
              },
            ),
          ),
          MenuRow(
            '새 메일 알림',
            '새 메일이 오면 알려 드려요',
            trailing: StatusChip(
              '곧 지원',
              Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ],
  );
}

Widget _choices<T>(
  T value,
  List<(T, String)> options,
  void Function(T) onPick,
) => SegmentedButton<T>(
  showSelectedIcon: false,
  segments: [
    for (final (v, label) in options)
      ButtonSegment(value: v, label: Text(label)),
  ],
  selected: {value},
  onSelectionChanged: (picked) => onPick(picked.single),
);
