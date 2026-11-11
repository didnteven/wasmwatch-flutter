import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  ErrorEvent event({List<RawStackFrame> captureFrames = const []}) => ErrorEvent(
        eventId: '0190b3c0-7a3e-7000-8000-000000000001',
        timestamp: DateTime.utc(2026, 11, 11),
        exceptionType: 'StateError',
        exceptionValue: 'x',
        frames: const [],
        debugMeta: const DebugMeta(),
        captureFrames: captureFrames,
      );

  test('capture frames travel in extensions, and only when present', () {
    final frame = WasmStackFrameParser.parse('    at wasm://wasm/00:wasm-function[1]:0x10').single;
    final json = event(captureFrames: [frame]).toJson();
    final sent = (json['extensions']! as Map)['capture_frames'] as List;
    expect(sent.single, frame.toJson());
    expect(event().toJson().containsKey('extensions'), isFalse);
  });
}
