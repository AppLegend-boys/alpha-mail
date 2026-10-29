import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import 'mail.dart';

/// Summarises mail on the phone with Gemma 4 E2B on LiteRT-LM, on the GPU
/// when it can. The model is downloaded once; mail never leaves the device.
class Summarizer {
  Summarizer._();
  static final instance = Summarizer._();

  static const _url =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
  static const _file = 'gemma-4-E2B-it.litertlm';
  static const sizeLabel = '2.6GB';

  /// Longer bodies are cut: reading the input is most of the wait, and the
  /// point of a mail is almost always near the top.
  static const _maxBody = 2500;

  /// Download percentage while the model is being fetched, else null.
  final progress = ValueNotifier<int?>(null);

  /// The last download stopped without finishing.
  bool failed = false;

  static const _group = 'summary';

  /// Fetched by the OS downloader with a notification, like the speech
  /// models, so it keeps going while the app is closed. flutter_gemma's own
  /// downloader can't: a file that finishes while the app is closed is
  /// never marked installed and would be fetched again.
  static final _task = bd.DownloadTask(
    taskId: 'summary-model',
    url: _url,
    baseDirectory: bd.BaseDirectory.applicationSupport,
    directory: 'models/summary',
    filename: _file,
    group: _group,
    updates: bd.Updates.statusAndProgress,
    // Android stops workers after 9 minutes; pausing lets it resume.
    allowPause: true,
    retries: 3,
  );

  /// Set up on first use rather than at launch, which most runs never need.
  Future<void>? _setup;
  Future<void> _ready() => _setup ??= _init();

  Future<void> _init() async {
    final downloader = bd.FileDownloader();
    downloader
      ..registerCallbacks(
        group: _group,
        taskStatusCallback: _onStatus,
        taskProgressCallback: (update) {
          if (update.progress >= 0) {
            progress.value = (update.progress * 100).floor();
          }
        },
      )
      ..configureNotificationForGroup(
        _group,
        running: const bd.TaskNotification(
          '요약 모델을 내려받고 있어요',
          '{progress} · 앱을 닫아도 계속 받아요',
        ),
        complete: const bd.TaskNotification('요약 모델을 다 받았어요', '메일을 열면 바로 요약해요'),
        error: const bd.TaskNotification('요약 모델을 받지 못했어요', '앱을 열고 다시 받아 주세요'),
        progressBar: true,
      );
    // Leftovers of flutter_gemma's own downloader, used by an early build.
    await downloader.cancelAll(group: 'smart_downloads');
    // Still running from an earlier session, or paused by Android.
    if (await downloader.taskForId(_task.taskId) != null) progress.value = 0;
    final paused = await downloader.database.allRecordsWithStatus(
      bd.TaskStatus.paused,
      group: _group,
    );
    for (final record in paused) {
      if (record.task case final bd.DownloadTask task
          when await downloader.resume(task)) {
        progress.value ??= (record.progress * 100).floor();
      }
    }
    await FlutterGemma.initialize();
  }

  void _onStatus(bd.TaskStatusUpdate update) {
    switch (update.status) {
      case bd.TaskStatus.complete:
        failed = false;
        progress.value = null;
      case bd.TaskStatus.failed || bd.TaskStatus.notFound:
        debugPrint(
          'summary model download failed: '
          '${update.responseStatusCode} ${update.exception?.description}',
        );
        failed = true;
        progress.value = null;
      case bd.TaskStatus.canceled:
        progress.value = null;
      default:
    }
  }

  Future<File> get _path async => File(await _task.filePath());

  Future<InferenceChat>? _chat;
  final _done = <String, String>{};

  /// One summary at a time; the model holds a single session.
  Future<void> _lock = Future.value();

  /// The OS downloader writes the file under its name only once complete.
  Future<bool> get installed async {
    await _ready();
    return (await _path).exists();
  }

  /// Starts the download and returns; [progress] follows it.
  Future<void> download() async {
    await _ready();
    if (progress.value != null) return;
    failed = false;
    progress.value = 0;
    final downloader = bd.FileDownloader();
    // Lets the progress notification show while the app is closed; the
    // download works without it.
    await downloader.permissions.request(bd.PermissionType.notifications);
    if (!await downloader.enqueue(_task)) {
      failed = true;
      progress.value = null;
    }
  }

  Future<InferenceChat> _open() async {
    await _ready();
    // Registers the downloaded file in place and marks it active.
    await FlutterGemma.installModel(
      modelType: ModelType.gemmaIt,
    ).fromFile((await _path).path).install();
    InferenceModel model;
    try {
      model = await FlutterGemma.getActiveModel(
        maxTokens: 4096,
        preferredBackend: PreferredBackend.gpu,
      );
    } catch (e) {
      debugPrint('GPU model failed, using CPU: $e');
      model = await FlutterGemma.getActiveModel(
        maxTokens: 4096,
        preferredBackend: PreferredBackend.cpu,
      );
    }
    return model.createChat(temperature: 0.2, topK: 1);
  }

  /// The summary of [mail] so far, growing as the model writes it.
  Stream<String> summarize(Mail mail) async* {
    final key = '${mail.account?.address}/${mail.uid}/${mail.subject}';
    if (_done[key] case final summary?) {
      yield summary;
      return;
    }
    final prior = _lock;
    final release = Completer<void>();
    _lock = release.future;
    await prior;
    InferenceChat? chat;
    var finished = false;
    try {
      chat = await (_chat ??= _open().catchError((Object e) {
        _chat = null;
        throw e;
      }));
      await chat.clearHistory();
      await chat.addQueryChunk(Message.text(text: _prompt(mail), isUser: true));
      var text = '';
      await for (final response in chat.generateChatResponseAsync()) {
        if (response is TextResponse) {
          text += response.token;
          yield text.trim();
        }
      }
      finished = true;
      _done[key] = text.trim();
    } finally {
      // Left the screen mid-summary: stop so the next one isn't kept waiting.
      if (!finished) await chat?.stopGeneration().catchError((_) {});
      release.complete();
    }
  }

  static String _prompt(Mail mail) {
    // Links mean nothing read aloud and cost tokens, so the model never sees them.
    final text = mail.body.replaceAll(RegExp(r'(https?://|www\.)\S+'), '');
    final body = text.length > _maxBody
        ? '${text.substring(0, _maxBody)}…'
        : text;
    return '다음 메일을 한국어 2~3문장으로 요약해 주세요. '
        '소리 내어 읽어 줄 글이니 목록 기호나 마크다운 없이 자연스러운 문장으로 쓰고, '
        '누가 보냈는지, 왜 보냈는지, 핵심 내용 순서로 써 주세요. '
        '날짜·마감·금액이 있으면 꼭 넣고, 링크·웹 주소·수신 거부 안내는 빼 주세요.\n\n'
        '보낸 사람: ${mail.from}\n제목: ${mail.subject}\n\n$body';
  }
}
