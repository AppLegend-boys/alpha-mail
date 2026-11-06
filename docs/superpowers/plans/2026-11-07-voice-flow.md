# 음성 모드 흐름 보완 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 화면을 보지 않고 음성 모드에서 메일을 듣고, 넘기고, 계정·순서를 바꾸고, Gemma가 쓴 답장을 확인해 보낼 수 있게 한다.

**Architecture:** 기본 규칙 다섯 개(그만·다음·보내·취소·다시)는 `lib/voice/commands.dart`의 순수 함수로 즉시 처리하고, 나머지 말은 `Summarizer`의 Gemma 세션에 JSON 행동으로 물어본다. 메일 고르기·JSON 해석·프롬프트도 같은 파일의 순수 함수로 두고 테스트한다. `voice_home.dart`는 이 함수들을 불러 상태만 옮긴다.

**Tech Stack:** Flutter, `flutter_gemma`(Gemma 4 E2B), sherpa-onnx STT(`Recognizer`), `flutter_tts`(`Reader`), `enough_mail`(`MailAccount.send`)

**Spec:** `docs/superpowers/specs/2026-11-07-voice-flow-design.md`

## Global Constraints

- 메일 내용·음성을 외부 AI 서버로 보내지 않음. Gemma는 기기 안에서만.
- 폰 앱만. 데스크탑 코드엔 손대지 않음.
- 메일은 규칙 “보내”(그 말만)로만 보냄. “응”, “네”, “보내자”, Gemma 판단으로는 절대 안 보냄.
- 초안을 읽는 동안 마이크를 끔. 다 읽은 뒤에만 확인을 들음.
- 받아쓰기는 2초 침묵에서 끝.
- Gemma가 없으면: 묻는 중엔 그만·나중 외의 말을 “읽어 줘”로, 답장은 “요약 모델을 받으면 말로 답장할 수 있어요”라고만 안내.
- 터치 홈(`home.dart`)·`BriefingScreen`·`compose.dart`의 명령 함수(`isYesCommand`, `isLaterCommand`, `isSkipCommand`, `sendAnswer`)는 지우지 않음. 음성 홈에서만 안 씀.
- 새 오류 문구는 한 줄 + `(X-00)` 코드, 설명은 `lib/screens/help.dart`.
- 작업 끝에 `TIMELINE.md` 맨 위 2026-11-07 항목에 기록.

## Review Focus

1. 읽는 중 폰 목소리가 새어 글자로 들어옴 → Gemma가 `none`을 주고 아무 일 없어야 함. (Task 2 `parseIntent` 테스트, Task 3 수동 확인)
2. Gemma가 JSON이 아닌 문장이나 목록 밖 값을 줌 → “못 알아들음”으로 다시 묻기. (Task 2 테스트)
3. 연결 안 된 계정·안 읽은 메일이 없는 계정을 말함(“아웃룩만”) → “Outlook에는 안 읽은 메일이 없어요” 후 다시 묻기, 지금 읽던 건 유지. (Task 2 `pickMails` 테스트)
4. 확인 단계에서 “보내 주신 거 말고…”, “보내지 마”, “4시로 보내자” → 보내지 않음. (Task 2 `quickCommand` 테스트)
5. 답장 중 화면을 떠나거나 “그만” → 생성 중인 초안은 버리고 아무것도 안 보냄 (`_run` 카운터). (Task 4 수동 확인)

---

### Task 1: 읽는 중 “그만”이 안 먹히는 버그

원인이 정해져 있지 않아 고칠 코드를 미리 정할 수 없다. `superpowers:systematic-debugging`으로 진행.

**Files:**
- Investigate: `lib/screens/voice_home.dart` (`_readMail`, `_hearCommands`, `_onSpeech`), `lib/voice/speech.dart` (`toggleListening`, VAD `minSilenceDuration: 0.6`), `lib/voice/tts.dart` (`Reader.speak`)
- Modify: `TROUBLESHOOTING.md`

