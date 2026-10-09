import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/src/cli/artifact_identity.dart';
import 'package:wasmwatch/src/cli/source_context.dart';
import 'package:wasmwatch/src/cli/upload_sourcemaps.dart';

const wasm = [0, 97, 115, 109, 1, 0, 0, 0];

void main() {
  test('artifact identity matches Node, including numeric keys and numbers',
      () {
    final map = jsonDecode(
            File('test/fixtures/artifact_identity.json').readAsStringSync())
        as Map<String, dynamic>;
    // Obtained with deriveArtifactIdentity in scripts/lib/artifact-identity.mjs
    // using Node and the eight-byte Wasm header above.
    final identity = deriveIdentity(wasm, map);
    expect(identity['debug_id'], '67c9216e-e766-7230-9a5b-01c555a3ea7a');
    expect(identity['map_payload_sha256'],
        'da2df7f01856e9d7efe1df5c4b66508cc317cd0a65772e5377a1925051bb1b61');
    map['x_wasmwatch_artifact'] = identity;
    expect(deriveIdentity(wasm, map), identity);
  });

  late Directory root;
  late Directory build;
  setUp(() {
    root = Directory.systemTemp.createTempSync('wasmwatch-upload-');
    build = Directory('${root.path}/build/web')..createSync(recursive: true);
    File('${root.path}/pubspec.yaml')
        .writeAsStringSync('name: demo\nversion: 1.2.3+4\n');
    Directory('${root.path}/lib').createSync();
    File('${root.path}/lib/main.dart').writeAsStringSync('void main() {}\n');
    File('${root.path}/lib/extra.dart').writeAsStringSync('const extra = 1;\n');
    Directory('${root.path}/dep/lib').createSync(recursive: true);
    File('${root.path}/dep/lib/dep.dart').writeAsStringSync('const dep = 2;\n');
    Directory('${root.path}/.dart_tool').createSync();
    File('${root.path}/.dart_tool/package_config.json')
        .writeAsStringSync(jsonEncode({
      'configVersion': 2,
      'packages': [
        {'name': 'dep', 'rootUri': '../dep', 'packageUri': 'lib/'}
      ]
    }));
    File('${build.path}/main.dart.wasm').writeAsBytesSync(wasm);
    File('${build.path}/main.dart.wasm.map').writeAsStringSync(jsonEncode({
      'version': 3,
      'sources': [
        File('${root.path}/lib/main.dart').uri.toString(),
        'package:dep/dep.dart'
      ],
      'mappings': 'AAAA',
      'sourcesContent': [null, null]
    }));
    File('${build.path}/index.html').writeAsStringSync(
        '<html><head><script>window.__WASMWATCH_DEBUG_ID__ = "old";window.__WASMWATCH_RELEASE__ = \'old\';</script></head></html>');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('enriches, seals, injects and uploads the exact final disk bytes',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Map<String, dynamic>? created;
    List<int>? uploaded;
    var polls = 0;
    final errors = <Object>[];
    server.listen((req) async {
      try {
        final raw = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        if (req.uri.path == '/storage') {
          expect(req.method, 'PUT');
          expect(req.headers.value('authorization'), isNull);
          expect(req.contentLength, raw.length);
          expect(req.headers.value('x-amz-checksum-sha256'),
              base64Encode(sha256.convert(raw).bytes));
          uploaded = raw;
          req.response.statusCode = 200;
        } else {
          expect(req.headers.value('authorization'), 'Bearer secret');
          expect(req.headers.value('accept'), 'application/json');
          req.response.headers.contentType = ContentType.json;
          if (req.uri.path == '/api/v1/projects/project/artifacts/upload-url') {
            created = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
            expect(req.headers.value('idempotency-key'),
                'wasmwatch-upload-${created!['debug_id']}-${created!['checksum_sha256']}');
            req.response.write(jsonEncode({
              'artifact_id': 'artifact',
              'debug_id': created!['debug_id'],
              'checksum_sha256': created!['checksum_sha256'],
              'max_upload_bytes': 104857600,
              'upload_url': 'http://127.0.0.1:${server.port}/storage',
              'required_upload_headers': {
                'Content-Length': '${created!['content_length']}',
                'x-amz-checksum-sha256': created!['checksum_sha256']
              },
              'signed_headers': [
                'host',
                'content-length',
                'x-amz-checksum-sha256'
              ]
            }));
          } else if (req.uri.path.endsWith('/complete')) {
            expect(req.headers.value('idempotency-key'),
                'wasmwatch-complete-artifact');
            expect(jsonDecode(utf8.decode(raw)), {
              'content_length': uploaded!.length,
              'checksum_sha256': sha256.convert(uploaded!).toString()
            });
            req.response.write('{}');
          } else if (req.uri.path.endsWith('/status')) {
            expect(req.headers.value('idempotency-key'),
                'wasmwatch-status-artifact');
            req.response.write(jsonEncode({
              'artifact_id': 'artifact',
              'debug_id': created!['debug_id'],
              'processing_status': polls++ == 0 ? 'processing' : 'ready'
            }));
          } else {
            throw StateError('Unexpected endpoint ${req.uri}');
          }
        }
      } catch (e) {
        errors.add(e);
        req.response.statusCode = 400;
      }
      await req.response.close();
    });
    final args = [
      build.path,
      '--dsn',
      'http://secret@127.0.0.1:${server.port}/api/v1/envelope/project',
      '--poll-interval-ms',
      '1'
    ];
    final output = await runUploadSourcemaps(args, environment: {});
    expect(errors, isEmpty);
    expect(output, contains('release demo@1.2.3+4'));
    expect(created!['release'], 'demo@1.2.3+4');
    final file = File('${build.path}/main.dart.wasm.map');
    expect(uploaded, file.readAsBytesSync());
    expect(created!['checksum_sha256'],
        sha256.convert(file.readAsBytesSync()).toString());
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(map['sources'], [
      'package:demo/main.dart',
      'package:dep/dep.dart',
      'package:demo/extra.dart'
    ]);
    expect(map['sourcesContent'],
        ['void main() {}\n', 'const dep = 2;\n', 'const extra = 1;\n']);
    expect(map['x_wasmwatch_artifact'], deriveIdentity(wasm, map));
    final html = File('${build.path}/index.html');
    expect(html.readAsStringSync(),
        contains('window.__WASMWATCH_DEBUG_ID__ = "${created!['debug_id']}"'));
    expect(html.readAsStringSync(),
        contains('window.__WASMWATCH_RELEASE__ = "demo@1.2.3+4"'));
    final before = html.readAsStringSync();
    await runUploadSourcemaps([build.path, '--dry-run'], environment: {});
    expect(html.readAsStringSync(), before);
    expect(file.readAsBytesSync(), uploaded);
  });

  for (final scenario in ['failed', 'timeout', 'bad-presign', 'put-failed']) {
    test('upload handles $scenario without exposing secrets', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Map<String, dynamic>? created;
      var creates = 0;
      var puts = 0;
      final keys = <String?>[];
      server.listen((req) async {
        final raw = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path.endsWith('upload-url')) {
          creates++;
          keys.add(req.headers.value('idempotency-key'));
          if (creates == 1) {
            req.response.statusCode = 503;
            req.response.write('secret signed-url');
          } else {
            created = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
            req.response.write(jsonEncode({
              'artifact_id': 'artifact',
              'debug_id': created!['debug_id'],
              'checksum_sha256': scenario == 'bad-presign'
                  ? 'wrong'
                  : created!['checksum_sha256'],
              'max_upload_bytes': 104857600,
              'upload_url':
                  'http://127.0.0.1:${server.port}/storage?secret-signed-url',
              'required_upload_headers': {
                'Content-Length': '${created!['content_length']}',
                'x-amz-checksum-sha256': created!['checksum_sha256'],
              },
              'signed_headers': [
                'host',
                'content-length',
                'x-amz-checksum-sha256'
              ],
            }));
          }
        } else if (req.uri.path == '/storage') {
          puts++;
          req.response.statusCode = scenario == 'put-failed' ? 500 : 200;
          req.response.write('secret-signed-url');
        } else if (req.uri.path.endsWith('/complete')) {
          req.response.write('{}');
        } else {
          req.response.write(jsonEncode({
            'artifact_id': 'artifact',
            'debug_id': created!['debug_id'],
            'processing_status': 'failed',
            'error': 'secret tenant data',
          }));
        }
        await req.response.close();
      });
      Object? error;
      try {
        await runUploadSourcemaps([
          build.path,
          '--dsn',
          'http://secret@127.0.0.1:${server.port}/project',
          '--timeout-secs',
          scenario == 'timeout' ? '0' : '10',
        ], environment: {});
      } catch (e) {
        error = e;
      }
      expect(error, isA<FormatException>());
      expect(error.toString(), isNot(contains('secret')));
      expect(
          error.toString(),
          contains(switch (scenario) {
            'failed' => 'artifact processing failed',
            'timeout' => 'timed out',
            'bad-presign' => 'does not match',
            _ => 'not retried',
          }));
      expect(creates, 2);
      expect(keys[0], keys[1]);
      expect(puts, scenario == 'bad-presign' ? 0 : 1);
    });
  }

  test('dry run supports overrides and disabling preparation', () async {
    final key = File('${root.path}/key')..writeAsStringSync('secret\n');
    final output = await runUploadSourcemaps([
      build.path,
      '--dry-run',
      '--no-source-context',
      '--no-rewrite-paths',
      '--api-key-file',
      key.path,
      '--release',
      'custom'
    ], environment: {});
    final map =
        jsonDecode(File('${build.path}/main.dart.wasm.map').readAsStringSync())
            as Map;
    expect((map['sources'] as List).first, startsWith('file:'));
    expect(map['sourcesContent'], [null, null]);
    expect(output, contains('release custom'));
    expect(output, contains('no network upload'));
  });

  test('mismatched explicit ID leaves artifacts unchanged', () async {
    final file = File('${build.path}/main.dart.wasm.map');
    final before = file.readAsStringSync();
    await expectLater(
        runUploadSourcemaps([build.path, '--dry-run', '--debug-id', 'wrong'],
            environment: {}),
        throwsA(isA<FormatException>()));
    expect(file.readAsStringSync(), before);
  });

  test('missing build tells developers the required Flutter command', () async {
    File('${build.path}/main.dart.wasm').deleteSync();
    await expectLater(
        runUploadSourcemaps([build.path, '--dry-run'], environment: {}),
        throwsA(predicate((e) => e.toString().contains(
            'flutter build web --wasm --source-maps --no-strip-wasm'))));
  });

  test('rewrite preserves collisions, unknown paths and raw escapes', () {
    final app = File('${root.path}/lib/main.dart').uri.toString();
    final map = <String, dynamic>{
      'sources': [
        app,
        'package:demo/main.dart',
        'file:///unknown/lib/a.dart',
        'file:///cache/hosted/pub.dev/some_pkg-1.2.3/lib/a%20b.dart',
        'dart:core',
        'file:///bad/../lib/a.dart'
      ]
    };
    rewriteSources(map, root);
    expect(map['sources'], [
      app,
      'package:demo/main.dart',
      'file:///unknown/lib/a.dart',
      'package:some_pkg/a%20b.dart',
      'dart:core',
      'file:///bad/../lib/a.dart'
    ]);
  });

  test('ambiguous package directories stay unmapped', () {
    File('${root.path}/.dart_tool/package_config.json')
        .writeAsStringSync(jsonEncode({
      'packages': [
        {'name': 'one', 'rootUri': '../dep'},
        {'name': 'two', 'rootUri': '../dep'}
      ]
    }));
    final source = File('${root.path}/dep/lib/dep.dart').uri.toString();
    final map = <String, dynamic>{
      'sources': [source]
    };
    rewriteSources(map, root);
    expect(map['sources'], [source]);
  });
}
