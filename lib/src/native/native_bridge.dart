import 'package:flutter/foundation.dart';

/// Optional native capture plugin registration. The core SDK has no plugin dependency.
abstract class NativeCrashBridge {
  static NativeCrashBridge? instance;

  @visibleForTesting
  static void reset() => instance = null;

  /// Late OS delivery; absent on bridges without notifications.
  Stream<void>? get reportsAvailable => null;

  Future<List<Map<String, Object?>>> start({
    required String release,
    String? environment,
    required String installId,
  });
  Future<void> setScope(Map<String, Object?> scope);
  Future<void> ack(List<String> ids);
}
