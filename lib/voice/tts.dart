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
    for (final part in speechParts(speakable(text))) {
      if (run != _run) return;
      await _tts.speak(part);
    }
  }

  Future<void> stop() async {
    _run++;
    speaking.value = false;
    await _tts.stop();
  }
}

/// Engines cap one utterance (Android at ~4000 chars), so long mails are
/// read in line-sized parts of at most [max] chars.
@visibleForTesting
Iterable<String> speechParts(String text, {int max = 1000}) sync* {
  final buffer = StringBuffer();
  for (var line in text.split(RegExp(r'\n+'))) {
    line = line.trim();
    // What came before goes first, or the long line jumps ahead of it.
    if (line.length > max && buffer.isNotEmpty) {
      yield buffer.toString();
      buffer.clear();
    }
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

/// A mail body as read aloud: without the quoted mail it answers, the
/// signature and a newsletter's 수신거부 footer. Falls back to the whole
/// body if that would leave nothing.
String spokenBody(String body) {
  final kept = <String>[];
  // IMAP bodies keep their CRLFs, which hid the '-- ' signature line.
  final lines = body.replaceAll('\r\n', '\n').split('\n');
  // Outlook's quoted header is a From: line followed by Sent: or To:;
  // a From: alone is just a line of the mail (a flight's "From: ICN").
  bool header(int i) =>
      _fromLine.hasMatch(lines[i].trim()) &&
      i + 1 < lines.length &&
      _headerLine.hasMatch(lines[i + 1].trim());
  for (final (i, raw) in lines.indexed) {
    final line = raw.trim();
    // What follows is an earlier mail or a signature.
    if (_quoteStart.hasMatch(line) || header(i) || raw == '-- ') break;
    // A footer: only in the latter half, where newsletters put it.
    if (i > lines.length / 2 && _footer.hasMatch(line)) break;
    if (line.startsWith('>') || _sentFrom.hasMatch(line)) continue;
    kept.add(raw);
  }
  final text = kept.join('\n').trim();
  return text.isEmpty ? body : text;
}

/// The line that starts a quoted or forwarded mail: Gmail's "2026년 … 님이
/// 작성:" and "On … wrote:", and "-----Original Message-----". Outlook's
/// header block is [_fromLine] then [_headerLine].
final _quoteStart = RegExp(
  r'^\d.*님이 작성:$|^on\s.+\swrote:$|^-{3,}\s*(original message|원본 메일|forwarded message|전달된 메일)',
  caseSensitive: false,
);
final _fromLine = RegExp(r'^(from|보낸 사람)\s*:', caseSensitive: false);
final _headerLine = RegExp(
  r'^(sent|date|to|보낸 날짜|날짜|받는 사람)\s*:',
  caseSensitive: false,
);
final _sentFrom = RegExp(
  r'^(sent from my \w+|\S+에서 보냄)$',
  caseSensitive: false,
);

/// A newsletter's footer, phrased as one: "수신거부는 여기", "[수신거부]",
/// "수신을 원하지 않으시면", "Unsubscribe". Not "수신거부 요청드립니다".
final _footer = RegExp(
  r'수신\s*거부\s*(하|를|는|안내|링크|\]|$)|수신을 원하지|unsubscribe|발신\s*전용',
  caseSensitive: false,
);

const _digits = ['공', '일', '이', '삼', '사', '오', '육', '칠', '팔', '구'];

/// [text] as the phone's voice should hear it: links, symbols and emoji
/// that it would spell out or name are dropped or put into words.
String speakable(String text) {
  String digits(String n) =>
      [for (final c in n.split('')) _digits[int.parse(c)]].join();
  return text
      .replaceAll(RegExp(r'(https?://|www\.)\S+'), '링크')
      // Before addresses and dates, whose dots and dashes they share.
      .replaceAllMapped(
        RegExp(
          // 15xx/16xx/18xx-xxxx are company lines; not years or amounts.
          r'(?<![\d.])(0\d{1,2}-\d{3,4}|1[568]\d{2}-\d{4})(?:-(\d{4}))?(?![\d.]|\s*[년원대])',
        ),
        (m) => [...m[1]!.split('-'), ?m[2]].map(digits).join(', '),
      )
      .replaceAllMapped(
        RegExp(r'([\w.+-]+)@([\w-]+(?:\.[\w-]+)+)'),
        (m) => '${m[1]} 골뱅이 ${m[2]}',
      )
      .replaceAllMapped(
        RegExp(r'(?<!\d)(20\d\d)[.\-/](\d{1,2})[.\-/](\d{1,2})\.?(?!\d)'),
        (m) => '${m[1]}년 ${int.parse(m[2]!)}월 ${int.parse(m[3]!)}일',
      )
      // Before times, which would turn 10:00~12:00 into 10시~12시.
      .replaceAllMapped(RegExp(r'(\d)\s*~\s*(\d)'), (m) => '${m[1]}에서 ${m[2]}')
      .replaceAllMapped(
        RegExp(r'(?<![\d:])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])'),
        (m) =>
            '${int.parse(m[1]!)}시${m[2] == '00' ? '' : ' ${int.parse(m[2]!)}분'}',
      )
      .replaceAllMapped(RegExp(r'₩\s?([\d,]+)'), (m) => '${m[1]}원')
      .replaceAllMapped(RegExp(r'\$\s?([\d,.]+)'), (m) => '${m[1]}달러')
      .replaceAllMapped(RegExp(r'€\s?([\d,.]+)'), (m) => '${m[1]}유로')
      // Emoji (with their joiners and variation selectors), drawn lines,
      // bullets and boxes the voice would name one by one.
      .replaceAll(
        RegExp(
          // The analyzer doesn't know this property; the Dart VM does.
          // ignore: valid_regexps
          r'[\p{Extended_Pictographic}\u{200D}\u{FE0F}\u{20E3}\u{1F3FB}-\u{1F3FF}]',
          unicode: true,
        ),
        '',
      )
      .replaceAll(RegExp(r'[─━│┃┌┐└┘├┤■□▶▷◀◁▲△▼▽●○◆◇★☆※♥♡◎•·~]'), ' ')
      .replaceAll(RegExp(r'([-=_*#+])\1{2,}'), ' ')
      .replaceAll(RegExp(r'[ㅋㅎㅠㅜ]{2,}'), '')
      .replaceAllMapped(RegExp(r'([!?.])\1+'), (m) => m[1]!)
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ');
}
