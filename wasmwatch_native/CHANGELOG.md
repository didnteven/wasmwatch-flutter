## 0.3.0

- iOS main-thread hang watchdog (arm64): reports hangs of at least `appHangTimeout` (default 2 s) in the same session, including Dart freezes, with the blocked thread's stack. Paused in the background and while a debugger is attached. A hang that ends in a kill is sent on the next launch. MetricKit hang diagnostics are used only when the watchdog is turned off.
- Verified on an iPhone (iOS 27.2): native hangs, Dart freezes (symbolicated Dart frames), sub-threshold hangs not reported, and kill recovery; real MetricKit exit counts.

## 0.2.0

- iOS 14+ MetricKit crash and hang diagnostics, pending report store and late-delivery notifications. No permission prompt or signal handlers.
- Native Mach-O frames and iOS crash context, with crashed-build identity and session recovery.
- Daily foreground/background exit counts flow through `app_exits` to release health, never issues or session changes. Native reports remain pending until accepted or permanently rejected.
- Hang and exit-count delivery remain unverified on a device (N4/N6); exit JSON tests use a synthetic fixture. KSCrash is the fallback if MetricKit proves unreliable.

## 0.1.0

Not published separately; its changes ship in 0.2.0.

- Optional Android plugin with automatic native bridge registration.
- Capture uncaught Java/Kotlin exceptions on all supported Android versions, chaining the previous handler.
- Recover native crashes, killed ANRs and OS kills on Android 11+; decode native tombstone stacks on Android 12+.
- Persist reports and scope, retain crashed-build identity and acknowledge reports after SDK recovery. No in-process signal handler.
