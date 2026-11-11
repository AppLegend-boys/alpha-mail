import 'dart:convert';

import '../mail/mail.dart';
import '../screens/mail_view.dart' show isSkipCommand;

/// The few words the voice home takes on its own, without asking Gemma:
/// the ones that can't wait for it, and the ones a mail going out must
/// never hang on a model's guess.
enum Quick { stop, next, send, cancel, again }

/// [confirming] is the "보낼까요?" step of a spoken reply, the only time
/// 보내·취소·다시 count. They count only said alone, so "4시로 보내자" or
/// "보내 주신 거" goes to Gemma as a change instead of sending.
Quick? quickCommand(String said, {bool confirming = false}) {
  if (_stop.hasMatch(said)) return Quick.stop;
  if (!confirming) return isSkipCommand(said) ? Quick.next : null;
  if (_bare('보내').hasMatch(said)) return Quick.send;
  if (_bare('취소').hasMatch(said)) return Quick.cancel;
  if (_bare('다시').hasMatch(said)) return Quick.again;
  return null;
}

final _stop = RegExp(r'그만|멈춰');
RegExp _bare(String word) =>
    RegExp('^\\s*$word\\s*(요|해|해 줘|해줘|줘)?\\s*[.!?]?\\s*\$');

/// What Gemma understood a sentence to ask for.
enum IntentAction { read, later, reply, none }

class VoiceIntent {
  const VoiceIntent({required this.action, this.mails, this.content});

  final IntentAction action;

  /// The listed mails to read, by number, in Gemma's order; null reads
  /// the unread ones as they come.
  final List<int>? mails;

  /// What to say in a reply, when it came with the request.
  final String? content;
}

/// Gemma's answer as an intent, or null when it isn't the JSON asked for.
VoiceIntent? parseIntent(String output) {
  final start = output.indexOf('{');
  final end = output.lastIndexOf('}');
  if (start < 0 || end < start) return null;
  try {
    final json = jsonDecode(output.substring(start, end + 1));
    if (json is! Map) return null;
    final action = IntentAction.values.asNameMap()[json['action']];
    if (action == null) return null;
    final mails = json['mails'];
    final content = json['content'];
    return VoiceIntent(
      action: action,
      mails: mails is List ? mails.whereType<int>().toList() : null,
      content: content is String && content.trim().isNotEmpty
          ? content.trim()
          : null,
    );
  } on FormatException {
    return null;
  }
}

/// The [listed] mails Gemma [picked], skipping numbers that aren't there.
List<Mail> pickMails(List<Mail> listed, List<int> picked) => [
  for (final i in {...picked})
    if (i >= 0 && i < listed.length) listed[i],
];

/// Gemma reads [mails] itself and picks by number, so "네이버만",
/// "오늘 온 거" or "민지 메일" need no rule each. The first [unread] are
/// unread; the rest were read in this conversation.
String intentPrompt(
  String said, {
  required List<Mail> mails,
  required int unread,
  required bool reading,
  required DateTime now,
}) {
  String day(DateTime? d) => d == null
      ? ''
      : _sameDay(d, now)
      ? '오늘'
      : _sameDay(d, now.subtract(const Duration(days: 1)))
      ? '어제'
      : '${d.month}월 ${d.day}일';
  final list = [
    for (final (i, m) in mails.indexed)
      [
        '$i. ${m.account?.service.label ?? ''}',
        m.from,
        m.subject,
        day(m.date?.toLocal()),
        if (i >= unread) '이미 읽음',
      ].join(' · '),
  ].join('\n');
  // Examples, not a "true|false" template: given one, Gemma filled every
  // key and "네이버만" came back as only today's mail.
  return '메일을 소리로 읽어 주는 앱이에요. 사용자가 한 말을 아래 예시처럼 JSON 한 줄로만 '
      '바꿔 주세요. 설명은 쓰지 마세요.\n'
      '사용자의 말은 음성인식으로 받아 적은 것이라 소리가 비슷한 다른 말로 '
      '잘못 적혀 있을 수 있어요. 예를 들어 "이거줘"는 "읽어 줘", '
      '"네이버 메 말"은 "네이버 메일"일 수 있으니 소리를 떠올려 뜻을 짐작하세요.\n\n'
      '예시 메일 목록:\n'
      '0. 네이버 메일 · 김민지 · 회의 일정 · 어제\n'
      '1. Gmail · 쿠팡 · 배송 안내 · 오늘\n'
      '2. 네이버 메일 · 박서준 · 견적서 · 오늘 · 이미 읽음\n'
      '예시:\n'
      '"응 읽어 줘" → {"action":"read"}\n'
      '"네이버 메일만 읽어 줘" → {"action":"read","mails":[0]}\n'
      '"지메일로 바꿔 줘" → {"action":"read","mails":[1]}\n'
      '"지메일부터 읽어 줘" → {"action":"read","mails":[1,0]}\n'
      '"오늘 온 거 읽어 줘" → {"action":"read","mails":[1]}\n'
      '"처음부터 다시" → {"action":"read","mails":[0,1,2]}\n'
      '"박서준 메일 읽어 줘" → {"action":"read","mails":[2]}\n'
      '"아웃룩 메일 읽어 줘" → {"action":"read","mails":[]}\n'
      '"나중에 할게" → {"action":"later"}\n'
      '"답장해 줘" → {"action":"reply"}\n'
      '"괜찮다고 보내자" → {"action":"reply","content":"괜찮다"}\n'
      '앱에게 하는 말이 아니면(다른 사람과의 대화, 앱이 읽어 준 메일 문장) '
      '→ {"action":"none"}\n'
      '이미 읽은 메일은 사용자가 처음부터, 다시, 또는 그 메일을 콕 집어 말할 때만 고르세요.\n\n'
      '지금 메일 목록:\n$list\n'
      '지금 상태: ${reading ? '메일을 읽어 주는 중' : '읽어 드릴지 묻는 중'}\n'
      '사용자: "$said" →';
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Asks Gemma for the reply text to [mail] from what the user [said], or
/// for [draft] changed the way they asked.
String replyPrompt(Mail mail, String said, {String? draft}) {
  final text = mail.body.replaceAll(RegExp(r'(https?://|www\.)\S+'), '');
  final body = text.length > 1500 ? '${text.substring(0, 1500)}…' : text;
  final ask = draft == null
      ? '사용자가 답장으로 하고 싶은 말: $said\n'
      : '지금 답장 초안:\n$draft\n\n사용자가 이렇게 고쳐 달래요: $said\n';
  return '받은 메일에 보낼 답장 본문만 한국어로 써 주세요. '
      '인사로 시작하는 존댓말로, 받은 메일의 말투에 맞추고, '
      '사용자가 말한 내용만 담아 짧게 써 주세요. '
      '마크다운, 제목, 따옴표, 설명은 쓰지 마세요.\n\n'
      '$ask\n'
      '받은 메일\n보낸 사람: ${mail.from}\n제목: ${mail.subject}\n\n$body';
}

/// "Re: " once, like every mail app.
String replySubject(String subject) =>
    subject.toLowerCase().startsWith('re:') ? subject : 'Re: $subject';
