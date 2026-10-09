import 'dart:async';
import 'event/error_event.dart';
import 'package:flutter/foundation.dart';
import 'wasm/release.dart';

typedef BeforeSend = FutureOr<ErrorEvent?> Function(ErrorEvent event);

class WasmWatchOptions {
  const WasmWatchOptions({
    required this.dsn,
    this.environment,
    this.release,
    this.autoInstallFlutterErrorHandlers = true,
    this.captureLifecycleBreadcrumbs = true,
    this.capturePrintBreadcrumbs = true,
    this.captureNavigationBreadcrumbs = true,
    this.debug = false,
    this.maxBreadcrumbs = 50,
    this.sampleRate = 1,
    this.beforeSend,
    this.enablePiiScrubbing = true,
    this.maxRetries = 3,
    this.captureBrowserErrors = true,
    this.captureUnhandledRejections = true,
    this.ignoreCrossOriginScriptErrors = true,
  }) : assert(maxBreadcrumbs >= 0 && maxBreadcrumbs <= 50),
       assert(sampleRate >= 0 && sampleRate <= 1),
       assert(maxRetries >= 0);

  final String dsn;
  final String? environment;
  final String? release;
  final bool autoInstallFlutterErrorHandlers;
  final bool captureLifecycleBreadcrumbs;
  final bool capturePrintBreadcrumbs;
  final bool captureNavigationBreadcrumbs;
  final bool debug;

  WasmWatchOptions resolved({
    String? dsn,
    String? environment,
    String? release,
  }) {
    const definedRelease = String.fromEnvironment('WASMWATCH_RELEASE');
    const definedEnvironment = String.fromEnvironment('WASMWATCH_ENVIRONMENT');
    return WasmWatchOptions(
      dsn: dsn ?? this.dsn,
      release:
          release ??
          this.release ??
          (definedRelease.isNotEmpty ? definedRelease : getWindowRelease()),
      environment:
          environment ??
          this.environment ??
          (definedEnvironment.isNotEmpty
              ? definedEnvironment
              : kReleaseMode
              ? 'production'
              : kProfileMode
              ? 'profile'
              : 'debug'),
      autoInstallFlutterErrorHandlers: autoInstallFlutterErrorHandlers,
      captureLifecycleBreadcrumbs: captureLifecycleBreadcrumbs,
      capturePrintBreadcrumbs: capturePrintBreadcrumbs,
      captureNavigationBreadcrumbs: captureNavigationBreadcrumbs,
      debug: debug,
      maxBreadcrumbs: maxBreadcrumbs,
      sampleRate: sampleRate,
      beforeSend: beforeSend,
      enablePiiScrubbing: enablePiiScrubbing,
      maxRetries: maxRetries,
      captureBrowserErrors: captureBrowserErrors,
      captureUnhandledRejections: captureUnhandledRejections,
      ignoreCrossOriginScriptErrors: ignoreCrossOriginScriptErrors,
    );
  }

  final int maxBreadcrumbs;
  final double sampleRate;
  final BeforeSend? beforeSend;
  final bool enablePiiScrubbing;
  final int maxRetries;

  /// Capture errors escaping to the browser window event loop.
  final bool captureBrowserErrors;

  /// Capture browser promise rejections without cancelling console logging.
  final bool captureUnhandledRejections;

  /// Ignore extension errors and anonymous cross-origin script errors.
  final bool ignoreCrossOriginScriptErrors;

  Dsn get parsedDsn => Dsn.parse(dsn);
}

class Dsn {
  const Dsn({
    required this.endpoint,
    required this.publicKey,
    required this.projectId,
  });

  final Uri endpoint;
  final String publicKey;
  final String projectId;

  static Dsn parse(String value) {
    final uri = Uri.parse(value);
    if (!uri.hasScheme || uri.userInfo.isEmpty || uri.host.isEmpty) {
      throw FormatException('DSN must include scheme, public key, and host');
    }
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (parts.length < 2) {
      throw FormatException('DSN path must end in /<version>/<project-id>');
    }
    return Dsn(
      endpoint: uri.replace(
        userInfo: '',
        path: '/api/v1/envelope',
        query: null,
      ),
      publicKey: Uri.decodeComponent(uri.userInfo),
      projectId: parts.last,
    );
  }
}
