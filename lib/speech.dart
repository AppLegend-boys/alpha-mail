import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'mail_account.dart';
import 'screens.dart';
import 'tts.dart';

/// Little-endian signed 16-bit PCM to normalized float samples in [-1, 1).
Float32List pcm16ToFloat32(Uint8List bytes) {
  final samples = Float32List(bytes.length ~/ 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}

/// On-device recognisers the user can switch between. None are bundled (the
/// Play Store caps the base app at 200 MB): the OS downloads each one once
/// into app support storage, even with the screen off or the app closed.
/// Not the cache directory: the OS empties that when space runs low, which
/// made users download the same model again.
enum SpeechModel {
  senseVoice(
    '문장 단위',
    'SenseVoice',
    '말을 멈추면 문장으로 적어요',
    '약 240MB',
    '외국어가 섞일 때',
    'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main',
    {'model.int8.onnx': 239233841, 'tokens.txt': 315894},
  ),
  qwen3(
    '고정확도',
    'Qwen3-ASR 0.6B',
    '가장 정확하지만 조금 느려요',
    '약 980MB',
    '정확도가 중요할 때',
    'https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main',
    {
      'conv_frontend.onnx': 44148281,
      'encoder.int8.onnx': 182491662,
      'decoder.int8.onnx': 755914231,
      'tokenizer/merges.txt': 1671853,
      'tokenizer/tokenizer_config.json': 12487,
      'tokenizer/vocab.json': 2776833,
    },
  );

  const SpeechModel(
    this.label,
    this.title,
    this.blurb,
    this.size,
    this.recommend,
    this.url,
    this.files,
  );
  final String label;
  final String title;
  final String blurb;
  final String size;

  /// When to pick this model, shown beside it in the picker.
  final String recommend;
  final String url;

  /// File name → byte size; the size doubles as a completeness check.
  final Map<String, int> files;

  /// One background download per file; `metaData` holds the file's key and
  /// `group` the model's name.
  // ponytail: iOS backs up app support to iCloud; exclude the models with
  // NSURLIsExcludedFromBackupKey if backup size becomes a complaint.
  List<bd.DownloadTask> get tasks => [
    for (final file in files.keys)
      bd.DownloadTask(
        url: '$url/$file',
        baseDirectory: bd.BaseDirectory.applicationSupport,
        directory: file.contains('/')
            ? 'models/$name/${file.substring(0, file.lastIndexOf('/'))}'
            : 'models/$name',
        filename: file.split('/').last,
        group: name,
        metaData: file,
        updates: bd.Updates.statusAndProgress,
        // Android stops workers after 9 minutes; pausing lets it resume.
        allowPause: true,
        retries: 3,
      ),
  ];

  static SpeechModel? forGroup(String group) =>
      values.where((m) => m.name == group).firstOrNull;

  /// Every file is on the phone at full size. Unlike the voice home's check,
  /// this doesn't move files an older build left in the cache.
  Future<bool> get downloaded async {
    for (final task in tasks) {
      final file = File(await task.filePath());
      if (!await file.exists() || await file.length() != files[task.metaData]) {
        return false;
      }
    }
    return true;
  }

  static Future<bool> anyDownloaded() async {
    for (final model in values) {
      if (await model.downloaded) return true;
    }
    return false;
  }
}

/// Runs an offline recogniser on its own isolate so slow models (Qwen3 takes
/// a second or more per sentence on a phone) never freeze the UI.
class _OfflineWorker {
  _OfflineWorker._(this._inbox, this._outbox, this._waiting);

  final ReceivePort _inbox;
  final SendPort _outbox;
  final Queue<Completer<String>> _waiting;

  int get pending => _waiting.length;

  static Future<_OfflineWorker> spawn(
    sherpa.OfflineRecognizerConfig config,
  ) async {
    final inbox = ReceivePort();
    final ready = Completer<SendPort>();
    final waiting = Queue<Completer<String>>();
    inbox.listen((message) {
      if (!ready.isCompleted) {
        message is SendPort
            ? ready.complete(message)
            : ready.completeError(Exception(message));
      } else if (waiting.isNotEmpty) {
        waiting.removeFirst().complete(message as String);
      }
    });
    await Isolate.spawn(_run, (inbox.sendPort, config));
    try {
      return _OfflineWorker._(inbox, await ready.future, waiting);
    } catch (_) {
      inbox.close();
      rethrow;
    }
  }

  Future<String> transcribe(Float32List samples) {
    final result = Completer<String>();
    _waiting.add(result);
    _outbox.send(samples);
    return result.future;
  }

  /// Frees the native model inside the worker; the isolate then exits.
  void dispose() {
    _outbox.send(null);
    _inbox.close();
    for (final result in _waiting) {
      result.complete('');
    }
    _waiting.clear();
  }

  static void _run((SendPort, sherpa.OfflineRecognizerConfig) args) {
    final (reply, config) = args;
    final sherpa.OfflineRecognizer recognizer;
    try {
      sherpa.initBindings();
      recognizer = sherpa.OfflineRecognizer(config);
    } catch (error) {
      reply.send('$error');
      return;
    }
    final inbox = ReceivePort();
    reply.send(inbox.sendPort);
    inbox.listen((samples) {
      if (samples is! Float32List) {
        recognizer.free();
        inbox.close();
        return;
      }
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      reply.send(recognizer.getResult(stream).text.trim());
      stream.free();
    });
  }
}

class SpeechScreen extends StatefulWidget {
  const SpeechScreen({super.key});

  @override
  State<SpeechScreen> createState() => _SpeechScreenState();
}

class _SpeechScreenState extends State<SpeechScreen>
    with SingleTickerProviderStateMixin {
  final _recorder = AudioRecorder();
  SpeechModel _model = SpeechModel.senseVoice;
  // Utterance model fed by voice-activity segments.
  _OfflineWorker? _offline;
  SpeechModel? _downloadingModel;
  final _fileProgress = <String, double>{};
  final _failedFiles = <String>{};
  SpeechModel? _failedDownload;
  sherpa.VoiceActivityDetector? _vad;
  final _vadPending = <double>[];
  StreamSubscription<Uint8List>? _audioSub;
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  final _scaffold = GlobalKey<ScaffoldState>();
  final _content = GlobalKey<NavigatorState>();

  /// What the user has said since the mic went on.
  String _heard = '';
  bool _opening = false;

  /// Saying "읽어드릴까요?" before the mic turns on.
  bool _asking = false;
  String _partial = '';
  String _status = '모델을 준비하고 있어요';
  bool _busy = true;

  /// Being deleted, so its card says so instead of 적용 중.
  SpeechModel? _deleting;
  bool _listening = false;
  bool _error = false;

  /// Linked mail accounts, and each one's unread mails or load error by
  /// address; mock mails until one is linked.
  List<MailAccount> _accounts = const [];
  final Map<String, List<Mail>> _unread = {};
  final Map<String, int> _unreadTotal = {};
  final Map<String, String> _mailErrors = {};

  /// Unread mails of every account, newest first.
  List<Mail> get _mails => _accounts.isEmpty
      ? mockMails
      : ([for (final a in _accounts) ...?_unread[a.address]]..sort(
          (a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)),
        ));

  /// Still fetching some account, with nothing failed or loaded for it.
  String? get _mailError =>
      _mailErrors.isEmpty ? null : _mailErrors.values.join('\n');

  String get _source => switch (_accounts) {
    [] => '예시 메일',
    [final only] => only.service.label,
    _ => '메일 ${_accounts.length}개 계정',
  };

  @override
  void initState() {
    super.initState();
    // Desktop starts with mail only: no recogniser, no model downloads.
    if (!isDesktop) _init();
    _loadMail();
    AppSettings.load().then((settings) {
      if (!mounted) return;
      setState(() => _settings = settings);
      _scheduleCheck();
    });
  }

  AppSettings _settings = const AppSettings();
  Timer? _checker;

  /// Re-fetches every account's unread count as often as 앱 설정 says.
  void _scheduleCheck() {
    _checker?.cancel();
    _checker = _settings.checkMinutes == 0
        ? null
        : Timer.periodic(Duration(minutes: _settings.checkMinutes), (_) {
            for (final account in _accounts) {
              _fetch(account);
            }
          });
  }

  void _openSettings() {
    _closeDrawer();
    _content.currentState?.popUntil((route) => route.isFirst);
    _push(
      section: 'settings',
      SettingsScreen(
        from: [homeLabel],
        accounts: _accounts,
        settings: _settings,
        onChanged: (settings) {
          setState(() => _settings = settings);
          settings.save();
          _scheduleCheck();
        },
        accountsScreen: _providerScreen,
      ),
    );
  }

  Future<void> _loadMail() async {
    final List<MailAccount> accounts;
    try {
      accounts = await MailAccount.loadAll();
    } catch (_) {
      // Without this the accounts just looked unlinked, as if they were lost.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: Text(
              // Only macOS asks before the app may read its keychain item.
              Platform.isMacOS
                  ? '키체인 접근이 허용되지 않아 저장된 메일 계정을 불러오지 못했어요. '
                        '앱을 다시 켜고 허락 창에서 [항상 허용]을 눌러 주세요.'
                  : '저장된 메일 계정을 불러오지 못했어요. 앱을 다시 켜 주세요.',
            ),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _accounts = accounts);
    await Future.wait(accounts.map(_fetch));
  }

  Future<void> _fetch(MailAccount account) async {
    try {
      final unread = await account.fetchUnread();
      if (mounted) setState(() => _setUnread(account, unread));
    } catch (error) {
      final message =
          '${account.address}: ${mailError(account.service, error)}';
      if (mounted) setState(() => _mailErrors[account.address] = message);
    }
  }

  void _setUnread(MailAccount account, Unread unread) {
    _unread[account.address] = unread.mails;
    _unreadTotal[account.address] = unread.total;
    _mailErrors.remove(account.address);
  }

  /// Drops a mail just marked read from its account's unread list.
  void _onRead(Mail mail) {
    final address = mail.account?.address;
    if (!mounted || address == null) return;
    final unread = _unread[address];
    // Opened twice: already counted. Matched by UID, since 전체 메일
    // fetches its own copy of the same mail.
    if (unread == null || !unread.any((m) => m.uid == mail.uid)) return;
    // A new list: the open screens still page through the old one.
    setState(() {
      _unread[address] = [
        for (final m in unread)
          if (m.uid != mail.uid) m,
      ];
      _unreadTotal.update(address, (n) => n - 1);
    });
  }

  void _openConnect() {
    _closeDrawer();
    _content.currentState?.popUntil((route) => route.isFirst);
    _push(section: 'connect', _providerScreen([homeLabel]));
  }

  Widget _providerScreen(List<String> from) => MailProviderScreen(
    from: from,
    accounts: _accounts,
    onAdded: (account, unread) async {
      final accounts = [
        for (final a in _accounts)
          if (a.address != account.address) a,
        account,
      ];
      await MailAccount.saveAll(accounts);
      setState(() {
        _accounts = accounts;
        _setUnread(account, unread);
      });
    },
    onRemoved: (account) async {
      final accounts = [
        for (final a in _accounts)
          if (a.address != account.address) a,
      ];
      await MailAccount.saveAll(accounts);
      setState(() {
        _accounts = accounts;
        _unread.remove(account.address);
        _unreadTotal.remove(account.address);
        _mailErrors.remove(account.address);
      });
    },
  );

  bool get _loaded => _offline != null;

  Future<void> _init() async {
    // Zipformer was dropped; free the ~140 MB older builds downloaded.
    final dropped = Directory(
      '${(await getApplicationSupportDirectory()).path}/models/zipformer',
    );
    if (await dropped.exists()) await dropped.delete(recursive: true);
    await _initDownloads();
    // Start on the first model already on the phone.
    for (final model in SpeechModel.values) {
      if (await _isDownloaded(model)) {
        _model = model;
        break;
      }
    }
    await _loadModel();
    await _refreshOnPhone();
  }

  Future<void> _initDownloads() async {
    final downloader = bd.FileDownloader();
    for (final model in SpeechModel.values) {
      // Per-group callbacks, not the single-listener `updates` stream, which
      // the summary model's downloader (flutter_gemma) also needs.
      downloader.registerCallbacks(
        group: model.name,
        taskStatusCallback: _onDownloadUpdate,
        taskProgressCallback: _onDownloadUpdate,
      );
      downloader.configureNotificationForGroup(
        model.name,
        running: bd.TaskNotification(
          '${model.label} 음성 모델을 내려받고 있어요',
          '파일 {numFinished}/{numTotal}개 받음',
        ),
        complete: bd.TaskNotification(
          '${model.label} 음성 모델을 다 받았어요',
          '앱을 열면 바로 쓸 수 있어요',
        ),
        error: const bd.TaskNotification('음성 모델을 받지 못했어요', '앱을 열고 다시 시도해 주세요'),
        // No bar: a group bar counts files, not bytes, so it disagreed with
        // the app's percentage (Qwen3's 750 MB decoder is one of six files).
        groupNotificationId: model.name,
      );
    }
    // Android stops background workers after 9 minutes and pauses the file;
    // the group notification counts a paused file as finished and said
    // "다 받았어요" mid-download. A foreground service has no such limit.
    await downloader.configure(
      androidConfig: [(bd.Config.runInForeground, bd.Config.always)],
    );
    // Picks up downloads that continued or finished while the app was closed.
    // Killed tasks are restarted by _resumeDownload, not the package, so a
    // file never downloads twice at once.
    await downloader.start(doRescheduleKilledTasks: false);
    for (final model in SpeechModel.values) {
      if ((await downloader.allTasks(group: model.name)).isNotEmpty) {
        await _markFinishedFiles(model);
        if (mounted) setState(() => _downloadingModel = model);
        break;
      }
      if (await (await _pendingMark(model)).exists()) {
        await _resumeDownload(model);
        break;
      }
    }
    if (_downloadingModel == null) await _deleteStaleTempFiles();
  }

  /// A download killed mid-file (app update, force stop) leaves its partial
  /// temp file behind; on one test phone these added up to over 1 GB. Only
  /// runs when nothing is downloading, so no live file is touched.
  Future<void> _deleteStaleTempFiles() async {
    for (final dir in [
      await getApplicationSupportDirectory(),
      await getTemporaryDirectory(),
    ]) {
      // macOS doesn't create the cache folder until something writes there.
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is File &&
            entry.uri.pathSegments.last.startsWith(
              'com.bbflight.background_downloader',
            )) {
          await entry.delete();
        }
      }
    }
  }

  /// Exists while a model is downloading, so a relaunch can pick it back up:
  /// iOS stops background downloads when the app is swiped away.
  Future<File> _pendingMark(SpeechModel model) async => File(
    '${(await getApplicationSupportDirectory()).path}/models/${model.name}.downloading',
  );

  Future<void> _clearPendingMark(SpeechModel model) async {
    final mark = await _pendingMark(model);
    if (await mark.exists()) await mark.delete();
  }

  /// Continues paused files from where they stopped; restarts the rest.
  Future<void> _resumeDownload(SpeechModel model) async {
    // Finished while the app was closed.
    if (await _isDownloaded(model)) return _clearPendingMark(model);
    final downloader = bd.FileDownloader();
    final paused = await downloader.database.allRecordsWithStatus(
      bd.TaskStatus.paused,
      group: model.name,
    );
    final resumed = <String>{};
    for (final record in paused) {
      if (record.task case final bd.DownloadTask task
          when await downloader.resume(task)) {
        resumed.add(task.metaData);
      }
    }
    await _startDownload(model, skip: resumed);
  }

  /// Copies a bundled asset to disk once, since sherpa-onnx needs file paths.
  Future<String> _assetFile(String dir, String name) async {
    final base = '${(await getApplicationSupportDirectory()).path}/$dir';
    await Directory(base).create(recursive: true);
    final file = File('$base/$name');
    if (!await file.exists()) {
      final data = await rootBundle.load('assets/models/$dir/$name');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return file.path;
  }

  // Only one model is kept in memory; each is 100 MB+.
  void _freeModels() {
    _vad?.free();
    _offline?.dispose();
    _vad = null;
    _offline = null;
    _vadPending.clear();
  }

  Future<void> _loadModel() async {
    final threads = Platform.numberOfProcessors.clamp(2, 4);
    try {
      sherpa.initBindings();
      _freeModels();
      if (!await _isDownloaded(_model)) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error = false;
            _status = '먼저 음성 모델을 내려받아 주세요';
          });
        }
        return;
      }
      final dir = await _modelDir(_model);
      final model = _model == SpeechModel.senseVoice
          ? sherpa.OfflineModelConfig(
              senseVoice: sherpa.OfflineSenseVoiceModelConfig(
                model: '$dir/model.int8.onnx',
                language: 'ko',
                useInverseTextNormalization: true,
              ),
              tokens: '$dir/tokens.txt',
              numThreads: threads,
              debug: false,
            )
          : sherpa.OfflineModelConfig(
              qwen3Asr: sherpa.OfflineQwen3AsrModelConfig(
                convFrontend: '$dir/conv_frontend.onnx',
                encoder: '$dir/encoder.int8.onnx',
                decoder: '$dir/decoder.int8.onnx',
                tokenizer: '$dir/tokenizer',
                maxNewTokens: 256,
              ),
              tokens: '', // Qwen3 reads its vocab from tokenizer/.
              numThreads: threads,
              debug: false,
            );
      _offline = await _OfflineWorker.spawn(
        sherpa.OfflineRecognizerConfig(model: model),
      );
      _vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: await _assetFile('vad', 'silero_vad.onnx'),
            minSilenceDuration: 0.6,
            maxSpeechDuration: 15,
          ),
          debug: false,
        ),
        bufferSizeInSeconds: 30,
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _error = false;
          _status = '말할 준비가 됐어요';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = true;
          _status = '음성 모델을 불러오지 못했어요. 다른 모델을 골라 주세요.';
        });
      }
    }
  }

  Future<String> _modelDir(SpeechModel model) async =>
      File(await model.tasks.first.filePath()).parent.path;

  Future<bool> _fileDone(bd.DownloadTask task) async {
    final file = File(await task.filePath());
    final size = SpeechModel.forGroup(task.group)?.files[task.metaData];
    if (await file.exists()) return await file.length() == size;
    // Older builds saved models in the cache; move any that survived.
    final old = File(
      await task.copyWith(baseDirectory: bd.BaseDirectory.temporary).filePath(),
    );
    if (!await old.exists() || await old.length() != size) return false;
    await file.parent.create(recursive: true);
    try {
      await old.rename(file.path);
    } on FileSystemException {
      await old.copy(file.path); // Different volume on some phones.
      await old.delete();
    }
    return true;
  }

  Future<bool> _isDownloaded(SpeechModel model) async {
    for (final task in model.tasks) {
      if (!await _fileDone(task)) return false;
    }
    return true;
  }

  Future<void> _markFinishedFiles(SpeechModel model) async {
    _fileProgress.clear();
    _failedFiles.clear();
    for (final task in model.tasks) {
      if (await _fileDone(task)) _fileProgress[task.metaData] = 1;
    }
    // Start from the last known progress, so reopening the app doesn't drop
    // the bar back to the finished files only.
    final records = await bd.FileDownloader().database.allRecords(
      group: model.name,
    );
    for (final record in records) {
      final name = record.task.metaData;
      if (_fileProgress[name] != 1 && record.progress > 0) {
        _fileProgress[name] = record.progress.clamp(0, 0.99);
      }
    }
  }

  double get _downloadFraction {
    final files = _downloadingModel?.files ?? const {};
    final total = files.values.fold(0, (a, b) => a + b);
    var done = 0.0;
    for (final MapEntry(key: name, value: size) in files.entries) {
      done += size * (_fileProgress[name] ?? 0);
    }
    return total == 0 ? 0 : done / total;
  }

  Future<bool> _confirmDownload(SpeechModel model) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${model.label} 모델을 내려받을까요?'),
          content: Text(
            '${model.title} 모델 파일 ${model.size}를 한 번 내려받아요. '
            'Wi-Fi 연결을 권장해요.\n\n'
            '${isDesktop ? '앱을 닫아도 다음에 열면 이어서 받아요. ' : '화면이 꺼지거나 다른 앱을 써도 계속 받아요. '}'
            '${_loaded ? '받는 동안에는 지금 모델을 그대로 쓸 수 있어요. ' : ''}'
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
      ) ??
      false;

  /// Asks, then hands the model's missing files to the OS downloader.
  Future<void> _requestDownload(SpeechModel model) async {
    final busyWith = _downloadingModel;
    if (busyWith != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${busyWith.label} 모델을 받는 중이에요. 다 받은 뒤에 골라 주세요.'),
        ),
      );
      return;
    }
    if (!await _confirmDownload(model)) return;
    await _startDownload(model);
  }

  Future<void> _startDownload(
    SpeechModel model, {
    Set<String> skip = const {},
  }) async {
    if (!mounted) return;
    // Set before any await so the buttons lock right away; otherwise the
    // notification prompt left the mic tappable and it asked again.
    setState(() {
      _downloadingModel = model;
      _failedDownload = null;
    });
    final downloader = bd.FileDownloader();
    // Lets the progress notification show while the app is closed; the
    // download works without it.
    await downloader.permissions.request(bd.PermissionType.notifications);
    await _markFinishedFiles(model);
    final missing = [
      for (final task in model.tasks)
        if (_fileProgress[task.metaData] != 1 && !skip.contains(task.metaData))
          task,
    ];
    final mark = await _pendingMark(model);
    await mark.parent.create(recursive: true);
    await mark.create();
    await downloader.enqueueAll(missing);
  }

  Future<void> _cancelDownload() async {
    final model = _downloadingModel;
    if (model != null) {
      await bd.FileDownloader().cancelAll(group: model.name);
      await _clearPendingMark(model);
    }
    if (mounted) setState(() => _downloadingModel = null);
  }

  void _onDownloadUpdate(bd.TaskUpdate update) {
    final model = SpeechModel.forGroup(update.task.group);
    if (model == null || !mounted) return;
    final name = update.task.metaData;
    switch (update) {
      case bd.TaskProgressUpdate(:final progress):
        if (progress < 0) return; // Negative values are status codes.
        final before = (_downloadFraction * 100).floor();
        // Never step back: a resume or retry restarts the reported progress
        // at 0 (or a stale value), which made the bar jump down and up.
        // ponytail: a true restart from zero shows a stalled bar until it
        // catches up; fine since that only happens after a failed resume.
        if (progress <= (_fileProgress[name] ?? 0)) return;
        _fileProgress[name] = progress;
        if ((_downloadFraction * 100).floor() != before) setState(() {});
      case bd.TaskStatusUpdate(:final status):
        switch (status) {
          case bd.TaskStatus.complete:
            _fileProgress[name] = 1;
            _finishDownload(model);
          case bd.TaskStatus.failed || bd.TaskStatus.notFound:
            debugPrint(
              'Model file failed: $name '
              '${update.responseStatusCode} ${update.exception?.description}',
            );
            _failedFiles.add(name);
            _finishDownload(model);
          // _cancelDownload already hid the banner. Any other cancel is iOS
          // reporting, at relaunch, the task it stopped; _resumeDownload has
          // replaced it.
          case bd.TaskStatus.canceled:
            break;
          default:
            if (_downloadingModel == null) {
              setState(() => _downloadingModel = model);
            }
        }
    }
  }

  /// Settles once every file has ended. One failed file no longer cancels
  /// the rest: the OS notification kept saying "downloading" for those while
  /// the app already said "failed", and retrying only fetches what's missing.
  Future<void> _finishDownload(SpeechModel model) async {
    final pending = model.files.keys.any(
      (f) => _fileProgress[f] != 1 && !_failedFiles.contains(f),
    );
    if (pending) return;
    await _clearPendingMark(model);
    if (!mounted) return;
    if (_failedFiles.isNotEmpty || !await _isDownloaded(model)) {
      if (mounted) {
        setState(() {
          _downloadingModel = null;
          _failedDownload = model;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _downloadingModel = null);
    await _refreshOnPhone();
    // Switch straight away unless the user is mid-sentence.
    if (!_busy && !_listening) await _switchModel(model);
  }

  Future<void> _switchModel(SpeechModel model) async {
    if (_busy || _listening || (model == _model && _loaded)) return;
    if (!await _isDownloaded(model)) {
      // Keep using the current model while the OS downloads in the background.
      await _requestDownload(model);
      return;
    }
    setState(() {
      _model = model;
      _busy = true;
      _error = false;
      _heard = '';
      _partial = '';
      _status = '모델을 적용 중이에요';
    });
    await _loadModel();
  }

  Future<void> _toggleListening() async {
    if (_busy) return;
    if (_listening) {
      await _audioSub?.cancel();
      await _recorder.stop();
      final vad = _vad;
      if (vad != null) {
        vad.flush();
        _drainVad();
        vad.reset();
        _vadPending.clear();
      }
      if (mounted) {
        setState(() {
          _listening = false;
          _partial = (_offline?.pending ?? 0) > 0 ? '…' : '';
          _status = _heard.isEmpty && _partial.isEmpty ? _missed : '말할 준비가 됐어요';
        });
      }
      return;
    }
    try {
      if (!await _recorder.hasPermission()) {
        setState(() {
          _error = true;
          _status = '설정에서 마이크 권한을 허용해 주세요';
        });
        return;
      }
      final audio = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      setState(() {
        _listening = true;
        _error = false;
        _heard = '';
        _partial = '';
        _status = '듣고 있어요';
      });
      _audioSub = audio.listen(
        _feed,
        onError: (_) {
          if (mounted) {
            setState(() {
              _listening = false;
              _error = true;
              _status = '마이크를 시작하지 못했어요';
            });
          }
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _listening = false;
          _error = true;
          _status = '녹음 기능을 사용할 수 없어요';
        });
      }
    }
  }

  void _feed(Uint8List bytes) {
    if (_vad != null) _feedVad(pcm16ToFloat32(bytes));
  }

  // Silero VAD expects fixed 512-sample windows at 16 kHz.
  void _feedVad(Float32List samples) {
    final vad = _vad!;
    _vadPending.addAll(samples);
    const window = 512;
    var offset = 0;
    while (_vadPending.length - offset >= window) {
      vad.acceptWaveform(
        Float32List.fromList(_vadPending.sublist(offset, offset + window)),
      );
      offset += window;
    }
    _vadPending.removeRange(0, offset);
    _drainVad();
  }

  /// Sends every finished speech segment the VAD has queued to the worker.
  /// Results come back in order; '…' marks sentences still being written.
  void _drainVad() {
    final vad = _vad;
    final worker = _offline;
    if (vad == null || worker == null) return;
    var sent = false;
    while (!vad.isEmpty()) {
      worker.transcribe(vad.front().samples).then((text) {
        _appendFinal(text);
        _paint(worker.pending > 0 ? '…' : '');
      });
      vad.pop();
      sent = true;
    }
    if (sent) _paint('…');
  }

  // Qwen3 has no language setting and sometimes answers in Chinese or
  // Japanese; drop Han and kana so only Korean (and Latin) reaches the user.
  // A sentence that was all Chinese becomes empty and counts as not heard.
  static final _notKorean = RegExp(
    r'[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3000-\u303f\uff01-\uff0f]+',
  );
  static String _koreanOnly(String text) =>
      text.replaceAll(_notKorean, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  void _appendFinal(String text) {
    text = _koreanOnly(text);
    if (text.isEmpty) return;
    _heard = _heard.isEmpty ? text : '$_heard $text';
    _checkCommand();
  }

  // ponytail: keyword match, not intent parsing; enough for "어, 해줘" /
  // "나중에" until a real assistant backend answers.
  static const _missed = '잘 듣지 못했어요. 다시 말씀해 주세요.';
  // A bare "응"/"네" only counts as the whole answer; inside other words it
  // fired on background chatter.
  static final _yes = RegExp(r'읽어|읊어|해줘|해 줘|그래|좋아|^\s*(응|네|예|어)\s*[.!?]?\s*$');
  static final _later = RegExp(r'나중|그만|취소');

  void _checkCommand() {
    final said = '$_heard $_partial';
    if (!_listening || _opening) return;
    if (_later.hasMatch(said)) {
      _opening = true;
      _toggleListening().whenComplete(() {
        _opening = false;
        Reader.instance.speak('알겠어요. 필요하면 다시 불러 주세요.');
      });
    } else if (_yes.hasMatch(said)) {
      _openBriefing();
    }
  }

  /// Opens a [MailFolder] from the menu or a home card, [only] one
  /// account's mail when given.
  void _openFolder(MailFolder folder, {MailAccount? only}) {
    _closeDrawer();
    _content.currentState?.popUntil((route) => route.isFirst);
    _push(
      section: folder.name,
      MailFolderScreen(
        from: [homeLabel],
        folder: folder,
        accounts: _accounts,
        only: only,
        limit: _settings.listSize,
        onRead: _onRead,
        onAllRead: (account) => setState(() {
          _unread[account.address] = [];
          _unreadTotal[account.address] = 0;
        }),
        onOpenAll: (only) => _openFolder(MailFolder.all, only: only),
      ),
    );
  }

  /// The mic: asks aloud whether to read the unread mail, then listens for
  /// the answer. Tapping again stops either step.
  Future<void> _talk() async {
    final reader = Reader.instance;
    if (_listening) return _toggleListening();
    if (_asking) {
      reader.stop();
      return setState(() => _asking = false);
    }
    final count = _mails.length;
    if (count == 0) {
      final loading = _accounts.any(
        (a) => _unread[a.address] == null && _mailErrors[a.address] == null,
      );
      await reader.speak(
        loading
            ? '메일을 불러오는 중이에요. 잠시 뒤에 다시 불러 주세요.'
            : _mailError != null
            ? '메일을 불러오지 못했어요.'
            : '안 읽은 메일이 없어요.',
      );
      return;
    }
    setState(() => _asking = true);
    // Listening only starts once the question ends, so the mic doesn't
    // hear the app's own voice.
    final problem = await reader.speak('안 읽은 메일이 $count건 있어요. 읽어드릴까요?');
    if (!mounted || !_asking) return;
    setState(() => _asking = false);
    // Cut off (a mail opened, or the mic tapped) or covered by another
    // screen: listening now would hear the app reading behind it.
    if (problem == Reader.cut || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    // No voice: the question is still on screen, so listen anyway.
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
    }
    await _toggleListening();
  }

  Future<void> _openBriefing() async {
    final mails = _mails;
    if (_opening) return;
    _opening = true;
    try {
      if (_listening) await _toggleListening();
      if (!mounted) return;
      if (mails.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_mailError ?? '안 읽은 메일이 없어요')));
        return;
      }
      await _push(
        BriefingScreen(from: [homeLabel], mails: mails, onRead: _onRead),
      );
    } finally {
      _opening = false;
    }
    if (mounted) {
      setState(() {
        _heard = '';
        _partial = '';
        _status = '말할 준비가 됐어요';
      });
    }
  }

  void _paint(String partial) {
    if (!mounted) return;
    setState(() => _partial = partial == '…' ? partial : _koreanOnly(partial));
    _checkCommand();
  }

  @override
  void dispose() {
    for (final model in SpeechModel.values) {
      bd.FileDownloader().unregisterCallbacks(group: model.name);
    }
    _changes.dispose();
    _checker?.cancel();
    _pulse.dispose();
    _audioSub?.cancel();
    _recorder.dispose();
    _freeModels();
    super.dispose();
  }

  /// Menu item lit up in the sidebar; [_push] sets it, and it goes back to
  /// home once that screen closes.
  String _section = 'home';

  /// Sidebar shrunk to an icon rail (wide windows only).
  bool _railOnly = false;

  /// Bumped per [_push], so a screen closing after another menu item has
  /// opened leaves the newer highlight alone.
  int _pushes = 0;

  /// Wide windows open screens in the content pane beside the sidebar.
  Future<void> _push(Widget screen, {String? section}) async {
    final push = ++_pushes;
    if (section != null) setState(() => _section = section);
    await (_content.currentState ?? Navigator.of(context)).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted && push == _pushes) setState(() => _section = 'home');
  }

  /// Menu taps close the drawer; the sidebar has none to close.
  void _closeDrawer() {
    if (_scaffold.currentState?.isDrawerOpen ?? false) Navigator.pop(context);
  }

  /// Progress of the model being downloaded, or why it failed.
  Widget? get _banner => switch (_downloadingModel ?? _failedDownload) {
    final model? => _DownloadBanner(
      label: model.label,
      progress: _downloadFraction,
      filesDone: _fileProgress.values.where((p) => p == 1).length,
      filesTotal: model.files.length,
      failed: _downloadingModel == null,
      onCancel: _cancelDownload,
      onRetry: () => _startDownload(model),
      onDismiss: () => setState(() => _failedDownload = null),
    ),
    null => null,
  };

  /// Models fully on the phone, for 음성 설정.
  Set<SpeechModel> _onPhone = {};

  Future<void> _refreshOnPhone() async {
    final onPhone = {
      for (final model in SpeechModel.values)
        if (await _isDownloaded(model)) model,
    };
    if (mounted) setState(() => _onPhone = onPhone);
  }

  void _openVoiceSettings() {
    _refreshOnPhone();
    _closeDrawer();
    _content.currentState?.popUntil((route) => route.isFirst);
    _push(section: 'voice', _VoiceSettingsScreen(this));
  }

  /// Bumped on every rebuild, so 음성 설정 (its own route) follows download
  /// progress and model changes made here.
  final _changes = ValueNotifier(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _changes.value++;
  }

  /// Deletes [model]'s files after asking; the one in use is unloaded first.
  Future<void> _deleteModel(SpeechModel model) async {
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
    if (ok != true || !mounted || _busy || _listening) return;
    // Locked while deleting, so nothing downloads or loads this model meanwhile.
    setState(() {
      _busy = true;
      _deleting = model;
    });
    if (model == _model) _freeModels();
    final dir = Directory(await _modelDir(model));
    if (await dir.exists()) await dir.delete(recursive: true);
    // Old records would start a new download's bar at 99%.
    await bd.FileDownloader().database.deleteAllRecords(group: model.name);
    await _refreshOnPhone();
    _deleting = null;
    if (!mounted) return;
    if (model != _model) return setState(() => _busy = false);
    // Carry on with another model already on the phone, if any.
    for (final other in SpeechModel.values) {
      if (await _isDownloaded(other)) {
        _model = other;
        break;
      }
    }
    setState(() {
      _busy = true;
      _status = '모델을 적용 중이에요';
    });
    await _loadModel();
  }

  Widget _mailCard(
    ColorScheme colors,
    String mark,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => VoiceCard(
    onTap: onTap,
    child: Row(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: colors.primaryContainer,
          child: Text(
            mark,
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
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
      ],
    ),
  );

  /// Menu body: inside the drawer on phones, the sidebar on wide windows.
  /// A folded [sidebar] shows icons only, with the label as a tooltip.
  Widget _menu(ColorScheme colors, {bool sidebar = false}) {
    final rail = sidebar && _railOnly;
    Widget item(
      String label, {
      required IconData icon,
      bool selected = false,
      Color? iconColor,
      required VoidCallback onTap,
    }) {
      // A ListTile with no room for a title throws in layout, so the rail
      // uses plain icon buttons.
      if (rail) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: IconButton(
            tooltip: label,
            onPressed: onTap,
            icon: Icon(icon),
            style: IconButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              backgroundColor: selected ? colors.primaryContainer : null,
              foregroundColor: selected
                  ? colors.onPrimaryContainer
                  : iconColor ?? colors.onSurfaceVariant,
            ),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: ListTile(
          selected: selected,
          selectedTileColor: colors.primaryContainer,
          selectedColor: colors.onPrimaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: Icon(
            icon,
            color: selected ? null : iconColor ?? colors.onSurfaceVariant,
          ),
          minLeadingWidth: 10,
          title: Text(
            label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          onTap: onTap,
        ),
      );
    }

    final toggle = IconButton(
      tooltip: rail ? '메뉴 펼치기' : '메뉴 접기',
      icon: Icon(rail ? Icons.menu_rounded : Icons.menu_open_rounded),
      onPressed: () => setState(() => _railOnly = !rail),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rail)
              toggle
            else
              Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: _Brand(),
                  ),
                  const Spacer(),
                  if (sidebar) toggle,
                ],
              ),
            Divider(height: 28, color: colors.outlineVariant),
            item(
              homeLabel,
              icon: Icons.home_rounded,
              selected: _section == 'home',
              onTap: () {
                _closeDrawer();
                _content.currentState?.popUntil((route) => route.isFirst);
              },
            ),
            if (_accounts.isNotEmpty)
              for (final (folder, icon) in [
                (MailFolder.all, Icons.inbox_rounded),
                (MailFolder.unread, Icons.mark_email_unread_outlined),
                (MailFolder.sent, Icons.send_outlined),
              ])
                item(
                  folder.label,
                  icon: icon,
                  selected: _section == folder.name,
                  onTap: () => _openFolder(folder),
                ),
            Divider(height: 20, color: colors.outlineVariant),
            if (!isDesktop)
              item(
                '음성 설정',
                icon: Icons.graphic_eq_rounded,
                selected: _section == 'voice',
                onTap: _openVoiceSettings,
              ),
            // A call to action until an account is linked; after that the
            // accounts live in 앱 설정.
            if (_accounts.isEmpty)
              if (rail)
                item(
                  '메일 연동하기',
                  icon: Icons.add_rounded,
                  iconColor: colors.primary,
                  onTap: _openConnect,
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: OutlinedButton.icon(
                    onPressed: _openConnect,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('메일 연동하기'),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      minimumSize: const Size.fromHeight(52),
                      foregroundColor: colors.primary,
                      backgroundColor: colors.primaryContainer.withValues(
                        alpha: 0.4,
                      ),
                      side: BorderSide(
                        color: colors.primary.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            item(
              '앱 설정',
              icon: Icons.settings_outlined,
              selected: _section == 'settings',
              onTap: _openSettings,
            ),
            item(
              '오프라인 화면 미리보기',
              icon: Icons.cloud_off_rounded,
              selected: _section == 'offline',
              onTap: () {
                _closeDrawer();
                _content.currentState?.popUntil((route) => route.isFirst);
                _push(section: 'offline', OfflineScreen(from: [homeLabel]));
              },
            ),
            const Spacer(),
            if (!isDesktop && !rail)
              VoiceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '음성 프라이버시',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '음성 원본은 기기 안에서 인식해요.',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_listening && !reduceMotion) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final needsModel = !_busy && !_loaded;
    final onMic = _busy || (needsModel && _downloadingModel != null)
        ? null
        : _loaded
        ? _talk
        : () => _requestDownload(_model);
    // Beside the mic: what tapping it does, and what to say.
    final (micTitle, micHint) = _error
        ? (_status, '다시 눌러 주세요')
        : _busy
        ? (_status, '처음 한 번만 조금 걸려요')
        : needsModel
        ? ('${_model.label} 모델 내려받기', '${_model.size}를 한 번 내려받아요')
        : _asking
        ? ('읽어드릴까요?', '질문이 끝나면 말씀해 주세요')
        : _listening
        ? ('듣고 있어요', '말씀해 주세요')
        : _partial == '…'
        ? ('말씀을 확인하고 있어요', '잠시만요')
        : (
            wide && !isDesktop ? '눌러서 말하기 · Space' : '눌러서 말하기',
            _status == _missed ? _missed : '"오늘 메일 온 거 읊어줘"',
          );
    final heard = '$_heard $_partial'.trim();

    final content = ListView(
      padding: wide
          ? const EdgeInsets.fromLTRB(48, 48, 48, 32)
          : const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        if (!wide) ...[
          Row(
            children: [
              IconButton.outlined(
                tooltip: '메뉴',
                onPressed: () => _scaffold.currentState?.openDrawer(),
                icon: const Icon(Icons.menu_rounded),
                style: IconButton.styleFrom(
                  side: BorderSide(color: colors.outlineVariant),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const _Brand(),
            ],
          ),
          const SizedBox(height: 28),
        ],
        if (!isDesktop)
          if (_banner case final banner?) ...[
            banner,
            const SizedBox(height: 20),
          ],
        // 01 voice home ⇄ 02 listening share this screen.
        if (_listening || _asking) ...[
          ScreenTitle(_source, '안 읽은 메일 ${_mails.length}건'),
          const SizedBox(height: 18),
          VoiceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '읽어드릴까요?',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '"어, 해줘" 또는 "나중에"',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ] else ...[
          isDesktop
              ? const ScreenTitle('메일 홈', '오늘 확인할 메일')
              : const ScreenTitle('운전 중에도', '메일을 듣고\n말로 답장하세요'),
          const SizedBox(height: 18),
          if (_accounts.isEmpty)
            _mailCard(
              colors,
              'N',
              '예시 메일 · 안 읽은 메일 ${mockMails.length}건',
              '메일 연동하기를 누르면 내 메일로 바뀌어요',
              () => _openFolder(MailFolder.unread),
            ),
          for (final (i, a) in _accounts.indexed) ...[
            if (i > 0) const SizedBox(height: 10),
            _mailCard(
              colors,
              a.service.mark,
              switch (_unread[a.address]) {
                null when _mailErrors[a.address] == null =>
                  '${a.service.label} · 불러오는 중',
                null => '${a.service.label} · 불러오지 못했어요',
                _ => '${a.service.label} · 안 읽은 메일 ${_unreadTotal[a.address]}건',
              },
              _mailErrors[a.address] ?? a.address,
              // Nothing unread: the whole inbox is what's left to see.
              () => _openFolder(
                _unreadTotal[a.address] == 0
                    ? MailFolder.all
                    : MailFolder.unread,
                only: a,
              ),
            ),
          ],
        ],
        if (!isDesktop) ...[
          const SizedBox(height: 28),
          Row(
            children: [
              _MicButton(
                pulse: _pulse,
                listening: _listening,
                busy: _busy,
                icon: needsModel
                    ? Icons.download_rounded
                    : _listening || _asking
                    ? Icons.stop_rounded
                    : Icons.mic_none_rounded,
                label: needsModel
                    ? '${_model.label} 모델 내려받기'
                    : _listening || _asking
                    ? '듣기 멈추기'
                    : '말하기 시작',
                onPressed: onMic,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        micTitle,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: _error ? colors.error : colors.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        micHint,
                        style: TextStyle(
                          fontSize: 15,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_listening || heard.isNotEmpty) ...[
            const SizedBox(height: 24),
            VoiceCard(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '인식한 말',
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          heard.isEmpty ? '…' : '“$heard”',
                          style: const TextStyle(
                            fontSize: 22,
                            height: 1.4,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_listening)
                    Icon(Icons.circle, size: 12, color: colors.primary),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '음성은 기기 안에서 인식합니다',
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ],
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        systemNavigationBarColor: colors.surface,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: CallbackShortcuts(
        bindings: {
          if (!isDesktop)
            const SingleActivator(LogicalKeyboardKey.space): () {
              // Only on the home pane, where the mic is.
              if (onMic != null &&
                  !(_content.currentState?.canPop() ?? false)) {
                onMic();
              }
            },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            key: _scaffold,
            drawer: wide ? null : Drawer(child: _menu(colors)),
            body: wide
                ? Row(
                    children: [
                      Container(
                        width: _railOnly ? 84 : 288,
                        decoration: BoxDecoration(
                          border: Border(
                            right: BorderSide(color: colors.outlineVariant),
                          ),
                        ),
                        child: _menu(colors, sidebar: true),
                      ),
                      Expanded(
                        child: Navigator(
                          key: _content,
                          pages: [
                            MaterialPage(
                              key: const ValueKey('home'),
                              child: Material(
                                color: colors.surface,
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 760,
                                    ),
                                    child: content,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          onDidRemovePage: (_) {},
                        ),
                      ),
                    ],
                  )
                : SafeArea(child: content),
          ),
        ),
      ),
    );
  }
}

/// Logo lockup, shared by the home bar and the drawer.
class _Brand extends StatelessWidget {
  const _Brand();

  // Lockup from design/logo (export/horizontal, mono #A8F5D0), tinted to
  // the symbol colour.
  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/brand/logo-horizontal.png',
    height: 34,
    color: Theme.of(context).colorScheme.primary,
    // The 600×160 source shrinks ~2–5×; the default low filter skips pixels
    // at that ratio and left the curves jagged. Medium samples mipmaps.
    filterQuality: FilterQuality.medium,
    semanticLabel: 'Alpha-mail',
  );
}

/// Round flat brown mic. Idle: a hairline ring like the cards' borders. Listening: rings keep
/// spreading out, so "it hears me" reads at a glance; with system animations
/// off the rings stay still and the label carries the state.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.pulse,
    required this.listening,
    required this.busy,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final AnimationController pulse;
  final bool listening;
  final bool busy;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  static const _size = 76.0;
  static const _fill = Color(0xff000000);
  static const _glyph = Color(0xffffffff);

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: _size * 1.6,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: pulse,
            builder: (context, _) => CustomPaint(
              size: const Size.square(_size * 1.6),
              painter: _RingsPainter(
                listening: listening,
                t: pulse.value,
                inner: _size / 2,
              ),
            ),
          ),
          Semantics(
            button: true,
            label: label,
            child: Tooltip(
              message: label,
              child: Opacity(
                opacity: onPressed == null ? 0.4 : 1,
                child: Container(
                  width: _size,
                  height: _size,
                  // Flat like the rest of the app: no gradient, no glow.
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: _fill,
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: onPressed,
                      child: busy
                          ? const Padding(
                              padding: EdgeInsets.all(24),
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: _glyph,
                              ),
                            )
                          : Icon(icon, size: 36, color: _glyph),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({
    required this.listening,
    required this.t,
    required this.inner,
  });

  final bool listening;
  final double t;
  final double inner;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.width / 2;
    final paint = Paint()..style = PaintingStyle.stroke;
    // Resting: one hairline ring in the cards' border colour.
    canvas.drawCircle(
      center,
      inner + 12,
      paint
        ..strokeWidth = 1.5
        ..color = const Color(0xffd6d6d6),
    );
    if (!listening) return;
    // Two rings, half a cycle apart, growing from the button edge outward.
    for (final offset in [0.0, 0.5]) {
      final p = (t + offset) % 1;
      canvas.drawCircle(
        center,
        inner + 12 + (outer - inner - 12) * p,
        paint
          ..strokeWidth = 2
          ..color = const Color(0xff000000).withValues(alpha: 0.45 * (1 - p)),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.t != t || old.listening != listening;
}

/// Shows the background model download without blocking the current model.
/// 음성 설정: pick, download or delete a speech model. Reads and drives the
/// home's state, which owns the recogniser and the downloads.
class _VoiceSettingsScreen extends StatelessWidget {
  const _VoiceSettingsScreen(this.home);
  final _SpeechScreenState home;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: home._changes,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final locked = home._busy || home._listening;
      return AppPage(
        trail: [homeLabel, '음성 설정'],
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
          if (home._banner case final banner?) ...[
            banner,
            const SizedBox(height: 16),
          ],
          for (final m in SpeechModel.values) ...[
            _modelCard(m, colors, locked),
            const SizedBox(height: 12),
          ],
        ],
      );
    },
  );

  Widget _modelCard(SpeechModel m, ColorScheme colors, bool locked) {
    final onPhone = home._onPhone.contains(m);
    final inUse = m == home._model && home._loaded;
    final downloading = home._downloadingModel == m;
    final deleting = home._deleting == m;
    final applying = deleting || home._busy && m == home._model;
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
                  '내려받는 중 ${(home._downloadFraction * 100).floor()}%',
                  style: TextStyle(color: colors.onSurfaceVariant),
                )
              else if (!onPhone)
                OutlinedButton.icon(
                  onPressed: locked || home._downloadingModel != null
                      ? null
                      : () => home._switchModel(m),
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('내려받기'),
                )
              else if (!inUse)
                FilledButton(
                  onPressed: locked ? null : () => home._switchModel(m),
                  // The theme's full-width minimum has no width to fill in
                  // a Row, which threw in layout and left the screen blank.
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  child: const Text('이 모델 쓰기'),
                ),
              const Spacer(),
              if (onPhone)
                TextButton.icon(
                  onPressed: locked ? null : () => home._deleteModel(m),
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

class _DownloadBanner extends StatelessWidget {
  const _DownloadBanner({
    required this.label,
    required this.progress,
    required this.filesDone,
    required this.filesTotal,
    required this.failed,
    required this.onCancel,
    required this.onRetry,
    required this.onDismiss,
  });

  final String label;
  final double progress;
  final int filesDone;
  final int filesTotal;
  final bool failed;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final percent = (progress * 100).floor();
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
                TextButton(onPressed: onRetry, child: const Text('다시 시도')),
                TextButton(onPressed: onDismiss, child: const Text('닫기')),
              ] else
                TextButton(onPressed: onCancel, child: const Text('취소')),
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
              '파일 $filesDone/$filesTotal개 받음 · '
              '${isDesktop ? '앱을 닫아도 이어서 받아요' : '화면을 꺼도 계속 받아요'}',
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
