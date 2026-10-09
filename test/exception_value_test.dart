import 'package:test/test.dart';
import 'package:wasmwatch/src/client.dart';
import 'package:wasmwatch/src/event/error_event.dart';
import 'package:wasmwatch/src/options.dart';
import 'package:wasmwatch/src/transport/http_transport.dart';
import 'package:wasmwatch/src/utils/exception_type.dart';

class _Prefixed implements Exception {
  @override
  String toString() => '_Prefixed: broke';
}

class _Plain implements Exception {
  @override
  String toString() => 'something broke';
}

class _Throws implements Exception {
  @override
  String toString() => throw StateError('no');
}

String value(Object e) => describeExceptionValue(e, describeExceptionType(e));

class _FakeTransport extends HttpTransport {
  _FakeTransport(super.dsn);
  @override
  Future<bool> send(String envelope) async => true;
}

void main() {
  group('describeExceptionValue', () {
    test('FormatException with message', () {
      expect(value(const FormatException('bad input')), 'bad input');
    });

    test('FormatException with source and offset', () {
      final v = value(const FormatException('bad input', 'abc', 1));
      expect(v, startsWith('bad input'));
      expect(v, contains('abc'));
      expect(v, isNot(startsWith('FormatException')));
    });

    test('FormatException without message is unchanged', () {
      expect(value(const FormatException()), 'FormatException');
    });

    test('StateError, ArgumentError.value have no type prefix and are unchanged', () {
      expect(value(StateError('oops')), 'Bad state: oops');
      final arg = ArgumentError.value(5, 'n', 'too big');
      expect(value(arg), arg.toString());
      expect(value(arg), isNot(startsWith('ArgumentError')));
    });

    test('RangeError.index keeps the detail after the message', () {
      final e = RangeError.index(3, [0], 'index');
      expect(e.toString(), startsWith('RangeError (index): '));
      final v = value(e);
      expect(v, startsWith('Index out of range'));
      expect(v, endsWith('(index)'));
      expect(v, isNot(contains('RangeError')));
    });

    test('IndexError maps to RangeError and is stripped', () {
      expect(describeExceptionValue('IndexError: bad', 'RangeError'), 'bad');
      expect(describeExceptionValue('RangeError (end): Invalid value', 'RangeError'), 'Invalid value (end)');
    });

    test('plain Exception and Error prefixes', () {
      expect(value(Exception('x')), 'x');
      expect(describeExceptionValue('Error: y', 'Error'), 'y');
    });

    test('custom exception with and without prefix', () {
      expect(value(_Prefixed()), 'broke');
      expect(value(_Plain()), 'something broke');
    });

    test('non-redundant prefix and later mentions are unchanged', () {
      expect(describeExceptionValue('Exception: x', '_MessageException'), 'Exception: x');
      expect(describeExceptionValue('failed with FormatException: x', 'FormatException'), 'failed with FormatException: x');
    });

    test('empty message keeps the original toString', () {
      expect(describeExceptionValue('FormatException: ', 'FormatException'), 'FormatException: ');
      expect(value(_Throws()), '');
    });
  });

  group('captureException', () {
    Future<ErrorEvent> capture(Object error, {String? hint}) async {
      ErrorEvent? captured;
      final options = WasmWatchOptions(
        dsn: 'https://key@example.com/1/2',
        beforeSend: (event) {
          captured = event;
          return event;
        },
      );
      final client = WasmWatchClient(options, transport: _FakeTransport(options.parsedDsn));
      await client.captureException(error, hint: hint);
      return captured!;
    }

    test('value has no duplicated type prefix and type is unchanged', () async {
      final event = await capture(const FormatException('bad input'));
      expect(event.exceptionType, 'FormatException');
      expect(event.exceptionValue, 'bad input');
    });

    test('hint is prepended to the stripped value', () async {
      final event = await capture(const FormatException('bad input'), hint: 'parse');
      expect(event.exceptionType, 'FormatException');
      expect(event.exceptionValue, 'parse: bad input');
    });
  });
}
