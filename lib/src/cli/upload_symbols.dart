import 'dart:io';
import 'dart:typed_data';
import '../native/aot_identity.dart';
import 'source_context.dart';
import 'upload_client.dart';

const uploadSymbolsHelp = '''Upload Flutter mobile debug symbols with pure Dart.
Usage: dart run wasmwatch:upload_symbols --symbols-dir build/symbols [options]
       dart run wasmwatch:upload_symbols --dsym App.framework.dSYM [options]
  --symbols-dir DIR          Android: the --split-debug-info directory
  --dsym DIR                 iOS: the build's App.framework.dSYM (not Runner.app.dSYM)
  --obfuscation-map FILE     Upload the map once per build debug ID
  --dsn DSN                 SDK DSN (or WASMWATCH_DSN)
  --upload-token TOKEN      Secret upload token (or WASMWATCH_UPLOAD_TOKEN)
  --upload-token-file FILE  Read the upload token from file
  --api-key KEY             Deprecated alias (or WASMWATCH_API_KEY)
  --api-key-file FILE       Read API key from file
  --project-id ID           Override project (or WASMWATCH_PROJECT_ID)
  --release RELEASE        Defaults to pubspec name@version (WASMWATCH_RELEASE)
  --package-root DIR        App directory containing pubspec.yaml
  --dry-run                 List artifacts without network requests
  --timeout-secs SECONDS    Processing timeout (default 300)
  --poll-interval-ms MS     Initial poll interval (default 250)
  --help                    Show this help''';

/// Reads section-backed GNU build-ID notes, without interpreting debug data.
String elfBuildId(Uint8List bytes) {
  const invalid = FormatException('invalid or unsupported ELF build-ID note');
  final data = ByteData.sublistView(bytes);
  void range(int offset, int length) {
    if (offset < 0 || length < 0 || offset > bytes.length - length) throw invalid;
  }

  int u16(int offset) => data.getUint16(offset, Endian.little);
  int u32(int offset) => data.getUint32(offset, Endian.little);
  int u64(int offset) => data.getUint64(offset, Endian.little);
  range(0, 16);
  if (bytes[0] != 0x7f || bytes[1] != 0x45 || bytes[2] != 0x4c ||
      bytes[3] != 0x46 || !{1, 2}.contains(bytes[4]) || bytes[5] != 1 || bytes[6] != 1) {
    throw invalid;
  }
  final wide = bytes[4] == 2;
  range(0, wide ? 64 : 52);
  final sectionOffset = wide ? u64(40) : u32(32);
  final entrySize = u16(wide ? 58 : 46);
  var count = u16(wide ? 60 : 48);
  if (sectionOffset == 0 || entrySize < (wide ? 64 : 40)) throw invalid;
  range(sectionOffset, entrySize);
  if (count == 0) count = wide ? u64(sectionOffset + 32) : u32(sectionOffset + 20);
  if (count <= 0 || count > (bytes.length - sectionOffset) ~/ entrySize) throw invalid;
  String? buildId;
  for (var i = 0; i < count; i++) {
    final section = sectionOffset + i * entrySize;
    if (u32(section + 4) != 7) continue; // SHT_NOTE
    final offset = wide ? u64(section + 24) : u32(section + 16);
    final size = wide ? u64(section + 32) : u32(section + 20);
    range(offset, size);
    final end = offset + size;
    var note = offset;
    while (note < end) {
      if (end - note < 12) throw invalid;
      final nameSize = u32(note);
      final descSize = u32(note + 4);
      final type = u32(note + 8);
      final name = note + 12;
      final desc = name + ((nameSize + 3) & ~3);
      final next = desc + ((descSize + 3) & ~3);
      if (next > end) throw invalid;
      // Android .symbols carry .note.gnu.build-id (GNU, type 3, 16 bytes); iOS .symbols carry no note.
      if (nameSize == 4 && bytes[name] == 0x47 && bytes[name + 1] == 0x4e &&
          bytes[name + 2] == 0x55 && bytes[name + 3] == 0 && type == 3) {
        if (descSize < 4 || descSize > 32) throw invalid;
        final id = bytes.sublist(desc, desc + descSize)
            .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (buildId != null && buildId != id) throw invalid;
        buildId = id;
      }
      note = next;
    }
  }
  if (buildId == null) throw const FormatException('ELF has no GNU build-ID note');
  return buildId;
}

