package dev.wasmwatch.wasmwatch_native

import java.io.File
import java.io.FileOutputStream

/** The pending directory is the only report queue. All operations share this lock. */
internal class PendingStore(private val root: File) {
    private val pending = File(root, "pending")

    init {
        // A process may have died after rename and before eviction. Recover that bound.
        evict()
        pending.listFiles()?.filter { it.name.startsWith(".pending-") && it.extension == "tmp" }?.forEach { it.delete() }
    }

    private fun evict() {
        files().sortedWith(compareBy<File> { it.lastModified() }.thenBy { it.name })
            .dropLast(MAX_FILES).forEach { check(it.delete()) { "Cannot evict pending report" } }
    }

    @Synchronized fun reports(): List<Obj> = files().mapNotNull { file ->
        try { if (file.length() > MAX_REPORT) null else Json.objectFrom(file.readText(Charsets.UTF_8)) }
        catch (_: Exception) { null }
    }

    @Synchronized fun write(report: Obj) {
        val id = report["id"] as String
        require(validId(id))
        val bytes = fitReport(report)
        atomicWrite(File(pending, "$id.json"), bytes)
        evict()
    }

    @Synchronized fun ack(ids: List<String>) {
        ids.filter(::validId).forEach { id ->
            val file = File(pending, "$id.json")
            check(!file.exists() || file.delete()) { "Cannot acknowledge report" }
        }
    }

    @Synchronized fun readScope(): Obj? = readObject("scope.json", MAX_SCOPE)
    @Synchronized fun readIdentity(): Obj? = readObject("identity.json", MAX_SCOPE)
    @Synchronized fun saveScope(scope: Obj) = saveObject("scope.json", scope)
    @Synchronized fun saveIdentity(identity: Obj) = saveObject("identity.json", identity)

    private fun readObject(name: String, limit: Int): Obj? = try {
        val file = File(root, name)
        if (file.length() > limit) null else Json.objectFrom(file.readText(Charsets.UTF_8))
    } catch (_: Exception) { null }

    private fun saveObject(name: String, value: Obj) {
        val bytes = Json.encode(value).toByteArray(Charsets.UTF_8)
        require(bytes.size <= MAX_SCOPE) { "Scope or identity exceeds 64 KiB" }
        atomicWrite(File(root, name), bytes)
    }

    private fun files(): List<File> = pending.listFiles()?.filter { it.isFile && it.name.endsWith(".json") } ?: emptyList()

    companion object {
        const val MAX_REPORT = 512 * 1024
        const val MAX_SCOPE = 64 * 1024
        const val MAX_FILES = 32
        private fun validId(id: String) = id.length in 1..160 && id.all { it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' }

        fun atomicWrite(file: File, bytes: ByteArray) {
            check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
            val temp = File.createTempFile(".pending-", ".tmp", file.parentFile)
            try {
                FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
                check(temp.renameTo(file)) { "Atomic rename failed" }
            } finally { temp.delete() }
        }

        /** Shrink frames first; leave the opaque, already bounded scope untouched. */
        private fun fitReport(report: Obj): ByteArray {
            var limit = 8192
            var frames = 256
            while (true) {
                val trimmed = trim(report, limit, frames) as Map<*, *>
                val fitted = pruneImages(trimmed)
                val bytes = Json.encode(fitted).toByteArray(Charsets.UTF_8)
                if (bytes.size <= MAX_REPORT) return bytes
                if (frames > 1) frames /= 2
                else if (limit > 64) limit /= 2
                else error("Report cannot fit")
            }
        }

        /** Frame truncation must also drop images no longer represented by a frame. */
        private fun pruneImages(report: Map<*, *>): Map<*, *> {
            val images = report["images"] as? List<*> ?: return report
            val pairs = (report["threads"] as? List<*>).orEmpty().flatMap { t ->
                ((t as? Map<*, *>)?.get("frames") as? List<*>).orEmpty()
            }.mapNotNull { f ->
                val frame = f as? Map<*, *> ?: return@mapNotNull null
                val name = frame["file_name"] as? String ?: return@mapNotNull null
                name to frame["build_id"]
            }.toSet()
            return report.toMutableMap().apply {
                put("images", images.filter { it is Map<*, *> && (it["file_name"] to it["build_id"]) in pairs }
                    .distinctBy { val image = it as Map<*, *>; image["file_name"] to image["build_id"] })
            }
        }

        private fun trim(value: Any?, limit: Int, frames: Int): Any? = when (value) {
            is Map<*, *> -> value.entries.associate { (k, v) ->
                k to when (k) {
                    "scope", "id", "release", "environment", "install_id" -> v
                    "frames" -> (v as? List<*>)?.take(frames)?.map { trim(it, limit, frames) }
                    else -> trim(v, limit, frames)
                }
            }
            is List<*> -> value.map { trim(it, limit, frames) }
            is String -> bounded(value, limit)
            else -> value
        }
    }
}