- [ ] **Step 1:** `_onSpeech`, `Recognizer`의 세그먼트 결과(`speech.dart:574` 근처), `toggleListening(echoCancel: true)` 시작/종료에 임시 `debugPrint` (타임스탬프 포함)
- [ ] **Step 2:** 실기기(갤럭시 SM S948N)에서 `flutter run -d <device-id>`, 음성 모드로 메일 읽기 중 “그만”을 3번 말하고 로그 수집
- [ ] **Step 3:** 로그로 가설 판정: (a) 세그먼트가 낭독 끝난 뒤에야 옴 (b) 녹음이 낭독 중 데이터를 안 줌 (c) 글자는 오는데 낭독 문장이 섞여 다른 데서 걸림 (d) 그 외
- [ ] **Step 4:** 원인 한 곳만 고침. 말 끝난 뒤 멈출 때까지 체감 1.5초 이내인지 실기기로 확인 (넘으면 VAD 설정까지 이 Task 범위)
- [ ] **Step 5:** 임시 로그 제거, `flutter analyze` 경고 없음, `flutter test` 통과
- [ ] **Step 6:** `TROUBLESHOOTING.md`에 문제·원인·해결 추가 후 커밋

```bash
git add -A && git commit -m "Fix 그만 not stopping the voice home while it reads"
```

막히면: Task 2·4(묻는 중 해석, 답장)는 이 Task와 상관없으니 먼저 진행하고, Task 3의 “읽는 중” 부분만 보류.

---

### Task 2: 명령 순수 함수 (`lib/voice/commands.dart`)

**Files:**
- Create: `lib/voice/commands.dart`
- Test: `test/voice_commands_test.dart`

**Interfaces:**
- Produces:
  - `enum Quick { stop, next, send, cancel, again }`
  - `Quick? quickCommand(String said, {bool confirming = false})` — `stop`: 그만|멈춰 포함, 언제나. `next`: `isSkipCommand(said)` (mail_view.dart 재사용), `confirming`이 아닐 때만. `send`/`cancel`/`again`: `confirming`일 때만, 그 말만(앞뒤 공백·문장부호·“요”·“해”·“해 줘” 허용, `_skip` 정규식과 같은 모양)
  - `enum IntentAction { read, later, reply, none }`
  - `class VoiceIntent { const VoiceIntent({required this.action, this.service, this.only = false, this.fromStart = false, this.today = false, this.content}); final IntentAction action; final MailService? service; final bool only; final bool fromStart; final bool today; final String? content; }`
  - `VoiceIntent? parseIntent(String output)` — 출력에서 첫 `{`~마지막 `}`를 `jsonDecode`. 키: `action`(필수, 목록 밖이면 null), `service`(`naver|gmail|outlook|null`, 그 외 문자열이면 null 처리), `only`, `from_start`, `today`(bool, 없으면 false), `content`(빈 문자열이면 null). 깨지면 null
  - `List<Mail> pickMails(List<Mail> mails, VoiceIntent intent, {required DateTime now})` — `today`: `date`가 `now`와 같은 날. `service`+`only`: 그 서비스만(`mail.account?.service`). `service`+`!only`: 그 서비스 먼저, 나머지는 원래 순서로 뒤에. 원래 순서는 유지
  - `String intentPrompt(String said, {required List<MailService> services, required bool reading})`
  - `String replyPrompt(Mail mail, String said, {String? draft})` — `draft`가 있으면 “이 초안을 이렇게 고쳐 줘”. 받은 메일은 보낸 사람·제목·본문 앞 1500자(링크 제거, `summary.dart` `_prompt`와 같은 방식). 출력은 본문만, 인사·존댓말, 받은 메일 말투, 마크다운 없음
  - `String replySubject(String subject)` — `compose.dart`의 `_subject`와 같은 규칙(이미 `re:`면 그대로, 아니면 `Re: `). `compose.dart`도 이걸 쓰게 바꿈

