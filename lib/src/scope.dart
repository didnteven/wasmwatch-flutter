import 'dart:collection';
import 'event/breadcrumb.dart';
import 'event/user.dart';

class Scope {
  Scope({WasmWatchUser? user, DateTime Function()? clock})
      : _user = user,
        clock = clock ?? DateTime.now;
  void Function()? onChanged;
  void _changed() => onChanged?.call();
  final DateTime Function() clock;
  WasmWatchUser? _user;
  WasmWatchUser? get user => _user;
  set user(WasmWatchUser? value) {
    _user = value;
    _changed();
  }

  late final Map<String, String> tags = _ChangingMap(_changed);
  final Map<String, Object?> extra = {};
  final Map<String, Object?> contexts = {};
  late final List<Breadcrumb> breadcrumbs = _ChangingList(_changed);

  Scope clone() {
    final result = Scope(user: user, clock: clock);
    result.tags.addAll(tags);
    result.extra.addAll(extra);
    result.contexts.addAll(contexts);
    result.breadcrumbs.addAll(breadcrumbs);
    return result;
  }

  void setTag(String key, String value) => tags[key] = value;
  void setExtra(String key, Object? value) => extra[key] = value;
  void setContext(String key, Object? value) => contexts[key] = value;
  void addBreadcrumb(Breadcrumb breadcrumb, {int maximum = 50}) {
    if (maximum <= 0) {
      breadcrumbs.clear();
      return;
    }
    final stamped = breadcrumb.timestamp == null
        ? breadcrumb.copyWith(timestamp: clock())
        : breadcrumb;
    if (breadcrumbs.isNotEmpty) {
      final old = breadcrumbs.last;
      final sameHttp = old.category == 'http' &&
          stamped.category == 'http' &&
          ['method', 'url', 'status_code']
              .every((key) => old.data[key] == stamped.data[key]);
      if (sameHttp ||
          (stamped.category != 'http' &&
              stamped.message != null &&
              old.category == stamped.category &&
              old.message == stamped.message)) {
        breadcrumbs[breadcrumbs.length - 1] = stamped.copyWith(data: {
          ...stamped.data,
          'count': ((old.data['count'] as int?) ?? 1) + 1,
          'first_timestamp': old.data['first_timestamp'] ??
              old.timestamp!.toUtc().toIso8601String(),
        });
        return;
      }
    }
    breadcrumbs.add(stamped);
    final limit = maximum.clamp(0, 50);
    while (breadcrumbs.length > limit) {
      final protect =
          breadcrumbs.where((b) => b.category == 'navigation').length <= 10;
      final index = protect
          ? breadcrumbs.indexWhere((b) => b.category != 'navigation')
          : 0;
      breadcrumbs.removeAt(index < 0 ? 0 : index);
    }
  }
}

// Preserve the mutable collection API, including direct mutations by callers.
class _ChangingMap<K, V> extends MapBase<K, V> {
  _ChangingMap(this.changed);
  final void Function() changed;
  final _values = <K, V>{};
  @override
  V? operator [](Object? key) => _values[key];
  @override
  void operator []=(K key, V value) {
    _values[key] = value;
    changed();
  }

  @override
  Iterable<K> get keys => _values.keys;
  @override
  void clear() {
    _values.clear();
    changed();
  }

  @override
  V? remove(Object? key) {
    final old = _values.remove(key);
    changed();
    return old;
  }
}

class _ChangingList<T> extends ListBase<T> {
  _ChangingList(this.changed);
  final void Function() changed;
  final _values = <T>[];
  @override
  int get length => _values.length;
  @override
  set length(int value) {
    _values.length = value;
    changed();
  }

  @override
  T operator [](int index) => _values[index];
  @override
  void operator []=(int index, T value) {
    _values[index] = value;
    changed();
  }

  @override
  void add(T value) {
    _values.add(value);
    changed();
  }

  @override
  void addAll(Iterable<T> values) {
    _values.addAll(values);
    changed();
  }

  @override
  void insert(int index, T value) {
    _values.insert(index, value);
    changed();
  }
}
