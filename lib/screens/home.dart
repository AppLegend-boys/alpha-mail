import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../mail/mail.dart';
import '../mail/mail_account.dart';
import '../mail/mail_inbox.dart';
import '../voice/model_downloads.dart';
import '../voice/speech.dart';
import '../voice/tts.dart';
import '../widgets.dart';
import 'compose.dart';
import 'connect.dart';
import 'help.dart';
import 'mail_list.dart';
import 'mail_view.dart';
import 'settings.dart';
import 'voice_settings.dart';

/// Voice home: a tile per account's unread count, the mic dock, and the
/// menu. Speech, downloads and mail live in their own classes; this screen
/// wires them up.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _speech = Recognizer();
  late final _downloads = ModelDownloads(onDone: _speech.switchWhenFree);
  final _inbox = MailInbox();
  final _content = GlobalKey<NavigatorState>();
  AppSettings _settings = const AppSettings();
  bool _opening = false;

  /// Saying "읽어드릴까요?" before the mic turns on.
  bool _asking = false;

  /// Dock tab lit up; [_push] sets it, and it goes back to home once that
  /// screen closes.
  String _section = 'home';

  /// Bumped per [_push], so a screen closing after another menu item has
  /// opened leaves the newer highlight alone.
  int _pushes = 0;

  /// Screens [_push] has open over home; while any are, system back pops
  /// them instead of leaving the app.
  int _open = 0;

  /// The screen [_push] opened last, for [_reopen].
  Route<void>? _top;

  /// Redraws on the hour so the greeting and date don't go stale.
  Timer? _clock;

  void _tickClock() =>
      _clock = Timer(Duration(minutes: 60 - DateTime.now().minute), () {
        if (!mounted) return;
        setState(() {});
        _tickClock();
      });

  @override
  void initState() {
    super.initState();
    for (final state in [_speech, _downloads, _inbox]) {
      state.addListener(_rebuild);
    }
    _speech.onSpeech = _checkCommand;
    _speech.addListener(_keepAwake);
    Reader.instance.speaking.addListener(_keepAwake);
    _tickClock();
    // Desktop starts with mail only: no recogniser, no model downloads.
    if (!isDesktop) _init();
    _loadMail();
    AppSettings.load().then((settings) {
      if (!mounted) return;
      setState(() => _settings = settings);
      _inbox.checkEvery(settings.checkMinutes);
    });
  }

  void _rebuild() => setState(() {});

  Timer? _sleep;
  bool _awake = false;

  /// Keeps the screen on while the mic listens or a mail is read aloud:
  /// voice use has no touches, so the phone took it for idle. The phone's
  /// own timeout counts from the last touch, so letting go at once could
  /// blank the screen in the short gap between a question and listening.
  void _keepAwake() {
    if (_speech.listening || Reader.instance.speaking.value) {
      _sleep?.cancel();
      _sleep = null;
      // The recogniser notifies on every partial word; enable just once.
      if (!_awake) WakelockPlus.enable();
      _awake = true;
    } else if (_awake) {
      _awake = false;
      _sleep ??= Timer(const Duration(seconds: 30), WakelockPlus.disable);
    }
  }

  Future<void> _init() async {
    // A downloader that fails to start still leaves the models on the phone
    // usable.
    try {
      await _downloads.init();
    } catch (error) {
      debugPrint('Model downloads not started: $error');
    }
    await _speech.start();
    await _downloads.refreshOnPhone();
  }

  Future<void> _loadMail() async {
    try {
      await _inbox.load();
    } catch (_) {
      // Without this the accounts just looked unlinked, as if they were lost.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: Text(
              // Only macOS asks before the app may read its keychain item.
              Platform.isMacOS
                  ? '키체인 접근이 허용되지 않아 저장된 메일 계정을 불러오지 못했어요. '
                        '앱을 다시 켜고 허락 창에서 [항상 허용]을 눌러 주세요.'
                  : '저장된 메일 계정을 불러오지 못했어요. 앱을 다시 켜 주세요.',
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    Reader.instance.speaking.removeListener(_keepAwake);
    _sleep?.cancel();
    WakelockPlus.disable();
    _speech.dispose();
    _downloads.dispose();
    _clock?.cancel();
    _inbox.dispose();
    super.dispose();
  }

  /// Screens open in the content pane, above the dock.
  Future<void> _push(Widget screen, {String? section}) async {
    final push = ++_pushes;
    setState(() {
      _open++;
      if (section != null) _section = section;
    });
    final route = _top = MaterialPageRoute<void>(builder: (_) => screen);
    await (_content.currentState ?? Navigator.of(context)).push(route);
    if (!mounted) return;
    setState(() => _open--);
    if (push == _pushes) {
      setState(() => _section = 'home');
      _inbox.retryFailed();
    }
  }

  /// A dock tap on the [section] already open goes back to its first screen
  /// instead of closing and reopening it, which flashed home in between.
  void _reopen(String section, VoidCallback open) {
    if (_section != section || _top == null) return open();
    _content.currentState?.popUntil((route) => route == _top);
  }

  /// Back to home, before a dock tab opens its screen.
  void _goHome() => _content.currentState?.popUntil((route) => route.isFirst);

  void _openSettings() {
    _goHome();
    _push(
      section: 'settings',
      SettingsScreen(
        from: [homeLabel],
        accounts: _inbox.accounts,
        settings: _settings,
        onChanged: (settings) {
          setState(() => _settings = settings);
          settings.save();
          _inbox.checkEvery(settings.checkMinutes);
        },
        accountsScreen: _providerScreen,
        voiceScreen: (from) {
          _downloads.refreshOnPhone();
          return VoiceSettingsScreen(
            from: from,
            speech: _speech,
            downloads: _downloads,
          );
        },
      ),
    );
  }

  void _openMail() {
    _goHome();
    _push(
      section: 'mail',
      MailMenuScreen(
        from: [homeLabel],
        folderScreen: (folder, from) => _folderScreen(folder, from: from),
        inbox: _inbox,
        unreadCount: () => _unreadCount,
      ),
    );
  }

  void _openConnect() {
    _goHome();
    _push(section: 'connect', _providerScreen([homeLabel]));
  }

  Widget _providerScreen(List<String> from) => MailProviderScreen(
    from: from,
    accounts: _inbox.accounts,
    onAdded: _inbox.add,
    onRemoved: _inbox.remove,
  );

  /// Opens a [MailFolder] from a home card, [only] one account's mail when
  /// given.
  void _openFolder(MailFolder folder, {MailAccount? only}) {
    _goHome();
    _push(section: 'mail', _folderScreen(folder, only: only));
  }

  Widget _folderScreen(
    MailFolder folder, {
    List<String>? from,
    MailAccount? only,
  }) => MailFolderScreen(
    from: from ?? [homeLabel],
    folder: folder,
    accounts: _inbox.accounts,
    only: only,
    limit: _settings.listSize,
    onRead: _inbox.markRead,
    onOpenAll: (only) => _openFolder(MailFolder.all, only: only),
    speech: _speech,
  );

  void _openCompose() {
    _goHome();
    _push(
      section: 'compose',
      ComposeScreen(
        from: [homeLabel],
        accounts: _inbox.accounts,
        speech: _speech,
        // Everyone who sent unread mail, so a recipient can be named aloud.
        contacts: {
          for (final m in _inbox.mails.reversed)
            if (m.address.isNotEmpty)
              m.from.replaceAll(RegExp(r'에게$'), ''): m.address,
        },
      ),
    );
  }

  // ponytail: keyword match, not intent parsing; enough for "어, 해줘" /
  // "나중에" until a real assistant backend answers.
  // A bare "응"/"네" only counts as the whole answer; inside other words it
  // fired on background chatter.
  static final _yes = RegExp(r'읽어|읊어|해줘|해 줘|그래|좋아|^\s*(응|네|예|어)\s*[.!?]?\s*$');
  static final _later = RegExp(r'나중|그만|취소');

  void _checkCommand() {
    final said = '${_speech.heard} ${_speech.partial}';
    if (!_speech.listening || _opening) return;
    if (_later.hasMatch(said)) {
      _opening = true;
      _speech.toggleListening().whenComplete(() {
        _opening = false;
        Reader.instance.speak('알겠어요. 필요하면 다시 불러 주세요.');
      });
    } else if (_yes.hasMatch(said)) {
      _openBriefing();
    }
  }

  /// The mic: asks aloud whether to read the unread mail, then listens for
  /// the answer. Tapping again stops either step.
  Future<void> _talk() async {
    final reader = Reader.instance;
    if (_speech.listening) return _speech.toggleListening();
    if (_asking) {
      reader.stop();
      return setState(() => _asking = false);
    }
    final count = _unreadCount;
    if (_inbox.mails.isEmpty) {
      await reader.speak(
        _inbox.loading
            ? '메일을 불러오는 중이에요. 잠시 뒤에 다시 불러 주세요.'
            : _inbox.error != null
            ? '메일을 불러오지 못했어요.'
            : '안 읽은 메일이 없어요.',
      );
      return;
    }
    setState(() => _asking = true);
    // Listening only starts once the question ends, so the mic doesn't
    // hear the app's own voice.
    final problem = await reader.speak('안 읽은 메일이 $count건 있어요. 읽어드릴까요?');
    if (!mounted || !_asking) return;
    setState(() => _asking = false);
    // Cut off (a mail opened, or the mic tapped) or covered by another
    // screen: listening now would hear the app reading behind it.
    if (problem == Reader.cut || (_content.currentState?.canPop() ?? false)) {
      return;
    }
    // No voice: the question is still on screen, so listen anyway.
    if (problem != null) {
      showProblem(context, problem);
    }
    await _speech.toggleListening();
  }

  Future<void> _openBriefing() async {
    final mails = _inbox.mails;
    if (_opening) return;
    _opening = true;
    try {
      if (_speech.listening) await _speech.toggleListening();
      if (!mounted) return;
      if (mails.isEmpty) {
        showProblem(context, _inbox.error ?? '안 읽은 메일이 없어요');
        return;
      }
      await _push(
        BriefingScreen(
          from: [homeLabel],
          mails: mails,
          onRead: _inbox.markRead,
          speech: _speech,
        ),
      );
    } finally {
      _opening = false;
    }
    if (mounted) _speech.clear();
  }

  /// Unread mail across accounts: the server's count, or the example mails'.
  int get _unreadCount => _inbox.accounts.isEmpty
      ? mockMails.length
      : _inbox.accounts.fold(
          0,
          (n, a) => n + (_inbox.unreadTotal[a.address] ?? 0),
        );

  /// Draft C's widgets: the unread total on the left, opening 안 읽은 메일,
  /// and one row per account on the right with its own count.
  Widget _unreadWidgets(ColorScheme colors) {
    Widget card({required Widget child, required VoidCallback onTap}) =>
        Material(
          color: colors.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: colors.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: child),
        );
    final total = card(
      onTap: () => _openFolder(MailFolder.unread),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _inbox.accounts.isEmpty ? '예시 메일' : '안 읽은 메일',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: colors.onSurfaceVariant,
              ),
            ),
            Text.rich(
              TextSpan(
                text: '$_unreadCount',
                children: [
                  TextSpan(
                    text: '건',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: colors.onSurface,
                    ),
                  ),
                ],
              ),
              style: const TextStyle(
                fontSize: 56,
                height: 1,
                fontWeight: FontWeight.w900,
                color: accent,
              ),
            ),
            const Text(
              '메일함 열기 ›',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
    final rows = [
      for (final a in _inbox.accounts)
        SizedBox(
          height: 76,
          child: card(
            onTap: () => _openFolder(MailFolder.unread, only: a),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  ServiceBadge(a.service.mark, a.service.color, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      a.service.label.replaceAll(' 메일', ''),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_inbox.unread[a.address] == null &&
                      _inbox.errors[a.address] == null)
                    const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  else
                    Text(
                      switch (_inbox.unread[a.address]) {
                        null => '실패',
                        _ => '${_inbox.unreadTotal[a.address] ?? 0}',
                      },
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color:
                            _inbox.errors[a.address] != null &&
                                _inbox.unread[a.address] == null
                            ? colors.error
                            : colors.onSurface,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
    ];
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ConstrainedBox(
              // Two account rows tall, as drawn, even with one account.
              constraints: const BoxConstraints(minHeight: 162),
              child: total,
            ),
          ),
          if (rows.isNotEmpty) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                children: [
                  for (final (i, row) in rows.indexed) ...[
                    if (i > 0) const SizedBox(height: 10),
                    row,
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final needsModel = !_speech.busy && !_speech.loaded;
    // Nothing to talk with until this download lands, so the mic waits.
    final waiting = needsModel ? _downloads.downloading : null;
    final onMic = _speech.busy || waiting != null
        ? null
        : _speech.loaded
        ? _talk
        : () => requestDownload(context, _speech, _downloads, _speech.model);
    // Beside the mic: what tapping it does, and what to say.
    final (micTitle, micHint) = _speech.error
        ? (_speech.status, '다시 눌러 주세요')
        : _speech.busy
        ? (_speech.status, '처음 한 번만 조금 걸려요')
        : waiting != null
        ? (
            '${waiting.label} 모델 받는 중 · ${(_downloads.fraction * 100).floor()}%',
            '다 받으면 눌러서 말할 수 있어요',
          )
        : needsModel
        ? ('${_speech.model.label} 모델 내려받기', '${_speech.model.size}를 한 번 내려받아요')
        : _asking
        ? ('읽어드릴까요?', '질문이 끝나면 말씀해 주세요')
        : _speech.listening
        ? ('듣고 있어요', '말씀해 주세요')
        : _speech.partial == '…'
        ? ('말씀을 확인하고 있어요', '잠시만요')
        : (
            wide && !isDesktop ? '눌러서 말하기 · Space' : '눌러서 말하기',
            _speech.status == Recognizer.missed
                ? Recognizer.missed
                : '"오늘 메일 온 거 읊어줘"',
          );
    final heard = '${_speech.heard} ${_speech.partial}'.trim();

    // Idle: the card suggests what to say; otherwise it shows what the mic
    // is doing.
    final idle =
        micTitle.startsWith('눌러서 말하기') && _speech.status != Recognizer.missed;
    // What the mic is doing, in a bubble rising from it; idle it says
    // nothing, as in draft C.
    final status = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: colors.surfaceContainer,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    micTitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _speech.error ? colors.error : colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    micHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // The tail, pointing down at the mic.
        CustomPaint(
          size: const Size(16, 8),
          painter: _Tail(colors.surfaceContainer),
        ),
        const SizedBox(height: 4),
      ],
    );

    // Tab bar under every screen: 홈 · 메일함 | mic | 메일 작성 · 설정, the mic
    // rising above the bar. The bar sits 26 down inside the stack so the
    // raised part still takes taps.
    Widget tab(
      String label,
      IconData icon,
      IconData selectedIcon,
      bool selected,
      VoidCallback onTap,
    ) {
      final color = selected ? colors.onSurface : colors.onSurfaceVariant;
      return Expanded(
        child: Semantics(
          selected: selected,
          button: true,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 64,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(selected ? selectedIcon : icon, size: 24, color: color),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      color: color,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final bar = Stack(
      alignment: Alignment.topCenter,
      // The bubble draws above the bar, over the screen's bottom edge.
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 26),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              8,
              0,
              8,
              MediaQuery.viewPaddingOf(context).bottom,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Row(
              children: [
                tab(
                  homeLabel,
                  Icons.home_outlined,
                  Icons.home_rounded,
                  _section == 'home',
                  _goHome,
                ),
                tab(
                  '메일',
                  Icons.mail_outline_rounded,
                  Icons.mail_rounded,
                  _section == 'mail',
                  () => _reopen('mail', _openMail),
                ),
                const Spacer(),
                tab(
                  '메일 작성',
                  Icons.edit_outlined,
                  Icons.edit_rounded,
                  _section == 'compose',
                  () => _reopen('compose', _openCompose),
                ),
                tab(
                  '설정',
                  Icons.settings_outlined,
                  Icons.settings_rounded,
                  _section == 'settings',
                  () => _reopen('settings', _openSettings),
                ),
              ],
            ),
          ),
        ),
        _MicButton(
          busy: _speech.busy,
          icon: needsModel
              ? Icons.download_rounded
              : _speech.listening || _asking
              ? Icons.stop_rounded
              : Icons.mic_none_rounded,
          label: waiting != null
              ? '${waiting.label} 모델 받는 중, 다 받으면 말할 수 있어요'
              : _speech.busy
              ? '${_speech.status}, 잠시만요'
              : needsModel
              ? '${_speech.model.label} 모델 내려받기'
              : _speech.listening || _asking
              ? '듣기 멈추기'
              : '말하기 시작 · "오늘 메일 온 거 읊어줘"',
          // From another screen the mic goes home first, where the voice
          // chat shows.
          onPressed: onMic == null
              ? null
              : () {
                  _goHome();
                  onMic();
                },
        ),
        if (!idle)
          Positioned(
            top: 0,
            left: 16,
            right: 16,
            child: FractionalTranslation(
              translation: const Offset(0, -1),
              child: IgnorePointer(child: Center(child: status)),
            ),
          ),
      ],
    );

    final now = DateTime.now();
    final greeting = switch (now.hour) {
      >= 5 && < 12 => '좋은 아침이에요',
      >= 12 && < 18 => '좋은 오후예요',
      >= 18 && < 23 => '좋은 저녁이에요',
      _ => '편안한 밤 보내세요',
    };
    final mails = _inbox.mails;
    final list = RefreshIndicator(
      onRefresh: _inbox.refresh,
      child: ListView(
        // Pullable even when the cards don't fill the screen.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: wide
            ? const EdgeInsets.fromLTRB(48, 48, 48, 32)
            : const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Align(alignment: Alignment.centerLeft, child: Brand()),
          ),
          const SizedBox(height: 16),
          if (!isDesktop && _downloads.shown != null) ...[
            DownloadBanner(_downloads),
            const SizedBox(height: 20),
          ],
          // 01 voice home ⇄ 02 listening share this screen.
          if (_speech.listening || _asking) ...[
            _Bubble(
              '안 읽은 메일이 $_unreadCount건 있어요. 읽어드릴까요?',
              hint: '"어, 해줘" 또는 "나중에"',
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    greeting,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${now.month}월 ${now.day}일 '
                    '${'월화수목금토일'[now.weekday - 1]}요일',
                    style: TextStyle(
                      fontSize: 15,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _unreadWidgets(colors),
            if (_inbox.accounts.isEmpty) ...[
              const SizedBox(height: 10),
              VoiceCard(
                onTap: _openConnect,
                child: Text(
                  '예시 메일이에요. 누르면 메일 연동으로 가요',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
            ],
            if (_inbox.error case final error?) ...[
              const SizedBox(height: 10),
              ProblemText(
                '$error\n아래로 당기면 다시 불러와요',
                style: TextStyle(fontSize: 13, color: colors.error),
              ),
            ],
            if (mails.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 22, 4, 8),
                child: Text(
                  '최근 안 읽은 메일',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
              MailTile(
                mails.first,
                read: false,
                showSource: true,
                onTap: () => _push(
                  BriefingScreen(
                    from: [homeLabel],
                    mails: mails,
                    onRead: _inbox.markRead,
                    autoRead: false,
                    speech: _speech,
                  ),
                ),
              ),
            ],
          ],
          if (!isDesktop) ...[
            if (_speech.listening || heard.isNotEmpty) ...[
              const SizedBox(height: 12),
              _Bubble(
                heard.isEmpty ? '…' : heard,
                mine: true,
                listening: _speech.listening,
              ),
              const SizedBox(height: 16),
              Text(
                '음성은 기기 안에서 인식합니다',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ],
          ],
        ],
      ),
    );
    // Home and every screen opened from it share this navigator, so the dock
    // stays put underneath them all.
    final screens = NavigatorPopHandler(
      enabled: _open > 0,
      onPopWithResult: (_) => _content.currentState?.maybePop(),
      child: Navigator(
        key: _content,
        pages: [
          MaterialPage(
            key: const ValueKey('home'),
            child: Material(
              color: colors.surface,
              child: wide
                  ? Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: list,
                      ),
                    )
                  : list,
            ),
          ),
        ],
        onDidRemovePage: (_) {},
      ),
    );
    // Hidden while typing, so the keyboard doesn't push it up the screen.
    final showBar = !isDesktop && MediaQuery.viewInsetsOf(context).bottom == 0;
    final content = Column(
      children: [
        // The bar pads itself for the home indicator; screens above it don't.
        Expanded(
          // This context sits above the SafeArea, so drop the status bar
          // again too, or every screen's top bar sits a status bar lower.
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: showBar,
            child: screens,
          ),
        ),
        if (showBar) bar,
      ],
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        systemNavigationBarColor: colors.surface,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: CallbackShortcuts(
        bindings: {
          if (!isDesktop)
            const SingleActivator(LogicalKeyboardKey.space): () {
              // Only on the home pane, where the mic is.
              if (onMic != null &&
                  !(_content.currentState?.canPop() ?? false)) {
                onMic();
              }
            },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(body: SafeArea(bottom: false, child: content)),
        ),
      ),
    );
  }
}