/// Reads the LC_UUID of a thin or universal Mach-O; the Dart VM prints it as the iOS `build_id`.
/// Flutter's App.framework.dSYM is universal with one arm64 slice.
String machOUuid(Uint8List bytes) {
  const invalid = FormatException('invalid or unsupported Mach-O file');
  final data = ByteData.sublistView(bytes);
  void range(int offset, int length) {
    if (offset < 0 || length < 0 || offset > bytes.length - length) throw invalid;
  }

  String? uuid(int slice) {
    range(slice, 32);
    if (data.getUint32(slice, Endian.little) != 0xfeedfacf) throw invalid; // MH_MAGIC_64
    final commands = data.getUint32(slice + 16, Endian.little);
    var command = slice + 32;
    for (var i = 0; i < commands; i++) {
      range(command, 8);
      final size = data.getUint32(command + 4, Endian.little);
      if (size < 8) throw invalid;
      if (data.getUint32(command, Endian.little) == 0x1b) { // LC_UUID
        if (size < 24) throw invalid;
        range(command + 8, 16);
        return bytes.sublist(command + 8, command + 24).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }
      command += size;
    }
    return null;
  }

  range(0, 8);
  final String? id;
  if (data.getUint32(0, Endian.big) == 0xcafebabe) { // FAT_MAGIC
    final count = data.getUint32(4, Endian.big);
    if (count == 0 || count > 8) throw invalid;
    range(8, count * 20);
    final slices = [for (var i = 0; i < count; i++) (cpu: data.getUint32(8 + i * 20, Endian.big), offset: data.getUint32(16 + i * 20, Endian.big))];
    const arm64 = 0x0100000c;
    final slice = count == 1 ? slices.single : slices.where((s) => s.cpu == arm64).firstOrNull;
    if (slice == null) throw const FormatException('universal Mach-O has no arm64 slice');
    id = uuid(slice.offset);
  } else {
    id = uuid(0);
  }
  if (id == null) throw const FormatException('Mach-O has no LC_UUID');
  return id;
}

Uint8List _artifactBytes(File file) {
  if (!file.existsSync()) throw FormatException('missing ${file.path}');
  if (file.lengthSync() == 0 || file.lengthSync() > 100 * 1024 * 1024) {
    throw const FormatException('artifact must be non-empty and within the 100 MiB v1 limit');
  }
  return file.readAsBytesSync();
}

