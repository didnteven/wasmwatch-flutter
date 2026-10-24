import 'dart:js_interop';
import 'package:flutter/foundation.dart';

@JS('WebAssembly.Exception')
extension type WasmException(JSObject _) implements JSObject {
  external JSString? get stack;
}

@JS('window.__wasmwatchRethrow')
external JSFunction? get _rethrow;

@JS('String')
external JSString _jsString(JSAny? value);

@JS('WebAssembly.Exception')
external JSFunction? get _wasmExceptionConstructor;

bool get hasWasmRethrowHelper => _rethrow != null;
bool isWasmException(JSAny? value) =>
    value != null &&
    _wasmExceptionConstructor != null &&
    value.isA<WasmException>();

/// Re-enter Dart's exception handler so its wasm exception tag can be decoded.
(Object, StackTrace)? unwrapWasmException(JSAny? value) {
  if (!kIsWasm ||
      value == null ||
      !hasWasmRethrowHelper ||
      !isWasmException(value)) return null;
  try {
    _rethrow!.callAsFunction(null, value);
  } catch (error, stack) {
    // Foreign wasm tags are surfaced as JS wrappers, not Dart exceptions.
    // The private dart2wasm JavaScriptError class name may be minified.
    // Its rendering still comes from the original opaque JS exception.
    if ((error is Error && error.toString() == _jsString(value).toDart) ||
        error is JSObject ||
        const {'JavaScriptError', '_JavaScriptError'}
            .contains(error.runtimeType.toString())) return null;
    return (error, stack);
  }
  return null;
}

String? wasmExceptionStack(JSAny? value) {
  try {
    return isWasmException(value)
        ? (value as WasmException).stack?.toDart
        : null;
  } catch (_) {
    return null;
  }
}
