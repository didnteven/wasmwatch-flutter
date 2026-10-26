# wasmwatch_native

Optional Android and iOS crash capture for WasmWatch, version 0.2.0. Add the dependency
alongside `wasmwatch` and call `WasmWatch.init` with a release and DSN as usual.
Flutter automatically registers the native bridge; no application registration
code is required. The SDK recovers reports on the next launch and sends them
through its normal transport. Crashes/hangs become events; iOS exits become daily
release-health counts. Reports retain the crashed build's identity.

```yaml
dependencies:
  wasmwatch:
    git:
      url: https://github.com/didnteven/wasmwatch-flutter.git
      ref: v0.7.0
  wasmwatch_native:
    git:
      url: https://github.com/didnteven/wasmwatch-flutter.git
      ref: v0.7.0
      path: wasmwatch_native
```

Generate a new lowercase UUID for each Android build and use the same value for
the app and its R8 mapping upload:

```sh
flutter build apk --release --dart-define=WASMWATCH_ANDROID_MAPPING_ID=<new-uuid-per-build>
dart run wasmwatch:upload_symbols --symbols-dir build/symbols/android \
  --android-mapping build/app/outputs/mapping/release/mapping.txt \
  --mapping-id <same-uuid> \
  --native-libs build/app/intermediates/merged_native_libs/release/out/lib
```

The upload command also needs your normal server/project credentials. Configure
`WASMWATCH_RELEASE` (or `release:` in `WasmWatch.init`) with the build's release.
Without a release the bridge cannot start capture with a trustworthy identity.
Use the same `ref` for both packages; the plugin depends on `wasmwatch` at that tag.

In the WasmWatch source repository, `example/` is a crash harness for emulators and
devices: buttons (and an optional polled command URL) trigger `throw`,
`throw_background`, `abort`, `anr`, `hang` (iOS) and `handled_dart`.

Java/Kotlin uncaught exceptions are captured on every supported Android version,
using Flutter's default minimum SDK (currently API 24). Android 11 / API 30 adds
historical native crashes, killed ANRs, low-memory kills, resource kills and
initialization failures. Android 12 / API 31 adds decoded native tombstone stacks.
On API 30 native crashes still carry exit metadata without tombstone frames.
Reports without tombstone evidence retain the exit description and any known
exit signal, with empty frames and the SDK's Dart image (or its unknown-build
placeholder). Invalid optional scope data is omitted without dropping the crash.
An ANR that recovers without a recorded exit cannot be captured by this API.
Other exit reasons, including user-requested stops and updates, are ignored.
Desktop and web calls return an empty list or do nothing without a channel call.

```dart
final reports = await WasmWatchNative.start(
  release: '1.2.0',
  environment: 'production', // optional
  installId: persistentRandomInstallId,
);
await WasmWatchNative.setScope({
  'pid': pid, // dart:io; required for iOS historical scope matching
  'session_id': sessionId,
  'tags': {'flavour': 'production'},
});
// Low-level API: acknowledge after durable buffering or completed delivery.
await WasmWatchNative.ack(successfullySentIds);
```

`start` returns `Future<List<Map<String, Object?>>>`. `setScope` takes an opaque
JSON object; native code stores and echoes it without interpreting breadcrumbs,
users, tags or session IDs. Scope JSON must fit within 64 KiB, including encoding
and escaping, with JSON nesting limited to 64 levels. An oversized or invalid
scope returns a platform error and leaves
the last scope intact. `ack(List<String>)` deletes only those pending files and
is idempotent. Disk/API failures surface as platform errors; malformed report
JSON entries are skipped individually by Dart.

## Version 1 report contract

These are local plugin reports, not ingestor events. All keys use snake_case.
Fields marked optional are omitted when unavailable. Numbers below are JSON
integers; timestamps are Unix milliseconds. A `start` channel call takes a map
`{release: String, environment?: String, install_id: String}` and returns a list
of JSON **strings**. `setScope` takes a JSON string; `ack` takes a list of strings.
The channel is `wasmwatch/native`.

