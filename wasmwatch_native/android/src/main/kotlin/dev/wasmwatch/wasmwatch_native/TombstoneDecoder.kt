package dev.wasmwatch.wasmwatch_native

/** Only the AOSP tombstone fields used by v1. Unknown fields are skipped, never guessed. */
internal object TombstoneDecoder {
    const val MAX_INPUT = 4 * 1024 * 1024
    private fun hex(n: Long) = "0x" + java.lang.Long.toUnsignedString(n, 16)

    fun decode(bytes: ByteArray): Obj? = try {
        require(bytes.size <= MAX_INPUT)
        // Validate top-level framing before allocating. Most truncated tombstones stop here.
        val check = Reader(bytes)
        var crashingTid: Long? = null
        while (check.next()) {
            if (check.field == 6) crashingTid = check.number() else check.skip()
        }
        val r = Reader(bytes)
        var tid: Long? = crashingTid
        var arch: Long? = null
        var signal: Obj? = null
        var abort: String? = null
        val threads = linkedMapOf<Long, Obj>()
        val mappings = mutableListOf<Mapping>()
        while (r.next()) when (r.field) {
            1 -> arch = r.number()
            2 -> r.string() // build_fingerprint: verified, not part of the v1 report.
            5 -> r.number() // pid comes from ApplicationExitInfo.
            6 -> tid = r.number()
            10 -> signal = signal(r.child())
            14 -> abort = r.string()
            16 -> {
                val entry = r.child()
                var key: Long? = null
                var thread: Obj? = null
                while (entry.next()) when (entry.field) {
                    1 -> key = entry.number()
                    2 -> thread = thread(entry.child())
                    else -> entry.skip()
                }
                val id = key
                val value = thread
                if (id != null && value != null && (threads.size < 8 || id == tid)) threads[id] = value
            }
            17 -> mappings.add(mapping(r.child()))
            else -> r.skip()
        }
        require(tid != null && signal != null)
        val selected = listOfNotNull(threads[tid]) + threads.filterKeys { it != tid }.values.take(7)
        val images = linkedMapOf<Pair<String, String?>, Obj>()
        for (t in selected) for (f in t["frames"] as List<*>) {
            val frame = f as Map<*, *>
            val file = frame["file_name"] as? String ?: continue
            val build = frame["build_id"] as? String
            val pc = (frame["pc"] as String).removePrefix("0x").toULong(16)
            val rel = (frame["rel_pc"] as String).removePrefix("0x").toULong(16)
            if (pc < rel) continue
            images.getOrPut(file to build) {
                linkedMapOf<String, Any?>("file_name" to file, "image_addr" to hex((pc - rel).toLong())).apply {
                    if (build != null) put("build_id", build)
                    mappings.firstOrNull { m ->
                        m.name == file && m.buildId == build && m.begin != null && m.end != null &&
                            m.end.toULong() > m.begin.toULong() && pc >= m.begin.toULong() && pc < m.end.toULong()
                    }?.let { put("image_size", hex((it.end!!.toULong() - it.begin!!.toULong()).toLong())) }
                }
            }
        }
        linkedMapOf<String, Any?>("threads" to selected, "signal" to signal, "images" to images.values.toList()).apply {
            val name = when (arch) { 0L -> "arm32"; 1L -> "arm64"; 2L -> "x86"; 3L -> "x86_64"; 4L -> "riscv64"; else -> null }
            if (name != null) put("arch", name)
            if (abort != null) put("abort_message", abort)
        }
    } catch (_: Exception) { null }

    private fun signal(r: Reader): Obj {
        val out = linkedMapOf<String, Any?>("number" to 0L, "name" to "", "code" to 0, "code_name" to "")
        var hasFault = false
        var fault = 0L
        while (r.next()) when (r.field) {
            1 -> out["number"] = r.number()
            2 -> out["name"] = r.string()
            3 -> out["code"] = r.number().toInt()
            4 -> out["code_name"] = r.string()
            8 -> hasFault = r.number() != 0L
            9 -> fault = r.number()
            else -> r.skip()
        }
        if (hasFault) out["fault_address"] = hex(fault)
        return out
    }

    private fun thread(r: Reader): Obj {
        val frames = mutableListOf<Obj>()
        val out = linkedMapOf<String, Any?>("frames" to frames)
        while (r.next()) when (r.field) {
            1 -> out["id"] = r.number()
            2 -> out["name"] = r.string()
            4 -> {
                val f = frame(r.child())
                if (f != null && frames.size < 256) frames.add(f)
            }
            else -> r.skip()
        }
        return out
    }

    private fun frame(r: Reader): Obj? {
        // Proto3 omits numeric zeros: a missing rel_pc/pc represents zero.
        var pc = 0L
        var rel = 0L
        val out = linkedMapOf<String, Any?>()
        while (r.next()) when (r.field) {
            1 -> rel = r.number()
            2 -> pc = r.number()
            3, 7 -> r.number()
            4 -> out["function_name"] = r.string()
            5 -> out["function_offset"] = hex(r.number())
            6 -> out["file_name"] = r.string()
            8 -> out["build_id"] = r.string().lowercase(java.util.Locale.ROOT)
            else -> r.skip()
        }
        // An empty message is not evidence of a frame.
        if (pc == 0L && rel == 0L && out.isEmpty()) return null
        out["pc"] = hex(pc); out["rel_pc"] = hex(rel)
        return out
    }

    private data class Mapping(val begin: Long?, val end: Long?, val name: String?, val buildId: String?)
    private fun mapping(r: Reader): Mapping {
        var begin: Long? = null; var end: Long? = null; var name: String? = null; var build: String? = null
        while (r.next()) when (r.field) {
            1 -> begin = r.number()
            2 -> end = r.number()
            3, 4, 5, 6, 9 -> r.number()
            7 -> name = r.string()
            8 -> build = r.string().lowercase(java.util.Locale.ROOT)
            else -> r.skip()
        }
        return Mapping(begin, end, name, build)
    }

    /** No copies for embedded messages. All lengths are checked against their parent. */
    private class Reader(val bytes: ByteArray, var pos: Int = 0, val end: Int = bytes.size, val depth: Int = 0) {
        var field = 0
        private var wire = 0
        fun next(): Boolean {
            if (pos == end) return false
            val tag = varint()
            require(tag > 0 && tag <= 0xffffffffL)
            field = (tag ushr 3).toInt(); wire = (tag and 7).toInt()
            require(field > 0)
            return true
        }
        private fun varint(): Long {
            var result = 0L
            for (i in 0..9) {
                require(pos < end)
                val b = bytes[pos++].toInt() and 255
                if (i == 9) require(b <= 1)
                result = result or ((b and 127).toLong() shl (i * 7))
                if (b < 128) return result
            }
            error("Invalid varint")
        }
        fun number(): Long { require(wire == 0); return varint() }
        private fun length(): Int {
            require(wire == 2)
            val n = varint()
            require(n >= 0 && n <= (end - pos).toLong())
            return n.toInt()
        }
        fun string(): String {
            val n = length()
            val result = bounded(String(bytes, pos, n, Charsets.UTF_8))
            pos += n
            return result
        }
        fun child(): Reader {
            require(depth < 8)
            val n = length()
            return Reader(bytes, pos, pos + n, depth + 1).also { pos += n }
        }
        fun skip() {
            when (wire) {
                0 -> varint()
                1 -> { require(end - pos >= 8); pos += 8 }
                2 -> { val n = length(); pos += n }
                5 -> { require(end - pos >= 4); pos += 4 }
                else -> error("Unsupported protobuf wire type")
            }
        }
    }
}
