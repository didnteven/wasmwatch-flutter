import 'package:shared_preferences/shared_preferences.dart';

abstract interface class OfflineStorage {
  Future<List<String>?> read(String key);
  Future<bool> write(String key, List<String> value);
  Future<bool> remove(String key);
}

class SharedPreferencesStorage implements OfflineStorage {
  SharedPreferencesStorage(this._preferences);
  final SharedPreferences _preferences;
  @override Future<List<String>?> read(String key) async => _preferences.getStringList(key);
  @override Future<bool> write(String key, List<String> value) => _preferences.setStringList(key, value);
  @override Future<bool> remove(String key) => _preferences.remove(key);
}

/// Bounded FIFO buffer. Drain is an explicit claim and [requeue] puts failed
/// entries back before later writes, preserving their retry order.
class OfflineBuffer {
  OfflineBuffer(this._storage, {this.maximum = 30, this.key = 'wasmwatch_offline_events'})
      : assert(maximum > 0 && maximum <= 30);
  final OfflineStorage _storage;
  final int maximum;
  final String key;
  Future<void> _serial = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() work) {
    final next = _serial.then((_) => work());
    _serial = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  Future<void> store(String envelope) => _locked(() async {
    final entries = [...?await _storage.read(key), envelope];
    final retained = entries.length <= maximum ? entries : entries.sublist(entries.length - maximum);
    if (!await _storage.write(key, retained)) throw StateError('Could not persist offline envelope');
  });

  Future<List<String>> drain() => _locked(() async {
    final entries = List<String>.from(await _storage.read(key) ?? const []);
    if (entries.isNotEmpty && !await _storage.remove(key)) throw StateError('Could not claim offline envelopes');
    return entries;
  });

  Future<void> requeue(List<String> envelopes) => _locked(() async {
    if (envelopes.isEmpty) return;
    final retained = [...envelopes, ...?await _storage.read(key)];
    final bounded = retained.length <= maximum ? retained : retained.sublist(0, maximum);
    if (!await _storage.write(key, bounded)) throw StateError('Could not requeue offline envelopes');
  });
}
