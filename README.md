# Alpha Mail

여러 메일 계정을 한곳에 모아 보고, 말로 듣고 답하는 Android·iOS 앱입니다.
음성인식, 요약, 답장 쓰기, 낭독은 모두 폰 안에서 처리합니다. 메일 내용과 음성은 외부 AI 서버로 보내지 않고, 앱이 통신하는 곳은 메일 서버(IMAP·SMTP)와 로그인(OAuth)뿐입니다.

## 주요 기능

- **메일 연동**: 네이버, Gmail, Outlook (IMAP으로 받고 SMTP로 보냄. Gmail·Outlook은 OAuth 로그인)
- **메일함**: 연결한 계정의 메일과 안 읽은 메일을 모아 보고, 주기적으로 새 메일을 확인
- **요약**: 메일 내용을 폰 안의 Gemma가 요약
- **화면 모드**: 터치 모드와 음성 모드 (설정 > 화면 모드)
- **음성 모드**: 마이크를 누르고 말하면 안 읽은 메일을 읽어 줌
  - 고정 명령 5개: 그만·멈춰 / 다음 / (확인할 때) 보내·취소·다시
  - 그 밖의 말("네이버만 읽어 줘", "박서준 메일 읽어 줘")은 Gemma가 뜻을 판단하고 읽을 메일을 고름
  - 말로 답장: "답장해 줘" → 내용 말하기 → Gemma가 초안 → 읽어 주고 "보낼까요?" → "보내"라고 해야 보냄
- **자동 실행**: 고른 블루투스 기기가 연결되면 하루 한 번 "안 읽은 메일이 N건 있어요. 읽어드릴까요?"라고 물음
  - Android: 앱이 꺼져 있어도 앱을 켬 ('다른 앱 위에 표시' 허용 필요)
  - iOS: 앱이 스스로 켜질 수 없어서 단축어 앱 자동화(블루투스 연결 → 앱 열기)를 쓰도록 안내

## 모델

| 용도 | 모델 | 크기 | 엔진 |
|---|---|---|---|
| 요약·명령 판단·답장 쓰기 | Gemma 4 E2B (`gemma-4-E2B-it.litertlm`) | 약 2.6GB | `flutter_gemma` (LiteRT-LM, GPU) |
| 음성인식 | SenseVoice (INT8) | 약 240MB | sherpa-onnx `1.13.8` |
| 음성인식 (정확도 높음) | Qwen3-ASR 0.6B (INT8) | 약 980MB | sherpa-onnx `1.13.8` |
| 말소리 감지(VAD) | Silero VAD | 앱에 포함 | sherpa-onnx |
| 낭독 | 폰에 내장된 TTS | - | `flutter_tts` |

- 모델은 앱에 넣지 않습니다. 처음 쓸 때 HuggingFace에서 알림을 띄운 채 내려받고, 그 뒤로는 인터넷 없이 동작합니다. 앱에 들어 있는 건 VAD(`assets/models/vad/`)뿐입니다.
- 음성인식 모델은 '음성 설정'에서 고르고, 받고, 지웁니다. 목록과 주소는 `lib/voice/speech.dart`의 `SpeechModel`에 있습니다.
- Gemma 모델 주소는 `lib/mail/summary.dart`에 있습니다.
- Android TTS는 오프라인 목소리만 씁니다 (네트워크 목소리는 메일 내용을 구글로 보냄).

## 실행

```sh
flutter pub get
flutter run -d <device-id>
flutter test
flutter analyze
flutter build apk --split-per-abi   # → build/app/outputs/flutter-apk/
```

- 보통 Android 폰에는 `app-arm64-v8a-release.apk`를 설치합니다 (`adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`).
- iOS는 16 이상이 필요하고(`flutter_gemma` 요구 사항), Xcode에서 서명을 설정해야 합니다.
- 데스크탑은 지원하지 않습니다 (2026-10-15에 제외).

## 문서

- `AGENTS.md`: 코드 구조와 꼭 지킬 규칙
- `DESIGN.md`: 디자인 기준
- `TIMELINE.md`: 날짜별 작업 기록과 결정
- `TROUBLESHOOTING.md`: 겪은 문제와 해결
