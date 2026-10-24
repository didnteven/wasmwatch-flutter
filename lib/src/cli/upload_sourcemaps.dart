import 'dart:convert';
import 'dart:io';
import 'artifact_identity.dart';
import 'source_context.dart';
import 'upload_client.dart';

export 'upload_client.dart' show uploadApiErrorMessage;

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
  if (!html.contains('window.__wasmwatchRethrow=')) {
    final bootstrap = RegExp(r'<script\b[^>]*flutter_bootstrap\.js[^>]*>',
            caseSensitive: false)
        .firstMatch(html);
    final head = html.toLowerCase().indexOf('</head>');
    final pos = bootstrap?.start ?? (head < 0 ? 0 : head);
    html =
        '${html.substring(0, pos)}<script>window.__wasmwatchRethrow=function(e){throw e};</script>\n${html.substring(pos)}';
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
    final target = UploadTarget.resolve(dsn!, bearer, option('project-id'));
    artifact = await uploadArtifact(
        target, 'wasm_source_map', id, release, bytes, timeout, interval);
    if (jsFound) {
      // Uploaded from an in-memory copy: the file on disk may be deployed as-is.
      // Any JS map failure is a warning: the WASM map is already uploaded, so it must never fail the build.
      try {
        final jsBytes = _jsMapBytes(jsFile, root,
            rewrite: !switches.contains('no-rewrite-paths'), context: !switches.contains('no-source-context'));
        jsLine =
            '\njs artifact ${await uploadArtifact(target, 'js_source_map', id, release, jsBytes, timeout, interval)}';
      } on UploadApiRejected catch (e) {
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
List<int> _jsMapBytes(File file, Directory root, {required bool rewrite, bool context = true}) {
  final original = file.readAsBytesSync();
  if (!rewrite && !context) return original;
  try {
    final map = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
    if (context) enrichSources(map, root);
    if (rewrite) rewriteSources(map, root);
    return utf8.encode(jsonEncode(map));
  } catch (_) {
    return original;
  }
}
