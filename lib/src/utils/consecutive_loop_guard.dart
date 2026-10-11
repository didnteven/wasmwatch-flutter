/// Separate content guard: a continuous loop slides the one-second window.
/// Only the immediately preceding content matters, so A/B/A is observable.
class ConsecutiveLoopGuard {
  String? _key;
  DateTime? _seen;
  bool record(String type, String message, String? stack, String? widget,
      DateTime now) {
    final normalized = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    final signature = stack?.split('\n').map((line) => line.trim()).join('\n');
    final key = '$type\u0000$normalized\u0000$signature\u0000$widget';
    final duplicate = _key == key &&
        _seen != null &&
        now.difference(_seen!) < const Duration(seconds: 1);
    _key = key;
    _seen = now;
    return duplicate;
  }
}
