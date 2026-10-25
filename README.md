# WasmWatch

Error tracking for Flutter apps: web (WebAssembly and JavaScript), iOS and Android.

## Install

While the pub.dev release is pending, add the public GitHub dependency to
your app's `pubspec.yaml`:

```yaml
dependencies:
  wasmwatch:
    git:
      url: https://github.com/didnteven/wasmwatch-flutter.git
      ref: v0.6.0
```

Then run `flutter pub get`.

## Initialize

Copy the DSN from your WasmWatch project settings.

```dart
import 'package:flutter/widgets.dart';
import 'package:wasmwatch/wasmwatch.dart';

Future<void> main() async {
  await WasmWatch.init(
    dsn: 'YOUR_DSN',
    appRunner: () => runApp(const MyApp()),
  );
}
```

## Build with source maps

```sh
flutter build web --wasm --source-maps --no-strip-wasm
```

## Upload source maps

```sh
export WASMWATCH_DSN='YOUR_DSN'
dart run wasmwatch:upload_sourcemaps build/web
```

Uploading source maps lets WasmWatch show readable Dart stack traces for
errors from your WebAssembly build.

## iOS and Android

The same `WasmWatch.init` captures Dart errors from iOS and Android release
builds, with device and OS context. Uncaught errors (`FlutterError.onError`,
`PlatformDispatcher.onError`, zones, isolates) are labeled **Unhandled**. Each
event is saved before it is sent, so one in flight when the app is killed goes
out at the next launch. Readable release builds need no upload.

For obfuscated `--split-debug-info` builds, upload each build's symbols and
obfuscation map with an `artifact:write` upload token (never the DSN's public
key). Give each platform its own paths:

```sh
export WASMWATCH_DSN='YOUR_DSN'
export WASMWATCH_UPLOAD_TOKEN='YOUR_UPLOAD_TOKEN'

# Android
flutter build apk --release --obfuscate --split-debug-info=build/symbols/android \
  --extra-gen-snapshot-options=--save-obfuscation-map=build/android-obfuscation.map.json
dart run wasmwatch:upload_symbols --symbols-dir build/symbols/android \
  --obfuscation-map build/android-obfuscation.map.json

# iOS: upload App.framework.dSYM (not Runner.app.dSYM) and the .symbols directory
flutter build ios --release --obfuscate --split-debug-info=build/symbols/ios \
  --extra-gen-snapshot-options=--save-obfuscation-map=build/ios-obfuscation.map.json
dart run wasmwatch:upload_symbols \
  --dsym build/ios/Release-iphoneos/App.framework.dSYM \
  --symbols-dir build/symbols/ios --obfuscation-map build/ios-obfuscation.map.json
```

The release defaults to your pubspec `name@version`; pass `--release` to match
a custom `release:`. A later upload also repairs earlier events.

### Isolates

Errors on the main isolate are captured automatically. For background
isolates, spawn them through WasmWatch to capture their uncaught errors with
the original type:

```dart
await WasmWatch.spawn(heavyWork, input);
// Or, for isolates you spawn yourself:
await Isolate.spawn(heavyWork, input, onError: WasmWatch.isolateErrorPort());
```

### Release health

On iOS and Android the SDK tracks sessions (`trackSessions`, on by default for
mobile), and the dashboard's **Releases** page shows crash-free users and
sessions. A session that ends with the app dying in the foreground counts as a
crash; one the OS kills in the background ends normally. Users are random
anonymous install IDs. Set `trackSessions: false` in `WasmWatchOptions` to opt
out.

Native crashes (Swift, Kotlin, C/C++), ANRs and app hangs are not captured yet;
run Crashlytics or Sentry alongside WasmWatch for those.

## Migrating an existing Flutter web app

If `web/index.html` still uses the legacy `_flutter.loader.loadEntrypoint`
bootstrap, replace it with `{{flutter_bootstrap_js}}` so the app runs as
WebAssembly.

## Manual error capture

```dart
try {
  doSomething();
} catch (error, stack) {
  await WasmWatch.captureException(error, stackTrace: stack);
}
```

## Track HTTP errors (`http` and Dio)

By default, 5xx responses and transport failures (timeout, connection, CORS)
are captured as error events; 4xx responses are warning breadcrumbs only.
Cancellations are never captured. URLs are recorded without query string,
fragment or credentials.

### `package:http`

```dart
import 'package:http/http.dart' as http;
import 'package:wasmwatch/wasmwatch.dart';

final client = WasmWatchHttpClient(http.Client());
final response = await client.get(Uri.parse('https://api.example.com/items'));
```

### Dio

`wasmwatch` does not depend on Dio. Copy
[`example/dio_interceptor.dart`](https://github.com/didnteven/wasmwatch-flutter/blob/main/example/dio_interceptor.dart)
into your app (it is covered by the SDK tests), then register it:

```dart
final dio = Dio()..interceptors.add(WasmWatchDioInterceptor());
```

Pass `HttpErrorTracker(captureServerErrors: false)` or
`captureTransportErrors: false` to either wrapper to keep those outcomes as
breadcrumbs only.

## License

MIT

## Loop protection and delivery behavior

In release mode, a fresh-object error with the same type, normalized message,
supplied throw stack and widget-origin evidence is suppressed when repeated
within one second. Each duplicate refreshes that interval: a continuous loop
emits once until it pauses. `A → B → A` remains capturable. Browser/Dart cross-hook
dedupe operates independently.

For loop protection, a session is one initialized client (unrelated to release
health sessions). `maxEventsPerSession` defaults to 100 capture
attempts after dedupe and before callbacks or delivery; dropped callbacks,
throttled attempts and transport failures still consume that session budget.
Existing 60/minute limiting also applies. Scoped guards contain SDK recursion
without suppressing unrelated concurrent errors. Inspect `captureAttempts`,
`consecutiveDrops` and `sessionCapDrops` for local diagnostics.

Debug mode defaults to volume protection bypass, while cross-hook dedupe,
re-entrancy protection and payload/queue bounds remain active. Set
`protectionBypass: false` to exercise release protections in a local test.
Labeling an event `environment: 'development'` does not disable protections.
Initialization starts a new client/session; it does not reset another client's
transport cooldown or bypass server admission limits.

Transport uses a bounded serial queue and shared `Retry-After` cooldown for
429/503, including offline replay, with jitter/backoff. Offline records are
bounded by age, bytes and count; permanent 4xx/oversized payloads are discarded.
A server `202` with `detail_retained: false` is successful delivery and is not
buffered as a failure. Admission/SDK protection removes observations before the
server counts them: counts describe admitted observations, not all original
application throws. Stable application user IDs are needed for identified-user
breadth; anonymous users remain unknown.
