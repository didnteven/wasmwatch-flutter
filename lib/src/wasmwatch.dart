import 'dart:async';
import 'package:flutter/widgets.dart';
import 'integrations/flutter_error.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'client.dart';
import 'event/breadcrumb.dart';
import 'event/user.dart';
import 'hub.dart';
import 'integrations/zone_integration.dart';
import 'options.dart';
import 'scope.dart';
import 'transport/offline_buffer.dart';
import 'wasm/loader_check.dart';
import 'web/browser_error_hooks_stub.dart'
    if (dart.library.js_interop) 'web/browser_error_hooks.dart';

class WasmWatch {
  WasmWatch._();
  static Hub? _hub;
  static BrowserErrorHooks? _browserHooks;
  static FlutterErrorIntegration? _flutterIntegration;
  static _LifecycleBreadcrumbs? _lifecycle;
  static FlutterErrorIntegration? get flutterErrorIntegration =>
      _flutterIntegration;
  static bool get isInitialized => _hub != null;
  static Hub get hub =>
      _hub ?? (throw StateError('WasmWatch has not been initialized'));

  /// Initializes handlers and runs the app in the same zone as its binding.
  static Future<void> init({
    String? dsn,
    WasmWatchOptions? options,
    String? environment,
    String? release,
    FutureOr<void> Function()? appRunner,
    WasmWatchClient? client,
  }) async {
    const definedDsn = String.fromEnvironment('WASMWATCH_DSN');
    final effectiveDsn =
        dsn ?? options?.dsn ?? client?.options.dsn ?? definedDsn;
    if (effectiveDsn.isEmpty) {
      await close();
      debugPrint(
        'WasmWatch: no DSN configured; running without error reporting. '
        'Pass dsn/options or define WASMWATCH_DSN.',
      );
      if (appRunner != null) {
        WidgetsFlutterBinding.ensureInitialized();
        await appRunner();
      }
      return;
    }
    final resolved =
        (options ?? client?.options ?? WasmWatchOptions(dsn: effectiveDsn))
            .resolved(
      dsn: effectiveDsn,
      environment: environment,
      release: release,
    );
    // Validate configuration before entering the application error zone.
    try {
      resolved.parsedDsn;
    } on FormatException catch (error) {
      throw ArgumentError.value(redactDsn(effectiveDsn), 'dsn', error.message);
    }
    if (client != null) client.options = resolved;
    Future<void> start() async {
      WidgetsFlutterBinding.ensureInitialized();
      await _initialize(resolved, client);
      if (appRunner != null) await appRunner();
    }

    if (appRunner == null) {
      await start();
    } else {
      await ZoneIntegration.runGuarded(
        start,
        onError: (error, stack) =>
            _hub?.client.captureException(error, stackTrace: stack),
        onPrint: resolved.capturePrintBreadcrumbs
            ? (line) {
                if (_hub != null &&
                    Zone.current[
                            FlutterErrorIntegration.suppressPrintZoneKey] !=
                        true)
                  addBreadcrumb(Breadcrumb(category: 'console', message: line));
              }
            : null,
      );
    }
  }

  static Future<void> _initialize(
    WasmWatchOptions options,
    WasmWatchClient? client,
  ) async {
    OfflineBuffer? offlineBuffer;
    if (client == null) {
      try {
        offlineBuffer = OfflineBuffer(
          SharedPreferencesStorage(await SharedPreferences.getInstance()),
        );
      } catch (_) {
        // Persistent storage is optional. Unsupported plugins (including on
        // WebAssembly) must not prevent the host application from starting.
      }
    }
    final activeClient =
        client ?? WasmWatchClient(options, offlineBuffer: offlineBuffer);
    activeClient.initializeMobileBuild();
    if (identical(_hub?.client, activeClient)) {
      _uninstall();
    } else {
      await close();
    }
    checkWasmLoader();
    _hub = Hub(activeClient);
    activeClient.hub = _hub;
    _browserHooks = BrowserErrorHooks()..install(activeClient);
    if (options.autoInstallFlutterErrorHandlers) {
      _flutterIntegration = FlutterErrorIntegration()..install(activeClient);
    }
    if (options.captureLifecycleBreadcrumbs) {
      _lifecycle = _LifecycleBreadcrumbs();
      WidgetsBinding.instance.addObserver(_lifecycle!);
    }
    await activeClient.flushOffline();
  }

  /// Restore handlers, remove observers/listeners, and close the transport.
  static Future<void> close() async {
    _uninstall();
    _hub?.client.transport.close();
    _hub = null;
  }

  static void _uninstall() {
    _browserHooks?.close();
    _browserHooks = null;
    _flutterIntegration?.close();
    _flutterIntegration = null;
    if (_lifecycle != null) WidgetsBinding.instance.removeObserver(_lifecycle!);
    _lifecycle = null;
  }

  static Future<String?> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? hint,
    FutureOr<void> Function(Scope scope)? withScope,
  }) async {
    if (withScope == null)
      return hub.client.captureException(
        error,
        stackTrace: stackTrace,
        hint: hint,
      );
    return hub.withScope((scope) async {
      await withScope(scope);
      return hub.client.captureException(
        error,
        stackTrace: stackTrace,
        hint: hint,
        scope: scope,
      );
    });
  }

  /// Capture a synchronous callback failure before it escapes into JavaScript.
  static R guardCallback<R>(R Function() body) {
    try {
      return body();
    } catch (error, stack) {
      final client = _hub?.client;
      if (client != null) {
        unawaited(client.captureException(error, stackTrace: stack, mechanism: {
          'type': 'js_callback',
          'handled': false
        }).then<void>((_) {},
            onError: (Object e, StackTrace s) =>
                client.suppressInternalError(e, s)));
      }
      rethrow;
    }
  }

  /// Return a one-argument callback suitable for `.toJS` or plugin APIs.
  static R Function(A) guardCallback1<A, R>(R Function(A) body) =>
      (argument) => guardCallback(() => body(argument));

  static Future<String?> captureMessage(
    String message, {
    SeverityLevel level = SeverityLevel.info,
  }) =>
      captureException(_MessageException(message), hint: level.name);
  static void setUser(WasmWatchUser user) => hub.scope.user = user;
  static void clearUser() => hub.scope.user = null;
  static void addBreadcrumb(Breadcrumb breadcrumb) => hub.scope.addBreadcrumb(
        breadcrumb,
        maximum: hub.client.options.maxBreadcrumbs,
      );
  static Future<T> withScope<T>(Future<T> Function(Scope scope) callback) =>
      hub.withScope(callback);

  static Future<T> runZonedGuarded<T>(Future<T> Function() body) =>
      ZoneIntegration.runZonedGuarded(hub.client, body);
}

class _MessageException implements Exception {
  const _MessageException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _LifecycleBreadcrumbs extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    WasmWatch.addBreadcrumb(
      Breadcrumb(category: 'app.lifecycle', message: state.name),
    );
  }
}
