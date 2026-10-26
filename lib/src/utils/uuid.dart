import 'dart:math';

String uuidV7(DateTime timestamp) {
  final random = Random.secure();
  final milliseconds = timestamp.millisecondsSinceEpoch;
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  for (var index = 5; index >= 0; index--) {
    bytes[index] = milliseconds >> ((5 - index) * 8) & 0xff;
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
