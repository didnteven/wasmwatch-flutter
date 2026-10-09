import 'package:flutter/foundation.dart';

import 'debug_id.dart';

/// Message for a WASM-built app (debug id injected) that runs as JavaScript.
const wasmLoaderWarning =
    'WasmWatch: a WasmWatch debug id is present in the page, but this app is '
    'running as JavaScript, not WebAssembly. Your web/index.html most likely '
    'still uses the legacy `_flutter.loader.loadEntrypoint` bootstrap, which '
    'ignores the WASM build. Replace it with `{{flutter_bootstrap_js}}` (see '
    '"Migrating an existing Flutter web app" in the WasmWatch '
    'README.md). Errors will not symbolicate against the uploaded '
    '.wasm.map until the app actually runs as WASM.';

/// Returns the warning text, or null. Only debug id present + JS runtime warns.
///
/// Conservative on purpose: a JS build without an injected id is a normal
/// non-WASM app, and a WASM runtime is already correct.
String? wasmLoaderMismatchWarning({
  required bool isWasmRuntime,
  required bool debugIdPresent,
}) => (debugIdPresent && !isWasmRuntime) ? wasmLoaderWarning : null;

/// Logs the warning through [log] (debugPrint by default) at most once per
/// call. Never creates or sends an event. Returns whether it logged.
bool checkWasmLoader({
  bool? isWasmRuntime,
  bool? debugIdPresent,
  void Function(String message)? log,
}) {
  final message = wasmLoaderMismatchWarning(
    isWasmRuntime: isWasmRuntime ?? wasmRuntime,
    debugIdPresent: debugIdPresent ?? pageHasDebugId,
  );
  if (message == null) return false;
  (log ?? (m) => debugPrint(m))(message);
  return true;
}
