package dev.wasmwatch.wasmwatch_native

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class CaptureTest {
    @get:Rule val temp = TemporaryFolder()
    private val identity: Obj get() = linkedMapOf("release" to "r", "environment" to "test", "install_id" to "i")
    private fun store() = PendingStore(temp.newFolder())
    private fun exit(reason: Int, pid: Int = 10, time: Long = 1000) = ExitRecord(pid, time, reason, "description", 6, 100, 12, 13, "app")
    private fun report(id: String = "java-test", time: Long = 950, pid: Int = 10): Obj = linkedMapOf<String, Any?>(
        "v" to 1, "id" to id, "kind" to "java_crash", "timestamp_ms" to time, "pid" to pid,
        "exception" to linkedMapOf("class" to "Test", "frames" to emptyList<Any>())
    ).apply { putAll(identity) }

    @Test fun reasonMappingAndWatermark() {
        for (reason in 0..30) {
            val store = store()
            var watermark = -1L
            ExitProcessor(store).process(listOf(exit(reason)), 0, identity, linkedMapOf("session_id" to "previous")) { watermark = it }
            assertEquals(1000L, watermark)
            val kind = when (reason) { 4 -> "java_crash"; 5 -> "native_crash"; 6 -> "anr"; 3, 7, 9 -> "app_exit"; else -> null }
            if (kind == null) assertTrue(store.reports().isEmpty()) else {
                val report = store.reports().single()
                assertEquals(kind, report["kind"])
                assertEquals("exit-10-1000-$reason", report["id"])
                assertEquals("previous", (report["scope"] as Map<*, *>)["session_id"])
                assertEquals(identity["release"], report["release"])
                val details = report["exit"] as Map<*, *>
                assertEquals(exit(reason).reasonName, details["reason"])
                assertEquals(12L, details["pss_kb"])
            }
        }
    }

    @Test fun firstRunSeedsHistoryEvenWhenEmptyAndDoesNotReadTraces() {
        val store = store()
        val p = ExitProcessor(store)
        var watermark: Long? = null
        p.process(listOf(exit(5).copy(trace = { error("must not read history") }), exit(10, time = 2000)), null, identity, null) { watermark = it }
        assertEquals(2000L, watermark)
        assertTrue(store.reports().isEmpty())
        p.process(emptyList(), null, identity, null) { watermark = it }
        assertEquals(0L, watermark)
        p.process(listOf(exit(4, time = 2000)), 2000, identity, null) { fail("old record") }
        assertTrue(store.reports().isEmpty())
    }

    @Test fun nativeCrashDedupesJavaWithinTwoSecondsOnlyForSamePid() {
        val store = store()
        ExitProcessor(store).process(listOf(exit(4), exit(5, time = 3000), exit(4, pid = 11), exit(4, time = 5001)), 0, identity, null) {}
        assertEquals(setOf("exit-10-3000-5", "exit-11-1000-4", "exit-10-5001-4"), store.reports().map { it["id"] }.toSet())
    }

    @Test fun pairsMostRecentHandlerAndKeepsItsIdentityAndScope() {
        val store = store()
        store.write(report("java-older", 900))
        store.write(report().apply { put("scope", linkedMapOf("session_id" to "handler")); put("release", "old") })
        val p = ExitProcessor(store)
        repeat(2) { p.process(listOf(exit(4)), 0, identity, linkedMapOf("session_id" to "previous")) {} }
        assertEquals(2, store.reports().size)
        val paired = store.reports().single { it["id"] == "java-test" }
        assertNotNull(paired["exit"])
        assertEquals("old", paired["release"])
        assertEquals("handler", (paired["scope"] as Map<*, *>)["session_id"])
        assertNull(store.reports().single { it["id"] == "java-older" }["exit"])
    }

    @Test fun pairingWindowAndUnmatchedHandler() {
        for ((stamp, pid) in listOf(1001L to 10, -59001L to 10, 950L to 11)) {
            val store = store(); store.write(report(time = stamp, pid = pid))
            ExitProcessor(store).process(listOf(exit(4)), 0, identity, null) {}
            assertEquals(2, store.reports().size)
            assertNull(store.reports().single { it["id"] == "java-test" }["exit"])
        }
        val store = store(); store.write(report(time = -59000))
        ExitProcessor(store).process(listOf(exit(4)), 0, identity, null) {}
        assertEquals(1, store.reports().size)
    }

    @Test fun deterministicIdsAndWatermarkAfterWrites() {
        val store = store()
        val p = ExitProcessor(store)
        repeat(2) {
            p.process(listOf(exit(3), exit(6, time = 1100)), 0, identity, null) { value ->
                assertEquals(1100L, value)
                assertEquals(2, store.reports().size)
            }
        }
        assertEquals(2, store.reports().size)
        val badRoot = temp.newFile()
        var advanced = false
        try {
            ExitProcessor(PendingStore(badRoot)).process(listOf(exit(3)), 0, identity, null) { advanced = true }
            fail("write should fail")
        } catch (_: IllegalStateException) { }
        assertFalse(advanced)
    }

    @Test fun boundedAtomicStoreAndSafeAcknowledgements() {
        val root = temp.newFolder()
        val store = PendingStore(root)
        repeat(35) { index ->
            store.write(report("java-$index"))
            File(root, "pending/java-$index.json").setLastModified(1000L + index)
        }
        assertEquals(32, store.reports().size)
        assertFalse(File(root, "pending/java-0.json").exists())
        assertTrue(File(root, "pending").listFiles()!!.all { it.extension == "json" })
        val frames = List(256) { linkedMapOf("module" to "x".repeat(8192), "function" to "y".repeat(8192)) }
        val huge = report().apply { put("exception", linkedMapOf("class" to "E", "frames" to frames)) }
        store.write(huge)
        val file = File(root, "pending/java-test.json")
        assertTrue(file.length() <= PendingStore.MAX_REPORT)
        assertTrue(((Json.objectFrom(file.readText())["exception"] as Map<*, *>)["frames"] as List<*>).isNotEmpty())
        store.write(report().apply { put("thread", "new") })
        assertEquals("new", store.reports().single { it["id"] == "java-test" }["thread"])
        val outside = File(root, "victim.json").apply { writeText("keep") }
        store.ack(listOf("../victim", "java-test", "absent"))
        assertTrue(outside.exists()); assertFalse(file.exists())
        assertTrue(File(root, "pending").listFiles()!!.none { it.extension == "tmp" })
    }

    @Test fun oversizedNativeReportsKeepOnlyImagesOfRetainedFrames() {
        val store = store()
        val frames = List(256) { n -> linkedMapOf<String, Any?>(
            "pc" to "0x1000", "rel_pc" to "0x100", "file_name" to "lib-$n.so",
            "build_id" to "abc$n", "function_name" to "f".repeat(8192)) }
        val images = frames.map { linkedMapOf("file_name" to it["file_name"], "build_id" to it["build_id"], "image_addr" to "0xf00") }
        val report = report("exit-10-1000-5").apply {
            put("kind", "native_crash"); remove("exception")
            put("threads", listOf(linkedMapOf("id" to 10, "name" to "main", "frames" to frames)))
            put("images", images)
        }
        store.write(report)
        val stored = store.reports().single()
        val kept = (((stored["threads"] as List<*>).single() as Map<*, *>)["frames"] as List<*>)
        assertTrue(kept.size < 256)
        assertEquals(kept.size, (stored["images"] as List<*>).size)
        assertEquals(kept.map { (it as Map<*, *>)["file_name"] }.toSet(), (stored["images"] as List<*>).map { (it as Map<*, *>)["file_name"] }.toSet())
    }

    @Test fun backgroundCallsDeferWorkAndReplyIncludingFailures() {
        val work = java.util.ArrayDeque<Runnable>()
        val replies = java.util.ArrayDeque<Runnable>()
        val calls = BackgroundCalls({ work.add(it) }, { replies.add(it) })
        val results = mutableListOf<Any?>()
        calls.run({ results.add("work"); 42 }, { results.add(it) }, { throw it })
        calls.run({ error("failed") }, { fail("unexpected success") }, { results.add(it.message) })
        assertTrue(results.isEmpty())
        work.remove().run()
        assertEquals(listOf("work"), results)
        work.remove().run()
        replies.remove().run()
        replies.remove().run()
        assertEquals(listOf("work", 42, "failed"), results)
    }

    @Test fun scopeIsCapturedBeforeItsQueuedWrite() {
        val store = store()
        val state = CaptureState(store)
        val snapshot = state.setScope("{\"session_id\":\"immediate\"}")
        assertNull(store.readScope())
        state.capture(Thread.currentThread(), Error(), 10, 1000)
        assertEquals("immediate", (store.reports().single()["scope"] as Map<*, *>)["session_id"])
        state.persistScope(snapshot)
        assertEquals("immediate", CaptureState(store).previousScope!!["session_id"])
    }

    @Test fun scopeSnapshotRejectsOversizeAndHandlerIdentitySurvivesRestart() {
        val store = store()
        store.saveScope(linkedMapOf("session_id" to "previous"))
        val state = CaptureState(store)
        state.start(identity)
        state.persistScope(state.setScope("{\"session_id\":\"current\",\"unknown\":[1,true,null]}"))
        assertEquals("previous", state.previousScope!!["session_id"])
        try { state.setScope("{\"data\":\"${"x".repeat(65536)}\"}"); fail("oversize") } catch (_: IllegalArgumentException) {}
        assertEquals("current", store.readScope()!!["session_id"])
        state.capture(Thread("worker"), IllegalStateException("boom"), 42, 1000)
        val report = store.reports().single()
        assertEquals("r", report["release"])
        assertEquals("current", (report["scope"] as Map<*, *>)["session_id"])
        val next = CaptureState(store)
        val nextIdentity = linkedMapOf<String, Any?>("release" to "new", "install_id" to "i")
        next.start(nextIdentity)
        assertEquals("r", Json.objectFrom(next.pending(nextIdentity).single())["release"])
        next.capture(Thread("new worker"), Error(), 43, 2000)
        assertEquals("new", store.reports().single { it["pid"] == 43L }["release"])
    }

    @Test fun deeplyNestedScopeCanStillBeEmbeddedInAReport() {
        val store = store()
        val state = CaptureState(store)
        state.start(identity)
        val scope = "{\"data\":" + "[".repeat(63) + "0" + "]".repeat(63) + "}"
        state.persistScope(state.setScope(scope))
        state.capture(Thread.currentThread(), Error("nested scope"), 10, 1000)
        assertEquals(Json.parse(scope), store.reports().single()["scope"])
        val next = CaptureState(store)
        assertEquals(Json.parse(scope), next.previousScope)
    }

    @Test fun returnedExitReportsKeepTheCrashedProcessIdentityAndScope() {
        val store = store()
        store.write(report("exit-10-1000-4").apply { put("scope", linkedMapOf("old" to true)) })
        val next = linkedMapOf<String, Any?>("release" to "new", "install_id" to "new-i")
        val returned = Json.objectFrom(CaptureState(store).pending(next).single())
        assertEquals("r", returned["release"]); assertEquals("test", returned["environment"])
        assertEquals(true, (returned["scope"] as Map<*, *>)["old"])
    }

    @Test fun exitsAfterAnUpdateUseThePreviousProcessRelease() {
        val store = store()
        CaptureState(store).start(identity)
        val updated = CaptureState(store)
        val next = linkedMapOf<String, Any?>("release" to "new", "install_id" to "i")
        updated.start(next)
        assertEquals("r", updated.previousIdentity!!["release"])
        ExitProcessor(store).process(listOf(exit(5)), 0, updated.previousIdentity!!, null) {}
        assertEquals("r", Json.objectFrom(updated.pending(next).single())["release"])
    }

    @Test fun throwableBoundsUnicodeCycleAndPreviousHandlerAlwaysRuns() {
        var error = IllegalStateException("🐈".repeat(5000))
        repeat(12) { error = IllegalStateException("🐈".repeat(5000), error) }
        error.stackTrace = Array(300) { StackTraceElement("Class", "method", "File.kt", 12) }
        error.addSuppressed(Error("ignored"))
        var chain: Map<*, *>? = JavaCapture.exception(error)
        assertEquals(256, (chain!!["frames"] as List<*>).size)
        var depth = 0
        while (chain != null) {
            depth++
            assertTrue((chain["message"] as String).toByteArray().size <= 8192)
            assertFalse(chain.containsKey("suppressed"))
            chain = chain["cause"] as? Map<*, *>
        }
        assertEquals(8, depth)
        val a = Exception(); val b = Exception(); a.initCause(b); b.initCause(a)
        assertNull(((JavaCapture.exception(a)["cause"] as Map<*, *>)["cause"]))
        var called = false
        val handler = ChainedHandler(Thread.UncaughtExceptionHandler { _, e -> assertSame(error, e); called = true }) { _, _ -> throw OutOfMemoryError() }
        handler.uncaughtException(Thread.currentThread(), error)
        assertTrue(called)
    }

    @Test fun anrRealFixtureAndNativeCount() {
        val parsed = AnrParser.parse(resource("anr.trace.txt"))!!
        assertEquals("main", parsed["name"]); assertEquals("Sleeping", parsed["state"])
        val frames = parsed["frames"] as List<*>
        assertTrue(frames.any { val f = it as Map<*, *>; f["module"] == "D.b" && f["function"] == "k" && f["filename"] == "SourceFile" && f["lineno"] == 119L })
        val synthetic = "\"main\" prio=5 tid=1 Waiting\n  native: #00 pc 123\n  - waiting on lock\n  at broken\n  at C.m(Unknown Source)\n\"worker\" prio=5 tid=2 Runnable\n  at Other.f(File:2)\n"
        val main = AnrParser.parse(synthetic.toByteArray())!!
        assertEquals(1, main["native_frame_count"])
        assertEquals(1, (main["frames"] as List<*>).size)
        assertNull(AnrParser.parse("junk".toByteArray()))
    }

    @Test fun realExitHistoryDropsOnlyTheDuplicateAndAttachesTraces() {
        val records = (Json.parse(resource("exit-reasons.json").toString(Charsets.UTF_8)) as List<*>).map {
            val r = it as Map<*, *>
            val reason = (r["reason"] as Number).toInt()
            ExitRecord((r["pid"] as Number).toInt(), (r["timestamp"] as Number).toLong(), reason,
                r["description"] as? String, (r["status"] as Number).toInt(), (r["importance"] as Number).toInt(),
                (r["pss"] as Number).toLong(), (r["rss"] as Number).toLong(), r["processName"] as? String,
                when (reason) { 5 -> { { resource("abort.tombstone.pb") } }; 6 -> { { resource("anr.trace.txt") } }; else -> null })
        }
        val store = store()
        ExitProcessor(store).process(records, 0, identity, null) {}
        assertEquals(4, store.reports().size)
        assertEquals(2, store.reports().count { it["kind"] == "java_crash" })
        val native = store.reports().single { it["kind"] == "native_crash" }
        assertEquals("SIGABRT", (native["signal"] as Map<*, *>)["name"])
        val anr = store.reports().single { it["kind"] == "anr" }
        assertEquals("main", ((anr["threads"] as List<*>).single() as Map<*, *>)["name"])
    }

    @Test fun restartRecoversStoreBoundsAndAbandonedTemporaryWrites() {
        val root = temp.newFolder()
        val directory = File(root, "pending").apply { mkdirs() }
        repeat(35) { n -> File(directory, "java-$n.json").apply { writeText(Json.encode(report("java-$n"))); setLastModified(1000L + n) } }
        File(directory, ".pending-interrupted.tmp").writeText("partial write")
        val store = PendingStore(root)
        assertEquals(32, store.reports().size)
        assertFalse(File(directory, "java-0.json").exists())
        assertFalse(File(directory, ".pending-interrupted.tmp").exists())
    }

    @Test fun jsonAndBoundedInput() {
        val value = linkedMapOf<String, Any?>("x" to "\"\\\n🐈", "array" to listOf(null, true, 1L, -3.5))
        assertEquals(value, Json.parse(Json.encode(value)))
        for (bad in listOf("{", "[1,]", "1 garbage", "01", "1e999", "\"bad\n\"")) {
            try { Json.parse(bad); fail(bad) } catch (_: Exception) {}
        }
        assertArrayEquals(ByteArray(10), readBounded(ByteArray(10).inputStream(), 10))
        try { readBounded(ByteArray(11).inputStream(), 10); fail("oversize") } catch (_: IllegalArgumentException) {}
    }

    private fun resource(name: String) = javaClass.classLoader!!.getResourceAsStream(name)!!.use { it.readBytes() }
}
