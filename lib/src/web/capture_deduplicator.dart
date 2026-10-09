/// Shares recent captures between browser hooks and Dart integrations. Ordinary
/// Dart captures retain their existing identity policy; matching across capture
/// paths also uses the message and supplied throw stack.
class CaptureDeduplicator {
  CaptureDeduplicator(
      {this.capacity = 32, this.window = const Duration(seconds: 2)});
  final int capacity;
  final Duration window;
  final _entries = <_Capture>[];

  bool record(Object error, String message, String? stack, DateTime now,
      {bool browser = false, bool suppressed = false}) {
    _entries.removeWhere((entry) => now.difference(entry.time) >= window);
    final normalized = message
        .replaceFirst(
            RegExp(
                r'^(?:Uncaught(?: \(in promise\))?\s+)?\w*(?:Error|Exception):\s*'),
            '')
        .trim();
    stack = stack == null
        ? null
        : stack
            .split('\n')
            .where((line) =>
                !RegExp(r'^\w*(?:Error|Exception):').hasMatch(line.trim()))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .join('\n');
    final duplicate = _entries.any((entry) =>
        (identical(entry.error, error) &&
            (browser ||
                entry.browser ||
                entry.suppressed ||
                now.difference(entry.time) <
                    const Duration(milliseconds: 100))) ||
        ((browser || entry.browser) &&
            entry.message == normalized &&
            (entry.stack == stack || entry.stack == null || stack == null)));
    if (!duplicate || suppressed) {
      _entries
          .add(_Capture(error, normalized, stack, now, browser, suppressed));
      if (_entries.length > capacity) _entries.removeAt(0);
    }
    return duplicate;
  }
}

class _Capture {
  _Capture(this.error, this.message, this.stack, this.time, this.browser,
      this.suppressed);
  final Object error;
  final String message;
  final String? stack;
  final DateTime time;
  final bool browser;
  final bool suppressed;
}
