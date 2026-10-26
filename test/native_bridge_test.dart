import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasmwatch/native_bridge.dart';
import 'package:wasmwatch/src/native/native_scope.dart';
import 'package:wasmwatch/src/session.dart';
import 'package:wasmwatch/wasmwatch.dart';

class FakeBridge extends NativeCrashBridge {
  final starts = <Map<String, Object?>>[];
  final scopes = <Map<String, Object?>>[];
  final acknowledgements = <String>[];
  List<Map<String, Object?>> reports = [];
  Future<List<Map<String, Object?>>> Function()? onStart;
  Future<void> Function(Map<String, Object?>)? onScope;
  bool failAck = false;
  final available = StreamController<void>.broadcast();
  @override
  Stream<void> get reportsAvailable => available.stream;
  @override
  Future<List<Map<String, Object?>>> start(
      {required String release,
      String? environment,
      required String installId}) async {
    starts.add({
      'release': release,
      'environment': environment,
      'install_id': installId
    });
    return onStart == null ? reports : onStart!();
  }

  @override
  Future<void> setScope(Map<String, Object?> scope) async {
    scopes.add(scope);
    await onScope?.call(scope);
  }

  @override
  Future<void> ack(List<String> ids) async {
    if (failAck) throw StateError('ack failed');
    acknowledgements.addAll(ids);
  }
}

class FailingStorage implements OfflineStorage {
  @override
  Future<List<String>?> read(String key) async => [];
  @override
  Future<bool> write(String key, List<String> value) async => false;
  @override
  Future<bool> remove(String key) async => true;
}

