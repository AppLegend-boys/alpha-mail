import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../mail/mail_account.dart';
import '../widgets.dart';

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

/// 앱 설정: linked mail accounts, how mail is fetched, and what's coming.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.from,
    required this.accounts,
    required this.settings,
    required this.onChanged,
    required this.accountsScreen,
  });

  final List<String> from;
  final List<MailAccount> accounts;
  final AppSettings settings;
  final void Function(AppSettings) onChanged;

  /// The account list to open, given its breadcrumb.
  final Widget Function(List<String> from) accountsScreen;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late var _settings = widget.settings;

  void _set(AppSettings settings) {
    setState(() => _settings = settings);
    widget.onChanged(settings);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final trail = [...widget.from, '앱 설정'];
    final hint = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    Widget row(
      String title,
      String sub,
      Widget trailing, {
      VoidCallback? onTap,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: VoiceCard(
        onTap: onTap,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(sub, style: hint),
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      ),
    );
    Widget choices(
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
    final soon = StatusChip('곧 지원', colors.onSurfaceVariant);
    return AppPage(
      trail: trail,
      children: [
        const ScreenTitle('앱 설정', '내 메일 공간 설정'),
        heading('메일 계정'),
        row(
          '연결한 메일',
          widget.accounts.isEmpty
              ? '아직 연결한 메일이 없어요'
              : [for (final a in widget.accounts) a.address].join('\n'),
          Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => widget.accountsScreen(trail)),
          ),
        ),
        heading('메일 가져오기'),
        row(
          '새 메일 확인',
          '홈의 안 읽은 메일 수를 다시 불러와요',
          choices(_settings.checkMinutes, const [
            (0, '끄기'),
            (5, '5분'),
            (15, '15분'),
          ], (v) => _set(_settings.copyWith(checkMinutes: v))),
        ),
        row(
          '목록에 보여줄 메일',
          '계정마다 최근 몇 건까지 불러올지',
          choices(_settings.listSize, const [
            (20, '20건'),
            (50, '50건'),
            (100, '100건'),
          ], (v) => _set(_settings.copyWith(listSize: v))),
        ),
        // The phone app stands alone, so only desktop has a phone to link.
        if (isDesktop) ...[
          heading('폰 연결'),
          row('폰과 연결하기', '폰에서 말로 이 데스크탑의 메일을 듣고 답장해요', soon),
        ],
        heading('알림'),
        row('새 메일 알림', '새 메일이 오면 알려 드려요', soon),
        heading('정보'),
        row(
          '개인정보',
          '메일은 우리 서버를 거치지 않고 이 기기에서만 불러와요. '
              '비밀번호와 로그인 정보는 기기의 보안 저장소에 저장돼요.',
          const SizedBox.shrink(),
        ),
        row(
          '구글 계정 권한 관리',
          '구글에서 이 앱의 메일 접근 권한을 직접 확인하거나 해제해요',
          Icon(Icons.open_in_new_rounded, color: colors.onSurfaceVariant),
          onTap: () =>
              launchUrl(Uri.parse('https://myaccount.google.com/permissions')),
        ),
      ],
    );
  }
}
