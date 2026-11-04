class PiiScrubber {
  static final RegExp _email =
      RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false);
  static final RegExp _creditCard = RegExp(r'\b\d(?:[ -]?\d){12,18}\b');
  static final RegExp _ssn = RegExp(r'\b\d{3}-\d{2}-\d{4}\b');
  static final RegExp _sensitiveKey = RegExp(
    r'(?:password|passcode|token|secret|authorization|auth|api[_-]?key|credential|cookie)',
    caseSensitive: false,
  );

  /// 13–19 digits that pass the Luhn checksum. Timestamps, order numbers and
  /// other long digit runs mostly fail it and are left alone.
  static bool _isCardNumber(String candidate) {
    var sum = 0;
    var double = false;
    var digits = 0;
    for (var i = candidate.length - 1; i >= 0; i--) {
      final code = candidate.codeUnitAt(i) - 0x30;
      if (code < 0 || code > 9) continue;
      digits++;
      var value = code;
      if (double) {
        value *= 2;
        if (value > 9) value -= 9;
      }
      sum += value;
      double = !double;
    }
    return digits >= 13 && digits <= 19 && sum % 10 == 0;
  }

  static String scrubString(String value) => value
      .replaceAll(_email, '[email]')
      .replaceAllMapped(
          _creditCard, (m) => _isCardNumber(m[0]!) ? '[credit-card]' : m[0]!)
      .replaceAll(_ssn, '[ssn]');

  static Object? scrub(Object? value) {
    if (value is String) return scrubString(value);
    if (value is List) return value.map(scrub).toList(growable: false);
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): _sensitiveKey.hasMatch(entry.key.toString())
              ? '[Filtered]'
              : scrub(entry.value),
      };
    }
    return value;
  }

  static Map<String, Object?> scrubMap(Map<String, Object?> values) =>
      scrub(values) as Map<String, Object?>;
}
