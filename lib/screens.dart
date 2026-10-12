import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'naver_mail.dart';

// ponytail: every screen here runs on mock mail until mail sync and TTS exist.

/// Amber for offline / waiting states (design 06).
const amber = Color(0xfff2a93b);
const amberCard = Color(0xff2a2218);

class Mail {
  const Mail(
    this.from,
    this.subject,
    this.body,
    this.length,
    this.draft, {
    this.html,
  });
  final String from;
  final String subject;
  final String body;

  /// How long reading it aloud takes, shown beside the waveform.
  final String length;
  final String draft;

  /// Original HTML body, shown as sent so its images and layout survive;
  /// [body] stays the plain text to read aloud.
  final String? html;
}

/// Desktop is mail-first for now: voice recognition and its models are off.
final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// First crumb of every menu path, named after what home is on this device.
final homeLabel = isDesktop ? '메일 홈' : '음성 홈';

const mockMails = [
  Mail(
    '프로젝트 운영팀',
    '오늘 일정 안내',
    '오늘 오후 3시 기획 회의가\n4층 회의실에서 열립니다.\n자료를 미리 확인해 주세요.',
    '0:18',
    '안녕하세요,\n메일 확인했습니다.\n오늘 오후 회의에\n참석하겠습니다.\n감사합니다.',
  ),
  Mail(
    '김서연 매니저',
    '견적서 회신 부탁드립니다',
    '지난주 요청하신 견적서를 첨부합니다.\n금요일까지 검토 후\n회신 부탁드립니다.',
    '0:14',
    '안녕하세요,\n견적서 잘 받았습니다.\n금요일까지 검토 후\n회신드리겠습니다.',
  ),
  Mail(
    '네이버페이',
    '결제 완료 안내',
    '주문하신 상품의 결제가\n정상적으로 완료되었습니다.',
    '0:09',
    '확인했습니다.\n감사합니다.',
  ),
];

/// Rounded dark card with a hairline border, the base of every block.
class VoiceCard extends StatelessWidget {
  const VoiceCard({
    super.key,
    required this.child,
    this.color,
    this.borderColor,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(14);
    return Material(
      color: color ?? colors.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: borderColor ?? colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Small grey label above a big white title, as on every design screen.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.label, this.title, {super.key});
  final String label;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            height: 1.35,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

/// The two big buttons at the bottom: outlined left, mint right.
class ButtonPair extends StatelessWidget {
  const ButtonPair({
    super.key,
    required this.left,
    required this.right,
    required this.onLeft,
    required this.onRight,
  });

  final String left;
  final String right;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: onLeft,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              foregroundColor: colors.onSurface,
              backgroundColor: colors.surfaceContainer,
              side: BorderSide(color: colors.outlineVariant),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(left),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(onPressed: onRight, child: Text(right)),
        ),
      ],
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.trail, required this.children});

  /// Menu path from home to this screen, shown top left.
  final List<String> trail;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(titleSpacing: 0, title: _Trail(trail)),
    body: SafeArea(
      top: false,
      // Desktop windows: keep the column readable instead of edge to edge.
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: children,
          ),
        ),
      ),
    ),
  );
}

