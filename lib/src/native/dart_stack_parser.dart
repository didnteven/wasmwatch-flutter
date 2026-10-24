import '../wasm/stack_frame_parser.dart';

class DartAotHeader {
  const DartAotHeader({
    this.buildId,
    this.os,
    this.arch,
    this.isolateDsoBase,
    this.vmDsoBase,
  });

  final String? buildId;
  final String? os;
  final String? arch;
  final String? isolateDsoBase;
  final String? vmDsoBase;
}

class DartStackTraceParser {
  // Android and iOS release frames carry `file:line` (rarely no line, never a
  // column); see test/fixtures/dart_aot.
  static final _frame = RegExp(
    r'^#(\d+)\s+(.+?) \((.+?)(?::(\d+))?(?::(\d+))?\)$',
  );

  static final _aotFrame = RegExp(
    r'^#\d+\s+abs\s+((?:0x)?[0-9a-fA-F]{1,16})(?:\s+virt\s+((?:0x)?[0-9a-fA-F]{1,16}))?(?:\s+(_kDart(?:Isolate|Vm)SnapshotInstructions)(?:\+((?:0x)?[0-9a-fA-F]{1,16}))?)?$',
  );

  static DartAotHeader? parseAotHeader(String stack) {
    if (!stack.contains('*** *** ***')) return null;
    String? field(String name, String pattern) =>
        RegExp('(?:^|[\\s,])$name: *($pattern)', multiLine: true)
            .firstMatch(stack)
            ?.group(1);
    final buildId = field('build_id', "'[0-9a-fA-F]{8,64}'")
        ?.replaceAll("'", '')
        .toLowerCase();
    return DartAotHeader(
      buildId: buildId,
      os: field('os', r'android\b|ios\b'),
      arch: field('arch', r'arm64\b|arm\b|x64\b|ia32\b|riscv64\b'),
      isolateDsoBase:
          _hex(field('isolate_dso_base', r'(?:0x)?[0-9a-fA-F]{1,16}\b')),
      vmDsoBase: _hex(field('vm_dso_base', r'(?:0x)?[0-9a-fA-F]{1,16}\b')),
    );
  }

  static List<RawStackFrame> parse(String stack, {DartAotHeader? aotHeader}) {
    final header = parseAotHeader(stack);
    if (header != null) {
      return [
        for (final rawLine in stack.split(RegExp(r'\r?\n')))
          if (rawLine.trimLeft().startsWith('#'))
            _parseAotLine(rawLine, header),
      ];
    }
    return [
      for (final rawLine in stack.split(RegExp(r'\r?\n')))
        if (rawLine.trim().isNotEmpty &&
            rawLine.trim() != '<asynchronous suspension>')
          aotHeader != null && _aotFrame.hasMatch(rawLine.trim())
              ? _parseAotLine(rawLine, aotHeader)
              : _parseLine(rawLine),
    ];
  }

  static RawStackFrame _parseAotLine(String rawLine, DartAotHeader header) {
    final match = _aotFrame.firstMatch(rawLine.trim());
    if (match == null) return RawStackFrame.raw(rawLine: rawLine);
    final absolute = _hex(match.group(1))!;
    var relative = _hex(match.group(2));
    final symbol = match.group(3);
    final base = symbol == '_kDartVmSnapshotInstructions'
        ? header.vmDsoBase
        : header.isolateDsoBase;
    if (relative == null && base != null) {
      final offset =
          BigInt.parse(absolute, radix: 16) - BigInt.parse(base, radix: 16);
      if (!offset.isNegative) relative = offset.toRadixString(16);
    }
    return RawStackFrame.dartAot(
      rawLine: rawLine,
      absoluteAddress: absolute,
      relativeAddress: relative,
      symbol: symbol,
      symbolOffset: _hex(match.group(4)),
    );
  }

  static String? _hex(String? value) => value == null
      ? null
      : BigInt.parse(value.replaceFirst(RegExp(r'^0x'), ''), radix: 16)
          .toRadixString(16);

  static RawStackFrame _parseLine(String rawLine) {
    final match = _frame.firstMatch(rawLine.trim());
    if (match == null) return RawStackFrame.raw(rawLine: rawLine);
    final line = int.tryParse(match.group(4) ?? '');
    final column = int.tryParse(match.group(5) ?? '');
    if ((match.group(4) != null && !_validCoordinate(line)) ||
        (match.group(5) != null && !_validCoordinate(column))) {
      return RawStackFrame.raw(rawLine: rawLine);
    }
    return RawStackFrame.dart(
      rawLine: rawLine,
      sourceFile: match.group(3)!,
      functionName: match.group(2)!,
      line: line,
      column: column,
    );
  }

  static bool _validCoordinate(int? value) =>
      value != null && value >= 1 && value <= 0xffffffff;
}
