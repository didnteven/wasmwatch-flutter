import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  test('fresh binding and runApp share the SDK guarded zone', () async {
    final outer = Zone.current;
    var ran = false;
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await WasmWatch.init(
        dsn: 'https://key@example.com/v1/project',
        client: WasmWatchClient(const WasmWatchOptions(
          dsn: 'https://key@example.com/v1/project',
        )),
        appRunner: () {
          expect(Zone.current, isNot(same(outer)));
          expect(WidgetsBinding.instance.debugCheckZone('appRunner'), true);
          runApp(const SizedBox());
          ran = true;
        },
      );
      expect(ran, true);
      expect(errors, isEmpty);
    } finally {
      await WasmWatch.close();
      FlutterError.onError = previous;
    }
  });
}
