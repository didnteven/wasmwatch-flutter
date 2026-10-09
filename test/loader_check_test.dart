import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  group('checkWasmLoader', () {
    for (final wasm in [true, false]) {
      for (final id in [true, false]) {
        final expectWarn = id && !wasm;
        test('wasm=$wasm debugId=$id -> ${expectWarn ? 'warns once' : 'silent'}', () {
          final logs = <String>[];
          final logged = checkWasmLoader(isWasmRuntime: wasm, debugIdPresent: id, log: logs.add);
          expect(logged, expectWarn);
          expect(logs.length, expectWarn ? 1 : 0);
          if (expectWarn) {
            expect(logs.single, contains('{{flutter_bootstrap_js}}'));
            expect(logs.single, contains('Migrating an existing Flutter web app'));
          }
        });
      }
    }

    test('defaults are silent on the VM', () {
      final logs = <String>[];
      expect(checkWasmLoader(log: logs.add), isFalse);
      expect(logs, isEmpty);
    });
  });
}
