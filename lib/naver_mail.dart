import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'screens.dart';

/// A Naver Mail account reached over IMAP (read). Since 2025 Naver only
/// accepts an app password here, which needs two-step login turned on.
class NaverMail {
  NaverMail(String id, this.password) : id = id.trim().split('@').first;

  final String id;
  final String password;

  String get address => '$id@naver.com';

  // The legacy keychain needs no keychain-sharing entitlement or
  // provisioning profile, so unsigned macOS builds can store the password.
  // accountName is the keychain service, the name macOS shows when it asks
  // to let the app read the password.
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accountName: 'Alpha Mail'),
    mOptions: MacOsOptions(
      accountName: 'Alpha Mail',
      usesDataProtectionKeychain: false,
    ),
  );

  // One keychain item for both fields: each item read can raise its own
  // macOS permission prompt, so two items meant two prompts per launch.
  static const _key = 'naver';

  /// The saved account, or null if none. Throws if the keychain refuses,
  /// e.g. when the user denies macOS's permission prompt.
  static Future<NaverMail?> load() async {
    final saved = await _storage.read(key: _key);
    if (saved == null) return null;
    final {'id': String id, 'password': String password} =
        jsonDecode(saved) as Map<String, dynamic>;
    return NaverMail(id, password);
  }

  Future<void> save() => _storage.write(
    key: _key,
    value: jsonEncode({'id': id, 'password': password}),
  );

  static Future<void> forget() => _storage.delete(key: _key);

  /// Logs in and returns the newest unread inbox mails, newest first.
  /// BODY.PEEK leaves them unread on the server.
  Future<List<Mail>> fetchUnread({int limit = 20}) async {
    final client = ImapClient();
    try {
      await client.connectToServer('imap.naver.com', 993);
      await client.login(id, password);
      await client.selectInbox();
      final unseen = (await client.searchMessages()).matchingSequence;
      if (unseen == null || unseen.isEmpty) return [];
      final ids = unseen.toList();
      final newest = ids.sublist(ids.length > limit ? ids.length - limit : 0);
      final fetched = await client.fetchMessages(
        MessageSequence.fromIds(newest),
        'BODY.PEEK[]',
      );
      return [for (final m in fetched.messages.reversed) _toMail(m)];
    } finally {
      if (client.isLoggedIn) await client.logout().catchError((_) {});
      await client.disconnect().catchError((_) {});
    }
  }

  static Mail _toMail(MimeMessage m) {
    final from = m.from?.firstOrNull;
    final text = m.decodeTextPlainPart();
    final html = m.decodeTextHtmlPart();
    return Mail(
      from?.personalName?.trim().isNotEmpty == true
          ? from!.personalName!.trim()
          : from?.email ?? '보낸 사람 없음',
      m.decodeSubject()?.trim() ?? '(제목 없음)',
      (text?.trim().isNotEmpty == true
              ? text!
              : html == null
              ? ''
              : htmlToText(html))
          .trim(),
      '',
      '답장 초안은 AI를 연결한 뒤에 만들어져요.',
      html: html == null ? null : _inlineImages(m, html),
    );
  }

  /// Swaps `cid:` image links for data URIs built from the mail's own
  /// attachments, so pictures embedded in the mail show without a server.
  static String _inlineImages(MimeMessage m, String html) =>
      html.replaceAllMapped(RegExp(r'''cid:([^"'\s>)]+)'''), (match) {
        // enough_mail compares against the raw lowercase "<id>" form.
        final part = m.getPartWithContentId('<${match[1]!.toLowerCase()}>');
        final bytes = part?.decodeContentBinary();
        if (bytes == null) return match[0]!;
        final type = part!.mediaType.text;
        return 'data:$type;base64,${base64Encode(bytes)}';
      });
}

/// Plain Korean message for a failed connect, for the connect screen.
String naverMailError(Object error) => switch (error) {
  SocketException() || TimeoutException() => '인터넷 연결을 확인해 주세요.',
  ImapException() =>
    '로그인하지 못했어요. 평소 비밀번호가 아니라 애플리케이션 비밀번호를 넣었는지, '
        '네이버 메일에서 IMAP/SMTP 사용을 켰는지 확인해 주세요.',
  _ => '네이버메일에 연결하지 못했어요. 잠시 후 다시 시도해 주세요.',
};

// ponytail: regex HTML stripping, enough to read a mail aloud; tables and
// inline layout flatten into lines. Swap in an HTML parser if text garbles.
String htmlToText(String html) => html
    .replaceAll(
      RegExp(
        r'<(style|script|head)[^>]*>.*?</\1>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    )
    .replaceAll(
      RegExp(r'<br\s*/?>|</(p|div|tr|li|h\d)>', caseSensitive: false),
      '\n',
    )
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n')
    .trim();
