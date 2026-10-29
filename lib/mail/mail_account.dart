import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:cp949_codec/cp949_codec.dart' show cp949;
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'mail.dart';

/// Mail services the app can read over IMAP. Naver takes an app password,
/// which needs two-step login turned on; Gmail and Outlook take OAuth.
enum MailService {
  naver('네이버 메일', 'N', Color(0xff03c75a), 'imap.naver.com', 'smtp.naver.com'),
  // Gmail keeps IMAP always on since 2025, so there is no setting to flip.
  gmail('Gmail', 'G', Color(0xffea4335), 'imap.gmail.com', 'smtp.gmail.com'),
  // Outlook.com and Microsoft 365 alike; its SMTP only takes STARTTLS on 587.
  outlook(
    'Outlook',
    'O',
    Color(0xff0078d4),
    'outlook.office365.com',
    'smtp-mail.outlook.com',
  );

  const MailService(this.label, this.mark, this.color, this.host, this.smtp);

  final String label;

  /// One-letter badge shown beside the service name.
  final String mark;

  /// Brand colour behind [mark].
  final Color color;
  final String host;

  /// Server mail is sent through, over SSL on port 465 (Outlook: 587).
  final String smtp;

  bool get usesOAuth => this != naver;
}

// iOS-type OAuth client from Google Cloud Console, used on every platform:
// its reversed ID is the redirect scheme, also set in both Info.plists and
// android/app/build.gradle.kts. Not a secret; installed apps use PKCE.
const googleClientId =
    '452100579076-7eh0ik6r8f41cp5pmvh770b0ke2q7ju1.apps.googleusercontent.com';
final _googleRedirect =
    '${googleClientId.split('.').reversed.join('.')}:/oauthredirect';
const _google = AuthorizationServiceConfiguration(
  authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
  tokenEndpoint: 'https://oauth2.googleapis.com/token',
);
// Full mail access is the only scope IMAP accepts.
const _googleScopes = ['openid', 'email', 'https://mail.google.com/'];

// Public client from an Azure app registration ("Mobile and desktop" platform,
// redirect URI below, any Microsoft account). Not a secret; PKCE.
const microsoftClientId = '5c79bf64-561f-4ca2-9f46-2921564f683b';
// Also set in ios/Runner/Info.plist and the RedirectUriReceiverActivity
// intent filter in android/app/src/main/AndroidManifest.xml.
const _microsoftRedirect = 'com.applegend.alphamail://oauthredirect';
const _microsoft = AuthorizationServiceConfiguration(
  authorizationEndpoint:
      'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
  tokenEndpoint: 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
);
const _microsoftScopes = [
  'openid',
  'email',
  'offline_access',
  'https://outlook.office.com/IMAP.AccessAsUser.All',
  'https://outlook.office.com/SMTP.Send',
];
const _appAuth = FlutterAppAuth();

/// Client ID, redirect, endpoints and scopes for an OAuth service.
(String, String, AuthorizationServiceConfiguration, List<String>) _oauth(
  MailService service,
) => service == MailService.outlook
    ? (microsoftClientId, _microsoftRedirect, _microsoft, _microsoftScopes)
    : (googleClientId, _googleRedirect, _google, _googleScopes);

/// An inbox's unread count and the newest of those mails.
typedef Unread = ({int total, List<Mail> mails});

/// A mail account reached over IMAP (read).
class MailAccount {
  /// A Naver account and its app password.
  MailAccount(String id, String password)
    : service = MailService.naver,
      address = '${id.trim().split('@').first}@naver.com',
      secret = password.trim();

  /// A Gmail account and the refresh token Google sign-in gave it.
  MailAccount.google(this.address, this.secret) : service = MailService.gmail;

  /// An Outlook account and the refresh token Microsoft sign-in gave it.
  MailAccount.outlook(this.address, this.secret)
    : service = MailService.outlook;

  final MailService service;

