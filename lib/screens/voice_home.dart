import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../mail/mail.dart';
import '../mail/mail_account.dart';
import '../mail/mail_inbox.dart';
import '../mail/summary.dart';
import '../voice/commands.dart';
import '../voice/model_downloads.dart';
import '../voice/speech.dart';
import '../voice/tts.dart';
import '../widgets.dart';
import 'help.dart';
import 'mail_view.dart';

/// What the voice home is doing; everything but [idle] is the chat (B).
enum VoiceStep {
  idle,
  asking,
  listening,
  reading,
  waiting,
  done,
  failed,
  // A spoken reply: what to say, Gemma writing it, "보낼까요?", sending.
  dictating,
  drafting,
  confirming,
  sending,
}

/// The pill's two lines. [again] is listening after a miss, [checking]
/// while the last words are still being written down.
(String, String) pillText(
  VoiceStep step, {
  bool paused = false,
  bool again = false,
  bool checking = false,
  int index = 0,
  Mail? mail,
}) => paused
    ? ('멈췄어요', '눌러서 이어 듣기')
    : switch (step) {
        VoiceStep.asking => ('물어보는 중', '잠시 들어 주세요'),
        VoiceStep.listening when checking => ('확인하고 있어요', '잠시만요'),
        VoiceStep.listening when again => ('다시 듣고 있어요', '조용한 곳에서 조금 크게'),
        VoiceStep.listening => ('듣고 있어요', '“지메일부터 읽어 줘”처럼'),
        VoiceStep.reading => (
          '${index + 1}번째 메일 읽는 중',
          mail == null ? '“다음” 하면 넘겨요' : '${mail.from}, ${mail.subject}',
        ),
        VoiceStep.dictating => ('듣고 있어요', '말을 마치면 잠깐 기다려 주세요'),
        VoiceStep.drafting => ('답장 쓰는 중', '잠시만요'),
        VoiceStep.confirming => ('보낼까요?', '“보내”, “다시”, “취소”'),
        VoiceStep.sending => ('보내는 중', '잠시만요'),
        VoiceStep.done => ('다 읽었어요', '눌러서 다시 말하기'),
        VoiceStep.failed => ('연결을 기다려요', '눌러서 다시 시도'),
        VoiceStep.waiting || VoiceStep.idle => ('눌러서 말하기', '“지메일부터 읽어 줘”처럼'),
      };

/// 음성 모드 home: one big mic (A). Tapping it turns this screen into a
/// chat (B) that asks, listens and reads the unread mail aloud, with the
/// mic shrunk into a pill at the bottom showing what it's doing.
class VoiceHome extends StatefulWidget {
  const VoiceHome({
    super.key,
    required this.speech,
    required this.downloads,
    required this.inbox,
    required this.unread,
    required this.greeting,
    required this.onDownload,
    required this.onOpenMail,
    required this.onCompose,
    required this.onReply,
    required this.onSettings,
    required this.onConnect,
  });

  final Recognizer speech;
  final ModelDownloads downloads;
  final MailInbox inbox;

  /// Unread mail across accounts.
  final int unread;

  /// "좋은 오후예요 · 11월 5일 목요일".
  final String greeting;

  /// Asks to download the speech model; null while one is on its way.
  final VoidCallback? onDownload;
  final VoidCallback onOpenMail;
  final VoidCallback onCompose;
  final void Function(Mail) onReply;
  final VoidCallback onSettings;
  final VoidCallback onConnect;

  @override
  State<VoiceHome> createState() => _VoiceHomeState();
}

/// One line of the chat.
class _Line {
  const _Line(this.text, {this.mine = false, this.miss = false, this.mail});
  final String text;
  final bool mine;

  /// Nothing was heard: an outlined bubble on the user's side.
  final bool miss;

  /// A mail being read, shown as a card.
  final Mail? mail;
}

class _VoiceHomeState extends State<VoiceHome> {
  final _reader = Reader.instance;
  final _lines = <_Line>[];
  final _scroll = ScrollController();
  VoiceStep _step = VoiceStep.idle;
  bool _paused = false;
  int _misses = 0;

  /// The unread mail as it was when reading began; reading marks them read,
  /// which takes them off the inbox's list.
  List<Mail> _mails = const [];
  int _index = 0;

  /// Every unread mail when this conversation first started reading, for
  /// "처음부터" after some were read and left the inbox's list.
  List<Mail> _all = const [];

  // shortcut: Gemma sees only this many mails, which keeps its wait near a
  // second; raise it if people with full inboxes ask for older ones.
  static const _listMax = 30;

  /// Gemma's summary model is downloaded, so it judges what was said;
  /// without it only the fixed words work. Checked each time the mic asks.
  bool _gemma = false;

  /// Waiting on Gemma's reading of what was said.
  bool _thinking = false;

