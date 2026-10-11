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
        maximumBytes: 100,
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
}
