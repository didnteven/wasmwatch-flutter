import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  test('uses only exception type and normalized symbol', () {
    final one = Fingerprinter.fingerprint(exceptionType: ' StateError ', culpritSymbol: 'CheckoutPage._loadUser');
    final two = Fingerprinter.fingerprint(exceptionType: 'StateError', culpritSymbol: 'CheckoutPage._loadUser');
    expect(one, two);
    expect(Fingerprinter.fingerprint(exceptionType: 'StateError', culpritSymbol: null), isNull);
    expect(one, isNot(Fingerprinter.fingerprint(exceptionType: 'StateError', culpritSymbol: 'CheckoutPage.build')));
  });
}
