import 'dart:convert';

import '../mail/mail.dart';
import '../mail/mail_account.dart';
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
  const VoiceIntent({
    required this.action,
    this.service,
    this.only = false,
    this.fromStart = false,
    this.today = false,
    this.content,
  });

  final IntentAction action;

  /// The account named, if any.
  final MailService? service;

  /// Only [service]'s mail; otherwise it goes first and the rest follow.
  final bool only;
  final bool fromStart;
  final bool today;

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
    final content = json['content'];
    return VoiceIntent(
      action: action,
      service: MailService.values.asNameMap()[json['service']],
      only: json['only'] == true,
      fromStart: json['from_start'] == true,
      today: json['today'] == true,
      content: content is String && content.trim().isNotEmpty
          ? content.trim()
          : null,
    );
  } on FormatException {
    return null;
  }
}

/// The mails to read for [intent], keeping their order otherwise.
List<Mail> pickMails(
  List<Mail> mails,
  VoiceIntent intent, {
  required DateTime now,
}) {
  final day = [
    for (final m in mails)
      if (!intent.today || _sameDay(m.date?.toLocal(), now)) m,
  ];
  final service = intent.service;
  if (service == null) return day;
  final named = [
    for (final m in day)
      if (m.account?.service == service) m,
  ];
  if (intent.only) return named;
  return [...named, ...day.where((m) => !named.contains(m))];
}

bool _sameDay(DateTime? a, DateTime b) =>
    a != null && a.year == b.year && a.month == b.month && a.day == b.day;

String intentPrompt(
  String said, {
  required List<MailService> services,
  required bool reading,
}) =>
    '메일을 소리로 읽어 주는 앱이에요. 사용자가 말한 문장을 보고 '
    '아래 JSON 하나로만 답해 주세요. 설명은 쓰지 마세요.\n'
    '{"action": "read|later|reply|none", '
    '"service": "${MailService.values.map((s) => s.name).join('|')}|null", '
    '"only": true|false, "from_start": true|false, "today": true|false, '
    '"content": "답장 내용 또는 null"}\n'
    '- read: 메일을 읽어 달라는 말. 특정 계정만이면 service와 only:true, '
    '그 계정부터면 only:false, 처음부터면 from_start:true, 오늘 온 것만이면 today:true\n'
    '- later: 나중에, 끝내자는 말\n'
    '- reply: 지금 메일에 답장하자는 말. 보낼 내용도 말했으면 content에\n'
    '- none: 앱에게 하는 말이 아님 (다른 사람과의 대화, 앱이 읽어 준 메일 문장)\n'
    '연결된 계정: ${services.map((s) => '${s.name}(${s.label})').join(', ')}\n'
    '지금 상태: ${reading ? '메일을 읽어 주는 중' : '읽어 드릴지 묻는 중'}\n'
    '사용자: $said';

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
