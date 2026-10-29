import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../mail/mail_account.dart';
import '../widgets.dart';
import 'help.dart';

/// Choices from 앱 설정, kept in a JSON file in the app's support folder.
class AppSettings {
  const AppSettings({this.listSize = 20, this.checkMinutes = 0});

  /// Mails per account in a mail list.
  final int listSize;

  /// How often home checks for new mail; 0 is never.
  final int checkMinutes;

  AppSettings copyWith({int? listSize, int? checkMinutes}) => AppSettings(
    listSize: listSize ?? this.listSize,
    checkMinutes: checkMinutes ?? this.checkMinutes,
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
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save() async => (await _file).writeAsString(
    jsonEncode({'listSize': listSize, 'checkMinutes': checkMinutes}),
  );
}

/// 설정: a menu of 메일 연동, 음성 설정, 알림 설정 and 도움말.
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
        MenuRow(
          '메일 연동',
          widget.accounts.isEmpty
              ? '아직 연결한 메일이 없어요'
              : [for (final a in widget.accounts) a.address].join('\n'),
          icon: Icons.alternate_email_rounded,
          onTap: () => _open(widget.accountsScreen(trail)),
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
  );
}

Widget _choices(
  int value,
  List<(int, String)> options,
  void Function(int) onPick,
) => SegmentedButton<int>(
  showSelectedIcon: false,
  segments: [
    for (final (v, label) in options)
      ButtonSegment(value: v, label: Text(label)),
  ],
  selected: {value},
  onSelectionChanged: (picked) => onPick(picked.single),
);
