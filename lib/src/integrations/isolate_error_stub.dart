import 'dart:isolate';
import '../client.dart';

/// Isolate APIs are unavailable in browsers.
class IsolateErrorIntegration {
  void install(WasmWatchClient client) {}
  void close() {}

  SendPort get errorPort =>
      throw UnsupportedError('Isolates are unavailable on the web');

  Future<Isolate> spawn<T>(void Function(T) entry, T message) =>
      throw UnsupportedError('Isolates are unavailable on the web');
}
