@TestOn('browser')
library;

import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:wasmwatch/src/web/wasm_exception.dart';

@JS('window.__wasmwatchRethrow')
external set rethrowHelper(JSFunction? value);
@JS('window.__wasmwatchRethrow')
external JSFunction? get rethrowHelper;

void main() {
  test('ignores null, plain values, and missing helper', () {
    final previous = rethrowHelper;
    addTearDown(() => rethrowHelper = previous);
    rethrowHelper = null;
    expect(unwrapWasmException(null), isNull);
    expect(unwrapWasmException('ordinary'.toJS), isNull);
  });

  test('rethrow helper recovers the Dart exception and throw stack', () {
    // A Dart callback used as a rethrow helper would not test JS re-entry.
    // Load exactly the inline script emitted by the injectors.
    final script = web.HTMLScriptElement()
      ..text = 'window.__wasmwatchRethrow=function(e){throw e};';
    final previous = rethrowHelper;
    web.document.head!.appendChild(script);
    addTearDown(() {
      rethrowHelper = previous;
      script.remove();
    });
    (Object, StackTrace)? recovered;
    final listener = ((web.Event event) {
      final error = event as web.ErrorEvent;
      recovered = unwrapWasmException(error.error);
      event.preventDefault();
    }).toJS;
    web.window.addEventListener('error', listener);
    addTearDown(() => web.window.removeEventListener('error', listener));
    final void Function(web.Event) throwing = (web.Event _) {
      throw StateError('escaped from JS callback');
    };
    final callback = throwing.toJS;
    final target = web.EventTarget();
    target.addEventListener('wasmwatch-test', callback);
    target.dispatchEvent(web.Event('wasmwatch-test'));
    expect(recovered, isNotNull);
    expect(recovered!.$1, isA<StateError>());
    expect(recovered!.$1.toString(), contains('escaped from JS callback'));
    expect(recovered!.$2.toString(), isNotEmpty);
  }, skip: !kIsWasm ? 'Requires flutter test --platform chrome --wasm' : false);
}
