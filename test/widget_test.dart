import 'dart:typed_data';

import 'package:alpha_mail/voice/speech.dart';
import 'package:alpha_mail/mail/mail_account.dart';
import 'package:alpha_mail/screens/compose.dart';
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
    expect(MailAccount.fromJson({'nope': 1}), isNull);
  });
}
