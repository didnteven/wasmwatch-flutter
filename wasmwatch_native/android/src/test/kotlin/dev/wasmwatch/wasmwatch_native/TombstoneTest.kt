package dev.wasmwatch.wasmwatch_native

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.Random

class TombstoneTest {
    private fun fixture() = javaClass.classLoader!!.getResourceAsStream("abort.tombstone.pb")!!.use { it.readBytes() }

    @Test fun realTombstoneHasDartAndFlutterFrames() {
        val result = TombstoneDecoder.decode(fixture())!!
        assertEquals("SIGABRT", (result["signal"] as Map<*, *>)["name"])
        assertEquals(-1, (result["signal"] as Map<*, *>)["code"])
        assertEquals("arm64", result["arch"])
        val threads = result["threads"] as List<*>
        assertTrue(threads.size <= 8)
        val crashing = threads.first() as Map<*, *>
        assertEquals(10090L, crashing["id"])
        val frames = crashing["frames"] as List<*>
        val dart = frames.map { it as Map<*, *> }.filter { it["build_id"] == "7a3ef930d1d5a7fd3fa36f070e4eb119" }
        assertTrue(dart.map { it["rel_pc"] }.containsAll(listOf("0x2270b4", "0x226b9c", "0xc15d4")))
        assertTrue(dart.all { (it["file_name"] as String).endsWith("base.apk") })
        assertTrue(frames.any {
            val f = it as Map<*, *>
            (f["file_name"] as? String)?.endsWith("libflutter.so") == true && (f["build_id"] as? String)?.startsWith("fc84702c") == true
        })
        val images = (result["images"] as List<*>).map { it as Map<*, *> }
        assertEquals(images.size, images.map { it["file_name"] to it["build_id"] }.toSet().size)
        assertTrue(images.any { it["build_id"] == "7a3ef930d1d5a7fd3fa36f070e4eb119" })
        assertTrue(images.any { it.containsKey("image_size") })
        for (t in threads) assertTrue(((t as Map<*, *>)["frames"] as List<*>).size <= 256)
    }

    @Test(timeout = 120000) fun everyTruncationAndRandomFlipsAreContained() {
        val bytes = fixture()
        for (n in bytes.indices) TombstoneDecoder.decode(bytes.copyOf(n))
        val random = Random(42)
        repeat(1000) {
            val flipped = bytes.copyOf()
            repeat(1 + random.nextInt(8)) {
                val p = random.nextInt(flipped.size)
                flipped[p] = (flipped[p].toInt() xor (1 shl random.nextInt(8))).toByte()
            }
            TombstoneDecoder.decode(flipped)?.let { result ->
                assertTrue((result["threads"] as List<*>).size <= 8)
                assertTrue(Json.encode(result).length < 8 * 1024 * 1024)
            }
        }
    }

    @Test fun protobufBoundsUnknownFieldsUnsignedAddressesAndMappings() {
        val frame = message(num(1, 0x20), num(2, -16L), str(6, "libtest.so"), str(8, "AB12"))
        val thread = message(num(1, 42), str(2, "crasher"), msg(4, frame))
        val entry = message(num(1, 42), msg(2, thread))
        val signal = message(num(1, 11), str(2, "SIGSEGV"), num(8, 1), num(9, -1))
        val top = message(num(6, 42), msg(10, signal), msg(16, entry),
            byteArrayOf(0xa1.toByte(), 0x06) + ByteArray(8), // unknown field 100, fixed64
            byteArrayOf(0xad.toByte(), 0x06) + ByteArray(4)) // unknown field 101, fixed32
        val result = TombstoneDecoder.decode(top)!!
        val reordered = TombstoneDecoder.decode(message(msg(16, entry), msg(10, signal), num(6, 42)))!!
        assertEquals(42L, ((reordered["threads"] as List<*>).first() as Map<*, *>)["id"])
        assertEquals("0xffffffffffffffff", (result["signal"] as Map<*, *>)["fault_address"])
        val image = (result["images"] as List<*>).single() as Map<*, *>
        assertEquals("0xffffffffffffffd0", image["image_addr"])
        assertEquals("ab12", image["build_id"])
        assertFalse(image.containsKey("image_size"))
        assertNull(TombstoneDecoder.decode(top + byteArrayOf(0x8a.toByte(), 0x06, 0x7f)))
        assertNull(TombstoneDecoder.decode(ByteArray(TombstoneDecoder.MAX_INPUT + 1)))
        assertNull(TombstoneDecoder.decode(ByteArray(12) { 0xff.toByte() }))
        assertNull(TombstoneDecoder.decode(byteArrayOf(0)))
        assertNull(TombstoneDecoder.decode(byteArrayOf(0x53))) // groups unsupported
        val giantThread = message(num(1, 42), *Array(300) { msg(4, frame) })
        val giant = TombstoneDecoder.decode(message(num(6, 42), msg(10, signal), msg(16, message(num(1, 42), msg(2, giantThread)))))!!
        assertEquals(256, (((giant["threads"] as List<*>).single() as Map<*, *>)["frames"] as List<*>).size)
    }

    private fun varint(n: Long): ByteArray {
        var value = n
        return ByteArrayOutputStream().apply {
            while (value and -128L != 0L) { write((value.toInt() and 127) or 128); value = value ushr 7 }
            write(value.toInt())
        }.toByteArray()
    }
    private fun num(field: Int, value: Long) = varint((field * 8).toLong()) + varint(value)
    private fun msg(field: Int, value: ByteArray) = varint((field * 8 + 2).toLong()) + varint(value.size.toLong()) + value
    private fun str(field: Int, value: String) = msg(field, value.toByteArray())
    private fun message(vararg fields: ByteArray) = fields.fold(ByteArray(0)) { acc, bytes -> acc + bytes }
}
