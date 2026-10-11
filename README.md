# WasmWatch

Error tracking for Flutter Web and WebAssembly applications.

## Install

While the pub.dev release is pending, add the public GitHub dependency to
your app's `pubspec.yaml`:

```yaml
dependencies:
  wasmwatch:
    git:
      url: https://github.com/didnteven/wasmwatch-flutter.git
      ref: v0.2.0
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

## License

MIT

## Loop protection and delivery behavior

In release mode, a fresh-object error with the same type, normalized message,
supplied throw stack and widget-origin evidence is suppressed when repeated
within one second. Each duplicate refreshes that interval: a continuous loop
emits once until it pauses. `A → B → A` remains capturable. Browser/Dart cross-hook
dedupe operates independently.

A session is one initialized client. `maxEventsPerSession` defaults to 100 capture
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

