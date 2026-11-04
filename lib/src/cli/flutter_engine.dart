import 'dart:convert';
import 'dart:io';

/// Injectable only for Flutter discovery; archive extraction uses the host unzip.
typedef FlutterRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

class FlutterEngine {
  FlutterEngine(this.revision, this.root);
  final String revision;
  final String? root;

  static Future<FlutterEngine> discover(
      String executable, FlutterRunner runner) async {
    final ProcessResult result;
    try {
      result = await runner(executable, ['--version', '--machine']);
    } on ProcessException {
      throw FormatException(
          'Flutter not found: $executable; use --flutter-bin');
    }
    if (result.exitCode != 0) {
      throw FormatException('Flutter --version --machine failed ($executable)');
    }
    try {
      final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final revision = data['engineRevision'];
      if (revision is! String ||
          !RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(revision)) {
        throw const FormatException(
            'Flutter output lacks a valid engineRevision');
      }
      return FlutterEngine(revision, data['flutterRoot'] as String?);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('invalid Flutter --version --machine output');
    }
  }

  File iosDwarf(String? dsymsDir) {
    if (dsymsDir != null) {
      final dir = Directory(dsymsDir);
      final candidates = <Directory>[
        if (dir.path.endsWith('Flutter.framework.dSYM')) dir,
        ...dir
            .listSync(recursive: true, followLinks: false)
            .whereType<Directory>()
            .where((d) => d.path.endsWith('/Flutter.framework.dSYM')),
      ]..sort((a, b) => a.path.compareTo(b.path));
      if (candidates.isNotEmpty) {
        return File(
            '${candidates.first.path}/Contents/Resources/DWARF/Flutter');
      }
    }
    if (root == null || root!.isEmpty) {
      throw const FormatException(
          'Flutter output lacks flutterRoot; pass --dsyms-dir');
    }
    return File('$root/bin/cache/artifacts/engine/ios-release/'
        'Flutter.xcframework/ios-arm64/dSYMs/Flutter.framework.dSYM/'
        'Contents/Resources/DWARF/Flutter');
  }

  static Directory cacheDirectory(Map<String, String> env) {
    final home = env['HOME'] ?? env['USERPROFILE'];
    final base = env['XDG_CACHE_HOME'] ??
        (Platform.isWindows ? env['LOCALAPPDATA'] : null) ??
        (home == null
            ? null
            : '$home/${Platform.isMacOS ? 'Library/Caches' : '.cache'}');
    if (base == null || base.isEmpty) {
      throw const FormatException(
          'cannot find user cache directory (HOME/XDG_CACHE_HOME)');
    }
    return Directory('$base/wasmwatch/flutter-engine');
  }

  File cachedZip(Directory cache, String abi) =>
      File('${cache.path}/$revision/android-$abi-release/symbols.zip');

  /// Keep compressed archives on disk; publish a complete download atomically.
  Future<File> androidZip(Directory cache, String abi, Uri storageBase) async {
    final zip = cachedZip(cache, abi);
    if (zip.existsSync()) return zip;
    zip.parent.createSync(recursive: true);
    final staging = Directory.systemTemp.createTempSync('wasmwatch-download-');
    // Stage alongside the destination for atomic rename across filesystems.
    final partial = File(
        '${zip.path}.${staging.uri.pathSegments.where((s) => s.isNotEmpty).last}.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final url =
          storageBase.resolve('$revision/android-$abi-release/symbols.zip');
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw FormatException(
            'Flutter engine symbols download failed: HTTP ${response.statusCode} ($url)');
      }
      final sink = partial.openWrite();
      try {
        var length = 0;
        await for (final chunk in response) {
          length += chunk.length;
          if (length > 256 * 1024 * 1024) {
            throw const FormatException(
                'Flutter engine symbols.zip exceeds 256 MiB');
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      partial.renameSync(zip.path);
      return zip;
    } finally {
      client.close(force: true);
      if (partial.existsSync()) partial.deleteSync();
      staging.deleteSync();
    }
  }
}

/// Select exactly one entry. No archive-controlled path is ever written to disk.
Future<File> extractFlutterLibrary(File zip, Directory temporary) async {
  try {
    final listing = await Process.run('unzip', ['-Z1', zip.path]);
    if (listing.exitCode != 0) {
      throw const FormatException('invalid Flutter engine symbols.zip');
    }
    final entries = const LineSplitter()
        .convert(listing.stdout as String)
        .where((s) => s == 'libflutter.so' || s.endsWith('/libflutter.so'))
        .toList();
    if (entries.length != 1) {
      throw const FormatException(
          'symbols.zip must contain exactly one libflutter.so entry');
    }
    final process =
        await Process.start('unzip', ['-p', zip.path, entries.single]);
    final errors = process.stderr.drain<void>();
    final output = File('${temporary.path}/libflutter.so');
    final sink = output.openWrite();
    try {
      var length = 0;
      await for (final chunk in process.stdout) {
        length += chunk.length;
        if (length > 256 * 1024 * 1024) {
          process.kill();
          throw const FormatException('libflutter.so exceeds 256 MiB');
        }
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
      await errors;
    }
    if (await process.exitCode != 0) {
      throw const FormatException(
          'could not extract libflutter.so (invalid ZIP/CRC)');
    }
    return output;
  } on ProcessException {
    throw const FormatException(
        'unzip is required to extract Flutter engine symbols.zip; install unzip');
  }
}
