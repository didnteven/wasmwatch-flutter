import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  test('non-WASM runtimes safely yield no debug ID', () {
    expect(extractWasmDebugId(), isNull);
  });
}
