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
