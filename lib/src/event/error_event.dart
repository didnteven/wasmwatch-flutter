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
  });

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
        'values': [
          {
            'type': clean(exceptionType),
            if (mechanism != null) 'mechanism': mechanism,
            'value': clean(exceptionValue),
            'stacktrace': {
              'frames': frames.map((frame) => clean(frame.toJson())).toList()
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

class DebugMeta {
  const DebugMeta({this.images = const []});
  final List<DebugImage> images;
  Map<String, Object?> toJson() =>
      {'images': images.map((image) => image.toJson()).toList()};
}

class DebugImage {
  const DebugImage({
    required this.debugId,
    required this.codeFile,
    required this.offsetKind,
    this.release,
    this.debugFile,
  });
  final String debugId;
  final String codeFile;
  final WasmOffsetKind offsetKind;
  final String? release;
  final String? debugFile;
  Map<String, Object?> toJson() => {
        'type': 'wasm',
        'debug_id': debugId,
        'code_file': codeFile,
        'offset_kind': offsetKind.wire,
        if (release != null) 'release': release,
        if (debugFile != null) 'debug_file': debugFile,
      };
}