  /// Full address, also the Gmail login. Any domain for Gmail (Workspace).
  final String address;

  /// Naver's app password, or the OAuth refresh token. Microsoft hands out
  /// a new refresh token on each use, so this can change ([onRenewed]).
  String secret;

  /// Called after [secret] changes, to save the new one.
  static void Function()? onRenewed;

  String get id => address.split('@').first;

  /// Opens Google's or Microsoft's sign-in page and returns the account it
  /// granted. Throws [FlutterAppAuthUserCancelledException] if the user
  /// backs out.
  static Future<MailAccount> signIn(MailService service) async {
    final (clientId, redirect, config, scopes) = _oauth(service);
    if (clientId.isEmpty) throw StateError('no $service client ID');
    final result = await _appAuth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        clientId,
        redirect,
        serviceConfiguration: config,
        scopes: scopes,
        // Always show the account picker, so switching accounts works.
        promptValues: ['select_account'],
      ),
    );
    // The ID token came straight from the provider over TLS, so its payload
    // can be read without checking the signature.
    final payload = result.idToken!.split('.')[1];
    final claims =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))))
            as Map<String, dynamic>;
    // Personal Microsoft accounts may leave out email; the login name is
    // the address then.
    final email = (claims['email'] ?? claims['preferred_username']) as String;
    return service == MailService.outlook
        ? MailAccount.outlook(email, result.refreshToken!)
        : MailAccount.google(email, result.refreshToken!);
  }

  /// Trades the refresh token for a fresh hour-long access token.
  Future<String> _accessToken() async {
    final (clientId, redirect, config, scopes) = _oauth(service);
    final token = await _appAuth
        .token(
          TokenRequest(
            clientId,
            redirect,
            serviceConfiguration: config,
            refreshToken: secret,
            // Microsoft wants the scopes again on refresh.
            scopes: service == MailService.outlook ? scopes : null,
          ),
        )
        // Seen to never answer after the app was started on a locked phone.
        .timeout(const Duration(seconds: 20));
    if (token.refreshToken case final renewed? when renewed != secret) {
      secret = renewed;
      onRenewed?.call();
    }
    return token.accessToken!;
  }

  /// Logs in to the IMAP server.
  Future<void> _login(ImapClient client) async {
    switch (service) {
      case MailService.naver:
        await client.login(id, secret);
      case MailService.gmail || MailService.outlook:
        await client.authenticateWithOAuth2(address, await _accessToken());
    }
  }

  /// Sends a plain-text mail from this account. With [replyTo] it threads
  /// under that mail in the recipient's mail app.
  // ponytail: Gmail files sent mail in 보낸 메일 itself; if Naver doesn't,
  // append the message to its sent folder over IMAP.
  Future<void> send({
    required String to,
    required String subject,
    required String text,
    Mail? replyTo,
  }) async {
    final builder = MessageBuilder()
      ..from = [MailAddress(null, address)]
      ..to = [MailAddress(null, to)]
      ..subject = subject
      ..text = text;
    if (replyTo?.messageId case final id?) {
      builder
        ..setHeader('In-Reply-To', id)
        ..setHeader('References', id);
    }
    final client = SmtpClient(service.smtp);
    Future<void> deliver() async {
      final ssl = service != MailService.outlook;
      await client.connectToServer(
        service.smtp,
        ssl ? 465 : 587,
        isSecure: ssl,
      );
      await client.ehlo();
      if (!ssl) await client.startTls();
      switch (service) {
        case MailService.naver:
          await client.authenticate(id, secret, AuthMechanism.login);
        case MailService.gmail || MailService.outlook:
          await client.authenticate(
            address,
            await _accessToken(),
            AuthMechanism.xoauth2,
          );
      }
      await client.sendMessage(
        builder.buildMimeMessage(),
        use8BitEncoding: true,
      );
    }

    try {
      // SmtpClient has no response timeout of its own; a silent server
      // would leave 보내는 중 forever.
      await deliver().timeout(const Duration(minutes: 1));
    } finally {
      await client.quit().catchError((_) => SmtpResponse(const []));
      await client.disconnect().catchError((_) {});
    }
  }

  /// Tells Google to drop the app's access. Best effort: the user can also
  /// remove it at myaccount.google.com/permissions. Microsoft has no revoke
  /// endpoint for one token; account.live.com/consent/Manage removes it.
  Future<void> revoke() async {
    if (service != MailService.gmail) return;
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.https('oauth2.googleapis.com', '/revoke', {'token': secret}),
      );
      await (await request.close()).drain<void>();
    } catch (_) {
    } finally {
      client.close();
    }
  }

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

  // One keychain item for every account: each item read can raise its own
  // macOS permission prompt, so one item per account meant one prompt each.
  // Named before Gmail existed; kept so saved Naver accounts still load.
  static const _key = 'naver';

  /// The saved accounts, oldest first. Throws if the keychain refuses,
  /// e.g. when the user denies macOS's permission prompt.
  static Future<List<MailAccount>> loadAll() async {
    final saved = await _storage.read(key: _key);
    if (saved == null) return [];
    return switch (jsonDecode(saved)) {
      final List<dynamic> list => [...list.map(fromJson).nonNulls],
      // Saved when only one account could be linked.
      final single => [?fromJson(single)],
    };
  }

  static MailAccount? fromJson(dynamic json) => switch (json) {
    {'service': 'gmail', 'address': String address, 'secret': String token} =>
      MailAccount.google(address, token),
    {'service': 'outlook', 'address': String address, 'secret': String token} =>
      MailAccount.outlook(address, token),
    {'address': String address, 'secret': String password} => MailAccount(
      address,
      password,
    ),
    // Saved before Gmail existed.
    {'id': String id, 'password': String password} => MailAccount(id, password),
    _ => null,
  };

  static Future<void> saveAll(List<MailAccount> accounts) => accounts.isEmpty
      ? _storage.delete(key: _key)
      : _storage.write(
          key: _key,
          value: jsonEncode([
            for (final a in accounts)
              {
                'service': a.service.name,
                'address': a.address,
                'secret': a.secret,
              },
          ]),
        );

  /// Logs in, opens the inbox (or the sent or trash [folder]) and runs
  /// [body], logging out after.
  // ponytail: a fresh IMAP login per call; keep one connection open if
  // reading many mails in a row gets slow.
  Future<T> _inInbox<T>(
    Future<T> Function(ImapClient client, Mailbox inbox) body, {
    MailFolder folder = MailFolder.all,
  }) async {
    // Without a limit a server that stops answering left the app loading
    // forever; long enough for 20 whole mails with attachments.
    final client = ImapClient(
      defaultResponseTimeout: const Duration(minutes: 2),
    );
    try {
      await client.connectToServer(service.host, 993);
      try {
        await _login(client);
      } on SocketException catch (e) {
        // The server was reached, so a dropped line here is it refusing
        // the login (Outlook hangs up when IMAP access isn't granted), not
        // the phone being offline.
        throw ImapException(client, 'login: $e');
      } on TimeoutException catch (e) {
        throw ImapException(client, 'login: $e');
      }
      final box = switch (folder) {
        MailFolder.sent => await client.selectMailbox(
          await _box(client, (b) => b.isSent, 'sent|보낸'),
        ),
        MailFolder.trash => await client.selectMailbox(
          await _box(client, (b) => b.isTrash, 'trash|deleted|휴지통'),
        ),
        _ => await client.selectInbox(),
      };
      return await body(client, box);
    } finally {
      if (client.isLoggedIn) await client.logout().catchError((_) {});
      await client.disconnect().catchError((_) {});
    }
  }

  /// Logs in and returns how many inbox mails are unread, with the newest
  /// [limit] of them, newest first. BODY.PEEK leaves them unread. With
  /// [before], only unread mails older than that UID count (더 보기).
  Future<Unread> fetchUnread({int limit = 20, int? before}) =>
      _inInbox((client, _) => _newest(client, 'UNSEEN', limit, before: before));

  /// Marks one mail read on the server, as opening it in a mail app would.
  Future<void> markSeen(int uid) => _inInbox(
    (client, _) => client.uidMarkSeen(MessageSequence.fromId(uid, isUid: true)),
  );

  /// Starred inbox mails (\\Flagged: Gmail's star, Naver's 중요 메일), like
  /// [fetchUnread].
  // shortcut: inbox only; Gmail stars in other labels are missed, search
  // [Gmail]/All Mail if users ask for them.
  Future<Unread> fetchStarred({int limit = 20, int? before}) => _inInbox(
    (client, _) => _newest(client, 'FLAGGED', limit, before: before),
  );

  /// The newest [limit] mails of the inbox (or the sent or trash [folder]),
  /// read or not, newest first; with [before], the ones older than that UID
  /// (더 보기).
  Future<List<Mail>> fetchRecent({
    int limit = 20,
    MailFolder folder = MailFolder.all,
    int? before,
  }) => _inInbox(folder: folder, (client, box) async {
    if (box.messagesExists == 0) return <Mail>[];
    if (before != null) {
      return (await _newest(
        client,
        'ALL',
        limit,
        before: before,
        folder: folder,
      )).mails;
    }
    final sized = await client.fetchRecentMessages(
      messageCount: limit,
      criteria: '(UID RFC822.SIZE)',
    );
    return _forList(client, sized.messages, folder);
  });

  /// [mail] whole, with the HTML and attachments a list leaves out.
  Future<Mail> fetchWhole(Mail mail) =>
      _inInbox(folder: mail.folder, (client, _) async {
        final fetched = await client.uidFetchMessage(
          mail.uid!,
          '(UID FLAGS BODY.PEEK[])',
        );
        return _toMail(fetched.messages.single, folder: mail.folder);
      });

  /// How many mails match [criteria] (below UID [before], when given), with
  /// the newest [limit] fetched whole, newest first.
  Future<Unread> _newest(
    ImapClient client,
    String criteria,
    int limit, {
    int? before,
    MailFolder folder = MailFolder.all,
  }) async {
    if (before != null) {
      // Nothing is older than UID 1, and "UID 1:0" is not a valid range.
      if (before <= 1) return (total: 0, mails: <Mail>[]);
      criteria = '$criteria UID 1:${before - 1}';
    }
    // UIDs stay valid across connections, so a mail can be marked read
    // later, and 더 보기 can ask for what's older than one; plain sequence
    // numbers shift as mail comes and goes.
    final ids = [
      ...?(await client.uidSearchMessages(
        searchCriteria: criteria,
      )).matchingSequence?.toList(),
    ]..sort();
    if (ids.isEmpty) return (total: 0, mails: <Mail>[]);
    final newest = ids.sublist(ids.length > limit ? ids.length - limit : 0);
    final sized = await client.uidFetchMessages(
      MessageSequence.fromIds(newest, isUid: true),
      '(UID RFC822.SIZE)',
    );
    return (
      total: ids.length,
      mails: await _forList(client, sized.messages, folder),
    );
  }

  /// Mails up to this size come whole; bigger ones carry attachments,
  /// which took most of a list's loading time.
  static const _wholeLimit = 100 * 1024;

  /// The [sized] mails (UID and size fetched) for a list, newest first:
  /// small ones whole, big ones with only their text, to fetch whole when
  /// opened ([fetchWhole]).
  Future<List<Mail>> _forList(
    ImapClient client,
    List<MimeMessage> sized,
    MailFolder folder,
  ) async {
    Future<List<MimeMessage>> fetch(bool big, String what) async {
      final uids = [
        for (final m in sized)
          if ((m.size ?? 0) > _wholeLimit == big) m.uid!,
      ];
      if (uids.isEmpty) return [];
      return (await client.uidFetchMessages(
        MessageSequence.fromIds(uids, isUid: true),
        what,
      )).messages;
    }

    final mails = [
      for (final m in await fetch(false, '(UID FLAGS BODY.PEEK[])'))
        _toMail(m, folder: folder),
    ];
    for (final m in await fetch(
      true,
      '(UID FLAGS BODYSTRUCTURE BODY.PEEK[HEADER])',
    )) {
      final text =
          m.body?.findFirst(MediaSubtype.textPlain) ??
          m.body?.findFirst(MediaSubtype.textHtml);
      String? body;
      // shortcut: a big mail that is one part (no fetch ID) shows no
      // preview until opened.
      if (text?.fetchId case final id?) {
        final fetched = await client.uidFetchMessage(
          m.uid!,
          '(BODY.PEEK[$id])',
        );
        if (fetched.messages.firstOrNull?.getPart(id) case final part?) {
          m.setPart(id, part);
          body = _asKorean(part) ?? part.decodeContentText();
          if (text!.contentType?.mediaType.sub == MediaSubtype.textHtml) {
            body = htmlToText(body ?? '');
          }
        }
      }
      mails.add(_toMail(m, folder: folder, preview: body ?? ''));
    }
    return mails..sort((a, b) => b.uid!.compareTo(a.uid!));
  }

  /// A special folder: flagged (\Sent, \Trash) where the server supports
  /// that (Gmail), else found by [name] ("Sent Messages" on Naver).
  static Future<Mailbox> _box(
    ImapClient client,
    bool Function(Mailbox) flagged,
    String name,
  ) async {
    final boxes = await client.listMailboxes(recursive: true);
    final byName = RegExp(name, caseSensitive: false);
    return boxes.where(flagged).firstOrNull ??
        boxes.firstWhere((b) => byName.hasMatch(b.name));
  }

  /// Sent mails show who they went to in place of the sender.
  /// With [preview], [m] has only its headers and that is its text.
  Mail _toMail(
    MimeMessage m, {
    MailFolder folder = MailFolder.all,
    String? preview,
  }) {
    final sent = folder == MailFolder.sent;
    final from = (sent ? m.to : m.from)?.firstOrNull;
    final text = preview ?? koreanText(m, MediaSubtype.textPlain);
    final html = preview != null ? null : koreanText(m, MediaSubtype.textHtml);
    final name = from?.personalName?.trim().isNotEmpty == true
        ? koreanHeader(from!.personalName!.trim())
        : from?.email;
    return Mail(
      sent ? '${name ?? '받는 사람 없음'}에게' : name ?? '보낸 사람 없음',
      koreanHeader(m.decodeSubject()?.trim() ?? '(제목 없음)'),
      (text?.trim().isNotEmpty == true
              ? text!
              : html == null
              ? ''
              : htmlToText(html))
          .trim(),
      '',
      // No AI drafts yet, so a reply starts empty.
      '',
      address: (sent ? from : m.replyTo?.firstOrNull ?? from)?.email ?? '',
      html: html == null ? null : _inlineImages(m, html),
      source: service.label,
      date: m.decodeDate(),
      account: this,
      uid: m.uid,
      // Never mark sent mail read; it is the user's own. Trash UIDs aren't
      // the inbox's, where marking read goes.
      seen: sent || folder == MailFolder.trash || m.isSeen,
      messageId: m.getHeaderValue('message-id')?.trim(),
      partial: preview != null,
      folder: folder,
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
String mailError(MailService service, Object error) => switch (error) {
  // Codes are explained in screens/help.dart.
  SocketException() || TimeoutException() => '인터넷 연결을 확인해 주세요. (C-01)',
  FlutterAppAuthUserCancelledException() => switch (service) {
    MailService.outlook => '마이크로소프트 로그인을 취소했어요.',
    _ => '구글 로그인을 취소했어요.',
  },
  StateError() when service == MailService.outlook =>
    '아직 Outlook 연동을 준비 중이에요. 앱에 마이크로소프트 앱 등록이 필요해요.',
  ImapException() ||
  SmtpException() ||
  FlutterAppAuthPlatformException() => switch (service) {
    MailService.naver => '네이버 로그인에 실패했어요. (L-01)',
    MailService.gmail => '구글 로그인에 실패했어요. (L-02)',
    MailService.outlook => '마이크로소프트 로그인에 실패했어요. (L-03)',
  },
  _ => '${service.label}에 연결하지 못했어요. (C-02)',
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

// enough_mail has no EUC-KR, which Korean mail (CP949, its superset, under
// several names) still often uses: it leaves those headers encoded and
// reads those bodies as broken UTF-8.
const _koreanCharsets = {'euc-kr', 'ks_c_5601-1987', 'ks_c_5601', 'cp949'};

final _koreanWords = RegExp(
  r'(?:=\?(?:euc-kr|ks_c_5601-1987|ks_c_5601|cp949)\?[bq]\?[^?]*\?=\s*)+',
  caseSensitive: false,
);
final _koreanWord = RegExp(r'\?([bq])\?([^?]*)\?=', caseSensitive: false);

/// Decodes the EUC-KR encoded words enough_mail left in a header. A run of
/// words is decoded as one, since mailers split a character across words.
String koreanHeader(String header) =>
    header.replaceAllMapped(_koreanWords, (run) {
      final bytes = <int>[
        for (final w in _koreanWord.allMatches(run[0]!))
          ...w[1]!.toLowerCase() == 'b'
              ? base64.decode(base64.normalize(w[2]!))
              : _quotedBytes(w[2]!.replaceAll('_', ' ')),
      ];
      final trailing = run[0]!.endsWith(' ') ? ' ' : '';
      return cp949.decode(bytes) + trailing;
    });

/// The text/plain or text/html body, read as EUC-KR when it is declared so.
String? koreanText(MimeMessage m, MediaSubtype subtype) {
  final part = _findPart(m, subtype);
  return (part == null ? null : _asKorean(part)) ??
      (subtype == MediaSubtype.textPlain
          ? m.decodeTextPlainPart()
          : m.decodeTextHtmlPart());
}

/// [part]'s text if it is declared EUC-KR, which enough_mail misreads.
String? _asKorean(MimePart part) {
  final charset = part.getHeaderContentType()?.charset?.toLowerCase();
  if (!_koreanCharsets.contains(charset)) return null;
  final encoding = part
      .getHeaderValue('content-transfer-encoding')
      ?.trim()
      .toLowerCase();
  final bytes = encoding == 'quoted-printable'
      ? _quotedBytes(part.mimeData?.decodeText(null, null) ?? '')
      : part.decodeContentBinary();
  return bytes == null ? null : cp949.decode(bytes);
}

/// The part [MimePart.decodeTextPlainPart] reads: the first one, depth first.
MimePart? _findPart(MimePart part, MediaSubtype subtype) {
  if (part.mediaType.sub == subtype) return part;
  for (final child in part.parts ?? const <MimePart>[]) {
    if (_findPart(child, subtype) case final found?) return found;
  }
  return null;
}

/// Quoted-printable to bytes: `=XX` is a byte, `=` at a line end joins lines.
List<int> _quotedBytes(String text) {
  final bytes = <int>[];
  final s = text.replaceAll(RegExp(r'=\r?\n'), '');
  for (var i = 0; i < s.length; i++) {
    final hex = s[i] == '=' && i + 2 < s.length
        ? int.tryParse(s.substring(i + 1, i + 3), radix: 16)
        : null;
    if (hex != null) {
      bytes.add(hex);
      i += 2;
    } else {
      bytes.addAll(utf8.encode(s[i]));
    }
  }
  return bytes;
}
