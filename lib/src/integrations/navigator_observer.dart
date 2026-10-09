import 'package:flutter/widgets.dart';
import '../event/breadcrumb.dart';
import '../wasmwatch.dart';

class NavigatorObserverIntegration extends NavigatorObserver {
  NavigatorObserverIntegration({void Function(Breadcrumb)? addBreadcrumb})
    : _addBreadcrumb =
          addBreadcrumb ??
          ((breadcrumb) {
            if (WasmWatch.isInitialized &&
                WasmWatch.hub.client.options.captureNavigationBreadcrumbs) {
              WasmWatch.addBreadcrumb(breadcrumb);
            }
          });
  final void Function(Breadcrumb) _addBreadcrumb;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _record(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _record(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _record(newRoute);
  }

  void _record(Route<dynamic> route) => _addBreadcrumb(
    Breadcrumb(
      category: 'navigation',
      message: route.settings.name ?? route.runtimeType.toString(),
      data: {'action': 'navigate'},
    ),
  );
}

/// Ready-made observer for MaterialApp.navigatorObservers.
class WasmWatchNavigatorObserver extends NavigatorObserverIntegration {
  WasmWatchNavigatorObserver({super.addBreadcrumb});
}
