import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../widgets.dart';

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

  /// Every file is on the phone at full size, after moving any an older
  /// build left in the cache.
  Future<bool> get downloaded async {
    for (final task in tasks) {
      if (!await fileDone(task)) return false;
    }
    return true;
  }

  /// Folder sherpa-onnx loads this model from.
  Future<String> get dir async =>
      File(await tasks.first.filePath()).parent.path;

  static Future<bool> fileDone(bd.DownloadTask task) async {
    final file = File(await task.filePath());
    final size = forGroup(task.group)?.files[task.metaData];
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
}

/// Runs an offline recogniser on its own isolate so slow models (Qwen3 takes
/// a second or more per sentence on a phone) never freeze the UI.
class _OfflineWorker {
  _OfflineWorker._(this._inbox, this._outbox, this._waiting, this._died);

  final ReceivePort _inbox;
  final SendPort _outbox;
  final Queue<Completer<String>> _waiting;

  /// Completes once the isolate has crashed or exited.
  final Completer<void> _died;

  int get pending => _waiting.length;

  static Future<_OfflineWorker> spawn(
    sherpa.OfflineRecognizerConfig config,
  ) async {
    final inbox = ReceivePort();
    final ready = Completer<SendPort>();
    final waiting = Queue<Completer<String>>();
    final died = Completer<void>();
    inbox.listen((message) {
      if (message is String && ready.isCompleted) {
        if (waiting.isNotEmpty) waiting.removeFirst().complete(message);
      } else if (message is SendPort) {
        ready.complete(message);
      } else {
        // An init error (String), a crash ([error, stack]) or the exit
        // (null): without this a dead worker left the load waiting forever.
        if (!ready.isCompleted) ready.completeError(Exception(message));
        if (!died.isCompleted) died.complete();
        for (final result in waiting) {
          result.complete('');
        }
        waiting.clear();
      }
    });
    await Isolate.spawn(
      _run,
      (inbox.sendPort, config),
      onError: inbox.sendPort,
      onExit: inbox.sendPort,
    );
    try {
      return _OfflineWorker._(inbox, await ready.future, waiting, died);
    } catch (_) {
      inbox.close();
      rethrow;
    }
  }

