import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  test('scrubs strings and recursively filters sensitive keys', () {
    final value = PiiScrubber.scrub({
      'message':
          'jane@example.com paid 4111-1111-1111-1111 with SSN 123-45-6789',
      'nested': [
        {'Authorization': 'Bearer secret'}
      ],
    }) as Map<String, Object?>;
    expect(value.toString(), isNot(contains('jane@example.com')));
    expect(value.toString(), isNot(contains('4111-1111-1111-1111')));
    expect(value.toString(), isNot(contains('123-45-6789')));
    expect(value['nested'].toString(), contains('[Filtered]'));
  });

  group('card numbers need a valid Luhn checksum', () {
    for (final card in [
      '4111111111111111', // Visa test number
      '4111-1111-1111-1111',
      '4111 1111 1111 1111',
      '378282246310005', // Amex, 15 digits
      '6011111111111117', // Discover
      '3530111333300000', // JCB
    ]) {
      test('scrubs $card', () {
        expect(PiiScrubber.scrubString('paid with $card today'),
            'paid with [credit-card] today');
      });
    }

    for (final other in [
      '1234567890123456', // 16 digits, fails Luhn
      '1730000000000000', // a microsecond timestamp
      '4111111111111112', // one digit off a valid card
      '12345678901234567890', // 20 digits is not a card
      '1730000000001', // a millisecond timestamp that passes Luhn
      '1730000000000005', // a microsecond timestamp that passes Luhn
      '9999999999999995', // passes Luhn, 9 is no network
    ]) {
      test('keeps $other', () {
        expect(PiiScrubber.scrubString('order $other shipped'),
            'order $other shipped');
      });
    }

    test('scrubs a card next to an order number', () {
      expect(
          PiiScrubber.scrubString(
              '4111111111111111 for order 1234567890123456'),
          '[credit-card] for order 1234567890123456');
    });
  });
}
