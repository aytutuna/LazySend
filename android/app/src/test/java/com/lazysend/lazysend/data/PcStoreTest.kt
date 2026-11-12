package com.lazysend.lazysend.data

import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class PcStoreTest {
    private val dir = File.createTempFile("pcstore", "").also { it.delete(); it.mkdirs() }
    private val file = File(dir, "pcs.json")
    private val pc = Pc("desktop-0001", "PC", "fp", listOf("10.0.0.2"), 52734, "secret")

    @After
    fun clean() {
        dir.deleteRecursively()
    }

    @Test
    fun keepsPcsAndTheirSecretsAcrossRestarts() {
        val first = PcStore(file, { "sealed:$it" }, { it.removePrefix("sealed:") })
        first.put(pc)

        val again = PcStore(file, { "sealed:$it" }, { it.removePrefix("sealed:") })

        assertEquals(listOf(pc), again.pcs.value)
        assertEquals(first.phoneId, again.phoneId)
    }

    @Test
    fun startsOverWithANewPhoneIdWhenTheSecretsCannotBeOpened() {
        val first = PcStore(file, { "sealed:$it" }, { it.removePrefix("sealed:") })
        first.put(pc)

        // The file was copied to a phone that does not hold the key.
        val moved = PcStore(file, { "sealed:$it" }, { null })

        assertEquals(emptyList<Pc>(), moved.pcs.value)
        assertNotEquals(first.phoneId, moved.phoneId)
        assertEquals(moved.phoneId, PcStore(file, { "sealed:$it" }, { it.removePrefix("sealed:") }).phoneId)
    }
}
