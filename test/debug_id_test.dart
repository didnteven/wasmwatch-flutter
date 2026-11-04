import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  test('non-WASM runtimes safely yield no debug ID', () {
    expect(extractWasmDebugId(), isNull);
  });

  group('resolveWebDebugId', () {
    const injected = 'c1356a64-6a6f-74c8-aa92-b12ec275a2f9';

    test('a dart2js build reads the id the upload CLI injected into the page',
        () {
      // Same id as the wasm build: one upload registers both source maps.
      expect(
          resolveWebDebugId(
              isWeb: true, compileTime: '', window: () => injected),
          injected);
    });

    test('a compile-time define wins over the page global', () {
      expect(
          resolveWebDebugId(
              isWeb: true, compileTime: 'from-define', window: () => injected),
          'from-define');
    });

    test('a web page without the global has no id', () {
      expect(
          resolveWebDebugId(isWeb: true, compileTime: '', window: () => null),
          isNull);
    });

    test('off the web the page is never consulted', () {
      expect(
          resolveWebDebugId(
              isWeb: false,
              compileTime: 'from-define',
              window: () => fail('read window off the web')),
          isNull);
    });
  });
}
