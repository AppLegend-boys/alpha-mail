import 'package:alpha_mail/mail/mail.dart';
import 'package:alpha_mail/mail/mail_account.dart';
import 'package:alpha_mail/voice/commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'quick rules: stop always, send only bare and only while confirming',
    () {
      expect(quickCommand('그만'), Quick.stop);
      expect(quickCommand('그만 읽어'), Quick.stop);
      expect(quickCommand('멈춰'), Quick.stop);
      expect(quickCommand('다음'), Quick.next);
      expect(quickCommand('다음 주 월요일까지'), isNull);
      expect(quickCommand('보내'), isNull); // not confirming
      expect(quickCommand('보내', confirming: true), Quick.send);
      expect(quickCommand('보내요.', confirming: true), Quick.send);
      expect(quickCommand('4시로 보내자', confirming: true), isNull);
      expect(quickCommand('보내지 마', confirming: true), isNull);
      expect(quickCommand('보내 주신 거 말고', confirming: true), isNull);
      expect(quickCommand('응', confirming: true), isNull);
      expect(quickCommand('취소', confirming: true), Quick.cancel);
      expect(quickCommand('다시', confirming: true), Quick.again);
      expect(quickCommand('다음', confirming: true), isNull);
    },
  );

  test('parseIntent reads the JSON and refuses anything else', () {
    final i = parseIntent('네! {"action":"read","mails":[2,0,"x",2]}')!;
    expect(i.action, IntentAction.read);
    expect(i.mails, [2, 0, 2]);
    expect(parseIntent('{"action":"read"}')!.mails, isNull);
    expect(parseIntent('{"action":"reply","content":"괜찮다고"}')!.content, '괜찮다고');
    expect(parseIntent('{"action":"reply","content":""}')!.content, isNull);
    expect(parseIntent('{"action":"none"}')!.action, IntentAction.none);
    expect(parseIntent('{"action":"delete"}'), isNull);
    expect(parseIntent('지메일 메일을 읽어 드릴게요'), isNull);
    expect(parseIntent('{"action":'), isNull);
  });

  final naver = MailAccount('minji', 'pw');
  final gmail = MailAccount.google('minji@gmail.com', 'token');
  Mail mail(String s, MailAccount a, int day) => Mail(
    '보낸이',
    s,
    '',
    '',
    '',
    account: a,
    date: DateTime(2026, 11, day, 9),
  );

  test('pickMails keeps the numbers Gemma chose that exist, once each', () {
    final n1 = mail('n1', naver, 6);
    final g1 = mail('g1', gmail, 7);
    final n2 = mail('n2', naver, 7);
    final listed = [n1, g1, n2];
    expect(pickMails(listed, [1, 0]), [g1, n1]);
    expect(pickMails(listed, [2, 2, 7, -1]), [n2]);
    expect(pickMails(listed, []), isEmpty);
  });

  test('intentPrompt numbers the mails and warns of misheard words', () {
    final prompt = intentPrompt(
      '이거줘',
      mails: [mail('견적서', naver, 6), mail('배송 안내', gmail, 7)],
      unread: 1,
      reading: false,
      now: DateTime(2026, 11, 7, 15),
    );
    // A "true|false" template had Gemma fill keys at random.
    expect(prompt, isNot(contains('true|false')));
    expect(prompt, contains('0. 네이버 메일 · 보낸이 · 견적서 · 어제'));
    expect(prompt, contains('1. Gmail · 보낸이 · 배송 안내 · 오늘 · 이미 읽음'));
    expect(prompt, contains('이거줘'));
    expect(prompt, contains('"mails":['));
  });

  test('replySubject adds Re: once', () {
    expect(replySubject('회의'), 'Re: 회의');
    expect(replySubject('RE: 회의'), 'RE: 회의');
  });
}
