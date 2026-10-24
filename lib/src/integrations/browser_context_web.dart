import 'dart:js_interop';
import 'dart:js_interop_unsafe';
Object? readBrowserValue(String path) {
  try {
    if (path == 'timezone') {
      final intl = globalContext.getProperty<JSObject>('Intl'.toJS);
      final format = intl.getProperty<JSFunction>('DateTimeFormat'.toJS).callAsConstructor<JSObject>();
      final options = format.callMethod<JSObject>('resolvedOptions'.toJS);
      return options.getProperty<JSString>('timeZone'.toJS).toDart;
    }
    JSAny? value = globalContext;
    for (final part in path.split('.')) {
      value = (value as JSObject).getProperty<JSAny?>(part.toJS);
    }
    return value?.dartify();
  } catch (_) { return null; }
}
Future<Map<String, Object?>> highEntropyValues() async {
  try {
    final nav = globalContext.getProperty<JSObject>('navigator'.toJS);
    final data = nav.getProperty<JSObject>('userAgentData'.toJS);
    final result = await data.callMethod<JSPromise<JSAny?>>('getHighEntropyValues'.toJS,
      ['platformVersion', 'model', 'architecture', 'bitness'].jsify()).toDart;
    return Map<String, Object?>.from(result?.dartify() as Map);
  } catch (_) { return {}; }
}
bool get browserContextAvailable => true;
