import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Bluetooth") {
      Bluetooth.shared.register(with: registrar.messenger())
    }
  }
}

/// 자동 실행 (lib/bluetooth.dart). iOS doesn't show apps the paired devices,
/// so both the list and "connected" are the Bluetooth audio connected now.
final class Bluetooth: NSObject, FlutterStreamHandler {
  static let shared = Bluetooth()
  private var observer: NSObjectProtocol?

  func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "alphamail/bluetooth", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        switch call.method {
        case "devices", "connected": result(Bluetooth.audio())
        default: result(FlutterMethodNotImplemented)
        }
      }
    FlutterEventChannel(name: "alphamail/bluetooth/changes", binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  // The port name is the ID: one device's uid differs between its media
  // (A2DP) and call (HFP) routes.
  private static func audio() -> [[String: String]] {
    let bluetooth: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
    return AVAudioSession.sharedInstance().currentRoute.outputs
      .filter { bluetooth.contains($0.portType) }
      .map { ["id": $0.portName, "name": $0.portName] }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    observer = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { _ in events(true) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    return nil
  }
}
