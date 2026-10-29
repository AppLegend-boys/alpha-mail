import 'dart:io';
import 'dart:typed_data';

import 'package:alpha_mail/voice/speech.dart';
import 'package:alpha_mail/mail/mail_account.dart';
import 'package:alpha_mail/screens/compose.dart';
import 'package:alpha_mail/screens/help.dart';
import 'package:alpha_mail/screens/mail_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pcm16ToFloat32 decodes little-endian samples to [-1, 1)', () {
    // 0, +1, -1, max, min as little-endian int16 pairs.
    final bytes = Uint8List.fromList([
      0x00, 0x00, // 0
      0x01, 0x00, // 1
      0xff, 0xff, // -1
      0xff, 0x7f, // 32767
      0x00, 0x80, // -32768
    ]);
    final samples = pcm16ToFloat32(bytes);

    expect(samples.length, 5);
    expect(samples[0], 0.0);
    expect(samples[1], closeTo(1 / 32768, 1e-9));
    expect(samples[2], closeTo(-1 / 32768, 1e-9));
    expect(samples[3], closeTo(32767 / 32768, 1e-6));
    expect(samples[4], -1.0);
  });

  test('pcm16ToFloat32 ignores a trailing odd byte', () {
    expect(pcm16ToFloat32(Uint8List.fromList([0x00, 0x00, 0x11])).length, 1);
  });

  test('model tasks keep subfolders and one group per model', () {
    final qwen = {for (final t in SpeechModel.qwen3.tasks) t.metaData: t};
    expect(qwen['decoder.int8.onnx']!.directory, 'models/qwen3');
    expect(qwen['tokenizer/vocab.json']!.directory, 'models/qwen3/tokenizer');
    expect(qwen['tokenizer/vocab.json']!.filename, 'vocab.json');
    for (final model in SpeechModel.values) {
      expect(model.tasks.length, model.files.length);
      expect(model.tasks.every((t) => t.group == model.name), isTrue);
      expect(SpeechModel.forGroup(model.name), model);
    }
  });

  test('only a clear yes sends a mail by voice', () {
    expect(sendAnswer('보내'), SendAnswer.yes);
    expect(sendAnswer('응 보내 줘'), SendAnswer.yes);
    expect(sendAnswer('네.'), SendAnswer.yes);
    expect(sendAnswer('보내지 마'), SendAnswer.no);
    expect(sendAnswer('아니요'), SendAnswer.no);
    expect(sendAnswer('취소해 줘'), SendAnswer.no);
    expect(sendAnswer('다시 할게'), SendAnswer.again);
    // "네" inside other words is chatter, not an answer.
    expect(sendAnswer('네 그런데 잠깐만'), SendAnswer.unclear);
    expect(sendAnswer('음'), SendAnswer.unclear);
  });

  test('only a bare "다음" skips to the next mail', () {
    expect(isSkipCommand('다음'), isTrue);
    expect(isSkipCommand('다음.'), isTrue);
    expect(isSkipCommand('다음 거'), isTrue);
    expect(isSkipCommand('넘겨 줘'), isTrue);
    // The app's own voice or mail text read aloud.
    expect(isSkipCommand('다음 주 월요일까지 제출해 주세요'), isFalse);
    expect(isSkipCommand('다음 메일입니다'), isFalse);
  });

  test('a recipient can be named or spelled aloud', () {
    const contacts = {'허재혁': 'jh@manyfast.io', '토스뱅크': 'no-reply@toss.im'};
    expect(findRecipient('허재혁 님에게요.', contacts), 'jh@manyfast.io');
    expect(findRecipient('재혁', contacts), 'jh@manyfast.io');
    expect(findRecipient('minji 골뱅이 네이버 닷 컴', contacts), 'minji@naver.com');
    expect(
      findRecipient('gunwoo405@gmail.com.', contacts),
      'gunwoo405@gmail.com',
    );
    expect(findRecipient('김철수', contacts), isNull);
    expect(findRecipient('어', contacts), isNull);
    // To oneself: the account the mail goes from.
    const me = 'gunwoo405@naver.com';
    expect(findRecipient('나한테', contacts, me: me), me);
    expect(findRecipient('내게요.', contacts, me: me), me);
    expect(findRecipient('나에게', contacts, me: me), me);
    expect(findRecipient('나한테', contacts), isNull);
  });

  test('htmlToText keeps line breaks and drops markup', () {
    const html =
        '<html><head><style>p{color:red}</style></head><body>'
        '<p>안녕하세요&nbsp;김서연입니다.</p><div>견적서 &amp; 일정</div>'
        'A&lt;B<br>끝</body></html>';
    expect(htmlToText(html), '안녕하세요 김서연입니다.\n견적서 & 일정\nA<B\n끝');
  });

  test('MailAccount keeps only the ID part of a Naver address', () {
    expect(MailAccount(' minji@naver.com ', 'pw').id, 'minji');
    expect(MailAccount('minji', 'pw').address, 'minji@naver.com');
    // Gmail keeps the whole address, Workspace domains included.
    final gmail = MailAccount.google('minji@company.com', 'token');
    expect(gmail.service, MailService.gmail);
    expect(gmail.address, 'minji@company.com');
  });

  test('MailAccount reads every saved format', () {
    final legacy = MailAccount.fromJson({'id': 'minji', 'password': 'pw'})!;
    expect(
      (legacy.service, legacy.address),
      (MailService.naver, 'minji@naver.com'),
    );
    final gmail = MailAccount.fromJson({
      'service': 'gmail',
      'address': 'minji@gmail.com',
      'secret': 'token',
    })!;
    expect((gmail.service, gmail.secret), (MailService.gmail, 'token'));
    final outlook = MailAccount.fromJson({
      'service': 'outlook',
      'address': 'minji@outlook.com',
      'secret': 'token',
    })!;
    expect(
      (outlook.service, outlook.address),
      (MailService.outlook, 'minji@outlook.com'),
    );
    expect(MailAccount.fromJson({'nope': 1}), isNull);
  });

  test('every error code in a message is explained in 도움말', () {
    final message = mailError(MailService.naver, const SocketException('down'));
    expect(problemCode('a@naver.com: $message'), 'C-01');
    expect(withoutCode(message), '인터넷 연결을 확인해 주세요.');
    expect(problemCode('안 읽은 메일이 없어요'), isNull);
    // Codes written in the sources must all be in the table.
    final used = {
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            !f.path.endsWith('help.dart'))
          for (final m in RegExp(
            r"\(([A-Z]-\d\d)\)'",
          ).allMatches(f.readAsStringSync()))
            m[1]!,
    };
    expect(used, isNotEmpty);
    expect(problems.keys, containsAll(used));
  });
}
