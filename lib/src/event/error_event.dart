import 'package:flutter/foundation.dart' show kIsWasm;
import '../utils/pii_scrubber.dart';
import '../wasm/stack_frame_parser.dart';
import 'breadcrumb.dart';
import 'user.dart';

class ErrorEvent {
  ErrorEvent({
    required this.eventId,
    required this.timestamp,
    required this.exceptionType,
    required this.exceptionValue,
    required this.frames,
    required this.debugMeta,
    this.platform = 'dart',
    this.release,
    this.environment,
    this.breadcrumbs = const [],
    this.contexts = const {},
    this.tags = const {},
    this.extra = const {},
    this.user,
    this.level = SeverityLevel.error,
    this.fingerprint,
    this.mechanism,
    this.exceptionValues,
  });

  final List<ExceptionValue>? exceptionValues;
  final String eventId;
  final DateTime timestamp;
  final String platform;
  final String? release;
  final String? environment;
  final String exceptionType;
  final String exceptionValue;
  final List<RawStackFrame> frames;
  final DebugMeta debugMeta;
  final List<Breadcrumb> breadcrumbs;
  final Map<String, Object?> contexts;
  final Map<String, String> tags;
  final Map<String, Object?> extra;
  final WasmWatchUser? user;
  final SeverityLevel level;
  final String? fingerprint;
  final Map<String, Object?>? mechanism;

  Map<String, Object?> toJson({bool scrubPii = true}) {
    Object? clean(Object? value) => scrubPii ? PiiScrubber.scrub(value) : value;
    final extensions = <String, Object?>{
      if (extra.isNotEmpty) 'extra': clean(extra),
      if (fingerprint != null) 'fingerprint_hint': fingerprint,
    };
    return <String, Object?>{
      'event_id': eventId,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'platform': platform,
      if (release != null) 'release': release,
      if (environment != null) 'environment': environment,
      'exception': {
        'values': exceptionValues != null
            ? exceptionValues!.map((value) => clean(value.toJson())).toList()
            : [
                {
                  'type': clean(exceptionType),
                  if (mechanism != null) 'mechanism': mechanism,
                  'value': clean(exceptionValue),
                  'stacktrace': {
                    'frames':
                        frames.map((frame) => clean(frame.toJson())).toList()
                  },
                },
              ],
      },
      'debug_meta': debugMeta
          .toJson(), // identifiers, not user data: the card regex mangles all-digit UUIDs
      if (breadcrumbs.isNotEmpty)
        'breadcrumbs': {
          'values': breadcrumbs.map((crumb) => clean(crumb.toJson())).toList()
        },
      if (user != null) 'user': clean(user!.toJson()),
      if (contexts.isNotEmpty) 'contexts': clean(contexts),
      if (tags.isNotEmpty) 'tags': clean(tags),
      if (extensions.isNotEmpty) 'extensions': extensions,
    };
  }
}

/// One throwable, in capture order (outer throwable followed by its causes).
class ExceptionValue {
  const ExceptionValue(
      {required this.type,
      required this.value,
      required this.frames,
      required this.mechanism});
  final String type;
  final String value;
  final List<RawStackFrame> frames;
  final Map<String, Object?> mechanism;
  Map<String, Object?> toJson() => {
        'type': type,
        'value': value,
        'mechanism': mechanism,
        'stacktrace': {
          'frames': frames.map((frame) => frame.toJson()).toList()
        },
      };
}

class DebugMeta {
  const DebugMeta({this.images = const []});
  final List<DebugImage> images;
  Map<String, Object?> toJson() =>
      {'images': images.map((image) => image.toJson()).toList()};
}

class DebugImage {
  /// A validated native/proguard image, or an existing serialized Dart image.
  DebugImage.fromJson(Map<String, Object?> json)
      : debugId = json['debug_id'] as String,
        codeFile = json['code_file'] as String? ?? '',
        type = json['type'] as String,
        offsetKind = WasmOffsetKind.unknown,
        buildId = json['build_id'] as String?,
        os = json['os'] as String?,
        arch = json['arch'] as String?,
        isolateDsoBase = json['isolate_dso_base'] as String?,
        vmDsoBase = json['vm_dso_base'] as String?,
        release = json['release'] as String?,
        debugFile = json['debug_file'] as String?,
        _json = Map.unmodifiable(json);
  final Map<String, Object?>? _json;
  const DebugImage({
    required this.debugId,
    required this.codeFile,
    this.offsetKind = WasmOffsetKind.unknown,
    this.type = kIsWasm ? 'wasm' : 'js',
    this.buildId,
    this.os,
    this.arch,
    this.isolateDsoBase,
    this.vmDsoBase,
    this.release,
    this.debugFile,
  }) : _json = null;
  final String debugId;
  final String codeFile;
  final String type;
  final String? buildId;
  final String? os;
  final String? arch;
  final String? isolateDsoBase;
  final String? vmDsoBase;
  final WasmOffsetKind offsetKind;
  final String? release;
  final String? debugFile;
  Map<String, Object?> toJson() =>
      _json ??
      {
        'type': type,
        'debug_id': debugId,
        'code_file': type == 'js' ? 'main.dart.js' : codeFile,
        if (type != 'elf') 'offset_kind': offsetKind.wire,
        if (buildId != null) 'build_id': buildId,
        if (os != null) 'os': os,
        if (arch != null) 'arch': arch,
        if (isolateDsoBase != null) 'isolate_dso_base': isolateDsoBase,
        if (vmDsoBase != null) 'vm_dso_base': vmDsoBase,
        if (release != null) 'release': release,
        if (debugFile != null) 'debug_file': debugFile,
      };
}
