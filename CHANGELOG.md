## 0.6.0

- Uncaught Dart errors (`FlutterError.onError`, `PlatformDispatcher.onError`, zones, isolates) are sent as unhandled (`mechanism.handled: false`); `captureException` events are handled. The dashboard labels and filters unhandled issues.
- Main-isolate error listener on iOS and Android; `WasmWatch.spawn` captures uncaught errors from spawned isolates with their original type; `WasmWatch.isolateErrorPort()` for isolates you spawn yourself.
- Every event is saved before it is sent and removed once accepted, so events in flight when the app is killed are sent at the next launch.
- Release health: sessions are tracked on iOS and Android (`trackSessions`, default on for mobile); the dashboard's Releases page shows crash-free users and sessions. Until native capture lands, a session that dies in the foreground is abnormal and counts as a crash; one the OS kills in the background ends normally. Verified on an iPhone 15 Pro Max.
- `upload_symbols --dsym … --symbols-dir build/symbols/ios` also uploads the iOS `.symbols` file, so frames in functions starting with `l` symbolicate (dart-lang/sdk#64716).

## 0.5.0

- Flutter iOS and Android: capture Dart errors from release builds, with the `dart-ios`/`dart-android` platform and device and OS context. Readable builds need no upload.
- Obfuscated `--split-debug-info` builds send address-only frames that the server symbolicates. Upload each build's symbols and obfuscation map with `dart run wasmwatch:upload_symbols`: `--symbols-dir` for Android `.symbols` files, `--dsym App.framework.dSYM` for iOS (the VM prints the dSYM's Mach-O UUID as the trace's `build_id`). Verified on an Android emulator and an iPhone.
- Stamp breadcrumbs at recording time, collapse consecutive repeats, and protect navigation history.
- Template HTTP failure URLs for stable grouping, preserve request contexts, and support custom path normalization.
- Add shared deterministic grouping normalization fixtures.

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
