import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../mail/mail_account.dart';
import '../widgets.dart';
import 'help.dart';

/// 메일 연동, on one screen as in mockup B: the linked accounts, then a
/// switch between Naver, Gmail and Outlook with that service's sign-in.
/// Any number of accounts can be linked, several per service too.
class MailProviderScreen extends StatefulWidget {
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

  /// Saves the new account and shows its unread mails.
  final Future<void> Function(MailAccount account, Unread unread) onAdded;
  final Future<void> Function(MailAccount account) onRemoved;

  @override
  State<MailProviderScreen> createState() => _MailProviderScreenState();
}

class _MailProviderScreenState extends State<MailProviderScreen> {
  // The first service with nothing linked yet, as the likeliest to add.
  late var _service = MailService.values.firstWhere(
    (s) => !widget.accounts.any((a) => a.service == s),
    orElse: () => MailService.naver,
  );

  Future<void> _disconnect(MailAccount account) async {
    await account.revoke();
    await widget.onRemoved(account);
    if (!mounted) return;
    // Back home, where the account list redraws.
    Navigator.popUntil(context, (route) => route.isFirst);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${account.address} 연결을 해제했어요')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final header = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final linked = widget.accounts;
    return AppPage(
      trail: [...widget.from, '메일 연동'],
      children: [
        const ScreenTitle('', '메일 연동'),
        const SizedBox(height: 20),
        if (linked.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
            child: Text('연결한 계정', style: header),
          ),
          VoiceCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, account) in linked.indexed) ...[
                  if (i > 0)
                    Divider(
                      height: 0.5,
                      thickness: 0.5,
                      indent: 60,
                      color: colors.outlineVariant,
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                    child: Row(
                      children: [
                        ServiceBadge(
                          account.service.mark,
                          account.service.color,
                          size: 30,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            account.address,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 17),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _disconnect(account),
                          style: TextButton.styleFrom(
                            foregroundColor: colors.error,
                          ),
                          child: const Text('연결 해제'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
          child: Text(
            linked.isEmpty ? '어떤 메일을 연결할까요?' : '다른 계정 추가하기',
            style: header,
          ),
        ),
        SegmentedButton<MailService>(
          showSelectedIcon: false,
          segments: [
            for (final s in MailService.values)
              ButtonSegment(
                value: s,
                label: Text(s.label.replaceAll(' 메일', '')),
              ),
          ],
          selected: {_service},
          onSelectionChanged: (picked) =>
              setState(() => _service = picked.first),
          style: SegmentedButton.styleFrom(
            backgroundColor: colors.surfaceContainer,
            selectedBackgroundColor: colors.primary,
            selectedForegroundColor: colors.onPrimary,
            side: BorderSide(color: colors.outlineVariant),
          ),
        ),
        const SizedBox(height: 12),
        // Keyed by service so switching starts with empty fields.
        _ConnectForm(
          key: ValueKey(_service),
          service: _service,
          onAdded: widget.onAdded,
        ),
      ],
    );
  }
}

/// Signs in to one mail service over IMAP: Naver with an app password,
/// Gmail and Outlook with their own sign-in. The password or token stays in
/// the keychain. Linking an address again replaces its saved login.
class _ConnectForm extends StatefulWidget {
  const _ConnectForm({super.key, required this.service, required this.onAdded});

  final MailService service;
  final Future<void> Function(MailAccount account, Unread unread) onAdded;

  @override
  State<_ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends State<_ConnectForm> {
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
      // Back home, where the new account shows.
      Navigator.popUntil(context, (route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${account.address}을 연결했어요. 안 읽은 메일이 ${unread.total}건 있어요',
          ),
        ),
      );
    } catch (error) {
      debugPrint('mail connect failed: $error');
      if (mounted) setState(() => _error = mailError(widget.service, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final service = widget.service;
    final naver = service == MailService.naver;
    // A label column and a borderless input, one row of a white group.
    Widget field(String label, Widget input) => Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(label, style: const TextStyle(fontSize: 15)),
          ),
          Expanded(child: input),
        ],
      ),
    );
    const bare = InputDecoration(
      border: InputBorder.none,
      contentPadding: EdgeInsets.symmetric(vertical: 14),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (naver) ...[
          VoiceCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                _SetupStep(
                  number: 1,
                  title: '2단계 인증 켜고 애플리케이션 비밀번호 만들기',
                  detail:
                      '보안설정에서 2단계 인증의 [관리] → 애플리케이션 비밀번호 관리에서 '
                      '"직접 입력"을 고르고, 이름에 "Alpha Mail"을 붙여 넣어 [생성]을 눌러요. '
                      '"올바르지 않은 접근"이 뜨면 naver.com에서 내 프로필 → 네이버ID → '
                      '보안설정으로 들어가 주세요.',
                  action: '네이버 보안설정 열기',
                  url: naverSecurity,
                  copy: 'Alpha Mail',
                ),
                _SetupStep(
                  number: 2,
                  title: 'IMAP/SMTP 사용 켜기',
                  detail: '"IMAP/SMTP 사용"을 "사용함"으로 고르고 저장해요.',
                  action: '네이버 IMAP 설정 열기',
                  url: naverMail,
                ),
                const _SetupStep(
                  number: 3,
                  title: '아래에 아이디와 애플리케이션 비밀번호 넣기',
                  detail: '평소 로그인 비밀번호로는 연결되지 않아요.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AutofillGroup(
            child: VoiceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  field(
                    '아이디',
                    TextField(
                      controller: _id,
                      enabled: !_busy,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: bare.copyWith(
                        hintText: '네이버 아이디',
                        suffixText: '@naver.com  ',
                      ),
                    ),
                  ),
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: 16,
                    color: colors.outlineVariant,
                  ),
                  field(
                    '앱 비밀번호',
                    TextField(
                      controller: _password,
                      enabled: !_busy,
                      obscureText: _hidden,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _connect(),
                      decoration: bare.copyWith(
                        hintText: '애플리케이션 비밀번호',
                        suffixIcon: IconButton(
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
                  ),
                ],
              ),
            ),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '버튼을 누르면 ${service == MailService.outlook ? '마이크로소프트' : '구글'} '
              '로그인 화면이 열려요. 계정을 고르고 메일 접근을 허용하면 바로 연결돼요. '
              '앱 비밀번호나 IMAP 설정은 필요 없어요.',
              style: hint.copyWith(fontSize: 15, height: 1.5),
            ),
          ),
        if (_error case final error?) ...[
          const SizedBox(height: 12),
          ProblemText(
            error,
            style: TextStyle(color: colors.error, height: 1.5),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : Text(switch (service) {
                  MailService.naver => '네이버 연결하기',
                  MailService.gmail => 'Google로 로그인',
                  MailService.outlook => 'Microsoft로 로그인',
                }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.lock_outline_rounded,
                  size: 14,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  naver
                      ? '비밀번호는 이 기기의 보안 저장소에만 저장돼요. '
                            '메일은 다른 서버를 거치지 않고 네이버와 직접 주고받아요.'
                      : '비밀번호는 앱이 보지 않아요. 받은 접근 권한만 이 기기의 '
                            '보안 저장소에 저장하고, 메일은 메일 서버와 직접 주고받아요.',
                  style: hint.copyWith(height: 1.4),
                ),
              ),
            ],
          ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 13,
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