  Future<String> transcribe(Float32List samples) {
    if (_died.isCompleted) return Future.value('');
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

/// The mic and the recogniser: loads one model at a time, listens, and
/// turns what the VAD cuts into sentences into [heard].
class Recognizer extends ChangeNotifier with SafeNotifier {
  final _recorder = AudioRecorder();
  SpeechModel model = SpeechModel.senseVoice;
  // Utterance model fed by voice-activity segments.
  _OfflineWorker? _offline;
  sherpa.VoiceActivityDetector? _vad;
  final _vadPending = <double>[];
  StreamSubscription<Uint8List>? _audioSub;

  /// What the user has said since the mic went on.
  String heard = '';

  /// '…' while a sentence is still being written.
  String partial = '';
  String status = '모델을 준비하고 있어요';
  bool busy = true;

  /// Being deleted, so its card says so instead of 적용 중.
  SpeechModel? deleting;
  bool listening = false;
  bool error = false;

  /// Called whenever [heard] or [partial] changes, to look for a command.
  /// The screen in charge of the mic swaps it for its own.
  VoidCallback? onSpeech;

  /// Bumped each time the mic goes on, so a sentence still being written
  /// from an earlier listen never lands in the new one (a late "보내" could
  /// have sent a mail).
  int _session = 0;

  bool get loaded => _offline != null;

  /// Whether the mic may be used, without asking for it.
  Future<bool> get micAllowed => _recorder.hasPermission(request: false);

  /// The VAD hears speech right now, mid-sentence.
  bool get hearing => _vad?.isDetected() ?? false;

  static const missed = '잘 듣지 못했어요. 다시 말씀해 주세요.';

  /// Starts on the first model already on the phone.
  Future<void> start() async {
    try {
      for (final m in SpeechModel.values) {
        if (await m.downloaded) {
          model = m;
          break;
        }
      }
    } catch (error) {
      debugPrint('Speech model check failed: $error');
    }
    await _load();
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
  void _free() {
    _vad?.free();
    _offline?.dispose();
    _vad = null;
    _offline = null;
    _vadPending.clear();
  }

  void _ready(String text, {bool failed = false}) {
    busy = false;
    error = failed;
    status = text;
    notifyListeners();
    _switchQueued();
  }

  Future<void> _load() async {
    final threads = Platform.numberOfProcessors.clamp(2, 4);
    try {
      sherpa.initBindings();
      _free();
      if (!await model.downloaded) return _ready('먼저 음성 모델을 내려받아 주세요');
      final dir = await model.dir;
      final config = model == SpeechModel.senseVoice
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
        sherpa.OfflineRecognizerConfig(model: config),
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
      _ready('말할 준비가 됐어요');
    } catch (_) {
      _ready('음성 모델을 불러오지 못했어요. 다른 모델을 골라 주세요.', failed: true);
    }
  }

  /// A model that finished downloading while the mic was busy; loaded as
  /// soon as it's free.
  SpeechModel? _queued;

  /// Loads a freshly downloaded [m] now, or once the mic is free.
  Future<void> switchWhenFree(SpeechModel m) async {
    if (busy || listening) {
      _queued = m;
      return;
    }
    await switchTo(m);
  }

  void _switchQueued() {
    final next = _queued;
    _queued = null;
    if (next != null) switchTo(next);
  }

  /// Loads [m] unless the mic is busy. False when [m] isn't on the phone
  /// yet and has to be downloaded first.
  Future<bool> switchTo(SpeechModel m) async {
    if (busy || listening || (m == model && loaded)) return true;
    if (!await m.downloaded) return false;
    model = m;
    busy = true;
    error = false;
    heard = '';
    partial = '';
    status = '모델을 적용 중이에요';
    notifyListeners();
    await _load();
    return true;
  }

  /// Deletes [m]'s files; the one in use is unloaded first and another
  /// model on the phone, if any, takes over. [removed] runs once the files
  /// are gone. False when deleting failed; the lock comes off either way.
  Future<bool> delete(
    SpeechModel m, {
    required Future<void> Function() removed,
  }) async {
    if (busy || listening) return true;
    // Locked while deleting, so nothing downloads or loads this model meanwhile.
    busy = true;
    deleting = m;
    notifyListeners();
    var ok = true;
    try {
      if (m == model) _free();
      final dir = Directory(await m.dir);
      if (await dir.exists()) await dir.delete(recursive: true);
      await removed();
    } catch (error) {
      debugPrint('Deleting ${m.name} failed: $error');
      ok = false;
    }
    deleting = null;
    if (m != model) {
      busy = false;
      notifyListeners();
      return ok;
    }
    try {
      for (final other in SpeechModel.values) {
        if (await other.downloaded) {
          model = other;
          break;
        }
      }
    } catch (_) {
      // _load below reports the model as missing.
    }
    status = '모델을 적용 중이에요';
    notifyListeners();
    await _load();
    return ok;
  }

  /// Back to the resting home after a command was handled.
  /// [dropPending] also discards sentences still being written, so a screen
  /// handing the mic back leaves nothing to arrive later.
  void clear({bool dropPending = false}) {
    if (dropPending) _session++;
    heard = '';
    partial = '';
    status = '말할 준비가 됐어요';
    notifyListeners();
  }

  /// [echoCancel] filters out the phone's own speaker, for listening while
  /// the app reads aloud.
  Future<void> toggleListening({bool echoCancel = false}) async {
    if (busy) return;
    if (listening) {
      await _audioSub?.cancel();
      await _recorder.stop();
      final vad = _vad;
      if (vad != null) {
        vad.flush();
        _drainVad();
        vad.reset();
        _vadPending.clear();
      }
      listening = false;
      partial = (_offline?.pending ?? 0) > 0 ? '…' : '';
      status = heard.isEmpty && partial.isEmpty ? missed : '말할 준비가 됐어요';
      notifyListeners();
      return _switchQueued();
    }
    try {
      if (!await _recorder.hasPermission()) {
        error = true;
        status = '설정에서 마이크 권한을 허용해 주세요';
        return notifyListeners();
      }
      final audio = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: echoCancel,
          noiseSuppress: echoCancel,
        ),
      );
      listening = true;
      _session++;
      error = false;
      heard = '';
      partial = '';
      status = '듣고 있어요';
      notifyListeners();
      _audioSub = audio.listen(
        _feed,
        onError: (_) {
          // Stopped too, so the next tap starts one recording, not a second.
          _audioSub?.cancel();
          _recorder.stop();
          listening = false;
          error = true;
          status = '마이크를 시작하지 못했어요';
          notifyListeners();
        },
      );
    } catch (_) {
      listening = false;
      error = true;
      status = '녹음 기능을 사용할 수 없어요';
      notifyListeners();
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
    final session = _session;
    while (!vad.isEmpty()) {
      worker.transcribe(vad.front().samples).then((text) {
        if (session != _session) return;
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
  static final _notKorean = RegExp(r'[぀-ヿ㐀-䶿一-鿿豈-﫿　-〿！-／]+');
  static String _koreanOnly(String text) =>
      text.replaceAll(_notKorean, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  void _appendFinal(String text) {
    text = _koreanOnly(text);
    if (text.isEmpty) return;
    heard = heard.isEmpty ? text : '$heard $text';
    onSpeech?.call();
  }

  void _paint(String text) {
    partial = text == '…' ? text : _koreanOnly(text);
    notifyListeners();
    onSpeech?.call();
  }

  @override
  void dispose() {
    onSpeech = null;
    _audioSub?.cancel();
    _recorder.dispose();
    _free();
    super.dispose();
  }
}
