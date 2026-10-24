import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class UploadApiRejected extends FormatException {
  UploadApiRejected(super.message, this.status, this.code);
  final int status;
  final String? code;
}

/// Where and as whom to upload; warnings are printed once per run, whatever the artifact count.
class UploadTarget {
  UploadTarget(this.base, this.project, this.key);
  final Uri base;
  final String project;
  final String key;
  var _deprecationWarned = false;

  void warnDeprecated() {
    if (_deprecationWarned) return;
    _deprecationWarned = true;
    stderr.writeln(
        'wasmwatch: warning: the server flags this key as a legacy upload key; create an upload token in Project Settings and set WASMWATCH_UPLOAD_TOKEN');
  }

  static UploadTarget resolve(String dsn, String? bearer, String? project) {
    Uri uri;
    try {
      uri = Uri.parse(dsn);
    } catch (_) {
      throw const FormatException('invalid DSN');
    }
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty)
      throw const FormatException(
          'invalid DSN: scheme must be http or https with a host');
    final segments = uri.pathSegments.where((s) => s.isNotEmpty);
    project ??= segments.isEmpty ? null : segments.last;
    if (project == null ||
        project.isEmpty ||
        project.length > 128 ||
        project.contains(RegExp(r'[/?#]')))
      throw const FormatException(
          'project ID is missing or invalid (put it in the DSN path or pass --project-id)');
    var key = bearer;
    if (key == null) {
      // The DSN is the string that gets compiled into the app, so it must never carry the secret.
      key = uri.userInfo.split(':').first;
      if (key.startsWith('wws_'))
        throw const FormatException(
            'the DSN contains an upload token (wws_...); pass it as WASMWATCH_UPLOAD_TOKEN and keep the DSN key (wwk_...) in the DSN');
      if (key.isNotEmpty)
        stderr.writeln(
            'wasmwatch: warning: uploading with the DSN key is deprecated; create an upload token in Project Settings and set WASMWATCH_UPLOAD_TOKEN');
    }
    if (key.isEmpty)
      throw const FormatException(
          'upload token is missing (set WASMWATCH_UPLOAD_TOKEN)');
    final base = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null);
    return UploadTarget(base, project, key);
  }
}

/// `Retry-After` in whole seconds, capped at 30; HTTP-date values are ignored.
Duration? _retryAfter(http.Response response) {
  final seconds = int.tryParse(response.headers['retry-after']?.trim() ?? '');
  if (seconds == null || seconds < 0) return null;
  return Duration(seconds: seconds > 30 ? 30 : seconds);
}

/// Message for a failed API response; exposed for tests.
String uploadApiErrorMessage(http.Response response) =>
    _apiError(response).message;

FormatException _apiError(http.Response response) {
  String? code;
  try {
    final body = jsonDecode(response.body);
    if (body is Map && body['error'] is String) code = body['error'] as String;
  } catch (_) {}
  final status = response.statusCode;
  switch (code) {
    case 'insufficient_scope':
      return UploadApiRejected(
          'this key cannot upload artifacts (HTTP $status insufficient_scope); create an upload token (wws_...) in Project Settings and set WASMWATCH_UPLOAD_TOKEN',
          status,
          code);
    case 'invalid_api_key':
      return UploadApiRejected(
          'the API key or upload token was rejected (HTTP $status invalid_api_key); check WASMWATCH_UPLOAD_TOKEN and the project ID',
          status,
          code);
    case 'invalid_artifact_type':
    case 'unsupported_artifact_type':
      return UploadApiRejected(
          'API request failed with HTTP $status ($code)', status, code);
  }
  return UploadApiRejected('API request failed with HTTP $status', status, null);
}

