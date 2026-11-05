import 'dart:js_interop';
import 'dart:js_interop_unsafe';
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

/// dart2js throws a Dart error as a JS `Error` whose `dartException` property
/// holds the original object (its `name` is empty). Null for anything else.
Object? unwrapDart2jsException(JSAny? value) {
  if (kIsWasm || value == null || !value.isA<JSObject>()) return null;
  try {
    final object = value as JSObject;
    if (!object.has('dartException')) return null;
    final carried = object['dartException'];
    // dart2js stores the Dart object itself; other runtimes may box it.
    if (carried.isA<JSBoxedDartObject>()) {
      return (carried as JSBoxedDartObject).toDart;
    }
    return carried.dartify();
  } catch (_) {
    return null;
  }
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
