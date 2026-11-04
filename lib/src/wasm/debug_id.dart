import 'package:flutter/foundation.dart';

import 'debug_id_vm.dart' if (dart.library.js_interop) 'debug_id_web.dart'
    as platform;

const _compileTimeDebugId = String.fromEnvironment('WASMWATCH_DEBUG_ID');

bool get isWasmRuntime => kIsWasm;

/// Same as [isWasmRuntime]; kIsWasm is the compile-time
/// `bool.fromEnvironment('dart.tool.dart2wasm')`, true only in dart2wasm output.
bool get wasmRuntime => kIsWasm;

/// True when `window.__WASMWATCH_DEBUG_ID__` was injected into the page.
/// Works under dart2js and dart2wasm (both have dart:js_interop); false on the VM.
bool get pageHasDebugId => platform.getWindowDebugId() != null;

/// The build's debug ID, from `--dart-define=WASMWATCH_DEBUG_ID` or the
/// `window.__WASMWATCH_DEBUG_ID__` global that `upload_sourcemaps` injects into
/// `index.html`. Named for wasm, but it also answers under dart2js: one upload
/// registers the wasm and the JS source map under the same ID. Null off the web.
String? extractWasmDebugId() => resolveWebDebugId(
    isWeb: kIsWeb,
    compileTime: _compileTimeDebugId,
    window: () => platform.getWindowDebugId());

/// [extractWasmDebugId] with its inputs passed in, so tests can cover the web
/// branch on the VM. [window] is only read on the web.
String? resolveWebDebugId(
    {required bool isWeb,
    required String compileTime,
    required String? Function() window}) {
  if (!isWeb) return null;
  if (compileTime.isNotEmpty) return compileTime;
  return window();
}
