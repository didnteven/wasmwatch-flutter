## 0.8.2

Use with `wasmwatch_native` 0.3.0 (same repository and tag).

- Uncaught errors in dart2js builds report their Dart type (`StateError`, …) instead of an empty one: the browser hook unwraps the Dart error dart2js carries on the JS error, as it already did on wasm.
- Uncaught browser errors keep the browser name and version. The script location moved from the `browser` context to `error_location`, so the `browser` tag and the dashboard's browser name no longer disappear.
- Custom exceptions keep their name in release builds when their `toString()` starts with it (`DioException`, `ClientException`, …) instead of showing as `Exception`.
- HTTP failure breadcrumbs and messages use the readable error type, not the minified `runtimeType` (`minified:aU`).
- Card-number scrubbing also requires a card-network prefix and length. Luhn alone still passed about 1 in 10 random 13–19 digit numbers (timestamps included), so the 0.8.1 note that they were "no longer replaced" overstated it; timestamps are now left alone.

## 0.8.1

Use with `wasmwatch_native` 0.3.0 (same repository and tag).

- JS (dart2js) builds now send the build's debug ID. It was always the all-zero placeholder outside wasm, so JS source maps never matched. `upload_sourcemaps` already injects `window.__WASMWATCH_DEBUG_ID__` and registers the JS map under the same ID as the wasm map. Rebuild web apps with this version: builds made with an earlier SDK keep sending the placeholder.
- Card-number scrubbing needs a valid Luhn checksum, so timestamps and order numbers of 13–19 digits are no longer replaced by `[credit-card]`. A number followed by a space also keeps that space.
- The `flutter.error` breadcrumb names the error with the readable type (`StateError: …`), not the minified `runtimeType` (`minified:Class1168: …`) seen in release wasm builds.
- A stalled connection no longer hangs the SDK: each request times out after 10 s (a failed attempt, retried and buffered as before), and `WasmWatch.init` waits at most 3 s for buffered events to replay, which carries on in the background.

## 0.8.0

Use with `wasmwatch_native` 0.3.0 (same repository and tag).

- iOS app hangs are reported in the same session: with `wasmwatch_native`, a watchdog reports the main thread blocked for `appHangTimeout` (default 2 s; `Duration.zero` disables it). Because Flutter runs Dart on the iOS main thread, this covers native hangs and Dart code freezing the UI, with symbolicated Dart frames. A hang that ends with the app being killed is sent on the next launch as `App hang: at least N sec (app terminated)`. Verified on an iPhone.
- Flutter engine frames can be symbolicated: `upload_symbols --flutter-engine [android|ios]` uploads the engine's debug symbols once per Flutter version per project (Android downloads them from Flutter's storage and needs `unzip`; iOS uses the local Flutter dSYM) and skips files the server already has.
- iOS daily exit counts have now been verified with real MetricKit deliveries on an iPhone.

## 0.7.0

Native crash capture with the optional `wasmwatch_native` 0.2.0 plugin (same repository, `path: wasmwatch_native`).

- Optional native bridge: discover `wasmwatch_native`, recover pending Android reports at init, synchronize scope and acknowledge reports after durable buffering.
- Convert Java/Kotlin crashes, native tombstones, killed ANRs and OS exits into events with the crashed build's release, mapping ID, images and exit context.
- Upgrade the previous process session to `crashed` when a recovered native report identifies it.
- Recover iOS MetricKit crashes and app hangs with native Mach-O stacks and the original build identity. Verified on an iPhone: Swift and `abort()` crashes, with Dart frames resolved inside the native stack.
- Send iOS daily exit counts as `app_exits`, removing a native report only after the server accepts it or rejects it permanently. Exit counts never create issues or change sessions. iOS hang and exit-count delivery are not yet verified on a device.
- `upload_symbols`: `--android-mapping`/`--mapping-id` (R8), `--native-libs` (Android `.so`) and `--dsyms-dir` (iOS Runner and plugin dSYMs).

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
