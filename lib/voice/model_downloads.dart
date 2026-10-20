import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'speech.dart';
import '../widgets.dart';

/// Speech model downloads, handed to the OS so they go on with the screen
/// off or the app closed. One model downloads at a time.
class ModelDownloads extends ChangeNotifier with SafeNotifier {
  ModelDownloads({required this.onDone});

  /// Called once every file of a model is on the phone.
  final Future<void> Function(SpeechModel model) onDone;

  SpeechModel? downloading;

  /// Last download that ended with a file missing, until dismissed.
  SpeechModel? failed;
  final _fileProgress = <String, double>{};
  final _failedFiles = <String>{};

  /// Models fully on the phone, for 음성 설정.
  Set<SpeechModel> onPhone = {};

  /// What the download banner shows: the running download, or a failed one.
  SpeechModel? get shown => downloading ?? failed;

  int get filesDone => _fileProgress.values.where((p) => p == 1).length;

  double get fraction {
    final files = downloading?.files ?? const {};
    final total = files.values.fold(0, (a, b) => a + b);
    var done = 0.0;
    for (final MapEntry(key: name, value: size) in files.entries) {
      done += size * (_fileProgress[name] ?? 0);
    }
    return total == 0 ? 0 : done / total;
  }

  Future<void> init() async {
    // Zipformer was dropped; free the ~140 MB older builds downloaded.
    final dropped = Directory(
      '${(await getApplicationSupportDirectory()).path}/models/zipformer',
    );
    if (await dropped.exists()) await dropped.delete(recursive: true);
    final downloader = bd.FileDownloader();
    for (final model in SpeechModel.values) {
      // Per-group callbacks, not the single-listener `updates` stream, which
      // the summary model's downloader (flutter_gemma) also needs.
      downloader.registerCallbacks(
        group: model.name,
        taskStatusCallback: _onUpdate,
        taskProgressCallback: _onUpdate,
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
    // Killed tasks are restarted by _resume, not the package, so a file
    // never downloads twice at once.
    await downloader.start(doRescheduleKilledTasks: false);
    for (final model in SpeechModel.values) {
      if ((await downloader.allTasks(group: model.name)).isNotEmpty) {
        await _markFinishedFiles(model);
        downloading = model;
        notifyListeners();
        break;
      }
      if (await (await _pendingMark(model)).exists()) {
        await _resume(model);
        break;
      }
    }
    if (downloading == null) await _deleteStaleTempFiles();
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
  Future<void> _resume(SpeechModel model) async {
    // Finished while the app was closed.
    if (await model.downloaded) return _clearPendingMark(model);
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
    await start(model, skip: resumed);
  }

  Future<void> _markFinishedFiles(SpeechModel model) async {
    _fileProgress.clear();
    _failedFiles.clear();
    for (final task in model.tasks) {
      if (await SpeechModel.fileDone(task)) _fileProgress[task.metaData] = 1;
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

  /// Hands [model]'s missing files, less [skip], to the OS downloader.
  Future<void> start(SpeechModel model, {Set<String> skip = const {}}) async {
    // Set before any await so the buttons lock right away; otherwise the
    // notification prompt left the mic tappable and it asked again.
    downloading = model;
    failed = null;
    notifyListeners();
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

  Future<void> cancel() async {
    final model = downloading;
    if (model != null) {
      await bd.FileDownloader().cancelAll(group: model.name);
      await _clearPendingMark(model);
    }
    downloading = null;
    notifyListeners();
  }

  void dismiss() {
    failed = null;
    notifyListeners();
  }

  void _onUpdate(bd.TaskUpdate update) {
    final model = SpeechModel.forGroup(update.task.group);
    if (model == null) return;
    final name = update.task.metaData;
    switch (update) {
      case bd.TaskProgressUpdate(:final progress):
        if (progress < 0) return; // Negative values are status codes.
        final before = (fraction * 100).floor();
        // Never step back: a resume or retry restarts the reported progress
        // at 0 (or a stale value), which made the bar jump down and up.
        // ponytail: a true restart from zero shows a stalled bar until it
        // catches up; fine since that only happens after a failed resume.
        if (progress <= (_fileProgress[name] ?? 0)) return;
        _fileProgress[name] = progress;
        if ((fraction * 100).floor() != before) notifyListeners();
      case bd.TaskStatusUpdate(:final status):
        switch (status) {
          case bd.TaskStatus.complete:
            _fileProgress[name] = 1;
            _finish(model);
          case bd.TaskStatus.failed || bd.TaskStatus.notFound:
            debugPrint(
              'Model file failed: $name '
              '${update.responseStatusCode} ${update.exception?.description}',
            );
            _failedFiles.add(name);
            _finish(model);
          // cancel() already hid the banner. Any other cancel is iOS
          // reporting, at relaunch, the task it stopped; _resume has
          // replaced it.
          case bd.TaskStatus.canceled:
            break;
          default:
            if (downloading == null) {
              downloading = model;
              notifyListeners();
            }
        }
    }
  }

  /// Settles once every file has ended. One failed file no longer cancels
  /// the rest: the OS notification kept saying "downloading" for those while
  /// the app already said "failed", and retrying only fetches what's missing.
  Future<void> _finish(SpeechModel model) async {
    final pending = model.files.keys.any(
      (f) => _fileProgress[f] != 1 && !_failedFiles.contains(f),
    );
    if (pending) return;
    await _clearPendingMark(model);
    downloading = null;
    if (_failedFiles.isNotEmpty || !await model.downloaded) {
      failed = model;
      return notifyListeners();
    }
    notifyListeners();
    await refreshOnPhone();
    await onDone(model);
  }

  Future<void> refreshOnPhone() async {
    onPhone = {
      for (final model in SpeechModel.values)
        if (await model.downloaded) model,
    };
    notifyListeners();
  }

  /// Forgets a deleted model's records, which would start a new download's
  /// bar at 99%.
  Future<void> forget(SpeechModel model) async {
    await bd.FileDownloader().database.deleteAllRecords(group: model.name);
    await refreshOnPhone();
  }

  @override
  void dispose() {
    for (final model in SpeechModel.values) {
      bd.FileDownloader().unregisterCallbacks(group: model.name);
    }
    super.dispose();
  }
}
