import 'package:alpha_mail/mail/mail.dart';
import 'package:alpha_mail/mail/mail_account.dart';
import 'package:alpha_mail/voice/commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quick rules: stop always, send only bare and only while confirming', () {
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
  });

  test('parseIntent reads the JSON and refuses anything else', () {
    final i = parseIntent(
      '네! {"action":"read","service":"gmail","only":false}',
    )!;
    expect(i.action, IntentAction.read);
    expect(i.service, MailService.gmail);
    expect(i.only, isFalse);
    expect(i.today, isFalse);
    expect(
      parseIntent('{"action":"reply","content":"괜찮다고"}')!.content,
      '괜찮다고',
    );
    expect(parseIntent('{"action":"reply","content":""}')!.content, isNull);
    expect(parseIntent('{"action":"none"}')!.action, IntentAction.none);
    expect(
      parseIntent('{"action":"read","service":"daum"}')!.service,
      isNull,
    );
    expect(parseIntent('{"action":"delete"}'), isNull);
    expect(parseIntent('지메일 메일을 읽어 드릴게요'), isNull);
    expect(parseIntent('{"action":'), isNull);
  });

  test('pickMails filters by service and day, or puts a service first', () {
    final naver = MailAccount('minji', 'pw');
    final gmail = MailAccount.google('minji@gmail.com', 'token');
    Mail mail(String s, MailAccount a, int day) =>
        Mail('보낸이', s, '', '', '', account: a, date: DateTime(2026, 11, day, 9));
    final n1 = mail('n1', naver, 6);
    final g1 = mail('g1', gmail, 7);
    final n2 = mail('n2', naver, 7);
    final now = DateTime(2026, 11, 7, 15);
    final mails = [n1, g1, n2];
    VoiceIntent read({
      MailService? service,
      bool only = false,
      bool today = false,
    }) => VoiceIntent(
      action: IntentAction.read,
      service: service,
      only: only,
      today: today,
    );
    expect(
      pickMails(mails, read(service: MailService.gmail, only: true), now: now),
      [g1],
    );
    expect(
      pickMails(mails, read(service: MailService.gmail), now: now),
      [g1, n1, n2],
    );
    expect(pickMails(mails, read(today: true), now: now), [g1, n2]);
    expect(
      pickMails(
        mails,
        read(service: MailService.outlook, only: true),
        now: now,
      ),
      isEmpty,
    );
  });

  test('replySubject adds Re: once', () {
    expect(replySubject('회의'), 'Re: 회의');
    expect(replySubject('RE: 회의'), 'RE: 회의');
  });
}
