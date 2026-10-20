import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mail/mail.dart';
import '../mail/mail_account.dart';
import '../mail/mail_inbox.dart';
import '../voice/model_downloads.dart';
import '../voice/speech.dart';
import '../voice/tts.dart';
import '../widgets.dart';
import 'connect.dart';
import 'home_menu.dart';
import 'mail_list.dart';
import 'mail_view.dart';
import 'offline.dart';
import 'settings.dart';
import 'voice_settings.dart';

/// Voice home: the mic, each account's unread count, and the menu. Speech,
/// downloads and mail live in their own classes; this screen wires them up.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final _speech = Recognizer();
  late final _downloads = ModelDownloads(onDone: _speech.switchWhenFree);
  final _inbox = MailInbox();
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  final _scaffold = GlobalKey<ScaffoldState>();
  final _content = GlobalKey<NavigatorState>();
  AppSettings _settings = const AppSettings();
  bool _opening = false;

  /// Saying "읽어드릴까요?" before the mic turns on.
  bool _asking = false;

  /// Menu item lit up in the sidebar; [_push] sets it, and it goes back to
  /// home once that screen closes.
  String _section = 'home';

  /// Sidebar shrunk to an icon rail (wide windows only).
  bool _railOnly = false;

  /// Bumped per [_push], so a screen closing after another menu item has
  /// opened leaves the newer highlight alone.
  int _pushes = 0;

  @override
  void initState() {
    super.initState();
    for (final state in [_speech, _downloads, _inbox]) {
      state.addListener(_rebuild);
    }
    _speech.onSpeech = _checkCommand;
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
    _speech.dispose();
    _downloads.dispose();
    _inbox.dispose();
    _pulse.dispose();
    super.dispose();
  }

  /// Wide windows open screens in the content pane beside the sidebar.
  Future<void> _push(Widget screen, {String? section}) async {
    final push = ++_pushes;
    if (section != null) setState(() => _section = section);
    await (_content.currentState ?? Navigator.of(context)).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted && push == _pushes) {
      setState(() => _section = 'home');
      _inbox.retryFailed();
    }
  }

  /// Menu taps close the drawer; the sidebar has none to close.
  void _closeDrawer() {
    if (_scaffold.currentState?.isDrawerOpen ?? false) Navigator.pop(context);
  }

  /// Back to home with the drawer shut, before a menu item opens its screen.
  void _goHome() {
    _closeDrawer();
    _content.currentState?.popUntil((route) => route.isFirst);
  }

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

  /// Opens a [MailFolder] from the menu or a home card, [only] one
  /// account's mail when given.
  void _openFolder(MailFolder folder, {MailAccount? only}) {
    _goHome();
    _push(
      section: folder.name,
      MailFolderScreen(
        from: [homeLabel],
        folder: folder,
        accounts: _inbox.accounts,
        only: only,
        limit: _settings.listSize,
        onRead: _inbox.markRead,
        onAllRead: _inbox.allRead,
        onOpenAll: (only) => _openFolder(MailFolder.all, only: only),
        speech: _speech,
      ),
    );
  }

  void _openVoiceSettings() {
    _downloads.refreshOnPhone();
    _goHome();
    _push(
      section: 'voice',
      VoiceSettingsScreen(
        from: [homeLabel],
        speech: _speech,
        downloads: _downloads,
      ),
    );
  }

  void _openOffline() {
    _goHome();
    _push(section: 'offline', OfflineScreen(from: [homeLabel]));
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
    final count = _inbox.mails.length;
    if (count == 0) {
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
    if (problem == Reader.cut || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    // No voice: the question is still on screen, so listen anyway.
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_inbox.error ?? '안 읽은 메일이 없어요')));
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

  Widget _menu({bool sidebar = false}) => HomeMenu(
    sidebar: sidebar,
    railOnly: _railOnly,
    onToggleRail: () => setState(() => _railOnly = !_railOnly),
    section: _section,
    linked: _inbox.accounts.isNotEmpty,
    onHome: _goHome,
    onFolder: _openFolder,
    onVoice: _openVoiceSettings,
    onConnect: _openConnect,
    onSettings: _openSettings,
    onOffline: _openOffline,
  );

  Widget _mailCard(
    ColorScheme colors,
    String mark,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => VoiceCard(
    onTap: onTap,
    child: Row(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: colors.primaryContainer,
          child: Text(
            mark,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: colors.primary,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (_speech.listening && !reduceMotion) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final needsModel = !_speech.busy && !_speech.loaded;
    final onMic = _speech.busy || (needsModel && _downloads.downloading != null)
        ? null
        : _speech.loaded
        ? _talk
        : () => requestDownload(context, _speech, _downloads, _speech.model);
    // Beside the mic: what tapping it does, and what to say.
    final (micTitle, micHint) = _speech.error
        ? (_speech.status, '다시 눌러 주세요')
        : _speech.busy
        ? (_speech.status, '처음 한 번만 조금 걸려요')
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

    final content = RefreshIndicator(
      onRefresh: _inbox.refresh,
      child: ListView(
        // Pullable even when the cards don't fill the screen.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: wide
            ? const EdgeInsets.fromLTRB(48, 48, 48, 32)
            : const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          if (!wide) ...[
            Row(
              children: [
                IconButton.outlined(
                  tooltip: '메뉴',
                  onPressed: () => _scaffold.currentState?.openDrawer(),
                  icon: const Icon(Icons.menu_rounded),
                  style: IconButton.styleFrom(
                    side: BorderSide(color: colors.outlineVariant),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Brand(),
              ],
            ),
            const SizedBox(height: 28),
          ],
          if (!isDesktop && _downloads.shown != null) ...[
            DownloadBanner(_downloads),
            const SizedBox(height: 20),
          ],
          // 01 voice home ⇄ 02 listening share this screen.
          if (_speech.listening || _asking) ...[
            ScreenTitle(_inbox.source, '안 읽은 메일 ${_inbox.mails.length}건'),
            const SizedBox(height: 18),
            VoiceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '읽어드릴까요?',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '"어, 해줘" 또는 "나중에"',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ] else ...[
            isDesktop
                ? const ScreenTitle('메일 홈', '오늘 확인할 메일')
                : const ScreenTitle('운전 중에도', '메일을 듣고\n말로 답장하세요'),
            const SizedBox(height: 18),
            if (_inbox.accounts.isEmpty)
              _mailCard(
                colors,
                'N',
                '예시 메일 · 안 읽은 메일 ${mockMails.length}건',
                '메일 연동하기를 누르면 내 메일로 바뀌어요',
                () => _openFolder(MailFolder.unread),
              ),
            for (final (i, a) in _inbox.accounts.indexed) ...[
              if (i > 0) const SizedBox(height: 10),
              _mailCard(
                colors,
                a.service.mark,
                switch (_inbox.unread[a.address]) {
                  null when _inbox.errors[a.address] == null =>
                    '${a.service.label} · 불러오는 중',
                  null => '${a.service.label} · 불러오지 못했어요',
                  _ =>
                    '${a.service.label} · 안 읽은 메일 ${_inbox.unreadTotal[a.address]}건',
                },
                _inbox.errors[a.address] ?? a.address,
                // Nothing unread: the whole inbox is what's left to see.
                () => _openFolder(
                  _inbox.unreadTotal[a.address] == 0
                      ? MailFolder.all
                      : MailFolder.unread,
                  only: a,
                ),
              ),
            ],
          ],
          if (!isDesktop) ...[
            const SizedBox(height: 28),
            Row(
              children: [
                _MicButton(
                  pulse: _pulse,
                  listening: _speech.listening,
                  busy: _speech.busy,
                  icon: needsModel
                      ? Icons.download_rounded
                      : _speech.listening || _asking
                      ? Icons.stop_rounded
                      : Icons.mic_none_rounded,
                  label: needsModel
                      ? '${_speech.model.label} 모델 내려받기'
                      : _speech.listening || _asking
                      ? '듣기 멈추기'
                      : '말하기 시작',
                  onPressed: onMic,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          micTitle,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: _speech.error
                                ? colors.error
                                : colors.primary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          micHint,
                          style: TextStyle(
                            fontSize: 15,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (_speech.listening || heard.isNotEmpty) ...[
              const SizedBox(height: 24),
              VoiceCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '인식한 말',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            heard.isEmpty ? '…' : '“$heard”',
                            style: const TextStyle(
                              fontSize: 22,
                              height: 1.4,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_speech.listening)
                      Icon(Icons.circle, size: 12, color: colors.primary),
                  ],
                ),
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
          child: Scaffold(
            key: _scaffold,
            drawer: wide ? null : Drawer(child: _menu()),
            body: wide
                ? Row(
                    children: [
                      Container(
                        width: _railOnly ? 84 : 288,
                        decoration: BoxDecoration(
                          border: Border(
                            right: BorderSide(color: colors.outlineVariant),
                          ),
                        ),
                        child: _menu(sidebar: true),
                      ),
                      Expanded(
                        child: Navigator(
                          key: _content,
                          pages: [
                            MaterialPage(
                              key: const ValueKey('home'),
                              child: Material(
                                color: colors.surface,
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 760,
                                    ),
                                    child: content,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          onDidRemovePage: (_) {},
                        ),
                      ),
                    ],
                  )
                : SafeArea(child: content),
          ),
        ),
      ),
    );
  }
}

/// Round flat brown mic. Idle: a hairline ring like the cards' borders. Listening: rings keep
/// spreading out, so "it hears me" reads at a glance; with system animations
/// off the rings stay still and the label carries the state.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.pulse,
    required this.listening,
    required this.busy,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final AnimationController pulse;
  final bool listening;
  final bool busy;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  static const _size = 76.0;
  static const _fill = Color(0xff000000);
  static const _glyph = Color(0xffffffff);

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: _size * 1.6,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: pulse,
            builder: (context, _) => CustomPaint(
              size: const Size.square(_size * 1.6),
              painter: _RingsPainter(
                listening: listening,
                t: pulse.value,
                inner: _size / 2,
              ),
            ),
          ),
          Semantics(
            button: true,
            label: label,
            child: Tooltip(
              message: label,
              child: Opacity(
                opacity: onPressed == null ? 0.4 : 1,
                child: Container(
                  width: _size,
                  height: _size,
                  // Flat like the rest of the app: no gradient, no glow.
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: _fill,
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: onPressed,
                      child: busy
                          ? const Padding(
                              padding: EdgeInsets.all(24),
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: _glyph,
                              ),
                            )
                          : Icon(icon, size: 36, color: _glyph),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({
    required this.listening,
    required this.t,
    required this.inner,
  });

  final bool listening;
  final double t;
  final double inner;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.width / 2;
    final paint = Paint()..style = PaintingStyle.stroke;
    // Resting: one hairline ring in the cards' border colour.
    canvas.drawCircle(
      center,
      inner + 12,
      paint
        ..strokeWidth = 1.5
        ..color = const Color(0xffd6d6d6),
    );
    if (!listening) return;
    // Two rings, half a cycle apart, growing from the button edge outward.
    for (final offset in [0.0, 0.5]) {
      final p = (t + offset) % 1;
      canvas.drawCircle(
        center,
        inner + 12 + (outer - inner - 12) * p,
        paint
          ..strokeWidth = 2
          ..color = const Color(0xff000000).withValues(alpha: 0.45 * (1 - p)),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.t != t || old.listening != listening;
}
