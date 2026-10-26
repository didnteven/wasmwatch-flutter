enum WasmOffsetKind { moduleRelative, functionRelative, unknown }

extension WasmOffsetKindWire on WasmOffsetKind {
  String get wire => switch (this) {
        WasmOffsetKind.moduleRelative => 'module_relative',
        WasmOffsetKind.functionRelative => 'function_relative',
        WasmOffsetKind.unknown => 'unknown',
      };
}

enum StackFrameType { wasm, js, dart, dartAot, raw, java, native }

class RawStackFrame {
  const RawStackFrame._({
    required this.type,
    required this.rawLine,
    this.functionIndex,
    this.byteOffset,
    this.offsetKind = WasmOffsetKind.unknown,
    this.functionName,
    this.sourceFile,
    this.line,
    this.column,
    this.inApp = false,
    this.absoluteAddress,
    this.relativeAddress,
    this.symbol,
    this.symbolOffset,
    Map<String, Object?>? wire,
  }) : _wire = wire;

  /// A validated Android Java or native frame.
  factory RawStackFrame.android(Map<String, Object?> wire) => RawStackFrame._(
        type: wire['type'] == 'java'
            ? StackFrameType.java
            : StackFrameType.native,
        rawLine: '',
        functionName: wire['function'] as String?,
        sourceFile: wire['filename'] as String?,
        line: wire['lineno'] as int?,
        symbol: wire['symbol'] as String?,
        symbolOffset: wire['symbol_offset'] as String?,
        wire: Map.unmodifiable(wire),
      );
  final Map<String, Object?>? _wire;

  factory RawStackFrame.wasm({
    required int functionIndex,
    required String rawLine,
    int? byteOffset,
    WasmOffsetKind offsetKind = WasmOffsetKind.unknown,
    String? functionName,
  }) =>
      RawStackFrame._(
        type: StackFrameType.wasm,
        rawLine: rawLine,
        functionIndex: functionIndex,
        byteOffset: byteOffset,
        offsetKind: offsetKind,
        functionName: functionName,
        inApp: true,
      );

  factory RawStackFrame.js({
    required String rawLine,
    required String sourceFile,
    String? functionName,
    int? line,
    int? column,
  }) =>
      RawStackFrame._(
        type: StackFrameType.js,
        rawLine: rawLine,
        sourceFile: sourceFile,
        functionName: functionName,
        line: line,
        column: column,
        inApp: sourceFile.contains('.dart') || sourceFile.contains('main.'),
      );

  factory RawStackFrame.dart({
    required String rawLine,
    required String sourceFile,
    String? functionName,
    int? line,
    int? column,
  }) =>
      RawStackFrame._(
        type: StackFrameType.dart,
        rawLine: rawLine,
        sourceFile: sourceFile,
        functionName: functionName,
        line: line,
        column: column,
        inApp: !sourceFile.startsWith('dart:') &&
            !sourceFile.startsWith('package:flutter/') &&
            !sourceFile.startsWith('package:flutter_test/') &&
            !sourceFile.startsWith('package:wasmwatch/'),
      );

  factory RawStackFrame.raw({required String rawLine}) =>
      RawStackFrame._(type: StackFrameType.raw, rawLine: rawLine);

  factory RawStackFrame.dartAot({
    required String rawLine,
    required String absoluteAddress,
    String? relativeAddress,
    String? symbol,
    String? symbolOffset,
  }) =>
      RawStackFrame._(
        type: StackFrameType.dartAot,
        rawLine: rawLine,
        absoluteAddress: absoluteAddress,
        relativeAddress: relativeAddress,
        symbol: symbol,
        symbolOffset: symbolOffset,
      );

  final StackFrameType type;
  final String rawLine;
  final int? functionIndex;
  final int? byteOffset;
  final WasmOffsetKind offsetKind;
  final String? functionName;
  final String? sourceFile;
  final int? line;
  final int? column;
  final bool inApp;
  final String? absoluteAddress;
  final String? relativeAddress;
  final String? symbol;
  final String? symbolOffset;

