package dev.wasmwatch.wasmwatch_native

import java.io.InputStream

internal typealias Obj = MutableMap<String, Any?>

/** Small JSON codec shared by disk storage and the JVM tests. No Android stubs. */
internal object Json {
    fun encode(value: Any?): String = buildString { appendValue(value, 0) }

    private fun StringBuilder.appendValue(value: Any?, depth: Int) {
        require(depth <= 96) { "JSON nesting too deep" }
        when (value) {
            null -> append("null")
            is String -> {
                append('"')
                for (c in value) when (c) {
                    '"' -> append("\\\"")
                    '\\' -> append("\\\\")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    else -> if (c < ' ' || c.isSurrogate()) append("\\u%04x".format(c.code)) else append(c)
                }
                append('"')
            }
            is Boolean -> append(value)
            is Number -> { require(value.toDouble().isFinite()); append(value) }
            is Map<*, *> -> {
                append('{')
                value.entries.forEachIndexed { i, entry ->
                    require(entry.key is String)
                    if (i > 0) append(',')
                    appendValue(entry.key, depth + 1); append(':'); appendValue(entry.value, depth + 1)
                }
                append('}')
            }
            is List<*> -> {
                append('[')
                value.forEachIndexed { i, item -> if (i > 0) append(','); appendValue(item, depth + 1) }
                append(']')
            }
            else -> error("Not JSON")
        }
    }

    fun parse(text: String, maxDepth: Int = 96): Any? = Parser(text, maxDepth).run { val result = value(0); space(); require(pos == text.length); result }
    @Suppress("UNCHECKED_CAST")
    fun objectFrom(text: String, maxDepth: Int = 96): Obj = (parse(text, maxDepth) as? MutableMap<String, Any?>) ?: error("Expected object")

    private class Parser(val text: String, val maxDepth: Int) {
        var pos = 0
        fun space() { while (pos < text.length && text[pos] in " \r\n\t") pos++ }
        fun take(c: Char): Boolean { space(); return if (pos < text.length && text[pos] == c) { pos++; true } else false }
        fun value(depth: Int): Any? {
            require(depth <= maxDepth); space(); require(pos < text.length)
            return when (text[pos]) {
                '{' -> {
                    pos++; val result = linkedMapOf<String, Any?>()
                    if (!take('}')) { do { space(); val key = string(); require(take(':')); result[key] = value(depth + 1) } while (take(',')); require(take('}')) }
                    result
                }
                '[' -> {
                    pos++; val result = mutableListOf<Any?>()
                    if (!take(']')) { do { result.add(value(depth + 1)) } while (take(',')); require(take(']')) }
                    result
                }
                '"' -> string()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> {
                    val start = pos
                    while (pos < text.length && text[pos] in "-+0123456789.eE") pos++
                    val s = text.substring(start, pos)
                    require(NUMBER.matches(s))
                    s.toLongOrNull() ?: s.toDouble().also { require(it.isFinite()) }
                }
            }
        }
        fun literal(word: String, result: Any?): Any? { require(text.startsWith(word, pos)); pos += word.length; return result }
        fun string(): String {
            require(pos < text.length && text[pos++] == '"')
            return buildString {
                while (true) {
                    require(pos < text.length)
                    val c = text[pos++]
                    if (c == '"') break
                    require(c >= ' ')
                    if (c != '\\') append(c) else {
                        require(pos < text.length)
                        append(when (val escaped = text[pos++]) {
                            '"', '\\', '/' -> escaped
                            'b' -> '\b'; 'f' -> '\u000c'; 'n' -> '\n'; 'r' -> '\r'; 't' -> '\t'
                            'u' -> { require(pos + 4 <= text.length); text.substring(pos, pos + 4).toInt(16).toChar().also { pos += 4 } }
                            else -> error("Invalid escape")
                        })
                    }
                }
            }
        }
    }
    private val NUMBER = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")
}

/** Limits UTF-8 bytes, without splitting a Unicode code point. */
internal fun bounded(text: String, bytes: Int = 8192): String {
    if (text.length <= bytes / 3) return text
    var end = 0
    var size = 0
    while (end < text.length) {
        val c = text.codePointAt(end)
        val count = when { c < 0x80 -> 1; c < 0x800 -> 2; c < 0x10000 -> 3; else -> 4 }
        if (size + count > bytes) break
        size += count; end += Character.charCount(c)
    }
    return text.substring(0, end)
}

internal fun readBounded(input: InputStream, limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (true) {
        val n = input.read(buffer, 0, minOf(buffer.size, limit + 1 - out.size()))
        if (n < 0) return out.toByteArray()
        if (n == 0) continue
        out.write(buffer, 0, n)
        require(out.size() <= limit) { "Trace too large" }
    }
}
