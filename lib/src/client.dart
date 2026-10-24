import 'dart:async';
import 'package:flutter/foundation.dart';
import 'version.dart';
import 'integrations/browser_context.dart';
import 'integrations/browser_context_source.dart' show browserContextAvailable;
import 'integrations/device_context.dart';
import 'dart:math';
import 'event/envelope.dart';
import 'event/error_event.dart';
import 'hub.dart';
import 'native/aot_identity.dart';
import 'native/dart_stack_parser.dart';
import 'options.dart';
import 'scope.dart';
import 'transport/http_transport.dart';
import 'transport/offline_buffer.dart';
import 'transport/rate_limiter.dart';
import 'utils/exception_type.dart';
import 'utils/consecutive_loop_guard.dart';
import 'utils/fingerprinter.dart';
import 'wasm/debug_id.dart';
import 'wasm/stack_frame_parser.dart';
import 'web/capture_deduplicator.dart';

class WasmWatchClient {
  WasmWatchClient(WasmWatchOptions options,
      {HttpTransport? transport,
      OfflineBuffer? offlineBuffer,
      RateLimiter? rateLimiter,
      DeviceContextIntegration? deviceContext,
      DateTime Function()? clock})
      : options = options.resolved(),
        transport = transport ??
            HttpTransport(options.parsedDsn, maxRetries: options.maxRetries),
        offlineBuffer = offlineBuffer,
        rateLimiter = rateLimiter ?? RateLimiter(),
        _clock = clock ?? DateTime.now {
    if (this.options.sendDefaultContext) {
      if (browserContextAvailable) {
        _browserContext = BrowserContextIntegration();
      } else {
        _deviceContext = deviceContext ?? DeviceContextIntegration();
      }
    }
  }

  BrowserContextIntegration? _browserContext;
  DeviceContextIntegration? _deviceContext;
  DartAotHeader? _aotHeader;