Future<String> runUploadSymbols(List<String> args,
    {Map<String, String>? environment}) async {
  final env = environment ?? Platform.environment;
  final values = <String, String>{};
  final switches = <String>{};
  const options = {'symbols-dir', 'obfuscation-map', 'dsym', 'dsn',
    'upload-token', 'upload-token-file', 'api-key', 'api-key-file', 'project-id',
    'release', 'package-root', 'timeout-secs', 'poll-interval-ms'};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--help' || arg == '-h') return uploadSymbolsHelp;
    if (arg == '--dry-run') {
      switches.add(arg.substring(2));
      continue;
    }
    if (!arg.startsWith('--')) throw const FormatException('expected options; use --help');
    final parts = arg.substring(2).split('=');
    final name = parts.first;
    if (!options.contains(name)) throw FormatException('unknown option --$name');
    if (parts.length > 1) {
      values[name] = parts.skip(1).join('=');
    } else {
      if (++i >= args.length || args[i].startsWith('--')) throw FormatException('--$name requires a value');
      values[name] = args[i];
    }
  }
  String? option(String name) => values[name] ?? env['WASMWATCH_${name.replaceAll('-', '_').toUpperCase()}'];
  int duration(String name, int fallback) {
    final n = int.tryParse(values[name] ?? '$fallback');
    if (n == null || n < 0) throw FormatException('--$name must be a non-negative integer');
    return n;
  }
  String? credential(String name) {
    final value = option(name);
    final path = values['$name-file'];
    if (path == null) return value;
    if (value != null) throw FormatException('--$name-file conflicts with --$name/WASMWATCH_${name.replaceAll('-', '_').toUpperCase()}');
    try {
      return File(path).readAsStringSync().replaceFirst(RegExp(r'[\r\n]+$'), '');
    } catch (_) {
      throw FormatException('could not read $name file');
    }
  }

  final timeout = duration('timeout-secs', 300);
  final interval = duration('poll-interval-ms', 250);
  final token = credential('upload-token');
  final key = credential('api-key');
  final dsym = values['dsym'];
  final directory = values['symbols-dir'];
  // One platform per run: Android and iOS builds have different obfuscation maps.
  if ((dsym == null) == (directory == null)) throw const FormatException('provide either --symbols-dir (Android) or --dsym (iOS)');
  final files = <File>[];
  final skipped = <String>[];
  if (directory != null) {
    final dir = Directory(directory);
    if (!dir.existsSync()) throw FormatException('missing ${dir.path}');
    for (final file in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.symbols'))) {
      // iOS .symbols have no build ID; the iOS identity and addresses are the dSYM's.
      if (RegExp(r'^app\.ios-.*\.symbols$').hasMatch(file.uri.pathSegments.last)) {
        skipped.add('skipped ${file.path}: iOS uses --dsym App.framework.dSYM');
      } else {
        files.add(file);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      throw FormatException(skipped.isEmpty ? 'no .symbols files found'
          : 'only iOS .symbols found; pass --dsym build/ios/Release-iphoneos/App.framework.dSYM');
    }
  }
  final dsymFile = dsym == null ? null : File('$dsym/Contents/Resources/DWARF/App');
  if (dsymFile != null) {
    if (!dsymFile.existsSync()) throw FormatException('missing ${dsymFile.path}; pass the App.framework.dSYM directory');
    files.add(dsymFile);
  }
  final dsn = option('dsn');
  final dryRun = switches.contains('dry-run');
  if (!dryRun && dsn == null) throw const FormatException('provide --dsn or WASMWATCH_DSN');
  var release = option('release');
  if (release == null) {
    // Symbols are often written outside the app (CI artifacts); fall back to
    // the app in the working directory before asking for --package-root.
    Directory root;
    try {
      root = findRoot(files.first, values['package-root']);
    } on FormatException {
      if (values['package-root'] != null) rethrow;
      try {
        root = findRoot(files.first, Directory.current.path);
      } on FormatException {
        throw const FormatException(
            'no pubspec.yaml above the symbols or in the working directory; pass --package-root or --release');
      }
    }
    final version = pubspecField(root, 'version');
    if (version == null || version.isEmpty) throw const FormatException('pubspec has no version; pass --release');
    release = '${pubspecField(root, 'name')}@$version';
  }
  final map = values['obfuscation-map'] == null ? null : _artifactBytes(File(values['obfuscation-map']!));
  final target = dryRun ? null : UploadTarget.resolve(dsn!, token ?? key, option('project-id'));
  final mapped = <String>{};
  final lines = <String>['release $release', ...skipped];
  for (final file in files) {
    final bytes = _artifactBytes(file);
    final buildId = file == dsymFile ? machOUuid(bytes) : elfBuildId(bytes);
    final id = dartAotDebugId(buildId);
    lines.add('${file.path}\ndebug id $id\nbuild id $buildId');
    final artifact = dryRun ? 'dry-run (no network upload)' : await uploadArtifact(target!, 'dart_symbols', id, release, bytes, timeout, interval);
    lines.add('dart_symbols artifact $artifact');
    if (map != null && mapped.add(id)) {
      final artifact = dryRun ? 'dry-run (no network upload)' : await uploadArtifact(target!, 'dart_obfuscation_map', id, release, map, timeout, interval);
      lines.add('dart_obfuscation_map artifact $artifact');
    }
  }
  return lines.join('\n');
}
