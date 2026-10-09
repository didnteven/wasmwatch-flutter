import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../options.dart';

class HttpTransport {
  HttpTransport(this.dsn, {http.Client? client, this.maxRetries = 3, this.baseDelay = const Duration(milliseconds: 200)})
      : _client = client ?? http.Client();
  final Dsn dsn;
  final http.Client _client;
  final int maxRetries;
  final Duration baseDelay;

  Future<bool> send(String envelope) async {
    final bodyLength = utf8.encode(envelope).length;
    if (bodyLength > 5 * 1024 * 1024) return false;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final response = await _client.post(
          dsn.endpoint,
          headers: {
            'Content-Type': 'application/x-sentry-envelope',
            'Authorization': 'Bearer ${dsn.publicKey}',
            'X-WasmWatch-Project': dsn.projectId,
          },
          body: envelope,
        );
        if (response.statusCode >= 200 && response.statusCode < 300) return true;
        if (response.statusCode != 429 && response.statusCode < 500) return false;
        if (attempt == maxRetries) return false;
        final retry = int.tryParse(response.headers['retry-after'] ?? '');
        await Future<void>.delayed(retry == null ? baseDelay * (1 << attempt) : Duration(seconds: retry));
      } on Object {
        if (attempt == maxRetries) return false;
        await Future<void>.delayed(baseDelay * (1 << attempt));
      }
    }
    return false;
  }

  void close() => _client.close();
}
