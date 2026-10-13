import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wasmwatch/wasmwatch.dart';

import '../example/dio_interceptor.dart';

void main() {
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
    Future<void> call(MockClient inner) =>
        WasmWatchHttpClient(inner, tracker).get(Uri.parse('https://a.io/x?k=1'));

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
        if (o.path.contains('cancel')) throw DioException(requestOptions: o, type: DioExceptionType.cancel);
        throw DioException(requestOptions: o, type: DioExceptionType.connectionTimeout);
      }));
      await d.get<void>('https://a.io/500').catchError((_) => Response(requestOptions: RequestOptions()));
      expect(captured, hasLength(1));
      await d.get<void>('https://a.io/404').catchError((_) => Response(requestOptions: RequestOptions()));
      expect(captured, hasLength(1));
      expect(crumbs.last.level, SeverityLevel.warning);
      await d.get<void>('https://a.io/timeout').catchError((_) => Response(requestOptions: RequestOptions()));
      expect(captured, hasLength(2));
      await d.get<void>('https://a.io/cancel').catchError((_) => Response(requestOptions: RequestOptions()));
      expect(captured, hasLength(2));
    });
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<List<int>>? s, Future<void>? c) async => handler(o);
  @override
  void close({bool force = false}) {}
}
