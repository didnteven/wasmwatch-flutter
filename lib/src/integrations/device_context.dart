import 'dart:math';
import 'package:flutter/foundation.dart';
import 'device_context_source.dart' as source;

typedef DeviceValueSource = Object? Function(String path);

class DeviceContextIntegration {
  DeviceContextIntegration({DeviceValueSource? read})
      : _read = read ?? source.readDeviceValue,
        _enabled = read != null || source.deviceContextAvailable;

  final DeviceValueSource _read;
  final bool _enabled;
  static final _started = DateTime.now().toUtc().toIso8601String();
  static final _session = _uuid();

  static String _uuid() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Object? _get(String path) {
    try {
      return _read(path);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _fields(Map<String, Object?> fields) =>
      fields..removeWhere((k, v) => v == null || v == '');
  num? _positive(String path) {
    final value = _get(path);
    return value is num && value.isFinite && value > 0 ? value : null;
  }

  Map<String, Object?> _os(String os) {
    final raw = _get('os.version');
    final value = raw is String ? raw.trim() : '';
    final pattern = os == 'ios'
        ? r'^(?:Version|iOS)\s+(\d+(?:\.\d+)*)\b'
        : r'^Android\s+(\d+(?:\.\d+)*)\b';
    final version =
        RegExp(pattern, caseSensitive: false).firstMatch(value)?.group(1);
    // Android reports its system build ID here (e.g. BP41.250916.009.A1), not
    // a release; keep unrecognized values as build evidence, never as version.
    return _fields({
      'name': os == 'ios' ? 'iOS' : 'Android',
      'version': version,
      'build': version == null ? value : null,
    });
  }

  Map<String, Object?> capture() {
    if (!_enabled) return {};
    final os = _get('os');
    if (os != 'ios' && os != 'android') return {};
    final ratio = _positive('view.pixel_ratio');
    final physicalWidth = _positive('view.width');
    final physicalHeight = _positive('view.height');
    final width = ratio == null
        ? null
        : physicalWidth == null
            ? null
            : physicalWidth / ratio;
    final height = ratio == null
        ? null
        : physicalHeight == null
            ? null
            : physicalHeight / ratio;
    return {
      'os': _os(os as String),
      'device': {
        'type': width != null && height != null && min(width, height) >= 600
            ? 'tablet'
            : 'mobile'
      },
      'screen':
          _fields({'width': width, 'height': height, 'pixel_ratio': ratio}),
      'culture':
          _fields({'locale': _get('locale'), 'timezone': _get('timezone')}),
      'runtime': {
        'name': 'flutter',
        'mode': kReleaseMode
            ? 'release'
            : kProfileMode
                ? 'profile'
                : 'debug'
      },
      'session': {'id': _session, 'started_at': _started},
    };
  }
}
