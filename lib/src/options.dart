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
    this.sendDefaultContext = true,
    bool? trackSessions,
    this.maxBreadcrumbs = 50,
    this.sampleRate = 1,
    this.maxEventsPerSession = 100,
    this.protectionBypass,
    this.beforeSend,
    this.normalizeHttpPath,
    this.enablePiiScrubbing = true,
    this.maxRetries = 3,
    this.captureBrowserErrors = true,
    this.captureUnhandledRejections = true,
    this.ignoreCrossOriginScriptErrors = true,
  })  : _trackSessions = trackSessions,
        assert(maxBreadcrumbs >= 0 && maxBreadcrumbs <= 50),
        assert(sampleRate >= 0 && sampleRate <= 1),
        assert(maxRetries >= 0),
        assert(maxEventsPerSession >= 0);

  final String dsn;
  final String? environment;
  final String? release;
  final bool autoInstallFlutterErrorHandlers;
  final bool captureLifecycleBreadcrumbs;
  final bool capturePrintBreadcrumbs;
  final bool captureNavigationBreadcrumbs;
  final bool debug;
  /// Collect browser/device context without persistent identifiers.
  final bool sendDefaultContext;

  final bool? _trackSessions;
  /// Track release-health sessions by default on iOS and Android only.
  bool get trackSessions => _trackSessions ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.android));

  WasmWatchOptions resolved({
    String? dsn,
    String? environment,
    String? release,
  }) {
    const definedRelease = String.fromEnvironment('WASMWATCH_RELEASE');
    const definedEnvironment = String.fromEnvironment('WASMWATCH_ENVIRONMENT');
    return WasmWatchOptions(
      dsn: dsn ?? this.dsn,
      release: release ??
          this.release ??
          (definedRelease.isNotEmpty ? definedRelease : getWindowRelease()),
      environment: environment ??
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
      sendDefaultContext: sendDefaultContext,
      trackSessions: _trackSessions,
      maxBreadcrumbs: maxBreadcrumbs,
      sampleRate: sampleRate,
      maxEventsPerSession: maxEventsPerSession,
      protectionBypass: protectionBypass,
      beforeSend: beforeSend,
      normalizeHttpPath: normalizeHttpPath,
      enablePiiScrubbing: enablePiiScrubbing,
      maxRetries: maxRetries,
      captureBrowserErrors: captureBrowserErrors,
      captureUnhandledRejections: captureUnhandledRejections,
      ignoreCrossOriginScriptErrors: ignoreCrossOriginScriptErrors,
    );
  }

  final int maxBreadcrumbs;
  final double sampleRate;

  /// One initialized client is a session; retries do not reserve attempts.
  final int maxEventsPerSession;

  /// Defaults to local debug builds. Environment labels cannot disable guards.
  /// Explicit override supports deterministic tests and local diagnostics.
  final bool? protectionBypass;
  bool get bypassProtection => protectionBypass ?? kDebugMode;
  final BeforeSend? beforeSend;

  /// Override the HTTP grouping path template; receives a sanitized URI.
  final String Function(Uri)? normalizeHttpPath;
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

/// Prefix of secret artifact upload tokens, which must never appear in a DSN.
const uploadTokenPrefix = 'wws_';

/// The DSN with an upload token masked, safe for error messages and crash reports.
String redactDsn(String value) {
  try {
    final uri = Uri.parse(value);
    if (Uri.decodeComponent(uri.userInfo).startsWith(uploadTokenPrefix)) {
      return uri.replace(userInfo: '${uploadTokenPrefix}***').toString();
    }
    return value;
  } on FormatException {
    return value.contains(uploadTokenPrefix) ? '<redacted>' : value;
  }
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
    // The DSN is compiled into a browser bundle: an upload token (secret) in it would be public.
    if (Uri.decodeComponent(uri.userInfo).startsWith(uploadTokenPrefix)) {
      throw const FormatException(
        'DSN contains an upload token (wws_…); upload tokens must never be '
        'compiled into an app. Use the project DSN key (wwk_…)',
      );
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
