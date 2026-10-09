import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  const dsn = String.fromEnvironment('WASMWATCH_DSN');
  const release = String.fromEnvironment('WASMWATCH_RELEASE');
  const environment = String.fromEnvironment('WASMWATCH_ENVIRONMENT');
  test('dart-define DSN, release and environment reach captured events',
      () async {
    final events = <ErrorEvent>[];
    try {
      await WasmWatch.init(appRunner: () async {
        final client = WasmWatch.hub.client;
        expect(client.options.dsn, dsn);
        // Retain detected metadata while replacing delivery with an in-memory sink.
        client.options = WasmWatchOptions(
          dsn: client.options.dsn,
          release: client.options.release,
          environment: client.options.environment,
          beforeSend: (event) {
            events.add(event);
            return null;
          },
        );
        await WasmWatch.captureException(StateError('defined metadata'));
      });
      expect(events.single.release, release);
      expect(events.single.environment, environment);
    } finally {
      await WasmWatch.close();
    }
  }, skip: dsn.isEmpty || release.isEmpty || environment.isEmpty);
}
