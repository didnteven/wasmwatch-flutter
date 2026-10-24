import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
