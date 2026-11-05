# Alpha Mail

Flutter 폰 앱(iOS·Android): 여러 메일 계정을 모아 보고, 음성인식·요약·낭독을 기기 안에서 처리. 사용자에게는 한국어로 답함.

## 명령어
```sh
flutter pub get
flutter run -d <device-id>
flutter test                 # test/widget_test.dart
flutter analyze
flutter build apk --split-per-abi   # → build/app/outputs/flutter-apk/
```

## 구조 (lib/)
- `main.dart`: 진입점, 스플래시
- `widgets.dart`: 공통 부품 `VoiceCard`, `ScreenTitle`, `AppPage`(경로·스와이프 뒤로), `WritePill`, `StatusChip`, `ServiceBadge`(네이버·Gmail 한 글자 배지), `Brand`, `SafeNotifier`(dispose 뒤 알림 무시). 새 화면도 이걸로 만듦
- `screens.dart`: 화면을 모두 내보내는 묶음 (`import 'screens.dart'` 하나로 다 씀)
- `mail/`: 메일 데이터
  - `mail.dart`: `Mail`, `MailFolder`, `markRead`, 예시 메일
  - `mail_account.dart`: 네이버·Gmail·Outlook IMAP(`enough_mail`)·SMTP 발송, Gmail·Outlook OAuth(`flutter_appauth`), `flutter_secure_storage`
  - `mail_inbox.dart`: `MailInbox`, 연동 계정과 안 읽은 메일, 주기적 확인
  - `summary.dart`: 기기 안 요약 (`flutter_gemma`, LiteRT-LM, Gemma 4 E2B 2.6GB)
- `voice/`: 음성
  - `speech.dart`: sherpa-onnx 한국어 STT. 모델 목록·URL은 `SpeechModel`, 녹음·인식·모델 불러오기·삭제는 `Recognizer`
  - `model_downloads.dart`: `ModelDownloads`, 음성 모델 다운로드·진행률·이어받기
  - `tts.dart`: `Reader`, 폰 내장 TTS (`flutter_tts`)
- `screens/`: 화면 하나당 파일 하나 — `home`(음성 홈, 위 상태 클래스들을 묶음), `voice_settings`(음성 설정·다운로드 배너), `mail_list`(메일 메뉴·메일함), `mail_view`(메일 내용·요약), `compose`(답장·작성·말로 보내기), `connect`(메일 연동), `settings`(설정 메뉴·알림 설정), `help`(도움말·오류 코드 표 `problems`, `showProblem`·`ProblemText`. 새 오류 문구는 한 줄로 쓰고 끝에 `(X-00)` 코드를 붙인 뒤 설명은 여기에)

## 꼭 지킬 것
- 폰 앱만. 데스크탑은 2026-10-15에 제외함. `isDesktop`·macOS 코드가 남아 있지만 새 기능은 넣지 않음.
- 메일 내용·음성을 외부 AI 서버로 보내지 않음 (메일 서버와의 통신만 허용).
- Android TTS는 오프라인 목소리만 씀. 네트워크 목소리는 메일 내용을 구글로 보냄.
- 모델은 앱 번들에 넣지 않음. 처음 쓸 때 `background_downloader`로 알림을 띄운 포그라운드 다운로드로 받음. 번들에 넣는 건 VAD(`assets/models/vad/`)뿐.
- 다운로더는 그룹별 콜백으로 씀. 공용 업데이트 스트림을 쓰면 다른 다운로드를 가로챔.
- Gmail OAuth 클라이언트 ID(`lib/mail/mail_account.dart`의 `googleClientId`)를 바꾸면 리다이렉트 스킴도 같이 바꿔야 함: `ios/Runner/Info.plist`, `macos/Runner/Info.plist`, `android/app/build.gradle.kts`(`appAuthRedirectScheme`). 마이크로소프트(`microsoftClientId`)의 리다이렉트 `com.applegend.alphamail://oauthredirect`는 `ios/Runner/Info.plist`와 `AndroidManifest.xml`의 `RedirectUriReceiverActivity`에 있음.
- iOS 최소 버전 16 (flutter_gemma 요구 사항).

## 작업 기록
- 하루 작업은 `TIMELINE.md` 맨 위에 날짜별로 적음 (최신순, 결정은 **결정:**으로 표시).
- 디자인 기준은 `DESIGN.md`.
- 겪은 문제는 `TROUBLESHOOTING.md`에 문제·원인·해결로 남김. 비슷한 증상이면 먼저 확인.
