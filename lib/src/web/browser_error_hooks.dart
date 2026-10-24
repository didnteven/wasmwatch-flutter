import 'dart:js_interop';
import 'package:web/web.dart' as web;
import '../client.dart';
import 'package:flutter/foundation.dart';
import '../grouping/normalize.dart';
import '../wasm/stack_frame_parser.dart';
import 'wasm_exception_stub.dart'
    if (dart.library.js_interop) 'wasm_exception.dart';

@JS('Error')
extension type _JSError(JSObject _) implements JSObject {
  external JSString get name;
  external JSString get message;
  external JSString? get stack;
}

@JS('String')
external JSString _stringify(JSAny? value);

/// Captures errors escaping Flutter's framework and zone handlers without
/// cancelling browser events or changing the browser's console output.
class BrowserErrorHooks {
  JSFunction? _errorListener;
  JSFunction? _rejectionListener;
  WasmWatchClient? _client;
  bool _handling = false;
  static bool _warnedMissingHelper = false;

  void install(WasmWatchClient client) {
    if (_client != null) return;
    _client = client;
    if (client.options.captureBrowserErrors) {
      _errorListener = ((web.Event event) {
        if (!event.isA<web.ErrorEvent>()) return;
        _guard(() {
          final error = event as web.ErrorEvent;
          final filename = error.filename;
          if (client.options.ignoreCrossOriginScriptErrors &&
              (filename.startsWith('chrome-extension://') ||
                  filename.startsWith('moz-extension://') ||
                  (error.message == 'Script error.' && filename.isEmpty))) {
            return;
          }
          _capture(error.error, 'window.onerror',
              fallback: error.message,
              filename: filename,
              line: error.lineno,
              column: error.colno);
        });
      }).toJS;
      web.window.addEventListener('error', _errorListener);
    }
    if (client.options.captureUnhandledRejections) {
      _rejectionListener = ((web.Event event) {
        if (!event.isA<web.PromiseRejectionEvent>()) return;
        _guard(() => _capture(
            (event as web.PromiseRejectionEvent).reason, 'unhandledrejection'));
      }).toJS;
      web.window.addEventListener('unhandledrejection', _rejectionListener);
    }
  }

  void _guard(void Function() body) {
    if (_handling || _client == null || WasmWatchClient.isInternalCapture)
      return;
    _handling = true;
    try {
      body();
    } catch (_) {
      // Hostile getters/stringifiers and SDK failures must never escape this
      // listener and generate another window error.
    } finally {
      _handling = false;
    }
  }

  void _capture(JSAny? reason, String mechanism,
      {String? fallback, String? filename, int? line, int? column}) {
    final unwrapped = unwrapWasmException(reason);
    if (unwrapped != null) {
      final client = _client!;
      client.captureException(unwrapped.$1,
          stackTrace: unwrapped.$2,
          browserCapture: true,
          mechanism: {
            'type': mechanism,
            'handled': false
          },
          tags: {
            'wasmwatch.unwrapped': 'true'
          }).then<void>((_) {},
          onError: (Object error, StackTrace stack) =>
              client.suppressInternalError(error, stack));
      return;
    }
    final opaqueWasm = isWasmException(reason);
    if (opaqueWasm &&
        !hasWasmRethrowHelper &&
        kDebugMode &&
        !_warnedMissingHelper) {
      _warnedMissingHelper = true;
      debugPrint(
          'WasmWatch: missing __wasmwatchRethrow helper; run the uploader to inject it.');
    }
    var name = 'Error';
    var message = fallback ?? _safeString(reason);
    String? stack;
    if (reason != null && reason.isA<_JSError>()) {
      final error = reason as _JSError;
      name = error.name.toDart;
      message = error.message.toDart;
      stack = error.stack?.toDart;
    } else if (fallback != null) {
      final match =
          RegExp(r'^(?:Uncaught\s+)?(\w*Error):\s*(.*)$', dotAll: true)
              .firstMatch(fallback);
      if (match != null) {
        name = match.group(1)!;
        message = match.group(2)!;
      }
    }
    if (opaqueWasm) {
      name = 'WebAssembly.Exception';
      message = 'Dart exception escaped to JavaScript (not unwrapped)';
      stack = wasmExceptionStack(reason);
    }
    final overflow = name == 'RangeError' &&
        message.contains('Maximum call stack size exceeded');
    // Empty evidence is preferable to a stack pointing at this listener.
    stack ??= filename != null && filename.isNotEmpty
        ? '    at $filename:${line ?? 0}:${column ?? 0}'
        : '';
    final client = _client!;
    client
        .captureException(
      _BrowserException(name, message),
      stackTrace: StackTrace.fromString(stack),
      exceptionTypeOverride: name,
      exceptionValueOverride: message,
      extra: {
        if (opaqueWasm &&
            stack.isNotEmpty &&
            WasmStackFrameParser.parse(stack)
                .every((f) => f.type == StackFrameType.raw))
          'wasm_exception_stack': stack
      },
      browserCapture: true,
      trimRecursion: overflow,
      mechanism: {'type': mechanism, 'handled': false},
      tags: {
        if (opaqueWasm) 'wasmwatch.unwrapped': 'false',
        'mechanism.type': mechanism,
        'handled': 'false',
        if (overflow) 'wasm.trap': 'stack_overflow',
      },
      contexts: {
        if (opaqueWasm)
          'route': {'path': templatePath(web.window.location.pathname)},
        if (filename != null)
          'browser': {
            'filename': filename,
            'lineno': line,
            'colno': column,
          },
      },
    )
        .then<void>((_) {}, onError: (Object error, StackTrace stack) {
      client.suppressInternalError(error, stack);
    });
  }

  String _safeString(JSAny? reason) {
    try {
      return _stringify(reason).toDart;
    } catch (_) {
      return '[unserializable rejection reason]';
    }
  }

  void close() {
    if (_errorListener != null) {
      web.window.removeEventListener('error', _errorListener);
    }
    if (_rejectionListener != null) {
      web.window.removeEventListener('unhandledrejection', _rejectionListener);
    }
    _errorListener = null;
    _rejectionListener = null;
    _client = null;
  }
}

class _BrowserException implements Exception {
  _BrowserException(this.name, this.message);
  final String name;
  final String message;
  @override
  String toString() => '$name: $message';
}
