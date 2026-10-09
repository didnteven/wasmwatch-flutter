# WasmWatch

Error tracking for Flutter Web and WebAssembly applications.

## Install

Add to `pubspec.yaml`, then run `flutter pub get`:

```yaml
dependencies:
  wasmwatch:
    git:
      url: https://github.com/didnteven/wasmwatch-flutter.git
      ref: main
```

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
