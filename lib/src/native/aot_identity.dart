import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Derives a UUIDv7-shaped identity from a snapshot's hexadecimal ELF build ID.
String dartAotDebugId(String buildId) {
  if (buildId.length < 8 ||
      buildId.length > 64 ||
      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(buildId)) {
    throw const FormatException('build ID must be 8 to 64 hexadecimal digits');
  }
  final bytes = sha256
      .convert(
          utf8.encode('wasmwatch-dart-aot-v1\u0000${buildId.toLowerCase()}'))
      .bytes
      .take(16)
      .toList();
  bytes[6] = (bytes[6] & 15) | 0x70;
  bytes[8] = (bytes[8] & 63) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
