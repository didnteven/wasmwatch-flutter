import 'dart:convert';
import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';

class MemoryStorage implements OfflineStorage {
  final values = <String, List<String>>{};
  @override
  Future<List<String>?> read(String key) async => values[key];
  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> write(String key, List<String> value) async {
    values[key] = List.of(value);
    return true;
  }
}

void main() {
  test('bounds writes and atomically claims/requeues drain entries', () async {
    final buffer = OfflineBuffer(MemoryStorage(), maximum: 3);
    for (final value in ['a', 'b', 'c', 'd']) {
      await buffer.store(value);
    }
    expect(await buffer.drain(), ['b', 'c', 'd']);
    await buffer.requeue(['b', 'c']);
    expect(await buffer.drain(), ['b', 'c']);
  });
  test('bounds bytes and age across restart and requeue', () async {
    var now = DateTime.utc(2026);
    final storage = MemoryStorage();
    final buffer = OfflineBuffer(storage,
        maximumBytes: 150,
        maximumAge: const Duration(hours: 1),
        clock: () => now);
    await buffer.store('short');
    await buffer.store('x' * 200);
    expect(await buffer.drain(), ['short']);
    await buffer.requeue(['short']);
    now = now.add(const Duration(hours: 2));
    final restarted = OfflineBuffer(storage,
        maximumAge: const Duration(hours: 1), clock: () => now);
    expect(await restarted.drain(), isEmpty);
  });
  test('removes exact IDs without losing identical or later envelopes',
      () async {
    final storage = MemoryStorage();
    final buffer = OfflineBuffer(storage);
    final first = await buffer.store('same');
    final second = await buffer.store('same');
    expect(second, isNot(first));
    final pending = await buffer.pending();
    expect(pending.map((entry) => entry.id), [first, second]);
    await buffer.store('later');
    await buffer.remove(first);
    expect((await buffer.pending()).map((entry) => entry.envelope),
        ['same', 'later']);
    await buffer.remove(first);
    expect((await buffer.pending()).first.id, second);
  });
  test('reads old and new entries without rewriting old entries', () async {
    final storage = MemoryStorage();
    final buffer = OfflineBuffer(storage);
    final old = jsonEncode({
      'at': DateTime.now().toUtc().toIso8601String(),
      'envelope': 'old',
    });
    storage.values[buffer.key] = [old, old];
    final id = await buffer.store('new');
    final restarted = OfflineBuffer(storage);
    final pending = await restarted.pending();
    expect(pending.map((entry) => entry.envelope), ['old', 'old', 'new']);
    expect(storage.values[buffer.key]!.first, old);
    await restarted.remove(pending.first.id);
    expect((await restarted.pending()).map((entry) => entry.envelope),
        ['old', 'new']);
    await restarted.remove(id);
    expect((await restarted.pending()).single.envelope, 'old');
  });

  test('session updates coalesce by sid and give way to events when full',
      () async {
    String session(String sid, String status) =>
        '{}\n{"type":"session","content_type":"application/json","length":1}\n'
        '{"sid":"$sid","status":"$status"}\n';
    expect(OfflineBuffer.sessionOnlyId(session('a', 'ok')), 'a');
    expect(OfflineBuffer.sessionOnlyId('{}\n{"type":"event"}\n{}\n'), isNull);
    final buffer = OfflineBuffer(MemoryStorage(), maximum: 3);
    await buffer.store(session('a', 'ok'));
    await buffer.store(session('a', 'exited'));
    expect((await buffer.pending()).map((entry) => entry.envelope),
        [session('a', 'exited')]);
    await buffer.store('event-1');
    await buffer.store(session('b', 'ok'));
    await buffer.store('event-2');
    expect((await buffer.pending()).map((entry) => entry.envelope),
        ['event-1', session('b', 'ok'), 'event-2']);
    await buffer.store('event-3');
    expect((await buffer.pending()).map((entry) => entry.envelope),
        ['event-1', 'event-2', 'event-3']);
  });
}
