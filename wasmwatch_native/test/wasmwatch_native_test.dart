import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch_native/wasmwatch_native.dart';
import 'package:wasmwatch/native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wasmwatch/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final valid = <String, Object?>{
    'v': 1,
    'id': 'exit-12-42-5',
    'kind': 'native_crash',
    'timestamp_ms': 42,
    'pid': 12,
    'release': '1.0',
    'install_id': 'install',
    'scope': {'session_id': 's'},
  };

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'start' ? [jsonEncode(valid)] : null;
    });
  });
  tearDown(() {
    NativeCrashBridge.reset();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('Flutter Dart registration wires all bridge methods to the channel',
      () async {
    NativeCrashBridge.reset();
    WasmWatchNativeAndroid.registerWith();
    final bridge = NativeCrashBridge.instance!;
    expect(
        await bridge.start(release: 'r', environment: 'prod', installId: 'i'),
        [valid]);
    await bridge.setScope({'session_id': 's'});
    await bridge.ack(['id']);
    expect(calls.map((call) => call.method), ['start', 'setScope', 'ack']);
    expect(jsonDecode(calls[1].arguments as String), {'session_id': 's'});
  });

  test('start sends identity and decodes pending JSON', () async {
    expect(
      await WasmWatchNative.start(
          release: '1.0', environment: 'prod', installId: 'install'),
      [valid],
    );
    expect(calls.single.method, 'start');
    expect(calls.single.arguments,
        {'release': '1.0', 'environment': 'prod', 'install_id': 'install'});
  });

  test('scope is JSON and ack forwards ids', () async {
    await WasmWatchNative.setScope({
      'tags': {'emoji': '🐈'},
      'user': null
    });
    await WasmWatchNative.ack(['a', 'b']);
    expect(calls[0].method, 'setScope');
    expect(jsonDecode(calls[0].arguments as String), {
      'tags': {'emoji': '🐈'},
      'user': null
    });
    expect(calls[1].method, 'ack');
    expect(calls[1].arguments, ['a', 'b']);
  });

  test('malformed entries are skipped independently', () async {
    messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
              'broken',
              'null',
              '[]',
              '42',
              '{}',
              7,
              null,
              jsonEncode({...valid, 'v': 2}),
              jsonEncode({...valid, 'pid': '12'}),
              jsonEncode({...valid, 'environment': []}),
              jsonEncode({...valid, 'kind': 'unknown'}),
              jsonEncode(valid),
            ]);
    expect(await WasmWatchNative.start(release: 'r', installId: 'i'), [valid]);
  });

  test('iOS registration decodes diagnostics and forwards late notifications',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final ios = {...valid, 'kind': 'ios_crash', 'received_ms': 123}
      ..remove('timestamp_ms')
      ..remove('pid');
    messenger.setMockMethodCallHandler(channel, (_) async => [jsonEncode(ios)]);
    WasmWatchNativeIOS.registerWith();
    final bridge = NativeCrashBridge.instance!;
    expect(await bridge.start(release: 'r', installId: 'i'), [ios]);
    final notified = bridge.reportsAvailable!.first;
    await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('reportsAvailable')),
        (_) {});
    await notified;
  });

  test('unexpected result type and null return no reports', () async {
    for (final result in [
      null,
      'bad',
      2,
      {'pending': []}
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => result);
      expect(
          await WasmWatchNative.start(release: 'r', installId: 'i'), isEmpty);
    }
  });

  test('unsupported platforms never call the channel', () async {
    for (final platform in TargetPlatform.values) {
      if (platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS) {
        continue;
      }
      debugDefaultTargetPlatformOverride = platform;
      expect(
          await WasmWatchNative.start(release: 'r', installId: 'i'), isEmpty);
      await WasmWatchNative.setScope({});
      await WasmWatchNative.ack(['a']);
    }
    expect(calls, isEmpty);
  });
}
