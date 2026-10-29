import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../mail/mail.dart';
import '../voice/speech.dart';
import '../mail/summary.dart';
import '../voice/tts.dart';
import '../widgets.dart';

/// 03 — reads one unread mail aloud, with a waveform while it plays.
/// Whether [said] asks to skip to the next mail. Only a bare "다음" counts:
/// the mic also catches the app's own voice and mail text like "다음 주
/// 월요일까지".
bool isSkipCommand(String said) => _skip.hasMatch(said);
final _skip = RegExp(
  r'^\s*(다음|다음 거|다음 꺼|다음 메일|넘겨|넘어가|건너뛰어)\s*(줘|요)?\s*[.!?]?\s*$',
);

class BriefingScreen extends StatefulWidget {
  const BriefingScreen({
    super.key,
    required this.from,
    this.index = 0,
    this.mails = mockMails,
    this.onRead,
    this.autoRead = true,
    this.speech,
  });

  /// The recogniser, for replying by voice; null hides the mic.
  final Recognizer? speech;

  /// Menu path of the screen that opened this one.
  final List<String> from;
  final int index;
  final List<Mail> mails;

  /// Called once a mail shown here is marked read on the server.
  final void Function(Mail)? onRead;

  /// Starts reading as soon as a mail shows; off when opened from a list,
  /// where the user may just be looking.
  final bool autoRead;

  @override
  State<BriefingScreen> createState() => _BriefingScreenState();
}

