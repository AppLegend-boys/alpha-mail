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

/// Little-endian signed 16-bit PCM to normalized float samples in [-1, 1).
Float32List pcm16ToFloat32(Uint8List bytes) {
  final samples = Float32List(bytes.length ~/ 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}

void main() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Gowun Batang',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  runApp(const AlphaVoiceApp());
}

// DESIGN.md §3 palette, mapped onto Material roles so widgets read it from Theme.
// Light only: the app ignores the phone's dark mode.
ThemeData _theme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xff2f5d4e),
    onPrimary: Color(0xffffffff),
    primaryContainer: Color(0xffe6eee7),
    onPrimaryContainer: Color(0xff1d3a30),
    secondary: Color(0xff1f3a31),
    onSecondary: Color(0xffffffff),
    tertiary: Color(0xff9bbfa6),
    onTertiary: Color(0xff1d3a30),
    error: Color(0xffb33a38),
    onError: Color(0xffffffff),
    surface: Color(0xfff4f3ef),
    onSurface: Color(0xff1f2622),
    onSurfaceVariant: Color(0xff5b6660),
    surfaceContainer: Color(0xffffffff),
    outline: Color(0xff7a867f),
    outlineVariant: Color(0xffdde2da),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class AlphaVoiceApp extends StatelessWidget {
  const AlphaVoiceApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Alpha Voice',
    debugShowCheckedModeBanner: false,
    theme: _theme(),
    home: const SpeechScreen(),
  );
}

/// On-device recognisers the user can switch between. None are bundled (the
/// Play Store caps the base app at 200 MB): the OS downloads each one once
/// into app support storage, even with the screen off or the app closed.
/// Not the cache directory: the OS empties that when space runs low, which
/// made users download the same model again.
enum SpeechModel {
  zipformer(
    '실시간',
    'Zipformer 한국어',
    '말하는 동안 바로 적어요',
    '약 140MB',
    '말하는 대로 바로 볼 때',
    'https://huggingface.co/k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16/resolve/main',
    {
      'encoder-epoch-99-avg-1.int8.onnx': 126968852,
      'decoder-epoch-99-avg-1.onnx': 11309084,
      'joiner-epoch-99-avg-1.int8.onnx': 2581421,
      'tokens.txt': 60246,
    },
  ),
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
  SpeechModel _model = SpeechModel.zipformer;
  // Streaming model (zipformer).
  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  // Utterance model (SenseVoice) fed by voice-activity segments.
  _OfflineWorker? _offline;
  StreamSubscription<bd.TaskUpdate>? _downloadSub;
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
  final _scroll = ScrollController();
  String _finalized = '';
  String _partial = '';
  int _lastPaintMs = 0;
  String _status = '모델을 준비하고 있어요';
  bool _busy = true;
  bool _listening = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  bool get _loaded => _recognizer != null || _offline != null;

  Future<void> _init() async {
    await _initDownloads();
    // Start on the first model already on the phone.
    for (final model in SpeechModel.values) {
      if (await _isDownloaded(model)) {
        _model = model;
        break;
      }
    }
    await _loadModel();
  }

