import 'dart:async';

import 'package:flutter/material.dart';

import '../mail/mail.dart';
import '../mail/mail_account.dart';
import '../voice/speech.dart';
import '../voice/tts.dart';
import '../widgets.dart';

enum SendAnswer { yes, no, again, unclear }

// ponytail: keyword match like home's commands. "보내지 마" is checked as a
// no before "보내" can count as a yes, and a bare "응"/"네" is a yes only as
// the whole answer.
final _no = RegExp(r'취소|그만|나중|아니|말아|보내지\s*마');
final _again = RegExp(r'다시');
final _yes = RegExp(r'보내|^\s*(응|네|예)\s*[.!?]?\s*$');

/// Reads the answer to 보낼까요?. Only a clear yes sends.
SendAnswer sendAnswer(String said) => _no.hasMatch(said)
    ? SendAnswer.no
    : _again.hasMatch(said)
    ? SendAnswer.again
    : _yes.hasMatch(said)
    ? SendAnswer.yes
    : SendAnswer.unclear;

/// The address of whoever [said] names: a spoken address ("minji 골뱅이
/// 네이버 닷 컴") or, from [contacts] (name → address), a name.
String? findRecipient(String said, Map<String, String> contacts) {
  var spoken = said.toLowerCase();
  for (final (word, text) in [
    (RegExp(r'골뱅이|앳'), '@'),
    (RegExp(r'닷|점'), '.'),
    (RegExp(r'지메일'), 'gmail'),
    (RegExp(r'네이버'), 'naver'),
    (RegExp(r'다음'), 'daum'),
    (RegExp(r'컴'), 'com'),
    (RegExp(r'넷'), 'net'),
  ]) {
    spoken = spoken.replaceAll(word, text);
  }
  final address = RegExp(
    r'[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]+',
  ).firstMatch(spoken.replaceAll(RegExp(r'\s'), ''))?[0];
  if (address != null) return address.replaceAll(RegExp(r'\.+$'), '');
  // "허재혁 님에게요." → 허재혁
  String bare(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\s.,!?]'), '')
      .replaceAll(RegExp(r'(님|씨|께|에게|한테|요)+$'), '');
  final name = bare(said);
  if (name.length < 2) return null;
  for (final MapEntry(key: contact, value: address) in contacts.entries) {
    final known = bare(contact);
    if (known.length >= 2 && (known.contains(name) || name.contains(known))) {
      return address;
    }
  }
  return null;
}

/// Where the voice flow is: the app talking, the user dictating, the user
/// answering 보낼까요?, or the mail going out.
enum _Step { idle, talking, dictating, naming, confirming, sending }

