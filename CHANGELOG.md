## 0.8.5

Use with `wasmwatch_native` 0.3.0 (same repository and tag). Needs an ingestor that reads `extensions.capture_frames`; against an older one grouping is unchanged.

- Web async errors group on where they were caught. dart2wasm keeps no throw site for an awaited error, so its stack is runtime frames only and grouping fell back to the message (same message from two places merged; an id in the message split one place). The SDK now also sends the stack taken at the `captureException` call (`extensions.capture_frames`, web only), and the server groups on its first two app frames when the error's own stack has none. A failed HTTP request is sent as the `wasmwatch.request` tag and is part of that grouping, so one shared interceptor still splits endpoints.
- `captureException(groupKey:)` from 0.8.4 is deprecated and ignored (still accepted, so nothing stops compiling); the server ignores the `wasmwatch.group_key` tag. Capture-site grouping replaces it. `HttpRequestException` events carry the request tag too.
- One-time effect: web issues that grouped on the message start new issues grouped on the catch site.
- Still not recoverable: uncaught async throws have no app frame in either stack and keep grouping on the message.

## 0.8.4

Use with `wasmwatch_native` 0.3.0 (same repository and tag). Needs an ingestor that reads the `wasmwatch.group_key` tag; without one the key is ignored and grouping is unchanged.

- `captureException(..., groupKey: 'loadJobs')` names the failing site. The server groups on exception type plus key instead of the stack or message, which fixes dart2wasm async errors that have no app frame: same message from different sites no longer merges, and a changing id or name in the message no longer splits one site. Optional; unset behaves as before. The key is sent as the `wasmwatch.group_key` tag (trimmed, 128 code points) and outranks the stack, so use one stable name per site. Native crashes ignore it.
- Adding a key to an existing error moves new events to a new issue; the old issue stops receiving them.

## 0.8.3

Use with `wasmwatch_native` 0.3.0 (same repository and tag).

- Errors from failed HTTP requests name the request. A `DioException` reads `DioException [bad response]: …` with a status but no URL, so on web builds where the stack has no app frame (dart2wasm async errors) every failure with the same status landed in one issue whatever endpoint it came from. The event message now starts with `GET https://host/templated/{id} failed: `, using the same query-free, templated URL as `HttpRequestException` (`normalizeHttpPath` applies). The server groups on the first 256 characters of that message, so endpoints separate and different ids on one endpoint still merge.
  - `DioException` needs no wiring: its own `requestOptions` are read (verified in a `--minify` dart2wasm build).
  - Any other error is linked when you report it to `HttpErrorTracker`: `recordFailure` does it automatically, and `recordResponse` takes a new optional `error:`. The example Dio interceptor passes it.
  - Events with an `exceptionValueOverride` and `HttpRequestException` are unchanged.
  - One-time effect: a web issue that grouped on that message (no app frame) stops receiving new events after you upgrade, and per-endpoint issues start instead; resolved/ignored state and assignments stay on the old issue. Errors with an app frame group on the frame and are not affected.
  - A relative request URL (Dio without a `baseUrl`) is reported as its path instead of a malformed `///path`; `HttpRequestException` messages benefit too.

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
