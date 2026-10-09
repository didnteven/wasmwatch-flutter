import 'dart:convert';
import 'dart:io';

bool validName(String name) => RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(name);
String? pubspecField(Directory root, String field) {
  final file = File('${root.path}/pubspec.yaml');
  if (!file.existsSync() || file.lengthSync() > 1024 * 1024) return null;
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('$field:')) {
      var value = line.substring(field.length + 1).split(' #').first.trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      return value;
    }
  }
  return null;
}

Directory findRoot(File map, String? explicit) {
  var dir = explicit == null
      ? File(map.resolveSymbolicLinksSync()).parent
      : Directory(explicit).absolute;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) {
      final name = pubspecField(dir, 'name');
      if (name != null && validName(name))
        return Directory(dir.resolveSymbolicLinksSync());
      break;
    }
    if (explicit != null || dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  throw const FormatException(
      'no readable pubspec.yaml with a valid package name above BUILD_DIR; pass --package-root');
}

String slash(String value) => value.endsWith('/') ? value : '$value/';
Map<String, Uri> packageLibraries(Directory root, {bool forgiving = false}) {
  final config = File('${root.path}/.dart_tool/package_config.json');
  final result = <String, Uri>{};
  if (!config.existsSync()) return result;
  try {
    final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
    for (final entry in json['packages'] as List? ?? []) {
      if (entry['name'] is! String || entry['rootUri'] is! String) continue;
      final uri =
          config.absolute.uri.resolve(slash(entry['rootUri'] as String));
      final lib = uri.resolve(slash(entry['packageUri'] as String? ?? 'lib/'));
      if (lib.scheme == 'file') result[entry['name'] as String] = lib;
    }
  } catch (_) {
    if (!forgiving) rethrow;
  }
  return result;
}

void enrichSources(Map<String, dynamic> map, Directory root) {
  final name = pubspecField(root, 'name')!;
  final packages = packageLibraries(root)
    ..[name] = Directory('${root.path}/lib').uri;
  File? sourceFile(Object? source) {
    if (source is! String) return null;
    try {
      if (source.startsWith('package:')) {
        final parts = source.substring(8).split('/');
        final base = packages[parts.first];
        return base == null || parts.length < 2
            ? null
            : File.fromUri(base.resolve(parts.skip(1).join('/')));
      }
      if (source.startsWith('file:')) return File.fromUri(Uri.parse(source));
      if (source.startsWith('/')) return File(source);
    } catch (_) {/* Unsupported URI remains without context. */}
    return null;
  }

  final sources = List<dynamic>.of(map['sources'] as List);
  final old = map['sourcesContent'] is List
      ? map['sourcesContent'] as List
      : <dynamic>[];
  final contents = List<dynamic>.generate(
      sources.length, (i) => i < old.length ? old[i] : null);
  final listed = <String>{};
  for (var i = 0; i < sources.length; i++) {
    final file = sourceFile(sources[i]);
    if (file != null) {
      try {
        listed.add(file.resolveSymbolicLinksSync());
      } on FileSystemException {}
    }
  }
  const maxSourceBytes = 6 * 1024 * 1024;
  var totalBytes = 0;
  for (final c in contents) {
    if (c is String) totalBytes += utf8.encode(c).length;
  }
  final appPrefix = 'package:$name/';
  for (var i = 0; i < sources.length; i++) {
    if (contents[i] != null) continue;
    final source = sources[i];
    if (source is String && source.startsWith(appPrefix)) {
      final file = sourceFile(source);
      if (file == null) continue;
      try {
        final text = file.readAsStringSync();
        final bytes = utf8.encode(text).length;
        if (totalBytes + bytes <= maxSourceBytes) {
          totalBytes += bytes;
          contents[i] = text;
        }
      } on FileSystemException {}
    }
  }
  for (var i = 0; i < sources.length; i++) {
    if (contents[i] != null) continue;
    final file = sourceFile(sources[i]);
    if (file == null) continue;
    try {
      final text = file.readAsStringSync();
      final bytes = utf8.encode(text).length;
      if (totalBytes + bytes <= maxSourceBytes) {
        totalBytes += bytes;
        contents[i] = text;
      }
    } on FileSystemException {}
  }
  final lib = Directory('${root.path}/lib');
  void collect(Directory dir) {
    if (!dir.existsSync()) return;
    final entries = dir.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      if (entry is Directory) collect(entry);
      if (entry is File &&
          entry.path.endsWith('.dart') &&
          !listed.contains(entry.resolveSymbolicLinksSync())) {
        final text = entry.readAsStringSync();
        final bytes = utf8.encode(text).length;
        if (totalBytes + bytes <= maxSourceBytes) {
          totalBytes += bytes;
          sources.add(
              'package:$name/${entry.path.substring(lib.path.length + 1).replaceAll('\\', '/')}');
          contents.add(text);
        }
      }
    }
  }

  collect(lib);
  map['sources'] = sources;
  map['sourcesContent'] = contents;
}

