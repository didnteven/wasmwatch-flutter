/// Shares recent captures between browser, isolate and Dart integrations. Ordinary
/// Dart captures retain their existing identity policy; matching across capture
/// paths also uses the message and supplied throw stack.
class CaptureDeduplicator {
  CaptureDeduplicator(
      {this.capacity = 32, this.window = const Duration(seconds: 2)});
  final int capacity;
  final Duration window;
  final _entries = <_Capture>[];

  bool record(Object error, String message, String? stack, DateTime now,
      {bool browser = false,
      bool suppressed = false,
      bool isolate = false,
      bool platformDispatcher = false}) {
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
    // Isolate listeners receive serialized errors, so identity is unavailable.
    // Match only the main-isolate/dispatcher pair, with an actual throw stack.
    String? serializedError;
    if (isolate || platformDispatcher) {
      try {
        serializedError = error.toString();
      } catch (_) {}
    }
    final duplicate = _entries.any((entry) =>
        (identical(entry.error, error) &&
            (browser ||
                entry.browser ||
                entry.suppressed ||
                now.difference(entry.time) <
                    const Duration(milliseconds: 100))) ||
        ((browser || entry.browser) &&
            entry.message == normalized &&
            (entry.stack == stack || entry.stack == null || stack == null)) ||
        (((isolate && entry.platformDispatcher) ||
                (platformDispatcher && entry.isolate)) &&
            serializedError != null &&
            serializedError == entry.serializedError &&
            stack != null &&
            stack.isNotEmpty &&
            entry.stack == stack));
    if (!duplicate || suppressed) {
      _entries.add(_Capture(error, normalized, stack, now, browser, suppressed,
          isolate, platformDispatcher, serializedError));
      if (_entries.length > capacity) _entries.removeAt(0);
    }
    return duplicate;
  }
}

class _Capture {
  _Capture(
      this.error,
      this.message,
      this.stack,
      this.time,
      this.browser,
      this.suppressed,
      this.isolate,
      this.platformDispatcher,
      this.serializedError);
  final Object error;
  final String message;
  final String? stack;
  final DateTime time;
  final bool browser;
  final bool suppressed;
  final bool isolate;
  final bool platformDispatcher;
  final String? serializedError;
}
