import 'dart:async';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../client.dart';
import '../event/breadcrumb.dart';

/// Chains framework and dispatcher handlers. Capture is intentionally detached:
/// Flutter's synchronous error contract must retain the previous handler's
/// observable behavior.
class FlutterErrorIntegration {
  /// Zone value used to attach private attribution to a single synchronous
  /// framework or platform capture. Values never enter the shared Scope.
  static final Object eventMetadataZoneKey = Object();

  /// Suppress console breadcrumbs for Flutter's verbose diagnostic report,
  /// including deferred prints scheduled by the previous handler.
  static final Object suppressPrintZoneKey = Object();
  static final Expando<Map<String, Object?>> _attachedMetadata =
      Expando<Map<String, Object?>>('WasmWatch Flutter event metadata');

  /// Attaches metadata to the error currently being forwarded through a
  /// handler chain. This supports handlers installed outside the SDK's normal
  /// installation order without mutating the shared scope.
  static void attachEventMetadata(Object error, Map<String, Object?> metadata) {
    _attachedMetadata[error] = metadata;
  }

  static Map<String, Object?>? _takeAttachedMetadata(Object error) {
    final metadata = _attachedMetadata[error];
    _attachedMetadata[error] = null;
    return metadata;
  }

  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;
  bool _installed = false;
  FlutterExceptionHandler? _flutterHandler;
  ErrorCallback? _platformHandler;
  Map<String, Object?> Function(FlutterErrorDetails)? _frameworkMetadata;
  Map<String, Object?> Function(Object)? _platformMetadata;

  /// Replaces this integration's downstream framework handler. This supports
  /// owners that remove a handler installed before the integration.
  void replacePreviousFlutterHandler(FlutterExceptionHandler? handler) {
    _previousFlutter = handler;
  }

  /// Replaces this integration's downstream dispatcher handler.
  void replacePreviousPlatformHandler(ErrorCallback? handler) {
    _previousPlatform = handler;
  }

  void setAttributionResolvers({
    Map<String, Object?> Function(FlutterErrorDetails)? framework,
    Map<String, Object?> Function(Object)? platform,
  }) {
    _frameworkMetadata = framework;
    _platformMetadata = platform;
  }

  void install(WasmWatchClient client) {
    if (_installed) return;
    _installed = true;
    _previousFlutter = FlutterError.onError;
    _previousPlatform = PlatformDispatcher.instance.onError;
    _flutterHandler = (details) {
      // Overflow diagnostics arrive as AssertionError(FlutterError(...)) in
      // debug builds. Preserve Flutter's real diagnostic object and stack so
      // the event remains both authentic and understandable.
      final exception = details.exception;
      final captured =
          exception is AssertionError && exception.message is FlutterError
              ? exception.message as FlutterError
              : exception;
      final provenance = _widgetProvenance(details);
      Object? metadata;
      Object? downstreamError;
      StackTrace? downstreamStack;
      final previousDebugPrint = debugPrint;
      try {
        debugPrint = (message, {wrapWidth}) => runZoned(
            () => debugPrintSynchronously(message, wrapWidth: wrapWidth),
            zoneValues: {suppressPrintZoneKey: true});
        runZoned(() => _previousFlutter?.call(details),
            zoneValues: {suppressPrintZoneKey: true});
      } catch (error, stack) {
        downstreamError = error;
        downstreamStack = stack;
      } finally {
        debugPrint = previousDebugPrint;
        metadata = _frameworkMetadata?.call(details);
        if (metadata is! Map || metadata.isEmpty) {
          metadata = _takeAttachedMetadata(details.exception) ??
              Zone.current[eventMetadataZoneKey];
        } else {
          _takeAttachedMetadata(details.exception);
        }
      }
      final eventMetadata = metadata is Map
          ? Map<String, Object?>.from(metadata)
          : const <String, Object?>{};
      String firstLine;
      try {
        firstLine = captured.toString().split(RegExp(r'[\r\n]')).first;
      } catch (_) {
        firstLine = '';
      }
      final message = '${captured.runtimeType}: $firstLine';
      client.hub?.scope.addBreadcrumb(
        Breadcrumb(
          category: 'flutter.error',
          level: SeverityLevel.error,
          message: message.length > 200 ? message.substring(0, 200) : message,
        ),
        maximum: client.options.maxBreadcrumbs,
      );
      client.captureException(
        captured,
        stackTrace: details.stack,
        captureStackWhenMissing: details.stack == null,
        contexts: {
          if (provenance.isNotEmpty) 'flutter_layout': provenance,
          if (eventMetadata['context'] is Map)
            'scenario':
                Map<String, Object?>.from(eventMetadata['context'] as Map),
        },
        tags: {
          if (provenance['source'] is Map)
            'wasmwatch.widget_origin': jsonEncode(provenance['source']),
          if (eventMetadata['tags'] is Map)
            ...Map<String, String>.from(eventMetadata['tags'] as Map),
        },
        captureZone: Zone.current,
      );
      if (downstreamError != null) {
        Error.throwWithStackTrace(downstreamError, downstreamStack!);
      }
    };
    FlutterError.onError = _flutterHandler;
    _platformHandler = (error, stackTrace) {
      bool? previousHandled;
      try {
        previousHandled = _previousPlatform?.call(error, stackTrace);
      } finally {
        Object? metadata = _platformMetadata?.call(error);
        if (metadata is! Map || metadata.isEmpty) {
          metadata = _takeAttachedMetadata(error) ??
              Zone.current[eventMetadataZoneKey];
        } else {
          _takeAttachedMetadata(error);
        }
        final eventMetadata = metadata is Map
            ? Map<String, Object?>.from(metadata)
            : const <String, Object?>{};
        client.captureException(
          error,
          stackTrace: stackTrace,
          contexts: {
            if (eventMetadata['context'] is Map)
              'scenario':
                  Map<String, Object?>.from(eventMetadata['context'] as Map),
          },
          tags: eventMetadata['tags'] is Map
              ? Map<String, String>.from(eventMetadata['tags'] as Map)
              : const {},
          captureZone: Zone.current,
        );
      }
      // A pre-existing handler retains its decision; with none installed, the
      // SDK has captured the error and explicitly handles it.
      return _previousPlatform == null ? true : previousHandled ?? false;
    };
    PlatformDispatcher.instance.onError = _platformHandler;
  }

