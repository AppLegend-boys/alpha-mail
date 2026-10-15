import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'mail_account.dart';
import 'summary.dart';
import 'tts.dart';

/// Amber for offline / waiting states (design 06).
const amber = Color(0xfff2a93b);
const amberCard = Color(0xff2a2218);

class Mail {
  const Mail(
    this.from,
    this.subject,
    this.body,
    this.length,
    this.draft, {
    this.html,
    this.source = '예시 메일',
    this.date,
    this.account,
    this.uid,
    this.seen = false,
  });
  final String from;
  final String subject;
  final String body;

  /// How long reading it aloud takes, shown beside the waveform.
  final String length;
  final String draft;

  /// Original HTML body, shown as sent so its images and layout survive;
  /// [body] stays the plain text to read aloud.
  final String? html;

  /// Mail service it came from, e.g. 네이버 메일.
  final String source;
  final DateTime? date;

  /// Where to mark it read; null for the example mails.
  final MailAccount? account;
  final int? uid;

  /// Already read when fetched, or sent by the user.
  final bool seen;
}

/// Marks [mail] read on its server, then tells [onRead]. Best effort: a
/// failure just leaves it unread.
void markRead(Mail mail, void Function(Mail)? onRead) {
  if (mail case Mail(:final account?, :final uid?, seen: false)) {
    account
        .markSeen(uid)
        .then(
          (_) => onRead?.call(mail),
          onError: (Object e) {
            debugPrint('mark read failed: $e');
          },
        );
  }
}

/// Desktop is mail-first for now: voice recognition and its models are off.
final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// First crumb of every menu path, named after what home is on this device.
final homeLabel = isDesktop ? '메일 홈' : '홈';

const mockMails = [
  Mail(
    '프로젝트 운영팀',
    '오늘 일정 안내',
    '오늘 오후 3시 기획 회의가\n4층 회의실에서 열립니다.\n자료를 미리 확인해 주세요.',
    '0:18',
    '안녕하세요,\n메일 확인했습니다.\n오늘 오후 회의에\n참석하겠습니다.\n감사합니다.',
  ),
  Mail(
    '김서연 매니저',
    '견적서 회신 부탁드립니다',
    '지난주 요청하신 견적서를 첨부합니다.\n금요일까지 검토 후\n회신 부탁드립니다.',
    '0:14',
    '안녕하세요,\n견적서 잘 받았습니다.\n금요일까지 검토 후\n회신드리겠습니다.',
  ),
  Mail(
    '네이버페이',
    '결제 완료 안내',
    '주문하신 상품의 결제가\n정상적으로 완료되었습니다.',
    '0:09',
    '확인했습니다.\n감사합니다.',
  ),
];

/// Rounded dark card with a hairline border, the base of every block.
class VoiceCard extends StatelessWidget {
  const VoiceCard({
    super.key,
    required this.child,
    this.color,
    this.borderColor,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(14);
    return Material(
      color: color ?? colors.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: borderColor ?? colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Small grey label above a big white title, as on every design screen.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.label, this.title, {super.key});
  final String label;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            height: 1.35,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

/// The two big buttons at the bottom: outlined left, mint right.
class ButtonPair extends StatelessWidget {
  const ButtonPair({
    super.key,
    required this.left,
    required this.right,
    required this.onLeft,
    required this.onRight,
  });

  final String left;
  final String right;
  final VoidCallback onLeft;
  final VoidCallback onRight;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: onLeft,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              foregroundColor: colors.onSurface,
              backgroundColor: colors.surfaceContainer,
              side: BorderSide(color: colors.outlineVariant),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(left),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(onPressed: onRight, child: Text(right)),
        ),
      ],
    );
  }
}

class _Page extends StatefulWidget {
  const _Page({required this.trail, required this.children});

  /// Menu path from home to this screen, shown top left.
  final List<String> trail;
  final List<Widget> children;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  /// Set once a trackpad swipe has gone back, so one swipe pops one page.
  bool _swiped = false;

