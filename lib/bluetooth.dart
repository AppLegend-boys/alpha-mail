import 'package:flutter/services.dart';

/// A Bluetooth device 자동 실행 can wait for.
typedef BluetoothDevice = ({String id, String name});

/// Bluetooth devices, from MainActivity.kt and AppDelegate.swift. Android
/// lists the paired ones; iOS doesn't show apps those, so there it's the
/// ones connected for audio now.
abstract final class Bluetooth {
  static const _methods = MethodChannel('alphamail/bluetooth');
  static const _events = EventChannel('alphamail/bluetooth/changes');

  /// Devices to pick from; asks for the Bluetooth permission on Android.
  static Future<List<BluetoothDevice>> devices() => _list('devices');

  /// IDs of the devices connected now.
  static Future<Set<String>> connected() async => {
    for (final d in await _list('connected')) d.id,
  };

  /// Android: whether 다른 앱 위에 표시 is allowed, which lets the app open
  /// itself when the device connects while it's closed.
  static Future<bool> launchAllowed() async {
    try {
      return await _methods.invokeMethod<bool>('launchAllowed') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Opens the phone's 다른 앱 위에 표시 setting for this app.
  static Future<void> allowLaunch() =>
      _methods.invokeMethod('allowLaunch').catchError((_) {});

  /// Fires when a device connects or disconnects.
  static Stream<void> get changes => _events.receiveBroadcastStream();

  static Future<List<BluetoothDevice>> _list(String method) async {
    try {
      // Android's profile lookups answer by callback; don't wait forever.
      final list = await _methods
          .invokeListMethod<Map>(method)
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
      return [
        for (final d in list ?? const <Map>[])
          (id: d['id'] as String, name: d['name'] as String),
      ];
    } on PlatformException {
      return [];
    } on MissingPluginException {
      return [];
    }
  }
}
