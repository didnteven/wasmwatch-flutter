import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('mobile platforms send the placeholder ELF image and desktop keeps dart',
      () async {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      ErrorEvent? captured;
      final client = WasmWatchClient(WasmWatchOptions(
        dsn: 'http://key@localhost/api/v1/1',
        release: '1.2.3',
        sendDefaultContext: false,
        beforeSend: (event) {
          captured = event;
          return null;
        },
      ));
      await client.captureException(StateError('metadata'),
          stackTrace:
              StackTrace.fromString('#0 f (package:app/main.dart:12:3)'));
      final mobile =
          platform == TargetPlatform.iOS || platform == TargetPlatform.android;
      expect(
          captured!.platform,
          mobile
              ? platform == TargetPlatform.iOS
                  ? 'dart-ios'
                  : 'dart-android'
              : 'dart');
      if (mobile) {
        expect(captured!.debugMeta.images.single.toJson(), {
          'type': 'elf',
          'debug_id': '00000000-0000-7000-8000-000000000000',
          'code_file': platform == TargetPlatform.iOS
              ? 'App.framework/App'
              : 'libapp.so',
          'os': platform == TargetPlatform.iOS ? 'ios' : 'android',
          'release': '1.2.3',
        });
      }
    }
  });

  test(
      'explicit ELF metadata serializes its optional fields without offset_kind',
      () {
    const image = DebugImage(
      type: 'elf',
      debugId: 'cf0b2495-2342-73b1-bc3a-bc637819102a',
      codeFile: 'libapp.so',
      buildId: '0123456789abcdef',
      os: 'android',
      arch: 'arm64',
    );
    expect(image.toJson(), {
      'type': 'elf',
      'debug_id': 'cf0b2495-2342-73b1-bc3a-bc637819102a',
      'code_file': 'libapp.so',
      'build_id': '0123456789abcdef',
      'os': 'android',
      'arch': 'arm64',
    });
  });

  test('default image JSON retains the existing web bytes', () {
    const image = DebugImage(
      debugId: '00000000-0000-7000-8000-000000000000',
      codeFile: 'main.dart.wasm',
      offsetKind: WasmOffsetKind.moduleRelative,
      release: 'web-release',
      debugFile: 'main.dart.wasm.map',
    );
    final expected = <String, Object?>{
      'type': kIsWasm ? 'wasm' : 'js',
      'debug_id': image.debugId,
      'code_file': kIsWasm ? image.codeFile : 'main.dart.js',
      'offset_kind': 'module_relative',
      'release': 'web-release',
      'debug_file': 'main.dart.wasm.map',
    };
    expect(jsonEncode(image.toJson()), jsonEncode(expected));
  });
}
