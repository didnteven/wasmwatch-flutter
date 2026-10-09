import 'dart:async';

/// Core type names that survive dart2wasm `--minify` inside `toString()`.
const _knownNames = <String, String>{
  'IndexError': 'RangeError',
  'RangeError': 'RangeError',
  'ArgumentError': 'ArgumentError',
  'StateError': 'StateError',
  'FormatException': 'FormatException',
  'UnimplementedError': 'UnimplementedError',
  'UnsupportedError': 'UnsupportedError',
  'TimeoutException': 'TimeoutException',
  'ConcurrentModificationError': 'ConcurrentModificationError',
  'AssertionError': 'AssertionError',
  'TypeError': 'TypeError',
  'NoSuchMethodError': 'NoSuchMethodError',
  'StackOverflowError': 'StackOverflowError',
  'OutOfMemoryError': 'OutOfMemoryError',
};

final _leadingIdentifier = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)');

/// Returns a stable, readable name for [error], including in dart2wasm
/// release builds where `runtimeType.toString()` is minified.
String describeExceptionType(Object error) {
  String text;
  try {
    text = error.toString();
  } catch (_) {
    text = '';
  }
  final leading = _leadingIdentifier.firstMatch(text)?.group(1);
  final known = leading == null ? null : _knownNames[leading];
  if (known != null) return known;

  // FlutterError implements AssertionError, but keeping its concrete debug
  // name makes framework diagnostics such as RenderFlex overflow readable.
  final runtime = error.runtimeType.toString();
  if (runtime == 'FlutterError') return runtime;

  if (error is RangeError) return 'RangeError';
  if (error is ArgumentError) return 'ArgumentError';
  if (error is StateError) return 'StateError';
  if (error is FormatException) return 'FormatException';
  if (error is UnimplementedError) return 'UnimplementedError';
  if (error is UnsupportedError) return 'UnsupportedError';
  if (error is TimeoutException) return 'TimeoutException';
  if (error is ConcurrentModificationError)
    return 'ConcurrentModificationError';
  if (error is AssertionError) return 'AssertionError';
  if (error is TypeError) return 'TypeError';
  if (error is NoSuchMethodError) return 'NoSuchMethodError';
  if (error is StackOverflowError) return 'StackOverflowError';
  if (error is OutOfMemoryError) return 'OutOfMemoryError';

  if (runtime.isNotEmpty && !runtime.startsWith('minified:')) return runtime;
  if (error is Error) return 'Error';
  if (error is Exception) return 'Exception';
  return 'Object';
}

final _prefixedValue =
    RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)(?: \((.*?)\))?: (.*)$', dotAll: true);

/// Returns the message of [error] without a leading type prefix that repeats
/// [type] (the dashboard renders `<type>: <value>`).
///
/// Removes `Type: `, a known alias such as `IndexError: ` for `RangeError`,
/// and `Exception: ` / `Error: ` for plain exceptions and errors. Dart's
/// parenthesized form `RangeError (index): msg` becomes `msg (index)`, so the
/// detail is kept after the message. If nothing meaningful would remain, or
/// the prefix is not redundant, the original `toString()` is returned. A
/// throwing `toString()` yields an empty string.
String describeExceptionValue(Object error, String type) {
  String text;
  try {
    text = error.toString();
  } catch (_) {
    return '';
  }
  final match = _prefixedValue.firstMatch(text);
  if (match == null) return text;
  final id = match.group(1)!;
  final plain = type == 'Exception' ||
      type == '_Exception' ||
      type == 'Error' ||
      type == '_Error';
  final redundant = id == type ||
      (_knownNames[id] == type) ||
      (plain && (id == 'Exception' || id == 'Error'));
  if (!redundant) return text;
  final message = match.group(3)!.trim();
  if (message.isEmpty) return text;
  final detail = match.group(2);
  return detail == null || detail.isEmpty ? message : '$message ($detail)';
}
