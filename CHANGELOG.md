## 0.3.1

- Added `HttpErrorTracker` and `WasmWatchHttpClient` for HTTP API error and breadcrumb monitoring.
- Added `WasmWatchDioInterceptor` example in `example/dio_interceptor.dart`.

## 0.3.0

- Added `WASMWATCH_UPLOAD_TOKEN` support for scoped CI sourcemap uploads.
- Added SDK runtime guard rejecting upload secrets in public DSNs.
- Added JavaScript source map upload fallback.

## 0.2.0

- Added consecutive loop error guard (<1s duplicate suppression window).
- Added session event cap (100 events/session default) and beforeSend re-entrancy protection.
- Enhanced HTTP transport with Retry-After header enforcement and compact 202 acceptance.
- Added byte and age bounded offline buffer storage.

## 0.1.0

- Initial release.