- [ ] **Step 1: 실패하는 테스트 작성** (`test/voice_commands_test.dart`)

```dart
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
  final i = parseIntent('네! {"action":"read","service":"gmail","only":false}')!;
  expect(i.action, IntentAction.read);
  expect(i.service, MailService.gmail);
  expect(i.only, isFalse);
  expect(i.today, isFalse);
  expect(parseIntent('{"action":"reply","content":"괜찮다고"}')!.content, '괜찮다고');
  expect(parseIntent('{"action":"none"}')!.action, IntentAction.none);
  expect(parseIntent('{"action":"read","service":"daum"}')!.service, isNull);
  expect(parseIntent('{"action":"delete"}'), isNull);
  expect(parseIntent('지메일 메일을 읽어 드릴게요'), isNull);
  expect(parseIntent('{"action":'), isNull);
});

test('pickMails filters by service and day, or puts a service first', () {
  // [n1 (어제), g1 (오늘), n2 (오늘)] 순서로 받은 목록.
  final now = DateTime(2026, 11, 7, 15);
  final mails = [n1, g1, n2];
  VoiceIntent read({MailService? service, bool only = false, bool today = false}) =>
      VoiceIntent(action: IntentAction.read, service: service, only: only, today: today);
  expect(pickMails(mails, read(service: MailService.gmail, only: true), now: now), [g1]);
  expect(pickMails(mails, read(service: MailService.gmail), now: now), [g1, n1, n2]);
  expect(pickMails(mails, read(today: true), now: now), [g1, n2]);
  expect(pickMails(mails, read(service: MailService.outlook, only: true), now: now), isEmpty);
});
```

테스트용 `Mail`은 `Mail(from, subject, body, length, draft, account: ..., date: ...)`로 만들고, 계정은 `MailAccount`를 서비스만 다르게 (widget_test.dart의 `MailAccount` 테스트가 만드는 방식 참고).

- [ ] **Step 2:** `flutter test test/voice_commands_test.dart` → 정의 없음으로 FAIL
- [ ] **Step 3:** 위 Interfaces대로 `lib/voice/commands.dart` 구현, `compose.dart` `_subject`를 `replySubject`로
- [ ] **Step 4:** `flutter test` 전체 PASS, `flutter analyze` 경고 없음
- [ ] **Step 5: 커밋**

```bash
git add lib/voice/commands.dart lib/screens/compose.dart test/voice_commands_test.dart
git commit -m "Add voice command rules, Gemma intent parsing and mail picking"
```

---

### Task 3: Gemma로 명령 알아듣기 (음성 홈)

**Files:**
- Modify: `lib/mail/summary.dart` (생성 메서드 추가)
- Modify: `lib/screens/voice_home.dart` (`_onSpeech`, `_startReading`, `_missed`, `pillText`)
- Test: `test/widget_test.dart` (`pillText` 테스트 갱신)

**Interfaces:**
- Consumes: Task 2 전부
- Produces: `Future<String> Summarizer.complete(String prompt)` — `summarize`와 같은 `_lock`·`_chat`, `clearHistory` 후 한 번 생성해 전체 텍스트 반환. 캐시 없음. **요약을 끊지 않고 lock을 기다린다**: 지금 코드는 메일 요약이 끝나야 낭독을 시작하므로 낭독 중엔 Gemma가 놀고 있어 끊을 일이 없음 (설계 문서의 “요약을 멈추고”에서 바꾼 점, 내 판단)

- [ ] **Step 1:** `Summarizer.complete` 추가. 모델 없으면 호출하지 않는 쪽 책임(`installed` 확인)
- [ ] **Step 2:** `_onSpeech` 다시 쓰기
  - 먼저 `quickCommand(said, confirming: _step == VoiceStep.confirming)`: `stop` → `_quit()`, `next`(읽는 중) → 지금처럼 다음 메일
  - 규칙에 안 맞으면: 모델 없음 → 묻는 중이면 `_startReading()`, 읽는 중이면 무시. 모델 있음 → `_think(said)`
  - `isYesCommand`·`isLaterCommand` 호출 삭제