/// Black round mic rising out of the tab bar. Listening shows a stop icon;
/// the card above says what it hears.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.busy,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final bool busy;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Opacity(
          opacity: onPressed == null ? 0.4 : 1,
          child: Material(
            color: colors.primary,
            shape: CircleBorder(
              side: BorderSide(color: colors.surface, width: 4),
            ),
            elevation: 6,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox.square(
                dimension: 64,
                child: busy
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: colors.onPrimary,
                        ),
                      )
                    : Icon(icon, size: 26, color: voiceBlue),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One line of the voice chat, as in a messenger: the app's on the left in
/// a card-white bubble, the user's on the right in grey, each with the
/// corner nearest its side as the tail.
class _Bubble extends StatelessWidget {
  const _Bubble(
    this.text, {
    this.mine = false,
    this.hint,
    this.listening = false,
  });

  final String text;
  final bool mine;
  final String? hint;

  /// Shows a dot beside the bubble while the mic is still hearing it.
  final bool listening;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const round = Radius.circular(20);
    const tail = Radius.circular(4);
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: mine ? colors.primaryContainer : colors.surfaceContainer,
        border: mine ? null : Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.only(
          topLeft: round,
          topRight: round,
          bottomLeft: mine ? round : tail,
          bottomRight: mine ? tail : round,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: mine ? 20 : 18,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: mine ? colors.onPrimaryContainer : colors.onSurface,
            ),
          ),
          if (hint case final hint?) ...[
            const SizedBox(height: 4),
            Text(hint, style: TextStyle(color: colors.onSurfaceVariant)),
          ],
        ],
      ),
    );
    return Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (listening) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Icon(Icons.circle, size: 8, color: colors.primary),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.85,
            ),
            child: bubble,
          ),
        ),
      ],
    );
  }
}

/// A small downward triangle under the mic's status bubble.
class _Tail extends CustomPainter {
  const _Tail(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Path()
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close(),
    Paint()..color = color,
  );

  @override
  bool shouldRepaint(_Tail old) => old.color != color;
}
