import 'package:dio/dio.dart';
import 'package:wasmwatch/wasmwatch.dart';

/// Dio interceptor: 5xx and transport failures become events, 4xx responses
/// become warning breadcrumbs, cancellations are ignored.
///
/// Copy into your app (it needs `dio` in your pubspec) and register it:
/// `dio.interceptors.add(WasmWatchDioInterceptor());`
class WasmWatchDioInterceptor extends Interceptor {
  WasmWatchDioInterceptor({HttpErrorTracker? tracker})
      : _tracker = tracker ?? HttpErrorTracker();
  final HttpErrorTracker _tracker;
  static const _started = 'wasmwatch_started_at';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_started] = DateTime.now().millisecondsSinceEpoch;
    handler.next(options);
  }

  Duration? _elapsed(RequestOptions options) {
    final started = options.extra[_started];
    return started is int
        ? Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - started)
        : null;
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _tracker.recordResponse(
      response.requestOptions.method,
      response.requestOptions.uri,
      response.statusCode ?? 0,
      duration: _elapsed(response.requestOptions),
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    final status = err.response?.statusCode;
    if (status != null) {
      _tracker.recordResponse(options.method, options.uri, status,
          duration: _elapsed(options));
    } else {
      _tracker.recordFailure(options.method, options.uri, err, err.stackTrace,
          cancelled: err.type == DioExceptionType.cancel,
          duration: _elapsed(options));
    }
    handler.next(err);
  }
}
