import 'package:flutter/foundation.dart';

import 'debug_id_vm.dart'
    if (dart.library.js_interop) 'debug_id_web.dart' as platform;

const _compileTimeDebugId = String.fromEnvironment('WASMWATCH_DEBUG_ID');

bool get isWasmRuntime => kIsWasm;

/// Same as [isWasmRuntime]; kIsWasm is the compile-time
/// `bool.fromEnvironment('dart.tool.dart2wasm')`, true only in dart2wasm output.
bool get wasmRuntime => kIsWasm;

/// True when `window.__WASMWATCH_DEBUG_ID__` was injected into the page.
/// Works under dart2js and dart2wasm (both have dart:js_interop); false on the VM.
bool get pageHasDebugId => platform.getWindowDebugId() != null;

String? extractWasmDebugId() {
  if (!kIsWasm) return null;
  if (_compileTimeDebugId.isNotEmpty) return _compileTimeDebugId;
  return platform.getWindowDebugId();
}
