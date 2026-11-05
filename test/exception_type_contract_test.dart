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

  group('a minified runtime name falls back to the name the exception prints',
      () {
    const minified = 'minified:aU';

    test('DioException-style toString', () {
      expect(
          describeExceptionType(_Printing('DioException [bad response]: 404'),
              runtimeTypeName: minified),
          'DioException');
    });

    test('ClientException-style toString', () {
      expect(
          describeExceptionType(_Printing('ClientException: failed, uri=x'),
              runtimeTypeName: minified),
          'ClientException');
    });

    test('a bare Exception or Error prefix keeps the generic name', () {
      expect(
          describeExceptionType(_Printing('Exception: PaymentError happened'),
              runtimeTypeName: minified),
          'Exception');
    });

    test('a toString that is just a message keeps the generic name', () {
      expect(
          describeExceptionType(_Printing('something went wrong'),
              runtimeTypeName: minified),
          'Exception');
    });
  });
}

class _Printing implements Exception {
  _Printing(this.text);
  final String text;
  @override
  String toString() => text;
}
