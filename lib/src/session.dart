import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'native/install_id.dart';

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
    this.onBegin,
  })  : _preferences = preferences,
        _clock = clock ?? DateTime.now;

  static const sessionKey = 'wasmwatch_session';
  static const previousSessionsKey = 'wasmwatch_previous_sessions';
  static const nativeWaitTimeout = Duration(seconds: 30);
  static const installIdKey = 'wasmwatch_install_id';
  static const backgroundKey = 'wasmwatch_session_background';
  static const backgroundTimeout = Duration(seconds: 30);
  final void Function()? onBegin;
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
  Timer? _nativeTimer;
  List<Map<String, Object?>> _previousSessions = [];
  bool _closed = false;
  Future<void> _pending = Future<void>.value();

  Map<String, Object?>? get context => _current == null
      ? null
      : {'id': _current!['sid'], 'started_at': _current!['started']};

  Future<void> get pending => _pending;

  Future<void> start(
      {List<Map<String, Object?>> nativeReports = const [],
      bool deferPrevious = false,
      String? installId}) async {
    String? previous;
    String? background;
    try {
      previous = _preferences?.getString(sessionKey);
      background = _preferences?.getString(backgroundKey);
      final stored = _preferences?.getString(previousSessionsKey);
      if (stored != null) {
        _previousSessions = (jsonDecode(stored) as List)
            .map((entry) => Map<String, Object?>.from(entry as Map))
            .toList();
      }
      if (previous != null) {
        final session = Map<String, Object?>.from(jsonDecode(previous) as Map);
        if (session['status'] == 'ok' &&
            !_previousSessions.any((entry) =>
                (entry['session'] as Map)['sid'] == session['sid'])) {
          _previousSessions.add({'session': session, 'background': background});
        }
      }
    } catch (_) {/* Ignore corrupt state, rather than blocking startup. */}
    _did = installId ?? await getInstallId(_preferences);
    // Persist before replacing the active session: a kill during native recovery
    // must leave both the deferred session and this launch's session recoverable.
    await _storePrevious();
    if (deferPrevious) {
      _nativeTimer = Timer(nativeWaitTimeout, () {
        unawaited(completeNativeReports());
      });
    } else {
      await completeNativeReports(nativeReports);
    }
    if (background != null) await _saveBackground(null);
    await _begin();
  }

  /// iOS can wait for a matching late diagnostic until the original 30 s timer.
  /// Reports after fallback still become events, without revising that session.
  Future<void> completeNativeReports(
      [List<Map<String, Object?>> nativeReports = const [],
      bool waitForMore = false]) {
    if (!waitForMore) {
      _nativeTimer?.cancel();
      _nativeTimer = null;
    }
    if (_closed || _previousSessions.isEmpty) return _pending;
    return _enqueue(() async {
      // Select inside the queue so a callback racing the fallback (or another
      // callback) cannot remove another deferred session from persistent state.
      final previous = _previousSessions.where((entry) {
        if (!waitForMore) return true;
        final sid = (entry['session'] as Map)['sid'];
        return nativeReports.any((report) =>
            report['kind'] == 'ios_crash' &&
            report['scope'] is Map &&
            (report['scope'] as Map)['session_id'] == sid);
      }).toList();
      final remaining = List<Map<String, Object?>>.from(_previousSessions);
      for (final entry in previous) {
        try {
          final session = Map<String, Object?>.from(entry['session'] as Map);
          if (session['status'] == 'ok') {
            // The OS suspends a backgrounded app (stopping the end timer) and may then kill it
            // without notice: that ends the session normally at the time it was backgrounded.
            // Only a session that died in the foreground is abnormal.
            final backgroundAt = entry['background'] == null
                ? null
                : DateTime.tryParse(entry['background'] as String);
            _advance(session, backgroundAt);
            session['init'] = false;
            session['status'] = backgroundAt == null
                ? 'abnormal'
                : (session['errors'] as int) > 0
                    ? 'errored'
                    : 'exited';
            final started = DateTime.parse(session['started'] as String);
            DateTime? reportTime;
            String? reportStatus;
            for (final report in nativeReports) {
              final scope = report['scope'];
              if (scope is! Map || scope['session_id'] != session['sid'])
                continue;
              final kind = report['kind'];
              final exit = report['exit'];
              final crash = kind == 'ios_crash' ||
                  kind == 'native_crash' ||
                  (kind == 'java_crash' && exit is Map);
              if (!crash && kind != 'anr' && kind != 'app_exit') continue;
              final status = crash ? 'crashed' : 'abnormal';
              if (reportStatus == 'crashed' && !crash) continue;
              final milliseconds = exit is Map
                  ? exit['timestamp_ms'] ?? report['timestamp_ms']
                  : report['timestamp_ms'];
              DateTime? at;
              if (milliseconds is int &&
                  milliseconds >= 0 &&
                  milliseconds <= 0xffffffffffff) {
                at = DateTime.fromMillisecondsSinceEpoch(milliseconds,
                    isUtc: true);
                if (!at.isAfter(started)) at = null;
              }
              if (reportStatus != status) reportTime = null;
              reportStatus = status;
              if (at != null && (reportTime == null || at.isAfter(reportTime)))
                reportTime = at;
            }
            if (reportStatus != null) {
              session['status'] = reportStatus;
              if (reportStatus == 'crashed')
                session['errors'] = max(session['errors'] as int, 1);
              if (reportTime != null)
                session['timestamp'] = reportTime.toIso8601String();
            }
          }
          // onUpdate persists the envelope before returning. Remove recovery
          // state only after it has accepted this update, never overwrite the
          // current session's storage with an update for an older session.
          entry['session'] = session;
          await _storePrevious(remaining);
          if (_current == null) {
            // Recovery without a bridge runs before _begin replaces sessionKey.
            // Mark that active slot terminal too, so a kill cannot re-add it.
            try {
              final stored = _preferences?.getString(sessionKey);
              if (stored != null &&
                  (jsonDecode(stored) as Map)['sid'] == session['sid']) {
                await _preferences?.setString(sessionKey, jsonEncode(session));
              }
            } catch (_) {/* Storage is optional on unsupported platforms. */}
          }
          await onUpdate(session);
          remaining.remove(entry);
          _previousSessions.remove(entry);
          await _storePrevious(remaining);
        } catch (_) {/* Retain failed updates for the next launch. */}
      }
      if (_previousSessions.isEmpty) {
        _nativeTimer?.cancel();
        _nativeTimer = null;
      }
    });
  }

  Future<void> _storePrevious([List<Map<String, Object?>>? sessions]) async {
    try {
      final remaining = sessions ?? _previousSessions;
      if (remaining.isEmpty) {
        await _preferences?.remove(previousSessionsKey);
      } else {
        await _preferences?.setString(
            previousSessionsKey, jsonEncode(remaining));
      }
    } catch (_) {/* Storage is optional on unsupported platforms. */}
  }

  Future<void> _begin() {
    final now = _clock().toUtc().toIso8601String();
    _current = {
      'sid': sessionUuid(),
      'did': _did,
      'init': true,
      'started': now,
      'timestamp': now,
      'status': 'ok',
      'errors': 0,
      'attrs': {'release': release, 'environment': environment},
      'platform': platform,
    };
    onBegin?.call();
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
    _nativeTimer?.cancel();
    _nativeTimer = null;
    _timer?.cancel();
    _timer = null;
    await _end();
  }
}
