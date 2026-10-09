import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initializes without offline storage when preferences plugin is missing',
      () async {
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');
    var storageCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      storageCalls++;
      throw MissingPluginException('SharedPreferences unavailable on WASM');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    addTearDown(WasmWatch.close);

    await WasmWatch.init(options: const WasmWatchOptions(
      dsn: 'https://test-key@ingest.example/api/1/test-project',
    ));

    expect(storageCalls, 1);
    expect(WasmWatch.hub.client.offlineBuffer, isNull);
    await expectLater(WasmWatch.hub.client.flushOffline(), completes);
  });
}