  // Mouse back button and two-finger swipe right go back, as in a browser.
  // ponytail: Flutter can't see gestures over the mail's WebView.
  void _onPointer(PointerEvent event) {
    switch (event) {
      case PointerDownEvent(:final buttons)
          when buttons & kBackMouseButton != 0:
        Navigator.maybePop(context);
      case PointerPanZoomStartEvent():
        _swiped = false;
      case PointerPanZoomUpdateEvent(:final pan)
          when !_swiped && pan.dx > 120 && pan.dx > pan.dy.abs() * 2:
        _swiped = true;
        Navigator.maybePop(context);
      default:
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onPointer,
    onPointerPanZoomStart: _onPointer,
    onPointerPanZoomUpdate: _onPointer,
    child: Scaffold(
      appBar: AppBar(titleSpacing: 0, title: _Trail(widget.trail)),
      body: SafeArea(
        top: false,
        // Desktop windows: keep the column readable instead of edge to edge.
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: widget.children,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Breadcrumb like "메일 홈 › 메일 연동하기 › 네이버 메일". Each crumb is one
/// route on the stack, so tapping one pops back to it.
class _Trail extends StatelessWidget {
  const _Trail(this.trail);
  final List<String> trail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '현재 위치',
      child: Row(
        children: [
          for (final (i, crumb) in trail.indexed) ...[
            if (i > 0)
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            Flexible(
              child: i == trail.length - 1
                  ? Text(
                      crumb,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : TextButton(
                      onPressed: () {
                        var back = trail.length - 1 - i;
                        Navigator.popUntil(context, (_) => back-- == 0);
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: colors.onSurfaceVariant,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 36),
                        textStyle: const TextStyle(fontSize: 15),
                      ),
                      child: Text(crumb, overflow: TextOverflow.ellipsis),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Mail lists in the menu, each across every linked account.
enum MailFolder {
  all('전체 메일'),
  unread('안 읽은 메일'),
  sent('보낸 메일');

  const MailFolder(this.label);
  final String label;
}

/// One [MailFolder] of every linked account, newest first, with a chip per
/// account to look at one alone. No accounts shows the example mails.
class MailFolderScreen extends StatefulWidget {
  const MailFolderScreen({
    super.key,
    required this.from,
    required this.folder,
    required this.accounts,
    this.only,
    this.limit = 20,
    this.onRead,
    this.onAllRead,
    this.onOpenAll,
  });

  final List<String> from;
  final MailFolder folder;

  /// Mails per account, from [AppSettings.listSize].
  final int limit;
  final List<MailAccount> accounts;

  /// The account picked first; null shows every account.
  final MailAccount? only;

  /// Called once an unread mail opened from here is marked read.
  final void Function(Mail)? onRead;

  /// Called once every inbox mail of the account is marked read.
  final void Function(MailAccount)? onAllRead;

  /// Opens 전체 메일, for [only] that account when given; the unread list
  /// links there at its end.
  final void Function(MailAccount? only)? onOpenAll;

  @override
  State<MailFolderScreen> createState() => _MailFolderScreenState();
}

class _MailFolderScreenState extends State<MailFolderScreen> {
  late String? _only = widget.only?.address;
  final _mails = <String, List<Mail>>{};
  final _errors = <String, String>{};

  /// Unread folder: the inbox's whole unread count per account.
  final _totals = <String, int>{};

  /// Accounts whose unread were all marked read here.
  final _allRead = <String>{};

  /// (address, UID) of mails read since the list opened.
  final _read = <(String, int)>{};
  bool _marking = false;

  /// Accounts whose last page came back full, so older mail may be left.
  final _more = <String>{};
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    for (final account in widget.accounts) {
      _fetch(account);
    }
  }

  /// Fetches the newest page, or with [before] the page older than that UID
  /// added to the end.
  Future<void> _fetch(MailAccount account, {int? before}) async {
    try {
      final mails = switch (widget.folder) {
        MailFolder.unread =>
          await account.fetchUnread(limit: widget.limit, before: before).then((
            unread,
          ) {
            // An older page counts only what's older, not the inbox.
            if (before == null) _totals[account.address] = unread.total;
            return unread.mails;
          }),
        MailFolder.all => await account.fetchRecent(
          limit: widget.limit,
          before: before,
        ),
        MailFolder.sent => await account.fetchRecent(
          limit: widget.limit,
          sent: true,
          before: before,
        ),
      };
      if (!mounted) return;
      setState(() {
        _mails[account.address] = [...?_mails[account.address], ...mails];
        mails.length >= widget.limit
            ? _more.add(account.address)
            : _more.remove(account.address);
      });
    } catch (error) {
      final message =
          '${account.address}: ${mailError(account.service, error)}';
      if (mounted) setState(() => _errors[account.address] = message);
    }
  }

  /// 더 보기: the next older page of every shown account that has one.
  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    await Future.wait([
      for (final a in _shown)
        if (_more.contains(a.address))
          _fetch(
            a,
            before: _mails[a.address]!.map((m) => m.uid!).reduce(math.min),
          ),
    ]);
    if (mounted) setState(() => _loadingMore = false);
  }

  List<MailAccount> get _shown => [
    for (final a in widget.accounts)
      if (_only == null || a.address == _only) a,
  ];

  bool get _loading => _shown.any(
    (a) => !_mails.containsKey(a.address) && !_errors.containsKey(a.address),
  );

  List<Mail> get _list => widget.accounts.isEmpty
      ? mockMails
      : ([for (final a in _shown) ...?_mails[a.address]]..sort(
          (a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)),
        ));

  bool _isRead(Mail mail) => switch (mail) {
    Mail(seen: true) => true,
    Mail(:final account?, :final uid?) =>
      _allRead.contains(account.address) ||
          _read.contains((account.address, uid)),
    _ => false,
  };

  int get _left => widget.accounts.isEmpty
      ? mockMails.length
      : [
          for (final a in _shown)
            if (!_allRead.contains(a.address))
              (_totals[a.address] ?? 0) -
                  (_mails[a.address] ?? const []).where(_isRead).length,
        ].fold(0, (sum, n) => sum + n);

  Future<void> _markAll() async {
    final accounts = [
      for (final a in _shown)
        if (_mails.containsKey(a.address) && !_allRead.contains(a.address)) a,
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('모두 읽음으로 표시할까요?'),
        content: Text(
          '${accounts.map((a) => a.address).join(', ')}의 안 읽은 메일 '
          '$_left건이 메일함에서도 읽음으로 바뀌어요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('모두 읽음'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _marking = true);
    await Future.wait([
      for (final account in accounts)
        account.markAllSeen().then(
          (_) {
            if (mounted) setState(() => _allRead.add(account.address));
            widget.onAllRead?.call(account);
          },
          onError: (Object error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${account.address}: ${mailError(account.service, error)}',
                ),
              ),
            );
          },
        ),
    ]);
    if (mounted) setState(() => _marking = false);
  }

  void _onRead(Mail mail) {
    if (mounted) setState(() => _read.add((mail.account!.address, mail.uid!)));
    widget.onRead?.call(mail);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final accounts = widget.accounts;
    final mails = _list;
    final unread = widget.folder == MailFolder.unread;
    return _Page(
      trail: [...widget.from, widget.folder.label],
      children: [
        ScreenTitle(switch (accounts) {
          [] => '예시 메일',
          [final single] => single.address,
          _ => _only ?? '메일 ${accounts.length}개 계정',
        }, unread ? '안 읽은 메일 $_left건' : widget.folder.label),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (accounts.length > 1)
                    for (final address in [
                      null,
                      ...accounts.map((a) => a.address),
                    ])
                      ChoiceChip(
                        label: Text(address ?? '전체 계정'),
                        selected: _only == address,
                        onSelected: (_) => setState(() => _only = address),
                      ),
                ],
              ),
            ),
            if (unread && accounts.isNotEmpty)
              TextButton.icon(
                onPressed: _marking || _loading || _left <= 0 ? null : _markAll,
                icon: _marking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.done_all_rounded),
                label: const Text('모두 읽음'),
              ),
          ],
        ),
        const SizedBox(height: 14),
        for (final a in _shown)
          if (_errors[a.address] case final error?) ...[
            Text(error, style: hint),
            const SizedBox(height: 8),
          ],
        if (mails.isEmpty)
          _loading
              ? const Center(child: CircularProgressIndicator())
              : Text('메일이 없어요', textAlign: TextAlign.center, style: hint),
        for (final (i, mail) in mails.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          MailTile(
            mail,
            read: _isRead(mail),
            showSource: _only == null && accounts.length > 1,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => BriefingScreen(
                  from: [...widget.from, widget.folder.label],
                  mails: mails,
                  index: i,
                  onRead: _onRead,
                  autoRead: false,
                ),
              ),
            ),
          ),
        ],
        if (_loading && mails.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('다른 계정 메일을 불러오는 중…', textAlign: TextAlign.center, style: hint),
        ] else if (_shown.any((a) => _more.contains(a.address))) ...[
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _loadingMore ? null : _loadMore,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: _loadingMore
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('더 보기'),
          ),
        ],
        if (unread && accounts.isNotEmpty && widget.onOpenAll != null) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => widget.onOpenAll!(
              accounts.where((a) => a.address == _only).firstOrNull,
            ),
            icon: const Icon(Icons.inbox_rounded),
            label: const Text('전체 메일함 가기'),
          ),
        ],
      ],
    );
  }
}

