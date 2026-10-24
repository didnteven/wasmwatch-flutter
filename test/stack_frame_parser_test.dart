import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  test('browser JS formats retain one based coordinates', () {
    for (final line in [
      'at fn (https://example.test/main.dart.js:123:45)',
      'at https://example.test/main.dart.js:123:45',
      'fn@https://example.test/main.dart.js:123:45',
      '@https://example.test/main.dart.js:123:45',
      'global code@https://example.test/main.dart.js:123:45',
    ]) {
      final frame = WasmStackFrameParser.parseLine(line);
      expect(frame.type, StackFrameType.js, reason: line);
      expect(frame.sourceFile, 'https://example.test/main.dart.js');
      expect(frame.line, 123);
      expect(frame.column, 45);
    }
    final safari = WasmStackFrameParser.parseLine('fn@https://example.test/main.dart.js:123');
    expect(safari.line, 123);
    expect(safari.column, isNull);
  });
  test('retains every non-header line and parses V8 wasm offsets', () {
    final frames = WasmStackFrameParser.parse('Error: boom\n    at wasm-function[312]:0x1a4\n    at wasm-stub\n');
    expect(frames, hasLength(2));
    expect(frames.first.type, StackFrameType.wasm);
    expect(frames.first.functionIndex, 312);
    expect(frames.first.byteOffset, 420);
    expect(frames.first.offsetKind, WasmOffsetKind.moduleRelative);
    expect(frames.last.type, StackFrameType.raw);
    expect(frames.last.rawLine, '    at wasm-stub');
  });

  test('parses SpiderMonkey function-relative evidence without invented offset', () {
    final frame = WasmStackFrameParser.parse('Error\nload@wasm-function[7]:12:34').single;
    expect(frame.functionName, 'load');
    expect(frame.functionIndex, 7);
    expect(frame.byteOffset, isNull);
    expect(frame.offsetKind, WasmOffsetKind.functionRelative);
  });

  test('retains JS and opaque lines exactly once', () {
    final frames = WasmStackFrameParser.parse('TypeError\nat Module.main (main.dart.js:3:4)\nWebKit wasm-stub');
    expect(frames.map((f) => f.rawLine), ['at Module.main (main.dart.js:3:4)', 'WebKit wasm-stub']);
    expect(frames.first.type, StackFrameType.js);
    expect(frames.last.type, StackFrameType.raw);
  });

  test('parses real V8 dart2wasm frames that carry the module URL and a U+0001 name prefix', () {
    const stack = 'FormatException: not-a-price\n'
        '    at \u0001.int._handleFormatError (http://127.0.0.1:8088/main.dart.wasm:wasm-function[1646]:0xd0502)\n'
        '    at \u0001.runWasmWatchTestError inner (http://127.0.0.1:8088/main.dart.wasm:wasm-function[3014]:0xf6fbc)\n'
        '    at http://127.0.0.1:8088/main.dart.wasm:wasm-function[12]:0x1a\n';
    final frames = WasmStackFrameParser.parse(stack);
    expect(frames, hasLength(3));
    expect(frames[0].functionIndex, 1646);
    expect(frames[0].byteOffset, 0xd0502);
    expect(frames[0].offsetKind, WasmOffsetKind.moduleRelative);
    expect(frames[0].functionName, '.int._handleFormatError');
    expect(frames[1].functionName, '.runWasmWatchTestError inner');
    expect(frames[1].byteOffset, 0xf6fbc);
    expect(frames[2].functionIndex, 12);
    expect(frames[2].functionName, isNull);
  });
}
