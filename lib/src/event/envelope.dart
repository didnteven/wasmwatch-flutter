import 'dart:convert';
import 'error_event.dart';

class Envelope {
  const Envelope({required this.event, required this.sdkVersion});
  final ErrorEvent event;
  final String sdkVersion;

  /// Sentry-compatible v1 wire shape: exactly three JSON records, newline
  /// delimited. The final newline is intentionally included for stream framing.
  String serialize() {
    final body = jsonEncode(event.toJson());
    final bytes = utf8.encode(body).length;
    if (bytes > 5 * 1024 * 1024) throw StateError('Event exceeds 5 MiB envelope limit');
    final header = jsonEncode({
      'event_id': event.eventId,
      'sent_at': DateTime.now().toUtc().toIso8601String(),
      'sdk': {'name': 'wasmwatch.dart', 'version': sdkVersion},
    });
    final item = jsonEncode({'type': 'event', 'content_type': 'application/json', 'length': bytes});
    return '$header\n$item\n$body\n';
  }
}