| Field | Type and meaning |
| --- | --- |
| `v` | Integer `1`, report format version. |
| `id` | String; handler reports use `java-<uuid>`, derived reports use `exit-<pid>-<timestamp>-<numeric reason>`. Acknowledge this exact value. |
| `kind` | `java_crash`, `native_crash`, `anr`, or `app_exit`. |
| `timestamp_ms` | Handler capture time, or historical exit timestamp. Pairing preserves the handler capture time. |
| `pid` | Integer Android process ID. |
| `thread` | Optional string; uncaught handler thread name. |
| `exception` | Optional Java exception object described below. Unpaired OS Java crashes have no exception/frames. |
| `threads` | Optional array of ANR or native thread objects described below. |
| `signal` | Optional native signal object described below. |
| `abort_message` | Optional native abort string, at most 8 KiB UTF-8 before JSON escaping. |
| `images` | Optional array of distinct native `(file_name, build_id)` images from reported frames. |
| `arch` | Optional known architecture: `arm32`, `arm64`, `x86`, `x86_64`, `riscv64`. Unknown enum values are omitted. |
| `exit` | Optional OS exit object. Handler reports gain it only if paired with a historical Java crash. |
| `scope` | Optional opaque JSON object: capture-time scope for a handler; previous-process scope for a derived report. |
| `release` | String passed to `start`, with identity rules below. |
| `environment` | Optional string passed to `start`. |
| `install_id` | String passed as `installId` to `start`; use a persistent random installation ID. |

An `exception` object contains `class` (throwable class string), optional
`message` (at most 8 KiB UTF-8), `frames` (array, at most 256), and optional
`cause` (another exception object). At most eight throwable objects are captured
in the chain, with cycles stopped; suppressed exceptions are ignored. Each Java
frame contains `module` (class name string), `function` (method name string),
optional `filename` (source filename string), and optional `lineno` (nonnegative
integer). Unknown/native locations do not produce invented source coordinates.
Frame order is the original stack order, with the newest call first.

For an ANR, `threads` contains just the main thread when its header is found:
`{name: "main", state: String, frames: [Java frame], native_frame_count: int}`.
`state` is the state text from the main-thread header (for example `Sleeping`).
Only parseable Java `at` lines produce frames, at most 256. Lock/wait lines are
ignored. `native:` lines are counted in `native_frame_count` but omitted from
`frames`. R8-obfuscated classes and methods are retained for server remapping.

For a tombstone, `threads` starts with the crashing `tid` if present, followed by
up to seven other threads. Each thread has `id` (optional integer protobuf
thread ID), `name` (optional string), and `frames` (array, at most 256). Each
native frame contains `pc` and `rel_pc` (unsigned hexadecimal strings prefixed
`0x`), optional `function_name` (string), `function_offset` (hex string),
`file_name` (string), and `build_id` (lowercase hexadecimal string from the
protobuf). Native thread frames retain tombstone order. Zero-valued protobuf
scalars use protobuf's default zero semantics.

Each image has `file_name`, optional `build_id`, and `image_addr` (hex string,
`pc - rel_pc`, with unsigned arithmetic; omitted image if that would underflow).
`image_size` is an optional hex string equal to `end_address - begin_address`
for a mapping with the same filename/build ID containing the frame's `pc`.
No size is emitted without that evidence. Images are deduplicated by filename
and build ID, keeping the first reported frame's load address. They can include
Dart AOT frames from `base.apk`, Flutter engine libraries and system libraries.

`signal` contains `number` (integer), `name` (string, e.g. `SIGABRT`), `code`
(signed integer), `code_name` (string), and optional `fault_address` (unsigned
hex string, only if the protobuf says it has a fault address).

`exit` contains all of:

| Field | Type and meaning |
| --- | --- |
| `reason` | String OS reason name: `CRASH`, `CRASH_NATIVE`, `ANR`, `LOW_MEMORY`, `EXCESSIVE_RESOURCE_USAGE`, or `INITIALIZATION_FAILURE`. |
| `description` | OS description string, or null if unavailable. |
| `status` | Integer OS exit status/signal. |
| `importance` | Integer Android process importance (e.g. 100 foreground, 400 cached). |
| `pss_kb`, `rss_kb` | Integer memory readings in KiB from Android (zero when Android supplies zero). |
| `timestamp_ms` | Integer OS exit timestamp; can differ from the handler capture time. |
| `process_name` | OS process name string, or null if unavailable. |

Exit-derived reports use the release/environment/install ID of the process that
exited: the identity saved by the previous process's last `start` (so a crash in
1.0.0 is reported as 1.0.0 after an update to 1.0.1). Only if no previous identity
was saved do they use the current `start`'s. Handler reports retain the identity
from the last `start` before capture, including after a process restart. Before the
very first `start` there is no identity: the handler still saves the crash, and its
missing identity is filled by the first `start` that returns it. A report's
identity never changes once set. Pairing with an
exit preserves a handler's identity and scope.