/// One row of a mail list: sender, time, subject and the first body line.
/// Read ones fade, as in a mail app's list.
class MailTile extends StatelessWidget {
  const MailTile(
    this.mail, {
    super.key,
    required this.read,
    required this.onTap,
    this.showSource = false,
  });

  final Mail mail;
  final bool read;
  final VoidCallback onTap;

  /// Prefix the time with the mail service, for lists mixing accounts.
  final bool showSource;

  static String _when(DateTime? date) {
    if (date == null) return '';
    final d = date.toLocal();
    final now = DateTime.now();
    String two(int n) => '$n'.padLeft(2, '0');
    return d.year == now.year && d.month == now.month && d.day == now.day
        ? '${two(d.hour)}:${two(d.minute)}'
        : '${d.month}/${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final when = _when(mail.date);
    return VoiceCard(
      onTap: onTap,
      child: Opacity(
        opacity: read ? 0.5 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    mail.from,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  showSource ? '${mail.source} · $when' : when,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              mail.subject,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 2),
            Text(
              mail.body.replaceAll(RegExp(r'\s+'), ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// 03 — reads one unread mail aloud, with a waveform while it plays.
class BriefingScreen extends StatefulWidget {
  const BriefingScreen({
    super.key,
    required this.from,
    this.index = 0,
    this.mails = mockMails,
    this.onRead,
    this.autoRead = true,
  });

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
    if (widget.autoRead) _read();
  }

  @override
  void dispose() {
    _reader.speaking.removeListener(_syncWave);
    _reader.stop();
    _wave.dispose();
    super.dispose();
  }

  void _syncWave() {
    _reader.speaking.value ? _wave.repeat() : _wave.stop();
    setState(() {});
  }

  /// Reads who and what, then the AI summary once it's written (the whole
  /// body if the summary model isn't downloaded or the summary fails).
  Future<void> _read() async {
    final mail = widget.mails[_index];
    final summarizer = Summarizer.instance;
    final rest = await summarizer.installed
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
      '${mail.from}.\n${mail.subject}.',
      then: rest,
    );
    if (problem != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
    }
  }

  void _next() {
    if (_index == widget.mails.length - 1) {
      _reader.stop();
      Navigator.pop(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('안 읽은 메일을 모두 들었어요')));
      return;
    }
    setState(() => _index++);
    markRead(widget.mails[_index], widget.onRead);
    if (widget.autoRead || _reader.speaking.value) {
      _read();
    } else {
      _reader.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mail = widget.mails[_index];
    return _Page(
      trail: [...widget.from, '메일 읽기'],
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
        _SummaryCard(mail),
        const SizedBox(height: 16),
        if (mail.html case final html?)
          _MailHtml(html)
        else
          Text(mail.body, style: const TextStyle(fontSize: 18, height: 1.7)),
        const SizedBox(height: 24),
        VoiceCard(
          onTap: () => _reader.speaking.value ? _reader.stop() : _read(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _reader.speaking.value ? '지금 읽어주는 중 · 눌러서 멈추기' : '눌러서 듣기',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 40,
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
                    mail.length,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ButtonPair(
          left: '다음 메일',
          right: '답장하기',
          onLeft: _next,
          onRight: () {
            _reader.stop();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ReplyScreen(mail: mail, from: [...widget.from, '메일 읽기']),
              ),
            );
          },
        ),
        const SizedBox(height: 14),
        Text(
          '"답장해줘" 또는 "다음 메일"',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// AI summary of [mail], written on the phone as it's read; offers the
/// model download the first time. Tap a finished summary to hear it.
class _SummaryCard extends StatefulWidget {
  const _SummaryCard(this.mail);
  final Mail mail;

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
      onTap: done ? () => Reader.instance.speak(_text) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(done ? 'AI 요약 · 눌러서 듣기' : 'AI 요약', style: hint),
          const SizedBox(height: 8),
          body,
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

  Future<void> _measure() async {
    try {
      final result = await _web.runJavaScriptReturningResult(
        'document.documentElement.scrollHeight',
      );
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

/// 04 — reads back a reply draft; nothing is sent without a clear yes.
class ReplyScreen extends StatefulWidget {
  const ReplyScreen({super.key, required this.mail, required this.from});
  final Mail mail;
  final List<String> from;

  @override
  State<ReplyScreen> createState() => _ReplyScreenState();
}

class _ReplyScreenState extends State<ReplyScreen> {
  final _reader = Reader.instance;

  @override
  void initState() {
    super.initState();
    _reader.speaking.addListener(_redraw);
  }

  @override
  void dispose() {
    _reader.speaking.removeListener(_redraw);
    _reader.stop();
    super.dispose();
  }

  void _redraw() => setState(() {});

  Future<void> _toggle() async {
    if (_reader.speaking.value) return _reader.stop();
    final problem = await _reader.speak(widget.mail.draft);
    if (problem != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Page(
      trail: [...widget.from, '답장'],
      children: [
        ScreenTitle('${widget.mail.from}에게', '답장 초안'),
        const SizedBox(height: 20),
        VoiceCard(
          padding: const EdgeInsets.all(18),
          child: Text(
            widget.mail.draft,
            style: const TextStyle(fontSize: 18, height: 1.7),
          ),
        ),
        const SizedBox(height: 14),
        VoiceCard(
          onTap: _toggle,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                _reader.speaking.value
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: colors.primary,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  '초안 다시 듣기',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          '이대로 보낼까요?',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 14),
        ButtonPair(
          left: '다시 말하기',
          right: '확인 후 보내기',
          onLeft: () => Navigator.pop(context),
          onRight: () {
            Navigator.popUntil(context, (route) => route.isFirst);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('보냈어요 (목업이라 실제로 발송되지 않아요)')),
            );
          },
        ),
        const SizedBox(height: 12),
        Text(
          '사용자가 말해야 발송됩니다',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: colors.primary),
        ),
      ],
    );
  }
}

/// 06 — cached briefing while offline; sending waits for a connection.
class OfflineScreen extends StatelessWidget {
  const OfflineScreen({super.key, required this.from});
  final List<String> from;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Page(
      trail: [...from, '오프라인 화면'],
      children: [
        VoiceCard(
          color: amberCard,
          borderColor: amber.withValues(alpha: 0.6),
          child: const Row(
            children: [
              Icon(Icons.circle, size: 12, color: amber),
              SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '오프라인',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: amber,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text('오전 9:12 이후 연결 끊김', style: TextStyle(fontSize: 13)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          '최근 브리핑',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        VoiceCard(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BriefingScreen(from: [...from, '오프라인 화면']),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '네이버메일 · 3건',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                '저장된 메일 요약을 재생할 수 있어요.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              const Text(
                '최신 내용이 아닐 수 있습니다.',
                style: TextStyle(color: amber, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        VoiceCard(
          color: const Color(0xff2a1d18),
          borderColor: const Color(0xff4a3127),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '답장 발송은 대기 중',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Color(0xffff9e7a),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '연결되면 다시 확인해 주세요.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('아직 연결되지 않았어요 (목업)'))),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            foregroundColor: colors.onSurface,
            backgroundColor: colors.surfaceContainer,
            side: BorderSide(color: colors.outlineVariant),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text(
            '연결 다시 확인',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// First step of connecting: pick the mail service. Any number of accounts
/// can be linked, several per service too.
class MailProviderScreen extends StatelessWidget {
  const MailProviderScreen({
    super.key,
    required this.from,
    required this.accounts,
    required this.onAdded,
    required this.onRemoved,
  });

  final List<String> from;

  /// Linked accounts, of every service.
  final List<MailAccount> accounts;
  final Future<void> Function(MailAccount account, Unread unread) onAdded;
  final Future<void> Function(MailAccount account) onRemoved;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget provider(
      String name,
      String mark,
      Color markColor,
      String sub, {
      VoidCallback? onTap,
      bool linked = false,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: VoiceCard(
        onTap:
            onTap ??
            () => ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('$name 연동은 곧 지원할 예정이에요'))),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: markColor,
              child: Text(
                mark,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$name 연동',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap == null)
              _StatusChip('곧 지원', colors.onSurfaceVariant)
            else ...[
              _StatusChip(
                linked ? '연결됨' : '연결 안 됨',
                linked ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
    return _Page(
      trail: [...from, '메일 연동하기'],
      children: [
        const ScreenTitle('메일 연동하기', '어떤 메일을 연결할까요?'),
        const SizedBox(height: 20),
        for (final (service, color, sub) in [
          (
            MailService.naver,
            const Color(0xff03c75a),
            '아이디와 애플리케이션 비밀번호로 연결해요',
          ),
          (MailService.gmail, const Color(0xffea4335), '구글 계정으로 로그인해서 연결해요'),
        ])
          provider(
            service.label,
            service.mark,
            color,
            switch ([
              for (final a in accounts)
                if (a.service == service) a.address,
            ]) {
              [] => sub,
              final linked => '연결됨 · ${linked.join(', ')}',
            },
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MailConnectScreen(
                  from: [...from, '메일 연동하기'],
                  service: service,
                  accounts: accounts,
                  onAdded: onAdded,
                  onRemoved: onRemoved,
                ),
              ),
            ),
            linked: accounts.any((a) => a.service == service),
          ),
        provider('Outlook', 'O', const Color(0xff0078d4), '마이크로소프트 계정으로 연결해요'),
      ],
    );
  }
}

/// Signs in to one mail service over IMAP: Naver with an app password,
/// Gmail with Google sign-in. The password or token stays in the keychain.
/// Linking an address again replaces its saved login.
class MailConnectScreen extends StatefulWidget {
  const MailConnectScreen({
    super.key,
    required this.from,
    required this.service,
    required this.accounts,
    required this.onAdded,
    required this.onRemoved,
  });

  final List<String> from;
  final MailService service;

  /// Linked accounts, of every service.
  final List<MailAccount> accounts;

  /// Saves the new account and shows its unread mails.
  final Future<void> Function(MailAccount account, Unread unread) onAdded;
  final Future<void> Function(MailAccount account) onRemoved;

  @override
  State<MailConnectScreen> createState() => _MailConnectScreenState();
}

class _MailConnectScreenState extends State<MailConnectScreen> {
  final _id = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hidden = true;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    final naver = widget.service == MailService.naver;
    if (naver && (_id.text.trim().isEmpty || _password.text.isEmpty)) {
      setState(() => _error = '아이디와 비밀번호를 모두 넣어 주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = naver
          ? MailAccount(_id.text, _password.text)
          : await MailAccount.signInWithGoogle();
      // Fetching doubles as the login check.
      final unread = await account.fetchUnread();
      await widget.onAdded(account, unread);
      if (!mounted) return;
      // Back home past the provider list.
      Navigator.popUntil(context, (route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${account.address}을 연결했어요 · 안 읽은 메일 ${unread.total}건'),
        ),
      );
    } catch (error) {
      debugPrint('mail connect failed: $error');
      if (mounted) setState(() => _error = mailError(widget.service, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect(MailAccount account) async {
    await account.revoke();
    await widget.onRemoved(account);
    if (!mounted) return;
    // Back home past the provider list.
    Navigator.popUntil(context, (route) => route.isFirst);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${account.address} 연결을 해제했어요')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    InputDecoration field(String label, {String? suffix, Widget? icon}) =>
        InputDecoration(
          labelText: label,
          suffixText: suffix,
          suffixIcon: icon,
          filled: true,
          fillColor: colors.surfaceContainer,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colors.outlineVariant),
          ),
        );
    final service = widget.service;
    final linked = [
      for (final a in widget.accounts)
        if (a.service == service) a,
    ];
    final naver = service == MailService.naver;
    return _Page(
      trail: [...widget.from, service.label],
      children: [
        ScreenTitle('메일 연동하기', service.label),
        const SizedBox(height: 20),
        if (linked.isNotEmpty) ...[
          for (final account in linked) ...[
            VoiceCard(
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '연결됨',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(account.address, style: hint),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _disconnect(account),
                    child: const Text('연결 해제'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 18),
          Text('다른 계정 추가하기', style: hint),
          const SizedBox(height: 12),
        ] else if (naver) ...[
          Text(
            '네이버는 외부 앱에서 메일을 열 때 2단계 인증과 '
            '애플리케이션 비밀번호를 꼭 쓰도록 하고 있어요. '
            '처음 한 번만 아래 순서대로 설정해 주세요.',
            style: hint.copyWith(height: 1.6),
          ),
          const SizedBox(height: 14),
          _SetupStep(
            number: 1,
            title: '2단계 인증 켜고 애플리케이션 비밀번호 만들기',
            detail:
                '버튼으로 네이버 보안설정을 연 뒤\n'
                '2단계 인증의 [관리] → 비밀번호 한 번 더 입력 → '
                '애플리케이션 비밀번호 관리에서 종류를 "직접 입력"으로 고르고, '
                '이름 칸에 "Alpha Mail"을 붙여 넣어 [생성]을 눌러요.\n'
                '2단계 인증이 꺼져 있다면 먼저 켜 주세요.\n'
                '"올바르지 않은 접근"이 뜨면 naver.com에서 '
                '내 프로필 → 네이버ID → 보안설정으로 들어가 주세요.',
            action: '네이버 보안설정 열기',
            url: _naverSecurity,
            copy: 'Alpha Mail',
          ),
          const SizedBox(height: 10),
          _SetupStep(
            number: 2,
            title: 'IMAP/SMTP 사용 켜기',
            detail:
                '버튼을 누르면 네이버 메일의 IMAP 설정 화면이 바로 열려요. '
                '"IMAP/SMTP 사용"을 "사용함"으로 고르고 저장해요.',
            action: 'IMAP 설정 바로 열기',
            url: _naverMail,
          ),
          const SizedBox(height: 10),
          const _SetupStep(
            number: 3,
            title: '아래에 아이디와 애플리케이션 비밀번호 넣기',
            detail: '1번에서 만든 비밀번호를 그대로 붙여 넣어요. 평소 로그인 비밀번호로는 연결되지 않아요.',
          ),
          const SizedBox(height: 24),
        ] else ...[
          Text(
            '버튼을 누르면 구글 로그인 화면이 열려요. '
            '계정을 고르고 메일 접근을 허용하면 바로 연결돼요. '
            '앱 비밀번호나 IMAP 설정은 필요 없어요.',
            style: hint.copyWith(height: 1.6),
          ),
        ],
        if (naver)
          AutofillGroup(
            child: Column(
              children: [
                TextField(
                  controller: _id,
                  enabled: !_busy,
                  autofillHints: const [AutofillHints.username],
                  textInputAction: TextInputAction.next,
                  decoration: field('네이버 아이디', suffix: '@naver.com'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: _hidden,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _connect(),
                  decoration: field(
                    '애플리케이션 비밀번호',
                    icon: IconButton(
                      tooltip: _hidden ? '비밀번호 보기' : '비밀번호 숨기기',
                      onPressed: () => setState(() => _hidden = !_hidden),
                      icon: Icon(
                        _hidden
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_error case final error?) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: TextStyle(color: colors.error, height: 1.5),
            ),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : Text(naver ? '연결하기' : 'Google로 로그인'),
        ),
        const SizedBox(height: 14),
        Text(
          naver
              ? '비밀번호는 이 기기의 보안 저장소에만 저장돼요.\n'
                    '메일은 다른 서버를 거치지 않고 네이버와 직접 주고받아요.'
              : '구글 비밀번호는 앱이 보지 않아요. 구글이 준 접근 권한만\n'
                    '이 기기의 보안 저장소에 저장하고, 메일은 구글과 직접 주고받아요.',
          textAlign: TextAlign.center,
          style: hint.copyWith(fontSize: 13, height: 1.5),
        ),
      ],
    );
  }
}

// Both pages ask for a Naver login first, then show the setting.
// Naver ID's security tab. nid.naver.com sometimes rejects pages opened
// from outside Naver ("일시적인 오류이거나 올바르지 않은 접근"), so the step
// also spells out the route from naver.com.
final _naverSecurity = Uri.parse(
  'https://nid.naver.com/user2/help/myInfoV2?m=viewSecurity&lang=ko_KR',
);
final _naverMail = Uri.parse('https://mail.naver.com/v2/settings/smtp/imap');

/// Opens [url] in the browser; if that fails, offers the address to copy
/// so the user is never left with a button that silently does nothing.
Future<void> _open(BuildContext context, Uri url) async {
  final messenger = ScaffoldMessenger.of(context);
  var opened = false;
  try {
    opened = await launchUrl(url);
  } catch (_) {}
  if (opened) return;
  messenger.showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('브라우저를 열지 못했어요. 주소를 복사해 열어 주세요.\n$url'),
      action: SnackBarAction(
        label: '주소 복사',
        onPressed: () => Clipboard.setData(ClipboardData(text: '$url')),
      ),
    ),
  );
}

/// One numbered setup step, with a button that opens the settings page for it.
class _SetupStep extends StatelessWidget {
  const _SetupStep({
    required this.number,
    required this.title,
    required this.detail,
    this.action,
    this.url,
    this.copy,
  });

  /// Text the step asks the user to type, offered as a copy button.
  final String? copy;

  final int number;
  final String title;
  final String detail;
  final String? action;
  final Uri? url;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return VoiceCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: colors.primaryContainer,
            child: Text(
              '$number',
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
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (url != null || copy != null) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (url case final url?)
                        OutlinedButton.icon(
                          onPressed: () => _open(context, url),
                          icon: const Icon(Icons.open_in_new_rounded, size: 18),
                          label: Text(action!),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.primary,
                            side: BorderSide(
                              color: colors.primary.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      if (copy case final copy?)
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: copy));
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '"$copy"를 복사했어요. 이름 칸에 붙여 넣어 주세요.',
                                ),
                              ),
                            );
                          },
                          icon: const Icon(
                            Icons.content_copy_rounded,
                            size: 18,
                          ),
                          label: Text('"$copy" 복사'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.onSurface,
                            side: BorderSide(color: colors.outlineVariant),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pill beside a mail service: 연결됨, 연결 안 됨 or 곧 지원.
class _StatusChip extends StatelessWidget {
  const _StatusChip(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

/// Choices from 앱 설정, kept in a JSON file in the app's support folder.
class AppSettings {
  const AppSettings({this.listSize = 20, this.checkMinutes = 0});

  /// Mails per account in a mail list.
  final int listSize;

  /// How often home checks for new mail; 0 is never.
  final int checkMinutes;

  AppSettings copyWith({int? listSize, int? checkMinutes}) => AppSettings(
    listSize: listSize ?? this.listSize,
    checkMinutes: checkMinutes ?? this.checkMinutes,
  );

  static Future<File> get _file async =>
      File('${(await getApplicationSupportDirectory()).path}/settings.json');

  /// The saved settings, or the defaults if there are none yet.
  static Future<AppSettings> load() async {
    try {
      final json = jsonDecode(await (await _file).readAsString());
      return AppSettings(
        listSize: json['listSize'] as int? ?? 20,
        checkMinutes: json['checkMinutes'] as int? ?? 0,
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save() async => (await _file).writeAsString(
    jsonEncode({'listSize': listSize, 'checkMinutes': checkMinutes}),
  );
}

/// 앱 설정: linked mail accounts, how mail is fetched, and what's coming.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.from,
    required this.accounts,
    required this.settings,
    required this.onChanged,
    required this.accountsScreen,
  });

  final List<String> from;
  final List<MailAccount> accounts;
  final AppSettings settings;
  final void Function(AppSettings) onChanged;

  /// The account list to open, given its breadcrumb.
  final Widget Function(List<String> from) accountsScreen;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late var _settings = widget.settings;

  void _set(AppSettings settings) {
    setState(() => _settings = settings);
    widget.onChanged(settings);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final trail = [...widget.from, '앱 설정'];
    final hint = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    Widget row(
      String title,
      String sub,
      Widget trailing, {
      VoidCallback? onTap,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: VoiceCard(
        onTap: onTap,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(sub, style: hint),
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
          ],
        ),
      ),
    );
    Widget choices(
      int value,
      List<(int, String)> options,
      void Function(int) onPick,
    ) => SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        for (final (v, label) in options)
          ButtonSegment(value: v, label: Text(label)),
      ],
      selected: {value},
      onSelectionChanged: (picked) => onPick(picked.single),
    );
    final soon = _StatusChip('곧 지원', colors.onSurfaceVariant);
    return _Page(
      trail: trail,
      children: [
        const ScreenTitle('앱 설정', '내 메일 공간 설정'),
        heading('메일 계정'),
        row(
          '연결한 메일',
          widget.accounts.isEmpty
              ? '아직 연결한 메일이 없어요'
              : [for (final a in widget.accounts) a.address].join('\n'),
          Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => widget.accountsScreen(trail)),
          ),
        ),
        heading('메일 가져오기'),
        row(
          '새 메일 확인',
          '홈의 안 읽은 메일 수를 다시 불러와요',
          choices(_settings.checkMinutes, const [
            (0, '끄기'),
            (5, '5분'),
            (15, '15분'),
          ], (v) => _set(_settings.copyWith(checkMinutes: v))),
        ),
        row(
          '목록에 보여줄 메일',
          '계정마다 최근 몇 건까지 불러올지',
          choices(_settings.listSize, const [
            (20, '20건'),
            (50, '50건'),
            (100, '100건'),
          ], (v) => _set(_settings.copyWith(listSize: v))),
        ),
        // The phone app stands alone, so only desktop has a phone to link.
        if (isDesktop) ...[
          heading('폰 연결'),
          row('폰과 연결하기', '폰에서 말로 이 데스크탑의 메일을 듣고 답장해요', soon),
        ],
        heading('알림'),
        row('새 메일 알림', '새 메일이 오면 알려 드려요', soon),
        heading('정보'),
        row(
          '개인정보',
          '메일은 우리 서버를 거치지 않고 이 기기에서만 불러와요. '
              '비밀번호와 로그인 정보는 기기의 보안 저장소에 저장돼요.',
          const SizedBox.shrink(),
        ),
        row(
          '구글 계정 권한 관리',
          '구글에서 이 앱의 메일 접근 권한을 직접 확인하거나 해제해요',
          Icon(Icons.open_in_new_rounded, color: colors.onSurfaceVariant),
          onTap: () =>
              launchUrl(Uri.parse('https://myaccount.google.com/permissions')),
        ),
      ],
    );
  }
}