- [ ] **Step 3:** `Future<void> _think(String said)` — `run` 캡처, `_thinking = true`(알약 ‘확인하고 있어요’), `parseIntent(await Summarizer.instance.complete(intentPrompt(...)))`, `run`이 바뀌었으면 버림
  - null → 묻는 중이면 `_missed(heard: true)`, 읽는 중이면 무시
  - `none` → 무시(묻는 중이면 `_missed`)
  - `later` → `_quit()`
  - `read` → `_startReading(intent)`: `pickMails(intent.fromStart && _mails.isNotEmpty ? 이번에 처음 모은 목록 : widget.inbox.mails, intent, now: DateTime.now())`. 비면 “○○에는 안 읽은 메일이 없어요”를 말하고, 읽는 중이었으면 읽던 메일을 이어 감, 묻는 중이었으면 다시 듣기
  - `reply` → Task 4의 `_startReply(content: intent.content)`
  - 읽는 중엔 낭독을 멈추지 않고 결과가 `read`/`later`/`reply`일 때만 바꿈
- [ ] **Step 4:** 문구 바꾸기: `pillText` listening/idle 힌트 → `'“지메일부터 읽어 줘”처럼'`, `_missed` 첫 안내 → `'“메일 읽어 줘”, “네이버만”처럼 말씀해 주세요.'` (모델 없으면 기존 문구 유지)
- [ ] **Step 5:** `flutter test`(pillText 테스트 힌트 값이 바뀌면 갱신), `flutter analyze`
- [ ] **Step 6:** 실기기 확인: “네이버 메일만 읽어 줘”, “지메일부터 읽어 줘”, 읽는 중 “지메일로 바꿔 줘”, “안 읽은 거 처음부터”, “오늘 온 거 읽어 줘”, 읽는 중 아무 말 안 할 때 낭독 소리로 엉뚱하게 바뀌지 않는지(Review Focus 1). Gemma 응답 시간을 로그로 한 번 재서 기록
- [ ] **Step 7: 커밋**

```bash
git add lib/mail/summary.dart lib/screens/voice_home.dart test/widget_test.dart
git commit -m "Let Gemma read voice commands: pick accounts, order and day by voice"
```

---

### Task 4: 말로 답장

**Files:**
- Modify: `lib/screens/voice_home.dart` (`VoiceStep`, `pillText`, 답장 흐름, ‘답장할래’ 칩)
- Test: `test/widget_test.dart` (`pillText` 새 단계)

**Interfaces:**
- Consumes: `quickCommand`, `replyPrompt`, `replySubject`, `Summarizer.complete`, `MailAccount.send({to, subject, text, replyTo})`
- Produces: `VoiceStep`에 `dictating, drafting, confirming, sending` 추가

- [ ] **Step 1: 실패하는 테스트**

```dart
test('voice pill follows the spoken reply', () {
  expect(pillText(VoiceStep.dictating).$1, '듣고 있어요');
  expect(pillText(VoiceStep.drafting).$1, '답장 쓰는 중');
  expect(pillText(VoiceStep.confirming), ('보낼까요?', '“보내”, “다시”, “취소”'));
  expect(pillText(VoiceStep.sending).$1, '보내는 중');
});
```

- [ ] **Step 2:** `flutter test` → FAIL
- [ ] **Step 3:** `pillText`에 네 단계 추가 (dictating 힌트 `'말을 마치면 잠깐 기다려 주세요'`, drafting·sending 힌트 `'잠시만요'`)
- [ ] **Step 4:** `_startReply({String? content})`
  - 모델 없음 → `'요약 모델을 받으면 말로 답장할 수 있어요.'` 말하고 읽던 메일 이어 감
  - `content` 있음 → `_draft(content)`, 없음 → `'뭐라고 보낼까요?'` 말하고 끝난 뒤 `dictating`으로 듣기
