import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class OfflineStorage {
  Future<List<String>?> read(String key);
  Future<bool> write(String key, List<String> value);
  Future<bool> remove(String key);
}

class SharedPreferencesStorage implements OfflineStorage {
  SharedPreferencesStorage(this._preferences);
  final SharedPreferences _preferences;
  @override
  Future<List<String>?> read(String key) async =>
      _preferences.getStringList(key);
  @override
  Future<bool> write(String key, List<String> value) =>
      _preferences.setStringList(key, value);
  @override
  Future<bool> remove(String key) => _preferences.remove(key);
}

/// Bounded FIFO buffer. Drain is an explicit claim and [requeue] puts failed
/// entries back before later writes, preserving their retry order.
class OfflineBuffer {
  OfflineBuffer(this._storage,
      {this.maximum = 30,
      this.key = 'wasmwatch_offline_events',
      this.maximumBytes = 256 * 1024,
      this.maximumAge = const Duration(days: 7),
      DateTime Function()? clock})
      : assert(maximum > 0 && maximum <= 30),
        _clock = clock ?? DateTime.now;
  final OfflineStorage _storage;
  final int maximum;
  final String key;
  final int maximumBytes;
  final Duration maximumAge;
  final DateTime Function() _clock;
  final _claimed = <String, String>{};
  String _pack(String envelope) =>
      _claimed.remove(envelope) ??
      jsonEncode(
          {'at': _clock().toUtc().toIso8601String(), 'envelope': envelope});
  List<String> _bounded(List<String> entries, {bool newest = false}) {
    final valid = <String>[];
    var bytes = 0;
    final iterable = newest ? entries.reversed : entries;
    for (final entry in iterable) {
      try {
        final value = jsonDecode(entry) as Map;
        final at = DateTime.parse(value['at'] as String);
        final size = utf8.encode(entry).length;
        if (_clock().difference(at) > maximumAge || size > maximumBytes)
          continue;
        if (valid.length >= maximum || bytes + size > maximumBytes) break;
        valid.add(entry);
        bytes += size;
      } catch (_) {/* Legacy undated entries cannot satisfy the age bound. */}
    }
    return newest ? valid.reversed.toList() : valid;
  }

  Future<void> _serial = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() work) {
    final next = _serial.then((_) => work());
    _serial = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  Future<void> store(String envelope) => _locked(() async {
        final entries = [...?await _storage.read(key), _pack(envelope)];
        final retained = _bounded(entries, newest: true);
        if (!await _storage.write(key, retained))
          throw StateError('Could not persist offline envelope');
      });

  Future<List<String>> drain() => _locked(() async {
        final entries = List<String>.from(await _storage.read(key) ?? const []);
        if (entries.isNotEmpty && !await _storage.remove(key))
          throw StateError('Could not claim offline envelopes');
        _claimed.clear();
        final result = <String>[];
        for (final packed in _bounded(entries)) {
          final value = jsonDecode(packed) as Map;
          final envelope = value['envelope'] as String;
          _claimed[envelope] = packed;
          result.add(envelope);
        }
        return result;
      });

  Future<void> requeue(List<String> envelopes) => _locked(() async {
        if (envelopes.isEmpty) return;
        final retained = [
          ...envelopes.map(_pack),
          ...?await _storage.read(key)
        ];
        final bounded = _bounded(retained);
        if (!await _storage.write(key, bounded))
          throw StateError('Could not requeue offline envelopes');
      });
}
