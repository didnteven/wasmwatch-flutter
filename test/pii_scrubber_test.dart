import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  test('scrubs strings and recursively filters sensitive keys', () {
    final value = PiiScrubber.scrub({
      'message': 'jane@example.com paid 4111-1111-1111-1111 with SSN 123-45-6789',
      'nested': [{'Authorization': 'Bearer secret'}],
    }) as Map<String, Object?>;
    expect(value.toString(), isNot(contains('jane@example.com')));
    expect(value.toString(), isNot(contains('4111-1111-1111-1111')));
    expect(value.toString(), isNot(contains('123-45-6789')));
    expect(value['nested'].toString(), contains('[Filtered]'));
  });
}
