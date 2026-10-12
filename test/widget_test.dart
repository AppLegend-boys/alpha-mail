import 'dart:typed_data';

import 'package:alpha_mail/main.dart';
import 'package:alpha_mail/naver_mail.dart';
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

  test('htmlToText keeps line breaks and drops markup', () {
    const html =
        '<html><head><style>p{color:red}</style></head><body>'
        '<p>안녕하세요&nbsp;김서연입니다.</p><div>견적서 &amp; 일정</div>'
        'A&lt;B<br>끝</body></html>';
    expect(htmlToText(html), '안녕하세요 김서연입니다.\n견적서 & 일정\nA<B\n끝');
  });

  test('NaverMail keeps only the ID part of an address', () {
    expect(NaverMail(' minji@naver.com ', 'pw').id, 'minji');
    expect(NaverMail('minji', 'pw').address, 'minji@naver.com');
  });
}
