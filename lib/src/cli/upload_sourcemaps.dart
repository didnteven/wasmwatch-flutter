import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'artifact_identity.dart';
import 'source_context.dart';

const uploadHelp = '''Upload Flutter Wasm source maps with pure Dart.
Usage: dart run wasmwatch:upload_sourcemaps [BUILD_DIR] [options]
BUILD_DIR defaults to build/web.
  --dsn DSN                  SDK DSN (or WASMWATCH_DSN)
  --upload-token TOKEN       Secret upload token wws_... (or WASMWATCH_UPLOAD_TOKEN)
  --upload-token-file FILE   Read the upload token from file
  --api-key KEY              Deprecated alias for --upload-token (or WASMWATCH_API_KEY)
  --api-key-file FILE        Read API key from file
  --project-id ID            Override project (or WASMWATCH_PROJECT_ID)
  --release RELEASE         Defaults to pubspec name@version (WASMWATCH_RELEASE)
  --package-root DIR         App directory containing pubspec.yaml
  --no-source-context        Skip embedding sources from disk
  --no-rewrite-paths         Preserve source paths
  --no-js-source-map         Do not upload main.dart.js.map
  --dry-run                  Prepare artifacts without network requests
  --debug-id ID              Assert artifact-derived ID
  --timeout-secs SECONDS     Processing timeout (default 300)
  --poll-interval-ms MS      Initial poll interval (default 250)
  --help                    Show this help
Build first: flutter build web --wasm --source-maps --no-strip-wasm''';

void atomicWrite(File file, List<int> bytes) {
  final temp = File(
      '${file.path}.wasmwatch-$pid-${DateTime.now().microsecondsSinceEpoch}');
  try {
    temp.writeAsBytesSync(bytes, flush: true);
    temp.renameSync(file.path);
  } finally {
    if (temp.existsSync()) temp.deleteSync();
  }
}

void injectGlobals(File file, String id, String release) {
  final original = file.readAsStringSync();
  var html = original;
  for (final entry in {
    '__WASMWATCH_DEBUG_ID__': id,
    '__WASMWATCH_RELEASE__': release
  }.entries) {
    final pattern = RegExp(
        'window\\s*\\.\\s*${entry.key}\\s*=\\s*(?:"(?:\\\\.|[^"\\\\])*"|\'(?:\\\\.|[^\'\\\\])*\')');
    final value = jsonEncode(entry.value)
        .replaceAll('<', r'\u003c')
        .replaceAll('>', r'\u003e')
        .replaceAll('&', r'\u0026');
    final assignment = 'window.${entry.key} = $value';
    if (pattern.hasMatch(html)) {
      html = html.replaceAllMapped(pattern, (_) => assignment);
    } else {
      var pos = html.toLowerCase().indexOf('</head>');
      if (pos < 0) pos = html.toLowerCase().indexOf('</body>');
      if (pos < 0) pos = html.length;
      html =
          '${html.substring(0, pos)}<script>$assignment;</script>\n${html.substring(pos)}';
    }
  }
  if (html != original) atomicWrite(file, utf8.encode(html));
}

