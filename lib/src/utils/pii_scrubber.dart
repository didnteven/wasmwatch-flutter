class PiiScrubber {
  static final RegExp _email = RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false);
  static final RegExp _creditCard = RegExp(r'\b(?:\d[ -]?){13,19}\b');
  static final RegExp _ssn = RegExp(r'\b\d{3}-\d{2}-\d{4}\b');
  static final RegExp _sensitiveKey = RegExp(
    r'(?:password|passcode|token|secret|authorization|auth|api[_-]?key|credential|cookie)',
    caseSensitive: false,
  );

  static String scrubString(String value) => value
      .replaceAll(_email, '[email]')
      .replaceAll(_creditCard, '[credit-card]')
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
