import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasmwatch/src/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final started = DateTime.utc(2026);
  for (final background in [false, true]) {
    for (final kind in [
      'native_crash',
      'java_crash',
      'java_unpaired',
      'anr',
      'app_exit',
      'unmatched'
    ]) {
      test('$kind recovery, background=$background', () async {
        SharedPreferences.setMockInitialValues({
          SessionTracker.sessionKey: jsonEncode({
            'sid': 'previous',
            'did': 'install',
            'init': true,
            'started': started.toIso8601String(),
            'timestamp': started.toIso8601String(),
            'status': 'ok',
            'errors': 0,
            'attrs': {'release': 'old', 'environment': 'test'},
            'platform': 'dart-android',
          }),
          if (background)
            SessionTracker.backgroundKey:
                started.add(const Duration(seconds: 2)).toIso8601String(),
        });
        final updates = <Map<String, Object?>>[];
        final tracker = SessionTracker(
            release: 'current',
            environment: 'test',
            platform: 'dart-android',
            preferences: await SharedPreferences.getInstance(),
            clock: () => started.add(const Duration(seconds: 20)),
            onUpdate: (update) async => updates.add(update));
        await tracker.start(nativeReports: [
          {
            'kind': kind == 'java_unpaired' ? 'java_crash' : kind,
            'scope': {
              'session_id': kind == 'unmatched' ? 'different' : 'previous'
            },
            'timestamp_ms':
                started.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
            if (kind != 'java_unpaired')
              'exit': {
                'timestamp_ms': started
                    .add(const Duration(seconds: 6))
                    .millisecondsSinceEpoch
              },
          }
        ]);
        final crash = kind == 'native_crash' || kind == 'java_crash';
        final abnormal = kind == 'anr' || kind == 'app_exit';
        expect(
            updates.first['status'],
            crash
                ? 'crashed'
                : abnormal || !background
                    ? 'abnormal'
                    : 'exited');
        expect(updates.first['errors'], crash ? 1 : 0);
        if (crash || abnormal)
          expect(updates.first['timestamp'],
              started.add(const Duration(seconds: 6)).toIso8601String());
        expect(updates.last['status'], 'ok');
        expect(updates.last['errors'], 0);
        await tracker.close();
      });
    }
  }
  test(
      'crash wins abnormal reports, preserves errors, and uses capture time without exit',
      () async {
    SharedPreferences.setMockInitialValues({
      SessionTracker.sessionKey: jsonEncode({
        'sid': 's',
        'did': 'i',
        'init': true,
        'started': started.toIso8601String(),
        'timestamp': started.toIso8601String(),
        'status': 'ok',
        'errors': 3,
        'attrs': {'release': 'old', 'environment': 'test'},
        'platform': 'dart-android',
      })
    });
    final updates = <Map<String, Object?>>[];
    final tracker = SessionTracker(
        release: 'new',
        environment: 'test',
        platform: 'dart-android',
        preferences: await SharedPreferences.getInstance(),
        clock: () => started.add(const Duration(seconds: 20)),
        onUpdate: (update) async => updates.add(update));
    await tracker.start(nativeReports: [
      {
        'kind': 'anr',
        'scope': {'session_id': 's'},
        'timestamp_ms':
            started.add(const Duration(seconds: 10)).millisecondsSinceEpoch
      },
      {
        'kind': 'native_crash',
        'scope': {'session_id': 's'},
        'timestamp_ms':
            started.add(const Duration(seconds: 5)).millisecondsSinceEpoch
      },
      {
        'kind': 'app_exit',
        'scope': {'session_id': 's'},
        'timestamp_ms':
            started.add(const Duration(seconds: 15)).millisecondsSinceEpoch
      },
    ]);
    expect(updates.first['status'], 'crashed');
    expect(updates.first['errors'], 3);
    expect(updates.first['timestamp'],
        started.add(const Duration(seconds: 5)).toIso8601String());
    await tracker.close();
  });
}
