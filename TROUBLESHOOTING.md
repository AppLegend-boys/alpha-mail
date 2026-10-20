# 문제 해결 기록

한 번 겪은 문제를 **문제 → 원인 → 해결** 순서로 남겨요. 비슷한 증상이 보이면 여기부터 확인하세요. 새로 겪으면 맨 위에 추가해요.

---

## 홈에 '불러오지 못했어요'가 남음 (메일함에서는 보임)

- **날짜:** 2026-10-19
- **문제:** 홈 카드가 '불러오지 못했어요'인데 눌러 들어가면 메일이 보이고, 홈으로 돌아와도 그대로임.
- **원인:** 홈의 안 읽은 메일은 앱을 켤 때 한 번만 받고, 주기 확인은 기본값이 '안 함'. 켤 때 한 번 실패하면 다시 받지 않았음. 메일함 화면은 따로 받아서 성공함. 첫 실패 이유는 아직 모름 (카드 아랫줄에 오류 문구가 나옴).
- **해결:** 다른 화면에서 홈으로 돌아올 때 실패한 계정만 다시 받음 (`MailInbox.retryFailed`).

## 홈에서 Gmail이 계속 '불러오는 중'

- **날짜:** 2026-10-18
- **문제:** 네이버는 불러왔는데 Gmail만 몇십 분째 '불러오는 중'. 로그에 오류 없음. 앱을 다시 켜니 바로 됨.
- **원인:** 앱 쪽 Gmail 연결(IMAP 소켓)이 하나도 없었어요. 네트워크가 아니라 **구글 토큰 갱신(`flutter_appauth`) 호출이 답을 안 주고 멈춘** 것으로 보여요. 화면이 잠긴 상태에서 앱이 켜졌을 때 생겼어요. 시간 제한이 없어서 영원히 기다렸어요. (정확한 원인은 재현하지 못함)
- **해결:** 토큰 요청은 20초, IMAP 서버 응답은 2분이 지나면 포기하고 '인터넷 연결을 확인해 주세요'를 보여요 (`lib/mail/mail_account.dart`의 `_login`, `_inInbox`).
- **확인:** 앱 소켓 보기 — 연결이 없는데 '불러오는 중'이면 앱 안에서 멈춘 거예요.
  ```sh
  adb shell "cat /proc/net/tcp6 /proc/net/tcp" | awk '$8==<앱 uid>'
  ```

## 메일 제목·보낸 사람이 `=?EUC-KR?B?xL+4rr7u...?=`처럼 깨져 보임

- **날짜:** 2026-10-18
- **문제:** 일부 한국 메일의 제목과 보낸 사람이 암호 같은 글자로 보이고, 본문도 깨짐. 로그에 `Error: no encoding found for [euc-kr].`
- **원인:** 메일 라이브러리 `enough_mail`이 EUC-KR(옛 한국어 인코딩, CP949·`ks_c_5601-1987`이라고도 씀)을 지원하지 않아요. 그래서 풀지 못한 채로 남겨 둬요.
- **해결:** `lib/mail/mail_account.dart`의 `koreanHeader`(제목·이름)와 `koreanText`(본문)가 `cp949_codec`으로 직접 풀어요. 로그의 `no encoding found`는 라이브러리가 찍는 거라 계속 보여도 괜찮아요.
- **다음에:** `charset` 패키지의 EUC-KR은 **틀린 글자를 내요**(안 → 陑). 한국어 인코딩 패키지를 바꿀 땐 `test/korean_mail_test.dart`의 표준 바이트 테스트(`BE C8` = 안)로 먼저 확인해요.

## 답장 화면에 들어가면 `setRequestedFrameRate` 로그가 계속 뜸

- **날짜:** 2026-10-17 · **기기:** 갤럭시 S26 Ultra (Android)
- **문제:** 메일 내용 화면에서 답장 화면으로 들어가면 아래 로그가 초당 약 24번씩 계속 찍힘. 앱을 뒤로 보내도 멈추지 않음. 메일함에서 연 '메일 작성'에서는 안 생김.
  ```
  I/View: setRequestedFrameRate frameRate=33.333332, this=io.flutter.plugins.webviewflutter.WebViewProxyApi$WebViewPlatformView{...}
  I/VRI[MainActivity]: Requested frameRateCategory 1 by io.flutter.plugins.webviewflutter...
  ```
