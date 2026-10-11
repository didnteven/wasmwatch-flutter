import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';
import 'package:wasmwatch/src/utils/consecutive_loop_guard.dart';

void main() {
  test('fresh identical loops slide until a pause and A/B/A survives', () {
    final guard = ConsecutiveLoopGuard();
    var now = DateTime.utc(2026);
    expect(
        guard.record('Error', ' layout   failed ', 'throw', 'Row', now), false);
    for (var i = 0; i < 100; i++) {
      now = now.add(const Duration(milliseconds: 100));
      expect(guard.record('Error', 'layout failed', 'throw', 'Row', now), true);
    }
    now = now.add(const Duration(seconds: 1));
    expect(guard.record('Error', 'layout failed', 'throw', 'Row', now), false);
    expect(guard.record('Error', 'B', 'throw', 'Row', now), false);
    expect(guard.record('Error', 'layout failed', 'throw', 'Row', now), false);
  });
  test('session attempts include rejected callbacks and forged dev label',
      () async {
    var callbacks = 0;
    final client = WasmWatchClient(WasmWatchOptions(
        dsn: 'http://key@localhost/api/v1/1',
        environment: 'dev',
        protectionBypass: false,
        maxEventsPerSession: 3,
        beforeSend: (event) {
          callbacks++;
          return null;
        }));
    for (var i = 0; i < 4; i++) {
      await client.captureException(StateError('error $i'));
    }
    expect(callbacks, 3);
    expect(client.captureAttempts, 3);
    expect(client.sessionCapDrops, 1);
  });
  test(
      'recursive beforeSend is blocked in caller zone; concurrent errors survive',
      () async {
    final release = Completer<void>();
    var callbacks = 0;
    late WasmWatchClient client;
    client = WasmWatchClient(WasmWatchOptions(
        dsn: 'http://key@localhost/api/v1/1',
        protectionBypass: false,
        beforeSend: (event) async {
          callbacks++;
          expect(
              await client.captureException(StateError('recursive')), isNull);
          await release.future;
          return null;
        }));
    final a =
        client.captureException(StateError('A'), captureZone: Zone.current);
    final b =
        client.captureException(StateError('B'), captureZone: Zone.current);
    expect(callbacks, 2);
    release.complete();
    await Future.wait([a, b]);
    expect(client.captureAttempts, 2);
  });
  test('debug default bypasses volume guards but retains recursion protection',
      () async {
    var callbacks = 0;
    final client = WasmWatchClient(WasmWatchOptions(
        dsn: 'http://key@localhost/api/v1/1',
        maxEventsPerSession: 0,
        beforeSend: (event) {
          callbacks++;
          return null;
        }));
    for (var i = 0; i < 110; i++) {
      await client.captureException(StateError('same'));
    }
    expect(callbacks, 110);
  });
}
