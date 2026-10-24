final _uuid = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
    caseSensitive: false);
final _hex = RegExp(r'\b[0-9a-f]{8,}\b', caseSensitive: false);

/// Preserve separators and static segments; replace variable path segments.
String templatePath(String path) => path.split('/').map((segment) {
      final variable = RegExp(r'^\d+$').hasMatch(segment) ||
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
                  caseSensitive: false)
              .hasMatch(segment) ||
          RegExp(r'^[0-9a-f]{8,}$', caseSensitive: false).hasMatch(segment) ||
          RegExp(r'^[a-z0-9_+=\-]{16,}$', caseSensitive: false)
              .hasMatch(segment) ||
          RegExp(r'[%\s.]').hasMatch(segment);
      return variable ? '{id}' : segment;
    }).join('/');

/// Ordered, case-insensitive normalization shared with the server fixtures.
String normalizeMessage(String s) {
  s = s.replaceAllMapped(
      RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false), (match) {
    final uri = Uri.tryParse(match[0]!);
    if (uri == null || uri.host.isEmpty) return match[0]!;
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}${templatePath(uri.path.isEmpty ? '/' : uri.path)}';
  });
  s = s.replaceAll(_uuid, '{uuid}');
  s = s.replaceAll(_hex, '{hex}');
  s = s.replaceAll(
      RegExp(r'\b[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\b',
          caseSensitive: false),
      '{email}');
  s = s.replaceAll(RegExp(r""""[^"\r\n]*"|'[^'\r\n]*'"""), "'{s}'");
  s = s.replaceAll(RegExp(r'\d+(?:\.\d+)?'), '{n}');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return String.fromCharCodes(s.runes.take(256));
}
