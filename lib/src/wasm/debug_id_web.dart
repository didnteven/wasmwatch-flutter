import 'dart:js_interop';

@JS('window.__WASMWATCH_DEBUG_ID__')
external JSString? get _windowDebugId;

String? getWindowDebugId() {
  try {
    final value = _windowDebugId?.toDart;
    return value?.isNotEmpty == true ? value : null;
  } on Object {
    return null;
  }
}
