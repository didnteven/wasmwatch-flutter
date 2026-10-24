import 'dart:math';
import 'package:flutter/foundation.dart';
import '../event/breadcrumb.dart';
import '../grouping/normalize.dart';
import 'browser_context_source.dart' as source;

typedef BrowserValueSource = Object? Function(String path);
/// All reads are guarded, including injected sources and optional browser APIs.
class BrowserContextIntegration {
  BrowserContextIntegration({BrowserValueSource? read, Future<Map<String, Object?>>? entropy})
      : _read = read ?? source.readBrowserValue,
        _enabled = read != null || source.browserContextAvailable {
    if (!_enabled) return;
    _static = _collectStatic();
    (entropy ?? source.highEntropyValues()).then((values) {
      _entropy = values;
      _static = _collectStatic();
    }).catchError((Object _) {});
  }
  final BrowserValueSource _read;
  final bool _enabled;
  Map<String, Object?> _entropy = {};
  Map<String, Object?> _static = {};
  static final _started = DateTime.now().toUtc().toIso8601String();
  static final _session = _uuid();
  static String _uuid() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0,8)}-${h.substring(8,12)}-${h.substring(12,16)}-${h.substring(16,20)}-${h.substring(20)}';
  }
  Object? _get(String path) { try { return _read(path); } catch (_) { return null; } }
  Map<String, Object?> _fields(Map<String, Object?> fields) => fields..removeWhere((k,v) => v == null || v == '');
  Map<String, Object?> _collectStatic() {
    final brands = _get('navigator.userAgentData.brands');
    final validBrands = brands is List ? brands.whereType<Map>().where((b) => ['Chromium','Google Chrome','Microsoft Edge'].contains(b['brand'])).toList() : <Map>[];
    final mobile = _get('navigator.userAgentData.mobile');
    final touch = _get('navigator.maxTouchPoints');
    return {
      if (validBrands.isNotEmpty) 'browser': {'name': validBrands.last['brand'], 'version': validBrands.last['version'], 'brands': validBrands.map((b) => '${b['brand']} ${b['version']}').join(', ')},
      'os': _fields({'name': _get('navigator.userAgentData.platform'), 'version': _entropy['platformVersion']}),
      'device': _fields({'type': mobile == true ? 'mobile' : (touch is num && touch > 1 && _get('navigator.platform') == 'MacIntel' ? 'tablet' : 'desktop'), 'model': _entropy['model'], 'arch': _entropy['architecture'], 'bitness': _entropy['bitness'], 'memory_gb': _get('navigator.deviceMemory'), 'processors': _get('navigator.hardwareConcurrency'), 'touch_points': touch, 'platform': _get('navigator.platform')}),
      'culture': _fields({'locale': _get('navigator.language'), 'timezone': _get('timezone')}),
      'runtime': {'name': 'flutter-web', 'renderer': kIsWasm ? 'wasm' : 'js'},
      'session': {'id': _session, 'started_at': _started},
    };
  }
  Map<String, Object?> capture(List<Breadcrumb> breadcrumbs) {
    if (!_enabled) return {};
    String? route;
    for (final crumb in breadcrumbs.reversed) {
      if (crumb.category == 'navigation') {
        final value = crumb.data['to'] ?? crumb.data['route'] ?? crumb.message;
        if (value is String && value.isNotEmpty) { route = value; break; }
      }
    }
    return {..._static,
      'screen': _fields({'width': _get('screen.width'), 'height': _get('screen.height'), 'pixel_ratio': _get('devicePixelRatio'), 'orientation': _get('screen.orientation.type')}),
      'viewport': _fields({'width': _get('innerWidth'), 'height': _get('innerHeight')}),
      'network': _fields({'effective_type': _get('navigator.connection.effectiveType'), 'save_data': _get('navigator.connection.saveData'), 'online': _get('navigator.onLine')}),
      'route': {'path': route ?? templatePath(_get('location.pathname') is String ? _get('location.pathname') as String : '/')},
    };
  }
}
