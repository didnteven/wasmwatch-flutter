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
  --api-key KEY              Override DSN key (or WASMWATCH_API_KEY)
  --api-key-file FILE        Read API key from file
  --project-id ID            Override project (or WASMWATCH_PROJECT_ID)
  --release RELEASE         Defaults to pubspec name@version (WASMWATCH_RELEASE)
  --package-root DIR         App directory containing pubspec.yaml
  --no-source-context        Skip embedding sources from disk
  --no-rewrite-paths         Preserve source paths
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
  const flags = {'no-source-context', 'no-rewrite-paths', 'dry-run'};
  const options = {
    'dsn',
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
  final artifact = switches.contains('dry-run')
      ? 'dry-run (no network upload)'
      : await _upload(dsn!, key, option('project-id'), id, release, bytes,
          timeout, interval);
  final total = (map['sources'] as List).length;
  final context = (map['sourcesContent'] as List? ?? [])
      .take(total)
      .where((v) => v != null)
      .length;
  return 'debug id $id\nrelease $release\nsources with context $context/$total\nartifact $artifact';
}

Future<String> _upload(String dsn, String? key, String? project, String id,
    String release, List<int> bytes, int timeout, int interval) async {
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
  key ??= uri.userInfo.split(':').first;
  if (key.isEmpty)
    throw const FormatException('invalid DSN: API key is missing');
  final base = Uri(
      scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
  Uri endpoint(String suffix) =>
      base.resolve('/api/v1/projects/$project/$suffix');
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
        await Future<void>.delayed(
            Duration(milliseconds: 100 * (1 << attempt)));
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw FormatException(
            'API request failed with HTTP ${response.statusCode}');
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
      'artifact_type': 'wasm_source_map',
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
