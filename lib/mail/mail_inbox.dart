import 'dart:async';

import 'package:flutter/foundation.dart';

import 'mail.dart';
import 'mail_account.dart';
import '../widgets.dart';

/// Linked mail accounts, and each one's unread mails or load error by
/// address; mock mails until one is linked.
class MailInbox extends ChangeNotifier with SafeNotifier {
  List<MailAccount> accounts = const [];
  final Map<String, List<Mail>> unread = {};
  final Map<String, int> unreadTotal = {};
  final Map<String, String> errors = {};
  Timer? _checker;

  /// Unread mails of every account, newest first. Sorted once per change,
  /// not on every rebuild.
  List<Mail> get mails => _mails ??= accounts.isEmpty
      ? mockMails
      : ([for (final a in accounts) ...?unread[a.address]]..sort(
          (a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)),
        ));
  List<Mail>? _mails;

  // Every change notifies, so this is where the sorted list goes stale.
  @override
  void notifyListeners() {
    _mails = null;
    super.notifyListeners();
  }

  String? get error => errors.isEmpty ? null : errors.values.join('\n');

  /// Still fetching some account, with nothing failed or loaded for it.
  bool get loading => accounts.any(
    (a) => unread[a.address] == null && errors[a.address] == null,
  );

  String get source => switch (accounts) {
    [] => '예시 메일',
    [final only] => only.service.label,
    _ => '메일 ${accounts.length}개 계정',
  };

  /// Throws when the saved accounts can't be read.
  Future<void> load() async {
    accounts = await MailAccount.loadAll();
    notifyListeners();
    await refresh();
  }

  /// Fetches every account again, for 아래로 당겨 새로고침.
  Future<void> refresh() => Future.wait(accounts.map(fetch));

  Future<void> fetch(MailAccount account) async {
    Unread? mails;
    Object? failure;
    try {
      mails = await account.fetchUnread();
    } catch (error) {
      failure = error;
    }
    // Removed while fetching: don't bring its mail or error back.
    if (!accounts.any((a) => a.address == account.address)) return;
    if (mails != null) {
      _setUnread(account, mails);
    } else {
      errors[account.address] =
          '${account.address}: ${mailError(account.service, failure!)}';
    }
    notifyListeners();
  }

  void _setUnread(MailAccount account, Unread mails) {
    unread[account.address] = mails.mails;
    unreadTotal[account.address] = mails.total;
    errors.remove(account.address);
  }

  /// Fetches again each account that failed. The check interval defaults to
  /// never, so a failed launch fetch otherwise stayed failed for good.
  void retryFailed() {
    for (final account in accounts) {
      if (errors.remove(account.address) != null) fetch(account);
    }
    notifyListeners();
  }

  /// Re-fetches every account's unread count every [minutes]; 0 stops.
  void checkEvery(int minutes) {
    _checker?.cancel();
    _checker = minutes == 0
        ? null
        : Timer.periodic(Duration(minutes: minutes), (_) {
            for (final account in accounts) {
              fetch(account);
            }
          });
  }

  /// Drops a mail just marked read from its account's unread list.
  void markRead(Mail mail) {
    final address = mail.account?.address;
    if (address == null) return;
    final mails = unread[address];
    // Opened twice: already counted. Matched by UID, since 전체 메일
    // fetches its own copy of the same mail.
    if (mails == null || !mails.any((m) => m.uid == mail.uid)) return;
    // A new list: the open screens still page through the old one.
    unread[address] = [
      for (final m in mails)
        if (m.uid != mail.uid) m,
    ];
    unreadTotal.update(address, (n) => n - 1);
    notifyListeners();
  }

  void allRead(MailAccount account) {
    unread[account.address] = [];
    unreadTotal[account.address] = 0;
    notifyListeners();
  }

  Future<void> add(MailAccount account, Unread mails) async {
    final next = [
      for (final a in accounts)
        if (a.address != account.address) a,
      account,
    ];
    await MailAccount.saveAll(next);
    accounts = next;
    _setUnread(account, mails);
    notifyListeners();
  }

  Future<void> remove(MailAccount account) async {
    final next = [
      for (final a in accounts)
        if (a.address != account.address) a,
    ];
    await MailAccount.saveAll(next);
    accounts = next;
    unread.remove(account.address);
    unreadTotal.remove(account.address);
    errors.remove(account.address);
    notifyListeners();
  }

  @override
  void dispose() {
    _checker?.cancel();
    super.dispose();
  }
}
