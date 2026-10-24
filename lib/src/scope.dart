import 'event/breadcrumb.dart';
import 'event/user.dart';

class Scope {
  Scope({this.user, DateTime Function()? clock})
      : clock = clock ?? DateTime.now;
  final DateTime Function() clock;
  WasmWatchUser? user;
  final Map<String, String> tags = {};
  final Map<String, Object?> extra = {};
  final Map<String, Object?> contexts = {};
  final List<Breadcrumb> breadcrumbs = [];

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
