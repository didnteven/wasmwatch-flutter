class PiiScrubber {
  static final RegExp _email =
      RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false);
  static final RegExp _creditCard = RegExp(r'\b\d(?:[ -]?\d){12,18}\b');
  static final RegExp _ssn = RegExp(r'\b\d{3}-\d{2}-\d{4}\b');
  static final RegExp _sensitiveKey = RegExp(
    r'(?:password|passcode|token|secret|authorization|auth|api[_-]?key|credential|cookie)',
    caseSensitive: false,
  );

  /// 13–19 digits that pass the Luhn checksum and start like a card network's
  /// numbers. Luhn alone passes 1 in 10 random numbers, including timestamps;
  /// the prefix and length rules leave timestamps and most order numbers alone.
  static bool _isCardNumber(String candidate) {
    final digits = candidate.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 13 &&
        digits.length <= 19 &&
        _luhnValid(digits) &&
        _hasCardNetworkPrefix(digits);
  }

  static bool _luhnValid(String digits) {
    var sum = 0;
    var double = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      var value = digits.codeUnitAt(i) - 0x30;
      if (double) {
        value *= 2;
        if (value > 9) value -= 9;
      }
      sum += value;
      double = !double;
    }
    return sum % 10 == 0;
  }

  static bool _hasCardNetworkPrefix(String digits) {
    final length = digits.length;
    int prefix(int n) => int.parse(digits.substring(0, n));
    final p2 = prefix(2), p3 = prefix(3), p4 = prefix(4), p6 = prefix(6);
    // Visa
    if (digits.startsWith('4') &&
        (length == 13 || length == 16 || length == 19)) return true;
    // Mastercard
    if (length == 16 && ((p2 >= 51 && p2 <= 55) || (p4 >= 2221 && p4 <= 2720)))
      return true;
    // American Express
    if (length == 15 && (p2 == 34 || p2 == 37)) return true;
    // Discover, UnionPay, JCB
    if (length >= 16 &&
        (p4 == 6011 ||
            p2 == 65 ||
            (p3 >= 644 && p3 <= 649) ||
            p2 == 62 ||
            (p4 >= 3528 && p4 <= 3589))) return true;
    // Diners Club
    if (length >= 14 &&
        (p2 == 36 || p2 == 38 || p2 == 39 || (p3 >= 300 && p3 <= 305)))
      return true;
    // Maestro
    if (length >= 12 && const {5018, 5020, 5038, 6304, 6759}.contains(p4))
      return true;
    return p6 >= 676100 && p6 <= 676399 && length >= 12;
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
