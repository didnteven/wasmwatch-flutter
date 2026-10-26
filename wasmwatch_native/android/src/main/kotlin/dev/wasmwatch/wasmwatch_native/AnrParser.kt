package dev.wasmwatch.wasmwatch_native

internal object AnrParser {
    private val header = Regex("^\"main\".*\\btid=1\\s+(.+)$")
    private val frame = Regex("^\\s+at ([^\\s(]+)\\(([^()]*)\\)\\s*$")
    private val source = Regex("^(.+):([0-9]+)$")

    fun parse(bytes: ByteArray): Obj? {
        if (bytes.size > 2 * 1024 * 1024) return null
        var main: Obj? = null
        val frames = mutableListOf<Obj>()
        var native = 0
        for (line in bytes.toString(Charsets.UTF_8).lineSequence()) {
            if (main == null) {
                val h = header.matchEntire(line) ?: continue
                main = linkedMapOf("name" to "main", "state" to bounded(h.groupValues[1]), "frames" to frames)
                continue
            }
            if (line.startsWith('"')) break
            if (line.trimStart().startsWith("native:")) { native++; continue }
            val m = frame.matchEntire(line) ?: continue
            val method = m.groupValues[1]
            val dot = method.lastIndexOf('.')
            if (dot <= 0 || dot == method.lastIndex || frames.size >= 256) continue
            val f = linkedMapOf<String, Any?>("module" to bounded(method.substring(0, dot)), "function" to bounded(method.substring(dot + 1)))
            val location = m.groupValues[2]
            source.matchEntire(location)?.let {
                val lineno = it.groupValues[2].toLongOrNull()
                if (lineno != null && lineno <= Int.MAX_VALUE) { f["filename"] = bounded(it.groupValues[1]); f["lineno"] = lineno }
            }
            if (location != "Native method" && location != "Unknown Source" && ':' !in location && location.isNotEmpty()) f["filename"] = bounded(location)
            frames.add(f)
        }
        return main?.apply { put("native_frame_count", native) }
    }
}
