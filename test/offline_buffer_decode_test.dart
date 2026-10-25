import 'package:test/test.dart';
import 'package:wasmwatch/wasmwatch.dart';
import 'offline_buffer_test.dart' show MemoryStorage;

class CountingStorage extends MemoryStorage {
  int reads = 0;
  bool failWrites = false;

  @override
  Future<List<String>?> read(String key) {
    reads++;
    return super.read(key);
  }

  @override
  Future<bool> write(String key, List<String> value) =>
      failWrites ? Future.value(false) : super.write(key, value);
}

void main() {
  test('replay membership uses the snapshot without reading the buffer again',
      () async {
    final storage = CountingStorage();
    final buffer = OfflineBuffer(storage);
    for (var i = 0; i < 30; i++) {
      await buffer.store('event-$i');
    }
    storage.reads = 0;
    final pending = await buffer.pending();
    expect(storage.reads, 1);
    for (final entry in pending) {
      expect(await buffer.contains(entry.id), isTrue);
      expect(await buffer.contains('missing'), isFalse);
    }
    expect(storage.reads, 1);
    for (final entry in pending) {
      expect(await buffer.contains(entry.id), isTrue);
      await buffer.remove(entry.id);
      expect(await buffer.contains(entry.id), isFalse);
    }
    expect(storage.reads, 1 + pending.length);
  });

  test('membership follows eviction, failed writes, drain and requeue',
      () async {
    final storage = CountingStorage();
    final buffer = OfflineBuffer(storage, maximum: 1);
    final first = await buffer.store('first');
    storage.failWrites = true;
    await expectLater(buffer.store('failed'), throwsStateError);
    expect(await buffer.contains(first), isTrue);
    storage.failWrites = false;
    final second = await buffer.store('second');
    expect(await buffer.contains(first), isFalse);
    expect(await buffer.contains(second), isTrue);
    final drained = await buffer.drain();
    expect(await buffer.contains(second), isFalse);
    await buffer.requeue(drained);
    expect(await buffer.contains(second), isTrue);
  });

  test('cold membership reads once and cached entries still expire', () async {
    var now = DateTime.utc(2026);
    final storage = CountingStorage();
    final original = OfflineBuffer(storage, clock: () => now);
    final id = await original.store('event');
    final restarted = OfflineBuffer(storage,
        clock: () => now, maximumAge: const Duration(hours: 1));
    storage.reads = 0;
    expect(await restarted.contains(id), isTrue);
    now = now.add(const Duration(hours: 2));
    expect(await restarted.contains(id), isFalse);
    expect(storage.reads, 1);
  });
}
