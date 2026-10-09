import 'dart:convert';
import 'package:crypto/crypto.dart';

// ECMAScript JSON.stringify: array-index keys precede insertion-ordered keys,
// and all numbers are IEEE doubles, printed without an unnecessary .0.
String stringifyPayload(Object? value) {
  if (value is num) return _number(value.toDouble());
  if (value is List) return '[${value.map(stringifyPayload).join(',')}]';
  if (value is Map<String, dynamic>) {
    int? index(String key) {
      final n = int.tryParse(key);
      return n != null && n >= 0 && n < 4294967295 && '$n' == key ? n : null;
    }

    final indexed = value.keys.where((k) => index(k) != null).toList()
      ..sort((a, b) => index(a)!.compareTo(index(b)!));
    final keys = [...indexed, ...value.keys.where((k) => index(k) == null)];
    return '{${keys.map((k) => '${jsonEncode(k)}:${stringifyPayload(value[k])}').join(',')}}';
  }
  return jsonEncode(value);
}

String _number(double n) {
  if (!n.isFinite) return 'null';
  if (n == 0) return '0';
  final negative = n < 0;
  final text = n.abs().toString();
  final parts = text.split('e');
  final mantissa = parts[0];
  final exponent = parts.length == 2 ? int.parse(parts[1]) : 0;
  final dot = mantissa.indexOf('.');
  var digits = mantissa.replaceAll('.', '');
  var point = (dot < 0 ? mantissa.length : dot) + exponent;
  while (digits.startsWith('0') && digits.length > 1) {
    digits = digits.substring(1);
    point--;
  }
  digits = digits.replaceFirst(RegExp(r'0+$'), '');
  final power = point - 1;
  String result;
  if (power >= -6 && power < 21) {
    if (point <= 0) {
      result = '0.${'0' * -point}$digits';
    } else if (point >= digits.length) {
      result = '$digits${'0' * (point - digits.length)}';
    } else {
      result = '${digits.substring(0, point)}.${digits.substring(point)}';
    }
  } else {
    result =
        '${digits[0]}${digits.length > 1 ? '.${digits.substring(1)}' : ''}e${power >= 0 ? '+' : ''}$power';
  }
  return '${negative ? '-' : ''}$result';
}

Map<String, dynamic> deriveIdentity(List<int> wasm, Map<String, dynamic> map) {
  if (wasm.length < 8 || wasm.take(4).join(',') != '0,97,115,109') {
    throw const FormatException(
        'artifact identity requires a valid non-empty Wasm binary');
  }
  if (map['version'] != 3 ||
      map['mappings'] is! String ||
      map['sources'] is! List) {
    throw const FormatException(
        'artifact identity requires a version 3 source map with mappings and sources');
  }
  final payload = Map<String, dynamic>.of(map)..remove('x_wasmwatch_artifact');
  final wasmHash = sha256.convert(wasm).toString();
  final mapHash =
      sha256.convert(utf8.encode(stringifyPayload(payload))).toString();
  final bytes = sha256
      .convert(
          utf8.encode('wasmwatch-artifact-v1\u0000$wasmHash\u0000$mapHash'))
      .bytes
      .take(16)
      .toList();
  bytes[6] = (bytes[6] & 15) | 0x70;
  bytes[8] = (bytes[8] & 63) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return {
    'version': 1,
    'debug_id':
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}',
    'wasm_sha256': wasmHash,
    'map_payload_sha256': mapHash
  };
}
