import 'event/breadcrumb.dart';
import 'event/user.dart';

class Scope {
  Scope({this.user});
  WasmWatchUser? user;
  final Map<String, String> tags = {};
  final Map<String, Object?> extra = {};
  final Map<String, Object?> contexts = {};
  final List<Breadcrumb> breadcrumbs = [];

  Scope clone() {
    final result = Scope(user: user);
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
    breadcrumbs.add(breadcrumb);
    if (breadcrumbs.length > maximum) breadcrumbs.removeRange(0, breadcrumbs.length - maximum);
  }
}