- [ ] **Step 5:** 받아쓰기 끝내기: `dictating` 중 `_onSpeech`는 `quickCommand`의 `stop`만 보고 나머지는 모아 둠(`_s.heard`가 세그먼트를 이어 붙임). 마지막 세그먼트 뒤 2초 동안 `!_s.hearing && _s.partial.isEmpty`이면 끝 → `_draft(_s.heard)`. 처음 8초 아무 말 없으면 `_missed`와 같은 방식으로 한 번 더 묻고, 두 번째엔 답장 취소 후 읽기 이어 감
- [ ] **Step 6:** `_draft(String said, {String? previous})` — 마이크 끔, `drafting`, `complete(replyPrompt(mail, said, draft: previous))`, 결과를 말풍선(`_say`)에 보이고 `'이렇게 보낼게요. $draft 보낼까요?'`를 읽음. 다 읽은 뒤에만 `confirming`으로 듣기
- [ ] **Step 7:** `confirming`에서 `quickCommand(confirming: true)`: `send` → `_sendReply`, `cancel` → `'안 보냈어요.'` 후 다음 메일, `again` → `'뭐라고 보낼까요?'`부터, `stop` → `_quit()`, 그 외 → `_draft(said, previous: draft)`. 8초 무응답은 한 번 더 묻고 두 번째엔 칩(보내기·다시·취소) 남기고 대기
- [ ] **Step 8:** `_sendReply` — `sending`, `mail.account!.send(to: mail.address, subject: replySubject(mail.subject), text: draft, replyTo: mail)`. 성공 `'보냈어요.'` 후 다음 메일. 실패 → `'보내지 못했어요. ${mailError(service, e)}'` 화면에, 읽을 땐 코드 빼고(기존 낭독 방식) `'다시 보낼까요?'` → `confirming`. 계정·주소 없는 예시 메일이면 `'예시 메일에는 답장할 수 없어요.'`
- [ ] **Step 9:** ‘답장할래’ 칩: 모델 있으면 `_startReply()`, 없으면 지금처럼 `widget.onReply(mail)`(작성 화면)
- [ ] **Step 10:** `flutter test`, `flutter analyze`
- [ ] **Step 11:** 실기기 확인: “답장해 줘” → 말하기 → 초안 → “보내”가 자기 계정 주소로 실제 도착(자기 자신에게 온 메일로 시험), “괜찮다고 보내자” 한 번에, 확인 단계 “4시로 보내자”가 안 보내고 고친 초안을 읽는지, 초안 낭독 중 아무 반응 없는지, 답장 중 “그만”·화면 이탈 시 안 보내는지(Review Focus 4·5)
- [ ] **Step 12: 커밋**

```bash
git add lib/screens/voice_home.dart test/widget_test.dart
git commit -m "Reply by voice: Gemma drafts it, reads it back, sends only on 보내"
```

---

### Task 5: 기록

- [ ] **Step 1:** `TIMELINE.md` 맨 위에 `## 2026-11-07 (토)`: **결정:** Gemma가 음성 명령을 판단하고 규칙은 다섯 개로 고정, 말로 답장(보내기는 “보내”만), Gemma 없으면 말로 답장 없음, 받아쓰기 2초 침묵, Task 1 버그 원인 한 줄, Task 3에서 잰 Gemma 응답 시간
- [ ] **Step 2:** 설계 문서의 “세션 순서” 문단을 Task 3의 결정(요약을 끊지 않고 기다림)으로 고침
- [ ] **Step 3: 커밋**

```bash
git add TIMELINE.md docs/superpowers/specs/2026-11-07-voice-flow-design.md
git commit -m "Log the voice flow work"
```
