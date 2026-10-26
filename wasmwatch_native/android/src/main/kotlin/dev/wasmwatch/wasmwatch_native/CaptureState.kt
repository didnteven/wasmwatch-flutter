package dev.wasmwatch.wasmwatch_native

import java.util.UUID

/** Shared for the whole process, including engine detach/reattach and background throws. */
internal class CaptureState(val store: PendingStore) {
    // Snapshot before Dart can replace scope. Never re-read it on a later start in this process.
    val previousScope: Obj? = store.readScope()
    // Exit records describe the previous process, which may run an older release than this one.
    val previousIdentity: Obj? = store.readIdentity()
    private var scope = previousScope
    private var identity = previousIdentity

    @Synchronized fun start(identity: Obj) {
        store.saveIdentity(identity)
        this.identity = identity
    }

    @Synchronized fun setScope(json: String): Obj {
        require(json.toByteArray(Charsets.UTF_8).size <= PendingStore.MAX_SCOPE) { "Scope exceeds 64 KiB" }
        // Reserve nesting headroom for embedding the opaque scope inside a report.
        val next = Json.objectFrom(json, maxDepth = 64)
        scope = next
        return next
    }

    @Synchronized fun persistScope(snapshot: Obj) { store.saveScope(snapshot) }

    @Synchronized fun capture(thread: Thread, error: Throwable, pid: Int, now: Long) {
        val report = linkedMapOf<String, Any?>(
            "v" to 1, "id" to "java-${UUID.randomUUID()}", "kind" to "java_crash",
            "timestamp_ms" to now, "pid" to pid, "thread" to bounded(thread.name),
            "exception" to JavaCapture.exception(error)
        )
        identity?.let { report.putAll(it) }
        scope?.let { report["scope"] = it }
        store.write(report)
    }

    @Synchronized fun pending(identity: Obj): List<String> {
        for (report in store.reports()) {
            // Only a crash before the very first start lacks identity; reports keep their own release.
            if (report["release"] == null) {
                report.putAll(identity)
                store.write(report)
            }
        }
        return store.reports().map(Json::encode)
    }
}
