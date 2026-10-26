import 'dart:convert';
import '../event/breadcrumb.dart';
import '../event/error_event.dart';
import '../event/user.dart';
import '../utils/uuid.dart';
import '../wasm/stack_frame_parser.dart';
import 'aot_identity.dart';
import 'native_debug_id.dart';

final canonicalUuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _hex = RegExp(r'^0x[0-9a-f]{1,16}$');

/// Retains every recognized report, omitting optional evidence that is invalid.
ErrorEvent? eventFromNativeReport(Object? input,
    {required DateTime now,
    Map<String, Object?>? deviceContext,
    Map<String, Object?>? dartImage}) {
  if (input is! Map<String, Object?>) return null;
  final report = input;
  final kind = report['kind'];
  const types = {
    'java_crash': 'JavaCrash',
    'native_crash': 'NativeCrash',
    'anr': 'ANR',
    'app_exit': 'AppExit',
    'ios_crash': 'NativeCrash',
    'ios_hang': 'AppHang'
  };
  if (!types.containsKey(kind)) return null;
  final ios = kind == 'ios_crash' || kind == 'ios_hang';
  final platform = ios ? 'dart-ios' : 'dart-android';
  final timeKey = ios ? 'received_ms' : 'timestamp_ms';
  final fallbackImage = dartImage ??
      (ios
          ? <String, Object?>{
              'type': 'elf',
              'debug_id': '00000000-0000-7000-8000-000000000000',
              'code_file': 'App',
              'os': 'ios',
            }
          : null);
  try {
    if (report['v'] is! int ||
        report['v'] != 1 ||
        (!ios && report['pid'] is! int)) throw const FormatException();
    _string(report['id'], 256);
    _string(report['install_id'], 256);
    final timestamp = _timestamp(report[timeKey]);
    final release = _string(report['release'], 256);
    final environment = report.containsKey('environment')
        ? _string(report['environment'], 128)
        : null;
    final scope = _optional(() => _map(report['scope'])) ?? <String, Object?>{};
    final exit = _optional(() {
      final exit = _map(report['exit']);
      _validateExit(exit);
      return exit;
    });
    final images = <DebugImage>[];
    final values = <ExceptionValue>[];
    void value(String type, String message, List<RawStackFrame> frames,
        String mechanism) {
      values.add(ExceptionValue(
          type: _string(type, 512),
          value: _string(message, 16384, empty: true),
          frames: frames,
          mechanism: {'type': mechanism, 'handled': false}));
    }

    final diagnostic =
        _optional(() => _map(report['diagnostic'])) ?? <String, Object?>{};
    final iosMetadata =
        _optional(() => _map(diagnostic['diagnosticMetaData'])) ??
            <String, Object?>{};
    if (ios) {
      final frames = _iosFrames(diagnostic, report, images);
      final exception = _machExceptions[iosMetadata['exceptionType']];
      if (kind == 'ios_hang') {
        final duration = diagnostic['hangDuration'];
        value(
            'AppHang',
            duration is String || duration is num
                ? 'App hang: $duration'
                : 'App hang',
            frames,
            'app_hang');
      } else {
        final reason = _optional(() =>
            _string(iosMetadata['terminationReason'], 16000, empty: true));
        value(
            _iosSignals[iosMetadata['signal']] ?? exception ?? 'NativeCrash',
            [exception, reason].whereType<String>().join(': '),
            frames,
            'ios_metrickit');
      }
    } else if (kind == 'native_crash') {
      final signal = _optional(() => _signal(report['signal']));
      final name = _optional(() => _string(signal?['name'], 512)) ??
          const {
            6: 'SIGABRT',
            11: 'SIGSEGV',
            7: 'SIGBUS',
            4: 'SIGILL',
            8: 'SIGFPE',
            5: 'SIGTRAP'
          }[exit?['status']] ??
          'NativeCrash';
      final sourceImages = report.containsKey('images')
          ? _list(report['images']).map(_map).toList()
          : <Map<String, Object?>>[];
      final threads =
          report.containsKey('threads') ? _list(report['threads']) : [];
      final sourceFrames = threads.isEmpty
          ? <Map<String, Object?>>[]
          : _list(_map(threads.first)['frames']).take(200).map(_map).toList();
      String key(Map<String, Object?> item) =>
          '${item['file_name']}\u0000${item['build_id']}';
      final available = <String, Map<String, Object?>>{};
      for (final image in sourceImages) {
        if (!image.containsKey('build_id')) continue;
        final wire = _optional(() {
          final code = _string(image['build_id'], 80);
          final debugId = nativeDebugId(code, 'elf');
          return <String, Object?>{
            'type': 'native',
            'format': 'elf',
            'code_id': code,
            'debug_id': debugId,
            'code_file': _string(image['file_name'], 1024),
            'image_addr': _address(image['image_addr']),
            if (image.containsKey('image_size'))
              'image_size': _address(image['image_size'])
          };
        });
        if (wire != null) available.putIfAbsent(key(image), () => wire);
      }
      // Reserve referenced images before filling spare slots. Drop frames whose
      // known images cannot fit, rather than silently losing their attribution.
      final wanted = <String>{};
      final kept = <Map<String, Object?>>[];
      for (final frame in sourceFrames) {
        final id = key(frame);
        if (available.containsKey(id) && !wanted.contains(id)) {
          if (wanted.length == 64) continue;
          wanted.add(id);
        }
        kept.add(frame);
      }
      for (final id in available.keys) {
        if (wanted.length == 64) break;
        wanted.add(id);
      }
      final indices = <String, int>{};
      for (final entry in available.entries) {
        if (!wanted.contains(entry.key)) continue;
        indices[entry.key] = images.length;
        images.add(DebugImage.fromJson(entry.value));
      }
      final frames = kept
          .map((frame) => RawStackFrame.android({
                'type': 'native',
                'instruction_addr': _address(frame['pc']),
                if (frame.containsKey('function_name'))
                  'symbol': _string(frame['function_name'], 256, empty: true),
                if (frame.containsKey('function_offset'))
                  'symbol_offset': _address(frame['function_offset']),
                if (indices[key(frame)] != null)
                  'image_index': indices[key(frame)],
              }))
          .toList();
      final codeName = signal?['code_name'];
      final description = exit?['description'] ?? '';
      value(
          name,
          (signal == null
              ? description
              : report['abort_message'] ??
                  (codeName == null || codeName == ''
                      ? name
                      : '$name ($codeName)')) as String,
          frames,
          'android_native');
    } else if (kind == 'java_crash' || kind == 'anr' || kind == 'app_exit') {
      if (kind != 'app_exit' && scope.containsKey('android_mapping_id')) {
        final id = scope['android_mapping_id'];
        if (id is String && canonicalUuid.hasMatch(id)) {
          images.add(DebugImage.fromJson({'type': 'proguard', 'debug_id': id}));
        }
      }
      if (dartImage != null) images.add(_fallbackImage(fallbackImage));
      if (kind == 'java_crash') {
        if (report.containsKey('exception')) {
          Map<String, Object?>? exception = _map(report['exception']);
          final seen = <Map<String, Object?>>{};
          while (exception != null && values.length < 10) {
            if (!seen.add(exception)) break;
            value(
                _string(exception['class'], 512),
                exception['message'] == null
                    ? ''
                    : _string(exception['message'], 16384, empty: true),
                _javaFrames(exception['frames']),
                'android_uncaught');
            exception = exception.containsKey('cause')
                ? _map(exception['cause'])
                : null;
          }
        } else {
          value('JavaCrash', exit?['description'] as String? ?? '', [],
              'android_uncaught');
        }
      } else if (kind == 'anr') {
        final threads = report.containsKey('threads')
            ? _list(report['threads']).map(_map)
            : <Map<String, Object?>>[];
        final main = threads.where((thread) => thread['name'] == 'main');
        final description = exit?['description'] as String?;
        value(
            'ANR',
            'App not responding${description == null || description.isEmpty ? '' : ': $description'}',
            main.isEmpty ? [] : _javaFrames(main.first['frames']),
            'anr');
      } else {
        final type = const {
              'LOW_MEMORY': 'LowMemoryKill',
              'EXCESSIVE_RESOURCE_USAGE': 'ExcessiveResourceUsage',
              'INITIALIZATION_FAILURE': 'InitializationFailure'
            }[exit?['reason']] ??
            'AppExit';
        value(type, exit?['description'] as String? ?? '', [], 'app_exit');
      }
    }
    if (images.isEmpty) images.add(_fallbackImage(fallbackImage));
    if (values.isEmpty) throw const FormatException();
    final tags = <String, String>{};
    final sourceTags = _optional(() => _map(scope['tags']));
    for (final entry in sourceTags?.entries ?? <MapEntry<String, Object?>>[]) {
      if (tags.length == 99) break;
      if (entry.key == 'wasmwatch.native_report') continue;
      final tag = _optional(() => MapEntry(
          _string(entry.key, 200), _string(entry.value, 1024, empty: true)));
      if (tag != null) tags[tag.key] = tag.value;
    }
    tags['wasmwatch.native_report'] = kind as String;
    final breadcrumbs = <Breadcrumb>[];
    final sourceCrumbs = _optional(() => _list(scope['breadcrumbs'])) ?? [];
    for (final item
        in sourceCrumbs.skip((sourceCrumbs.length - 50).clamp(0, 1 << 30))) {
      final breadcrumb = _optional(() {
        final crumb = _map(item);
        final time = DateTime.parse(crumb['timestamp'] as String).toUtc();
        if (time.year < 0 || time.year > 9999) throw const FormatException();
        final level = crumb['level'] == null
            ? SeverityLevel.info
            : SeverityLevel.values.byName(crumb['level'] as String);
        final data = crumb.containsKey('data')
            ? _map(crumb['data'])
            : <String, Object?>{};
        final keptData =
            Map<String, Object?>.fromEntries(data.entries.take(50));
        jsonEncode(keptData);
        return Breadcrumb(
            category: _string(crumb['category'], 256),
            message: crumb['message'] == null
                ? null
                : _string(crumb['message'], 4096, empty: true),
            level: level,
            data: keptData,
            timestamp: time);
      });
      if (breadcrumb != null) breadcrumbs.add(breadcrumb);
    }
    final user = _optional(() {
      final source = _map(scope['user']);
      if (source.isEmpty ||
          source.keys
              .any((key) => !['id', 'username', 'email_hash'].contains(key)))
        throw const FormatException();
      final hash = source['email_hash'];
      if (source.containsKey('email_hash') &&
          (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)))
        throw const FormatException();
      return WasmWatchUser(
          id: source.containsKey('id')
              ? _string(source['id'], 256, empty: true)
              : null,
          username: source.containsKey('username')
              ? _string(source['username'], 256, empty: true)
              : null,
          emailHash: hash as String?);
    });
    final sessionId = _optional(() => _string(scope['session_id'], 256));
    final contexts = <String, Object?>{
      if (sessionId != null) 'session': {'id': sessionId},
      if (deviceContext != null)
        'device': Map.fromEntries(deviceContext.entries
            .where((entry) => _scalar(entry.value))
            .take(50)),
      if (exit != null) 'app_exit': exit,
      if (ios && iosMetadata.isNotEmpty) kind: _iosContext(iosMetadata),
    };
    // The mechanism contract permits only type/handled. Keep signal evidence in
    // app_exit without overwriting any OS exit fields.
    final signal = _optional(() => _signal(report['signal']));
    if (kind == 'native_crash' && signal != null) {
      contexts['app_exit'] = {
        ...?exit,
        'signal_number': signal['number'],
        'signal_code': signal['code'],
        'signal_name': _string(signal['name'], 512),
        if (signal.containsKey('code_name'))
          'signal_code_name': _string(signal['code_name'], 512, empty: true),
        if (signal.containsKey('fault_address'))
          'fault_address': _address(signal['fault_address']),
      };
    }
    final first = values.first;
    return ErrorEvent(
        eventId: uuidV7(timestamp),
        timestamp: timestamp,
        platform: platform,
        release: release,
        environment: environment,
        exceptionType: first.type,
        exceptionValue: first.value,
        frames: first.frames,
        mechanism: first.mechanism,
        exceptionValues: values,
        debugMeta: DebugMeta(images: images),
        breadcrumbs: breadcrumbs,
        user: user,
        tags: tags,
        contexts: contexts);
  } catch (_) {
    // Unexpected conversion failures are bugs, but must not erase a real crash.
    final timestamp =
        _optional(() => _timestamp(report[timeKey])) ?? now.toUtc();
    return ErrorEvent(
        eventId: uuidV7(timestamp),
        timestamp: timestamp,
        platform: platform,
        release: _optional(() => _string(report['release'], 256)),
        environment: _optional(() => _string(report['environment'], 128)),
        exceptionType: types[kind]!,
        exceptionValue: '',
        frames: [],
        mechanism: {
          'type': ios
              ? (kind == 'ios_hang' ? 'app_hang' : 'ios_metrickit')
              : 'android_native_report',
          'handled': false
        },
        debugMeta: DebugMeta(images: [_fallbackImage(fallbackImage)]),
        tags: {'wasmwatch.native_report': kind as String});
  }
}