  /// Cache snapshot identity and load bases once at SDK initialization.
  void initializeMobileBuild({StackTrace? stackTrace}) {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) return;
    // Android's build_id is the ELF build ID, iOS's the App.framework Mach-O UUID (mobile spike Q2).
    _aotHeader = DartStackTraceParser.parseAotHeader(
        (stackTrace ?? StackTrace.current).toString());
  }

  WasmWatchOptions options;
  final HttpTransport transport;
  final OfflineBuffer? offlineBuffer;
  final RateLimiter rateLimiter;
  final DateTime Function() _clock;
  DateTime Function() get clock => _clock;
  final _loopGuard = ConsecutiveLoopGuard();
  bool _constructing = false;
  int captureAttempts = 0;
  int consecutiveDrops = 0;
  int sessionCapDrops = 0;
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
    Map<String, Object?> extra = const {},
    Map<String, String> tags = const {},
    Zone? captureZone,
    String? exceptionTypeOverride,
    String? exceptionValueOverride,
    Map<String, Object?>? mechanism,
    bool browserCapture = false,
    bool trimRecursion = false,
  }) async {
    if (isInternalCapture || _constructing) return null;
    _constructing = true;
    try {
      final now = _clock();
      final exceptionType =
          exceptionTypeOverride ?? describeExceptionType(error);
      final exceptionValue = exceptionValueOverride ??
          describeExceptionValue(error, exceptionType);
      if (!options.bypassProtection &&
          _loopGuard.record(
              exceptionType,
              exceptionValue,
              stackTrace?.toString(),
              tags['wasmwatch.widget_origin'] ??
                  contexts['flutter_layout']?.toString(),
              now)) {
        consecutiveDrops++;
        return null;
      }
      if (_deduplicator.record(
          error, exceptionValue, stackTrace?.toString(), now,
          browser: browserCapture)) return null;
      if (!options.bypassProtection) {
        if (captureAttempts >= options.maxEventsPerSession) {
          sessionCapDrops++;
          return null;
        }
        captureAttempts++;
        if (!rateLimiter.allow(now) ||
            Random().nextDouble() > options.sampleRate) return null;
      }
      // Flutter layout diagnostics do not always carry the stack that produced
      // them.  Retain the capture-time stack for operational evidence, but mark
      // it so a receiver never presents captureException as the throw site.
      final usedCaptureTimeStack =
          stackTrace == null && captureStackWhenMissing;
      final stack = (stackTrace ?? StackTrace.current).toString();
      final aotHeader = kIsWeb
          ? null
          : _aotHeader ?? DartStackTraceParser.parseAotHeader(stack);
      var frames = kIsWeb
          ? WasmStackFrameParser.parse(stack)
          : DartStackTraceParser.parse(stack, aotHeader: aotHeader);
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
      final defaults = _browserContext?.capture(activeScope.breadcrumbs) ??
          _deviceContext?.capture() ?? <String, Object?>{};
      final event = ErrorEvent(
        eventId: _uuidV7(now),
        timestamp: now,
        platform: _platform(),
        release: options.release,
        environment: options.environment,
        exceptionType: exceptionType,
        mechanism: mechanism,
        exceptionValue:
            hint == null ? exceptionValue : '$hint: $exceptionValue',
        frames: frames,
        debugMeta: debugMeta ?? _defaultDebugMeta(aotHeader: aotHeader),
        breadcrumbs:
            activeScope.breadcrumbs.take(options.maxBreadcrumbs).toList(),
        contexts: {...defaults, ...activeScope.contexts, ...contexts},
        tags: {
          for (final key in ['browser', 'os', 'device'])
            if ((contexts[key] ?? activeScope.contexts[key] ?? defaults[key]) case final Map value)
              if (value[key == 'device' ? 'type' : 'name'] case final String name)
                key == 'device' ? 'device.type' : key: name,
          ...activeScope.tags,
          ...tags,
          if (usedCaptureTimeStack) 'wasmwatch.stack_trace_origin': 'capture',
        },
        extra: {...activeScope.extra, ...extra},
        user: activeScope.user,
        fingerprint: Fingerprinter.fingerprint(
            exceptionType: exceptionType, culpritSymbol: symbol),
      );
      return _runInternal(() async {
        final processed = options.beforeSend == null
            ? event
            : await (captureZone ?? Zone.current).fork(zoneValues: {
                internalCaptureZoneKey: true
              }).run(() => options.beforeSend!(event));
        if (processed == null) return null;
        final envelope =
            Envelope(event: processed, sdkVersion: wasmwatchSdkVersion)
                .serialize();
        await flushOffline();
        final sent = await transport.send(envelope);
        if (!sent && transport.shouldBuffer(envelope) && offlineBuffer != null)
          await offlineBuffer!.store(envelope);
        return processed.eventId;
      });
    } finally {
      _constructing = false;
    }
  }

  Future<void> flushOffline() => _runInternal(() async {
        final buffer = offlineBuffer;
        if (buffer == null) return;
        final claimed = await buffer.drain();
        for (var index = 0; index < claimed.length; index++) {
          if (!await transport.send(claimed[index])) {
            if (!transport.shouldBuffer(claimed[index])) continue;
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

  DebugMeta _defaultDebugMeta({DartAotHeader? aotHeader}) {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      final ios = defaultTargetPlatform == TargetPlatform.iOS;
      final header = aotHeader ?? _aotHeader;
      final buildId = header?.buildId;
      return DebugMeta(images: [
        DebugImage(
            type: 'elf',
            debugId: buildId == null
                ? '00000000-0000-7000-8000-000000000000'
                : dartAotDebugId(buildId),
            buildId: buildId,
            codeFile: ios ? 'App.framework/App' : 'libapp.so',
            os: header?.os ?? (ios ? 'ios' : 'android'),
            arch: header?.arch,
            isolateDsoBase: header?.isolateDsoBase,
            vmDsoBase: header?.vmDsoBase,
            release: options.release)
      ]);
    }
    final id = extractWasmDebugId() ?? '00000000-0000-7000-8000-000000000000';
    return DebugMeta(images: [
      DebugImage(
          debugId: id,
          codeFile: isWasmRuntime ? 'main.dart.wasm' : 'main.dart.js',
          offsetKind: WasmOffsetKind.unknown,
          release: options.release)
    ]);
  }

  String _platform() {
    if (kIsWeb) return isWasmRuntime ? 'dart-wasm' : 'dart';
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'dart-ios',
      TargetPlatform.android => 'dart-android',
      _ => 'dart',
    };
  }

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
