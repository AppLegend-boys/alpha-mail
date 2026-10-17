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
- `speech.dart`: 음성 홈 + sherpa-onnx 한국어 STT, 모델 목록·URL은 `SpeechModel`
- `screens.dart`: 메일함, 메일 화면, 설정
- `mail_account.dart`: 네이버·Gmail IMAP(`enough_mail`), Gmail OAuth(`flutter_appauth`), `flutter_secure_storage`
- `summary.dart`: 기기 안 요약 (`flutter_gemma`, LiteRT-LM, Gemma 4 E2B 2.6GB)
- `tts.dart`: `Reader`, 폰 내장 TTS (`flutter_tts`)

## 꼭 지킬 것
- 폰 앱만. 데스크탑은 2026-10-15에 제외함. `isDesktop`·macOS 코드가 남아 있지만 새 기능은 넣지 않음.
- 메일 내용·음성을 외부 AI 서버로 보내지 않음 (메일 서버와의 통신만 허용).
- Android TTS는 오프라인 목소리만 씀. 네트워크 목소리는 메일 내용을 구글로 보냄.
- 모델은 앱 번들에 넣지 않음. 처음 쓸 때 `background_downloader`로 알림을 띄운 포그라운드 다운로드로 받음. 번들에 넣는 건 VAD(`assets/models/vad/`)뿐.
- 다운로더는 그룹별 콜백으로 씀. 공용 업데이트 스트림을 쓰면 다른 다운로드를 가로챔.
- Gmail OAuth 클라이언트 ID(`mail_account.dart`의 `googleClientId`)를 바꾸면 리다이렉트 스킴도 같이 바꿔야 함: `ios/Runner/Info.plist`, `macos/Runner/Info.plist`, `android/app/build.gradle.kts`(`appAuthRedirectScheme`).
- iOS 최소 버전 16 (flutter_gemma 요구 사항).

## 작업 기록
- 하루 작업은 `TIMELINE.md` 맨 위에 날짜별로 적음 (최신순, 결정은 **결정:**으로 표시).
- 디자인 기준은 `DESIGN.md`.