  Future<void> _initDownloads() async {
    final downloader = bd.FileDownloader();
    _downloadSub = downloader.updates.listen(_onDownloadUpdate);
    for (final model in SpeechModel.values) {
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
    _stream?.free();
    _recognizer?.free();
    _vad?.free();
    _offline?.dispose();
    _stream = null;
    _recognizer = null;
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
      switch (_model) {
        case SpeechModel.zipformer:
          final model = sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: '$dir/encoder-epoch-99-avg-1.int8.onnx',
              decoder: '$dir/decoder-epoch-99-avg-1.onnx',
              joiner: '$dir/joiner-epoch-99-avg-1.int8.onnx',
            ),
            tokens: '$dir/tokens.txt',
            modelType: 'zipformer',
            modelingUnit: 'cjkchar',
            numThreads: threads,
            debug: false,
          );
          _recognizer = sherpa.OnlineRecognizer(
            sherpa.OnlineRecognizerConfig(model: model, ruleFsts: ''),
          );
          _stream = _recognizer!.createStream();
        case SpeechModel.senseVoice || SpeechModel.qwen3:
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
      }
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
            '화면이 꺼지거나 다른 앱을 써도 계속 받아요. '
            '${_loaded ? '받는 동안에는 지금 모델을 그대로 쓸 수 있어요. ' : ''}'
            '받은 뒤에는 인터넷 없이 이 휴대폰 안에서만 인식해요.',
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
      _finalized = '';
      _partial = '';
      _status = '모델을 준비하고 있어요';
    });
    await _loadModel();
  }

  Future<void> _toggleListening() async {
    if (_busy) return;
    if (_listening) {
      await _audioSub?.cancel();
      await _recorder.stop();
      final stream = _stream;
      final recognizer = _recognizer;
      if (stream != null && recognizer != null) {
        stream.inputFinished();
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
        _appendFinal(recognizer.getResult(stream).text.trim());
        stream.free();
        _stream = recognizer.createStream();
      }
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
          _status = '받아쓰기를 마쳤어요';
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
        _finalized = '';
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

  // ponytail: the streaming model decodes on the UI isolate; move it into a
  // worker like _OfflineWorker if a slow phone drops frames while listening.
  void _feed(Uint8List bytes) {
    final samples = pcm16ToFloat32(bytes);
    if (_vad != null) return _feedVad(samples);
    final stream = _stream;
    final recognizer = _recognizer;
    if (stream == null || recognizer == null) return;
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final partial = recognizer.getResult(stream).text.trim();
    if (recognizer.isEndpoint(stream)) {
      _appendFinal(partial);
      recognizer.reset(stream);
      _paint('');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPaintMs < 150) return;
    _lastPaintMs = now;
    _paint(partial);
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

  void _appendFinal(String text) {
    if (text.isEmpty) return;
    _finalized = '$_finalized$text ';
  }

  void _paint(String partial) {
    if (!mounted) return;
    _lastPaintMs = DateTime.now().millisecondsSinceEpoch;
    setState(() => _partial = partial);
    _followTail();
  }

  // Keep the newest words in view as the transcript grows.
  void _followTail() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  @override
  void dispose() {
    _downloadSub?.cancel();
    _pulse.dispose();
    _scroll.dispose();
    _audioSub?.cancel();
    _recorder.dispose();
    _freeModels();
    super.dispose();
  }

  static const _serif = TextStyle(fontFamily: 'GowunBatang');

  Widget _sheetText(ColorScheme colors, bool hasText) => hasText
      ? SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(20, 22, 22, 22),
          // Settled words in full ink; words still being recognised stay
          // lighter until they settle.
          child: Text.rich(
            TextSpan(
              style: _serif.copyWith(fontSize: 21, height: 1.75),
              children: [
                TextSpan(
                  text: _finalized,
                  style: TextStyle(color: colors.onSurface),
                ),
                TextSpan(
                  text: _partial,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        )
      : Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 22, 22),
          child: Text(
            _listening ? '말씀하시면 여기에 바로 적혀요' : '마이크를 누르고 말하면 여기에 적혀요',
            style: _serif.copyWith(
              fontSize: 17,
              height: 1.75,
              color: colors.onSurfaceVariant,
            ),
          ),
        );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_listening && !reduceMotion) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
    final hasText = _finalized.isNotEmpty || _partial.isNotEmpty;
    final needsModel = !_busy && !_loaded;
    final hint = _error
        ? null
        : _busy
        ? '처음 한 번만 조금 걸려요'
        : needsModel
        ? '${_model.size}를 한 번 내려받아요'
        : _listening
        ? '잠시 말을 멈추면 문장이 확정돼요'
        : '마이크는 말하는 동안에만 켜져요';
    final onMic = _busy || (needsModel && _downloadingModel != null)
        ? null
        : _loaded
        ? _toggleListening
        : () => _requestDownload(_model);

    // 1:3:6 — forest green primary 1, deep green header band 3, warm paper page 6.
    const headerInk = Colors.white;
    const lightMint = Color(0xffcfe0d3);
    const mint = Color(0xff9bbfa6);
    const headerTeal = Color(0xff1f3a31);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        systemNavigationBarColor: colors.surface,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: colors.surface,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: headerTeal,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // The logo's mint underline, under the chosen model.
                      DecoratedBox(
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: mint, width: 3),
                          ),
                        ),
                        child: DropdownButton<SpeechModel>(
                          value: _model,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          itemHeight: 56,
                          borderRadius: BorderRadius.circular(14),
                          dropdownColor: colors.surfaceContainer,
                          iconEnabledColor: mint,
                          iconDisabledColor: lightMint,
                          onChanged: _busy || _listening
                              ? null
                              : (m) => _switchModel(m!),
                          // Closed: on the dark header. Open: on white.
                          selectedItemBuilder: (_) => [
                            for (final m in SpeechModel.values)
                              _ModelRow(m, main: headerInk, accent: mint),
                          ],
                          items: [
                            for (final m in SpeechModel.values)
                              DropdownMenuItem(
                                value: m,
                                child: _ModelRow(
                                  m,
                                  main: colors.onSurface,
                                  accent: colors.primary,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _model.blurb,
                        style: const TextStyle(fontSize: 13, color: lightMint),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_downloadingModel ?? _failedDownload
                          case final model?) ...[
                        _DownloadBanner(
                          label: model.label,
                          progress: _downloadFraction,
                          filesDone: _fileProgress.values
                              .where((p) => p == 1)
                              .length,
                          filesTotal: model.files.length,
                          failed: _downloadingModel == null,
                          onCancel: _cancelDownload,
                          onRetry: () => _startDownload(model),
                          onDismiss: () =>
                              setState(() => _failedDownload = null),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Expanded(
                        // A sheet of letter paper; while listening a teal
                        // margin rule marks where the words are going.
                        child: Container(
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: colors.surfaceContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              AnimatedContainer(
                                duration: reduceMotion
                                    ? Duration.zero
                                    : const Duration(milliseconds: 200),
                                width: 4,
                                color: _listening
                                    ? colors.primary
                                    : Colors.transparent,
                              ),
                              Expanded(child: _sheetText(colors, hasText)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: _MicButton(
                          pulse: _pulse,
                          listening: _listening,
                          busy: _busy,
                          icon: needsModel
                              ? Icons.download_rounded
                              : _listening
                              ? Icons.stop_rounded
                              : Icons.mic_rounded,
                          label: needsModel
                              ? '${_model.label} 모델 내려받기'
                              : _listening
                              ? '받아쓰기 멈추기'
                              : '말하기 시작',
                          onPressed: onMic,
                        ),
                      ),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _status,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                            color: _error ? colors.error : colors.onSurface,
                          ),
                        ),
                      ),
                      if (hint != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          hint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Model name on the left, when to pick it on the right.
class _ModelRow extends StatelessWidget {
  const _ModelRow(this.model, {required this.main, required this.accent});

  final SpeechModel model;
  final Color main;
  final Color accent;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        model.label,
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: main,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          '${model.recommend} 추천',
          textAlign: TextAlign.end,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: accent),
        ),
      ),
    ],
  );
}

/// The mic as the logo's teal tile; a mint outline ripples out while listening.
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

  static const _size = 88.0;
  // Same corner ratio and gradient as the logo tile (rx 62 on 224).
  static const _radius = _size * 62 / 224;
  static const _tile = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xff3a6d5b), Color(0xff244a3e)],
  );
  static const _mint = Color(0xff9bbfa6);
  static const _paper = Color(0xfff4f3ef);

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
    );
    return SizedBox.square(
      dimension: _size * 1.5,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (listening)
            AnimatedBuilder(
              animation: pulse,
              builder: (context, _) {
                final grow = 1 + 0.4 * pulse.value;
                return Container(
                  width: _size * grow,
                  height: _size * grow,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_radius * grow),
                    border: Border.all(
                      color: _mint.withValues(alpha: 1 - pulse.value),
                      width: 3,
                    ),
                  ),
                );
              },
            ),
          Semantics(
            button: true,
            label: label,
            child: Tooltip(
              message: label,
              child: Opacity(
                opacity: onPressed == null ? 0.4 : 1,
                child: Ink(
                  width: _size,
                  height: _size,
                  decoration: ShapeDecoration(gradient: _tile, shape: shape),
                  child: InkWell(
                    customBorder: shape,
                    onTap: onPressed,
                    child: busy
                        ? const Padding(
                            padding: EdgeInsets.all(28),
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: _paper,
                            ),
                          )
                        : Icon(icon, size: 38, color: _paper),
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

/// Shows the background model download without blocking the current model.
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
              '파일 $filesDone/$filesTotal개 받음 · 화면을 꺼도 계속 받아요',
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
