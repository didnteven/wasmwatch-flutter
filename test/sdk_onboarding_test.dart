// print() interception is the behavior under test.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';

const dsn = 'https://key@example.com/v1/project';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(WasmWatch.close);

  WasmWatchClient makeClient(
    List<ErrorEvent> events, {
    int maximum = 50,
    bool breadcrumbs = true,
    bool handlers = true,
  }) =>
      WasmWatchClient(
        WasmWatchOptions(
          dsn: dsn,
          maxBreadcrumbs: maximum,
          capturePrintBreadcrumbs: breadcrumbs,
          captureLifecycleBreadcrumbs: breadcrumbs,
          captureNavigationBreadcrumbs: breadcrumbs,
          autoInstallFlutterErrorHandlers: handlers,
          beforeSend: (event) {
            events.add(event);
            return null;
          },
        ),
      );

  test(
    'appRunner installs handlers and captures an uncaught async error',
    () async {
      final events = <ErrorEvent>[];
      final client = makeClient(events);
      final outerZone = Zone.current;
      final captured = Completer<void>();
      client.options = WasmWatchOptions(
        dsn: dsn,
        beforeSend: (event) {
          events.add(event);
          captured.complete();
          return null;
        },
      );
      final previousFlutter = FlutterError.onError;
      final previousPlatform = PlatformDispatcher.instance.onError;
      await WasmWatch.init(
        dsn: dsn,
        client: client,
        appRunner: () {
          expect(Zone.current, isNot(same(outerZone)));
          expect(WidgetsBinding.instance, isNotNull);
          expect(FlutterError.onError, isNot(same(previousFlutter)));
          expect(
            PlatformDispatcher.instance.onError,
            isNot(same(previousPlatform)),
          );
          scheduleMicrotask(
            () => throw StateError('uncaught onboarding error'),
          );
        },
      );
      await captured.future.timeout(const Duration(seconds: 2));
      expect(
        events.single.exceptionValue,
        contains('uncaught onboarding error'),
      );
      expect(events.single.environment, 'debug');
      expect(events.single.release, isNull);
    },
  );

  test('explicit metadata reaches emitted events', () async {
    final events = <ErrorEvent>[];
    await WasmWatch.init(
      client: makeClient(events),
      release: '1.2+3',
      environment: 'staging',
      appRunner: () async {
        await WasmWatch.captureException(StateError('metadata'));
      },
    );
    expect(events.single.release, '1.2+3');
    expect(events.single.environment, 'staging');
  });

  test(
    'print, lifecycle and navigation retain the latest bounded breadcrumbs',
    () async {
      final events = <ErrorEvent>[];
      await WasmWatch.init(
        client: makeClient(events, maximum: 2),
        appRunner: () async {
          print('first');
          print('second');
          WidgetsBinding.instance.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          WasmWatchNavigatorObserver().didPush(
            PageRouteBuilder<void>(
              settings: const RouteSettings(name: '/checkout'),
              pageBuilder: (_, __, ___) => const SizedBox(),
            ),
            null,
          );
          await WasmWatch.captureException(StateError('breadcrumbs'));
        },
      );
      expect(events.single.breadcrumbs.map((b) => b.category), [
        'app.lifecycle',
        'navigation',
      ]);
      expect(events.single.breadcrumbs.last.message, '/checkout');
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
    },
  );

  test('print is captured and still forwarded to the parent zone', () async {
    final events = <ErrorEvent>[];
    final output = <String>[];
    await runZoned(
      () => WasmWatch.init(
        client: makeClient(events),
        appRunner: () async {
          print('visible output');
          await WasmWatch.captureException(StateError('print'));
        },
      ),
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => output.add(line),
      ),
    );
    expect(output, contains('visible output'));
    expect(events.single.breadcrumbs.single.message, 'visible output');
  });

  test('automatic integrations can be disabled', () async {
    final previous = FlutterError.onError;
    final events = <ErrorEvent>[];
    await WasmWatch.init(
      client: makeClient(events, breadcrumbs: false, handlers: false),
      appRunner: () {
        print('disabled');
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      },
    );
    expect(FlutterError.onError, same(previous));
    expect(WasmWatch.hub.scope.breadcrumbs, isEmpty);
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  test(
    're-init captures once, chains once, and close restores previous handlers',
    () async {
      final events = <ErrorEvent>[];
      final client = makeClient(events);
      final originalFlutter = FlutterError.onError;
      final originalPlatform = PlatformDispatcher.instance.onError;
      var frameworkCalls = 0;
      var platformCalls = 0;
      void framework(FlutterErrorDetails _) {
        frameworkCalls++;
      }

      bool platform(Object _, StackTrace __) {
        platformCalls++;
        return false;
      }

      FlutterError.onError = framework;
      PlatformDispatcher.instance.onError = platform;
      addTearDown(() {
        FlutterError.onError = originalFlutter;
        PlatformDispatcher.instance.onError = originalPlatform;
      });
      await WasmWatch.init(client: client);
      await WasmWatch.init(client: client);
      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('framework')),
      );
      expect(
        PlatformDispatcher.instance.onError!(
          StateError('platform'),
          StackTrace.current,
        ),
        false,
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      expect(frameworkCalls, 1);
      expect(platformCalls, 1);
      await WasmWatch.close();
      expect(FlutterError.onError, same(framework));
      expect(PlatformDispatcher.instance.onError, same(platform));
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await WasmWatch.close();
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
    },
  );

  test('invalid explicit DSN gives a clear argument error', () async {
    await expectLater(WasmWatch.init(dsn: 'invalid'), throwsArgumentError);
  });

  test('missing DSN warns and still runs the application', () async {
    var ran = false;
    final messages = <String>[];
    await runZoned(
      () => WasmWatch.init(
        appRunner: () {
          ran = true;
        },
      ),
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => messages.add(line),
      ),
    );
    expect(ran, true);
    expect(WasmWatch.isInitialized, false);
    expect(messages.join(), contains('no DSN configured'));
  });
}
