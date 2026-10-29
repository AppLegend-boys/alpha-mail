import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../mail/mail_account.dart';
import '../widgets.dart';
import 'help.dart';

/// First step of connecting: pick the mail service. Any number of accounts
/// can be linked, several per service too.
class MailProviderScreen extends StatelessWidget {
  const MailProviderScreen({
    super.key,
    required this.from,
    required this.accounts,
    required this.onAdded,
    required this.onRemoved,
  });

  final List<String> from;

  /// Linked accounts, of every service.
  final List<MailAccount> accounts;
  final Future<void> Function(MailAccount account, Unread unread) onAdded;
  final Future<void> Function(MailAccount account) onRemoved;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget provider(
      String name,
      String mark,
      Color markColor,
      String sub, {
      VoidCallback? onTap,
      bool linked = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: VoiceCard(
        onTap:
            onTap ??
            () => ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('$name 연동은 곧 지원할 예정이에요'))),
        child: Row(
          children: [
            ServiceBadge(mark, markColor, size: 40),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$name 연동',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap == null)
              StatusChip('곧 지원', colors.onSurfaceVariant)
            else ...[
              StatusChip(
                linked ? '연결됨' : '연결 안 됨',
                linked ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
    return AppPage(
      trail: [...from, '메일 연동하기'],
      children: [
        const ScreenTitle('메일 연동하기', '어떤 메일을 연결할까요?'),
        const SizedBox(height: 20),
        for (final (service, sub) in [
          (MailService.naver, '아이디와 애플리케이션 비밀번호로 연결해요'),
          (MailService.gmail, '구글 계정으로 로그인해서 연결해요'),
          (MailService.outlook, '마이크로소프트 계정으로 로그인해서 연결해요'),
        ])
          provider(
            service.label,
            service.mark,
            service.color,
            switch ([
              for (final a in accounts)
                if (a.service == service) a.address,
            ]) {
              [] => sub,
              final linked => '연결됨 · ${linked.join(', ')}',
            },
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MailConnectScreen(
                  from: [...from, '메일 연동하기'],
                  service: service,
                  accounts: accounts,
                  onAdded: onAdded,
                  onRemoved: onRemoved,
                ),
              ),
            ),
            linked: accounts.any((a) => a.service == service),
          ),
      ],
    );
  }
}

/// Signs in to one mail service over IMAP: Naver with an app password,
/// Gmail and Outlook with their own sign-in. The password or token stays in the keychain.
/// Linking an address again replaces its saved login.
class MailConnectScreen extends StatefulWidget {
  const MailConnectScreen({
    super.key,
    required this.from,
    required this.service,
    required this.accounts,
    required this.onAdded,
    required this.onRemoved,
  });

  final List<String> from;
  final MailService service;

  /// Linked accounts, of every service.
  final List<MailAccount> accounts;

  /// Saves the new account and shows its unread mails.
  final Future<void> Function(MailAccount account, Unread unread) onAdded;
  final Future<void> Function(MailAccount account) onRemoved;

  @override
  State<MailConnectScreen> createState() => _MailConnectScreenState();
}

class _MailConnectScreenState extends State<MailConnectScreen> {
  final _id = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hidden = true;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    final naver = widget.service == MailService.naver;
    if (naver && (_id.text.trim().isEmpty || _password.text.isEmpty)) {
      setState(() => _error = '아이디와 비밀번호를 모두 넣어 주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = naver
          ? MailAccount(_id.text, _password.text)
          : await MailAccount.signIn(widget.service);
      // Fetching doubles as the login check.
      final unread = await account.fetchUnread();
      await widget.onAdded(account, unread);
      if (!mounted) return;
      // Back home past the provider list.
      Navigator.popUntil(context, (route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${account.address}을 연결했어요 · 안 읽은 메일 ${unread.total}건'),
        ),
      );
    } catch (error) {
      debugPrint('mail connect failed: $error');
      if (mounted) setState(() => _error = mailError(widget.service, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect(MailAccount account) async {
    await account.revoke();
    await widget.onRemoved(account);
    if (!mounted) return;
    // Back home past the provider list.
    Navigator.popUntil(context, (route) => route.isFirst);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${account.address} 연결을 해제했어요')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    InputDecoration field(String label, {String? suffix, Widget? icon}) =>
        InputDecoration(
          labelText: label,
          suffixText: suffix,
          suffixIcon: icon,
          filled: true,
          fillColor: colors.surfaceContainer,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colors.outlineVariant),
          ),
        );
    final service = widget.service;
    final linked = [
      for (final a in widget.accounts)
        if (a.service == service) a,
    ];
    final naver = service == MailService.naver;
    return AppPage(
      trail: [...widget.from, service.label],
      children: [
        ScreenTitle('메일 연동하기', service.label),
        const SizedBox(height: 20),
        if (linked.isNotEmpty) ...[
          for (final account in linked) ...[
            VoiceCard(
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '연결됨',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(account.address, style: hint),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _disconnect(account),
                    child: const Text('연결 해제'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 18),
          Text('다른 계정 추가하기', style: hint),
          const SizedBox(height: 12),
        ] else if (naver) ...[
          Text(
            '네이버는 외부 앱에서 메일을 열 때 2단계 인증과 '
            '애플리케이션 비밀번호를 꼭 쓰도록 하고 있어요. '
            '처음 한 번만 아래 순서대로 설정해 주세요.',
            style: hint.copyWith(height: 1.6),
          ),
          const SizedBox(height: 14),
          _SetupStep(
            number: 1,
            title: '2단계 인증 켜고 애플리케이션 비밀번호 만들기',
            detail:
                '버튼으로 네이버 보안설정을 연 뒤\n'
                '2단계 인증의 [관리] → 비밀번호 한 번 더 입력 → '
                '애플리케이션 비밀번호 관리에서 종류를 "직접 입력"으로 고르고, '
                '이름 칸에 "Alpha Mail"을 붙여 넣어 [생성]을 눌러요.\n'
                '2단계 인증이 꺼져 있다면 먼저 켜 주세요.\n'
                '"올바르지 않은 접근"이 뜨면 naver.com에서 '
                '내 프로필 → 네이버ID → 보안설정으로 들어가 주세요.',
            action: '네이버 보안설정 열기',
            url: naverSecurity,
            copy: 'Alpha Mail',
          ),
          const SizedBox(height: 10),
          _SetupStep(
            number: 2,
            title: 'IMAP/SMTP 사용 켜기',
            detail:
                '버튼을 누르면 네이버 메일의 IMAP 설정 화면이 바로 열려요. '
                '"IMAP/SMTP 사용"을 "사용함"으로 고르고 저장해요.',
            action: 'IMAP 설정 바로 열기',
            url: naverMail,
          ),
          const SizedBox(height: 10),
          const _SetupStep(
            number: 3,
            title: '아래에 아이디와 애플리케이션 비밀번호 넣기',
            detail: '1번에서 만든 비밀번호를 그대로 붙여 넣어요. 평소 로그인 비밀번호로는 연결되지 않아요.',
          ),
          const SizedBox(height: 24),
        ] else ...[
          Text(
            '버튼을 누르면 ${service == MailService.outlook ? '마이크로소프트' : '구글'} 로그인 화면이 열려요. '
            '계정을 고르고 메일 접근을 허용하면 바로 연결돼요. '
            '앱 비밀번호나 IMAP 설정은 필요 없어요.',
            style: hint.copyWith(height: 1.6),
          ),
        ],
        if (naver)
          AutofillGroup(
            child: Column(
              children: [
                TextField(
                  controller: _id,
                  enabled: !_busy,
                  autofillHints: const [AutofillHints.username],
                  textInputAction: TextInputAction.next,
                  decoration: field('네이버 아이디', suffix: '@naver.com'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: _hidden,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _connect(),
                  decoration: field(
                    '애플리케이션 비밀번호',
                    icon: IconButton(
                      tooltip: _hidden ? '비밀번호 보기' : '비밀번호 숨기기',
                      onPressed: () => setState(() => _hidden = !_hidden),
                      icon: Icon(
                        _hidden
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_error case final error?) ...[
          const SizedBox(height: 12),
          ProblemText(
            error,
            style: TextStyle(color: colors.error, height: 1.5),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : Text(switch (service) {
                  MailService.naver => '연결하기',
                  MailService.gmail => 'Google로 로그인',
                  MailService.outlook => 'Microsoft로 로그인',
                }),
        ),
        const SizedBox(height: 14),
        Text(
          naver
              ? '비밀번호는 이 기기의 보안 저장소에만 저장돼요.\n'
                    '메일은 다른 서버를 거치지 않고 네이버와 직접 주고받아요.'
              : service == MailService.outlook
              ? '마이크로소프트 비밀번호는 앱이 보지 않아요. 마이크로소프트가 준 접근 권한만\n'
                    '이 기기의 보안 저장소에 저장하고, 메일은 마이크로소프트와 직접 주고받아요.'
              : '구글 비밀번호는 앱이 보지 않아요. 구글이 준 접근 권한만\n'
                    '이 기기의 보안 저장소에 저장하고, 메일은 구글과 직접 주고받아요.',
          textAlign: TextAlign.center,
          style: hint.copyWith(fontSize: 13, height: 1.5),
        ),
      ],
    );
  }
}

// Both pages ask for a Naver login first, then show the setting.
// Naver ID's security tab. nid.naver.com sometimes rejects pages opened
// from outside Naver ("일시적인 오류이거나 올바르지 않은 접근"), so the step
// also spells out the route from naver.com.
final naverSecurity = Uri.parse(
  'https://nid.naver.com/user2/help/myInfoV2?m=viewSecurity&lang=ko_KR',
);
final naverMail = Uri.parse('https://mail.naver.com/v2/settings/smtp/imap');

/// Opens [url] in the browser; if that fails, offers the address to copy
/// so the user is never left with a button that silently does nothing.
Future<void> openLink(BuildContext context, Uri url) async {
  final messenger = ScaffoldMessenger.of(context);
  var opened = false;
  try {
    // In the browser app, not a tab over this one, so the steps here stay
    // a switch away while following them.
    opened = await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (opened) return;
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('브라우저를 열지 못했어요. 주소를 복사해 열어 주세요.\n$url'),
      action: SnackBarAction(
        label: '주소 복사',
        onPressed: () => Clipboard.setData(ClipboardData(text: '$url')),
      ),
    ),
  );
}

/// One numbered setup step, with a button that opens the settings page for it.
class _SetupStep extends StatelessWidget {
  const _SetupStep({
    required this.number,
    required this.title,
    required this.detail,
    this.action,
    this.url,
    this.copy,
  });

  /// Text the step asks the user to type, offered as a copy button.
  final String? copy;

  final int number;
  final String title;
  final String detail;
  final String? action;
  final Uri? url;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return VoiceCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: colors.primaryContainer,
            child: Text(
              '$number',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: colors.primary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (url != null || copy != null) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (url case final url?)
                        OutlinedButton.icon(
                          onPressed: () => openLink(context, url),
                          icon: const Icon(Icons.open_in_new_rounded, size: 18),
                          label: Text(action!),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.primary,
                            side: BorderSide(
                              color: colors.primary.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      if (copy case final copy?)
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: copy));
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '"$copy"를 복사했어요. 이름 칸에 붙여 넣어 주세요.',
                                ),
                              ),
                            );
                          },
                          icon: const Icon(
                            Icons.content_copy_rounded,
                            size: 18,
                          ),
                          label: Text('"$copy" 복사'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.onSurface,
                            side: BorderSide(color: colors.outlineVariant),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
