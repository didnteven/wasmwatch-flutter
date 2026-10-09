import 'dart:async';
import 'dart:math';
import 'event/envelope.dart';
import 'event/error_event.dart';
import 'hub.dart';
import 'options.dart';
import 'scope.dart';
import 'transport/http_transport.dart';
import 'transport/offline_buffer.dart';
import 'transport/rate_limiter.dart';
import 'utils/exception_type.dart';
import 'utils/fingerprinter.dart';
import 'wasm/debug_id.dart';
import 'wasm/stack_frame_parser.dart';
import 'web/capture_deduplicator.dart';

class WasmWatchClient {
  WasmWatchClient(WasmWatchOptions options,
      {HttpTransport? transport,
      OfflineBuffer? offlineBuffer,
      RateLimiter? rateLimiter})
      : options = options.resolved(),
        transport = transport ??
            HttpTransport(options.parsedDsn, maxRetries: options.maxRetries),
        offlineBuffer = offlineBuffer,
        rateLimiter = rateLimiter ?? RateLimiter();

  WasmWatchOptions options;
  final HttpTransport transport;
  final OfflineBuffer? offlineBuffer;
  final RateLimiter rateLimiter;
  final _deduplicator = CaptureDeduplicator();
  static final internalCaptureZoneKey = Object();
  static bool get isInternalCapture =>
      Zone.current[internalCaptureZoneKey] == true;

  void suppressInternalError(Object error, StackTrace stack) {
    final type = describeExceptionType(error);
    _deduplicator.record(error, describeExceptionValue(error, type),
        stack.toString(), DateTime.now(),
        suppressed: true);
  }

  Hub? hub;

  Future<String?> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? hint,
    Scope? scope,
    DebugMeta? debugMeta,
    bool captureStackWhenMissing = false,
    Map<String, Object?> contexts = const {},
    Map<String, String> tags = const {},
    Zone? captureZone,
    String? exceptionTypeOverride,
    String? exceptionValueOverride,
    Map<String, Object?>? mechanism,
    bool browserCapture = false,
    bool trimRecursion = false,
  }) async {
    final now = DateTime.now();
    final exceptionType = exceptionTypeOverride ?? describeExceptionType(error);
    final exceptionValue =
        exceptionValueOverride ?? describeExceptionValue(error, exceptionType);
    if (_deduplicator.record(error, exceptionValue, stackTrace?.toString(), now,
        browser: browserCapture)) return null;
    if (!rateLimiter.allow(now) || Random().nextDouble() > options.sampleRate)
      return null;
    // Flutter layout diagnostics do not always carry the stack that produced
    // them.  Retain the capture-time stack for operational evidence, but mark
    // it so a receiver never presents captureException as the throw site.
    final usedCaptureTimeStack = stackTrace == null && captureStackWhenMissing;
    var frames = WasmStackFrameParser.parse(
        (stackTrace ?? StackTrace.current).toString());
    if (trimRecursion) {
      final seen = <String>{};
      frames = frames
          .where((frame) => seen.add(frame.rawLine.trim()))
          .take(50)
          .toList();
    }
    frames = frames.take(200).toList();
    final activeScope = scope ?? hub?.scope ?? Scope();
    String? symbol;
    for (final frame in frames) {
      if (frame.type != StackFrameType.raw && frame.functionName != null) {
        symbol = frame.functionName;
        break;
      }
    }
    final event = ErrorEvent(
      eventId: _uuidV7(now),
      timestamp: now,
      platform: _platform(),
      release: options.release,
      environment: options.environment,
      exceptionType: exceptionType,
      mechanism: mechanism,
      exceptionValue: hint == null ? exceptionValue : '$hint: $exceptionValue',
      frames: frames,
      debugMeta: debugMeta ?? _defaultDebugMeta(),
      breadcrumbs:
          activeScope.breadcrumbs.take(options.maxBreadcrumbs).toList(),
      contexts: {...activeScope.contexts, ...contexts},
      tags: {
        ...activeScope.tags,
        ...tags,
        if (usedCaptureTimeStack) 'wasmwatch.stack_trace_origin': 'capture',
      },
      extra: activeScope.extra,
      user: activeScope.user,
      fingerprint: Fingerprinter.fingerprint(
          exceptionType: exceptionType, culpritSymbol: symbol),
    );
    return _runInternal(() async {
      final processed = options.beforeSend == null
          ? event
          : await (captureZone ?? Zone.current)
              .run(() => options.beforeSend!(event));
      if (processed == null) return null;
      final envelope =
          Envelope(event: processed, sdkVersion: '0.1.0').serialize();
      final sent = await transport.send(envelope);
      if (!sent && offlineBuffer != null) await offlineBuffer!.store(envelope);
      return processed.eventId;
    });
  }

  Future<void> flushOffline() => _runInternal(() async {
        final buffer = offlineBuffer;
        if (buffer == null) return;
        final claimed = await buffer.drain();
        for (var index = 0; index < claimed.length; index++) {
          if (!await transport.send(claimed[index])) {
            await buffer.requeue(claimed.sublist(index));
            return;
          }
        }
      });

  Future<T> _runInternal<T>(Future<T> Function() operation) {
    // Complete in the caller's error zone so a failed send remains observable
    // by explicit callers, while detached SDK errors cannot reach window hooks.
    final completion = Completer<T>();
    runZoned(
        () {
          Future<T>.sync(operation).then(completion.complete,
              onError: (Object error, StackTrace stack) {
            suppressInternalError(error, stack);
            completion.completeError(error, stack);
          });
        },
        zoneValues: {internalCaptureZoneKey: true},
        zoneSpecification: ZoneSpecification(
          handleUncaughtError: (self, parent, zone, error, stack) {
            suppressInternalError(error, stack);
          },
        ));
    return completion.future;
  }

  DebugMeta _defaultDebugMeta() {
    final id = extractWasmDebugId() ?? '00000000-0000-7000-8000-000000000000';
    return DebugMeta(images: [
      DebugImage(
          debugId: id,
          codeFile: isWasmRuntime ? 'main.dart.wasm' : 'main.dart.js',
          offsetKind: WasmOffsetKind.unknown,
          release: options.release)
    ]);
  }

  String _platform() => isWasmRuntime ? 'dart-wasm' : 'dart';

  static String _uuidV7(DateTime timestamp) {
    final random = Random.secure();
    final milliseconds = timestamp.millisecondsSinceEpoch;
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    for (var index = 5; index >= 0; index--) {
      bytes[index] = milliseconds >> ((5 - index) * 8) & 0xff;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}
