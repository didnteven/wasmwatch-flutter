import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/native_bridge.dart';
import 'package:wasmwatch_native/wasmwatch_native.dart';

// No binding here: Flutter's generated registrant calls registerWith before
// main, so registration must not touch the binary messenger.
void main() {
  test('registration works before the Flutter binding exists', () {
    WasmWatchNativeAndroid.registerWith();
    expect(NativeCrashBridge.instance, isA<WasmWatchNativeAndroid>());
    WasmWatchNativeIOS.registerWith();
    expect(NativeCrashBridge.instance, isA<WasmWatchNativeIOS>());
  });
}
