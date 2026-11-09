import 'http_tracking.dart';

class _FailedRequest {
  const _FailedRequest(this.method, this.url);
  final String method;
  final String url;
}

final _failedRequests = Expando<_FailedRequest>('wasmwatch.failed_request');

/// Links [error] to the request that produced it, so an event captured later
/// for that same error object names the request. Dio's `DioException` text,
/// for one, carries a status but no URL, which would otherwise make every
/// failure with that status look identical.
void rememberFailedRequest(Object error, String method, Uri uri) {
  try {
    _failedRequests[error] = _FailedRequest(method, HttpErrorTracker.sanitizeUrl(uri));
  } catch (_) {
    // Expando rejects numbers, strings and booleans; those are never request errors.
  }
}

/// `METHOD https://host/templated/{id}` for the request behind [error], or
/// null. Uses the link from [rememberFailedRequest], else (for a
/// `DioException` only) its own `requestOptions`, so apps need no wiring.
String? failedRequestOf(Object error, String exceptionType,
    {String Function(Uri)? normalizeHttpPath}) {
  // HttpRequestException already puts its request in its message.
  if (error is HttpRequestException) return null;
  String? describe(String method, String url) {
    final templated =
        HttpRequestException(method, url, normalizeHttpPath: normalizeHttpPath)
            .templatedUrl;
    return '$method $templated';
  }

  try {
    final known = _failedRequests[error];
    if (known != null) return describe(known.method, known.url);
  } catch (_) {}
  // endsWith: subclasses (and minified builds, which name the type from toString) still match.
  if (!exceptionType.endsWith('DioException')) return null;
  try {
    // Dynamic on purpose: depending on dio here would force it on every app.
    final dynamic options = (error as dynamic).requestOptions;
    final method = options.method;
    final uri = options.uri;
    if (method is String && uri is Uri) {
      return describe(method, HttpErrorTracker.sanitizeUrl(uri));
    }
  } catch (_) {}
  return null;
}