class _BriefingScreenState extends State<BriefingScreen>
    with SingleTickerProviderStateMixin {
  late int _index = widget.index;

  /// Goes on to the next mail when one finishes; off once the user stops.
  late bool _auto = widget.autoRead;
  late final _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  final _reader = Reader.instance;

  @override
  void initState() {
    super.initState();
    _reader.speaking.addListener(_syncWave);
    markRead(widget.mails[_index], widget.onRead);
    if (widget.autoRead) {
      _read();
      _hearNext();
    }
  }

  @override
  void dispose() {
    _reader.speaking.removeListener(_syncWave);
    _unhear();
    _reader.stop();
    _wave.dispose();
    super.dispose();
  }

  void _syncWave() {
    _reader.speaking.value ? _wave.repeat() : _wave.stop();
    setState(() {});
  }

  /// Reads who and what, then the AI summary once it's written (the whole
  /// body if [whole], or the summary model isn't downloaded or fails).
  Future<void> _read({bool next = false, bool whole = false}) async {
    final mail = widget.mails[_index];
    final summarizer = Summarizer.instance;
    final rest = !whole && await summarizer.installed
        ? summarizer
              .summarize(mail)
              .last
              .then(
                (summary) => '요약입니다. $summary',
                onError: (Object e) {
                  debugPrint('summary for reading failed: $e');
                  return spokenBody(mail.body);
                },
              )
        : Future.value(spokenBody(mail.body));
    if (!mounted || widget.mails[_index] != mail) return;
    final problem = await _reader.speak(
      // Not "다음 메일": the mic listening for "다음" would hear it.
      '${next ? '이어서 읽을게요.\n' : ''}${mail.from}.\n${mail.subject}.',
      then: rest,
    );
    // Cut off by a tap or another read: that one decides what comes next.
    if (!mounted || problem == Reader.cut) return;
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
    } else if (_auto && widget.mails[_index] == mail) {
      _readNext();
    }
  }

  /// The recogniser's callback before this screen took it, given back after.
  VoidCallback? _homeOnSpeech;

  /// Hands-free reading listens for "다음" to skip to the next mail. Only
  /// with mic permission already given: reading never asks for it.
  Future<void> _hearNext() async {
    final s = widget.speech;
    if (s == null || !s.loaded || s.listening) return;
    if (!await s.micAllowed) return;
    if (!mounted || !_auto) return;
    _homeOnSpeech = s.onSpeech;
    s.onSpeech = _onSpeech;
    await s.toggleListening(echoCancel: true);
    if (mounted) setState(() {});
  }

  void _unhear() {
    final s = widget.speech;
    if (s == null || s.onSpeech != _onSpeech) return;
    s.onSpeech = _homeOnSpeech;
    // Clear after the stop, which would otherwise set "잘 듣지 못했어요".
    if (s.listening) {
      s.toggleListening().whenComplete(() => s.clear(dropPending: true));
    } else {
      s.clear(dropPending: true);
    }
    if (mounted) setState(() {});
  }

  void _onSpeech() {
    final s = widget.speech!;
    if (s.heard.isEmpty) return;
    final skip = _auto && isSkipCommand(s.heard);
    // shortcut: each sentence is judged alone and then dropped; good enough
    // for one-word commands, not for longer ones.
    s.clear();
    if (skip) {
      _reader.stop();
      _readNext();
    }
  }

  /// Hands-free reading: on to the next mail, or says it's done.
  void _readNext() {
    if (_index == widget.mails.length - 1) {
      _auto = false;
      _unhear();
      _reader.speak('안 읽은 메일을 다 읽었어요.');
      return;
    }
    setState(() => _index++);
    markRead(widget.mails[_index], widget.onRead);
    _read(next: true);
  }

  /// What the running read covers, for the card's "읽는 중" line.
  bool _whole = false;

  void _listen({required bool whole}) {
    _auto = widget.autoRead;
    _whole = whole;
    _read(whole: whole);
  }

  void _stopReading() {
    _auto = false;
    _unhear();
    _reader.stop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mail = widget.mails[_index];
    return AppPage(
      trail: [...widget.from, '메일 내용'],
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '${mail.source} · ${_index + 1} / ${widget.mails.length}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: colors.primary,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          mail.from,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          mail.subject,
          style: TextStyle(fontSize: 16, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Divider(color: colors.outlineVariant),
        const SizedBox(height: 16),
        _SummaryCard(
          mail,
          listen: (summaryReady) => _reader.speaking.value
              ? Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 32,
                        child: AnimatedBuilder(
                          animation: _wave,
                          builder: (context, _) => CustomPaint(
                            painter: _WavePainter(_wave.value, colors.primary),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      widget.speech?.onSpeech == _onSpeech
                          ? '"다음" 하면 넘겨요'
                          : _whole
                          ? '전체 읽는 중'
                          : '요약 읽는 중',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      // The theme's full-width minimum breaks inside a Row.
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 44),
                      ),
                      onPressed: _stopReading,
                      icon: const Icon(Icons.stop_rounded),
                      label: const Text('멈추기'),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        // Reads the whole body anyway while there's no summary.
                        onPressed: summaryReady
                            ? () => _listen(whole: false)
                            : null,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('요약 듣기'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        // Same box as the filled 요약 듣기 beside it.
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          side: BorderSide(color: colors.outlineVariant),
                          textStyle: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        onPressed: () => _listen(whole: true),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          mail.length.isEmpty
                              ? '전체 듣기'
                              : '전체 듣기 ${mail.length}',
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        if (mail.html case final html?)
          _MailHtml(html)
        else
          Text(mail.body, style: const TextStyle(fontSize: 18, height: 1.7)),
        // Room so the last line can scroll out from under the reply pill.
        const SizedBox(height: 104),
      ],
    );
  }
}

/// AI summary of [mail], written on the phone as it's read; offers the
/// model download the first time. [listen] builds the listen buttons
/// under it, told whether the summary is ready to read.
class _SummaryCard extends StatefulWidget {
  const _SummaryCard(this.mail, {required this.listen});
  final Mail mail;
  final Widget Function(bool summaryReady) listen;

  @override
  State<_SummaryCard> createState() => _SummaryCardState();
}

class _SummaryCardState extends State<_SummaryCard> {
  final _summarizer = Summarizer.instance;
  bool? _installed;
  String _text = '';
  bool _writing = false;
  Object? _error;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _summarizer.progress.addListener(_onProgress);
    _check();
  }

  @override
  void didUpdateWidget(_SummaryCard old) {
    super.didUpdateWidget(old);
    if (old.mail != widget.mail && _installed == true) _start();
  }

  @override
  void dispose() {
    _summarizer.progress.removeListener(_onProgress);
    _sub?.cancel();
    super.dispose();
  }

  /// A download started from another mail may finish while this one shows.
  void _onProgress() {
    if (_summarizer.progress.value == null && _installed == false) {
      _check();
    } else {
      setState(() {});
    }
  }

  Future<void> _check() async {
    final installed = await _summarizer.installed;
    if (!mounted) return;
    setState(() => _installed = installed);
    if (installed) _start();
  }

  void _start() {
    _sub?.cancel();
    setState(() {
      _text = '';
      _error = null;
      _writing = true;
    });
    _sub = _summarizer
        .summarize(widget.mail)
        .listen(
          (text) => setState(() => _text = text),
          onError: (Object e) {
            debugPrint('summary failed: $e');
            setState(() {
              _error = e;
              _writing = false;
            });
          },
          onDone: () => setState(() => _writing = false),
        );
  }

  Future<void> _download() async {
    try {
      await _summarizer.download();
    } catch (e) {
      debugPrint('summary model download failed: $e');
      _summarizer.failed = true;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final progress = _summarizer.progress.value;
    final done = _text.isNotEmpty && !_writing && _error == null;
    final Widget body;
    if (progress != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('요약 모델 받는 중 · $progress% · 앱을 닫아도 계속 받아요', style: hint),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress / 100),
        ],
      );
    } else if (_installed == false) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            !_summarizer.failed
                ? '요약 모델(${Summarizer.sizeLabel})을 한 번 받으면 폰 안에서 메일을 '
                      '요약해요. 와이파이에서 받아 주세요.'
                : '요약 모델을 받지 못했어요. 연결을 확인하고 다시 받아 주세요.',
            style: const TextStyle(fontSize: 15, height: 1.6),
          ),
          TextButton(onPressed: _download, child: const Text('요약 모델 받기')),
        ],
      );
    } else if (_error != null) {
      body = Row(
        children: [
          const Expanded(child: Text('요약하지 못했어요')),
          TextButton(onPressed: _start, child: const Text('다시 시도')),
        ],
      );
    } else if (_text.isEmpty) {
      body = Text(_installed == null ? '' : '요약하는 중…', style: hint);
    } else {
      body = Text(_text, style: const TextStyle(fontSize: 17, height: 1.6));
    }
    return VoiceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AI 요약', style: hint),
          const SizedBox(height: 8),
          body,
          const SizedBox(height: 14),
          widget.listen(done),
        ],
      ),
    );
  }
}

