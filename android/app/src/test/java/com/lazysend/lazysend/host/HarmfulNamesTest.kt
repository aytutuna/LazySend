package com.lazysend.lazysend.host

import java.io.File
import java.nio.charset.CodingErrorAction
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Reads testdata/harmful-names.json, shared with the Windows and Swift tests. */
class HarmfulNamesTest {
    private fun load() = run {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "testdata/harmful-names.json").exists()) dir = dir.parentFile
        Json.parseToJsonElement(File(dir ?: throw java.io.FileNotFoundException("harmful-names.json"), "testdata/harmful-names.json").readText()).jsonObject
    }

    private fun wellFormed(text: String) = try {
        Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(text))
        true
    } catch (e: java.nio.charset.CharacterCodingException) {
        false
    }

    @Test
    fun everyHarmfulNameComesOutSafe() {
        val data = load()
        val maxBytes = data.getValue("maxFileNameBytes").jsonPrimitive.int
        val failures = mutableListOf<String>()
        for (case in data.getValue("names").jsonArray) {
            val name = case.jsonObject.getValue("name").jsonPrimitive.content
            val clean = cleanFileName(name)
            val label = "\"$name\" became \"$clean\""
            if (clean.isEmpty() || clean.toByteArray().size > maxBytes) failures += "$label: empty or too long"
            if (clean.trim('.').isEmpty()) failures += "$label: only dots"
            if (clean.any { it == '/' || it == '\\' || it == ':' || it < ' ' || it in '\u007F'..'\u009F' }) failures += "$label: a separator or control character is left"
            if (clean.any { it == '\u061c' || it == '\u200e' || it == '\u200f' || it in '\u202a'..'\u202e' || it in '\u2066'..'\u2069' }) failures += "$label: a direction control is left"
            if (clean.endsWith('.') || clean.endsWith(' ')) failures += "$label: ends with a dot or space"
            if (!wellFormed(clean)) failures += "$label: not well-formed"
            case.jsonObject["keep"]?.jsonPrimitive?.content?.let { if (!clean.endsWith(it)) failures += "$label: lost the extension" }
            case.jsonObject["exact"]?.jsonPrimitive?.content?.let { if (clean != it) failures += "$label: expected $it" }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun aHugeNameIsCutInOnePass() {
        val clean = cleanFileName("a".repeat(5_000_000) + ".txt")
        assertTrue(clean.endsWith(".txt") && clean.toByteArray().size <= 240)
    }

    @Test
    fun aLoneSurrogateBecomesAReplacementCharacter() {
        assertEquals("a�b�.txt", cleanFileName("a\uD800b\uDC00.txt"))
    }
}
