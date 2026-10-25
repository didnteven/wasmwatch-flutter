import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wasmwatch/wasmwatch.dart';
import 'offline_buffer_test.dart' show MemoryStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const options = WasmWatchOptions(
    dsn: 'http://key@localhost/api/v1/1',
    autoInstallFlutterErrorHandlers: false,
    captureLifecycleBreadcrumbs: false,
    capturePrintBreadcrumbs: false,
    trackSessions: false,
  );

  WasmWatchClient client(OfflineStorage storage,
      Future<http.Response> Function(http.Request) handler) {
    final transport = HttpTransport(options.parsedDsn,
        delay: (_) async {}, jitter: () => 0, client: MockClient(handler));
    addTearDown(transport.close);
    return WasmWatchClient(options,
        transport: transport, offlineBuffer: OfflineBuffer(storage));
  }

  test('a storage failure does not block delivery', () async {
    final delivered = <String>[];
    final live = client(_FailingStorage(), (request) async {
      delivered.add(request.body);
      return http.Response('', 202);
    });
    expect(await live.captureException(StateError('unpersisted')), isNotNull);
    expect(delivered, hasLength(1));
  });

  test('interrupted live send survives and is delivered once at the next init',
      () async {
    final storage = MemoryStorage();
    final started = Completer<String>();
    final first = client(storage, (request) {
      started.complete(request.body);
      return Completer<http.Response>().future;
    });
    unawaited(first.captureException(StateError('interrupted')));
    final envelope = await started.future;
    expect((await OfflineBuffer(storage).pending()).single.envelope, envelope);

    final delivered = <String>[];
    final restarted = client(storage, (request) async {
      delivered.add(request.body);
      return http.Response('', 202);
    });
    addTearDown(WasmWatch.close);
    await WasmWatch.init(options: options, client: restarted);
    await restarted.flushOffline();
    expect(delivered, [envelope]);
    expect(await restarted.offlineBuffer!.pending(), isEmpty);
  });

  test('interrupted replay stays persisted until the next init acknowledges it',
      () async {
    final storage = MemoryStorage();
    await OfflineBuffer(storage).store('interrupted replay');
    final started = Completer<void>();
    final first = client(storage, (request) {
      started.complete();
      return Completer<http.Response>().future;
    });
    unawaited(first.flushOffline());
    await started.future;

    final delivered = <String>[];
    final restarted = client(storage, (request) async {
      delivered.add(request.body);
      return http.Response('', 200);
    });
    addTearDown(WasmWatch.close);
    await WasmWatch.init(options: options, client: restarted);
    await restarted.flushOffline();
    expect(delivered, ['interrupted replay']);
    expect(await restarted.offlineBuffer!.pending(), isEmpty);
  });

  for (final status in [200, 202, 204, 400, 413]) {
    test('$status removes the live entry and never replays it', () async {
      final storage = MemoryStorage();
      var calls = 0;
      final active = client(storage, (request) async {
        calls++;
        expect((await OfflineBuffer(storage).pending()).single.envelope,
            request.body);
        return http.Response('', status);
      });
      expect(await active.captureException(StateError('status $status')),
          isNotNull);
      expect(await active.offlineBuffer!.pending(), isEmpty);
      final restarted = client(storage, (_) async {
        calls++;
        return http.Response('', 200);
      });
      await restarted.flushOffline();
      expect(calls, 1);
    });

    test('$status removes a replayed entry', () async {
      final storage = MemoryStorage();
      await OfflineBuffer(storage).store('replayed');
      var calls = 0;
      final active = client(storage, (_) async {
        calls++;
        return http.Response('', status);
      });
      await active.flushOffline();
      await active.flushOffline();
      expect(await active.offlineBuffer!.pending(), isEmpty);
      expect(calls, 1);
    });
  }

  test('concurrent flushes do not duplicate an online send', () async {
    final storage = MemoryStorage();
    final started = Completer<void>();
    final release = Completer<http.Response>();
    var calls = 0;
    final active = client(storage, (_) {
      calls++;
      started.complete();
      return release.future;
    });
    final capture = active.captureException(StateError('online'));
    await started.future;
    final flush = active.flushOffline();
    final anotherFlush = active.flushOffline();
    release.complete(http.Response('', 200));
    await Future.wait([capture, flush, anotherFlush]);
    expect(calls, 1);
    expect(await active.offlineBuffer!.pending(), isEmpty);
  });

  for (final status in [429, 500]) {
    test('$status remains persisted and replays after restart', () async {
      final storage = MemoryStorage();
      String? envelope;
      final first = client(storage, (request) async {
        envelope = request.body;
        return http.Response('', status);
      });
      await first.captureException(StateError('temporary $status'));
      expect((await first.offlineBuffer!.pending()).single.envelope, envelope);
      final delivered = <String>[];
      final restarted = client(storage, (request) async {
        delivered.add(request.body);
        return http.Response('', 200);
      });
      await restarted.flushOffline();
      expect(delivered, [envelope]);
      expect(await restarted.offlineBuffer!.pending(), isEmpty);
    });
  }
}

class _FailingStorage implements OfflineStorage {
  @override
  Future<List<String>?> read(String key) async => null;
  @override
  Future<bool> write(String key, List<String> value) async => false;
  @override
  Future<bool> remove(String key) async => false;
}
