import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

String? _fallbackInstallId;

/// Shares identity even when preferences are unavailable or session tracking is off.
Future<String> getInstallId(SharedPreferences? preferences) async {
  try {
    final stored = preferences?.getString('wasmwatch_install_id');
    if (stored != null && stored.isNotEmpty) return stored;
  } catch (_) {}
  final id = _fallbackInstallId ??= sessionUuid();
  try {
    await preferences?.setString('wasmwatch_install_id', id);
  } catch (_) {}
  return id;
}

String sessionUuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