## Persistence and safety

The single report queue is `filesDir/wasmwatch/pending/<id>.json`. Reports remain
until acknowledged, except oldest-file eviction at 32 files. Every file is at
most 512 KiB. Strings are limited to 8 KiB UTF-8 (identity and opaque scope retain
their original values); frames and then strings shrink further if needed to fit
the file limit. Source frames can therefore be fewer than the per-thread limits.
Writes use a sibling temporary file, flush/sync, then rename. Restart cleans
abandoned temporary files and restores the 32-file bound.

`filesDir/wasmwatch/scope.json` holds the last scope, bounded to 64 KiB.
`identity.json` alongside it persists the last start's identity, also bounded to
64 KiB. Scope updates replace the in-memory snapshot synchronously, then queue
atomic persistence on the process-wide single-thread worker. Native start and
acknowledgement disk/API work also run on that worker, with channel results
posted to the main thread. Identity changes follow successful persistence. The
previous scope is read on engine attachment, before Dart can replace it; repeated
starts in that process continue to use that same previous-process snapshot.
The uncaught handler is installed once per process on attachment, writes
synchronously and always chains the previous handler even after a `Throwable`
during capture. Detaching an engine does not remove it.

On API 30+, `start` requests up to 32 historical exits using
`getHistoricalProcessExitReasons(null, 0, 32)`. The watermark is stored in
SharedPreferences `wasmwatch_native`, key `exit_watermark_ms`. The first run seeds
it to the newest exit (or zero for empty history), without converting history.
Subsequent calls consider strictly newer exits. Skipped exits still advance it.
All reports are persisted before the watermark is committed; retries overwrite
deterministic derived IDs. A `CRASH` is suppressed when the same PID has a
`CRASH_NATIVE` within 2000 ms. A Java crash pairs with the newest eligible handler
report of that PID at/before the exit, within 60 seconds. Unpaired handler reports
remain pending, since a background-thread throw may leave the process running.

ANR input is bounded to 2 MiB; protobuf input to 4 MiB. Invalid/truncated
protobufs return no decoded payload (valid complete prefixes may decode as
partial reports); exit metadata is still saved. The protobuf reader checks
lengths, varints, fixed32/64 widths and nesting (at most eight), and skips unknown
fields. Parsing, JSON, capture state, mapping and storage use plain Kotlin/JVM
classes without Android types. No signal handlers or protobuf dependencies.

## iOS capture and version 1 additions

Flutter registers the iOS bridge automatically. The layout is generated from
Flutter 3.41.2's default iOS plugin template: CocoaPods, iOS 13.0 deployment
minimum, with MetricKit diagnostics guarded by `#available(iOS 14.0, *)`.
The default template does not generate a SwiftPM plugin. `ios/Package.swift`
is a dependency-free macOS XCTest harness for the plain Swift core.

One subscriber per process handles `MXCrashDiagnostic` and `MXHangDiagnostic`
from callbacks and `pastDiagnosticPayloads` at `start`. Reports arriving after
`start` cause a main-thread `reportsAvailable` method-channel notification;
the SDK re-reads pending reports and deduplicates delivery by report ID.
All filesystem work runs on a single serial background queue; replies return
on the main thread. iOS 13 returns no reports and treats scope/ack as no-ops.

The common `v`, `id`, `kind`, identity and optional `scope` fields above apply.
iOS does not use Android's top-level `pid` or `timestamp_ms` fields:

| Field | Meaning |
| --- | --- |
| `kind` | `ios_crash`, `ios_hang`, or `ios_exit_metrics`. |
| `id` | `ios-` plus lowercase SHA-256 of canonical (sorted-key) diagnostic JSON; callback/history delivery has the same ID. Exit metrics additionally hash the payload time window, keeping identical counts on different days distinct. |
| `received_ms` | Unix milliseconds when the plugin received this diagnostic; not an inferred crash time. |
| `payload_begin`, `payload_end` | MetricKit payload time range, Unix milliseconds. |
| `diagnostic` | The individual diagnostic's `jsonRepresentation()` as an object. For exit metrics, the `applicationExitMetrics` object (empty if absent). |
| `app_binaries` | Binary name to absolute app-bundle path, for the main executable and Mach-O framework executables/dylibs. System binaries keep their bare names during conversion. |
| `truncated` | Optional `attributed_stack_only`, `call_stack_dropped` or `metadata_only`, documenting size reduction. |

