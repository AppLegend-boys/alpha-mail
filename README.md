# Alpha Mail

Android·iOS용 완전 로컬 한국어 음성인식 MVP입니다. 마이크 음성은 sherpa-onnx 엔진과 한국어 Zipformer 모델로 기기 안에서 처리합니다. 앱에는 네트워크 권한을 추가하지 않았고, 음성 서버나 API 키를 사용하지 않습니다.

## 실행

Flutter SDK와 Android SDK를 설치한 뒤 USB 디버깅을 켠 Android 휴대폰을 연결합니다.

```sh
flutter pub get
flutter run
```

미리 빌드한 Android 설치 파일은 `build/app/outputs/flutter-apk/`에 있습니다. 보통 Android 휴대폰은 `app-arm64-v8a-release.apk`를 설치하면 됩니다. 구형 32비트 Android는 `app-armeabi-v7a-release.apk`, x86_64 기기는 `app-x86_64-release.apk`를 사용하세요. USB 연결 후 `adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`로 설치하거나 APK를 휴대폰에 복사해 열 수 있습니다. iPhone은 macOS의 Xcode와 서명 설정이 필요하며, 연결한 기기에서 `flutter run -d <device-id>`를 실행합니다.

## 모델

- sherpa-onnx `1.13.8`
- 한국어 streaming Zipformer, INT8 encoder/joiner
- 모델은 앱 번들에 넣지 않고, 앱에서 처음 선택할 때 HuggingFace에서 내려받습니다. 받은 뒤에는 오프라인으로 동작합니다.
- 원본 모델 안내: https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html

앱 번들에는 VAD 모델(`assets/models/vad/silero_vad.onnx`)만 포함됩니다. 음성인식 모델 목록과 다운로드 주소는 `lib/main.dart`의 `SpeechModel`에 있습니다.

## 현재 범위

말하기 시작·멈추기, 한국어 실시간 문장 표시, 마이크 권한 처리까지 구현했습니다. 기기 성능에 따라 속도와 인식률이 다르므로 보급형·구형 기기까지 지원 여부를 확인하려면 실제 기기별 측정이 필요합니다. 현재는 Android APK를 빌드했으며, iOS 서명 및 실기기 설치는 아직 수행하지 않았습니다.
