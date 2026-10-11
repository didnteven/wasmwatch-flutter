import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wasmwatch/wasmwatch.dart';

void main() {
  final dsn = Dsn.parse('http://key@localhost/api/v1/1');
  test(
      'shared cooldown persists after exhausted retries and treats compact 202 as success',
      () async {
    var now = DateTime.utc(2026);
    final times = <DateTime>[];
    final transport = HttpTransport(dsn,
        maxRetries: 0,
        clock: () => now,
        jitter: () => 0,
        delay: (d) async {
          now = now.add(d);
        },
        client: MockClient((r) async {
          times.add(now);
          return times.length == 1
              ? http.Response('', 429, headers: {'retry-after': '6'})
              : http.Response('{"detail_retained":false}', 202);
        }));
    expect(await transport.send('first'), false);
    expect(await transport.send('offline'), true);
    expect(times[1].difference(times[0]), const Duration(seconds: 6));
  });
  test('permanent 4xx is not buffered and outgoing work is bounded', () async {
    final release = Completer<void>();
    var calls = 0;
    final transport =
        HttpTransport(dsn, maximumPending: 1, client: MockClient((r) async {
      calls++;
      await release.future;
      return http.Response('', 400);
    }));
    final first = transport.send('bad');
    expect(await transport.send('overflow'), false);
    release.complete();
    expect(await first, false);
    expect(transport.shouldBuffer('bad'), false);
    expect(calls, 1);
  });
}