The store is `Library/Application Support/wasmwatch/pending/<id>.json`, with
32 files, each at most 512 KiB, atomic sibling-temp writes with flush/sync and
rename, and oldest-file eviction. Oversized reports first discard other threads,
then the call-stack tree, retaining metadata and an explicit truncation marker.
A bounded journal of the last 512 IDs prevents replay after acknowledgement when
MetricKit returns recent history again. Unacknowledged files also deduplicate.
The SDK converts `ios_exit_metrics` into one `app_exits` envelope per report,
using the report's release, environment, install ID and UTC payload time window.
`cumulative<Name>ExitCount` counters in foreground/background data become snake_case
reasons; numeric strings and integral numbers are accepted, unknown fields are
ignored, and zero counts are omitted. Empty/zero-only reports are acknowledged
without sending. Exit counts never create events or change sessions (D8).

The normal transport persists these envelopes offline and retries transient
failures. The native report is acknowledged only after server acceptance or a
permanent 4xx other than 429; offline buffering alone does not acknowledge it.
A later launch/notification can resend an unacknowledged report; the server
replaces a resent report per install, so retries do not double count.

The SDK's `test/fixtures/native/ios/exit-metrics.synthetic.json` is a
**synthetic, unverified** fixture, not a device capture. Exit-count JSON and
delivery remain unverified on a device (spike N6). KSCrash is the fallback if
MetricKit delivery proves unreliable.

`start` persists identity in `identity.json`. `setScope` replaces the in-memory
scope immediately and queues its persistence. `scopes.json` retains the latest
scope for each of eight distinct PIDs, together with that scope's start identity.
A diagnostic attaches only the entry matching `diagnosticMetaData.pid`. A missing
PID or no match means no scope/session and the current identity. A diagnostic
received before the first `start` is stored immediately, with missing identity
filled by the first successful `start`; an already attached identity never
changes. A scope sent before `start` is bound to that start's identity.

Crash events use `dart-ios`, signal names before Mach exception names, and the
`ios_metrickit` mechanism. Metadata remains in `contexts.ios_crash`. Attributed
stacks flatten root-first, depth-first: the real abort fixture starts at the
kernel abort and ends at dyld (30 frames, 10 Mach-O images), matching the batch A
contract example exactly. Unknown addresses/UUIDs do not invent evidence.
A matching crash marks the deferred previous session `crashed`; iOS waits for
late delivery up to the existing 30-second fallback. Hangs do not alter sessions.

Hang conversion follows Apple's `MXHangDiagnostic.h` (`hangDuration`, a duration
measurement, and `callStackTree`), tested with a synthetic diagnostic derived from
the crash fixture. **Hang JSON/delivery remains unverified on a device**: the
spike has not received a hang payload yet. The example permits local HTTP and
requests local-network access for a local DSN and command polling.

## Offline development

```sh
export FLUTTER_SUPPRESS_ANALYTICS=true
export GRADLE_USER_HOME="/Volumes/250GB SAMSUNG 970 EVO PLUS /dev-tools/gradle"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
flutter pub get --offline
flutter test --no-pub
flutter analyze --no-pub
cd example
flutter pub get --offline
# Flutter generates the ignored Gradle wrapper on the first Android build.
# If needed, copy an existing local Flutter wrapper before this command.
cd android
./gradlew --offline :wasmwatch_native:testReleaseUnitTest
```

The example uses AGP 8.11.1, Kotlin 2.2.20 and Gradle 8.14. For
`flutter build apk --release --no-pub`, ensure the wrapper passes `--offline` to
Gradle as well (Flutter has no corresponding build flag). On the spike cache,
add `--target-platform android-arm64`: the ARMv7 and x86_64 release engine artifacts
are not cached; the ARM64 APK builds offline. The JVM suite includes
the real ANR/tombstone fixtures, every tombstone truncation and seeded random
byte flips. All test resources are inside this package.

The iOS core's offline XCTest suite can be run without an iOS device:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/wasmwatch-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/wasmwatch-module-cache \
swift test --package-path ios --scratch-path /private/tmp/wasmwatch-swift-tests \
  --cache-path /private/tmp/wasmwatch-swift-cache --disable-sandbox
cd example
flutter pub get --offline
COCOAPODS_DISABLE_STATS=true flutter build ios --release --no-codesign --no-pub
```
