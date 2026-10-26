package dev.wasmwatch.wasmwatch_native

import java.util.concurrent.Executor

/** Serialize disk/API work and return channel completions to the platform thread. */
internal class BackgroundCalls(private val executor: Executor, private val reply: Executor) {
    fun run(work: () -> Any?, success: (Any?) -> Unit, failure: (Exception) -> Unit) {
        executor.execute {
            try {
                val value = work()
                reply.execute { success(value) }
            } catch (error: Throwable) {
                // Any throwable must still answer the channel call, or Dart would wait forever.
                val failed = error as? Exception ?: RuntimeException(error.toString(), error)
                reply.execute { failure(failed) }
            }
        }
    }
}
