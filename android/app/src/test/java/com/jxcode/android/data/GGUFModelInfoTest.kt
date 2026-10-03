package com.jxcode.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The GGUF header reader, against files this test writes itself.
 *
 * A real model is 2–9 GB and none of it is needed to answer the only question
 * that matters — what window was this trained for — so the fixtures here are a
 * few hundred bytes of header. That also makes it possible to test the cases a
 * real file cannot: a truncated header, a version this reader does not know,
 * and metadata keys placed *after* the enormous tokenizer arrays, which is
 * where a skip that is one byte out of step stops finding anything.
 */
class GGUFModelInfoTest {

    private val typeUint32 = 4L
    private val typeFloat32 = 6L
    private val typeString = 8L
    private val typeArray = 9L

    // MARK: - Fixtures

    private fun string(value: String): ByteArray {
        val bytes = value.toByteArray(Charsets.UTF_8)
        return ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(bytes.size.toLong()).array() + bytes
    }

    private fun uint32(value: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()

    private fun float32(value: Float): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(value).array()

    private fun stringArray(values: List<String>): ByteArray =
        uint32(typeString.toInt()) + u64(values.size.toLong()) + values.fold(ByteArray(0)) { acc, v -> acc + string(v) }

    private fun nestedArray(rows: List<List<String>>): ByteArray =
        uint32(typeArray.toInt()) + u64(rows.size.toLong()) +
            rows.fold(ByteArray(0)) { acc, row -> acc + stringArray(row) }

    private fun u64(value: Long): ByteArray =
        ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array()

    private data class Entry(val key: String, val type: Long, val payload: ByteArray)

    private fun gguf(
        version: Int = 3,
        entries: List<Entry>,
        tensorCount: Long = 0,
        trailer: ByteArray = ByteArray(32)
    ): File {
        val out = ByteArrayOutputStream()
        out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(0x46554747).array())
        out.write(uint32(version))
        out.write(u64(tensorCount))
        out.write(u64(entries.size.toLong()))
        for (entry in entries) {
            out.write(string(entry.key))
            out.write(uint32(entry.type.toInt()))
            out.write(entry.payload)
        }
        out.write(trailer)
        val file = File.createTempFile("jxcode-test-", ".gguf")
        file.deleteOnExit()
        file.writeBytes(out.toByteArray())
        return file
    }

    /** The keys a Llama-architecture file carries, in the order llama.cpp writes them. */
    private fun llamaEntries(): List<Entry> = listOf(
        Entry("general.architecture", typeString, string("llama")),
        Entry("general.name", typeString, string("synthetic-test")),
        Entry("llama.context_length", typeUint32, uint32(32768)),
        Entry("llama.block_count", typeUint32, uint32(32)),
        Entry("general.file_type", typeUint32, uint32(15)),
        Entry("tokenizer.ggml.tokens", typeArray, stringArray(listOf("a", "b", "c", "d"))),
        Entry("tokenizer.ggml.merges", typeArray, stringArray(listOf("a b", "b c"))),
        Entry("synthetic.nested", typeArray, nestedArray(listOf(listOf("x", "y"), listOf("p", "q")))),
        // Deliberately after the arrays: a skip that mis-counts a byte loses
        // exactly these and nothing before them.
        Entry("llama.rope.freq_base", typeFloat32, float32(10000.0f)),
        Entry("general.quantization_version", typeUint32, uint32(2))
    )

    // MARK: - Tests

    @Test
    fun `reads the window the model declares`() {
        val info = GGUFReader.read(gguf(entries = llamaEntries()))!!
        assertEquals("llama", info.architecture)
        assertEquals("synthetic-test", info.name)
        assertEquals(32768, info.contextLength)
        assertEquals(32, info.blockCount)
    }

    @Test
    fun `names the quantisation the way a filename does`() {
        assertEquals("Q4_K_M", GGUFReader.read(gguf(entries = llamaEntries()))!!.quantLabel)
    }

    @Test
    fun `keeps reading keys that sit behind the tokenizer arrays`() {
        // This is the assertion that fails when the structural skip is wrong:
        // every key above the arrays would still parse, and these two would not.
        val keys = GGUFReader.read(gguf(entries = llamaEntries()))!!.allKeys
        assertTrue("rope.freq_base missing: $keys", "llama.rope.freq_base" in keys)
        assertTrue("quantization_version missing: $keys", "general.quantization_version" in keys)
        assertTrue("nested array key missing: $keys", "synthetic.nested" in keys)
    }

    @Test
    fun `namespaces the lookup under the architecture`() {
        // The classic integration bug: a Qwen file stores `qwen2.context_length`,
        // and a reader that hardcodes the `llama.` prefix finds nothing and
        // silently serves a 128k model at the 4096 default.
        val entries = listOf(
            Entry("general.architecture", typeString, string("qwen2")),
            Entry("qwen2.context_length", typeUint32, uint32(131072)),
            Entry("qwen2.block_count", typeUint32, uint32(28))
        )
        val info = GGUFReader.read(gguf(entries = entries))!!
        assertEquals("qwen2", info.architecture)
        assertEquals(131072, info.contextLength)
        assertEquals(28, info.blockCount)
    }

    @Test
    fun `falls back to an unscoped context key when the architecture is unknown`() {
        val entries = listOf(
            Entry("some.newarch.context_length", typeUint32, uint32(4096))
        )
        assertEquals(4096, GGUFReader.read(gguf(entries = entries))!!.contextLength)
    }

    @Test
    fun `reports the projector architecture`() {
        val entries = listOf(
            Entry("general.architecture", typeString, string("clip")),
            Entry("general.name", typeString, string("mmproj-test"))
        )
        val info = GGUFReader.read(gguf(entries = entries))!!
        assertTrue(info.isProjector)
        assertNull(info.contextLength)
    }

    @Test
    fun `refuses a file that is not GGUF`() {
        val file = File.createTempFile("jxcode-test-", ".bin")
        file.deleteOnExit()
        file.writeBytes(ByteArray(64) { 0x41 })
        assertNull(GGUFReader.read(file))
    }

    @Test
    fun `refuses a version it does not understand`() {
        assertNull(GGUFReader.read(gguf(version = 99, entries = llamaEntries())))
    }

    @Test
    fun `survives a header that claims more than the file holds`() {
        // Truncated after the first key: the reader must not hang, and must not
        // invent a context length out of the bytes that happen to follow.
        val out = ByteArrayOutputStream()
        out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(0x46554747).array())
        out.write(uint32(3))
        out.write(u64(0))
        out.write(u64(500))
        out.write(string("general.architecture"))
        out.write(uint32(typeString.toInt()))
        out.write(string("llama"))
        val file = File.createTempFile("jxcode-test-", ".gguf")
        file.deleteOnExit()
        file.writeBytes(out.toByteArray())
        assertNull(GGUFReader.read(file))
    }

    @Test
    fun `summary names the three facts that decide usability`() {
        assertEquals("llama · Q4_K_M · 32768 ctx", GGUFReader.read(gguf(entries = llamaEntries()))!!.summary())
    }

    @Test
    fun `reads a file with no metadata at all`() {
        val info = GGUFReader.read(gguf(entries = emptyList()))!!
        assertNull(info.contextLength)
        assertNull(info.quantLabel)
        assertFalse(info.isProjector)
        assertEquals("unknown", info.summary())
    }
}
