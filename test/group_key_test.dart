import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('groupKey becomes the wasmwatch.group_key tag', () async {
    final events = <ErrorEvent>[];
    await WasmWatch.init(
        client: WasmWatchClient(WasmWatchOptions(
      dsn: 'https://key@example.com/v1/project',
      autoInstallFlutterErrorHandlers: false,
      captureLifecycleBreadcrumbs: false,
      captureBrowserErrors: false,
      captureUnhandledRejections: false,
      beforeSend: (event) {
        events.add(event);
        return null;
      },
    )));
    addTearDown(WasmWatch.close);
    await WasmWatch.captureException(StateError('a'), groupKey: ' loadJobs ');
    await WasmWatch.captureException(StateError('b'), groupKey: '  ');
    await WasmWatch.captureException(StateError('c'), groupKey: 'x' * 300);
    await WasmWatch.captureException(StateError('e'), groupKey: '😀' * 200);
    await WasmWatch.captureException(StateError('d'), withScope: (scope) {
      scope.setTag('wasmwatch.group_key', 'scoped');
    });
    expect(events[0].tags['wasmwatch.group_key'], 'loadJobs');
    expect(events[1].tags, isNot(contains('wasmwatch.group_key')));
    expect(events[2].tags['wasmwatch.group_key'], hasLength(128));
    expect(events[3].tags['wasmwatch.group_key'], '😀' * 128);
    expect(events[4].tags['wasmwatch.group_key'], 'scoped');
  });
}
