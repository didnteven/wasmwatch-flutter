import 'dart:async';

import 'package:http/http.dart' as http;

import '../event/breadcrumb.dart';
import '../wasmwatch.dart';

/// Error raised for an HTTP failure that is reported as an event.
class HttpRequestException implements Exception {
  const HttpRequestException(this.method, this.url, {this.statusCode, this.cause});
  final String method;
  final String url;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => statusCode == null
      ? 'HttpRequestException: $method $url failed (${cause ?? 'transport error'})'
      : 'HttpRequestException: $method $url returned $statusCode';
}

/// Shared policy for `package:http` and Dio tracking.
///
/// 5xx responses and transport failures become error events; 4xx responses
/// become warning breadcrumbs; other responses are info breadcrumbs.
/// Cancellations are never captured. URLs are recorded without query string,
/// fragment or credentials.
class HttpErrorTracker {
  HttpErrorTracker({
    this.captureServerErrors = true,
    this.captureTransportErrors = true,
    this.addBreadcrumb,
    this.capture,
  });

  final bool captureServerErrors;
  final bool captureTransportErrors;
  final void Function(Breadcrumb)? addBreadcrumb;
  final Future<void> Function(Object error, StackTrace? stackTrace)? capture;

  static String sanitizeUrl(Uri uri) => Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        path: uri.path,
      ).toString();

  void _crumb(Breadcrumb breadcrumb) {
    final sink = addBreadcrumb;
    if (sink != null) {
      sink(breadcrumb);
    } else if (WasmWatch.isInitialized) {
      WasmWatch.addBreadcrumb(breadcrumb);
    }
  }

  Future<void> _capture(Object error, StackTrace? stack) async {
    final sink = capture;
    if (sink != null) return sink(error, stack);
    if (WasmWatch.isInitialized) {
      await WasmWatch.captureException(error, stackTrace: stack);
    }
  }

  /// Records a completed response.
  Future<void> recordResponse(
    String method,
    Uri uri,
    int statusCode, {
    Duration? duration,
  }) async {
    final url = sanitizeUrl(uri);
    final level = statusCode >= 500
        ? SeverityLevel.error
        : statusCode >= 400
            ? SeverityLevel.warning
            : SeverityLevel.info;
    _crumb(Breadcrumb(
      category: 'http',
      message: '$method $url -> $statusCode',
      level: level,
      data: {
        'method': method,
        'url': url,
        'status_code': statusCode,
        if (duration != null) 'duration_ms': duration.inMilliseconds,
      },
    ));
    if (statusCode >= 500 && captureServerErrors) {
      await _capture(
        HttpRequestException(method, url, statusCode: statusCode),
        StackTrace.current,
      );
    }
  }

  /// Records a request that failed before a response arrived.
  /// Pass [cancelled] for user/CancelToken cancellations: they are ignored.
  Future<void> recordFailure(
    String method,
    Uri uri,
    Object error,
    StackTrace? stackTrace, {
    bool cancelled = false,
    Duration? duration,
  }) async {
    if (cancelled) return;
    final url = sanitizeUrl(uri);
    _crumb(Breadcrumb(
      category: 'http',
      message: '$method $url failed',
      level: SeverityLevel.error,
      data: {
        'method': method,
        'url': url,
        'error': error.runtimeType.toString(),
        if (duration != null) 'duration_ms': duration.inMilliseconds,
      },
    ));
    if (captureTransportErrors) {
      await _capture(
        HttpRequestException(method, url, cause: error.runtimeType),
        stackTrace,
      );
    }
  }
}

/// Drop-in `http.Client` that reports failures. Wrap your client:
/// `final client = WasmWatchHttpClient(http.Client());`
class WasmWatchHttpClient extends http.BaseClient {
  WasmWatchHttpClient([http.Client? inner, HttpErrorTracker? tracker])
      : _inner = inner ?? http.Client(),
        _tracker = tracker ?? HttpErrorTracker();

  final http.Client _inner;
  final HttpErrorTracker _tracker;

  /// Telemetry must never delay or fail the caller's request: fire and forget,
  /// swallowing any error from the tracker or a `beforeSend` hook.
  void _safely(Future<void> Function() record) {
    try {
      unawaited(record().catchError((Object _, StackTrace __) {}));
    } catch (_) {}
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final watch = Stopwatch()..start();
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (error, stack) {
      // Aborted requests are cancellations, not failures.
      final cancelled = error is http.RequestAbortedException;
      _safely(() => _tracker.recordFailure(
            request.method,
            request.url,
            error,
            stack,
            cancelled: cancelled,
            duration: watch.elapsed,
          ));
      rethrow;
    }
    _safely(() => _tracker.recordResponse(
          request.method,
          request.url,
          response.statusCode,
          duration: watch.elapsed,
        ));
    return response;
  }

  @override
  void close() => _inner.close();
}
