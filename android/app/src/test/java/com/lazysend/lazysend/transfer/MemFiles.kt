package com.lazysend.lazysend.transfer

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicInteger

/** Received files kept in memory; [writeDelayMs] slows each write so a test can catch a transfer half way. */
class MemFiles(private val writeDelayMs: Long = 20) : ReceivedFiles {
    val data = HashMap<String, ByteArrayOutputStream>()
    val created = AtomicInteger()
    val folders = HashMap<String, String>()
    val names = HashMap<String, String>()
    val finished = HashMap<String, Long?>()

    fun seed(bytes: Int): ReceivedFiles.Part {
        val part = create("seed", null)
        append(part).use { it.write(ByteArray(bytes)) }
        return ReceivedFiles.Part(part.uri, bytes.toLong())
    }

    @Synchronized
    override fun existing(uri: String) = data[uri]?.let { ReceivedFiles.Part(uri, it.size().toLong()) }

    @Synchronized
    override fun create(name: String, mime: String?, folder: String): ReceivedFiles.Part {
        val uri = "mem://${created.incrementAndGet()}"
        data[uri] = ByteArrayOutputStream()
        folders[uri] = folder
        names[uri] = name
        return ReceivedFiles.Part(uri, 0)
    }

    override fun append(part: ReceivedFiles.Part): OutputStream = object : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        override fun write(b: ByteArray, off: Int, len: Int) {
            if (writeDelayMs > 0) Thread.sleep(writeDelayMs)
            synchronized(this@MemFiles) { data[part.uri]!!.write(b, off, len) }
        }
    }

    @Synchronized
    override fun finish(part: ReceivedFiles.Part, modified: Long?): String {
        finished[part.uri] = modified
        return part.uri
    }

    @Synchronized
    override fun discard(uri: String) {
        data.remove(uri)
    }

    @Synchronized
    override fun read(uri: String): InputStream = ByteArrayInputStream(data[uri]!!.toByteArray())

    @Synchronized
    fun bytes(uri: String): ByteArray = data[uri]!!.toByteArray()
}
