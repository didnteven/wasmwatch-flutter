@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  test('a dart2js page reads the debug id upload_sourcemaps injected', () {
    globalContext['__WASMWATCH_DEBUG_ID__'] =
        'c1356a64-6a6f-74c8-aa92-b12ec275a2f9'.toJS;
    addTearDown(() => globalContext.delete('__WASMWATCH_DEBUG_ID__'.toJS));
    expect(extractWasmDebugId(), 'c1356a64-6a6f-74c8-aa92-b12ec275a2f9');
  });

  test('a page without the global has no id', () {
    globalContext.delete('__WASMWATCH_DEBUG_ID__'.toJS);
    expect(extractWasmDebugId(), isNull);
  });
}
