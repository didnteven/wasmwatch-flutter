@TestOn('browser')
library;

import 'dart:js_interop';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;
import 'package:wasmwatch/wasmwatch.dart';
import 'package:wasmwatch/src/web/browser_error_hooks.dart';

@JS('Object.create')
external JSObject nullPrototypeObject(JSAny? prototype);

@JS('Error')
extension type NativeError._(JSObject _) implements JSObject {
  external factory NativeError(String message);
  external set stack(String value);
}

@JS('RangeError')
extension type NativeRangeError._(JSObject _) implements JSObject {
  external factory NativeRangeError(String message);
  external set stack(String value);
}

class FailingTransport extends HttpTransport {
  FailingTransport(WasmWatchOptions options, this.failure, this.failureStack)
      : super(options.parsedDsn);
  final Object failure;
  final StackTrace failureStack;
  int calls = 0;
  @override
  Future<bool> send(String envelope) async {
    calls++;
    Error.throwWithStackTrace(failure, failureStack);
  }
}

void main() {
  final events = <ErrorEvent>[];
  late WasmWatchClient client;
  late BrowserErrorHooks hooks;

  WasmWatchClient makeClient(
          {bool errors = true,
          bool rejections = true,
          bool ignore = true,
          BeforeSend? beforeSend}) =>
      WasmWatchClient(
        WasmWatchOptions(
            dsn: 'https://key@example.com/v1/project',
            captureBrowserErrors: errors,
            captureUnhandledRejections: rejections,
            ignoreCrossOriginScriptErrors: ignore,
            beforeSend: beforeSend ??
                (event) {
                  events.add(event);
                  return null;
                }),
      );

  web.ErrorEvent dispatchError(String message,
      {String filename = 'main.dart.js', JSAny? error}) {
    final event = web.ErrorEvent(
        'error',
        web.ErrorEventInit(
            message: message,
            filename: filename,
            lineno: 12,
            colno: 34,
            error: error,
            cancelable: true));
    web.window.dispatchEvent(event);
    return event;
  }

  void reject(JSAny? reason) {
    final promise = JSPromise<JSAny?>(((JSFunction resolve, JSFunction reject) {
      resolve.callAsFunction(null, null);
    }).toJS);
    final event = web.PromiseRejectionEvent(
        'unhandledrejection',
        web.PromiseRejectionEventInit(
            promise: promise, reason: reason, cancelable: true));
    web.window.dispatchEvent(event);
    expect(event.defaultPrevented, isFalse);
  }

  setUp(() {
    events.clear();
    client = makeClient();
    hooks = BrowserErrorHooks()..install(client);
  });
  tearDown(() async {
    hooks.close();
    client.transport.close();
    await WasmWatch.close();
  });

  test('fresh native errors share the production loop guard', () async {
    hooks.close();
    client.transport.close();
    client = WasmWatchClient(WasmWatchOptions(
        dsn: 'https://key@example.com/v1/project',
        protectionBypass: false,
        beforeSend: (event) {
          events.add(event);
          return null;
        }));
    hooks = BrowserErrorHooks()..install(client);
    for (var i = 0; i < 20; i++) {
      final error = NativeError('same loop')
        ..stack = 'Error: same loop\n at render (main.dart.js:12:34)';
      dispatchError('same loop', error: error);
    }
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
  });

  test('installs once, captures location and leaves default logging enabled',
      () {
    hooks.install(client);
    final event = dispatchError('boom');
    web.window.dispatchEvent(web.Event('error'));
    expect(event.defaultPrevented, isFalse);
    expect(events, hasLength(1));
    expect(events.single.exceptionValue, 'boom');
    expect(events.single.contexts['browser'],
        {'filename': 'main.dart.js', 'lineno': 12, 'colno': 34});
    expect(
        events.single.mechanism, {'type': 'window.onerror', 'handled': false});
    final json = events.single.toJson(scrubPii: false);
    expect(((json['exception'] as Map)['values'] as List).single['mechanism'],
        events.single.mechanism);
  });

  test('filters extension and anonymous cross-origin errors', () {
    dispatchError('extension', filename: 'chrome-extension://abc/a.js');
    dispatchError('extension', filename: 'moz-extension://abc/a.js');
    dispatchError('Script error.', filename: '');
    expect(events, isEmpty);
    dispatchError('Script error.', filename: 'main.dart.js');
    expect(events, hasLength(1));
  });

  test('can disable filtering and independently disable listeners', () {
    hooks.close();
    client.transport.close();
    client = makeClient(errors: false);
    hooks.install(client);
    dispatchError('disabled');
    reject('rejection'.toJS);
    expect(events.single.exceptionValue, 'rejection');
    hooks.close();
    client.transport.close();
    client = makeClient(rejections: false, ignore: false);
    hooks.install(client);
    reject('disabled'.toJS);
    dispatchError('Script error.', filename: '');
    expect(events, hasLength(2));
  });

  test('extracts JS Error details and trims stack-overflow recursion', () {
    final error = NativeRangeError('Maximum call stack size exceeded');
    error.stack = 'RangeError: Maximum call stack size exceeded\n'
        '${List.filled(100, '    at recurse (main.dart.wasm:wasm-function[42]:0xff)').join('\n')}';
    reject(error);
    expect(events.single.exceptionType, 'RangeError');
    expect(events.single.tags['wasm.trap'], 'stack_overflow');
    expect(events.single.frames, hasLength(1));
    expect(events.single.frames.single.functionIndex, 42);
    expect(events.single.mechanism!['type'], 'unhandledrejection');
  });

  test('stringifies primitive and null rejections', () {
    reject(42.toJS);
    reject(null);
    expect(events.map((e) => e.exceptionValue), ['42', 'null']);
  });

  test('contains throwing stringifiers and continues capturing', () {
    reject(nullPrototypeObject(null));
    expect(events.single.exceptionValue, '[unserializable rejection reason]');
    dispatchError('next error');
    expect(events, hasLength(2));
  });

  test('deduplicates browser events against manual and Flutter captures',
      () async {
    const stack = '    at work (main.dart.js:12:34)';
    await client.captureException(StateError('already captured'),
        stackTrace: StackTrace.fromString(stack));
    final native = NativeError('Bad state: already captured')..stack = stack;
    dispatchError('already captured', error: native);
    reject(native);
    final previous = FlutterError.onError;
    FlutterError.onError = (_) {};
    final integration = FlutterErrorIntegration()..install(client);
    try {
      FlutterError.onError!(FlutterErrorDetails(
          exception: StateError('framework'),
          stack: StackTrace.fromString(stack),
          silent: true));
      reject(NativeError('Bad state: framework')..stack = stack);
      expect(events, hasLength(2));
    } finally {
      integration.close();
      FlutterError.onError = previous;
    }
  });

  test('contains SDK failures and suppresses their browser echo', () async {
    hooks.close();
    client.transport.close();
    var calls = 0;
    final failure = StateError('transport failed');
    final failureStack = StackTrace.fromString('    at send (sdk.js:1:2)');
    client = makeClient(beforeSend: (_) {
      calls++;
      Error.throwWithStackTrace(failure, failureStack);
    });
    hooks.install(client);
    dispatchError('original');
    await Future<void>.delayed(Duration.zero);
    reject(NativeError(failure.toString())..stack = failureStack.toString());
    expect(calls, 1);
  });

  test('a throwing transport does not start an error feedback loop', () async {
    hooks.close();
    client.transport.close();
    const options = WasmWatchOptions(dsn: 'https://key@example.com/v1/project');
    final failure = Exception('network failure');
    final stack = StackTrace.fromString('    at send (sdk.js:1:2)');
    final transport = FailingTransport(options, failure, stack);
    client = WasmWatchClient(options, transport: transport);
    hooks.install(client);
    dispatchError('application error');
    await Future<void>.delayed(Duration.zero);
    reject(NativeError('network failure')..stack = stack.toString());
    expect(transport.calls, 1);
  });

  test('reinitialization replaces listeners without closing a reused client',
      () async {
    hooks.close();
    await WasmWatch.init(options: client.options, client: client);
    await WasmWatch.init(options: client.options, client: client);
    dispatchError('once');
    expect(events, hasLength(1));
    final next = makeClient();
    await WasmWatch.init(options: next.options, client: next);
    dispatchError('next');
    expect(events, hasLength(2));
    expect(WasmWatch.hub.client, same(next));
  });

  test('WasmWatch init installs hooks and close removes both listeners',
      () async {
    hooks.close();
    await WasmWatch.init(options: client.options, client: client);
    dispatchError('installed');
    expect(events, hasLength(1));
    await WasmWatch.close();
    dispatchError('after close');
    reject('after close'.toJS);
    expect(events, hasLength(1));
    await WasmWatch.close();
  });
}