/// Renders a mail's HTML as its sender laid it out, images included, as
/// tall as the mail so the page scrolls as one. The mail's own scripts are
/// blocked and links open in the browser, never inside the app.
class _MailHtml extends StatefulWidget {
  const _MailHtml(this.html);
  final String html;

  @override
  State<_MailHtml> createState() => _MailHtmlState();
}

class _MailHtmlState extends State<_MailHtml> {
  /// Content height once the page has loaded; a placeholder until then.
  double _height = 520;

  // JavaScript is on only so the app can measure the page; the CSP in
  // [_page] keeps every script inside the mail from running.
  late final _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) => _measure(),
        onNavigationRequest: (request) {
          if (!request.url.startsWith('http')) {
            return NavigationDecision.navigate;
          }
          launchUrl(Uri.parse(request.url));
          return NavigationDecision.prevent;
        },
      ),
    );

  // Mails are designed on white, so they keep a white page of their own
  // inside the dark app instead of being recoloured.
  String get _page =>
      '<!doctype html><html><head><meta charset="utf-8">'
      '<meta http-equiv="Content-Security-Policy" content="script-src \'none\'">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>html,body{margin:0;background:#fff;color:#111}'
      'body{padding:16px;font:15px/1.6 -apple-system,sans-serif;'
      'overflow-wrap:anywhere}img{max-width:100%;height:auto}</style>'
      '</head><body>${widget.html}</body></html>';

  // Newsletters laid out at a fixed width (often 600–700px) ran off the
  // right edge; shrink those to the screen width, as mail apps do. The
  // widest element counts too: a mail's own overflow:hidden box hid its
  // table from scrollWidth. 16 is the body's right padding.
  static const _fitAndMeasure =
      '(function(){var b=document.body,w=window.innerWidth,s=b.scrollWidth;'
      "document.querySelectorAll('body *').forEach(function(e){"
      'var r=Math.ceil(e.getBoundingClientRect().right)+16;if(r>s)s=r;});'
      'if(s<=w+1)return b.scrollHeight;var k=w/s;'
      "b.style.boxSizing='border-box';b.style.width=s+'px';"
      "b.style.transformOrigin='0 0';b.style.transform='scale('+k+')';"
      "document.documentElement.style.overflowX='hidden';"
      'return b.scrollHeight*k;})()';

  Future<void> _measure() async {
    try {
      // The body, not the document: the document is never shorter than the
      // box itself, so a short mail kept the placeholder height.
      final result = await _web.runJavaScriptReturningResult(_fitAndMeasure);
      final height = double.tryParse('$result');
      if (height == null || !mounted) return;
      // shortcut: past ~15000 device pixels a WebView texture can fail to
      // draw, so very long mails scroll inside the box; paginate if needed.
      final max = 15000 / MediaQuery.devicePixelRatioOf(context);
      setState(() => _height = height.clamp(120, max));
    } catch (e) {
      debugPrint('mail height probe failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _web.loadHtmlString(_page);
  }

  // "다음 메일" reuses this widget with the next mail's HTML.
  @override
  void didUpdateWidget(_MailHtml old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _web.loadHtmlString(_page);
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: SizedBox(
      height: _height,
      child: WebViewWidget(controller: _web),
    ),
  );
}

/// Bars whose heights ripple left to right, like the design's waveform.
class _WavePainter extends CustomPainter {
  _WavePainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 28;
    final gap = size.width / bars;
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.min(4, gap * 0.5)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars; i++) {
      final phase = (i / bars + t) * 2 * math.pi;
      final h =
          size.height *
          (0.2 +
              0.8 *
                  (0.5 + 0.5 * math.sin(phase * 2) * math.cos(i * 1.7)).abs());
      final x = gap * (i + 0.5);
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.t != t;
}
