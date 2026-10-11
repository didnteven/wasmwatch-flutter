import 'package:wasmwatch/src/utils/consecutive_loop_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/src/web/capture_deduplicator.dart';
import 'package:wasmwatch/src/web/browser_error_hooks_stub.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  final now = DateTime.utc(2026);
  test('content guard preserves independent cross-hook suppression', () {
    final identity = CaptureDeduplicator();
    final content = ConsecutiveLoopGuard();
    final error = Object();
    expect(content.record('Error', 'boom', 'stack', null, now), false);
    expect(identity.record(error, 'boom', 'stack', now), false);
    expect(content.record('Error', 'B', 'other', null, now), false);
    expect(content.record('Error', 'boom', 'stack', null, now), false);
    expect(identity.record(error, 'boom', 'stack', now, browser: true), true);
  });
  test('shares a two-second window across capture paths', () {
    final buffer = CaptureDeduplicator();
    expect(buffer.record(Object(), 'StateError: boom', 'stack', now), false);
    expect(
        buffer.record(Object(), 'boom', 'stack',
            now.add(const Duration(milliseconds: 1900)),
            browser: true),
        true);
    expect(
        buffer.record(
            Object(), 'boom', 'stack', now.add(const Duration(seconds: 2)),
            browser: true),
        false);
  });
  test('bounds memory and preserves different throw sites', () {
    final buffer = CaptureDeduplicator();
    for (var i = 0; i < 33; i++) {
      buffer.record(Object(), 'error $i', 'stack', now);
    }
    expect(
        buffer.record(Object(), 'error 0', 'stack', now, browser: true), false);
    expect(
        buffer.record(Object(), 'error 32', 'other stack', now, browser: true),
        false);
  });
  test('does not deduplicate separate ordinary Dart exceptions', () {
    final buffer = CaptureDeduplicator();
    expect(buffer.record(Object(), 'boom', null, now), false);
    expect(buffer.record(Object(), 'boom', null, now), false);
  });
  test('matches missing stacks and retains identity deduplication', () {
    final buffer = CaptureDeduplicator();
    final error = Object();
    expect(buffer.record(error, 'boom', null, now), false);
    expect(buffer.record(error, 'boom', null, now), true);
    expect(buffer.record(Object(), 'boom', 'stack', now, browser: true), true);
  });
  test('normalizes JS stack headers and indentation across paths', () {
    final buffer = CaptureDeduplicator();
    buffer.record(Object(), 'boom', '    at work (main.js:1:2)', now);
    expect(
        buffer.record(
            Object(), 'boom', 'Error: boom\n  at work (main.js:1:2)', now,
            browser: true),
        true);
  });
  test('explicit capture callers still observe SDK failures', () async {
    final error = StateError('beforeSend failed');
    final client = WasmWatchClient(WasmWatchOptions(
      dsn: 'https://key@example.com/v1/project',
      beforeSend: (_) => throw error,
    ));
    addTearDown(client.transport.close);
    await expectLater(
        client.captureException(Exception('original')), throwsA(same(error)));
  });
  test('browser options default on and VM hooks are harmless', () async {
    const options = WasmWatchOptions(dsn: 'https://key@example.com/v1/project');
    expect(options.captureBrowserErrors, true);
    expect(options.captureUnhandledRejections, true);
    expect(options.ignoreCrossOriginScriptErrors, true);
    final client = WasmWatchClient(options);
    final hooks = BrowserErrorHooks()..install(client);
    hooks.close();
    hooks.close();
    await WasmWatch.init(options: options, client: client);
    await WasmWatch.close();
    await WasmWatch.close();
    expect(() => WasmWatch.hub, throwsStateError);
  });
}
