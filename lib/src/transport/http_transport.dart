import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../options.dart';

class HttpTransport {
  HttpTransport(this.dsn,
      {http.Client? client,
      this.maxRetries = 3,
      this.baseDelay = const Duration(milliseconds: 200),
      DateTime Function()? clock,
      Future<void> Function(Duration)? delay,
      double Function()? jitter,
      this.maximumPending = 32})
      : _client = client ?? http.Client(),
        _clock = clock ?? DateTime.now,
        _delay = delay ?? Future<void>.delayed,
        _jitter = jitter ?? Random().nextDouble;
  final Dsn dsn;
  final http.Client _client;
  final int maxRetries;
  final Duration baseDelay;
  final int maximumPending;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final double Function() _jitter;
  DateTime? _cooldownUntil;
  Future<void> _serial = Future.value();
  int _pending = 0;
  final _permanent = <String>{};

  bool shouldBuffer(String envelope) => !_permanent.contains(envelope);
  void _reject(String envelope) {
    if (_permanent.length >= 64) _permanent.remove(_permanent.first);
    _permanent.add(envelope);
  }

  Future<bool> send(String envelope) {
    if (utf8.encode(envelope).length > 5 * 1024 * 1024) {
      _reject(envelope);
      return Future.value(false);
    }
    if (_pending >= maximumPending) return Future.value(false);
    _pending++;
    final result = _serial.then((_) => _send(envelope));
    _serial = result.then<void>((_) {}, onError: (_, __) {});
    return result.whenComplete(() {
      _pending--;
    });
  }

  Future<void> _waitCooldown() async {
    final until = _cooldownUntil;
    if (until != null && until.isAfter(_clock()))
      await _delay(until.difference(_clock()));
  }

  void _cooldown(Duration value) {
    final until = _clock().add(value);
    if (_cooldownUntil == null || until.isAfter(_cooldownUntil!))
      _cooldownUntil = until;
  }

  Future<bool> _send(String envelope) async {
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      await _waitCooldown();
      try {
        final response = await _client.post(dsn.endpoint,
            headers: {
              'Content-Type': 'application/x-sentry-envelope',
              'Authorization': 'Bearer ${dsn.publicKey}',
              'X-WasmWatch-Project': dsn.projectId,
            },
            body: envelope);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _permanent.remove(envelope);
          return true;
        }
        // Exit aggregates acknowledge only accepted or permanent 4xx replies.
        // Keep the existing event/session redirect handling unchanged.
        if (response.statusCode != 429 &&
            response.statusCode < 500 &&
            (response.statusCode >= 400 || !_isAppExits(envelope))) {
          _reject(envelope);
          return false;
        }
        final seconds = int.tryParse(response.headers['retry-after'] ?? '');
        final retry = seconds == null
            ? baseDelay * (1 << attempt)
            : Duration(seconds: max(0, seconds));
        _cooldown(retry + Duration(milliseconds: (_jitter() * 200).round()));
        if (attempt == maxRetries) return false;
      } on Object {
        _cooldown(baseDelay * (1 << attempt) +
            Duration(milliseconds: (_jitter() * 200).round()));
        if (attempt == maxRetries) return false;
      }
    }
    return false;
  }

  bool _isAppExits(String envelope) {
    try {
      return (jsonDecode(envelope.split('\n')[1]) as Map)['type'] == 'app_exits';
    } catch (_) {
      return false;
    }
  }

  void close() => _client.close();
}
