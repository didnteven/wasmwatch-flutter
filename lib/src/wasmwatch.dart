import 'dart:async';
import 'dart:isolate';
import 'package:flutter/widgets.dart';
import 'integrations/flutter_error.dart';
import 'integrations/isolate_error_stub.dart'
    if (dart.library.io) 'integrations/isolate_error.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'client.dart';
import 'event/breadcrumb.dart';
import 'event/user.dart';
import 'hub.dart';
import 'integrations/zone_integration.dart';
import 'options.dart';
import 'scope.dart';
import 'session.dart';
import 'transport/offline_buffer.dart';
import 'wasm/loader_check.dart';
import 'web/browser_error_hooks_stub.dart'
    if (dart.library.js_interop) 'web/browser_error_hooks.dart';
import 'package:flutter/foundation.dart';
import 'native/install_id.dart';
import 'native/native_bridge.dart';
import 'native/native_scope.dart';

class WasmWatch {
  WasmWatch._();
  static Hub? _hub;
  static NativeScopeSync? _nativeScope;
  static StreamSubscription<void>? _nativeReportsSubscription;
  static final _nativeReportIds = <String>{};
  static BrowserErrorHooks? _browserHooks;
  static FlutterErrorIntegration? _flutterIntegration;
  static IsolateErrorIntegration? _isolateIntegration;
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
        onError: (error, stack) => _hub?.client.captureException(error,
            stackTrace: stack,
            mechanism: const {'type': 'zone', 'handled': false}),
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
    SharedPreferences? preferences;
    final bridge = !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS)
        ? NativeCrashBridge.instance
        : null;
    if (client == null || options.trackSessions || bridge != null) {
      try {
        preferences = await SharedPreferences.getInstance();
        if (client == null) {
          offlineBuffer = OfflineBuffer(SharedPreferencesStorage(preferences));
        }
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
      await activeClient.sessionTracker?.close();
      activeClient.sessionTracker = null;
    } else {
      await close();
    }
    checkWasmLoader();
    _hub = Hub(activeClient);
    activeClient.hub = _hub;
    _isolateIntegration = IsolateErrorIntegration()..install(activeClient);
    _browserHooks = BrowserErrorHooks()..install(activeClient);
    if (options.autoInstallFlutterErrorHandlers) {
      _flutterIntegration = FlutterErrorIntegration()..install(activeClient);
    }
    String? installId;
    if (bridge != null) {
      try {
        installId = await getInstallId(preferences);
      } catch (error, stack) {
        activeClient.suppressInternalError(error, stack);
      }
      _nativeScope = NativeScopeSync(
          bridge: bridge,
          scope: () => _hub!.scope,
          sessionId: () =>
              activeClient.sessionTracker?.context?['id'] as String?,
          onError: activeClient.suppressInternalError);
      _hub!.onScopeChanged = () => _nativeScope?.update();
    }
    if (options.trackSessions) {
      final tracker = SessionTracker(
        release:
            options.release?.isNotEmpty == true ? options.release! : 'unknown',
        environment: options.environment!,
        platform: activeClient.platform,
        preferences: preferences,
        clock: activeClient.clock,
        onUpdate: activeClient.sendSession,
        onBegin: () => _nativeScope?.update(sessionBegin: true),
      );
      activeClient.sessionTracker = tracker;
      await tracker.start(deferPrevious: bridge != null, installId: installId);
    }
    if (!options.trackSessions) _nativeScope?.update(sessionBegin: true);
    if (options.captureLifecycleBreadcrumbs || options.trackSessions) {
      _lifecycle = _LifecycleBreadcrumbs();
      WidgetsBinding.instance.addObserver(_lifecycle!);
    }
    if (bridge != null) {
      // Neither native trace recovery nor event delivery delays app startup.
      final nativeInstallId = installId ?? await getInstallId(null);
      final nativeHub = _hub;
      void recover() {
        if (!identical(_hub, nativeHub)) return;
        // Native disk calls serialize themselves. A slow event send must not
        // hold up a later crash diagnostic and its deferred session update.
        unawaited(_startNative(activeClient, bridge, nativeInstallId));
      }

      _nativeReportsSubscription = bridge.reportsAvailable?.listen(
          (_) => recover(),
          onError: (Object error, StackTrace stack) =>
              activeClient.suppressInternalError(error, stack));
      recover();
    }
    await activeClient.flushOffline();
  }

  static Future<void> _startNative(WasmWatchClient client,
      NativeCrashBridge bridge, String installId) async {
    final tracker = client.sessionTracker;
    final hub = _hub;
    try {
      final reports = await bridge.start(
          release: client.options.release?.isNotEmpty == true
              ? client.options.release!
              : 'unknown',
          environment: client.options.environment,
          installId: installId);
      // Closing or reinitializing leaves reports pending for the next start.
      if (!identical(_hub, hub)) return;
      await tracker?.completeNativeReports(
          reports, defaultTargetPlatform == TargetPlatform.iOS);
      await _deliverNativeReports(client, bridge, reports);
    } catch (error, stack) {
      client.suppressInternalError(error, stack);
      await tracker?.completeNativeReports(
          const [], defaultTargetPlatform == TargetPlatform.iOS);
    }
  }

  static Future<void> _deliverNativeReports(WasmWatchClient client,
      NativeCrashBridge bridge, List<Map<String, Object?>> reports) async {
    for (final report in reports) {
      final id = report['id'];
      if (id is! String || id.isEmpty || !_nativeReportIds.add(id)) continue;
      final exits = report['kind'] == 'ios_exit_metrics';
      var acknowledged = false;
      try {
        final event = exits ? null : client.nativeReportEvent(report);
        if (exits
            ? await client.sendAppExits(report)
            : (event == null || await client.capturePrebuiltEvent(event))) {
          try {
            await bridge.ack([id]);
            acknowledged = true;
          } catch (error, stack) {
            client.suppressInternalError(error, stack);
          }
        }
      } catch (error, stack) {
        client.suppressInternalError(error, stack);
      } finally {
        if (exits && !acknowledged) _nativeReportIds.remove(id);
      }
    }
  }

  /// Restore handlers, remove observers/listeners, and close the transport.
  static Future<void> close() async {
    _uninstall();
    await _hub?.client.sessionTracker?.close();
    _hub?.client.sessionTracker = null;
    _hub?.client.transport.close();
    _hub = null;
  }

  static void _uninstall() {
    unawaited(_nativeReportsSubscription?.cancel());
    _nativeReportsSubscription = null;
    _nativeScope?.close();
    _nativeScope = null;
    _hub?.onScopeChanged = null;
    _browserHooks?.close();
    _browserHooks = null;
    _flutterIntegration?.close();
    _flutterIntegration = null;
    _isolateIntegration?.close();
    _isolateIntegration = null;
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

  /// Spawn an isolate whose uncaught errors retain their original type name.
  /// Requires initialization; isolate spawning is unavailable on the web.
  static Future<Isolate> spawn<T>(void Function(T) entry, T message) {
    final integration = _isolateIntegration;
    if (integration == null) {
      throw StateError('WasmWatch has not been initialized');
    }
    return integration.spawn(entry, message);
  }

  /// Forward uncaught errors from manually spawned isolates as RemoteError.
  /// Pass this port to Isolate.spawn's onError argument to avoid startup races.
  /// The port remains valid until close() or the next init().
  static SendPort isolateErrorPort() {
    final integration = _isolateIntegration;
    if (integration == null) {
      throw StateError('WasmWatch has not been initialized');
    }
    return integration.errorPort;
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
    final client = WasmWatch._hub?.client;
    if (client == null) return;
    final tracker = client.sessionTracker;
    if (tracker != null) {
      unawaited(tracker.didChangeAppLifecycleState(state).catchError(
          (Object error, StackTrace stack) =>
              client.suppressInternalError(error, stack)));
    }
    if (client.options.captureLifecycleBreadcrumbs) {
      WasmWatch.addBreadcrumb(
        Breadcrumb(category: 'app.lifecycle', message: state.name),
      );
    }
  }
}
