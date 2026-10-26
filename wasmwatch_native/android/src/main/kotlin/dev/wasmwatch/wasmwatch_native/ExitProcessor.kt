package dev.wasmwatch.wasmwatch_native

/** Snapshot of ApplicationExitInfo, with lazy bounded trace access supplied by Android. */
internal data class ExitRecord(
    val pid: Int, val timestamp: Long, val reason: Int,
    val description: String?, val status: Int, val importance: Int,
    val pssKb: Long, val rssKb: Long, val processName: String?,
    val trace: (() -> ByteArray?)? = null
) {
    val reasonName: String get() = when (reason) {
        0 -> "UNKNOWN"; 1 -> "EXIT_SELF"; 2 -> "SIGNALED"; 3 -> "LOW_MEMORY"
        4 -> "CRASH"; 5 -> "CRASH_NATIVE"; 6 -> "ANR"; 7 -> "INITIALIZATION_FAILURE"
        8 -> "PERMISSION_CHANGE"; 9 -> "EXCESSIVE_RESOURCE_USAGE"; 10 -> "USER_REQUESTED"
        11 -> "USER_STOPPED"; 12 -> "DEPENDENCY_DIED"; 13 -> "OTHER"; 14 -> "FREEZER"
        15 -> "PACKAGE_STATE_CHANGE"; 16 -> "PACKAGE_UPDATED"
        else -> "UNKNOWN"
    }
    fun details(): Obj = linkedMapOf(
        "reason" to reasonName, "description" to description?.let { bounded(it) },
        "status" to status, "importance" to importance, "pss_kb" to pssKb, "rss_kb" to rssKb,
        "timestamp_ms" to timestamp, "process_name" to processName?.let { bounded(it) }
    )
}

internal class ExitProcessor(private val store: PendingStore) {
    /** Persist the watermark only after every write has succeeded, including skipped exits. */
    fun process(records: List<ExitRecord>, watermark: Long?, identity: Obj, previousScope: Obj?, advance: (Long) -> Unit) {
        val newest = records.maxOfOrNull { it.timestamp } ?: (watermark ?: 0L)
        if (watermark == null) { advance(newest); return }
        val fresh = records.filter { it.timestamp > watermark }.sortedBy { it.timestamp }
        for (record in fresh) {
            val kind = when (record.reason) {
                4 -> "java_crash"; 5 -> "native_crash"; 6 -> "anr"
                3, 7, 9 -> "app_exit"
                else -> continue
            }
            if (record.reason == 4 && records.any {
                    it.reason == 5 && it.pid == record.pid && within(it.timestamp, record.timestamp, 2000)
                }) continue
            val paired = if (record.reason == 4) store.reports().filter {
                val stamp = (it["timestamp_ms"] as? Number)?.toLong()
                val exit = it["exit"] as? Map<*, *>
                it["kind"] == "java_crash" && (it["id"] as? String)?.startsWith("java-") == true &&
                    (it["pid"] as? Number)?.toInt() == record.pid && stamp != null && stamp <= record.timestamp &&
                    within(stamp, record.timestamp, 60_000) &&
                    (exit == null || (exit["timestamp_ms"] as? Number)?.toLong() == record.timestamp)
            }.maxByOrNull { (it["timestamp_ms"] as Number).toLong() } else null
            if (paired != null) {
                paired["exit"] = record.details()
                store.write(paired)
                continue
            }
            val report = linkedMapOf<String, Any?>(
                "v" to 1, "id" to "exit-${record.pid}-${record.timestamp}-${record.reason}",
                "kind" to kind, "timestamp_ms" to record.timestamp, "pid" to record.pid,
                "exit" to record.details()
            )
            report.putAll(identity)
            if (previousScope != null) report["scope"] = previousScope
            val trace = try { record.trace?.invoke() } catch (_: Exception) { null }
            if (trace != null) when (record.reason) {
                5 -> TombstoneDecoder.decode(trace)?.let { report.putAll(it) }
                6 -> AnrParser.parse(trace)?.let { report["threads"] = listOf(it) }
            }
            store.write(report)
        }
        if (newest > watermark) advance(newest)
    }

    private fun within(a: Long, b: Long, distance: Long): Boolean =
        if (a >= b) a.toULong() - b.toULong() <= distance.toULong() else b.toULong() - a.toULong() <= distance.toULong()
}
