package dev.wasmwatch.wasmwatch_native

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Process
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class WasmWatchNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var state: CaptureState
    private val mainHandler = Handler(Looper.getMainLooper())
    private val calls = BackgroundCalls(processExecutor) { task -> mainHandler.post(task) }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        synchronized(processLock) {
            val shared = processState ?: CaptureState(PendingStore(File(context.filesDir, "wasmwatch"))).also { processState = it }
            state = shared
            if (!handlerInstalled) {
                val previous = Thread.getDefaultUncaughtExceptionHandler()
                Thread.setDefaultUncaughtExceptionHandler(ChainedHandler(previous) { thread, error ->
                    shared.capture(thread, error, Process.myPid(), System.currentTimeMillis())
                })
                handlerInstalled = true
            }
        }
        channel = MethodChannel(binding.binaryMessenger, "wasmwatch/native")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> calls.run({
                    val release = call.argument<String>("release") ?: error("release required")
                    val installId = call.argument<String>("install_id") ?: error("install_id required")
                    val identity = linkedMapOf<String, Any?>("release" to release, "install_id" to installId)
                    call.argument<String>("environment")?.let { identity["environment"] = it }
                    state.start(identity)
                    if (Build.VERSION.SDK_INT >= 30) collectExits(identity)
                    state.pending(identity)
                }, result::success) { error -> result.error("wasmwatch_native", error.message, null) }
                "setScope" -> {
                    val snapshot = state.setScope(call.arguments as String)
                    calls.run({ state.persistScope(snapshot); null }, result::success) { error ->
                        result.error("wasmwatch_native", error.message, null)
                    }
                }
                "ack" -> calls.run({
                    val ids = call.arguments as? List<*> ?: error("ids required")
                    state.store.ack(ids.map { it as String }); null
                }, result::success) { error -> result.error("wasmwatch_native", error.message, null) }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("wasmwatch_native", error.message, null)
        }
    }

    @android.annotation.TargetApi(30)
    private fun collectExits(identity: Obj) {
        val preferences = context.getSharedPreferences("wasmwatch_native", Context.MODE_PRIVATE)
        val key = "exit_watermark_ms"
        val watermark = if (preferences.contains(key)) preferences.getLong(key, 0) else null
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val records = manager.getHistoricalProcessExitReasons(null, 0, 32).map { info ->
            ExitRecord(info.pid, info.timestamp, info.reason, info.description, info.status, info.importance,
                info.pss, info.rss, info.processName,
                if (info.reason == ApplicationExitInfo.REASON_ANR ||
                    info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE && Build.VERSION.SDK_INT >= 31) {
                    { readTrace(info) }
                } else null)
        }
        ExitProcessor(state.store).process(records, watermark, state.previousIdentity ?: identity, state.previousScope) { value ->
            check(preferences.edit().putLong(key, value).commit()) { "Cannot persist exit watermark" }
        }
    }

    @android.annotation.TargetApi(30)
    private fun readTrace(info: ApplicationExitInfo): ByteArray? = try {
        val limit = if (info.reason == ApplicationExitInfo.REASON_ANR) 2 * 1024 * 1024 else TombstoneDecoder.MAX_INPUT
        info.traceInputStream?.use { readBounded(it, limit) }
    } catch (_: Exception) { null }

    companion object {
        private val processExecutor = Executors.newSingleThreadExecutor()
        private val processLock = Any()
        private var processState: CaptureState? = null
        private var handlerInstalled = false
    }
}
