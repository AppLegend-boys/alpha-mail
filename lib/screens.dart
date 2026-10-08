import 'dart:math' as math;

import 'package:flutter/material.dart';

// ponytail: every screen here runs on mock mail until mail sync and TTS exist.

/// Amber for offline / waiting states (design 06).
const amber = Color(0xfff2a93b);
const amberCard = Color(0xff2a2218);

class Mail {
  const Mail(this.from, this.subject, this.body, this.length, this.draft);
  final String from;
  final String subject;
  final String body;

  /// How long reading it aloud takes, shown beside the waveform.
  final String length;
  final String draft;
}

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
  const _Page({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: children,
      ),
    ),
  );
}

/// 03 — reads one unread mail aloud, with a waveform while "playing".
class BriefingScreen extends StatefulWidget {
  const BriefingScreen({super.key, this.index = 0});
  final int index;

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
    if (_index == mockMails.length - 1) {
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
    final mail = mockMails[_index];
    return _Page(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '네이버메일 · ${_index + 1} / ${mockMails.length}',
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
            MaterialPageRoute(builder: (_) => ReplyScreen(mail: mail)),
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
  const ReplyScreen({super.key, required this.mail});
  final Mail mail;

  @override
  State<ReplyScreen> createState() => _ReplyScreenState();
}

class _ReplyScreenState extends State<ReplyScreen> {
  bool _playing = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Page(
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
  const OfflineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Page(
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
            MaterialPageRoute(builder: (_) => const BriefingScreen()),
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
