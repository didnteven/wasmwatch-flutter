import 'dart:convert';
import 'package:crypto/crypto.dart';

class Fingerprinter {
  /// Permanent grouping requires a resolved symbol. Raw offsets are intentionally
  /// excluded so a rebuilt module or source-line shift cannot churn an issue.
  static String? fingerprint({required String exceptionType, String? culpritSymbol}) {
    final type = _normalize(exceptionType);
    final culprit = _normalize(culpritSymbol ?? '');
    if (type.isEmpty || culprit.isEmpty) return null;
    return sha256.convert(utf8.encode('$type\u0000$culprit')).toString();
  }

  static String _normalize(String input) => input.trim().replaceAll(RegExp(r'\s+'), ' ');
}
