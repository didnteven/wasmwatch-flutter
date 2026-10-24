import 'package:flutter_test/flutter_test.dart';
import 'package:wasmwatch/src/scope.dart';
import 'package:wasmwatch/src/client.dart';
import 'package:wasmwatch/src/hub.dart';
import 'package:wasmwatch/src/options.dart';
import 'package:wasmwatch/src/event/breadcrumb.dart';

void main() {
  test('null messages and HTTP URLs do not collapse unrelated breadcrumbs', () {
    final scope = Scope();
    scope.addBreadcrumb(const Breadcrumb(category: 'ui', data: {'x': 1}));
    scope.addBreadcrumb(const Breadcrumb(category: 'ui', data: {'x': 2}));
    expect(scope.breadcrumbs, hasLength(2));
    scope.addBreadcrumb(const Breadcrumb(category: 'http', message: 'GET', data: {'url': '/a'}));
    scope.addBreadcrumb(const Breadcrumb(category: 'http', message: 'GET', data: {'url': '/b'}));
    expect(scope.breadcrumbs, hasLength(4));
  });

  test(
      'Hub stamps with client clock; clones keep clock; JSON keeps distinct times',
      () {
    var now = DateTime.utc(2026);
    final client = WasmWatchClient(
        const WasmWatchOptions(dsn: 'https://key@example.com/v1/project'),
        clock: () => now);
    final scope = Hub(client).scope;
    scope.addBreadcrumb(const Breadcrumb(category: 'a', message: 'first'));
    now = now.add(const Duration(seconds: 2));
    final clone = scope.clone();
    clone.addBreadcrumb(const Breadcrumb(category: 'b'));
    expect(clone.breadcrumbs.first.toJson()['timestamp'],
        '2026-01-01T00:00:00.000Z');
    expect(clone.breadcrumbs.last.toJson()['timestamp'],
        '2026-01-01T00:00:02.000Z');
    final explicit = DateTime.utc(2020);
    clone.addBreadcrumb(Breadcrumb(category: 'c', timestamp: explicit));
    expect(clone.breadcrumbs.last.timestamp, explicit);
    client.transport.close();
  });

  test('HTTP repeats collapse despite differing messages and retain first time',
      () {
    var now = DateTime.utc(2026);
    final scope = Scope(clock: () => now);
    for (var i = 0; i < 3; i++) {
      scope.addBreadcrumb(Breadcrumb(
          category: 'http',
          message: 'request $i',
          data: const {'method': 'GET', 'url': '/x', 'status_code': 204}));
      now = now.add(const Duration(seconds: 1));
    }
    expect(scope.breadcrumbs, hasLength(1));
    expect(scope.breadcrumbs.single.data['count'], 3);
    expect(scope.breadcrumbs.single.data['first_timestamp'],
        '2026-01-01T00:00:00.000Z');
    expect(scope.breadcrumbs.single.timestamp,
        DateTime.utc(2026).add(const Duration(seconds: 2)));
  });

  test('console spam collapses only consecutively', () {
    final scope = Scope();
    const crumb = Breadcrumb(category: 'console', message: 'spam');
    scope.addBreadcrumb(crumb);
    scope.addBreadcrumb(crumb);
    expect(scope.breadcrumbs.single.data['count'], 2);
    scope.addBreadcrumb(const Breadcrumb(category: 'other'));
    scope.addBreadcrumb(crumb);
    expect(scope.breadcrumbs, hasLength(3));
    expect(scope.breadcrumbs.last.data.containsKey('count'), isFalse);
  });

  test('navigation survives sixty distinct HTTP requests', () {
    final scope = Scope();
    for (var i = 0; i < 3; i++) {
      scope.addBreadcrumb(
          Breadcrumb(category: 'navigation', message: '/page/$i'));
    }
    for (var i = 0; i < 60; i++) {
      scope.addBreadcrumb(Breadcrumb(
          category: 'http', message: 'request $i', data: {'url': '/$i'}));
    }
    expect(scope.breadcrumbs, hasLength(50));
    expect(scope.breadcrumbs.where((b) => b.category == 'navigation'),
        hasLength(3));
    expect(scope.breadcrumbs[3].message, 'request 13');
  });

  test('over ten navigations evicts oldest overall and honors zero capacity',
      () {
    final scope = Scope();
    for (var i = 0; i < 51; i++) {
      scope.addBreadcrumb(Breadcrumb(category: 'navigation', message: '$i'));
    }
    expect(scope.breadcrumbs.first.message, '1');
    scope.addBreadcrumb(const Breadcrumb(category: 'end'), maximum: 0);
    expect(scope.breadcrumbs, isEmpty);
  });
}