class _SourcePath {
  final List<String> raw;
  final List<String> decoded;
  final bool drive;
  _SourcePath(this.raw, this.decoded, this.drive);
  static _SourcePath? parse(String source) {
    final url = source.startsWith('file:///');
    final drivePattern = RegExp(r'^[a-zA-Z]:[/\\]');
    final String body;
    if (url) {
      body = source.substring(8);
    } else if (source.startsWith('/') && !source.startsWith('//')) {
      body = source.substring(1);
    } else if (drivePattern.hasMatch(source)) {
      body = source;
    } else {
      return null;
    }
    final drive = drivePattern.hasMatch(body);
    final raw = body.split(drive && !url ? RegExp(r'[/\\]') : '/');
    try {
      final decoded = raw.map((s) => url ? Uri.decodeComponent(s) : s).toList();
      if (decoded.any((s) =>
          s.isEmpty ||
          s == '.' ||
          s == '..' ||
          s.contains(RegExp(r'[/\\\x00]')))) return null;
      return _SourcePath(raw, decoded, drive);
    } on FormatException {
      return null;
    }
  }

  File pubspec(int end) =>
      File('${drive ? '' : '/'}${decoded.take(end).join('/')}/pubspec.yaml');
  String? package(String name, int from) => validName(name) && from < raw.length
      ? 'package:$name/${raw.skip(from).join('/')}'
      : null;
}

void rewriteSources(Map<String, dynamic> map, Directory root) {
  final libs = <(List<String>, String)>[];
  final entries = <(List<String>, String)>[];
  final config = File('${root.path}/.dart_tool/package_config.json');
  if (config.existsSync() && config.lengthSync() <= 1024 * 1024) {
    try {
      final json = jsonDecode(config.readAsStringSync()) as Map;
      final bases = {
        config.absolute.parent.uri,
        Directory(config.parent.resolveSymbolicLinksSync()).uri
      };
      for (final entry in json['packages'] as List? ?? []) {
        final name = entry['name'];
        if (name is! String || !validName(name) || entry['rootUri'] is! String)
          continue;
        for (final base in bases) {
          final packageRoot = base.resolve(slash(entry['rootUri'] as String));
          final lib = packageRoot
              .resolve(slash(entry['packageUri'] as String? ?? 'lib/'));
          if (lib.scheme != 'file' || !lib.path.startsWith(packageRoot.path))
            continue;
          final parts = lib.pathSegments.where((s) => s.isNotEmpty).toList();
          entries.add((parts, name));
        }
      }
    } catch (_) {/* Rust ignores unusable rewrite configuration. */}
  }
  bool equal(List<String> a, List<String> b) =>
      a.join('\u0000') == b.join('\u0000');
  void add(List<String> parts, String name) {
    if (!libs.any((e) => equal(e.$1, parts))) libs.add((parts, name));
  }

  for (final e in entries) {
    if (!entries.any((other) => equal(e.$1, other.$1) && e.$2 != other.$2))
      add(e.$1, e.$2);
  }
  final lib = Directory('${root.path}/lib');
  for (final path in {
    lib.absolute.path,
    if (lib.existsSync()) lib.resolveSymbolicLinksSync()
  }) {
    add(path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList(),
        pubspecField(root, 'name')!);
  }
  String? rewrite(String source) {
    final p = _SourcePath.parse(source);
    if (p == null) return null;
    (List<String>, String)? best;
    for (final e in libs) {
      if (p.decoded.length > e.$1.length &&
          equal(p.decoded.take(e.$1.length).toList(), e.$1) &&
          (best == null || e.$1.length >= best.$1.length)) best = e;
    }
    if (best != null) return p.package(best.$2, best.$1.length);
    for (var i = 0; i + 3 < p.decoded.length; i++) {
      if (p.decoded[i] != 'hosted' || p.decoded[i + 3] != 'lib') continue;
      final match = RegExp(
              r'^([a-z_][a-z0-9_]*)-([0-9]+\.[0-9]+\.[0-9]+)(-[a-zA-Z0-9.\-]+)?(\+[a-zA-Z0-9.\-]+)?$')
          .firstMatch(p.decoded[i + 2]);
      if (match == null) continue;
      final name = match[1]!;
      final spec = p.pubspec(i + 3);
      if (spec.existsSync() && pubspecField(spec.parent, 'name') != name)
        return null;
      return p.package(name, i + 4);
    }
    for (var i = p.decoded.length - 2; i >= 1; i--) {
      if (p.decoded[i] != 'lib') continue;
      final spec = p.pubspec(i);
      if (spec.existsSync()) {
        final name = pubspecField(spec.parent, 'name');
        return name == null ? null : p.package(name, i + 1);
      }
    }
    return null;
  }

  final sources = map['sources'] as List;
  final replacements =
      sources.map((s) => s is String ? rewrite(s) : null).toList();
  while (true) {
    final finals =
        List.generate(sources.length, (i) => replacements[i] ?? sources[i]);
    final collisions = List.generate(sources.length, (i) => i)
        .where((i) =>
            replacements[i] != null &&
            finals.where((s) => s == finals[i]).length > 1)
        .toList();
    if (collisions.isEmpty) break;
    for (final i in collisions) {
      replacements[i] = null;
    }
  }
  map['sources'] =
      List.generate(sources.length, (i) => replacements[i] ?? sources[i]);
}
