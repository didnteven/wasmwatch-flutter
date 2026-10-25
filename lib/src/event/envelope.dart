import 'dart:convert';
import 'error_event.dart';

class Envelope {
  const Envelope({this.event, this.session, required this.sdkVersion})
      : assert(event != null || session != null);
  final ErrorEvent? event;
  final Map<String, Object?>? session;
  final String sdkVersion;

  /// Newline-delimited JSON records: event, session, or event then session.
  /// Each item's length counts UTF-8 bytes; the final newline frames the stream.
  String serialize() {
    final records = <String>[
      jsonEncode({
        if (event != null) 'event_id': event!.eventId,
        'sent_at': DateTime.now().toUtc().toIso8601String(),
        'sdk': {'name': 'wasmwatch.dart', 'version': sdkVersion},
      }),
    ];
    void add(String type, Object payload) {
      final body = jsonEncode(payload);
      records.add(jsonEncode({
        'type': type,
        'content_type': 'application/json',
        'length': utf8.encode(body).length,
      }));
      records.add(body);
    }

    if (event != null) {
      final payload = event!.toJson();
      if (session != null) {
        // beforeSend may await while the lifecycle rolls the active session.
        // Bind the wire event to the session whose counter was incremented,
        // preserving identifiers verbatim through PII scrubbing.
        final context = {
          'id': session!['sid'],
          'started_at': session!['started']
        };
        final contexts =
            Map<String, Object?>.from(payload['contexts'] as Map? ?? {});
        contexts['session'] = context;
        contexts['device'] = {
          if (contexts['device'] case final Map device) ...device,
          'session': context,
        };
        payload['contexts'] = contexts;
      }
      add('event', payload);
    }
    if (session != null) add('session', session!);
    if (event == null && session == null) throw StateError('Empty envelope');
    final wire = '${records.join('\n')}\n';
    if (utf8.encode(wire).length > 5 * 1024 * 1024)
      throw StateError('Envelope exceeds 5 MiB limit');
    return wire;
  }
}
