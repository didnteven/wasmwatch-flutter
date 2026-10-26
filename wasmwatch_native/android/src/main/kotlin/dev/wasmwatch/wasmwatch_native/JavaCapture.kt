package dev.wasmwatch.wasmwatch_native

import java.util.Collections
import java.util.IdentityHashMap

internal object JavaCapture {
    fun exception(error: Throwable): Obj {
        val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
        fun capture(t: Throwable, depth: Int): Obj {
            seen.add(t)
            return linkedMapOf<String, Any?>(
                "class" to bounded(t.javaClass.name),
                "frames" to t.stackTrace.take(256).map { frame ->
                    linkedMapOf<String, Any?>("module" to bounded(frame.className), "function" to bounded(frame.methodName)).apply {
                        frame.fileName?.let { put("filename", bounded(it)) }
                        if (frame.lineNumber >= 0) put("lineno", frame.lineNumber)
                    }
                }
            ).apply {
                t.message?.let { put("message", bounded(it)) }
                t.cause?.takeIf { depth < 8 && !seen.contains(it) }?.let { put("cause", capture(it, depth + 1)) }
            }
        }
        return capture(error, 1)
    }
}

/** Failure to capture must never prevent the runtime's previous handler running. */
internal class ChainedHandler(
    private val previous: Thread.UncaughtExceptionHandler?,
    private val capture: (Thread, Throwable) -> Unit
) : Thread.UncaughtExceptionHandler {
    override fun uncaughtException(thread: Thread, error: Throwable) {
        try { capture(thread, error) } catch (_: Throwable) { /* Best effort on a crashing process. */ }
        finally { previous?.uncaughtException(thread, error) }
    }
}