  void close() {
    if (!_installed) return;
    if (identical(FlutterError.onError, _flutterHandler)) {
      FlutterError.onError = _previousFlutter;
    }
    if (identical(PlatformDispatcher.instance.onError, _platformHandler)) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
    _installed = false;
  }
}

/// Flutter's public inspector serialization exposes compiler creation locations.
/// These describe widget construction, never an exception's runtime stack.
Map<String, Object?> _widgetProvenance(FlutterErrorDetails details) {
  final result = <String, Object?>{
    if (details.library != null) 'library': details.library,
  };
  try {
    if (details.context != null) {
      result['context'] = details.context!.toDescription();
    }
    final nodes =
        details.informationCollector?.call() ?? const <DiagnosticsNode>[];
    for (final node in nodes.take(50)) {
      final creator = node.value;
      if (creator is! DebugCreator) continue;
      final elements = <Element>[creator.element];
      creator.element.visitAncestorElements((element) {
        elements.add(element);
        return elements.length < 20;
      });
      result['widget'] = creator.element.widget.runtimeType.toString();
      result['creation_chain'] = elements
          .map((element) => element.widget.runtimeType.toString())
          .toList();
      // The nearest build element owns this render subtree. Its identity is
      // structural diagnostic evidence, not a sampled build invocation.
      final owners =
          elements.where((e) => e is StatelessElement || e is StatefulElement);
      final owner = owners.isEmpty ? null : owners.first;
      for (final element in elements) {
        if (identical(element, owner)) break;
        final serialized = element.widget.toDiagnosticsNode().toJsonMap(
              InspectorSerializationDelegate(
                service: WidgetInspectorService.instance,
                subtreeDepth: 0,
                expandPropertyValues: false,
              ),
            );
        final location = serialized['creationLocation'];
        if (serialized['createdByLocalProject'] != true || location is! Map)
          continue;
        final file = location['file'];
        final line = location['line'];
        final column = location['column'];
        if (file is! String || file.length > 600 || line is! int || line <= 0)
          continue;
        final source = <String, Object?>{
          'kind': 'widget_creation',
          'widget': element.widget.runtimeType.toString(),
          'source_file': file,
          'line': line,
          if (column is int && column > 0) 'column': column,
          if (owner != null)
            'build_owner':
                (owner is StatefulElement ? owner.state : owner.widget)
                    .runtimeType
                    .toString(),
        };
        // Tags are the existing durable dashboard transport; keep within the
        // event contract's per-tag limit, while contexts retain the chain.
        if (jsonEncode(source).length <= 1024) result['source'] = source;
        break;
      }
      break;
    }
  } catch (_) {
    // A collector or inspector failure must never disrupt handler chaining.
    result['collector_failed'] = true;
  }
  return result;
}
