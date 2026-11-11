import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wasmwatch/src/grouping/normalize.dart' show normalizeMessage;
import 'package:wasmwatch/wasmwatch.dart';

import '../example/dio_interceptor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('failure message templates the sanitized URL', () {
    const error = HttpRequestException(
        'GET', 'https://u:p@api.zeil.com/logo-search/123?q=secret#x',
        statusCode: 503);
    expect(error.toString(),
        'HttpRequestException: GET https://api.zeil.com/logo-search/{id} returned 503');
  });

  for (final custom in [false, true]) {
    test('capture retains concrete request context; custom template=$custom',
        () async {
      final events = <ErrorEvent>[];
      final options = WasmWatchOptions(
        dsn: 'https://key@example.com/v1/project',
        autoInstallFlutterErrorHandlers: false,
        captureLifecycleBreadcrumbs: false,
        captureBrowserErrors: false,
        captureUnhandledRejections: false,
        normalizeHttpPath: custom
            ? (uri) {
                expect(uri.query, isEmpty);
                expect(uri.userInfo, isEmpty);
                return '/logo-search/{logo}';
              }
            : null,
        beforeSend: (event) {
          events.add(event);
          return null;
        },
      );
      await WasmWatch.init(client: WasmWatchClient(options));
      addTearDown(WasmWatch.close);
      final tracker = HttpErrorTracker();
      final uri =
          Uri.parse('https://u:p@api.zeil.com/logo-search/123?q=secret#x');
      await tracker.recordResponse('GET', uri, 503);
      await tracker.recordFailure(
          'POST', uri, StateError('down'), StackTrace.current);
      expect(events, hasLength(2));
      for (final event in events) {
        expect(event.exceptionValue,
            contains(custom ? '/logo-search/{logo}' : '/logo-search/{id}'));
        expect(event.exceptionValue, isNot(contains('123')));
      }
      expect(events.first.contexts['request'], {
        'method': 'GET',
        'url': 'https://api.zeil.com/logo-search/123',
        'status_code': 503,
      });
      expect(events.last.contexts['request'], {
        'method': 'POST',
        'url': 'https://api.zeil.com/logo-search/123',
        'status_code': null,
      });
    });
  }

  group('request context on captured errors', () {
    late List<ErrorEvent> events;
    setUp(() async {
      events = [];
      await WasmWatch.init(
          client: WasmWatchClient(WasmWatchOptions(
        dsn: 'https://key@example.com/v1/project',
        autoInstallFlutterErrorHandlers: false,
        captureLifecycleBreadcrumbs: false,
        captureBrowserErrors: false,
        captureUnhandledRejections: false,
        beforeSend: (event) {
          events.add(event);
          return null;
        },
      )));
      addTearDown(WasmWatch.close);
    });

    DioException bad(String url, int status, {String method = 'GET'}) {
      final options = RequestOptions(path: url, method: method);
      return DioException.badResponse(
          statusCode: status,
          requestOptions: options,
          response: Response<void>(requestOptions: options, statusCode: status));
    }

    Future<String> value(Object error) async {
      events.clear();
      await WasmWatch.hub.client.captureException(error);
      return events.single.exceptionValue;
    }

    test('a DioException names its request without any wiring', () async {
      final text =
          await value(bad('https://api.zeil.com/jobs/123?token=s#f', 500));
      expect(text, startsWith('GET https://api.zeil.com/jobs/{id} failed: '));
      expect(text, contains('DioException'));
      expect(text, isNot(contains('token')));
      expect(text, isNot(contains('123')));
    });

    test('a failed request is also sent as a tag for the server to group on',
        () async {
      events.clear();
      await WasmWatch.hub.client
          .captureException(bad('https://api.zeil.com/jobs/7?x=1', 500));
      await WasmWatch.hub.client.captureException(StateError('plain'));
      expect(events.first.tags['wasmwatch.request'],
          'GET https://api.zeil.com/jobs/{id}');
      expect(events.last.tags, isNot(contains('wasmwatch.request')));
      await WasmWatch.hub.client.captureException(
          const HttpRequestException('POST', 'https://api.zeil.com/pay/9?x=1'));
      expect(events.last.tags['wasmwatch.request'],
          'POST https://api.zeil.com/pay/{id}');
    });

    test('same status on different endpoints no longer shares a message',
        () async {
      final jobs = await value(bad('https://api.zeil.com/jobs', 500));
      final profile = await value(bad('https://api.zeil.com/profile', 500));
      expect(jobs, isNot(profile));
      // The request leads, so the server's 256-character cut keeps it.
      expect(normalizeMessage(jobs).substring(0, 40), contains('/jobs'));
      expect(normalizeMessage(profile).substring(0, 40), contains('/profile'));
      // Different ids on one endpoint still share a message.
      expect(normalizeMessage(await value(bad('https://api.zeil.com/jobs/1', 500))),
          normalizeMessage(await value(bad('https://api.zeil.com/jobs/2', 500))));
    });

    test('recordResponse links any exception to its request', () async {
      final error = StateError('payment rejected');
      await HttpErrorTracker(addBreadcrumb: (_) {}, captureServerErrors: false)
          .recordResponse('POST', Uri.parse('https://api.zeil.com/pay/42?x=1'), 422,
              error: error);
      expect(await value(error),
          'POST https://api.zeil.com/pay/{id} failed: Bad state: payment rejected');
    });

    test('recordFailure links the transport error automatically', () async {
      final error = StateError('down');
      await HttpErrorTracker(addBreadcrumb: (_) {}, captureTransportErrors: false)
          .recordFailure('GET', Uri.parse('https://api.zeil.com/x'), error,
              StackTrace.current);
      expect(await value(error), startsWith('GET https://api.zeil.com/x failed: '));
    });

    test('honours normalizeHttpPath', () async {
      events.clear();
      await WasmWatch.close();
      await WasmWatch.init(
          client: WasmWatchClient(WasmWatchOptions(
        dsn: 'https://key@example.com/v1/project',
        autoInstallFlutterErrorHandlers: false,
        captureLifecycleBreadcrumbs: false,
        captureBrowserErrors: false,
        captureUnhandledRejections: false,
        normalizeHttpPath: (uri) => '/api/{v}',
        beforeSend: (event) {
          events.add(event);
          return null;
        },
      )));
      expect(await value(bad('https://api.zeil.com/jobs/9', 500)),
          startsWith('GET https://api.zeil.com/api/{v} failed: '));
    });

    test('a relative request URL keeps just its path', () async {
      expect(await value(bad('/jobs/9', 500)), startsWith('GET /jobs/{id} failed: '));
      expect(HttpErrorTracker.sanitizeUrl(Uri.parse('/jobs/9?x=1')), '/jobs/9');
    });

    test('a DioException subclass is still recognised', () async {
      final options = RequestOptions(path: 'https://api.zeil.com/jobs', method: 'GET');
      expect(await value(_ZeilDioException(requestOptions: options)),
          startsWith('GET https://api.zeil.com/jobs failed: '));
    });

    test('unrelated errors, HttpRequestException and overrides are untouched',
        () async {
      expect(await value(StateError('boom')), 'Bad state: boom');
      const http = HttpRequestException('GET', 'https://a.io/x', statusCode: 503);
      expect(await value(http), 'GET https://a.io/x returned 503');
      events.clear();
      await WasmWatch.hub.client.captureException(bad('https://a.io/x', 500),
          exceptionValueOverride: 'custom');
      expect(events.single.exceptionValue, 'custom');
    });
  });

  late List<Breadcrumb> crumbs;
  late List<Object> captured;
  late HttpErrorTracker tracker;
  setUp(() {
    crumbs = [];
    captured = [];
    tracker = HttpErrorTracker(
      addBreadcrumb: crumbs.add,
      capture: (error, stack) async => captured.add(error),
    );
  });

  test('sanitizeUrl drops query, fragment and credentials', () {
    expect(
      HttpErrorTracker.sanitizeUrl(Uri.parse('https://u:p@a.io:8443/x?t=1#f')),
      'https://a.io:8443/x',
    );
  });

  group('http client', () {
    Future<void> call(MockClient inner) => WasmWatchHttpClient(inner, tracker)
        .get(Uri.parse('https://a.io/x?k=1'));

    test('5xx captures an event', () async {
      await call(MockClient((_) async => http.Response('', 503)));
      expect(captured, hasLength(1));
      expect(captured.single.toString(), contains('503'));
      expect(captured.single.toString(), isNot(contains('k=1')));
      expect(crumbs.single.level, SeverityLevel.error);
    });

    test('4xx is a warning breadcrumb only', () async {
      await call(MockClient((_) async => http.Response('', 404)));
      expect(captured, isEmpty);
      expect(crumbs.single.level, SeverityLevel.warning);
    });

    test('failure breadcrumb names the error with the readable type', () async {
      // IndexError's runtimeType differs from the readable name RangeError.
      await tracker.recordFailure('GET', Uri.parse('https://api.zeil.com/x'),
          IndexError.withLength(5, 2), StackTrace.current);
      expect(crumbs.single.data['error'], 'RangeError');
      expect((captured.single as HttpRequestException).toString(),
          contains('(RangeError)'));
    });

    test('transport failure captures and rethrows', () async {
      await expectLater(
        call(MockClient((_) async => throw http.ClientException('down'))),
        throwsA(isA<http.ClientException>()),
      );
      expect(captured, hasLength(1));
    });
  });

  group('dio interceptor', () {
    Dio dio(HttpClientAdapter adapter) => Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(WasmWatchDioInterceptor(tracker: tracker));

    test('5xx, 4xx and transport failures', () async {
      final d = dio(_Adapter((o) {
        if (o.path.contains('500')) return ResponseBody.fromString('', 500);
        if (o.path.contains('404')) return ResponseBody.fromString('', 404);
        if (o.path.contains('cancel'))
          throw DioException(requestOptions: o, type: DioExceptionType.cancel);
        throw DioException(
            requestOptions: o, type: DioExceptionType.connectionTimeout);
      }));
      await d
          .get<void>('https://a.io/500')
          .catchError((_) => Response(requestOptions: RequestOptions()));
      expect(captured, hasLength(1));
      await d
          .get<void>('https://a.io/404')
          .catchError((_) => Response(requestOptions: RequestOptions()));
      expect(captured, hasLength(1));
      expect(crumbs.last.level, SeverityLevel.warning);
      await d
          .get<void>('https://a.io/timeout')
          .catchError((_) => Response(requestOptions: RequestOptions()));
      expect(captured, hasLength(2));
      await d
          .get<void>('https://a.io/cancel')
          .catchError((_) => Response(requestOptions: RequestOptions()));
      expect(captured, hasLength(2));
    });
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
          RequestOptions o, Stream<List<int>>? s, Future<void>? c) async =>
      handler(o);
  @override
  void close({bool force = false}) {}
}

class _ZeilDioException extends DioException {
  _ZeilDioException({required super.requestOptions});
}
