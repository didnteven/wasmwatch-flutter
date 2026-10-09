import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:test/test.dart';
import 'package:wasmwatch/src/utils/exception_type.dart';

class _CustomError implements Exception {}

void main() {
  test('names core Dart error types without relying on runtimeType.toString',
      () {
    expect(describeExceptionType(RangeError.index(3, [0], 'index')),
        anyOf('RangeError', 'IndexError'));
    expect(describeExceptionType(StateError('x')), 'StateError');
    expect(
        describeExceptionType(const FormatException('x')), 'FormatException');
    expect(describeExceptionType(ArgumentError('x')), 'ArgumentError');
    expect(describeExceptionType(UnsupportedError('x')), 'UnsupportedError');
    expect(
        describeExceptionType(UnimplementedError('x')), 'UnimplementedError');
    expect(describeExceptionType(TimeoutException('x')), 'TimeoutException');
    expect(describeExceptionType(ConcurrentModificationError()),
        'ConcurrentModificationError');
    expect(describeExceptionType(AssertionError('x')), 'AssertionError');
    expect(describeExceptionType(FlutterError('x')), 'FlutterError');
  });

  test('never returns a minified: name and always returns a non-empty string',
      () {
    for (final e in <Object>[
      _CustomError(),
      Object(),
      42,
      'str',
      StateError('x')
    ]) {
      final name = describeExceptionType(e);
      expect(name, isNotEmpty);
      expect(name, isNot(startsWith('minified:')));
    }
  });

  test('keeps the readable runtime name for user classes where available', () {
    expect(describeExceptionType(_CustomError()),
        anyOf('_CustomError', 'Exception'));
  });
}
