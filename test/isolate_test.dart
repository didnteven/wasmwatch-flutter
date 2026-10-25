import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/src/integrations/isolate_error.dart';
import 'package:wasmwatch/wasmwatch.dart';

class WorkerFailure implements Exception {
  const WorkerFailure(this.message);
  final String message;
  @override
  String toString() => 'worker failed: $message';
}

void failWorker(String message) => throw WorkerFailure(message);

void failAsyncWorker(String message) {
  Future<void>.delayed(Duration.zero, () => failWorker(message));
}

void successfulWorker(SendPort result) => result.send('done');

// A separate VM isolate lets an actual uncaught error reach addErrorListener
// without also failing flutter_test's own error zone. Keep it alive long enough
// for its current-isolate listener to process the VM's serialized error.
void currentIsolateWorker((SendPort, bool, bool) arguments) {
  final (result, duplicate, platformFirst) = arguments;
  Isolate.current.setErrorsFatal(false);
  final events = <Map<String, Object?>>[];
  final client = WasmWatchClient(WasmWatchOptions(
    dsn: 'https://key@example.com/v1/project',
    sendDefaultContext: false,
    protectionBypass: true,
    beforeSend: (event) {
      events.add(event.toJson(scrubPii: false));
      return null;
    },
  ));
  final isolates = IsolateErrorIntegration()..install(client);
  final flutter = FlutterErrorIntegration()..install(client);
  Object? failure;
  StackTrace? trace;
  Timer.run(() {
    try {
      failWorker('current isolate');
    } catch (error, stack) {
      failure = error;
      trace = stack;
      if (duplicate && platformFirst) {
        PlatformDispatcher.instance.onError!(error, stack);
      }
      Error.throwWithStackTrace(error, stack);
    }
  });
  // Wait for the VM's actual error notification, then allow both listeners to
  // process it before checking the second delivery path and returning events.
  final observed = RawReceivePort();
  observed.handler = (_) {
    Timer.run(() {
      if (duplicate && !platformFirst) {
        PlatformDispatcher.instance.onError!(failure!, trace!);
      }
      isolates.close();
      flutter.close();
      Isolate.current.removeErrorListener(observed.sendPort);
      observed.close();
      Isolate.exit(result, events);
    });
  };
  Isolate.current.addErrorListener(observed.sendPort);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(WasmWatch.close);

  Future<(List<ErrorEvent>, Future<ErrorEvent>)> initialize() async {
    final events = <ErrorEvent>[];
    final captured = Completer<ErrorEvent>();
    await WasmWatch.init(
      client: WasmWatchClient(WasmWatchOptions(
        dsn: 'https://key@example.com/v1/project',
        beforeSend: (event) {
          events.add(event);
          if (!captured.isCompleted) captured.complete(event);
          return null;
        },
      )),
    );
    return (events, captured.future);
  }

  for (final async in [false, true]) {
    test('spawn preserves ${async ? 'async' : 'sync'} type, message and stack',
        () async {
      final (events, captured) = await initialize();
      final worker = await WasmWatch.spawn(
          async ? failAsyncWorker : failWorker, 'background request');
      addTearDown(() => worker.kill(priority: Isolate.immediate));
      final event = await captured.timeout(const Duration(seconds: 5));
      expect(event.exceptionType, 'WorkerFailure');
      expect(event.exceptionValue, 'worker failed: background request');
      expect(event.frames.first.rawLine, contains('failWorker'));
      expect(event.frames.first.rawLine, contains('isolate_test.dart:'));
      expect(event.mechanism, {'type': 'isolate', 'handled': false});
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
    });
  }

  test('spawn passes the message and returns an isolate on success', () async {
    final (events, _) = await initialize();
    final result = ReceivePort();
    addTearDown(result.close);
    final worker = await WasmWatch.spawn(successfulWorker, result.sendPort);
    addTearDown(() => worker.kill(priority: Isolate.immediate));
    expect(await result.first.timeout(const Duration(seconds: 5)), 'done');
    expect(events, isEmpty);
  });

  test('manual onError port captures a real isolate failure as RemoteError',
      () async {
    final (events, captured) = await initialize();
    final worker = await Isolate.spawn(failWorker, 'manual',
        onError: WasmWatch.isolateErrorPort());
    addTearDown(() => worker.kill(priority: Isolate.immediate));
    final event = await captured.timeout(const Duration(seconds: 5));
    expect(event.exceptionType, 'RemoteError');
    expect(event.exceptionValue, 'worker failed: manual');
    expect(event.frames.first.rawLine, contains('failWorker'));
    expect(event.mechanism, {'type': 'isolate', 'handled': false});
    expect(events, hasLength(1));
  });

  test('close and re-init replace ports and remove the old receiver', () async {
    final (oldEvents, _) = await initialize();
    final oldPort = WasmWatch.isolateErrorPort();
    final (events, captured) = await initialize();
    expect(WasmWatch.isolateErrorPort(), isNot(oldPort));
    oldPort.send(['old error', 'old stack']);
    final worker = await WasmWatch.spawn(failWorker, 'new client');
    addTearDown(() => worker.kill(priority: Isolate.immediate));
    await captured.timeout(const Duration(seconds: 5));
    expect(oldEvents, isEmpty);
    expect(events, hasLength(1));
    await WasmWatch.close();
    expect(WasmWatch.isolateErrorPort, throwsStateError);
    expect(() => WasmWatch.spawn(failWorker, 'closed'), throwsStateError);
  });

  for (final duplicate in [false, true]) {
    for (final platformFirst in duplicate ? [false, true] : [false]) {
      test(
          'real current-isolate listener captures once '
          '(dispatcher: $duplicate, platform first: $platformFirst)', () async {
        final result = ReceivePort();
        addTearDown(result.close);
        final worker = await Isolate.spawn(
            currentIsolateWorker, (result.sendPort, duplicate, platformFirst),
            onError: result.sendPort);
        addTearDown(() => worker.kill(priority: Isolate.immediate));
        final events = await result
            .firstWhere((message) => !(message is List &&
                message.isNotEmpty &&
                message.first == 'worker failed: current isolate'))
            .timeout(const Duration(seconds: 5));
        expect(events, isA<List>());
        expect(events, hasLength(1));
        final exception = (events as List).single['exception']['values'][0];
        expect(exception['value'], 'worker failed: current isolate');
        expect(exception['mechanism'], {
          'type': platformFirst ? 'platform_dispatcher' : 'isolate',
          'handled': false,
        });
      });
    }
  }
}
