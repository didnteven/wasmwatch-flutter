import 'dart:io';
import 'dart:ui';

bool get deviceContextAvailable => Platform.isIOS || Platform.isAndroid;

Object? readDeviceValue(String path) {
  final dispatcher = PlatformDispatcher.instance;
  switch (path) {
    case 'os':
      return Platform.operatingSystem;
    case 'os.version':
      return Platform.operatingSystemVersion;
    case 'locale':
      return dispatcher.locale.toLanguageTag();
    case 'timezone':
      return DateTime.now().timeZoneName;
    case 'view.width':
    case 'view.height':
    case 'view.pixel_ratio':
      if (dispatcher.views.isEmpty) return null;
      final view = dispatcher.views.first;
      return switch (path) {
        'view.width' => view.physicalSize.width,
        'view.height' => view.physicalSize.height,
        _ => view.devicePixelRatio,
      };
    default:
      return null;
  }
}
