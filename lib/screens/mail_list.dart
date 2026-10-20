import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../mail/mail.dart';
import '../mail/mail_account.dart';
import '../voice/speech.dart';
import '../widgets.dart';
import 'compose.dart';
import 'mail_view.dart';
import 'settings.dart';

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
    this.speech,
  });

  /// The recogniser, for replying and writing by voice; null hides the mic.
  final Recognizer? speech;

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

  /// Opens 메일 작성; [byVoice] starts with dictating the body.
  void _write({bool byVoice = false}) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ComposeScreen(
        from: [...widget.from, widget.folder.label],
        accounts: widget.accounts,
        account: widget.accounts.where((a) => a.address == _only).firstOrNull,
        speech: widget.speech,
        byVoice: byVoice,
        // Everyone in the list, so a recipient can be named aloud.
        contacts: {
          for (final m in _list.reversed)
            if (m.address.isNotEmpty)
              m.from.replaceAll(RegExp(r'에게$'), ''): m.address,
        },
      ),
    ),
  );

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

  /// The service name ("Gmail"), or the address when two accounts share it.
  String _name(MailAccount a) =>
      widget.accounts.where((b) => b.service == a.service).length > 1
      ? a.address
      : a.service.label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hint = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final accounts = widget.accounts;
    final mails = _list;
    final unread = widget.folder == MailFolder.unread;
    return AppPage(
      trail: [...widget.from, widget.folder.label],
      floating: WritePill(
        '메일 작성',
        onWrite: _write,
        onVoice: widget.speech?.loaded == true
            ? () => _write(byVoice: true)
            : null,
      ),
      children: [
        ScreenTitle(switch (accounts) {
          [] => '예시 메일',
          [final single] => single.service.label,
          _ when _only != null => _name(
            accounts.firstWhere((a) => a.address == _only),
          ),
          _ => '메일 ${accounts.length}개 계정',
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
                    for (final a in [null, ...accounts])
                      ChoiceChip(
                        // The service's badge says which account; a tick
                        // would only repeat the chip's selected fill.
                        showCheckmark: false,
                        avatar: a == null
                            ? null
                            : CircleAvatar(
                                backgroundColor: a.service.color,
                                child: Text(
                                  a.service.mark,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                        label: Text(a == null ? '전체 계정' : _name(a)),
                        selected: _only == a?.address,
                        onSelected: (_) => setState(() => _only = a?.address),
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
                  speech: widget.speech,
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
        // Room so the last mail can scroll out from under the write pill.
        const SizedBox(height: 104),
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
    final ago = now.difference(d);
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (ago.inMinutes < 1) return '방금';
    if (ago.inHours < 1) return '${ago.inMinutes}분 전';
    if (days == 0) return '${ago.inHours}시간 전';
    if (days == 1) return '어제';
    if (days < 7) return '$days일 전';
    return d.year == now.year
        ? '${d.month}/${d.day}'
        : '${d.year}/${d.month}/${d.day}';
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
