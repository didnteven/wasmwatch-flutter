import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/wasmwatch.dart';
import 'package:wasmwatch/src/integrations/device_context.dart';
import 'package:wasmwatch/src/integrations/device_context_stub.dart' as stub;

void main() {
  test(
      'collects mobile OS, logical screen, culture, runtime and a stable session',
      () {
    final data = <String, Object?>{
      'os': 'android',
      'os.version': 'Android 14 (API 34)',
      'view.width': 1080,
      'view.height': 2400,
      'view.pixel_ratio': 3,
      'locale': 'en-NZ',
      'timezone': 'NZDT',
    };
    final integration = DeviceContextIntegration(read: (path) => data[path]);
    final first = integration.capture();
    expect(first['os'], {'name': 'Android', 'version': '14'});
    expect(first['device'], {'type': 'mobile'});
    expect(first['screen'], {'width': 360, 'height': 800, 'pixel_ratio': 3});
    expect(first['culture'], {'locale': 'en-NZ', 'timezone': 'NZDT'});
    expect(first['runtime'], {'name': 'flutter', 'mode': 'debug'});
    final session = first['session'] as Map;
    expect(
        session['id'],
        matches(RegExp(
            r'^[\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}$')));
    expect(DateTime.parse(session['started_at'] as String).isUtc, true);
    data['view.width'] = 2400;
    data['view.height'] = 1800;
    final next = integration.capture();
    expect(next['screen'], {'width': 800, 'height': 600, 'pixel_ratio': 3});
    expect(next['device'], {'type': 'tablet'});
    expect(next['session'], session);
    expect(
        DeviceContextIntegration(read: (path) => data[path])
            .capture()['session'],
        session);
    data['view.height'] = 1797;
    expect(integration.capture()['device'], {'type': 'mobile'});
  });

  test('normalizes iOS versions and retains unknown OS version evidence', () {
    final data = <String, Object?>{
      'os': 'ios',
      'os.version': 'Version 18.1.2 (Build 22B91)'
    };
    final integration = DeviceContextIntegration(read: (path) => data[path]);
    expect(integration.capture()['os'], {'name': 'iOS', 'version': '18.1.2'});
    // Captured from an iPhone release build (mobile spike Q5).
    data['os.version'] = 'Version 27.2 (Build 24B5084k)';
    expect(integration.capture()['os'], {'name': 'iOS', 'version': '27.2'});
    data['os'] = 'android';
    data['os.version'] = 'Linux 6.1.0 vendor build';
    expect(integration.capture()['os'],
        {'name': 'Android', 'build': 'Linux 6.1.0 vendor build'});
    // Captured from an Android 16 emulator release build (mobile spike Q5).
    data['os.version'] = 'BP41.250916.009.A1';
    expect(integration.capture()['os'],
        {'name': 'Android', 'build': 'BP41.250916.009.A1'});
  });

  test('missing or hostile sources and unavailable views do not throw', () {
    for (final read in <DeviceValueSource>[
      (p) => null,
      (p) => throw StateError('blocked')
    ]) {
      expect(DeviceContextIntegration(read: read).capture(), isEmpty);
    }
    for (final ratio in [null, 0, double.nan, double.infinity]) {
      final integration = DeviceContextIntegration(
          read: (path) => {
                'os': 'ios',
                'view.width': 1200,
                'view.height': 2400,
                'view.pixel_ratio': ratio,
              }[path]);
      expect(integration.capture()['screen'], isEmpty);
      expect(integration.capture()['device'], {'type': 'mobile'});
    }
    final noView =
        DeviceContextIntegration(read: (path) => path == 'os' ? 'ios' : null)
            .capture();
    expect(noView['screen'], isEmpty);
    expect(noView['os'], {'name': 'iOS'});
    expect(stub.deviceContextAvailable, false);
    expect(stub.readDeviceValue('os'), isNull);
  });

  test(
      'client falls back to device context, preserves overrides and derives tags',
      () async {
    final device = DeviceContextIntegration(
        read: (path) => {
              'os': 'android',
              'os.version': 'Android 14',
              'view.width': 2400,
              'view.height': 1800,
              'view.pixel_ratio': 3,
            }[path]);
    ErrorEvent? captured;
    final client = WasmWatchClient(
        WasmWatchOptions(
          dsn: 'http://key@localhost/api/v1/1',
          beforeSend: (event) {
            captured = event;
            return null;
          },
        ),
        deviceContext: device);
    await client.captureException(StateError('defaults'));
    expect(captured!.contexts['os'], {'name': 'Android', 'version': '14'});
    expect(captured!.tags['os'], 'Android');
    expect(captured!.tags['device.type'], 'tablet');
    final scope = Scope()
      ..setContext('device', {'type': 'custom', 'model': 'My device'});
    await client
        .captureException(StateError('overrides'), scope: scope, contexts: {
      'os': {'name': 'custom OS'}
    }, tags: {
      'os': 'explicit tag'
    });
    expect(captured!.contexts['os'], {'name': 'custom OS'});
    expect(
        captured!.contexts['device'], {'type': 'custom', 'model': 'My device'});
    expect(captured!.tags['os'], 'explicit tag');
    expect(captured!.tags['device.type'], 'custom');
    final disabled = WasmWatchClient(
        WasmWatchOptions(
          dsn: 'http://key@localhost/api/v1/1',
          sendDefaultContext: false,
          beforeSend: (event) {
            captured = event;
            return null;
          },
        ),
        deviceContext: device);
    await disabled.captureException(StateError('disabled'));
    expect(captured!.contexts, isEmpty);
    expect(captured!.tags, isEmpty);
  });
}
