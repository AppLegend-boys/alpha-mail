import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Reads text aloud with the phone's built-in voice. On Android only offline
/// voices are used: a network voice sends the text (the mail itself) to the
/// engine's server. iOS voices always run on the device.
class Reader {
  Reader._();
  static final instance = Reader._();

  final _tts = FlutterTts();

  /// True while something is being read.
  final speaking = ValueNotifier(false);

  /// Why reading can't work on this phone, or null once it's set up.
  Future<String?>? _ready;

  /// Bumped by every speak/stop so an older read stops between parts.
  int _run = 0;

  Future<String?> _setup() async {
    await _tts.awaitSpeakCompletion(true);
    if (Platform.isIOS) {
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [],
        IosTextToSpeechAudioMode.spokenAudio,
      );
      await _tts.setLanguage('ko-KR');
      return null;
    }
    final voices = [
      for (final v in (await _tts.getVoices as List?) ?? const [])
        Map<String, String>.from(v as Map),
    ];
    final offline = voices.where(
      (v) =>
          (v['locale'] ?? '').startsWith('ko') &&
          v['network_required'] == '0' &&
          !(v['features'] ?? '').split('\t').contains('notInstalled'),
    );
    if (offline.isEmpty) {
      return '한국어 오프라인 음성이 없어요. (V-01)';
    }
    final voice = offline.first;
    await _tts.setVoice({'name': voice['name']!, 'locale': voice['locale']!});
    return null;
  }

  /// Reads [text], then [then] once it's ready, cutting off whatever was
  /// being read. A stop while waiting for [then] skips it. Returns why it
  /// couldn't read, [cut] if a later speak or stop cut it off, or null once
  /// it was read to the end.
  Future<String?> speak(String text, {Future<String>? then}) async {
    final run = ++_run;
    await _tts.stop();
    final problem = await (_ready ??= _setup());
    if (problem != null) return problem;
    if (run != _run) return cut;
    speaking.value = true;
    await _say(text, run);
    if (then != null && run == _run) await _say(await then, run);
    if (run != _run) return cut;
    speaking.value = false;
    return null;
  }

  /// What [speak] returns when it was cut off; not a problem to show.
  static const cut = 'cut';

  Future<void> _say(String text, int run) async {
    for (final part in _parts(text)) {
      if (run != _run) return;
      await _tts.speak(part);
    }
  }

  Future<void> stop() async {
    _run++;
    speaking.value = false;
    await _tts.stop();
  }

  /// Engines cap one utterance (Android at ~4000 chars), so long mails are
  /// read in line-sized parts of at most [max] chars.
  static Iterable<String> _parts(String text, {int max = 1000}) sync* {
    final buffer = StringBuffer();
    for (var line in text.split(RegExp(r'\n+'))) {
      line = line.trim();
      while (line.length > max) {
        yield line.substring(0, max);
        line = line.substring(max);
      }
      if (buffer.length + line.length > max) {
        yield buffer.toString();
        buffer.clear();
      }
      if (line.isNotEmpty) buffer.writeln(line);
    }
    if (buffer.isNotEmpty) yield buffer.toString();
  }
}

/// A mail body as read aloud, with links replaced so long URLs aren't
/// spelled out.
String spokenBody(String body) =>
    body.replaceAll(RegExp(r'https?://\S+'), '링크');