var _nextId = 0;
Map<String, Object?> report() => Map<String, Object?>.from(
    jsonDecode(File('test/fixtures/native/java_crash.json').readAsStringSync())
        as Map)
  ..['id'] = 'test-${_nextId++}';
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    NativeCrashBridge.reset();
  });
  tearDown(() async {
    await WasmWatch.close();
    NativeCrashBridge.reset();
    debugDefaultTargetPlatformOverride = null;
  });
  WasmWatchClient client(
      {bool sessions = false,
      OfflineBuffer? buffer,
      BeforeSend? beforeSend,
      Future<http.Response> Function(http.Request)? send}) {
    final config = WasmWatchOptions(
        dsn: 'http://key@localhost/v1/1',
        release: 'current-build',
        environment: 'test',
        trackSessions: sessions,
        captureLifecycleBreadcrumbs: false,
        autoInstallFlutterErrorHandlers: false,
        maxRetries: 0,
        beforeSend: beforeSend);
    return WasmWatchClient(config,
        offlineBuffer: buffer,
        transport: HttpTransport(config.parsedDsn,
            maxRetries: 0,
            client: MockClient(send ?? (_) async => http.Response('', 200))));
  }

  test(
      'Android bridge shares persistent install ID and uses the new session scope',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final previous = SessionTracker(
        release: 'old',
        environment: 'test',
        platform: 'dart-android',
        preferences: prefs,
        onUpdate: (_) async {});
    await previous.start();
    final id = previous.context!['id'];
    final native = report();
    (native['scope'] as Map)['session_id'] = id;
    native['exit'] = {
      'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
      'reason': 'CRASH'
    };
    final bridge = FakeBridge()..reports = [native];
    bridge.onStart = () async {
      expect(jsonDecode(prefs.getString(SessionTracker.sessionKey)!)['sid'],
          isNot(id));
      expect(jsonDecode(prefs.getString(SessionTracker.sessionKey)!)['status'],
          'ok');
      return bridge.reports;
    };
    NativeCrashBridge.instance = bridge;
    final active = client(sessions: true);
    await WasmWatch.init(client: active);
    await settle();
    expect(bridge.starts.single['install_id'],
        prefs.getString(SessionTracker.installIdKey));
    expect(bridge.starts.single['release'], 'current-build');
    expect(bridge.scopes.first['session_id'],
        active.sessionTracker!.context!['id']);
    expect(
        jsonDecode(prefs.getString(SessionTracker.sessionKey)!)['errors'], 0);
    await previous.close();
  });
  test(
      'install ID persists with sessions disabled, other platforms do not start bridge',
      () async {
    final bridge = FakeBridge();
    NativeCrashBridge.instance = bridge;
    await WasmWatch.init(client: client());
    final prefs = await SharedPreferences.getInstance();
    expect(bridge.starts.single['install_id'],
        prefs.getString(SessionTracker.installIdKey));
    expect(prefs.getString(SessionTracker.sessionKey), isNull);
    await WasmWatch.init(client: client());
    expect(bridge.starts[0]['install_id'], bridge.starts[1]['install_id']);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await WasmWatch.init(client: client());
    expect(bridge.starts, hasLength(2));
  });
  test(
      'bridge errors, a pending start, scope errors and ack errors cannot fail initialization',
      () async {
    final bridge = FakeBridge();
    NativeCrashBridge.instance = bridge;
    bridge.onStart = () => Future.error(StateError('start failed'));
    bridge.onScope = (_) => Future.error(StateError('scope failed'));
    await WasmWatch.init(client: client());
    bridge.onStart = () => Completer<List<Map<String, Object?>>>().future;
    final watch = Stopwatch()..start();
    await WasmWatch.init(client: client());
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    await settle();
    bridge.onStart = null;
    bridge.reports = [report()];
    bridge.failAck = true;
    await WasmWatch.init(client: client());
    await settle();
    expect(WasmWatch.isInitialized, true);
  });
  Future<String> seedPrevious({bool background = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().subtract(const Duration(minutes: 1)).toUtc();
    await prefs.setString(
        SessionTracker.sessionKey,
        jsonEncode({
          'sid': 'previous',
          'did': 'install',
          'init': true,
          'started': now.toIso8601String(),
          'timestamp': now.toIso8601String(),
          'status': 'ok',
          'errors': 0,
          'attrs': {'release': 'old', 'environment': 'test'},
          'platform': 'dart-android'
        }));
    if (background)
      await prefs.setString(
          SessionTracker.backgroundKey, now.toIso8601String());
    return 'previous';
  }

  List<Map> sessionUpdates(List<String> wires, String sid) => wires
      .expand((wire) => wire.trimRight().split('\n').map(jsonDecode))
      .whereType<Map>()
      .where((row) => row['sid'] == sid)
      .toList();

  Map<String, Object?> exitsReport() => Map<String, Object?>.from(jsonDecode(
      File('test/fixtures/native/ios/exit-metrics.synthetic.json')
          .readAsStringSync()) as Map)
    ..['id'] = 'ios-${(_nextId++).toRadixString(16).padLeft(64, '0')}';

  test(
      'exit metrics preserve identity, bypass event hooks and never change sessions',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final sid = await seedPrevious();
    final report = exitsReport();
    final bridge = FakeBridge()..reports = [report, report];
    NativeCrashBridge.instance = bridge;
    final wires = <String>[];
    final active = client(
        sessions: true,
        beforeSend: (_) => throw StateError('not an event'),
        send: (request) async {
          wires.add(request.body);
          return http.Response('', 202);
        });
    await WasmWatch.init(client: active);
    await settle();
    final exitWires = wires
        .where((wire) =>
            (jsonDecode(wire.split('\n')[1]) as Map)['type'] == 'app_exits')
        .toList();
    expect(exitWires, hasLength(1));
    final records = exitWires.single.trim().split('\n');
    expect(records, hasLength(3));
    final payload = jsonDecode(records[2]) as Map;
    expect(payload['id'], report['id']);
    expect(payload['release'], 'old-ios-build');
    expect(payload['environment'], 'production');
    expect(payload['platform'], 'dart-ios');
    expect(payload['install_id'], report['install_id']);
    expect(bridge.acknowledgements, [report['id']]);
    expect(active.captureAttempts, 0);
    expect(
        sessionUpdates(wires, sid)
            .where((update) => update['status'] == 'crashed'),
        isEmpty);
    await bridge.available.close();
  });

  for (final status in [200, 202, 302, 400, 403, 429, 500]) {
    test('exit metrics ack policy for HTTP $status with offline persistence',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final report = exitsReport();
      final bridge = FakeBridge()..reports = [report];
      NativeCrashBridge.instance = bridge;
      final prefs = await SharedPreferences.getInstance();
      final buffer = OfflineBuffer(SharedPreferencesStorage(prefs));
      var response = status;
      final active = client(
          buffer: buffer, send: (_) async => http.Response('', response));
      await WasmWatch.init(client: active);
      await settle();
      final completed =
          status < 300 || (status >= 400 && status < 500 && status != 429);
      expect(bridge.acknowledgements, completed ? [report['id']] : isEmpty);
      expect(await buffer.pending(), completed ? isEmpty : hasLength(1));
      if (!completed) {
        response = 202;
        // A later bridge refresh retries the report; identity remains unchanged.
        bridge.available.add(null);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await settle();
        expect(bridge.acknowledgements, [report['id']]);
        expect(await buffer.pending(), isEmpty);
      }
      await bridge.available.close();
    });
  }

  test('empty and zero exit metrics ack without transport or sessions',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final report = exitsReport()
      ..['diagnostic'] = {
        'foregroundExitData': {'cumulativeNormalAppExitCount': 0}
      };
    final empty = {...report, 'id': 'empty', 'diagnostic': <String, Object?>{}};
    final bridge = FakeBridge()..reports = [report, empty];
    NativeCrashBridge.instance = bridge;
    var sends = 0;
    await WasmWatch.init(client: client(send: (_) async {
      sends++;
      return http.Response('', 202);
    }));
    await settle();
    expect(sends, 0);
    expect(bridge.acknowledgements, [report['id'], 'empty']);
    await bridge.available.close();
  });

  test(
      'iOS empty start waits for late crash; notifications dedupe and ack empty exit metrics',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final sid = await seedPrevious();
    final bridge = FakeBridge();
    NativeCrashBridge.instance = bridge;
    final wires = <String>[];
    await WasmWatch.init(
        client: client(
            sessions: true,
            send: (request) async {
              wires.add(request.body);
              return http.Response('', 200);
            }));
    await settle();
    expect(sessionUpdates(wires, sid), isEmpty);
    expect(bridge.scopes.first['pid'], pid);
    final native = report()
      ..['kind'] = 'ios_crash'
      ..['received_ms'] = 123;
    (native['scope'] as Map)['session_id'] = sid;
    final metrics = {...native, 'kind': 'ios_exit_metrics', 'id': 'metrics'};
    bridge.reports = [native, native, metrics];
    bridge.available.add(null);
    bridge.available.add(null);
    await settle();
    expect(bridge.starts.length, 3);
    expect(sessionUpdates(wires, sid).single['status'], 'crashed');
    expect(bridge.acknowledgements, unorderedEquals([native['id'], 'metrics']));
    final count = bridge.starts.length;
    await WasmWatch.close();
    bridge.available.add(null);
    await settle();
    expect(bridge.starts.length, count);
    await bridge.available.close();
  });

  test('late iOS crash recovery is not blocked by an earlier pending event',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final sid = await seedPrevious();
    final earlier = report()
      ..['kind'] = 'ios_hang'
      ..['received_ms'] = 123;
    final bridge = FakeBridge()..reports = [earlier];
    NativeCrashBridge.instance = bridge;
    final hung = Completer<void>();
    final wires = <String>[];
    await WasmWatch.init(
        client: client(
            sessions: true,
            beforeSend: (event) async {
              if (event.exceptionType == 'AppHang') await hung.future;
              return event;
            },
            send: (request) async {
              wires.add(request.body);
              return http.Response('', 200);
            }));
    await settle();
    expect(hung.isCompleted, false);
    expect(bridge.acknowledgements, isEmpty);
    final crash = report()
      ..['kind'] = 'ios_crash'
      ..['received_ms'] = 123;
    (crash['scope'] as Map)['session_id'] = sid;
    bridge.reports = [earlier, crash];
    bridge.available.add(null);
    await settle();
    expect(sessionUpdates(wires, sid).single['status'], 'crashed');
    expect(bridge.acknowledgements, [crash['id']]);
    hung.complete();
    await settle();
    expect(bridge.acknowledgements, [crash['id'], earlier['id']]);
    await bridge.available.close();
  });

  testWidgets(
      'iOS hangs leave the deferred session alone until the 30 second fallback',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final sid = await seedPrevious();
    final wires = <String>[];
    final hang = report()
      ..['kind'] = 'ios_hang'
      ..['received_ms'] = 123;
    (hang['scope'] as Map)['session_id'] = sid;
    final bridge = FakeBridge()..reports = [hang];
    NativeCrashBridge.instance = bridge;
    final active = client(
        sessions: true,
        send: (request) async {
          wires.add(request.body);
          return http.Response('', 200);
        });
    await WasmWatch.init(client: active);
    await tester.pump();
    expect(sessionUpdates(wires, sid), isEmpty);
    await tester.pump(const Duration(seconds: 30));
    await active.sessionTracker!.pending;
    await tester.pump();
    expect(sessionUpdates(wires, sid).single['status'], 'abnormal');
    await WasmWatch.close();
    unawaited(bridge.available.close());
    debugDefaultTargetPlatformOverride = null;
  });

  test('init and the new session finish before slow native recovery', () async {
    final sid = await seedPrevious();
    final prefs = await SharedPreferences.getInstance();
    final gate = Completer<List<Map<String, Object?>>>();
    final bridge = FakeBridge()..onStart = () => gate.future;
    NativeCrashBridge.instance = bridge;
    final wires = <String>[];
    final active = client(
        sessions: true,
        send: (request) async {
          wires.add(request.body);
          return http.Response('', 200);
        });
    await WasmWatch.init(client: active);
    await settle();
    expect(gate.isCompleted, false);
    expect(active.sessionTracker!.context!['id'], isNot(sid));
    expect(sessionUpdates(wires, sid), isEmpty);
    expect(prefs.getString(SessionTracker.previousSessionsKey), contains(sid));
    final native = report()..['kind'] = 'native_crash';
    (native['scope'] as Map)['session_id'] = sid;
    gate.complete([native, native]);
    await settle();
    final ended = sessionUpdates(wires, sid).single;
    expect(ended['status'], 'crashed');
    expect(ended['errors'], 1);
    expect(bridge.acknowledgements, [native['id']]);
    expect(prefs.getString(SessionTracker.previousSessionsKey), isNull);
    expect(jsonDecode(prefs.getString(SessionTracker.sessionKey)!)['status'],
        'ok');
  });
  for (final background in [false, true]) {
    for (final failure in ['error', 'timeout']) {
      testWidgets(
          '$failure falls back to non-native session rules, background=$background',
          (tester) async {
        final sid = await seedPrevious(background: background);
        final gate = Completer<List<Map<String, Object?>>>();
        final bridge = FakeBridge()..onStart = () => gate.future;
        NativeCrashBridge.instance = bridge;
        final wires = <String>[];
        final active = client(
            sessions: true,
            send: (request) async {
              wires.add(request.body);
              return http.Response('', 200);
            });
        await WasmWatch.init(client: active);
        await tester.pump();
        expect(sessionUpdates(wires, sid), isEmpty);
        if (failure == 'error') {
          gate.completeError(StateError('bridge failed'));
        } else {
          await tester.pump(const Duration(seconds: 29));
          expect(sessionUpdates(wires, sid), isEmpty);
          await tester.pump(const Duration(seconds: 1));
        }
        await tester.pump();
        await active.sessionTracker!.pending;
        await tester.pump();
        expect(sessionUpdates(wires, sid).single['status'],
            background ? 'exited' : 'abnormal');
        if (failure == 'timeout') {
          final native = report()..['kind'] = 'native_crash';
          (native['scope'] as Map)['session_id'] = sid;
          gate.complete([native]);
          await tester.pump();
          await tester.pump();
          expect(sessionUpdates(wires, sid), hasLength(1));
          expect(bridge.acknowledgements, [native['id']]);
        }
        await WasmWatch.close();
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
  test(
      'kill during native wait preserves both sessions and emits each only once on restart',
      () async {
    final sid = await seedPrevious();
    final bridge = FakeBridge()
      ..onStart = () => Completer<List<Map<String, Object?>>>().future;
    NativeCrashBridge.instance = bridge;
    final first = client(sessions: true);
    await WasmWatch.init(client: first);
    final currentSid = first.sessionTracker!.context!['id'] as String;
    final prefs = await SharedPreferences.getInstance();
    final killedState = {
      for (final key in prefs.getKeys()) key: prefs.get(key)!
    };
    await WasmWatch.close();
    // A process kill leaves storage exactly as it was during the wait.
    SharedPreferences.setMockInitialValues(killedState);
    final native = report()..['kind'] = 'native_crash';
    (native['scope'] as Map)['session_id'] = sid;
    bridge.onStart = null;
    bridge.reports = [native];
    final wires = <String>[];
    WasmWatchClient next() => client(
        sessions: true,
        send: (request) async {
          wires.add(request.body);
          return http.Response('', 200);
        });
    await WasmWatch.init(client: next());
    await settle();
    expect(sessionUpdates(wires, sid).single['status'], 'crashed');
    expect(sessionUpdates(wires, currentSid).single['status'], 'abnormal');
    expect(
        (await SharedPreferences.getInstance())
            .getString(SessionTracker.previousSessionsKey),
        isNull);
    await WasmWatch.init(client: next());
    await settle();
    expect(sessionUpdates(wires, sid), hasLength(1));
    expect(sessionUpdates(wires, currentSid), hasLength(1));
  });
  test(
      'durable storage acknowledges before a hung send, dedupes and never records a new session error',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final buffer = OfflineBuffer(SharedPreferencesStorage(prefs));
    final bridge = FakeBridge();
    final native = report();
    bridge.reports = [native, native];
    NativeCrashBridge.instance = bridge;
    final gate = Completer<http.Response>();
    var beforeSends = 0;
    final active = client(
        sessions: true,
        buffer: buffer,
        beforeSend: (event) {
          beforeSends++;
          expect(event.release, '2.1.0+57');
          return event;
        },
        send: (request) => request.body.contains('"type":"event"')
            ? gate.future
            : Future.value(http.Response('', 200)));
    await WasmWatch.init(client: active);
    await settle();
    expect(beforeSends, 1);
    expect(bridge.acknowledgements, [native['id']]);
    final entries = await buffer.pending();
    expect(entries, hasLength(1));
    expect(entries.single.envelope, contains('android_uncaught'));
    expect(
        jsonDecode(prefs.getString(SessionTracker.sessionKey)!)['errors'], 0);
    gate.complete(http.Response('', 200));
    await settle();
    expect(await buffer.pending(), isEmpty);
    await WasmWatch.init(client: active);
    await settle();
    expect(beforeSends, 1);
  });
  test('native recovery completing after close stays pending for a later init',
      () async {
    final gate = Completer<List<Map<String, Object?>>>();
    final native = report();
    final bridge = FakeBridge()..onStart = () => gate.future;
    NativeCrashBridge.instance = bridge;
    await WasmWatch.init(client: client());
    await WasmWatch.close();
    gate.complete([native]);
    await settle();
    expect(bridge.acknowledgements, isEmpty);
    bridge.onStart = null;
    bridge.reports = [native];
    await WasmWatch.init(client: client());
    await settle();
    expect(bridge.acknowledgements, [native['id']]);
  });
  test(
      'unknown reports are acked and recognized malformed reports are delivered',
      () async {
    final unknown = report()..['kind'] = 'unknown';
    final malformed = report()..['exception'] = {};
    final bridge = FakeBridge()..reports = [unknown, malformed];
    NativeCrashBridge.instance = bridge;
    final captured = <ErrorEvent>[];
    await WasmWatch.init(client: client(beforeSend: (event) {
      captured.add(event);
      return event;
    }));
    await settle();
    expect(captured.single.exceptionType, 'JavaCrash');
    expect(captured.single.release, malformed['release']);
    expect(bridge.acknowledgements, [unknown['id'], malformed['id']]);
  });
  test('conversion and beforeSend drops ack; delivery errors remain pending',
      () async {
    final bridge = FakeBridge();
    NativeCrashBridge.instance = bridge;
    final malformed = report()..['exception'] = {};
    final dropped = report();
    bridge.reports = [malformed, dropped];
    await WasmWatch.init(client: client(beforeSend: (_) => null));
    await settle();
    expect(bridge.acknowledgements, [malformed['id'], dropped['id']]);
    final failed = report();
    bridge.reports = [failed];
    await WasmWatch.init(
        client: client(send: (_) async => http.Response('', 500)));
    await settle();
    expect(bridge.acknowledgements, isNot(contains(failed['id'])));
  });
  for (final status in [200, 400, 413, 500]) {
    test('without buffer ack waits for send completion ($status)', () async {
      final bridge = FakeBridge()..reports = [report()];
      NativeCrashBridge.instance = bridge;
      final gate = Completer<http.Response>();
      await WasmWatch.init(client: client(send: (_) => gate.future));
      await settle();
      expect(bridge.acknowledgements, isEmpty);
      gate.complete(http.Response('', status));
      await settle();
      expect(bridge.acknowledgements.isNotEmpty, status < 500);
    });
  }
  for (final failedWrite in [false, true]) {
    test(
        'non-durable buffer entries require completed delivery (failed write=$failedWrite)',
        () async {
      final prefs = await SharedPreferences.getInstance();
      final buffer = failedWrite
          ? OfflineBuffer(FailingStorage())
          : OfflineBuffer(SharedPreferencesStorage(prefs), maximumBytes: 1);
      final bridge = FakeBridge()..reports = [report()];
      NativeCrashBridge.instance = bridge;
      final gate = Completer<http.Response>();
      await WasmWatch.init(
          client: client(buffer: buffer, send: (_) => gate.future));
      await settle();
      expect(bridge.acknowledgements, isEmpty);
      expect(await buffer.pending(), isEmpty);
      gate.complete(http.Response('', 500));
      await settle();
      expect(bridge.acknowledgements, isEmpty);
    });
  }
  test('prebuilt event delivery applies PII scrubbing and rate limiting',
      () async {
    final bridge = FakeBridge()..reports = [report()];
    ((bridge.reports.single['exception']) as Map)['message'] =
        'user@example.com';
    NativeCrashBridge.instance = bridge;
    final wires = <String>[];
    await WasmWatch.init(client: client(send: (request) async {
      wires.add(request.body);
      return http.Response('', 200);
    }));
    await settle();
    expect(wires.single, isNot(contains('user@example.com')));
    final config = WasmWatchOptions(
        dsn: 'http://key@localhost/v1/1',
        release: 'build',
        trackSessions: false,
        protectionBypass: false,
        autoInstallFlutterErrorHandlers: false,
        captureLifecycleBreadcrumbs: false);
    final limited = WasmWatchClient(config,
        rateLimiter: RateLimiter(maximumPerMinute: 0),
        transport:
            HttpTransport(config.parsedDsn, client: MockClient((_) async {
          fail('rate-limited event must not reach transport');
        })));
    final event = limited.nativeReportEvent(report())!;
    expect(await limited.capturePrebuiltEvent(event), true);
    limited.transport.close();
  });

  testWidgets(
      'scope writes serialize direct mutations, coalesce and retain the trailing update',
      (tester) async {
    debugDefaultTargetPlatformOverride = null;
    final bridge = FakeBridge();
    final scope = Scope();
    final gate = Completer<void>();
    bridge.onScope = (_) => gate.future;
    final sync = NativeScopeSync(
        bridge: bridge,
        scope: () => scope,
        sessionId: () => 'session',
        clock: tester.binding.clock.now,
        onError: (_, __) {});
    scope.onChanged = () => sync.update();
    sync.update(sessionBegin: true);
    expect(bridge.scopes, hasLength(1));
    scope.tags['direct'] = 'one';
    scope.user = const WasmWatchUser(id: 'user');
    scope.breadcrumbs.add(Breadcrumb(
        category: 'test', message: 'last', timestamp: DateTime.utc(2026)));
    scope.tags['direct'] = 'last';
    await tester.pump(const Duration(seconds: 2));
    expect(bridge.scopes, hasLength(1));
    gate.complete();
    await tester.pump();
    expect(bridge.scopes, hasLength(2));
    expect(bridge.scopes.last['tags'], {'direct': 'last'});
    expect(bridge.scopes.last['user'], {'id': 'user'});
    expect(
        bridge.scopes.last['breadcrumbs'], [scope.breadcrumbs.single.toJson()]);
    scope.tags.clear();
    await tester.pump(const Duration(milliseconds: 999));
    expect(bridge.scopes, hasLength(2));
    await tester.pump(const Duration(milliseconds: 1));
    expect(bridge.scopes, hasLength(3));
    sync.close();
  });
  testWidgets(
      'session begin is immediate; scope drops oldest breadcrumbs below 60 KiB',
      (tester) async {
    debugDefaultTargetPlatformOverride = null;
    final bridge = FakeBridge();
    final scope = Scope();
    for (var i = 0; i < 70; i++) {
      scope.breadcrumbs.add(Breadcrumb(
          category: 'test',
          message: '$i:${'界' * 1300}',
          timestamp: DateTime.utc(2026)));
    }
    var sid = 'first';
    final sync = NativeScopeSync(
        bridge: bridge,
        scope: () => scope,
        sessionId: () => sid,
        clock: tester.binding.clock.now,
        onError: (_, __) {});
    sync.update(sessionBegin: true);
    await tester.pump();
    final snapshot = bridge.scopes.single;
    expect(utf8.encode(jsonEncode(snapshot)).length, lessThan(60 * 1024));
    expect((snapshot['breadcrumbs'] as List).last['message'],
        scope.breadcrumbs.last.message);
    const mapping = String.fromEnvironment('WASMWATCH_ANDROID_MAPPING_ID');
    expect(snapshot['android_mapping_id'], mapping.isEmpty ? null : mapping);
    sid = 'second';
    sync.update(sessionBegin: true);
    await tester.pump();
    expect(bridge.scopes.last['session_id'], 'second');
    sync.close();
  });
  test('Hub observes user, tags, breadcrumbs and restores the parent scope',
      () async {
    final active = client();
    final hub = Hub(active);
    var changes = 0;
    hub.onScopeChanged = () => changes++;
    hub.scope.setTag('k', 'v');
    hub.scope.user = const WasmWatchUser(id: 'a');
    hub.scope.addBreadcrumb(const Breadcrumb(category: 'ui', message: 'x'));
    expect(changes, greaterThanOrEqualTo(3));
    await hub.withScope((scope) async {
      scope.tags['k'] = 'child';
    });
    expect(hub.scope.tags['k'], 'v');
    active.transport.close();
  });
}