  /// Bumped when the conversation ends, so Gemma's answer about an earlier
  /// one is dropped. Not [_run]: that moves on with every mail read.
  int _talk = 0;

  /// The mail being answered, and Gemma's reply to it.
  Mail? _replyTo;
  String _draftText = '';

  /// The latest sentence sent to Gemma; older answers still queued are
  /// dropped.
  int _thought = 0;

  /// Bumped by every new step, pause and reset, so an older step still
  /// waiting on speech or the network stops there.
  int _run = 0;

  /// Gives up listening after a stretch of silence.
  Timer? _silence;

  /// The recogniser's callback before this screen took it, given back after.
  VoidCallback? _homeOnSpeech;

  Recognizer get _s => widget.speech;

  @override
  void initState() {
    super.initState();
    _homeOnSpeech = _s.onSpeech;
    _s.onSpeech = _onSpeech;
  }

  @override
  void dispose() {
    _run++;
    _silence?.cancel();
    if (_s.onSpeech == _onSpeech) _s.onSpeech = _homeOnSpeech;
    if (_step != VoiceStep.idle) {
      _reader.stop();
      if (_s.listening) _s.toggleListening();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _say(String text, {Mail? mail, bool mine = false, bool miss = false}) {
    _lines.add(_Line(text, mail: mail, mine: mine, miss: miss));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _stopMic() async {
    _silence?.cancel();
    if (_s.listening) await _s.toggleListening();
    _s.clear(dropPending: true);
  }

  /// Back to the big mic.
  void _reset() {
    _run++;
    _talk++;
    _all = const [];
    _reader.stop();
    _stopMic();
    setState(() {
      _step = VoiceStep.idle;
      _paused = false;
      _misses = 0;
      _thinking = false;
      _lines.clear();
    });
  }

  /// The big mic: asks whether to read the unread mail, then listens.
  Future<void> _ask() async {
    final run = ++_run;
    if (widget.inbox.mails.isEmpty) {
      if (widget.inbox.error case final error?) {
        setState(() {
          _step = VoiceStep.failed;
          _lines.clear();
          _say(error);
        });
        _reader.speak('메일을 불러오지 못했어요.');
      } else {
        _reader.speak(
          widget.inbox.loading
              ? '메일을 불러오는 중이에요. 잠시 뒤에 다시 불러 주세요.'
              : '안 읽은 메일이 없어요.',
        );
      }
      return;
    }
    _gemma = await Summarizer.instance.installed;
    if (!mounted || run != _run) return;
    final question = '안 읽은 메일이 ${widget.unread}건 있어요. 읽어드릴까요?';
    setState(() {
      _paused = false;
      _step = VoiceStep.asking;
      if (_lines.lastOrNull?.text != question) _say(question);
    });
    // Listening only starts once the question ends, so the mic doesn't
    // hear the app's own voice. No voice: the question is on screen anyway.
    final problem = await _reader.speak(question);
    if (!mounted || run != _run) return;
    if (problem != null && problem != Reader.cut) showProblem(context, problem);
    await _listen(run);
  }

  Future<void> _listen(int run) async {
    await _s.toggleListening();
    if (!mounted || run != _run) return;
    // No mic permission: back to the big mic, which says so. Not [_reset],
    // whose clear would wipe that status.
    if (!_s.listening) {
      return setState(() {
        _step = VoiceStep.idle;
        _lines.clear();
      });
    }
    setState(() => _step = VoiceStep.listening);
    _waitForWords(const Duration(seconds: 8));
  }

  void _waitForWords(Duration wait) => _onQuiet(
    wait,
    VoiceStep.listening,
    () => _s.heard.isNotEmpty
        ? _waitForWords(const Duration(seconds: 3))
        : _missed(heard: false),
  );

  /// Calls [then] once nothing has been said for [wait] in [step]. Still
  /// talking, or still being written down: gives it [more].
  void _onQuiet(
    Duration wait,
    VoiceStep step,
    VoidCallback then, {
    Duration more = const Duration(seconds: 3),
  }) {
    _silence?.cancel();
    _silence = Timer(wait, () {
      if (!mounted || _step != step || _paused) return;
      if (_s.hearing || _s.partial.isNotEmpty) {
        return _onQuiet(more, step, then, more: more);
      }
      then();
    });
  }

  void _onSpeech() {
    final said = _s.heard.trim();
    if (said.isEmpty) {
      // Still being written down: the reply isn't over yet.
      if (_step == VoiceStep.dictating) _waitForReply(_replyPause);
      return;
    }
    if (_step == VoiceStep.dictating) {
      if (quickCommand(said) == Quick.stop) return _quit();
      // Sentences add up in [heard] until a pause ends the reply.
      return _waitForReply(_replyPause);
    }
    if (_step == VoiceStep.confirming) {
      if (!_s.listening || _paused) return;
      setState(() => _say(said, mine: true));
      switch (quickCommand(said, confirming: true)) {
        case Quick.send:
          _sendReply();
        case Quick.cancel:
          _cancelReply();
        case Quick.again:
          _startReply();
        case Quick.stop:
          _quit();
        case _:
          _draft(said, previous: _draftText);
      }
      return;
    }
    if (_step == VoiceStep.reading) {
      // shortcut: each sentence is judged alone and then dropped; good enough
      // for one-word commands, not for longer ones.
      _s.clear();
      switch (quickCommand(said)) {
        case Quick.stop:
          _quit();
        case Quick.next:
          _reader.stop();
          _next();
        case _:
          // Talking over the mail without the model: nothing to judge it.
          if (_gemma) _think(said, reading: true);
      }
      return;
    }
    if (_step != VoiceStep.listening || _paused || _thinking) return;
    setState(() => _say(said, mine: true));
    if (quickCommand(said) == Quick.stop) return _quit();
    if (_gemma) {
      _think(said, reading: false);
    } else {
      // Without the model the question is only "읽어드릴까요?".
      isLaterCommand(said) ? _quit() : _startReading();
    }
  }

  /// Asks Gemma what [said] wants and does it. While [reading] the mail
  /// goes on meanwhile, and anything it doesn't take is let go.
  Future<void> _think(String said, {required bool reading}) async {
    final talk = _talk;
    final thought = ++_thought;
    // Set before the mic stops: the same sentence comes in twice (heard,
    // then partial cleared) and must be judged once.
    setState(() => _thinking = true);
    if (!reading) await _stopMic();
    if (!mounted) return;
    VoiceIntent? intent;
    // Unread first, then the ones read in this talk, for "처음부터".
    final unread = widget.inbox.mails.take(_listMax).toList();
    final listed = [
      ...unread,
      ..._all.where((m) => !unread.contains(m)),
    ].take(_listMax).toList();
    try {
      intent = parseIntent(
        await Summarizer.instance.complete(
          intentPrompt(
            said,
            mails: listed,
            unread: unread.length,
            reading: reading,
            now: DateTime.now(),
          ),
        ),
      );
    } catch (e) {
      debugPrint('Gemma could not judge "$said": $e');
    }
    if (!mounted || talk != _talk || thought != _thought) return;
    setState(() => _thinking = false);
    if (_paused) return;
    switch (intent?.action) {
      case IntentAction.later:
        _quit();
      case IntentAction.read:
        _startReading(switch (intent!.mails) {
          final picked? => pickMails(listed, picked),
          null => null,
        });
      case IntentAction.reply:
        if (reading) _startReply(content: intent!.content);
      case IntentAction.none || null:
        if (!reading) _missed(heard: true);
    }
  }

  /// Nothing heard, or nothing it understood: says what it can take and
  /// listens once more, then leaves it to the buttons.
  Future<void> _missed({required bool heard}) async {
    final run = ++_run;
    final again = ++_misses < 2;
    final reply = !again
        ? '아래 버튼으로 골라 주세요.'
        : _gemma
        ? '“메일 읽어 줘”, “네이버만”처럼 말씀해 주세요.'
        : '“어, 해줘” 또는 “나중에”라고 말씀해 주세요.';
    setState(() {
      _step = again ? VoiceStep.asking : VoiceStep.waiting;
      if (!heard) _say('잘 들리지 않았어요', mine: true, miss: true);
      _say(reply);
    });
    await _stopMic();
    await _reader.speak(reply);
    if (!mounted || run != _run || !again) return;
    await _listen(run);
  }

  /// "나중에" or "그만".
  void _quit() {
    _reset();
    _reader.speak('알겠어요. 필요하면 다시 불러 주세요.');
  }

  /// Reads the unread mail, or the ones Gemma [picked].
  void _startReading([List<Mail>? picked]) {
    if (_all.isEmpty) _all = List.of(widget.inbox.mails);
    final mails = picked ?? List.of(widget.inbox.mails);
    if (mails.isEmpty) {
      _nothing(reading: _step == VoiceStep.reading);
      return;
    }
    _mails = mails;
    _index = 0;
    _misses = 0;
    _readMail();
  }

  /// Nothing matched what was asked: says so, then goes back to the mail
  /// being read, or listens again.
  Future<void> _nothing({required bool reading}) async {
    final run = ++_run;
    const text = '말씀하신 메일이 없어요.';
    setState(() => _say(text));
    await _stopMic();
    await _reader.speak(text);
    if (!mounted || run != _run) return;
    reading ? _readMail() : _listen(run);
  }

  /// Reads who and what, then the summary once it's written (the whole
  /// body when the summary model isn't downloaded or fails).
  Future<void> _readMail({bool next = false}) async {
    final run = ++_run;
    var mail = _mails[_index];
    setState(() {
      _paused = false;
      _step = VoiceStep.reading;
      if (_lines.lastOrNull?.mail != mail) _say('', mail: mail);
    });
    await _stopMic();
    markRead(mail, widget.inbox.markRead);
    _hearCommands(run);
    if (mail.partial) {
      // A failed fetch keeps the text, so it can still be read aloud.
      mail = await mail.account!.fetchWhole(mail).catchError((Object e) {
        debugPrint('fetch for reading failed: $e');
        return mail;
      });
    }
    if (!mounted || run != _run) return;
    final summarizer = Summarizer.instance;
    final rest = await summarizer.installed
        ? summarizer
              .summarize(mail)
              .last
              .then(
                (summary) => '요약입니다. $summary',
                onError: (Object e) => spokenBody(mail.body),
              )
        : Future.value(spokenBody(mail.body));
    if (!mounted || run != _run) return;
    final problem = await _reader.speak(
      // Not "다음 메일": the mic listening for "다음" would hear it.
      '${next ? '이어서 읽을게요.\n' : ''}${mail.from}.\n${mail.subject}.',
      then: rest,
    );
    if (!mounted || run != _run || problem == Reader.cut) return;
    if (problem != null) {
      showProblem(context, problem);
      return _pause();
    }
    _next();
  }

  /// While reading, listens for "다음" and "그만", with the phone's own
  /// voice filtered out. Only with mic permission already given.
  Future<void> _hearCommands(int run) async {
    if (!_s.loaded || _s.listening || !await _s.micAllowed) return;
    if (!mounted || run != _run) return;
    await _s.toggleListening(echoCancel: true);
  }

  void _next() {
    if (_index == _mails.length - 1) {
      _finish();
      return;
    }
    _index++;
    _readMail(next: true);
  }

  Future<void> _finish() async {
    _run++;
    final text = '${_mails.length}건을 모두 읽었어요. 다시 들으려면 아래 알약을 눌러 주세요.';
    setState(() {
      _step = VoiceStep.done;
      _say(text);
    });
    await _stopMic();
    _reader.speak(text);
  }

  void _pause() {
    _run++;
    setState(() => _paused = true);
    _reader.stop();
    _stopMic();
  }

  void _resume() => switch (_step) {
    VoiceStep.reading => _readMail(),
    VoiceStep.dictating => _startReply(),
    VoiceStep.confirming => _readDraft(),
    _ => _ask(),
  };

  void _tapMic() {
    if (_s.loaded) {
      _ask();
    } else {
      widget.onDownload?.call();
    }
  }

  void _tapPill() {
    switch (_step) {
      case VoiceStep.idle:
        _tapMic();
      case VoiceStep.done:
        _ask();
      case VoiceStep.failed:
        _retry();
      case VoiceStep.waiting:
        _misses = 0;
        _listen(++_run);
      case VoiceStep.drafting || VoiceStep.sending:
        break;
      case _:
        _paused ? _resume() : _pause();
    }
  }

  Future<void> _retry() async {
    await widget.inbox.refresh();
    if (!mounted) return;
    _reset();
    _ask();
  }

  Future<void> _reply() async {
    _pause();
    widget.onReply(_mails[_index]);
  }

  /// The quiet that ends a spoken reply; [Recognizer] already cuts a
  /// sentence at 0.6 s, so pauses inside the reply stay in it.
  static const _replyPause = Duration(seconds: 2);

  /// "답장해 줘" for the mail being read, with what to say if it came
  /// along ("괜찮다고 보내자"). Only with Gemma, which writes it.
  Future<void> _startReply({String? content}) async {
    final run = ++_run;
    final mail = _mails[_index];
    setState(() {
      _paused = false;
      _step = VoiceStep.asking;
    });
    _reader.stop();
    await _stopMic();
    if (!mounted || run != _run) return;
    if (mail.account == null || mail.address.isEmpty) {
      return _sayThenNext('예시 메일에는 답장할 수 없어요.', run);
    }
    _replyTo = mail;
    _misses = 0;
    if (content != null) return _draft(content);
    await _askReply(run, '뭐라고 보낼까요?');
  }

  Future<void> _askReply(int run, String question) async {
    setState(() => _say(question));
    await _reader.speak(question);
    if (!mounted || run != _run) return;
    await _s.toggleListening();
    if (!mounted || run != _run || !_s.listening) return;
    setState(() => _step = VoiceStep.dictating);
    _waitForReply(const Duration(seconds: 8));
  }

  void _waitForReply(Duration wait) => _onQuiet(wait, VoiceStep.dictating, () {
    final said = _s.heard.trim();
    if (said.isNotEmpty) {
      _draft(said);
    } else if (++_misses < 2) {
      final run = ++_run;
      _stopMic().then((_) => _askReply(run, '잘 들리지 않았어요. 뭐라고 보낼까요?'));
    } else {
      _sayThenNext('답장은 그만둘게요.', ++_run);
    }
  }, more: _replyPause);

  /// Gemma writes the reply from [said], or changes [previous] the way
  /// [said] asks, then reads it back.
  Future<void> _draft(String said, {String? previous}) async {
    final run = ++_run;
    setState(() {
      _step = VoiceStep.drafting;
      if (previous == null) _say(said, mine: true);
    });
    await _stopMic();
    var text = '';
    try {
      text = await Summarizer.instance.complete(
        replyPrompt(_replyTo!, said, draft: previous),
      );
    } catch (e) {
      debugPrint('Gemma could not write the reply: $e');
    }
    if (!mounted || run != _run) return;
    if (text.isEmpty) {
      _misses = 0;
      return _askReply(run, '답장을 쓰지 못했어요. 다시 말씀해 주세요.');
    }
    _draftText = text;
    setState(() => _say(text));
    _readDraft();
  }

  /// Reads the draft with the mic off, so its own "보내" can't send it,
  /// then listens for 보내·다시·취소 or a change.
  Future<void> _readDraft() async {
    final run = ++_run;
    setState(() {
      _paused = false;
      _step = VoiceStep.confirming;
    });
    await _stopMic();
    final problem = await _reader.speak('이렇게 보낼게요.\n$_draftText\n보낼까요?');
    if (!mounted || run != _run) return;
    if (problem != null && problem != Reader.cut) showProblem(context, problem);
    _misses = 0;
    await _listenConfirm(run);
  }

  Future<void> _listenConfirm(int run) async {
    await _s.toggleListening();
    if (!mounted || run != _run || !_s.listening) return;
    _onQuiet(const Duration(seconds: 8), VoiceStep.confirming, () async {
      final run = ++_run;
      await _stopMic();
      // Twice unanswered: the buttons stay for later.
      if (++_misses >= 2) return;
      const again = '“보내”, “다시”, “취소” 중에 말씀해 주세요.';
      setState(() => _say(again));
      await _reader.speak(again);
      if (!mounted || run != _run) return;
      await _listenConfirm(run);
    });
  }

  /// Only on a bare "보내" or the button.
  Future<void> _sendReply() async {
    final run = ++_run;
    final mail = _replyTo!;
    final account = mail.account!;
    setState(() => _step = VoiceStep.sending);
    await _stopMic();
    try {
      await account.send(
        to: mail.address,
        subject: replySubject(mail.subject),
        text: _draftText,
        replyTo: mail,
      );
    } catch (e) {
      debugPrint('Voice reply failed: $e');
      if (!mounted || run != _run) return;
      final problem = '보내지 못했어요. ${mailError(account.service, e)}';
      setState(() {
        _step = VoiceStep.confirming;
        _say(problem);
      });
      await _reader.speak('${withoutCode(problem)}\n다시 보낼까요?');
      if (!mounted || run != _run) return;
      _misses = 0;
      return _listenConfirm(run);
    }
    if (!mounted || run != _run) return;
    _sayThenNext('보냈어요.', run);
  }

  void _cancelReply() => _sayThenNext('안 보냈어요.', ++_run);

  /// Says [text], then reads on from the next mail.
  Future<void> _sayThenNext(String text, int run) async {
    setState(() => _say(text));
    await _stopMic();
    await _reader.speak(text);
    if (!mounted || run != _run) return;
    _next();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final still = MediaQuery.disableAnimationsOf(context);
    final motion = still ? Duration.zero : const Duration(milliseconds: 520);
    const curve = Cubic(.32, .72, 0, 1);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final on = _step != VoiceStep.idle;
    final inbox = widget.inbox;
    final noAccounts = inbox.accounts.isEmpty;
    final needsModel = !_s.busy && !_s.loaded;
    final waiting = needsModel ? widget.downloads.downloading : null;
    final noMic = _s.error && _s.status == Recognizer.noMic;

    // A: what the big mic does.
    final (big, hint) = waiting != null
        ? ('음성 모델 받는 중', '다 받으면 눌러서 말할 수 있어요')
        : _s.busy
        ? (_s.status, '처음 한 번만 조금 걸려요')
        : needsModel
        ? ('${_s.model.label} 모델 내려받기', '${_s.model.size}를 한 번 내려받아요')
        : _s.error
        ? (_s.status, '다시 눌러 주세요')
        : widget.unread == 0
        ? ('눌러서 말하기', '새 메일이 오면 눌러서 들어 보세요')
        : ('눌러서 말하기', '“메일 읽어 줘”처럼\n편하게 말씀하세요');
    final (title, sub) = noAccounts
        ? ('메일을 먼저\n연결해 주세요', '연결하면 안 읽은 메일을 말로 알려 드려요')
        : inbox.mails.isEmpty && inbox.loading
        ? ('메일을\n불러오는 중이에요', '잠시만 기다려 주세요')
        : widget.unread == 0
        ? ('새 메일이\n없어요', '안 읽은 메일을 모두 확인했어요')
        : (
            '안 읽은 메일\n${widget.unread}건이 있어요',
            [
              for (final a in inbox.accounts)
                if ((inbox.unreadTotal[a.address] ?? 0) > 0)
                  '${a.service.label} ${inbox.unreadTotal[a.address]}건',
            ].join(', '),
          );

    final (pillTitle, pillHint) = pillText(
      _step,
      paused: _paused,
      again: _misses > 0,
      checking: _s.partial == '…' || _thinking,
      index: _index,
      mail: _step == VoiceStep.reading ? _mails[_index] : null,
    );
    final soft =
        _paused ||
        const [
          VoiceStep.waiting,
          VoiceStep.done,
          VoiceStep.failed,
        ].contains(_step);
    final micFill = needsModel || noMic ? colors.outline : colors.primary;
    final onTap = !on && (_s.busy || waiting != null)
        ? null
        : on
        ? _tapPill
        : _tapMic;

    Widget fade(bool shown, Widget child, {Offset slide = Offset.zero}) =>
        IgnorePointer(
          ignoring: !shown,
          child: AnimatedOpacity(
            opacity: shown ? 1 : 0,
            duration: motion * 0.8,
            curve: curve,
            child: AnimatedSlide(
              offset: shown ? Offset.zero : slide,
              duration: motion,
              curve: curve,
              child: child,
            ),
          ),
        );

    Widget chip(String label, VoidCallback onPressed) => FilledButton.tonal(
      // The theme's full-width minimum breaks inside a Wrap.
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
    final chips = switch (_step) {
      VoiceStep.reading when !_paused => [
        chip('답장할래', _gemma ? _startReply : _reply),
        chip('다음 메일', () {
          _reader.stop();
          _next();
        }),
        chip('그만', _quit),
      ],
      VoiceStep.waiting => [chip('읽어 줘', _startReading), chip('나중에', _quit)],
      VoiceStep.confirming when !_paused => [
        chip('보내기', _sendReply),
        chip('다시', _startReply),
        chip('취소', _cancelReply),
      ],
      VoiceStep.done => [chip('처음 화면으로', _reset)],
      VoiceStep.failed => [chip('다시 시도', _retry)],
      _ => const <Widget>[],
    };

    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        const micSize = 184.0;
        final micTop = math.max(230.0, h * 0.5 - micSize / 2 - 30);
        final pillTop = h - bottom - 16 - 72;
        return Stack(
          children: [
            // A: greeting and the unread count.
            Positioned(
              left: 24,
              right: 76,
              top: 24,
              child: fade(
                !on,
                slide: const Offset(0, -0.1),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      noAccounts ? '처음 오셨네요' : widget.greeting,
                      style: TextStyle(
                        fontSize: 15,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.8,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      sub,
                      style: TextStyle(
                        fontSize: 17,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 20,
              top: 20,
              child: fade(
                !on,
                Glass(
                  child: SizedBox.square(
                    dimension: 44,
                    child: IconButton(
                      tooltip: '설정',
                      onPressed: widget.onSettings,
                      icon: Icon(
                        Icons.settings_outlined,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (noAccounts)
              Positioned(
                left: 24,
                right: 24,
                top: micTop,
                child: Column(
                  children: [
                    for (final service in MailService.values) ...[
                      Material(
                        color: colors.surfaceContainer,
                        borderRadius: BorderRadius.circular(20),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: widget.onConnect,
                          child: SizedBox(
                            height: 62,
                            child: Row(
                              children: [
                                const SizedBox(width: 20),
                                ServiceBadge(
                                  service.mark,
                                  service.color,
                                  size: 32,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  '${service.label} 연결',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      '메일 내용과 목소리는 이 휴대폰 안에서만 처리해요',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              // A: the halo behind the mic, a progress ring while the model
              // downloads.
              Positioned(
                left: (w - 248) / 2,
                top: micTop - 32,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: on ? 0 : 1,
                    duration: motion,
                    child: AnimatedScale(
                      scale: on ? 1.4 : 1,
                      duration: motion,
                      curve: curve,
                      child: Container(
                        width: 248,
                        height: 248,
                        decoration: BoxDecoration(
                          color: noMic
                              ? colors.outlineVariant
                              : colors.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: waiting == null
                            ? null
                            : Padding(
                                padding: const EdgeInsets.all(3),
                                child: CircularProgressIndicator(
                                  value: widget.downloads.fraction,
                                  strokeWidth: 6,
                                  color: colors.primary,
                                  backgroundColor: colors.outlineVariant,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                top: micTop + micSize + 52,
                child: fade(
                  !on,
                  noMic
                      ? Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '마이크 권한이 꺼져 있어요',
                                style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                '말로 메일을 들으려면 휴대폰 설정 앱에서 Alpha-mail의 '
                                '마이크를 켜 주세요. 목소리는 휴대폰 밖으로 나가지 않아요.',
                                style: TextStyle(fontSize: 15, height: 1.5),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          children: [
                            Text(
                              big,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: _s.error ? colors.error : null,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              hint,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                height: 1.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
            Positioned(
              left: 24,
              right: 24,
              bottom: bottom + 24,
              child: fade(
                !on && !noAccounts,
                slide: const Offset(0, 0.4),
                Row(
                  children: [
                    for (final (label, onTap) in [
                      ('메일 목록', widget.onOpenMail),
                      ('새 메일 쓰기', widget.onCompose),
                    ]) ...[
                      if (label != '메일 목록') const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                            backgroundColor: colors.surfaceContainer,
                            foregroundColor: colors.onSurface,
                            shape: const StadiumBorder(),
                            textStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          onPressed: onTap,
                          child: Text(label),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // B: back, the title and how far reading has got.
            Positioned(
              left: 20,
              right: 20,
              top: 16,
              child: fade(
                on,
                slide: const Offset(0, -0.3),
                Column(
                  children: [
                    Row(
                      children: [
                        Material(
                          color: colors.surfaceContainer,
                          shape: const CircleBorder(),
                          child: IconButton(
                            tooltip: '처음 화면으로',
                            onPressed: _reset,
                            icon: const Icon(Icons.chevron_left_rounded),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _step == VoiceStep.failed
                                  ? '안 읽은 메일 확인 못 함'
                                  : '안 읽은 메일 ${widget.unread}건',
                              style: TextStyle(
                                fontSize: 14,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const Text(
                              'Alpha와 대화',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.4,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    if (_mails.isNotEmpty && _step != VoiceStep.failed) ...[
                      const SizedBox(height: 14),
                      _Progress(
                        done: switch (_step) {
                          VoiceStep.reading => _index + 1,
                          VoiceStep.done => _mails.length,
                          _ => 0,
                        },
                        of: _mails.length,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // B: the chat, between the title and the buttons.
            if (on)
              Positioned(
                left: 0,
                right: 0,
                top: 120,
                bottom: h - pillTop + (chips.isEmpty ? 16 : 76),
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  children: [
                    for (final line in _lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _ChatLine(
                          line,
                          failed: _step == VoiceStep.failed,
                        ),
                      ),
                  ],
                ),
              ),
            Positioned(
              left: 20,
              right: 20,
              top: pillTop - 60,
              child: fade(
                chips.isNotEmpty,
                slide: const Offset(0, 0.2),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: chips,
                ),
              ),
            ),

            // The mic, which shrinks into the pill.
            if (!noAccounts)
              AnimatedPositioned(
                duration: motion,
                curve: curve,
                left: on ? 20 : (w - micSize) / 2,
                top: on ? pillTop : micTop,
                width: on ? w - 40 : micSize,
                height: on ? 72 : micSize,
                child: Semantics(
                  button: true,
                  liveRegion: on,
                  label: !on
                      ? waiting != null
                            ? '음성 모델을 받는 중이라 아직 말할 수 없어요'
                            : needsModel
                            ? big
                            : '눌러서 말하기'
                      : _paused
                      ? '이어 듣기'
                      : soft
                      ? '$pillTitle, $pillHint'
                      : '$pillTitle, 눌러서 멈추기',
                  onTap: onTap,
                  excludeSemantics: true,
                  child: AnimatedContainer(
                    duration: motion,
                    curve: curve,
                    decoration: BoxDecoration(
                      color: on
                          ? soft
                                ? colors.primaryContainer
                                : colors.primary
                          : micFill,
                      borderRadius: BorderRadius.circular(on ? 36 : 92),
                      boxShadow: soft || needsModel || noMic
                          ? null
                          : [
                              BoxShadow(
                                color: colors.primary.withValues(alpha: 0.3),
                                blurRadius: 24,
                                offset: const Offset(0, 8),
                              ),
                            ],
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(on ? 36 : 92),
                        onTap: onTap,
                        child: LayoutBuilder(
                          // Each face shows once the box has room for it.
                          builder: (context, c) => c.maxWidth > 240
                              ? _PillFace(
                                  title: pillTitle,
                                  hint: pillHint,
                                  soft: soft,
                                  moving:
                                      !soft &&
                                      !still &&
                                      _step != VoiceStep.idle,
                                  fast:
                                      _step == VoiceStep.listening &&
                                      _s.partial == '…',
                                  icon: _paused
                                      ? Icons.play_arrow_rounded
                                      : soft
                                      ? Icons.mic_none_rounded
                                      : Icons.stop_rounded,
                                )
                              : c.maxWidth < 120
                              ? const SizedBox()
                              : Center(
                                  child: waiting != null
                                      ? Text(
                                          '${(widget.downloads.fraction * 100).floor()}%',
                                          style: TextStyle(
                                            fontSize: 44,
                                            fontWeight: FontWeight.w800,
                                            color: colors.onPrimary,
                                          ),
                                        )
                                      : _s.busy
                                      ? SizedBox.square(
                                          dimension: 56,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 4,
                                            color: colors.onPrimary,
                                          ),
                                        )
                                      : Icon(
                                          needsModel
                                              ? Icons.download_rounded
                                              : noMic
                                              ? Icons.mic_off_outlined
                                              : Icons.mic_none_rounded,
                                          size: 72,
                                          color: colors.onPrimary,
                                        ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Segments for a few mails, one bar for many, and "1 / 8" beside.
class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.of});
  final int done;
  final int of;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: of <= 12
              ? Row(
                  children: [
                    for (var i = 0; i < of; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 600),
                          height: 4,
                          decoration: BoxDecoration(
                            color: i < done
                                ? colors.primary
                                : colors.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ],
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: done / of,
                    minHeight: 4,
                    color: colors.primary,
                    backgroundColor: colors.outlineVariant,
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Text(
          '$done / $of',
          style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The pill's inside: bars, what it's doing, and the stop/play circle.
class _PillFace extends StatelessWidget {
  const _PillFace({
    required this.title,
    required this.hint,
    required this.soft,
    required this.moving,
    required this.fast,
    required this.icon,
  });

  final String title;
  final String hint;
  final bool soft;
  final bool moving;
  final bool fast;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fg = soft ? colors.primary : colors.onPrimary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 10, 0),
      child: Row(
        children: [
          _Bars(
            moving: moving,
            fast: fast,
            color: soft ? colors.primary : colors.inversePrimary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: soft ? colors.primary : colors.inversePrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: soft
                  ? colors.primary
                  : colors.onPrimary.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: colors.onPrimary),
          ),
        ],
      ),
    );
  }
}

/// Five bars bobbing while the app talks or listens; flat when [moving] is
/// off (paused, done, or the phone's reduce-motion setting).
class _Bars extends StatefulWidget {
  const _Bars({required this.moving, required this.fast, required this.color});
  final bool moving;
  final bool fast;
  final Color color;

  @override
  State<_Bars> createState() => _BarsState();
}

class _BarsState extends State<_Bars> with SingleTickerProviderStateMixin {
  late final _wave = AnimationController(vsync: this);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_Bars old) {
    super.didUpdateWidget(old);
    if (old.moving != widget.moving || old.fast != widget.fast) _sync();
  }

  void _sync() {
    _wave.duration = Duration(milliseconds: widget.fast ? 500 : 900);
    widget.moving ? _wave.repeat() : _wave.stop();
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 36,
    height: 28,
    child: AnimatedBuilder(
      animation: _wave,
      builder: (context, _) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final shift in const [0.0, 0.33, 0.67, 0.17, 0.5])
            Container(
              width: 4,
              height: widget.moving
                  ? 28 *
                        (0.3 +
                            0.7 *
                                (0.5 -
                                    0.5 *
                                        math.cos(
                                          2 * math.pi * (_wave.value + shift),
                                        )))
                  : 6,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    ),
  );
}

class _ChatLine extends StatelessWidget {
  const _ChatLine(this.line, {required this.failed});
  final _Line line;

  /// The chat holds just the error that stopped it.
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const round = Radius.circular(20);
    const tail = Radius.circular(6);
    final mine = line.mine;
    final mail = line.mail;
    final Widget body = mail != null
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (mail.account case final a?) ...[
                    ServiceBadge(a.service.mark, a.service.color, size: 22),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      mail.from,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (mail.date case final d?) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${d.hour < 12 ? '오전' : '오후'} '
                      '${(d.hour + 11) % 12 + 1}:${'${d.minute}'.padLeft(2, '0')}',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                mail.subject,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                spokenBody(mail.body),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          )
        : failed && !mine
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.error_outline_rounded,
                  size: 20,
                  color: colors.error,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ProblemText(
                  line.text,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: colors.error,
                  ),
                ),
              ),
            ],
          )
        : Text(
            line.text,
            style: TextStyle(
              fontSize: mine && !line.miss ? 20 : 17,
              height: 1.45,
              fontWeight: mine && !line.miss ? FontWeight.w700 : null,
              color: line.miss
                  ? colors.onSurfaceVariant
                  : mine
                  ? colors.onPrimary
                  : colors.onSurface,
            ),
          );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: mail != null || failed ? double.infinity : 300,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: line.miss
                ? Colors.transparent
                : mine
                ? colors.primary
                : colors.surfaceContainer,
            border: line.miss
                ? Border.all(color: colors.outline, width: 1.5)
                : null,
            borderRadius: BorderRadius.only(
              topLeft: round,
              topRight: round,
              bottomLeft: mine ? round : tail,
              bottomRight: mine ? tail : round,
            ),
          ),
          child: body,
        ),
      ),
    );
  }
}