  Map<String, Object?> toJson() => switch (type) {
        StackFrameType.java || StackFrameType.native => _wire!,
        StackFrameType.wasm => {
            'type': 'wasm',
            'wasm_function_index': functionIndex,
            if (byteOffset != null) 'wasm_offset': byteOffset,
            'offset_kind': offsetKind.wire,
            if (functionName != null) 'function_name': functionName,
            'in_app': inApp,
            'raw_line': rawLine,
          },
        StackFrameType.js => {
            'type': 'js',
            'source_file': sourceFile,
            if (line != null) 'line': line,
            if (column != null) 'column': column,
            if (functionName != null) 'function_name': functionName,
            'in_app': inApp,
            'raw_line': rawLine,
          },
        StackFrameType.dart => {
            'type': 'dart',
            'source_file': sourceFile,
            if (line != null) 'line': line,
            if (column != null) 'column': column,
            if (functionName != null) 'function_name': functionName,
            'in_app': inApp,
            'raw_line': rawLine,
          },
        StackFrameType.dartAot => {
            'type': 'dart_aot',
            'absolute_address': absoluteAddress,
            if (relativeAddress != null) 'relative_address': relativeAddress,
            if (symbol != null) 'symbol': symbol,
            if (symbolOffset != null) 'symbol_offset': symbolOffset,
            'in_app': false,
            'raw_line': rawLine,
          },
        StackFrameType.raw => {
            'type': 'raw',
            'raw_line': rawLine,
            'in_app': false
          },
      };
}

/// Parses one structured frame for every non-header input line. Offset kind is
/// deliberately conservative: V8's `0x` offset is module-relative, while
/// Firefox's line/column representation is function-relative.
class WasmStackFrameParser {
  // V8 prints `at NAME (URL:wasm-function[N]:0xOFFSET)`; the module URL is optional in
  // synthetic corpora but always present in real browsers, so both must parse.
  static final RegExp _v8Wasm = RegExp(
    r'^\s*at\s+(?:(.*?)\s*\()?(?:\S*?:)?wasm-function\[(\d+)\](?::0x([0-9a-f]+))?\)?\s*$',
    caseSensitive: false,
  );
  static final RegExp _firefoxWasm = RegExp(
    r'^\s*(?:(.*?)@)?wasm-function\[(\d+)\](?::(\d+):(\d+))?\s*$',
    caseSensitive: false,
  );
  static final RegExp _v8Js = RegExp(
    r'^\s*at\s+(?:(.*?)\s*\()?(.+?):(\d+):(\d+)\)?\s*$',
  );
  static final RegExp _firefoxJs =
      RegExp(r'^\s*(.*?)@(.+?):(\d+)(?::(\d+))?\s*$');

  static List<RawStackFrame> parse(String stack) {
    final lines = stack.split(RegExp(r'\r?\n'));
    final start = lines.isNotEmpty && _isHeader(lines.first) ? 1 : 0;
    return [
      for (final line in lines.skip(start))
        if (line.isNotEmpty) parseLine(line)
    ];
  }

  static bool _isHeader(String line) =>
      !line.contains('wasm-function[') &&
      !line.trimLeft().startsWith('at ') &&
      !line.contains('@') &&
      RegExp(r'^(?:\w*(?:Error|Exception)|Error)(?::|$)').hasMatch(line.trim());

  static RawStackFrame parseLine(String rawLine) {
    final v8 = _v8Wasm.firstMatch(rawLine);
    if (v8 != null) {
      final offset = v8.group(3);
      return RawStackFrame.wasm(
        functionIndex: int.parse(v8.group(2)!),
        byteOffset: offset == null ? null : int.parse(offset, radix: 16),
        offsetKind: offset == null
            ? WasmOffsetKind.unknown
            : WasmOffsetKind.moduleRelative,
        functionName: _blankToNull(v8.group(1)),
        rawLine: rawLine,
      );
    }
    final firefox = _firefoxWasm.firstMatch(rawLine);
    if (firefox != null) {
      final line = firefox.group(3);
      final column = firefox.group(4);
      // Browser evidence expresses this as line/column, not a byte address.
      // Keep a calculated offset out of the event rather than inventing one.
      return RawStackFrame.wasm(
        functionIndex: int.parse(firefox.group(2)!),
        offsetKind: line == null || column == null
            ? WasmOffsetKind.unknown
            : WasmOffsetKind.functionRelative,
        functionName: _blankToNull(firefox.group(1)),
        rawLine: rawLine,
      );
    }
    final js = _v8Js.firstMatch(rawLine) ?? _firefoxJs.firstMatch(rawLine);
    if (js != null) {
      return RawStackFrame.js(
        rawLine: rawLine,
        functionName: _blankToNull(js.group(1)),
        sourceFile: js.group(2)!,
        line: int.parse(js.group(3)!),
        column: js.group(4) == null ? null : int.parse(js.group(4)!),
      );
    }
    // Includes WebKit's `wasm-stub`/opaque forms, retained verbatim.
    return RawStackFrame.raw(rawLine: rawLine);
  }

  static String? _blankToNull(String? value) {
    // dart2wasm prefixes function names with a U+0001 marker; drop control characters.
    final trimmed = (value ?? '').replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    return trimmed.isEmpty || trimmed == '<anonymous>' ? null : trimmed;
  }
}
