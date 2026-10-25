import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// D7 sessions. State is saved before updates enter the offline envelope buffer.
/// Sending an update must only wait for persistence, never for the network.
class SessionTracker {
  SessionTracker({
    required this.release,
    required this.environment,
    required this.platform,
    required this.onUpdate,
    SharedPreferences? preferences,
    DateTime Function()? clock,
  })  : _preferences = preferences,
        _clock = clock ?? DateTime.now;

  static const sessionKey = 'wasmwatch_session';
  static const installIdKey = 'wasmwatch_install_id';
  static const backgroundKey = 'wasmwatch_session_background';
  static const backgroundTimeout = Duration(seconds: 30);
  final String release;
  final String environment;
  final String platform;
  final Future<void> Function(Map<String, Object?> update) onUpdate;
  final SharedPreferences? _preferences;
  final DateTime Function() _clock;
  Map<String, Object?>? _current;
  String? _did;
  DateTime? _backgroundAt;
  Timer? _timer;
  bool _closed = false;
  Future<void> _pending = Future<void>.value();

  Map<String, Object?>? get context => _current == null
      ? null
      : {'id': _current!['sid'], 'started_at': _current!['started']};

  Future<void> get pending => _pending;

  Future<void> start() async {
    String? previous;
    String? background;
    try {
      _did = _preferences?.getString(installIdKey);
      previous = _preferences?.getString(sessionKey);
      background = _preferences?.getString(backgroundKey);
    } catch (_) {/* Storage is optional on unsupported platforms. */}
    if (_did == null) {
      _did = _uuid();
      try {
        await _preferences?.setString(installIdKey, _did!);
      } catch (_) {/* Keep the random install ID in memory if storage fails. */}
    }
    if (previous != null) {
      try {
        final session = Map<String, Object?>.from(jsonDecode(previous) as Map);
        if (session['status'] == 'ok') {
          // The OS suspends a backgrounded app (stopping the end timer) and may then kill it
          // without notice: that ends the session normally at the time it was backgrounded.
          // Only a session that died in the foreground is abnormal.
          final backgroundAt =
              background == null ? null : DateTime.tryParse(background);
          _advance(session, backgroundAt);
          session['init'] = false;
          session['status'] = backgroundAt == null
              ? 'abnormal'
              : (session['errors'] as int) > 0
                  ? 'errored'
                  : 'exited';
          await _save(session, emit: true);
        }
      } catch (_) {/* Ignore corrupt state, rather than blocking startup. */}
    }
    if (background != null) await _saveBackground(null);
    await _begin();
  }

  Future<void> _begin() {
    final now = _clock().toUtc().toIso8601String();
    _current = {
      'sid': _uuid(),
      'did': _did,
      'init': true,
      'started': now,
      'timestamp': now,
      'status': 'ok',
      'errors': 0,
      'attrs': {'release': release, 'environment': environment},
      'platform': platform,
    };
    return _save(_current!, emit: true);
  }

  /// Both handled and unhandled captured events contribute to release health.
  Future<Map<String, Object?>?> recordError() {
    final session = _current;
    if (_closed || session == null) return Future.value(null);
    session['errors'] = min((session['errors'] as int) + 1, 0xffffffff);
    session['init'] = false;
    _advance(session);
    final snapshot = Map<String, Object?>.from(session);
    return _save(snapshot).then((_) => snapshot);
  }

  void _advance(Map<String, Object?> session, [DateTime? at]) {
    final previous = DateTime.parse(session['timestamp'] as String);
    final now = (at ?? _clock()).toUtc();
    // The ingestor replaces rows by timestamp (microseconds), including rapid
    // captures in a single clock tick and clocks adjusted backwards by the OS.
    session['timestamp'] = (now.isAfter(previous)
            ? now
            : previous.add(const Duration(microseconds: 1)))
        .toIso8601String();
  }

  Future<void> _save(Map<String, Object?> session, {bool emit = false}) {
    final snapshot = Map<String, Object?>.from(session);
    return _enqueue(() async {
      try {
        await _preferences?.setString(sessionKey, jsonEncode(snapshot));
      } catch (_) {/* A storage failure must not block delivery. */}
      if (emit) {
        try {
          await onUpdate(snapshot);
        } catch (_) {/* One failed send must not stall later updates. */}
      }
    });
  }

  /// Records when the app went to the background (null on resume), so the next launch can
  /// tell an OS kill of a suspended app from a foreground crash.
  Future<void> _saveBackground(DateTime? at) => _enqueue(() async {
        try {
          if (at == null) {
            await _preferences?.remove(backgroundKey);
          } else {
            await _preferences?.setString(
                backgroundKey, at.toUtc().toIso8601String());
          }
        } catch (_) {/* Without storage, a later OS kill reads as abnormal. */}
      });

  Future<void> _enqueue(Future<void> Function() step) =>
      _pending = _pending.then((_) => step());

  Future<void> _end([DateTime? at]) {
    final session = _current;
    if (session == null) return _pending;
    _current = null;
    session['init'] = false;
    session['status'] = (session['errors'] as int) > 0 ? 'errored' : 'exited';
    _advance(session, at);
    return _save(session, emit: true);
  }

  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_closed) return;
    if (state == AppLifecycleState.resumed) {
      _timer?.cancel();
      _timer = null;
      final background = _backgroundAt;
      _backgroundAt = null;
      if (background != null) unawaited(_saveBackground(null));
      // Mobile platforms may suspend Dart timers while the app is backgrounded.
      if (background != null &&
          _clock().difference(background) >= backgroundTimeout) {
        await _end(background.add(backgroundTimeout));
      }
      if (!_closed && _current == null) await _begin();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (_backgroundAt != null) return;
      _backgroundAt = _clock();
      unawaited(_saveBackground(_backgroundAt));
      _timer = Timer(backgroundTimeout, () {
        _timer = null;
        unawaited(_end(_backgroundAt!.add(backgroundTimeout)));
      });
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await _end();
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
