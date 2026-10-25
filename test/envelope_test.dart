import 'dart:convert';
import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  test('builds exactly three JSON records and uses UTF-8 byte length', () {
    final event = ErrorEvent(
      eventId: '0193f04a-1234-7abc-9def-0123456789ab',
      timestamp: DateTime.utc(2025),
      exceptionType: 'StateError', exceptionValue: 'é',
      frames: [RawStackFrame.raw(rawLine: 'opaque')],
      debugMeta: const DebugMeta(images: [DebugImage(debugId: '0193f05e-7d4c-7b2a-8f3a-1c2d3e4f5a6b', codeFile: 'main.dart.wasm', offsetKind: WasmOffsetKind.unknown)]),
    );
    final wire = Envelope(event: event, sdkVersion: '0.1.0').serialize();
    final records = wire.trimRight().split('\n');
    expect(records, hasLength(3));
    final image = jsonDecode(records[2])['debug_meta']['images'][0];
    expect(image['type'], 'js');
    expect(image['code_file'], 'main.dart.js');
    expect(jsonDecode(records[1])['length'], utf8.encode(records[2]).length);
  });

  test('keeps an all-digit debug id intact while still scrubbing the message', () {
    const zeroId = '00000000-0000-7000-8000-000000000000';
    final event = ErrorEvent(
      eventId: '0193f04a-1234-7abc-9def-0123456789ab',
      timestamp: DateTime.utc(2025),
      exceptionType: 'StateError', exceptionValue: 'card 4111 1111 1111 1111',
      frames: [RawStackFrame.raw(rawLine: 'opaque')],
      debugMeta: const DebugMeta(images: [DebugImage(debugId: zeroId, codeFile: 'main.dart.wasm', offsetKind: WasmOffsetKind.unknown)]),
    );
    final json = jsonEncode(event.toJson());
    expect(json, contains(zeroId));
    expect(json, isNot(contains('4111')));
  });

  test('captureException defaults to handled and preserves explicit mechanisms on the wire', () async {
    final events = <ErrorEvent>[];
    final client = WasmWatchClient(WasmWatchOptions(
      dsn: 'http://key@localhost/api/v1/1',
      beforeSend: (event) { events.add(event); return null; },
    ));
    await client.captureException(StateError('caught'));
    await client.captureException(StateError('uncaught'),
        mechanism: const {'type': 'flutter_error', 'handled': false});
    final mechanisms = events.map((event) {
      final records = Envelope(event: event, sdkVersion: 'test').serialize().trimRight().split('\n');
      return jsonDecode(records[2])['exception']['values'][0]['mechanism'];
    }).toList();
    expect(mechanisms, [
      {'type': 'generic', 'handled': true},
      {'type': 'flutter_error', 'handled': false},
    ]);
  });

  test('guarded zone errors carry an unhandled mechanism', () async {
    final events = <ErrorEvent>[];
    final client = WasmWatchClient(WasmWatchOptions(
      dsn: 'http://key@localhost/api/v1/1',
      beforeSend: (event) { events.add(event); return null; },
    ));
    await expectLater(ZoneIntegration.runZonedGuarded<void>(client, () async {
      throw StateError('zone error');
    }), throwsStateError);
    expect(events.single.mechanism, {'type': 'zone', 'handled': false});
  });

}
