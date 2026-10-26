import 'dart:async';
import 'dart:convert';
import '../scope.dart';
import '../utils/pii_scrubber.dart';
import 'native_bridge.dart';
import 'process_id_stub.dart' if (dart.library.io) 'process_id_io.dart';
import 'native_reports.dart' show canonicalUuid;

/// One outstanding write and one trailing snapshot. A new session bypasses the
/// one-second debounce, but still waits for any outstanding native write.
class NativeScopeSync {
  NativeScopeSync(
      {required this.bridge,
      required this.scope,
      required this.sessionId,
      required this.onError,
      DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final NativeCrashBridge bridge;
  final Scope Function() scope;
  final String? Function() sessionId;
  final void Function(Object, StackTrace) onError;
  Timer? _timer;
  DateTime? _lastSent;
  bool _busy = false, _dirty = false, _immediate = false, _closed = false;

  void update({bool sessionBegin = false}) {
    if (_closed) return;
    _dirty = true;
    _immediate |= sessionBegin;
    _schedule();
  }

  void _schedule() {
    if (_closed || _busy || !_dirty) return;
    _timer?.cancel();
    final delay = _lastSent == null || _immediate
        ? Duration.zero
        : const Duration(seconds: 1) - _clock().difference(_lastSent!);
    if (delay <= Duration.zero) {
      unawaited(_send());
    } else {
      _timer = Timer(delay, () => unawaited(_send()));
    }
  }

  Future<void> _send() async {
    if (_closed || _busy || !_dirty) return;
    _busy = true;
    _dirty = _immediate = false;
    _lastSent = _clock();
    try {
      final current = scope();
      final crumbs = current.breadcrumbs
          .skip((current.breadcrumbs.length - 50).clamp(0, 1 << 30))
          .map((crumb) => PiiScrubber.scrub(crumb.toJson()))
          .toList();
      const mappingId = String.fromEnvironment('WASMWATCH_ANDROID_MAPPING_ID');
      final snapshot = <String, Object?>{
        if (nativeProcessId case final int id) 'pid': id,
        if (sessionId() case final String id) 'session_id': id,
        if (mappingId.length == 36 && canonicalUuid.hasMatch(mappingId))
          'android_mapping_id': mappingId,
        'breadcrumbs': crumbs,
        if (current.user != null)
          'user': PiiScrubber.scrub(current.user!.toJson()),
        if (current.tags.isNotEmpty) 'tags': PiiScrubber.scrub(current.tags),
      };
      var encoded = jsonEncode(snapshot);
      while (utf8.encode(encoded).length >= 60 * 1024 && crumbs.isNotEmpty) {
        crumbs.removeAt(0);
        encoded = jsonEncode(snapshot);
      }
      if (utf8.encode(encoded).length >= 60 * 1024)
        throw const FormatException('Native scope exceeds 60 KiB');
      await bridge
          .setScope(Map<String, Object?>.from(jsonDecode(encoded) as Map));
    } catch (error, stack) {
      onError(error, stack);
    } finally {
      _busy = false;
      _schedule();
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }
}
