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
