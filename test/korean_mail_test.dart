import 'dart:convert';

import 'package:alpha_mail/mail/mail_account.dart';
import 'package:cp949_codec/cp949_codec.dart' show cp949;
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final b64 = base64.encode(cp949.encode('안녕하세요 메일'));

  test('the codec reads standard EUC-KR bytes', () {
    // 안 = BE C8, 녕 = B3 E7 in EUC-KR.
    expect(cp949.decode([0xBE, 0xC8, 0xB3, 0xE7, 0x20, 0x41]), '안녕 A');
  });

  test('EUC-KR encoded words in a header are decoded', () {
    expect(koreanHeader('=?EUC-KR?B?$b64?='), '안녕하세요 메일');
    // A character split across two words still decodes.
    final bytes = cp949.encode('한글');
    final a = base64.encode(bytes.sublist(0, 3));
    final b = base64.encode(bytes.sublist(3));
    expect(koreanHeader('[공지] =?euc-kr?B?$a?= =?euc-kr?B?$b?= 끝'), '[공지] 한글 끝');
    expect(koreanHeader('=?ks_c_5601-1987?Q?=C7=D1_A?='), '한 A');
    expect(koreanHeader('그냥 제목'), '그냥 제목');
  });

  test('an EUC-KR body is read as Korean', () {
    final m = MimeMessage.parseFromText(
      'Subject: =?EUC-KR?B?$b64?=\r\n'
      'Content-Type: text/plain; charset="euc-kr"\r\n'
      'Content-Transfer-Encoding: base64\r\n'
      '\r\n'
      '$b64\r\n',
    );
    expect(koreanHeader(m.decodeSubject()!), '안녕하세요 메일');
    expect(koreanText(m, MediaSubtype.textPlain), '안녕하세요 메일');
  });
}
