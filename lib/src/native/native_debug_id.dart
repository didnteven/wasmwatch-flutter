/// Symbolic identity: Mach-O uses the binary UUID's bytes unchanged, with no age.
/// ELF reverses the first three UUID fields of its truncated/padded build ID.
String nativeDebugId(String codeId, String format) {
  if (!RegExp(r'^(?:[0-9a-f]{2}){4,40}$').hasMatch(codeId) ||
      !{'elf', 'macho'}.contains(format) ||
      (format == 'macho' && codeId.length != 32)) {
    throw const FormatException('invalid native code ID or format');
  }
  final bytes = List<int>.filled(16, 0);
  for (var i = 0; i < 16 && i * 2 < codeId.length; i++) {
    bytes[i] = int.parse(codeId.substring(i * 2, i * 2 + 2), radix: 16);
  }
  if (format == 'elf') {
    for (final (start, end) in [(0, 4), (4, 6), (6, 8)]) {
      bytes.setRange(start, end, bytes.sublist(start, end).reversed.toList());
    }
  }
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