/// Breadcrumb like "메일 홈 › 메일 연동하기 › 네이버 메일". Each crumb is one
/// route on the stack, so tapping one pops back to it.
class _Trail extends StatelessWidget {
  const _Trail(this.trail);
  final List<String> trail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '현재 위치',
      child: Row(
        children: [
          for (final (i, crumb) in trail.indexed) ...[
            if (i > 0)
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            Flexible(
              child: i == trail.length - 1
                  ? Text(
                      crumb,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : TextButton(
                      onPressed: () {
                        var back = trail.length - 1 - i;
                        Navigator.popUntil(context, (_) => back-- == 0);
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: colors.onSurfaceVariant,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 36),
                        textStyle: const TextStyle(fontSize: 15),
                      ),
                      child: Text(crumb, overflow: TextOverflow.ellipsis),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 03 — reads one unread mail aloud, with a waveform while "playing".
class BriefingScreen extends StatefulWidget {
  const BriefingScreen({
    super.key,
    required this.from,
    this.index = 0,
    this.mails = mockMails,
  });

  /// Menu path of the screen that opened this one.
  final List<String> from;
  final int index;
  final List<Mail> mails;

  @override
  State<BriefingScreen> createState() => _BriefingScreenState();
}

class _BriefingScreenState extends State<BriefingScreen>
    with SingleTickerProviderStateMixin {
  late int _index = widget.index;
  late final _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  void _next() {
    if (_index == widget.mails.length - 1) {
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('안 읽은 메일을 모두 들었어요')));
      return;
    }
    setState(() => _index++);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mail = widget.mails[_index];
    return _Page(
      trail: [...widget.from, '메일 읽기'],
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '네이버메일 · ${_index + 1} / ${widget.mails.length}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: colors.primary,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          mail.from,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          mail.subject,
          style: TextStyle(fontSize: 16, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Divider(color: colors.outlineVariant),
        const SizedBox(height: 16),
        if (mail.html case final html?)
          _MailHtml(html)
        else
          Text(mail.body, style: const TextStyle(fontSize: 18, height: 1.7)),
        const SizedBox(height: 24),
        VoiceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '지금 읽어주는 중',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: AnimatedBuilder(
                        animation: _wave,
                        builder: (context, _) => CustomPaint(
                          painter: _WavePainter(_wave.value, colors.primary),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    mail.length,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ButtonPair(
          left: '다음 메일',
          right: '답장하기',
          onLeft: _next,
          onRight: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  ReplyScreen(mail: mail, from: [...widget.from, '메일 읽기']),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '"답장해줘" 또는 "다음 메일"',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Renders a mail's HTML as its sender laid it out, images included.
/// Scripts stay off and links open in the browser, never inside the app.
class _MailHtml extends StatefulWidget {
  const _MailHtml(this.html);
  final String html;

  @override
  State<_MailHtml> createState() => _MailHtmlState();
}

class _MailHtmlState extends State<_MailHtml> {
  late final _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.disabled)
    ..setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          if (!request.url.startsWith('http')) {
            return NavigationDecision.navigate;
          }
          launchUrl(Uri.parse(request.url));
          return NavigationDecision.prevent;
        },
      ),
    );

  // Mails are designed on white, so they keep a white page of their own
  // inside the dark app instead of being recoloured.
  String get _page =>
      '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>html,body{margin:0;background:#fff;color:#111}'
      'body{padding:16px;font:15px/1.6 -apple-system,sans-serif;'
      'overflow-wrap:anywhere}img{max-width:100%;height:auto}</style>'
      '</head><body>${widget.html}</body></html>';

  @override
  void initState() {
    super.initState();
    _web.loadHtmlString(_page);
  }

  // "다음 메일" reuses this widget with the next mail's HTML.
  @override
  void didUpdateWidget(_MailHtml old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _web.loadHtmlString(_page);
  }

  // ponytail: fixed height with its own scroll; size to the content via a
  // height probe if long mails feel cramped.
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SizedBox(height: 520, child: WebViewWidget(controller: _web)),
  );
}

/// Bars whose heights ripple left to right, like the design's waveform.
class _WavePainter extends CustomPainter {
  _WavePainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 28;
    final gap = size.width / bars;
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.min(4, gap * 0.5)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars; i++) {
      final phase = (i / bars + t) * 2 * math.pi;
      final h =
          size.height *
          (0.2 +
              0.8 *
                  (0.5 + 0.5 * math.sin(phase * 2) * math.cos(i * 1.7)).abs());
      final x = gap * (i + 0.5);
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.t != t;
}

/// 04 — reads back a reply draft; nothing is sent without a clear yes.
class ReplyScreen extends StatefulWidget {
  const ReplyScreen({super.key, required this.mail, required this.from});
  final Mail mail;
  final List<String> from;

  @override
  State<ReplyScreen> createState() => _ReplyScreenState();
}

class _ReplyScreenState extends State<ReplyScreen> {
  bool _playing = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Page(
      trail: [...widget.from, '답장'],
      children: [
        ScreenTitle('${widget.mail.from}에게', '답장 초안'),
        const SizedBox(height: 20),
        VoiceCard(
          padding: const EdgeInsets.all(18),
          child: Text(
            widget.mail.draft,
            style: const TextStyle(fontSize: 18, height: 1.7),
          ),
        ),
        const SizedBox(height: 14),
        VoiceCard(
          onTap: () => setState(() => _playing = !_playing),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: colors.primary,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '초안 다시 듣기',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              Text('0:06', style: TextStyle(color: colors.onSurfaceVariant)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          '이대로 보낼까요?',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 14),
        ButtonPair(
          left: '다시 말하기',
          right: '확인 후 보내기',
          onLeft: () => Navigator.pop(context),
          onRight: () {
            Navigator.popUntil(context, (route) => route.isFirst);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('보냈어요 (목업이라 실제로 발송되지 않아요)')),
            );
          },
        ),
        const SizedBox(height: 12),
        Text(
          '사용자가 말해야 발송됩니다',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: colors.primary),
        ),
      ],
    );
  }
}

/// 06 — cached briefing while offline; sending waits for a connection.
class OfflineScreen extends StatelessWidget {
  const OfflineScreen({super.key, required this.from});
  final List<String> from;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Page(
      trail: [...from, '오프라인 화면'],
      children: [
        VoiceCard(
          color: amberCard,
          borderColor: amber.withValues(alpha: 0.6),
          child: const Row(
            children: [
              Icon(Icons.circle, size: 12, color: amber),
              SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '오프라인',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: amber,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text('오전 9:12 이후 연결 끊김', style: TextStyle(fontSize: 13)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          '최근 브리핑',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        VoiceCard(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BriefingScreen(from: [...from, '오프라인 화면']),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '네이버메일 · 3건',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                '저장된 메일 요약을 재생할 수 있어요.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              const Text(
                '최신 내용이 아닐 수 있습니다.',
                style: TextStyle(color: amber, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        VoiceCard(
          color: const Color(0xff2a1d18),
          borderColor: const Color(0xff4a3127),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '답장 발송은 대기 중',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Color(0xffff9e7a),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '연결되면 다시 확인해 주세요.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('아직 연결되지 않았어요 (목업)'))),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            foregroundColor: colors.onSurface,
            backgroundColor: colors.surfaceContainer,
            side: BorderSide(color: colors.outlineVariant),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text(
            '연결 다시 확인',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// First step of connecting: pick the mail service. Only Naver works yet.
class MailProviderScreen extends StatelessWidget {
  const MailProviderScreen({
    super.key,
    required this.from,
    this.connected,
    required this.onChanged,
  });

  final List<String> from;
  final String? connected;
  final void Function(NaverMail? account, List<Mail> unread) onChanged;

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
            CircleAvatar(
              radius: 20,
              backgroundColor: markColor,
              child: Text(
                mark,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
            ),
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
              _StatusChip('곧 지원', colors.onSurfaceVariant)
            else ...[
              _StatusChip(
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
    return _Page(
      trail: [...from, '메일 연동하기'],
      children: [
        const ScreenTitle('메일 연동하기', '어떤 메일을 연결할까요?'),
        const SizedBox(height: 20),
        provider(
          '네이버 메일',
          'N',
          const Color(0xff03c75a),
          connected == null ? '아이디와 애플리케이션 비밀번호로 연결해요' : '연결됨 · $connected',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MailConnectScreen(
                from: [...from, '메일 연동하기'],
                connected: connected,
                onChanged: onChanged,
              ),
            ),
          ),
          linked: connected != null,
        ),
        provider('Gmail', 'G', const Color(0xffea4335), '구글 계정으로 연결해요'),
        provider('Outlook', 'O', const Color(0xff0078d4), '마이크로소프트 계정으로 연결해요'),
      ],
    );
  }
}

/// Signs in to Naver Mail over IMAP; the password stays in the keychain.
class MailConnectScreen extends StatefulWidget {
  const MailConnectScreen({
    super.key,
    required this.from,
    this.connected,
    required this.onChanged,
  });

  final List<String> from;

  /// Address of the account already connected, if any.
  final String? connected;

  /// Called with the new account and its unread mails, or null on disconnect.
  final void Function(NaverMail? account, List<Mail> unread) onChanged;

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
    if (_id.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = '아이디와 비밀번호를 모두 넣어 주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final account = NaverMail(_id.text, _password.text);
    try {
      // Fetching doubles as the login check.
      final unread = await account.fetchUnread();
      await account.save();
      widget.onChanged(account, unread);
      if (!mounted) return;
      // Back home past the provider list.
      Navigator.popUntil(context, (route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${account.address}을 연결했어요 · 안 읽은 메일 ${unread.length}건',
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = naverMailError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    await NaverMail.forget();
    widget.onChanged(null, const []);
    if (!mounted) return;
    // Back home past the provider list.
    Navigator.popUntil(context, (route) => route.isFirst);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('메일 연결을 해제했어요')));
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
    final connected = widget.connected;
    return _Page(
      trail: [...widget.from, '네이버 메일'],
      children: [
        const ScreenTitle('메일 연동하기', '네이버 메일'),
        const SizedBox(height: 20),
        if (connected != null) ...[
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
                      Text(connected, style: hint),
                    ],
                  ),
                ),
                TextButton(onPressed: _disconnect, child: const Text('연결 해제')),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text('다른 계정으로 바꾸기', style: hint),
          const SizedBox(height: 12),
        ] else ...[
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
            url: _naverSecurity,
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
            url: _naverMail,
          ),
          const SizedBox(height: 10),
          const _SetupStep(
            number: 3,
            title: '아래에 아이디와 애플리케이션 비밀번호 넣기',
            detail: '1번에서 만든 비밀번호를 그대로 붙여 넣어요. 평소 로그인 비밀번호로는 연결되지 않아요.',
          ),
          const SizedBox(height: 24),
        ],
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
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: TextStyle(color: colors.error, height: 1.5),
            ),
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
              : const Text('연결하기'),
        ),
        const SizedBox(height: 14),
        Text(
          '비밀번호는 이 기기의 보안 저장소(키체인)에만 저장돼요.\n'
          '메일은 다른 서버를 거치지 않고 네이버와 직접 주고받아요.',
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
final _naverSecurity = Uri.parse(
  'https://nid.naver.com/user2/help/myInfoV2?m=viewSecurity&lang=ko_KR',
);
final _naverMail = Uri.parse('https://mail.naver.com/v2/settings/smtp/imap');

/// Opens [url] in the browser; if that fails, offers the address to copy
/// so the user is never left with a button that silently does nothing.
Future<void> _open(BuildContext context, Uri url) async {
  final messenger = ScaffoldMessenger.of(context);
  var opened = false;
  try {
    opened = await launchUrl(url);
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

/// One numbered setup step, with a button that opens the Naver page for it.
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
                          onPressed: () => _open(context, url),
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

/// Small pill beside a mail service: 연결됨, 연결 안 됨 or 곧 지원.
class _StatusChip extends StatelessWidget {
  const _StatusChip(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
    ),
  );
}