Future<String> runUploadSourcemaps(List<String> args,
    {Map<String, String>? environment}) async {
  final env = environment ?? Platform.environment;
  final values = <String, String>{};
  final switches = <String>{};
  String? build;
  const flags = {
    'no-source-context',
    'no-rewrite-paths',
    'no-js-source-map',
    'dry-run'
  };
  const options = {
    'dsn',
    'upload-token',
    'upload-token-file',
    'api-key',
    'api-key-file',
    'project-id',
    'release',
    'package-root',
    'debug-id',
    'timeout-secs',
    'poll-interval-ms'
  };
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--help' || arg == '-h') return uploadHelp;
    if (arg.startsWith('--')) {
      final parts = arg.substring(2).split('=');
      final name = parts.first;
      if (flags.contains(name) && parts.length == 1) {
        switches.add(name);
        continue;
      }
      if (!options.contains(name))
        throw FormatException('unknown option --$name');
      if (parts.length > 1) {
        values[name] = parts.skip(1).join('=');
      } else {
        if (++i >= args.length || args[i].startsWith('--'))
          throw FormatException('--$name requires a value');
        values[name] = args[i];
      }
    } else {
      if (arg.startsWith('-') || build != null)
        throw const FormatException('expected one BUILD_DIR; use --help');
      build = arg;
    }
  }
  String? option(String name) =>
      values[name] ??
      env['WASMWATCH_${name.replaceAll('-', '_').toUpperCase()}'];
  int duration(String name, int fallback) {
    final n = int.tryParse(values[name] ?? '$fallback');
    if (n == null || n < 0)
      throw FormatException('--$name must be a non-negative integer');
    return n;
  }

  final timeout = duration('timeout-secs', 300);
  final interval = duration('poll-interval-ms', 250);
  var token = option('upload-token');
  if (values['upload-token-file'] != null) {
    if (token != null)
      throw const FormatException(
          '--upload-token-file conflicts with --upload-token/WASMWATCH_UPLOAD_TOKEN');
    try {
      token = File(values['upload-token-file']!)
          .readAsStringSync()
          .replaceFirst(RegExp(r'[\r\n]+$'), '');
    } catch (_) {
      throw const FormatException('could not read upload token file');
    }
  }
  var key = option('api-key');
  if (values['api-key-file'] != null) {
    if (key != null)
      throw const FormatException(
          '--api-key-file conflicts with --api-key/WASMWATCH_API_KEY');
    try {
      key = File(values['api-key-file']!)
          .readAsStringSync()
          .replaceFirst(RegExp(r'[\r\n]+$'), '');
    } catch (_) {
      throw const FormatException('could not read API key file');
    }
  }
  // Precedence: upload token, then the deprecated API key; null means the DSN key fallback.
  final bearer = token ?? key;
  final dir = Directory(build ?? 'build/web').absolute;
  for (final name in ['main.dart.wasm', 'main.dart.wasm.map', 'index.html']) {
    if (!File('${dir.path}/$name').existsSync())
      throw FormatException(
          'missing ${dir.path}/$name; run flutter build web --wasm --source-maps --no-strip-wasm');
  }
  final dsn = option('dsn');
  if (!switches.contains('dry-run') && dsn == null)
    throw const FormatException('provide --dsn or WASMWATCH_DSN');
  final mapFile = File('${dir.path}/main.dart.wasm.map');
  final root = findRoot(mapFile, values['package-root']);
  final version = pubspecField(root, 'version');
  final release = option('release') ??
      (version == null || version.isEmpty
          ? throw const FormatException(
              'pubspec has no version; pass --release')
          : '${pubspecField(root, 'name')}@$version');
  final map = jsonDecode(mapFile.readAsStringSync()) as Map<String, dynamic>;
  final wasm = File('${dir.path}/main.dart.wasm').readAsBytesSync();
  deriveIdentity(wasm, map);
  if (!switches.contains('no-source-context')) enrichSources(map, root);
  if (!switches.contains('no-rewrite-paths')) rewriteSources(map, root);
  final identity = deriveIdentity(wasm, map);
  final id = identity['debug_id'] as String;
  if (values['debug-id'] != null && values['debug-id'] != id)
    throw FormatException(
        'explicit debug ID does not match artifact-derived ID $id');
  map['x_wasmwatch_artifact'] = identity;
  final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(map));
  atomicWrite(mapFile, bytes);
  injectGlobals(File('${dir.path}/index.html'), id, release);
  final jsFile = File('${dir.path}/main.dart.js.map');
  final jsFound = !switches.contains('no-js-source-map') && jsFile.existsSync();
  var jsLine = switches.contains('no-js-source-map')
      ? '\njs source map skipped (--no-js-source-map)'
      : jsFound
          ? ''
          : '\njs source map not found (main.dart.js.map)';
  String artifact;
  if (switches.contains('dry-run')) {
    if (jsFound) jsLine = '\njs source map found (dry run, not uploaded)';
    artifact = 'dry-run (no network upload)';
  } else {
    final target = _Target.resolve(dsn!, bearer, option('project-id'));
    artifact = await _upload(
        target, 'wasm_source_map', id, release, bytes, timeout, interval);
    if (jsFound) {
      // Uploaded from an in-memory copy: the file on disk may be deployed as-is.
      // Any JS map failure is a warning: the WASM map is already uploaded, so it must never fail the build.
      try {
        final jsBytes = _jsMapBytes(jsFile, root,
            rewrite: !switches.contains('no-rewrite-paths'));
        jsLine =
            '\njs artifact ${await _upload(target, 'js_source_map', id, release, jsBytes, timeout, interval)}';
      } on _ApiRejected catch (e) {
        if (e.status == 400 && e.code == 'invalid_artifact_type') {
          stderr.writeln(
              'wasmwatch: warning: server does not accept JS source maps yet; skipped main.dart.js.map');
          jsLine = '\njs source map skipped (not supported by the server)';
        } else {
          stderr.writeln(
              'wasmwatch: warning: JS source map upload failed; skipped main.dart.js.map: ${e.code}');
          jsLine = '\njs source map skipped (upload failed)';
        }
      } catch (e) {
        stderr.writeln(
            'wasmwatch: warning: JS source map upload failed; skipped main.dart.js.map: $e');
        jsLine = '\njs source map skipped (upload failed)';
      }
    }
  }
  final total = (map['sources'] as List).length;
  final context = (map['sourcesContent'] as List? ?? [])
      .take(total)
      .where((v) => v != null)
      .length;
  return 'debug id $id\nrelease $release\nsources with context $context/$total\nartifact $artifact$jsLine';
}

/// Source paths are rewritten like the Wasm map's; anything that cannot be handled is uploaded unmodified.
List<int> _jsMapBytes(File file, Directory root, {required bool rewrite}) {
  final original = file.readAsBytesSync();
  if (!rewrite) return original;
  try {
    final map = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
    final before = jsonEncode(map['sources']);
    rewriteSources(map, root);
    return jsonEncode(map['sources']) == before
        ? original
        : utf8.encode(jsonEncode(map));
  } catch (_) {
    return original;
  }
}

class _ApiRejected extends FormatException {
  _ApiRejected(super.message, this.status, this.code);
  final int status;
  final String? code;
}

/// Where and as whom to upload; warnings are printed once per run, whatever the artifact count.
class _Target {
  _Target(this.base, this.project, this.key);
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

  static _Target resolve(String dsn, String? bearer, String? project) {
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
    return _Target(base, project, key);
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
      return _ApiRejected(
          'this key cannot upload artifacts (HTTP $status insufficient_scope); create an upload token (wws_...) in Project Settings and set WASMWATCH_UPLOAD_TOKEN',
          status,
          code);
    case 'invalid_api_key':
      return _ApiRejected(
          'the API key or upload token was rejected (HTTP $status invalid_api_key); check WASMWATCH_UPLOAD_TOKEN and the project ID',
          status,
          code);
    case 'invalid_artifact_type':
    case 'unsupported_artifact_type':
      return _ApiRejected(
          'API request failed with HTTP $status ($code)', status, code);
  }
  return _ApiRejected('API request failed with HTTP $status', status, null);
}

Future<String> _upload(_Target target, String artifactType, String id,
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
