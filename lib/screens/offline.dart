import 'package:flutter/material.dart';

import '../widgets.dart';
import 'mail_view.dart';

/// 06 — cached briefing while offline; sending waits for a connection.
class OfflineScreen extends StatelessWidget {
  const OfflineScreen({super.key, required this.from});
  final List<String> from;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppPage(
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
          color: const Color(0xffffe9e3),
          borderColor: const Color(0xfff5c2b3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '답장 발송은 대기 중',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Color(0xffc2410c),
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