Future<String> uploadArtifact(UploadTarget target, String artifactType, String id,
    String release, List<int> bytes, int timeout, int interval) async {
  final base = target.base;
  final key = target.key;
  Uri endpoint(String suffix) =>
      base.resolve('/api/v1/projects/${target.project}/$suffix');
  if (bytes.isEmpty || bytes.length > 100 * 1024 * 1024)
    throw const FormatException(
        'artifact must be non-empty and within the 100 MiB v1 limit');
  final digest = sha256.convert(bytes);
  final checksum = digest.toString();
  final client = http.Client();
  Future<Map<String, dynamic>> request(String method, Uri url, String idem,
      [Map<String, dynamic>? body]) async {
    for (var attempt = 0; attempt <= 3; attempt++) {
      http.Response response;
      try {
        final req = http.Request(method, url)..followRedirects = false;
        req.headers.addAll({
          'Authorization': 'Bearer $key',
          'Idempotency-Key': idem,
          'Accept': 'application/json'
        });
        if (body != null) {
          req.headers['Content-Type'] = 'application/json';
          req.body = jsonEncode(body);
        }
        response = await http.Response.fromStream(await client.send(req));
      } catch (_) {
        if (attempt == 3) throw const FormatException('HTTP request failed');
        await Future<void>.delayed(
            Duration(milliseconds: 100 * (1 << attempt)));
        continue;
      }
      if ((response.statusCode == 429 || response.statusCode >= 500) &&
          attempt < 3) {
        await Future<void>.delayed(_retryAfter(response) ??
            Duration(milliseconds: 100 * (1 << attempt)));
        continue;
      }
      if (response.headers.containsKey('x-wasmwatch-deprecation'))
        target.warnDeprecated();
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw _apiError(response);
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        throw const FormatException('API response was invalid');
      }
    }
    throw const FormatException('HTTP request failed');
  }

  try {
    final create = await request('POST', endpoint('artifacts/upload-url'),
        'wasmwatch-upload-$id-$checksum', {
      'debug_id': id,
      'artifact_type': artifactType,
      'content_length': bytes.length,
      'checksum_sha256': checksum,
      'release': release
    });
    final headers = create['required_upload_headers'];
    final signed = (create['signed_headers'] as List? ?? [])
        .map((v) => v.toString().toLowerCase())
        .toSet();
    if (create['artifact_id'] is! String ||
        create['debug_id'] != id ||
        create['checksum_sha256'] != checksum ||
        create['max_upload_bytes'] is! num ||
        (create['max_upload_bytes'] as num) < bytes.length ||
        headers is! Map ||
        headers['Content-Length'] != '${bytes.length}' ||
        headers['x-amz-checksum-sha256'] != checksum ||
        !signed
            .containsAll({'content-length', 'x-amz-checksum-sha256', 'host'}))
      throw const FormatException(
          'presigned response does not match the local artifact');
    Uri url;
    try {
      url = base.resolve(create['upload_url'] as String);
    } catch (_) {
      throw const FormatException('presigned upload URL is invalid');
    }
    if (!{'http', 'https'}.contains(url.scheme) || url.host.isEmpty)
      throw const FormatException('presigned upload URL is invalid');
    http.Response put;
    try {
      final req = http.Request('PUT', url)..followRedirects = false;
      req.bodyBytes = bytes;
      req.headers.addAll({
        'Content-Length': '${bytes.length}',
        'x-amz-checksum-sha256': base64Encode(digest.bytes)
      });
      put = await http.Response.fromStream(await client.send(req));
    } catch (_) {
      throw const FormatException(
          'HTTP request failed; presigned upload was not retried because its outcome is uncertain');
    }
    if (put.statusCode < 200 || put.statusCode >= 300)
      throw FormatException(
          'presigned upload failed with HTTP ${put.statusCode}; the upload was not retried because its outcome is uncertain');
    final artifact = create['artifact_id'] as String;
    await request(
        'POST',
        endpoint('artifacts/$artifact/complete'),
        'wasmwatch-complete-$artifact',
        {'content_length': bytes.length, 'checksum_sha256': checksum});
    final watch = Stopwatch()..start();
    final limit = Duration(seconds: timeout);
    var delay = Duration(milliseconds: interval < 1 ? 1 : interval);
    while (true) {
      final remaining = limit - watch.elapsed;
      if (remaining <= Duration.zero)
        throw const FormatException(
            'timed out waiting for artifact processing');
      Map<String, dynamic> status;
      try {
        status = await request('GET', endpoint('artifacts/$artifact/status'),
                'wasmwatch-status-$artifact')
            .timeout(remaining);
      } on TimeoutException {
        throw const FormatException(
            'timed out waiting for artifact processing');
      }
      if (status['artifact_id'] != artifact || status['debug_id'] != id)
        throw const FormatException('status identity mismatch');
      switch (status['processing_status']) {
        case 'ready':
          return artifact;
        case 'failed':
          throw const FormatException('artifact processing failed');
        case 'pending':
        case 'processing':
          break;
        default:
          throw const FormatException('unknown processing status');
      }
      final left = limit - watch.elapsed;
      if (left <= Duration.zero)
        throw const FormatException(
            'timed out waiting for artifact processing');
      await Future<void>.delayed(delay < left ? delay : left);
      delay = Duration(
          milliseconds: delay.inMilliseconds * 2 > 2000
              ? 2000
              : delay.inMilliseconds * 2);
    }
  } finally {
    client.close();
  }
}
