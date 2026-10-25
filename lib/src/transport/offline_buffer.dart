import 'dart:convert';
import 'dart:math';
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

class OfflineEntry {
  const OfflineEntry({required this.id, required this.envelope});
  final String id;
  final String envelope;
}

/// Bounded FIFO buffer. [pending] keeps entries persisted until [remove]
/// acknowledges delivery. [drain] and [requeue] retain their explicit claim API.
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
  final _random = Random.secure();
  final _claimed = <String, String>{};
  String _pack(String envelope) =>
      _claimed.remove(envelope) ??
      jsonEncode({
        'id': List.generate(16, (_) => _random.nextInt(256))
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
        'at': _clock().toUtc().toIso8601String(),
        'envelope': envelope,
      });
  // Each locked operation decodes stored entries once. Keep packed bytes intact
  // for legacy IDs and for writes that must not reset an entry's age.
  Map<String, DateTime>? _pendingIds;

  List<_StoredEntry> _bounded(List<_StoredEntry> entries,
      {bool newest = false}) {
    final valid = <_StoredEntry>[];
    var bytes = 0;
    final iterable = newest ? entries.reversed : entries;
    for (final entry in iterable) {
      final at = entry.at;
      if (at == null ||
          _clock().difference(at) > maximumAge ||
          entry.size > maximumBytes) continue;
      if (valid.length >= maximum || bytes + entry.size > maximumBytes) break;
      valid.add(entry);
      bytes += entry.size;
    }
    return newest ? valid.reversed.toList() : valid;
  }

  void _index(List<_StoredEntry> entries) {
    _pendingIds = {for (final entry in entries) entry.id: entry.at!};
  }

  Future<List<_StoredEntry>> _read() async {
    final entries = [
      for (final packed in await _storage.read(key) ?? const <String>[])
        _StoredEntry(packed)
    ];
    _index(_bounded(entries));
    return entries;
  }

  Future<void> _write(List<_StoredEntry> entries) async {
    if (!await _storage.write(key, [for (final entry in entries) entry.packed]))
      throw StateError('Could not persist offline envelope');
    _index(entries);
  }

  Future<void> _serial = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() work) {
    final next = _serial.then((_) => work());
    _serial = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  /// The session ID of an envelope that carries only a session update, else null.
  static String? sessionOnlyId(String envelope) {
    try {
      final records = envelope.split('\n');
      if (records.length < 3 ||
          (jsonDecode(records[1]) as Map)['type'] != 'session') return null;
      return (jsonDecode(records[2]) as Map)['sid'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<String> store(String envelope) => _locked(() async {
        final packed = _StoredEntry(_pack(envelope));
        final entries = await _read();
        // A later update of a session replaces earlier ones (the server keeps the
        // latest), and session-only updates give way before events when full.
        final sid = packed.sessionId;
        if (sid != null) entries.removeWhere((entry) => entry.sessionId == sid);
        entries.add(packed);
        var excess = entries.length - maximum;
        if (excess > 0) {
          entries.removeWhere((entry) {
            if (excess <= 0 ||
                identical(entry, packed) ||
                entry.sessionId == null) return false;
            excess--;
            return true;
          });
        }
        await _write(_bounded(entries, newest: true));
        return packed.id;
      });

  /// Read pending entries without removing them before delivery is acknowledged.
  Future<List<OfflineEntry>> pending() => _locked(() async => [
        for (final entry in _bounded(await _read()))
          OfflineEntry(id: entry.id, envelope: entry.envelope)
      ]);

  /// Membership in this buffer's latest snapshot, updated by each storage
  /// operation. Replay checks need no storage read or JSON decode.
  Future<bool> contains(String id) => _locked(() async {
        if (_pendingIds == null) await _read();
        final at = _pendingIds![id];
        return at != null && _clock().difference(at) <= maximumAge;
      });

  Future<void> remove(String id) => _locked(() async {
        final entries = _bounded(await _read());
        final index = entries.indexWhere((entry) => entry.id == id);
        if (index < 0) return;
        entries.removeAt(index);
        if (entries.isEmpty) {
          if (!await _storage.remove(key))
            throw StateError('Could not remove offline envelope');
          _index(entries);
        } else {
          await _write(entries);
        }
      });

  Future<List<String>> drain() => _locked(() async {
        final entries = await _read();
        if (entries.isNotEmpty && !await _storage.remove(key))
          throw StateError('Could not claim offline envelopes');
        _index(const []);
        _claimed.clear();
        final result = <String>[];
        for (final entry in _bounded(entries)) {
          _claimed[entry.envelope] = entry.packed;
          result.add(entry.envelope);
        }
        return result;
      });

  Future<void> requeue(List<String> envelopes) => _locked(() async {
        if (envelopes.isEmpty) return;
        final retained = [
          ...envelopes.map((envelope) => _StoredEntry(_pack(envelope))),
          ...await _read()
        ];
        await _write(_bounded(retained));
      });
}

class _StoredEntry {
  _StoredEntry(this.packed) {
    try {
      _value = jsonDecode(packed) as Map;
      at = DateTime.parse(_value!['at'] as String);
    } catch (_) {/* Legacy undated entries cannot satisfy the age bound. */}
  }

  final String packed;
  Map? _value;
  DateTime? at;
  late final int size = utf8.encode(packed).length;
  // Dated entries from older SDKs have no ID. Remove one matching entry only.
  String get id => _value!['id'] as String? ?? packed;
  String get envelope => _value!['envelope'] as String;
  late final String? sessionId = _sessionId();

  String? _sessionId() {
    try {
      return OfflineBuffer.sessionOnlyId(envelope);
    } catch (_) {
      return null;
    }
  }
}
