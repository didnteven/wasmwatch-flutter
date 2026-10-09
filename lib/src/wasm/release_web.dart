import 'dart:js_interop';

@JS('window.__WASMWATCH_RELEASE__')
external JSString? get _windowRelease;

String? getWindowRelease() {
  try {
    final value = _windowRelease?.toDart;
    return value?.isNotEmpty == true ? value : null;
  } on Object {
    return null;
  }
}
