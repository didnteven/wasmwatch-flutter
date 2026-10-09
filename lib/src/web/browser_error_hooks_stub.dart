import '../client.dart';

/// Browser hooks are unavailable on VM, mobile, and desktop targets.
class BrowserErrorHooks {
  void install(WasmWatchClient client) {}
  void close() {}
}
