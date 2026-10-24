import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';
import 'package:wasmwatch/src/native/dart_stack_parser.dart';

void main() {
  test(
      'parses readable VM frames, closures, async gaps and optional coordinates',
      () {
    const stack = '#0      HomePage._load (package:app/home.dart:42:10)\r\n'
        '#1      HomePage.build.<anonymous closure> (package:app/home.dart:51)\r\n'
        '<asynchronous suspension>\r\n'
        '#2      _rootRun (dart:async/zone.dart)\r\n'
        '#3      main (file:///app/lib/main.dart:12:3)\r\n';
    final frames = DartStackTraceParser.parse(stack);
    expect(frames, hasLength(4));
    expect(frames.first.toJson(), {
      'type': 'dart',
      'source_file': 'package:app/home.dart',
      'line': 42,
      'column': 10,
      'function_name': 'HomePage._load',
      'in_app': true,
      'raw_line': '#0      HomePage._load (package:app/home.dart:42:10)',
    });
    expect(frames[1].functionName, 'HomePage.build.<anonymous closure>');
    expect(frames[1].sourceFile, 'package:app/home.dart');
    expect(frames[1].line, 51);
    expect(frames[1].column, isNull);
    expect(frames[2].sourceFile, 'dart:async/zone.dart');
    expect(frames[2].toJson().containsKey('line'), false);
    expect(frames[2].toJson().containsKey('column'), false);
    expect(frames[3].sourceFile, 'file:///app/lib/main.dart');
    expect(frames[3].line, 12);
    expect(frames[3].column, 3);
  });

  test(
      'marks SDK and Flutter frames out of app without excluding other packages',
      () {
    for (final entry in {
      'dart:async/future.dart': false,
      'package:flutter/src/widgets/framework.dart': false,
      'package:flutter_test/src/binding.dart': false,
      'package:wasmwatch/src/client.dart': false,
      'package:app/home.dart': true,
      'package:flutter_helpers/helpers.dart': true,
      'file:///app/main.dart': true,
    }.entries) {
      final frame =
          DartStackTraceParser.parse('#0 f (${entry.key}:12:3)').single;
      expect(frame.type, StackFrameType.dart);
      expect(frame.inApp, entry.value, reason: entry.key);
    }
  });

  test(
      'retains unmatched evidence verbatim and ignores only blank lines and async gaps',
      () {
    for (final line in [
      'opaque VM line',
      '    #00 abs 00000001063e3a5b virt 000000000002fa5b _kDartIsolateSnapshotInstructions+0x1f65b',
      "build_id: '7D0E1A5F9C0A3B2E4F6A8B9C0D1E2F30'",
      '#0 f (package:app/main.dart:0:3)',
      '#0 f (package:app/main.dart:12:4294967296)',
    ]) {
      final frame =
          DartStackTraceParser.parse('$line\n  <asynchronous suspension>  \n\n')
              .single;
      expect(frame.type, StackFrameType.raw);
      expect(frame.rawLine, line);
    }
    expect(DartStackTraceParser.parse(' \n\r\n'), isEmpty);
  });

  test(
      'client trims repeated Dart frames and keeps the existing 50 frame limit',
      () async {
    ErrorEvent? captured;
    final client = WasmWatchClient(WasmWatchOptions(
      dsn: 'http://key@localhost/api/v1/1',
      sendDefaultContext: false,
      beforeSend: (event) {
        captured = event;
        return null;
      },
    ));
    final lines =
        List.generate(60, (i) => '#$i f$i (package:app/main.dart:12:3)');
    await client.captureException(StateError('recursion'),
        stackTrace: StackTrace.fromString(
            lines.expand((line) => [line, line]).join('\n')),
        trimRecursion: true);
    expect(captured!.frames, hasLength(50));
    expect(captured!.frames.every((f) => f.type == StackFrameType.dart), true);
    expect(captured!.frames.map((f) => f.rawLine).toSet(), hasLength(50));
    expect(captured!.frames.last.functionName, 'f49');
  });

  test('parses every readable frame captured from Android and iOS release builds', () {
    // Mobile spike Q4: release frames carry a line (rarely none) but never a column, on both platforms.
    for (final name in ['sync', 'closure', 'cast', 'custom', 'null', 'range', 'async', 'current']
        .expand((name) => [name, 'ios-$name'])) {
      final text = File('test/fixtures/dart_aot/$name.trace.txt').readAsStringSync();
      final frames = DartStackTraceParser.parse(text);
      expect(frames, hasLength(RegExp(r'^#\d+', multiLine: true).allMatches(text).length), reason: name);
      for (final frame in frames) {
        expect(frame.type, StackFrameType.dart, reason: frame.rawLine);
        expect(frame.column, isNull, reason: frame.rawLine);
        expect(frame.sourceFile, matches(RegExp(r'^(package|dart):')), reason: frame.rawLine);
      }
    }
    final sync = DartStackTraceParser.parse(File('test/fixtures/dart_aot/sync.trace.txt').readAsStringSync());
    expect([sync.first.functionName, sync.first.sourceFile, sync.first.line], ['Basket._sum', 'package:spike_app/main.dart', 20]);
    final range = DartStackTraceParser.parse(File('test/fixtures/dart_aot/range.trace.txt').readAsStringSync());
    expect([range.first.functionName, range.first.sourceFile, range.first.line], ['runScenarios.<anonymous closure>', 'package:spike_app/main.dart', null]);
    final closure = DartStackTraceParser.parse(File('test/fixtures/dart_aot/closure.trace.txt').readAsStringSync());
    expect(closure.first.functionName, 'runScenarios.<anonymous closure>.<anonymous closure>');
    expect(closure[3].functionName, 'new _GrowableList._ofEfficientLengthIterable');
    // The iOS captures come from a later spike_main.dart with six more lines.
    final iosSync = DartStackTraceParser.parse(File('test/fixtures/dart_aot/ios-sync.trace.txt').readAsStringSync());
    expect([iosSync.first.functionName, iosSync.first.sourceFile, iosSync.first.line], ['Basket._sum', 'package:spike_app/main.dart', 26]);
    final iosRange = DartStackTraceParser.parse(File('test/fixtures/dart_aot/ios-range.trace.txt').readAsStringSync());
    expect(iosRange.first.line, isNull);
  });
}
