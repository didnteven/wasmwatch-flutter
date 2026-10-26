import 'client.dart';
import 'scope.dart';

class Hub {
  Hub(this.client, [Scope? scope])
      : _scope = scope ?? Scope(clock: client.clock) {
    _observe(_scope);
  }
  void Function()? onScopeChanged;
  void _observe(Scope scope) {
    scope.onChanged = () {
      if (identical(_scope, scope)) onScopeChanged?.call();
    };
  }

  final WasmWatchClient client;
  Scope _scope;
  Scope get scope => _scope;
  Future<T> withScope<T>(Future<T> Function(Scope scope) callback) async {
    final previous = _scope;
    _scope = previous.clone();
    _observe(_scope);
    try {
      return await callback(_scope);
    } finally {
      _scope = previous;
      onScopeChanged?.call();
    }
  }
}
