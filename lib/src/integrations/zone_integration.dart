import 'dart:async' as dart_async;
import '../client.dart';

class ZoneIntegration {
  static Future<void> runGuarded(
    Future<void> Function() body, {
    required void Function(Object, StackTrace) onError,
    void Function(String)? onPrint,
  }) {
    final completer = dart_async.Completer<void>();
    dart_async.runZonedGuarded(
      () async {
        try {
          await body();
        } catch (error, stack) {
          onError(error, stack);
        } finally {
          completer.complete();
        }
      },
      onError,
      zoneSpecification: dart_async.ZoneSpecification(
        print: (self, parent, zone, line) {
          onPrint?.call(line);
          parent.print(zone, line);
        },
      ),
    );
    return completer.future;
  }

  static Future<T> runZonedGuarded<T>(
    WasmWatchClient client,
    Future<T> Function() body,
  ) {
    final completer = dart_async.Completer<T>();
    dart_async.runZonedGuarded(
      () async {
        try {
          completer.complete(await body());
        } on Object catch (error, stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
          rethrow;
        }
      },
      (Object error, StackTrace stack) {
        client.captureException(error,
            stackTrace: stack,
            mechanism: const {'type': 'zone', 'handled': false});
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    return completer.future;
  }
}
