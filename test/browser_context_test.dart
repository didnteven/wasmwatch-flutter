import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/src/integrations/browser_context.dart';
import 'package:wasmwatch/src/options.dart';
import 'package:wasmwatch/src/event/breadcrumb.dart';

void main() {
  test('static and high entropy values are cached; dynamic values change', () async {
    final data = <String, Object?>{'navigator.userAgentData.brands': [{'brand':'Chromium','version':'130'}], 'navigator.userAgentData.mobile': true, 'navigator.userAgentData.platform':'Android', 'navigator.hardwareConcurrency':8, 'innerWidth':400, 'location.pathname':'/orders/12345'};
    final integration = BrowserContextIntegration(read: (path) => data[path], entropy: Future.value({'model':'Pixel','architecture':'arm','platformVersion':'14'}));
    await Future<void>.delayed(Duration.zero);
    final first = integration.capture([]);
    expect((first['browser'] as Map)['name'], 'Chromium');
    expect((first['device'] as Map)['model'], 'Pixel');
    expect((first['os'] as Map)['version'], '14');
    data['innerWidth'] = 800;
    final next = integration.capture([const Breadcrumb(category:'navigation',message:'/checkout')]);
    expect((next['viewport'] as Map)['width'], 800);
    expect((next['route'] as Map)['path'], '/checkout');
    expect(next['session'], first['session']);
    expect((next['session'] as Map)['id'], matches(RegExp(r'^[\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}$')));
  });
  test('missing and hostile APIs never throw', () {
    for (final read in <BrowserValueSource>[(p) => null, (p) => throw StateError('blocked')]) {
      expect(() => BrowserContextIntegration(read:read, entropy:Future.value({})).capture([]), returnsNormally);
    }
  });
  test('default context option survives resolution', () {
    const options = WasmWatchOptions(dsn:'https://key@example.com/v1/project',sendDefaultContext:false);
    expect(options.resolved().sendDefaultContext, false);
    expect(const WasmWatchOptions(dsn:'https://key@example.com/v1/project').sendDefaultContext,true);
  });
}
