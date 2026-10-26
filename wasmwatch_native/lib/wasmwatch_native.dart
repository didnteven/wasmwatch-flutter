import 'package:wasmwatch/native_bridge.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Optional Android and iOS capture. Reports stay pending until [ack] succeeds.
class WasmWatchNative {
  static const _channel = MethodChannel('wasmwatch/native');
  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  static final _available = StreamController<void>.broadcast();
  static var _listening = false;

  // Flutter runs registerWith before main, when no binding (and so no
  // messenger) exists yet, so the handler is installed on the first start.
  static void _registerNotifications() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'reportsAvailable') _available.add(null);
    });
  }

  /// Returns version 1 reports as JSON objects, skipping malformed entries.
  static Future<List<Map<String, Object?>>> start({
    required String release,
    String? environment,
    required String installId,
  }) async {
    if (!_supported) return [];
    _registerNotifications();
    final result = await _channel.invokeMethod<Object?>('start', {
      'release': release,
      if (environment != null) 'environment': environment,
      'install_id': installId,
    });
    if (result is! List) return [];
    final reports = <Map<String, Object?>>[];
    for (final item in result) {
      if (item is! String) continue;
      try {
        final decoded = jsonDecode(item);
        if (decoded is! Map<String, dynamic> ||
            decoded['v'] != 1 ||
            decoded['id'] is! String ||
            !const [
              'java_crash',
              'native_crash',
              'anr',
              'app_exit',
              'ios_crash',
              'ios_hang',
              'ios_exit_metrics'
            ].contains(decoded['kind']) ||
            (decoded['kind'].toString().startsWith('ios_')
                ? decoded['received_ms'] is! int
                : decoded['timestamp_ms'] is! int || decoded['pid'] is! int) ||
            decoded['release'] is! String ||
            decoded['install_id'] is! String ||
            (decoded.containsKey('environment') &&
                decoded['environment'] is! String)) {
          continue;
        }
        reports.add(Map<String, Object?>.from(decoded));
      } on FormatException {
        // A corrupt native report must not prevent other reports being sent.
      }
    }
    return reports;
  }

  /// Stores an opaque JSON scope, limited to 64 KiB.
  static Future<void> setScope(Map<String, Object?> scope) async {
    if (!_supported) return;
    await _channel.invokeMethod<void>('setScope', jsonEncode(scope));
  }

  /// Deletes acknowledged pending reports.
  static Future<void> ack(List<String> ids) async {
    if (!_supported) return;
    await _channel.invokeMethod<void>('ack', ids);
  }
}

/// Automatically registered by Flutter when this plugin is a dependency.
class WasmWatchNativeAndroid extends NativeCrashBridge {
  static void registerWith() {
    NativeCrashBridge.instance = WasmWatchNativeAndroid();
  }

  @override
  Stream<void> get reportsAvailable => WasmWatchNative._available.stream;

  @override
  Future<List<Map<String, Object?>>> start(
          {required String release,
          String? environment,
          required String installId}) =>
      WasmWatchNative.start(
          release: release, environment: environment, installId: installId);
  @override
  Future<void> setScope(Map<String, Object?> scope) =>
      WasmWatchNative.setScope(scope);
  @override
  Future<void> ack(List<String> ids) => WasmWatchNative.ack(ids);
}

/// iOS uses the same method-channel bridge and late-delivery notifications.
class WasmWatchNativeIOS extends WasmWatchNativeAndroid {
  static void registerWith() {
    NativeCrashBridge.instance = WasmWatchNativeIOS();
  }
}
