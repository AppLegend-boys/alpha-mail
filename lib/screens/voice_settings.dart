import 'package:flutter/material.dart';

import '../voice/model_downloads.dart';
import '../voice/speech.dart';
import '../widgets.dart';

/// Loads [m], or asks to download it first. The current model stays in use
/// while the OS downloads in the background.
Future<void> useModel(
  BuildContext context,
  Recognizer speech,
  ModelDownloads downloads,
  SpeechModel m,
) async {
  if (!await speech.switchTo(m) && context.mounted) {
    await requestDownload(context, speech, downloads, m);
  }
}

/// Asks, then hands the model's missing files to the OS downloader.
Future<void> requestDownload(
  BuildContext context,
  Recognizer speech,
  ModelDownloads downloads,
  SpeechModel model,
) async {
  if (downloads.downloading case final busyWith?) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${busyWith.label} 모델을 받는 중이에요. 다 받은 뒤에 골라 주세요.')),
    );
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${model.label} 모델을 내려받을까요?'),
      content: Text(
        '${model.title} 모델 파일 ${model.size}를 한 번 내려받아요. '
        'Wi-Fi 연결을 권장해요.\n\n'
        '${isDesktop ? '앱을 닫아도 다음에 열면 이어서 받아요. ' : '화면이 꺼지거나 다른 앱을 써도 계속 받아요. '}'
        '${speech.loaded ? '받는 동안에는 지금 모델을 그대로 쓸 수 있어요. ' : ''}'
        '받은 뒤에는 인터넷 없이 이 기기 안에서만 인식해요.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('나중에'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('내려받기'),
        ),
      ],
    ),
  );
  if (ok == true) await downloads.start(model);
}

/// 음성 설정: pick, download or delete a speech model.
class VoiceSettingsScreen extends StatelessWidget {
  const VoiceSettingsScreen({
    super.key,
    required this.from,
    required this.speech,
    required this.downloads,
  });

  /// Menu path to this screen.
  final List<String> from;
  final Recognizer speech;
  final ModelDownloads downloads;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([speech, downloads]),
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final locked = speech.busy || speech.listening;
      return AppPage(
        trail: [...from, '음성 설정'],
        children: [
          const ScreenTitle('음성 설정', '어떤 모델로 알아들을까요?'),
          const SizedBox(height: 8),
          Text(
            locked
                ? '듣는 중이거나 모델을 적용 중일 때는 바꿀 수 없어요'
                : '받은 모델은 인터넷 없이 이 휴대폰 안에서만 인식해요',
            style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          if (downloads.shown != null) ...[
            DownloadBanner(downloads),
            const SizedBox(height: 16),
          ],
          for (final m in SpeechModel.values) ...[
            _modelCard(context, m, colors, locked),
            const SizedBox(height: 12),
          ],
        ],
      );
    },
  );

  /// Deletes [model]'s files after asking.
  Future<void> _delete(BuildContext context, SpeechModel model) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${model.label} 모델을 삭제할까요?'),
        content: Text('휴대폰 공간 ${model.size}가 비워져요. 다시 쓰려면 새로 내려받아야 해요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final deleted = await speech.delete(
      model,
      removed: () => downloads.forget(model),
    );
    if (!deleted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${model.label} 모델을 삭제하지 못했어요. 다시 시도해 주세요.')),
      );
    }
  }

  Widget _modelCard(
    BuildContext context,
    SpeechModel m,
    ColorScheme colors,
    bool locked,
  ) {
    final onPhone = downloads.onPhone.contains(m);
    final inUse = m == speech.model && speech.loaded;
    final downloading = downloads.downloading == m;
    final deleting = speech.deleting == m;
    final applying = deleting || speech.busy && m == speech.model;
    return VoiceCard(
      borderColor: inUse ? colors.primary : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${m.label} · ${m.title}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (inUse)
                Text(
                  '사용 중',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: colors.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${m.blurb} · ${m.recommend} · ${m.size}',
            style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (applying)
                Row(
                  children: [
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      deleting ? '삭제 중…' : '적용 중…',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                )
              else if (downloading)
                Text(
                  '내려받는 중 ${(downloads.fraction * 100).floor()}%',
                  style: TextStyle(color: colors.onSurfaceVariant),
                )
              else if (!onPhone)
                OutlinedButton.icon(
                  onPressed: locked || downloads.downloading != null
                      ? null
                      : () => useModel(context, speech, downloads, m),
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('내려받기'),
                )
              else if (!inUse)
                FilledButton(
                  onPressed: locked
                      ? null
                      : () => useModel(context, speech, downloads, m),
                  // The theme's full-width minimum has no width to fill in
                  // a Row, which threw in layout and left the screen blank.
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  child: const Text('이 모델 쓰기'),
                ),
              const Spacer(),
              if (onPhone)
                TextButton.icon(
                  onPressed: locked ? null : () => _delete(context, m),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('삭제'),
                  style: TextButton.styleFrom(foregroundColor: colors.error),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows the background model download without blocking the current model,
/// or why it failed. Only built while [ModelDownloads.shown] is set.
class DownloadBanner extends StatelessWidget {
  const DownloadBanner(this.downloads, {super.key});
  final ModelDownloads downloads;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = downloads.shown!.label;
    final progress = downloads.fraction;
    final percent = (progress * 100).floor();
    final failed = downloads.downloading == null;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: failed ? colors.error : colors.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.downloading_rounded,
                size: 20,
                color: failed ? colors.error : colors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    failed
                        ? '$label 모델을 내려받지 못했어요. 인터넷 연결을 확인해 주세요.'
                        : '$label 모델 내려받는 중 ($percent%)',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: failed ? colors.error : colors.onSurface,
                    ),
                  ),
                ),
              ),
              if (failed) ...[
                TextButton(
                  onPressed: () => downloads.start(downloads.shown!),
                  child: const Text('다시 시도'),
                ),
                TextButton(
                  onPressed: downloads.dismiss,
                  child: const Text('닫기'),
                ),
              ] else
                TextButton(
                  onPressed: downloads.cancel,
                  child: const Text('취소'),
                ),
            ],
          ),
          if (!failed) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: colors.outlineVariant,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '파일 ${downloads.filesDone}/${downloads.shown!.files.length}개 받음 · '
              '${isDesktop ? '앱을 닫아도 이어서 받아요' : '화면을 꺼도 계속 받아요'}',
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
