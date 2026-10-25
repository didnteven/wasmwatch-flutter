import 'dart:async';
import 'dart:isolate';
import '../client.dart';

/// Owns the current-isolate listener and the port for spawned isolates.
class IsolateErrorIntegration {
  RawReceivePort? _currentErrors;
  RawReceivePort? _spawnedErrors;

  void install(WasmWatchClient client) {
    if (_currentErrors != null) return;
    _currentErrors = RawReceivePort(
        (Object? message) => _capture(client, message, current: true))
      ..keepIsolateAlive = false;
    _spawnedErrors = RawReceivePort(
        (Object? message) => _capture(client, message, current: false))
      ..keepIsolateAlive = false;
    Isolate.current.addErrorListener(_currentErrors!.sendPort);
  }

  SendPort get errorPort => _spawnedErrors!.sendPort;

  Future<Isolate> spawn<T>(void Function(T) entry, T message) =>
      Isolate.spawn(_run<T>, (entry, message, errorPort), onError: errorPort);

  void close() {
    final current = _currentErrors;
    if (current != null) {
      Isolate.current.removeErrorListener(current.sendPort);
      current.close();
    }
    _currentErrors = null;
    _spawnedErrors?.close();
    _spawnedErrors = null;
  }

  void _capture(WasmWatchClient client, Object? message,
      {required bool current}) {
    String? type;
    String description;
    String stack;
    if (message case (String name, String value, String trace)) {
      type = name;
      description = value;
      stack = trace;
    } else if (message case [String value, String? trace]) {
      description = value;
      stack = trace ?? '';
    } else {
      return;
    }
    final error = RemoteError(description, stack);
    unawaited(client
        .captureException(
          error,
          stackTrace: error.stackTrace,
          exceptionTypeOverride: type ?? 'RemoteError',
          exceptionValueOverride: description,
          mechanism: const {'type': 'isolate', 'handled': false},
          isolateCapture: current,
        )
        .then<void>((_) {},
            onError: (Object error, StackTrace stack) =>
                client.suppressInternalError(error, stack)));
  }
}

void _run<T>((void Function(T), T, SendPort) arguments) {
  final (entry, message, errors) = arguments;
  runZonedGuarded(() => entry(message), (error, stack) {
    String description;
    try {
      description = error.toString();
    } catch (_) {
      description = '';
    }
    errors.send((error.runtimeType.toString(), description, stack.toString()));
    // Match Isolate.spawn's default errorsAreFatal behavior, including for
    // asynchronous failures caught by the zone.
    Isolate.exit();
  });
}
