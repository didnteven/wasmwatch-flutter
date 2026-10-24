import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/src/version.dart';

void main() {
  test('SDK envelope version matches pubspec', () {
    final version = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync())!
        .group(1);
    expect(version, wasmwatchSdkVersion);
  });
}