- **원인:** 답장 화면은 메일 내용 화면 **위에 쌓여서** 열려요. 그래서 아래에 깔린 메일 본문 WebView(`_MailHtml`)도 살아 있어요. Android WebView는 다른 화면에 가려 안 보여도 계속 다시 그렸어요. 단순한 로그가 아니라 **배터리를 쓰는 문제**예요. '메일 작성'은 뒤에 WebView가 없어서 괜찮았던 거예요.
- **해결:** 답장 화면이 열려 있는 동안에는 WebView를 화면에서 떼어 둬요(`_MailHtml(hidden: true)`). 컨트롤러는 그대로 두기 때문에 돌아오면 같은 내용과 높이로 다시 붙어요. (`lib/screens/mail_view.dart`의 `_BriefingScreenState._reply`)
- **확인:** 답장 화면에서 아래 명령의 결과가 0에 가까우면 고쳐진 거예요.
  ```sh
  adb logcat -c; sleep 3; adb logcat -d | grep -c setRequestedFrameRate
  ```
- **다음에:** WebView가 있는 화면 위에 새 화면을 띄울 때는 같은 방법으로 WebView를 떼어 둬요.

## 음성 설정 화면에 들어가면 아무것도 안 뜸 (빈 화면)

- **날짜:** 2026-10-17
- **문제:** 음성 설정 화면이 하얗게 비어 있음. 받아 둔 모델 중 지금 쓰지 않는 게 있을 때만 생김.
- **원인:** 앱 공통 설정(`lib/main.dart`의 `filledButtonTheme`)에서 FilledButton의 최소 크기가 `Size.fromHeight(56)`, 즉 **가로를 꽉 채우기**로 돼 있어요. 이 버튼('이 모델 쓰기')을 `Row` 안에 넣으면 채울 가로 폭이 정해져 있지 않아서 화면 배치 단계에서 오류가 나고, 화면 전체가 안 그려져요.
- **해결:** Row 안의 FilledButton에는 최소 크기를 직접 줘요.
  ```dart
  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
  ```
- **다음에:** FilledButton을 Row 안에 넣을 때는 항상 위처럼 최소 크기를 직접 지정하거나 `Expanded`로 감싸요.

## 요약 모델 다운로드가 시작하자마자 실패

- **날짜:** 2026-10-15
- **문제:** 요약 모델(Gemma, 2.6GB) 다운로드가 바로 실패함.
- **원인:** 음성 모델 다운로드가 `background_downloader`의 **공용 알림 스트림(`updates`)을 혼자 잡고** 있었어요. 이 스트림은 한 곳에서만 들을 수 있어서, 요약 모델 다운로드는 결과를 받지 못했어요.
- **해결:** 음성 모델은 `registerCallbacks(group: ...)`로 **그룹별 콜백**을 써요.
- **다음에:** 다운로드를 새로 추가할 때도 공용 스트림 말고 그룹별 콜백을 써요.

## `adb pair` 오류: `protocol fault (couldn't read status message)`

- **날짜:** 2026-10-16
- **문제:** 와이파이로 무선 디버깅 페어링을 하면 위 오류가 남. 폰 핫스팟에 연결하면 됨.
- **원인:** 그 와이파이가 **같은 네트워크 기기끼리의 통신을 막아요**(AP 격리, 클라이언트 격리). 회사·학교·카페 와이파이에서 흔해요. 무선 디버깅 첫 화면의 포트(연결용)를 페어링에 넣어도 같은 오류가 나요.
- **해결:** 핫스팟을 쓰거나 USB 케이블로 연결해요. 페어링은 한 번만 하면 되고, 그다음부터는 `adb connect <IP>:<포트>`만 하면 돼요. 무선 디버깅을 껐다 켜면 포트가 바뀌어요.

## 빌드할 때마다 Kotlin Gradle Plugin(KGP) 경고

- **날짜:** 2026-10-16
- **문제:** `flutter run`을 할 때마다 "plugins that apply Kotlin Gradle Plugin" 경고가 뜸 (`flutter_gemma`, `flutter_tts`, `large_file_handler`, `record_android`).
- **원인:** 우리 코드가 아니라 플러그인들이 옛날 방식으로 Kotlin을 써서 나와요. `flutter_tts`는 이미 최신 버전이라 우리 쪽에서 고칠 수 없어요.
- **해결:** 지금은 무시해도 돼요. 경고일 뿐이고 빌드에는 영향이 없어요. `flutter_gemma`는 개발이 중단됐으니(후속 `flutter_edge_ai`) 옮길 때 일부가 같이 사라질 수 있어요.