/// 04 — writes a new mail, or with [mail] a reply to it; nothing is sent
/// without a clear yes.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({
    super.key,
    required this.from,
    this.mail,
    this.accounts = const [],
    this.account,
    this.speech,
    this.byVoice = false,
    this.contacts = const {},
  });

  /// Names to addresses the voice flow can pick a recipient from.
  final Map<String, String> contacts;
  final List<String> from;

  /// The mail being answered; null for a new mail.
  final Mail? mail;

  /// Accounts a new mail can go from, starting at [account].
  final List<MailAccount> accounts;
  final MailAccount? account;

  /// The recogniser for writing by voice; null hides the mic.
  final Recognizer? speech;

  /// Starts by asking for the body aloud and writing down the answer.
  final bool byVoice;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  final _reader = Reader.instance;
  late final _to = TextEditingController(text: widget.mail?.address);
  late final _subject = TextEditingController(
    text: switch (widget.mail?.subject) {
      null => '',
      final s when s.toLowerCase().startsWith('re:') => s,
      final s => 'Re: $s',
    },
  );
  late final _body = TextEditingController(text: widget.mail?.draft);
  late MailAccount? _sender =
      widget.mail?.account ?? widget.account ?? widget.accounts.firstOrNull;

  _Step _step = _Step.idle;

  /// The body before dictating, so 다시 can start over from it.
  String _base = '';

  /// Why the voice flow stopped, shown until it starts again.
  String? _note;

  /// Times 보낼까요? or 누구에게 was asked again after an answer it didn't
  /// understand.
  int _asked = 0;

  /// The body came from dictating, so the mic picks up at the recipient or
  /// 보낼까요? instead of asking for the body again.
  bool _dictated = false;

  /// How long the mic has heard nothing, to tell when the user is done.
  Duration _quiet = Duration.zero;
  Timer? _ticker;
  static const _tick = Duration(milliseconds: 400);

  /// Home's command handler, given back when the voice flow ends.
  VoidCallback? _homeOnSpeech;

  /// Set once 보냈어요 is said, so closing the screen doesn't cut it off.
  bool _keepVoice = false;

  Recognizer? get _speech => widget.speech;

  @override
  void initState() {
    super.initState();
    _speech?.addListener(_redraw);
    if (widget.byVoice) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _dictate());
    }
  }

  @override
  void dispose() {
    _release();
    _speech?.removeListener(_redraw);
    if (!_keepVoice) _reader.stop();
    _to.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  void _redraw() => setState(() {});

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Takes the mic's speech callback from home, which would otherwise hear
  /// "응" in the reply as its own command.
  void _take() {
    final s = _speech!;
    if (s.onSpeech == _onSpeech) return;
    _homeOnSpeech = s.onSpeech;
    s.onSpeech = _onSpeech;
  }

  /// Stops listening and gives the mic back to home.
  void _release() {
    _ticker?.cancel();
    _ticker = null;
    final s = _speech;
    if (s == null || s.onSpeech != _onSpeech) return;
    s.onSpeech = _homeOnSpeech;
    if (s.listening) s.toggleListening();
  }

  Future<void> _mute() async {
    final s = _speech!;
    if (s.listening) await s.toggleListening();
  }

  /// Says [text] before the mic goes on, so it doesn't hear the app.
  /// False if the flow was stopped meanwhile.
  Future<bool> _say(String text) async {
    setState(() => _step = _Step.talking);
    final problem = await _reader.speak(text);
    if (!mounted || _step != _Step.talking || problem == Reader.cut) {
      return false;
    }
    // No voice: the status card shows the same words, so carry on.
    if (problem != null) _snack(problem);
    return true;
  }

  Future<void> _listen(_Step step) async {
    final s = _speech!;
    _quiet = Duration.zero;
    setState(() => _step = step);
    if (!s.listening) await s.toggleListening();
    if (!mounted || _step != step) return;
    if (!s.listening) return _stop(s.status);
    _ticker ??= Timer.periodic(_tick, _onTick);
  }

  /// The voice flow: asks for the mail, writes down what is said, reads it
  /// back and sends it only on a clear yes.
  Future<void> _dictate() async {
    final s = _speech;
    if (s == null || !s.loaded || s.busy) {
      return _snack('음성 모델을 준비하고 있어요. 잠시 뒤에 다시 눌러 주세요.');
    }
    _reader.stop();
    _take();
    _note = null;
    _asked = 0;
    if (_dictated && _body.text.trim().isNotEmpty) return _confirm();
    _base = _body.text.trim();
    if (!await _say(
      widget.mail == null ? '메일 내용을 말씀해 주세요.' : '답장 내용을 말씀해 주세요.',
    )) {
      return;
    }
    await _listen(_Step.dictating);
  }

  void _onSpeech() {
    final s = _speech!;
    switch (_step) {
      case _Step.dictating:
        _body.text = '$_base ${s.heard}'.trim();
        if (s.heard.isNotEmpty) _dictated = true;
      case _Step.naming when s.heard.isNotEmpty:
        _name(s.heard);
      case _Step.confirming when s.heard.isNotEmpty:
        _answer(s.heard);
      default:
    }
  }

  void _onTick(Timer _) {
    final s = _speech!;
    if (!s.listening) return;
    _quiet = s.hearing || s.partial == '…' ? Duration.zero : _quiet + _tick;
    switch (_step) {
      // A 2-second pause after the last sentence ends the dictation.
      case _Step.dictating
          when s.heard.isNotEmpty && _quiet >= const Duration(seconds: 2):
        _confirm();
      case _Step.dictating when _quiet >= const Duration(seconds: 8):
        _stopSaying('잘 듣지 못했어요. 마이크를 눌러 다시 말씀해 주세요.');
      case _Step.confirming || _Step.naming
          when _quiet >= const Duration(seconds: 8):
        _stopSaying('대답이 없어서 보내지 않았어요.');
      default:
    }
  }

  Future<void> _confirm() async {
    setState(() => _step = _Step.talking);
    await _mute();
    if (!mounted || _step != _Step.talking) return;
    if (_to.text.trim().isEmpty) {
      _asked = 0;
      return _retry('누구에게 보낼까요? 이름이나 메일 주소를 말씀해 주세요.', _Step.naming);
    }
    // The recipient is read out too: a misheard name must not slip by.
    if (!await _say(
      '${_to.text.trim()}에게 이렇게 보낼게요. ${_body.text.trim()}. '
      '보낼까요? 보내, 다시, 취소 중에 말씀해 주세요.',
    )) {
      return;
    }
    await _listen(_Step.confirming);
  }

  /// Every branch moves [_step] on at once, so the same answer is never
  /// handled twice.
  void _answer(String said) {
    switch (sendAnswer(said)) {
      case SendAnswer.no:
        _stopSaying('보내지 않았어요. 고치거나 보내기를 눌러 주세요.');
      case SendAnswer.again:
        _body.text = _base;
        _retry('다시 말씀해 주세요.', _Step.dictating);
      case SendAnswer.yes:
        setState(() => _step = _Step.sending);
        _mute().then((_) => _send(byVoice: true));
      case SendAnswer.unclear when ++_asked > 2:
        _stopSaying('대답을 알아듣지 못해서 보내지 않았어요.');
      case SendAnswer.unclear:
        _retry('보내, 다시, 취소 중에 말씀해 주세요.', _Step.confirming);
    }
  }

  void _name(String said) {
    if (findRecipient(said, widget.contacts) case final address?) {
      _to.text = address;
      _asked = 0;
      _confirm();
    } else if (++_asked > 2) {
      _stopSaying('받는 사람을 찾지 못했어요. 메일 주소를 입력해 주세요.');
    } else {
      _retry('못 찾았어요. 이름이나 메일 주소를 다시 말씀해 주세요.', _Step.naming);
    }
  }

  Future<void> _retry(String prompt, _Step next) async {
    setState(() => _step = _Step.talking);
    await _mute();
    if (!mounted || _step != _Step.talking) return;
    if (!await _say(prompt)) return;
    await _listen(next);
  }

  /// Ends the voice flow, leaving what was written for the user to edit.
  void _stop([String? note]) {
    _release();
    _reader.stop();
    setState(() {
      _step = _Step.idle;
      _note = note;
    });
  }

  /// [_stop], saying why aloud: the user may not be looking.
  void _stopSaying(String note) {
    _stop(note);
    _reader.speak(note);
  }

  Future<void> _send({bool byVoice = false}) async {
    final sender = _sender;
    final to = _to.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    void fail(String message) {
      if (byVoice) return _stopSaying(message);
      _stop(message);
      _snack(message);
    }

    if (sender == null) {
      // The example mails have no account to send from.
      if (byVoice) {
        _stopSaying('예시 메일이라 실제로 보내지 않았어요.');
        _keepVoice = true;
      }
      Navigator.pop(context);
      messenger.showSnackBar(
        const SnackBar(content: Text('예시 메일이라 실제로 보내지 않았어요')),
      );
      return;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(to)) {
      return fail('받는 사람 메일 주소를 확인해 주세요.');
    }
    if (_body.text.trim().isEmpty) return fail('보낼 내용이 없어요.');
    _release();
    setState(() => _step = _Step.sending);
    try {
      await sender.send(
        to: to,
        subject: _subject.text.trim(),
        text: _body.text.trim(),
        replyTo: widget.mail,
      );
    } catch (error) {
      debugPrint('Send failed: $error');
      if (mounted) fail('보내지 못했어요. ${mailError(sender.service, error)}');
      return;
    }
    if (byVoice) {
      _keepVoice = true;
      _reader.speak('보냈어요.');
    }
    messenger.showSnackBar(const SnackBar(content: Text('보냈어요')));
    if (mounted) Navigator.pop(context);
  }

  /// What the status card says, or null to hide it.
  (String, String)? get _status => switch (_step) {
    _Step.talking => ('잠시만요', '안내가 끝나면 말씀해 주세요'),
    _Step.dictating => ('듣고 있어요', '다 말씀하시고 잠시 멈추면 읽어 드려요'),
    _Step.naming => ('누구에게 보낼까요?', '이름이나 메일 주소를 말씀해 주세요'),
    _Step.confirming => ('보낼까요?', '"보내", "다시", "취소"로 말씀해 주세요'),
    _Step.sending => ('보내는 중이에요', _to.text.trim()),
    _Step.idle => switch (_note) {
      final note? => (note, '마이크를 누르면 다시 말로 쓸 수 있어요'),
      null => null,
    },
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reply = widget.mail != null;
    final running = _step != _Step.idle;
    final canTalk = _speech?.loaded == true;
    const text = TextStyle(fontSize: 16);
    const bare = InputDecoration.collapsed(hintText: '');
    return AppPage(
      trail: [...widget.from, reply ? '답장' : '메일 작성'],
      floating: WritePill(
        _step == _Step.sending ? '보내는 중' : '보내기',
        icon: Icons.send_rounded,
        onWrite: () {
          if (_step != _Step.sending) _send();
        },
        onVoice: running
            ? _stop
            : canTalk
            ? _dictate
            : null,
        voiceIcon: running ? Icons.stop_rounded : Icons.mic_none_rounded,
        voiceLabel: running ? '멈추기' : '말로 쓰기',
      ),
      children: [
        if (_status case (final title, final hint)) ...[
          VoiceCard(
            borderColor: running ? colors.primary : null,
            child: Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          hint,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (_speech?.listening == true && running)
                    Icon(Icons.circle, size: 12, color: colors.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        // One line per header, like a mail app's compose screen.
        for (final (label, field) in [
          (
            '보내는 사람',
            !reply && widget.accounts.length > 1
                ? DropdownButton<MailAccount>(
                    value: _sender,
                    isDense: true,
                    isExpanded: true,
                    underline: const SizedBox(),
                    style: text.copyWith(color: colors.onSurface),
                    items: [
                      for (final a in widget.accounts)
                        DropdownMenuItem(value: a, child: Text(a.address)),
                    ],
                    onChanged: (a) => setState(() => _sender = a),
                  )
                : Text(_sender?.address ?? '예시 계정', style: text),
          ),
          (
            '받는 사람',
            TextField(
              controller: _to,
              style: text,
              keyboardType: TextInputType.emailAddress,
              decoration: bare.copyWith(hintText: '메일 주소'),
            ),
          ),
          (
            '제목',
            TextField(controller: _subject, style: text, decoration: bare),
          ),
        ]) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 84,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(child: field),
              ],
            ),
          ),
          Divider(height: 1, color: colors.outlineVariant),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _body,
          minLines: 8,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontSize: 17, height: 1.6),
          decoration: bare.copyWith(hintText: '내용을 입력하세요'),
        ),
        Divider(height: 1, color: colors.outlineVariant),
        // Room so the last line can scroll out from under the send pill.
        const SizedBox(height: 104),
      ],
    );
  }
}