/// Synthetic MXAppExitMetric shape until spike N6 supplies a device fixture.
/// Unknown counters and malformed values are ignored; zero counts never travel.
Map<String, Object?>? appExitsFromNativeReport(Map<String, Object?> report) {
  final diagnostic = _optional(() => _map(report['diagnostic'])) ?? {};
  final exits = <Map<String, Object?>>[];
  final counter = RegExp(r'^cumulative([A-Z][A-Za-z0-9]*)ExitCount$');
  for (final state in ['foreground', 'background']) {
    final data = _optional(() => _map(diagnostic['${state}ExitData'])) ?? {};
    for (final entry in data.entries) {
      final match = counter.firstMatch(entry.key);
      if (match == null) continue;
      final value = entry.value;
      final number = value is num
          ? value
          : value is String
              ? num.tryParse(value)
              : null;
      if (number == null ||
          !number.isFinite ||
          number < 0 ||
          number != number.truncateToDouble() ||
          number == 0) continue;
      final reason = match
          .group(1)!
          .replaceAllMapped(
              RegExp(r'([A-Z]+)([A-Z][a-z])'), (m) => '${m[1]}_${m[2]}')
          .replaceAllMapped(
              RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
          .toLowerCase();
      exits.add({'state': state, 'reason': reason, 'count': number.toInt()});
    }
  }
  if (exits.isEmpty) return null;
  Object? time(String key) =>
      _optional(() => _timestamp(report[key]).toIso8601String()) ?? report[key];
  // Preserve invalid identity/time evidence for a permanent server rejection.
  return {
    'id': report['id'],
    'release': report['release'],
    if (report.containsKey('environment')) 'environment': report['environment'],
    'platform': 'dart-ios',
    if (report.containsKey('install_id')) 'install_id': report['install_id'],
    'payload_begin': time('payload_begin'),
    'payload_end': time('payload_end'),
    'exits': exits,
  };
}

const _iosSignals = {
  6: 'SIGABRT',
  11: 'SIGSEGV',
  10: 'SIGBUS',
  4: 'SIGILL',
  8: 'SIGFPE',
  5: 'SIGTRAP',
  9: 'SIGKILL',
};
const _machExceptions = {
  1: 'EXC_BAD_ACCESS',
  2: 'EXC_BAD_INSTRUCTION',
  3: 'EXC_ARITHMETIC',
  5: 'EXC_SOFTWARE',
  6: 'EXC_BREAKPOINT',
  10: 'EXC_CRASH',
  11: 'EXC_RESOURCE',
  12: 'EXC_GUARD',
};

// MetricKit roots are the innermost calls in the real device fixtures. Walk
// root-first, depth-first; reversing would put dyld before the abort/fatalError.
List<RawStackFrame> _iosFrames(Map<String, Object?> diagnostic,
    Map<String, Object?> report, List<DebugImage> images) {
  final tree = _optional(() => _map(diagnostic['callStackTree']));
  final stacks = _optional(() => _list(tree?['callStacks'])) ?? [];
  Map<String, Object?>? attributed;
  for (final stack in stacks) {
    final candidate = _optional(() => _map(stack));
    if (candidate?['threadAttributed'] == true) {
      attributed = candidate;
      break;
    }
  }
  final roots =
      _optional(() => _list(attributed?['callStackRootFrames'])) ?? [];
  final binaries = _optional(() => _map(report['app_binaries'])) ?? {};
  final indices = <String, int>{};
  final bases = <String, BigInt>{};
  final frames = <RawStackFrame>[];
  final pending = <Object?>[...roots.reversed];
  var visited = 0;
  while (pending.isNotEmpty && frames.length < 200 && visited++ < 4096) {
    final source = _optional(() => _map(pending.removeLast()));
    if (source == null) continue;
    final children = _optional(() => _list(source['subFrames'])) ?? [];
    pending.addAll(children.reversed);
    final address = _optional(() => _iosInteger(source['address']));
    if (address == null) continue;
    final code = _optional(() {
      final raw = _string(source['binaryUUID'], 36).toLowerCase();
      if (!canonicalUuid.hasMatch(raw)) throw const FormatException();
      return raw.replaceAll('-', '');
    });
    int? index;
    if (code != null) {
      final offset =
          _optional(() => _iosInteger(source['offsetIntoBinaryTextSegment']));
      final base =
          offset != null && address >= offset ? address - offset : null;
      if (indices.containsKey(code)) {
        // Contradictory load addresses cannot support image attribution.
        if (base == bases[code]) index = indices[code];
      } else if (base != null && images.length < 64) {
        final name = _optional(() => _string(source['binaryName'], 1024));
        final path = _optional(() => _string(binaries[name], 1024));
        if (name != null) {
          index = images.length;
          indices[code] = index;
          bases[code] = base;
          images.add(DebugImage.fromJson({
            'type': 'native',
            'format': 'macho',
            'code_id': code,
            'debug_id': nativeDebugId(code, 'macho'),
            'code_file': path ?? name,
            'image_addr': '0x${base.toRadixString(16)}',
          }));
        }
      }
    }
    frames.add(RawStackFrame.android({
      'type': 'native',
      'instruction_addr': '0x${address.toRadixString(16)}',
      if (index != null) 'image_index': index,
    }));
  }
  return frames;
}

BigInt _iosInteger(Object? input) {
  final BigInt value;
  if (input is int) {
    value = BigInt.from(input);
  } else if (input is String &&
      RegExp(r'^(?:0x[0-9a-fA-F]+|[0-9]+)$').hasMatch(input)) {
    value = BigInt.parse(input);
  } else {
    throw const FormatException();
  }
  if (value.isNegative || value > BigInt.parse('ffffffffffffffff', radix: 16)) {
    throw const FormatException();
  }
  return value;
}

Map<String, Object?> _iosContext(Map<String, Object?> metadata) {
  final context = <String, Object?>{};
  const fields = {
    'exceptionType': 'exception_type',
    'exceptionCode': 'exception_code',
    'signal': 'signal_number',
    'terminationReason': 'termination_reason',
    'osVersion': 'os_version',
    'deviceType': 'device_type',
    'platformArchitecture': 'platform_architecture',
    'pid': 'pid',
    'appVersion': 'app_version',
    'appBuildVersion': 'app_build_version',
    'bundleIdentifier': 'bundle_identifier',
  };
  for (final entry in fields.entries) {
    final value = metadata[entry.key];
    if (value is int || (value is String && value.runes.length <= 16384)) {
      context[entry.value] = value;
    }
  }
  final exception = _machExceptions[metadata['exceptionType']];
  final signal = _iosSignals[metadata['signal']];
  if (exception != null) context['exception_name'] = exception;
  if (signal != null) context['signal_name'] = signal;
  return context;
}

T? _optional<T>(T Function() read) {
  try {
    return read();
  } catch (_) {
    return null;
  }
}

bool _scalar(Object? value) =>
    value == null ||
    value is String ||
    value is bool ||
    (value is num && value.isFinite);

DebugImage _fallbackImage(Map<String, Object?>? dartImage) =>
    _optional(() => _dartImage(dartImage!)) ??
    DebugImage.fromJson({
      'type': 'elf',
      'debug_id': '00000000-0000-7000-8000-000000000000',
      'code_file': 'libapp.so',
      'os': 'android'
    });

Map<String, Object?> _signal(Object? input) {
  final signal = _map(input);
  _string(signal['name'], 512);
  if (signal['number'] is! int || signal['code'] is! int)
    throw const FormatException();
  if (signal.containsKey('code_name'))
    _string(signal['code_name'], 512, empty: true);
  if (signal.containsKey('fault_address')) _address(signal['fault_address']);
  return signal;
}

List<RawStackFrame> _javaFrames(Object? input) =>
    _list(input).take(200).map((item) {
      final frame = _map(item);
      final line = frame['lineno'];
      if (frame.containsKey('lineno') &&
          (line is! int || line < 0 || line > 0xffffffff))
        throw const FormatException();
      return RawStackFrame.android({
        'type': 'java',
        'module': _string(frame['module'], 512),
        'function': _string(frame['function'], 256),
        if (frame.containsKey('filename'))
          'filename': _string(frame['filename'], 256, empty: true),
        if (line != null) 'lineno': line,
        'in_app': false
      });
    }).toList();

DebugImage _dartImage(Map<String, Object?> image) {
  if (image['type'] != 'elf' ||
      image.keys.any((key) => ![
            'type',
            'debug_id',
            'code_file',
            'build_id',
            'os',
            'arch',
            'release',
            'isolate_dso_base',
            'vm_dso_base'
          ].contains(key))) throw const FormatException();
  _string(image['code_file'], 1024);
  final build = image['build_id'];
  if (build != null &&
      (build is! String || !RegExp(r'^[0-9a-f]{8,64}$').hasMatch(build)))
    throw const FormatException();
  if (image['debug_id'] !=
      (build == null
          ? '00000000-0000-7000-8000-000000000000'
          : dartAotDebugId(build as String))) throw const FormatException();
  if (image.containsKey('os') && !['ios', 'android'].contains(image['os']))
    throw const FormatException();
  if (image.containsKey('arch') &&
      !['arm64', 'arm', 'x64', 'ia32', 'riscv64'].contains(image['arch']))
    throw const FormatException();
  if (image.containsKey('release')) _string(image['release'], 256);
  for (final key in ['isolate_dso_base', 'vm_dso_base']) {
    if (image.containsKey(key) &&
        (image[key] is! String ||
            !RegExp(r'^[0-9a-f]{1,16}$').hasMatch(image[key] as String)))
      throw const FormatException();
  }
  return DebugImage.fromJson(image);
}

void _validateExit(Map<String, Object?> exit) {
  const keys = {
    'reason',
    'description',
    'status',
    'importance',
    'pss_kb',
    'rss_kb',
    'timestamp_ms',
    'process_name'
  };
  if (exit.length != keys.length || !exit.keys.every(keys.contains))
    throw const FormatException();
  if (![
    'CRASH',
    'CRASH_NATIVE',
    'ANR',
    'LOW_MEMORY',
    'EXCESSIVE_RESOURCE_USAGE',
    'INITIALIZATION_FAILURE'
  ].contains(exit['reason'])) throw const FormatException();
  _timestamp(exit['timestamp_ms']);
  for (final key in ['status', 'importance', 'pss_kb', 'rss_kb']) {
    if (exit[key] is! int) throw const FormatException();
  }
  for (final key in ['description', 'process_name']) {
    if (exit[key] != null && exit[key] is! String)
      throw const FormatException();
  }
}

DateTime _timestamp(Object? input) {
  if (input is! int || input < 0 || input > 0xffffffffffff)
    throw const FormatException();
  final time = DateTime.fromMillisecondsSinceEpoch(input, isUtc: true);
  if (time.year > 9999) throw const FormatException();
  return time;
}

Map<String, Object?> _map(Object? input) => input is Map<String, Object?>
    ? input
    : Map<String, Object?>.from(input as Map);
List<Object?> _list(Object? input) => input as List<Object?>;
String _string(Object? input, int maximum, {bool empty = false}) {
  if (input is! String ||
      (!empty && input.isEmpty) ||
      input.runes.length > maximum) throw const FormatException();
  return input;
}

String _address(Object? input) {
  if (input is! String || !_hex.hasMatch(input)) throw const FormatException();
  return input;
}
