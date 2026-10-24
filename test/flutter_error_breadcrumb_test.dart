// The test exercises print() capture, so it prints on purpose.
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final throws in [false, true]) {
    test(
        'Flutter report prints are suppressed and printing is restored (throws: $throws)',
        () async {
      final previous = FlutterError.onError;
      final events = <ErrorEvent>[];
      final printed = <String>[];
      final previousDebugPrint = debugPrint;
      final downstreamError = StateError('previous handler failed');
      FlutterError.onError = (_) {
        for (var i = 0; i < 60; i++) {
          print('report line $i');
        }
        scheduleMicrotask(() => print('deferred report line'));
        if (throws) throw downstreamError;
      };
      final client = WasmWatchClient(WasmWatchOptions(
        dsn: 'http://key@localhost/api/v1/1',
        sendDefaultContext: false,
        capturePrintBreadcrumbs: true,
        beforeSend: (event) {
          events.add(event);
          return null;
        },
      ));
      try {
        await runZoned(
            () => WasmWatch.init(
                  client: client,
                  appRunner: () async {
                    print('earlier console breadcrumb');
                    final details = FlutterErrorDetails(
                      exception: StateError('first line\nsecond line'),
                      stack: StackTrace.fromString(
                          '#0 f (package:app/main.dart:1)'),
                    );
                    if (throws) {
                      expect(() => FlutterError.onError!(details),
                          throwsA(same(downstreamError)));
                    } else {
                      FlutterError.onError!(details);
                    }
                    print('outside handler');
                    await Future<void>.delayed(Duration.zero);
                  },
                ),
            zoneSpecification: ZoneSpecification(
              print: (_, __, ___, line) => printed.add(line),
            ));
        expect(identical(debugPrint, previousDebugPrint), true);
        expect(events, hasLength(1));
        expect(events.single.breadcrumbs.map((b) => b.category),
            ['console', 'flutter.error']);
        final errorCrumb = events.single.breadcrumbs.last;
        expect(errorCrumb.level, SeverityLevel.error);
        expect(errorCrumb.message, 'StateError: Bad state: first line');
        final breadcrumbs = WasmWatch.hub.scope.breadcrumbs;
        expect(breadcrumbs.map((b) => b.message), [
          'earlier console breadcrumb',
          'StateError: Bad state: first line',
          'outside handler',
        ]);
        expect(breadcrumbs.where((b) => b.category == 'flutter.error'),
            hasLength(1));
        expect(printed.where((line) => line.startsWith('report line')),
            hasLength(60));
        expect(printed, contains('deferred report line'));
      } finally {
        await WasmWatch.close();
        FlutterError.onError = previous;
      }
    });
  }

  for (final pending in [false, true]) {
    test('debugPrint reports stay suppressed with pending throttle: $pending',
        () async {
      final previous = FlutterError.onError;
      final previousDebugPrint = debugPrint;
      final printed = <String>[];
      debugPrint = debugPrintThrottled;
      FlutterError.onError = (_) {
        debugPrint('report ${'x' * (13 * 1024)}');
        debugPrint('report final line');
      };
      final client = WasmWatchClient(WasmWatchOptions(
        dsn: 'http://key@localhost/api/v1/1',
        sendDefaultContext: false,
        capturePrintBreadcrumbs: true,
        beforeSend: (_) => null,
      ));
      try {
        await runZoned(
            () => WasmWatch.init(
                  client: client,
                  appRunner: () async {
                    if (pending) {
                      debugPrint('earlier ${'x' * (13 * 1024)}');
                      debugPrint('pending before error');
                    }
                    FlutterError.onError!(FlutterErrorDetails(
                      exception: StateError('failure'),
                      stack: StackTrace.current,
                    ));
                    expect(identical(debugPrint, debugPrintThrottled), true);
                    // The report bypasses the existing throttle buffer.
                    expect(printed, contains('report final line'));
                    await debugPrintDone;
                    debugPrint('after restore');
                    await debugPrintDone;
                  },
                ),
            zoneSpecification: ZoneSpecification(
              print: (_, __, ___, line) => printed.add(line),
            ));
        final messages = WasmWatch.hub.scope.breadcrumbs.map((b) => b.message);
        expect(messages.where((message) => message?.startsWith('report') ?? false),
            isEmpty);
        if (pending) expect(messages, contains('pending before error'));
        expect(messages, contains('after restore'));
        expect(printed, contains('report final line'));
      } finally {
        await debugPrintDone;
        await WasmWatch.close();
        FlutterError.onError = previous;
        debugPrint = previousDebugPrint;
      }
    });
  }

  test('Flutter error breadcrumb message is limited to 200 characters',
      () async {
    final previous = FlutterError.onError;
    FlutterError.onError = (_) {};
    final events = <ErrorEvent>[];
    final client = WasmWatchClient(WasmWatchOptions(
      dsn: 'http://key@localhost/api/v1/1',
      sendDefaultContext: false,
      beforeSend: (event) {
        events.add(event);
        return null;
      },
    ));
    try {
      await WasmWatch.init(client: client);
      FlutterError.onError!(FlutterErrorDetails(
        exception: FlutterError('${'x' * 250}\nsecond line'),
        stack: StackTrace.current,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(events.single.breadcrumbs, hasLength(1));
      expect(events.single.breadcrumbs.single.message,
          'FlutterError: ${'x' * 186}');
    } finally {
      await WasmWatch.close();
      FlutterError.onError = previous;
    }
  });
}
