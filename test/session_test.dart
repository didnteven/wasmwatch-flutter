import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasmwatch/src/session.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() async {
    await WasmWatch.close();
    debugDefaultTargetPlatformOverride = null;
  });

  test('sessions default to mobile and explicit options survive resolution',
      () {
    const options = WasmWatchOptions(dsn: 'http://key@localhost/v1/1');
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(options.resolved().trackSessions,
          platform == TargetPlatform.android || platform == TargetPlatform.iOS);
      expect(
          const WasmWatchOptions(dsn: '', trackSessions: false)
              .resolved()
              .trackSessions,
          false);
      expect(
          const WasmWatchOptions(dsn: '', trackSessions: true)
              .resolved()
              .trackSessions,
          true);
    }
  });

  testWidgets(
      'background timeout rolls the session, short interruptions retain it',
      (tester) async {
    var now = DateTime.utc(2026);
    final updates = <Map<String, Object?>>[];
    final tracker = SessionTracker(
      release: '1.0',
      environment: 'test',
      platform: 'dart-ios',
      preferences: await SharedPreferences.getInstance(),
      clock: () => now,
      onUpdate: (update) async => updates.add(update),
    );
    await tracker.start();
    final first = tracker.context!['id'];
    await tracker.didChangeAppLifecycleState(AppLifecycleState.inactive);
    now = now.add(const Duration(seconds: 40));
    await tester.pump(const Duration(seconds: 40));
    expect(tracker.context!['id'], first);
    await tracker.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tracker.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 29));
    await tester.pump(const Duration(seconds: 29));
    await tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(tracker.context!['id'], first);
    await tracker.recordError();
    await tracker.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    await tracker.pending;
    expect(tracker.context, isNull);
    expect(updates.last['sid'], first);
    expect(updates.last['status'], 'errored');
    expect(updates.last['errors'], 1);
    await tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(tracker.context!['id'], isNot(first));
    expect(updates.last['init'], true);
    expect(updates.last['errors'], 0);
    await tracker.close();
    expect(updates.last['status'], 'exited');
    final count = updates.length;
    await tracker.close();
    expect(updates, hasLength(count));
  });

  testWidgets(
      'resume expires a session even when background timers were suspended',
      (tester) async {
    var now = DateTime.utc(2026);
    final updates = <Map<String, Object?>>[];
    final tracker = SessionTracker(
      release: '1.0',
      environment: 'test',
      platform: 'dart-android',
      clock: () => now,
      onUpdate: (update) async => updates.add(update),
    );
    await tracker.start();
    await tracker.didChangeAppLifecycleState(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 2));
    await tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(updates.map((s) => s['status']), ['ok', 'exited', 'ok']);
    expect(updates[1]['timestamp'],
        DateTime.utc(2026, 1, 1, 0, 0, 30).toIso8601String());
    await tracker.close();
  });

  test(
      'crash-restart reports abnormal with original attrs, errors and install ID',
      () async {
    final preferences = await SharedPreferences.getInstance();
    var now = DateTime.utc(2026);
    final updates = <Map<String, Object?>>[];
    SessionTracker tracker(String release) => SessionTracker(
          release: release,
          environment: 'test',
          platform: 'dart-ios',
          clock: () => now,
          preferences: preferences,
          onUpdate: (update) async => updates.add(update),
        );
    final first = tracker('old');
    await first.start();
    final sid = first.context!['id'];
    final did = preferences.getString(SessionTracker.installIdKey);
    expect(
        did,
        matches(RegExp(
            r'^[\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}$')));
    expect(did, isNot(sid));
    await first.recordError();
    await first.recordError();
    final persisted =
        jsonDecode(preferences.getString(SessionTracker.sessionKey)!);
    expect(persisted['errors'], 2);
    expect(persisted['status'], 'ok');
    final timestamp = DateTime.parse(persisted['timestamp'] as String);
    now = now.subtract(const Duration(minutes: 1));
    // Discard the first tracker without close(), as when the process is killed.
    final restarted = tracker('new');
    await restarted.start();
    final abnormal = updates[1];
    expect(abnormal['sid'], sid);
    expect(abnormal['did'], did);
    expect(abnormal['init'], false);
    expect(abnormal['status'], 'abnormal');
    expect(abnormal['errors'], 2);
    expect(abnormal['attrs'], {'release': 'old', 'environment': 'test'});
    expect(DateTime.parse(abnormal['timestamp'] as String).isAfter(timestamp),
        true);
    expect(updates.last['did'], did);
    expect(updates.last['sid'], isNot(sid));
    await restarted.close();
    updates.clear();
    final third = tracker('new');
    await third.start();
    expect(updates.map((s) => s['status']), ['ok']);
    await third.close();
  });

  test(
      'an OS kill while backgrounded ends the session at background time, not as a crash',
      () async {
    final preferences = await SharedPreferences.getInstance();
    var now = DateTime.utc(2026);
    final updates = <Map<String, Object?>>[];
    SessionTracker tracker() => SessionTracker(
          release: '1',
          environment: 'test',
          platform: 'dart-ios',
          clock: () => now,
          preferences: preferences,
          onUpdate: (update) async => updates.add(update),
        );
    for (final errors in [0, 1]) {
      updates.clear();
      final first = tracker();
      await first.start();
      final sid = first.context!['id'];
      for (var i = 0; i < errors; i++) {
        await first.recordError();
      }
      now = now.add(const Duration(seconds: 5));
      final backgroundAt = now;
      await first.didChangeAppLifecycleState(AppLifecycleState.paused);
      await first.pending;
      // iOS suspends the app, so the 30 s end timer never fires before the OS kills it.
      now = now.add(const Duration(hours: 3));
      final restarted = tracker();
      await restarted.start();
      final ended =
          updates.firstWhere((u) => u['sid'] == sid && u['status'] != 'ok');
      expect(ended['status'], errors > 0 ? 'errored' : 'exited');
      expect(ended['timestamp'], backgroundAt.toIso8601String());
      expect(preferences.getString(SessionTracker.backgroundKey), isNull);
      // The resumed-then-killed case still counts as abnormal.
      await restarted.didChangeAppLifecycleState(AppLifecycleState.paused);
      await restarted.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await restarted.pending;
      final killed = restarted.context!['id'];
      updates.clear();
      final third = tracker();
      await third.start();
      expect(
          updates.firstWhere((u) => u['sid'] == killed)['status'], 'abnormal');
      await third.close();
      await preferences.remove(SessionTracker.sessionKey);
    }
  });

  test('a failed send does not stall later session updates or captures',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final updates = <Map<String, Object?>>[];
    var fail = true;
    final tracker = SessionTracker(
      release: '1',
      environment: 'test',
      platform: 'dart-ios',
      preferences: preferences,
      onUpdate: (update) async {
        if (fail) throw StateError('send failed');
        updates.add(update);
      },
    );
    await tracker.start();
    fail = false;
    expect((await tracker.recordError())!['errors'], 1);
    await tracker.close();
    expect(updates.map((u) => u['status']), ['errored']);
    expect(
        jsonDecode(preferences.getString(SessionTracker.sessionKey)!)['status'],
        'errored');
  });

  const options = WasmWatchOptions(
    dsn: 'http://key@localhost/v1/1',
    release: '1.0',
    environment: 'test',
    trackSessions: true,
    captureLifecycleBreadcrumbs: false,
    capturePrintBreadcrumbs: false,
    autoInstallFlutterErrorHandlers: false,
  );

  Future<WasmWatchClient> client(
      Future<http.Response> Function(http.Request) handler,
      {WasmWatchOptions config = options}) async {
    final preferences = await SharedPreferences.getInstance();
    final transport = HttpTransport(config.parsedDsn,
        maxRetries: 0, client: MockClient(handler));
    addTearDown(transport.close);
    return WasmWatchClient(config,
        transport: transport,
        offlineBuffer: OfflineBuffer(SharedPreferencesStorage(preferences)));
  }

  test(
      'handled and unhandled events share sid and increment the persisted counter',
      () async {
    final delivered = <List<dynamic>>[];
    final active = await client((request) async {
      delivered
          .add(request.body.trimRight().split('\n').map(jsonDecode).toList());
      return http.Response('', 200);
    });
    await WasmWatch.init(client: active);
    for (final handled in [true, false]) {
      await active
          .captureException(StateError('handled: $handled'), mechanism: {
        'type': 'test',
        'handled': handled
      }, contexts: {
        'device': {
          'model': 'custom',
          'session': {'id': 'override'}
        }
      });
    }
    final events = delivered.where((r) => r.length == 5).toList();
    expect(events, hasLength(2));
    for (var i = 0; i < events.length; i++) {
      final records = events[i];
      expect(records[1]['type'], 'event');
      expect(records[3]['type'], 'session');
      expect(records[3]['length'], utf8.encode(jsonEncode(records[4])).length);
      expect(records[2]['contexts']['session']['id'], records[4]['sid']);
      expect(
          records[2]['contexts']['device']['session']['id'], records[4]['sid']);
      expect(records[2]['contexts']['device']['model'], 'custom');
      expect(records[4]['errors'], i + 1);
      expect(records[4]['status'], 'ok');
    }
    final preferences = await SharedPreferences.getInstance();
    expect(
        jsonDecode(preferences.getString(SessionTracker.sessionKey)!)['errors'],
        2);
    await WasmWatch.close();
    expect(
        jsonDecode(preferences.getString(SessionTracker.sessionKey)!)['status'],
        'errored');
  });

  test(
      'session-only update survives a hung send and replays from the offline buffer',
      () async {
    final started = Completer<String>();
    final first = await client((request) {
      started.complete(request.body);
      return Completer<http.Response>().future;
    });
    final tracker = SessionTracker(
      release: '1',
      environment: 'test',
      platform: 'dart-ios',
      onUpdate: first.sendSession,
    );
    await tracker.start();
    final wire = await started.future;
    expect(jsonDecode(wire.split('\n')[1])['type'], 'session');
    expect(jsonDecode(wire.split('\n')[0]).containsKey('event_id'), false);
    expect((await first.offlineBuffer!.pending()).single.envelope, wire);
    final delivered = <String>[];
    final restarted = await client((request) async {
      delivered.add(request.body);
      return http.Response('', 200);
    });
    await restarted.flushOffline();
    expect(delivered, [wire]);
    expect(await restarted.offlineBuffer!.pending(), isEmpty);
  });

  testWidgets('the SDK observes sessions with lifecycle breadcrumbs disabled',
      (tester) async {
    var now = DateTime.utc(2026);
    final preferences = await SharedPreferences.getInstance();
    final transport = HttpTransport(options.parsedDsn,
        client: MockClient((_) async => http.Response('', 200)));
    final active = WasmWatchClient(options,
        clock: () => now,
        transport: transport,
        offlineBuffer: OfflineBuffer(SharedPreferencesStorage(preferences)));
    await WasmWatch.init(client: active);
    final sid = active.sessionTracker!.context!['id'];
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    await active.sessionTracker!.pending;
    expect(active.sessionTracker!.context, isNull);
    expect(
        jsonDecode(preferences.getString(SessionTracker.sessionKey)!)['status'],
        'exited');
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await active.sessionTracker!.pending;
    expect(active.sessionTracker!.context!['id'], isNot(sid));
    expect(active.hub!.scope.breadcrumbs, isEmpty);
    await WasmWatch.close();
  });

  testWidgets(
      'a delayed beforeSend keeps the event and its session update aligned',
      (tester) async {
    var now = DateTime.utc(2026);
    final gate = Completer<ErrorEvent?>();
    late ErrorEvent captured;
    final delivered = <List<dynamic>>[];
    final config = WasmWatchOptions(
      dsn: options.dsn,
      trackSessions: true,
      autoInstallFlutterErrorHandlers: false,
      captureLifecycleBreadcrumbs: false,
      beforeSend: (event) {
        captured = event;
        return gate.future;
      },
    );
    final preferences = await SharedPreferences.getInstance();
    final active = WasmWatchClient(config,
        clock: () => now,
        offlineBuffer: OfflineBuffer(SharedPreferencesStorage(preferences)),
        transport:
            HttpTransport(config.parsedDsn, client: MockClient((request) async {
          delivered.add(
              request.body.trimRight().split('\n').map(jsonDecode).toList());
          return http.Response('', 200);
        })));
    await WasmWatch.init(client: active);
    final previousSid = active.sessionTracker!.context!['id'];
    final capture = active.captureException(StateError('delayed'));
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    await active.sessionTracker!.pending;
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await active.sessionTracker!.pending;
    gate.complete(captured);
    await capture;
    final records = delivered.singleWhere((r) => r.length == 5);
    expect(records[4]['sid'], isNot(previousSid));
    expect(records[4]['errors'], 1);
    expect(records[2]['contexts']['session']['id'], records[4]['sid']);
    expect(
        records[2]['contexts']['device']['session']['id'], records[4]['sid']);
    await WasmWatch.close();
  });

  test(
      'an event and session persist together before a hung send and replay once',
      () async {
    final started = Completer<String>();
    final first = await client((request) {
      if (request.body.trimRight().split('\n').length == 3)
        return Future.value(http.Response('', 200));
      started.complete(request.body);
      return Completer<http.Response>().future;
    });
    await WasmWatch.init(client: first);
    unawaited(first.captureException(StateError('interrupted')));
    final wire = await started.future;
    final records = wire.trimRight().split('\n').map(jsonDecode).toList();
    expect(records[1]['type'], 'event');
    expect(records[3]['type'], 'session');
    expect(records[4]['errors'], 1);
    expect((await first.offlineBuffer!.pending()).single.envelope, wire);
    final delivered = <String>[];
    final restarted = await client((request) async {
      delivered.add(request.body);
      return http.Response('', 202);
    });
    await restarted.flushOffline();
    await restarted.flushOffline();
    expect(delivered, [wire]);
    expect(await restarted.offlineBuffer!.pending(), isEmpty);
  });

  test('opting out creates no persisted session or install identifier',
      () async {
    final delivered = <String>[];
    final active = await client((request) async {
      delivered.add(request.body);
      return http.Response('', 200);
    },
        config: const WasmWatchOptions(
            dsn: 'http://key@localhost/v1/1', trackSessions: false));
    await WasmWatch.init(client: active);
    await active.captureException(StateError('untracked'));
    await WasmWatch.close();
    expect(delivered, hasLength(1));
    expect(delivered.single.trimRight().split('\n'), hasLength(3));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(SessionTracker.sessionKey), isNull);
    expect(preferences.getString(SessionTracker.installIdKey), isNull);
  });

  for (final status in [200, 400, 413, 500]) {
    test(
        'session updates use existing offline acknowledgement rules for $status',
        () async {
      final completed = Completer<void>();
      late WasmWatchClient active;
      active = await client((request) async {
        expect(
            (await active.offlineBuffer!.pending())
                .any((e) => e.envelope == request.body),
            true);
        completed.complete();
        return http.Response('', status);
      });
      final tracker = SessionTracker(
        release: '1',
        environment: 'test',
        platform: 'dart-ios',
        onUpdate: active.sendSession,
      );
      await tracker.start();
      await completed.future;
      await Future<void>.delayed(Duration.zero);
      expect((await active.offlineBuffer!.pending()).isEmpty, status < 500);
    });
  }
}
