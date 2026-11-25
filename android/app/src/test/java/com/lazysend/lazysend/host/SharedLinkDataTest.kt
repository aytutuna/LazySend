package com.lazysend.lazysend.host

import com.lazysend.lazysend.link.ApiError
import com.lazysend.lazysend.link.DataSource
import com.lazysend.lazysend.link.Hello
import com.lazysend.lazysend.link.ItemRequest
import com.lazysend.lazysend.link.ItemState
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.LinkJson
import com.lazysend.lazysend.link.OutboxReply
import com.lazysend.lazysend.link.PairRequest
import com.lazysend.lazysend.link.PairResponse
import com.lazysend.lazysend.link.PairingCode
import com.lazysend.lazysend.link.PairingCodeException
import java.io.ByteArrayInputStream
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Reads testdata/link, the phone link's shared test data, and checks this code base against every case in it. */
class SharedLinkDataTest {
    private fun load(file: String): JsonObject {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "testdata/link/$file").exists()) dir = dir.parentFile
        return Json.parseToJsonElement(File(dir ?: throw java.io.FileNotFoundException(file), "testdata/link/$file").readText()).jsonObject
    }

    private fun JsonObject.str(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonObject.array(name: String): JsonArray = getValue(name).jsonArray
    private fun JsonElement.text(): String? = (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    private fun noFailures(failures: List<String>) = assertTrue(failures.joinToString("\n"), failures.isEmpty())

    private fun pattern(from: Long, to: Long) = ByteArray((to - from).toInt()) { ((from + it) % 251).toByte() }

    private fun hex(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Test
    fun pairingCodesAreReadAsTheDataSays() {
        val failures = ArrayList<String>()
        for (c in load("pairing-uris.json").array("cases").map { it.jsonObject }) {
            val name = c.str("name")
            val result = c.str("result")!!
            val read = try {
                PairingCode.parse(c.str("uri")!!)
            } catch (e: PairingCodeException) {
                if (!e.problem.name.equals(result, ignoreCase = true)) failures.add("$name: expected $result, got ${e.problem}")
                continue
            }
            if (result != "ok") {
                failures.add("$name: expected $result, got a code")
                continue
            }
            val p = c.getValue("pairing").jsonObject
            val same = read.desktopId == p.str("desktopId") && read.name == p.str("name") && read.fingerprint == p.str("fingerprint") &&
                read.port == p.getValue("port").jsonPrimitive.int && read.token == p.str("token") &&
                read.addresses == p.array("addresses").map { it.text() } && read.checkCode == p.str("checkCode")
            if (!same) failures.add("$name: the parts differ")
        }
        noFailures(failures)
    }

    @Test
    fun checkCodesMatch() {
        for (c in load("check-codes.json").array("cases").map { it.jsonObject }) {
            val fingerprint = c.array("fingerprint").map { it.jsonPrimitive.int.toByte() }.toByteArray()
            assertEquals(c.str("checkCode"), Fingerprint.spaced(Fingerprint.checkCode(fingerprint)))
            assertEquals(c.str("matchCode"), Fingerprint.spaced(Fingerprint.matchCode(fingerprint, c.str("shortCode")!!)))
        }
    }

    @Test
    fun shortCodesAreReadAndRedeemedAsTheDataSays() {
        val data = load("short-codes.json")
        val failures = ArrayList<String>()
        for (n in data.array("normalize").map { it.jsonObject }) {
            val typed = n.str("typed")
            if (PairingSession.normalizeShortCode(typed) != n.str("canonical")) failures.add("normalize \"$typed\": expected ${n.str("canonical")}")
        }
        val token = data.array("tokenBytes").map { it.jsonPrimitive.int.toByte() }.toByteArray()
        for (r in data.array("redeem").map { it.jsonObject }) {
            val session = PairingSession(0, token)
            val typed = session.shortCode.take(4).lowercase() + "-" + session.shortCode.drop(4).lowercase()
            for ((step, a) in r.array("attempts").map { it.jsonObject }.withIndex()) {
                val presented = when (val t = a.str("token")) {
                    "\$token" -> session.tokenText
                    "\$shortCode" -> session.shortCode
                    "\$shortCodeTyped" -> typed
                    else -> t
                }
                val got = session.redeem(presented, a.getValue("at").jsonPrimitive.long * 1000, a.str("peer")!!)
                if (!got.name.equals(a.str("expect"), ignoreCase = true)) {
                    failures.add("${r.str("name")}, attempt ${step + 1}: expected ${a.str("expect")}, got $got")
                }
            }
        }
        noFailures(failures)
    }

    private fun fields(type: String, body: String): Map<String, Any?> = when (type) {
        "PairRequest" -> LinkJson.decodeFromString<PairRequest>(body).let {
            mapOf("token" to it.token, "phoneId" to it.phoneId, "phoneName" to it.phoneName, "platform" to it.platform, "appVersion" to it.appVersion)
        }
        "PairResponse" -> LinkJson.decodeFromString<PairResponse>(body).let {
            mapOf("protocolVersion" to it.protocolVersion, "desktopId" to it.desktopId, "desktopName" to it.desktopName, "deviceSecret" to it.deviceSecret)
        }
        "Hello" -> LinkJson.decodeFromString<Hello>(body).let {
            mapOf("protocolVersion" to it.protocolVersion, "desktopId" to it.desktopId, "desktopName" to it.desktopName, "maxChunkBytes" to it.maxChunkBytes, "addresses" to it.addresses)
        }
        "ItemRequest" -> LinkJson.decodeFromString<ItemRequest>(body).let {
            mapOf(
                "kind" to it.kind, "text" to it.text, "url" to it.url, "name" to it.name, "size" to it.size, "mime" to it.mime,
                "sourceId" to it.sourceId, "sha256" to it.sha256, "sendId" to it.sendId, "clip" to it.clip,
            )
        }
        "ItemState" -> LinkJson.decodeFromString<ItemState>(body).let {
            mapOf("id" to it.id, "offset" to it.offset, "done" to it.done, "duplicate" to it.duplicate)
        }
        "OutboxReply" -> LinkJson.decodeFromString<OutboxReply>(body).let {
            mapOf(
                "ids" to it.items.map { i -> i.id }, "kinds" to it.items.map { i -> i.kind }, "more" to (it.more ?: false),
                "firstText" to it.items.getOrNull(0)?.text, "firstClip" to it.items.getOrNull(0)?.clip,
                "secondUrl" to it.items.getOrNull(1)?.url, "thirdName" to it.items.getOrNull(2)?.name, "thirdSize" to it.items.getOrNull(2)?.size,
            )
        }
        "ApiError" -> LinkJson.decodeFromString<ApiError>(body).let {
            mapOf("error" to it.error, "message" to it.message, "offset" to it.offset)
        }
        else -> throw IllegalArgumentException(type)
    }

    private fun matches(expected: JsonElement, actual: Any?): Boolean = when {
        expected is JsonNull -> actual == null
        expected is JsonArray -> actual is List<*> && actual == expected.map { it.text() }
        expected is JsonPrimitive && expected.isString -> actual == expected.content
        expected is JsonPrimitive && (expected.content == "true" || expected.content == "false") -> actual == expected.boolean
        expected is JsonPrimitive -> actual is Number && actual.toLong() == expected.long
        else -> false
    }

    @Test
    fun messagesAreReadAsTheDataSays() {
        val data = load("messages.json")
        val failures = ArrayList<String>()
        for (c in data.array("cases").map { it.jsonObject }) {
            val name = c.str("name")
            try {
                val read = fields(c.str("type")!!, c.getValue("json").toString())
                for ((key, value) in c.getValue("expect").jsonObject) {
                    if (!read.containsKey(key) || !matches(value, read[key])) failures.add("$name: $key is ${read[key]}, expected $value")
                }
            } catch (e: kotlinx.serialization.SerializationException) {
                failures.add("$name: not read")
            }
        }
        for (c in data.array("invalid").map { it.jsonObject }) {
            try {
                fields(c.str("type")!!, c.str("body")!!)
                failures.add("${c.str("name")}: read although it is not valid")
            } catch (e: kotlinx.serialization.SerializationException) {
            } catch (e: IllegalArgumentException) {
            }
        }
        noFailures(failures)
    }

    @Test
    fun namesAndIdsAreMadeSafeAsTheDataSays() {
        val data = load("names.json")
        val maxBytes = data.getValue("maxFileNameBytes").jsonPrimitive.int
        val failures = ArrayList<String>()
        for (c in data.array("cleanFileName").map { it.jsonObject }) {
            val name = c.str("name")
            val clean = cleanFileName(name)
            val label = "\"$name\" became \"$clean\""
            if (clean.isEmpty() || clean.toByteArray().size > maxBytes) failures.add("$label: empty or too long")
            if (clean.any { it == '/' || it == '\\' || it == ':' || it < ' ' || it in '\u007F'..'\u009F' }) failures.add("$label: a separator or control character is left")
            if (clean.endsWith(".") || clean.endsWith(" ")) failures.add("$label: ends with a dot or space")
            if (!wellFormed(clean)) failures.add("$label: not well-formed text")
            c.str("keep")?.let { if (!clean.endsWith(it)) failures.add("$label: lost $it") }
            c.str("exact")?.let { if (clean != it) failures.add("$label: expected $it") }
        }
        for (id in data.array("validIds")) if (!isValidId(id.text())) failures.add("id $id refused")
        for (id in data.array("invalidIds")) if (isValidId(id.text())) failures.add("id $id accepted")
        noFailures(failures)
    }

    private fun wellFormed(text: String): Boolean {
        var i = 0
        while (i < text.length) {
            if (Character.isHighSurrogate(text[i]) && i + 1 < text.length && Character.isLowSurrogate(text[i + 1])) i++ else if (Character.isSurrogate(text[i])) return false
            i++
        }
        return true
    }

    @Test
    fun largeFileIsDescribedByItsSizeAndFingerprint() {
        val data = load("large-file.json")
        val size = data.getValue("size").jsonPrimitive.long
        val sha = MessageDigest.getInstance("SHA-256")
        var at = 0L
        while (at < size) {
            val to = minOf(size, at + (1 shl 20))
            sha.update(pattern(at, to))
            at = to
        }
        assertEquals(data.str("sha256"), sha.digest().joinToString("") { "%02x".format(it) })
    }

    @Test
    fun sessionsRunAsTheDataSays() {
        val data = load("sessions.json")
        val large = load("large-file.json")
        for (c in data.array("cases").map { it.jsonObject }) {
            if (c["readers"]?.jsonArray?.none { it.text() == "kotlin" } == true) continue
            HostFixture().use { host ->
                val run = Session(host, large)
                for ((step, s) in c.array("steps").map { it.jsonObject }.withIndex()) {
                    try {
                        run.step(s)
                    } catch (e: AssertionError) {
                        throw AssertionError("${c.str("name")}, step ${step + 1} (${s.str("op")}): ${e.message}", e)
                    }
                }
            }
        }
    }

    private inner class Session(private val host: HostFixture, private val large: JsonObject) {
        private val credentials = host.pair()
        private val client = host.client(credentials)
        private val received = ArrayList<Pair<String, String>>()
        private var id = ""
        private var size = 0L
        private var offset = 0L
        private var settled = 0L
        private var polled = ArrayList<String>()

        init {
            host.core.router.onText = { _, kind, text, _ -> received.add(kind to text) }
        }

        private fun sizeOf(content: JsonElement) = if (content is JsonPrimitive) large.getValue("size").jsonPrimitive.long else content.jsonObject.getValue("size").jsonPrimitive.long

        private fun checkState(expect: JsonObject, state: ItemState) {
            expect["offset"]?.let { assertEquals(it.jsonPrimitive.long, state.offset) }
            expect["done"]?.let { assertEquals(it.jsonPrimitive.boolean, state.done) }
        }

        private fun source(bytes: ByteArray) = DataSource { ByteArrayInputStream(bytes) }

        private fun put(from: Long, to: Long): ItemState = runBlocking { client.putChunk(id, from, to - from, source(pattern(from, to))) }

        private fun expectError(s: JsonObject, block: () -> Unit) {
            try {
                block()
            } catch (e: LinkException) {
                assertEquals(s.getValue("status").jsonPrimitive.int, e.status)
                assertEquals(s.str("code"), e.code)
                s["offset"]?.let { assertEquals(it.jsonPrimitive.long, e.offset) }
                return
            }
            fail("expected ${s.str("code")}")
        }

        fun step(s: JsonObject) {
            when (val op = s.str("op")) {
                "begin" -> {
                    val content = s.getValue("content")
                    size = sizeOf(content)
                    val sha = when {
                        s["hash"] != null -> if (content is JsonPrimitive) large.str("sha256") else hex(pattern(0, size))
                        s["hashOfOther"] != null -> hex("other".toByteArray())
                        else -> null
                    }
                    val state = runBlocking { client.postItem(ItemRequest("file", name = s.str("name"), size = size, sha256 = sha)) }
                    id = state.id
                    offset = state.offset
                    checkState(s.getValue("expect").jsonObject, state)
                }
                "put" -> {
                    val state = put(s.getValue("from").jsonPrimitive.long, s.getValue("to").jsonPrimitive.long)
                    offset = state.offset
                    checkState(s.getValue("expect").jsonObject, state)
                }
                "putAll" -> {
                    val chunk = s.getValue("chunk").jsonPrimitive.long
                    var last: ItemState? = null
                    while (offset < size) {
                        last = put(offset, minOf(size, offset + chunk))
                        offset = last.offset
                    }
                    checkState(s.getValue("expect").jsonObject, last!!)
                }
                "putError" -> expectError(s) { put(s.getValue("from").jsonPrimitive.long, s.getValue("to").jsonPrimitive.long) }
                "drop" -> {
                    val at = s.getValue("offset").jsonPrimitive.long
                    val sent = pattern(at, at + s.getValue("sent").jsonPrimitive.long)
                    host.raw(
                        "PUT /v1/items/$id/data HTTP/1.1\r\nHost: x\r\nX-Device-Id: ${credentials.deviceId}\r\nAuthorization: Bearer ${credentials.secret}\r\n" +
                            "X-Offset: $at\r\nContent-Length: ${s.getValue("declared").jsonPrimitive.long}\r\n\r\n" + String(sent, Charsets.ISO_8859_1),
                    ) { it.close() }
                }
                "settle" -> {
                    var last = -1L
                    runBlocking {
                        for (i in 0 until 100) {
                            val now = client.itemState(id).offset
                            if (now == last) break
                            last = now
                            delay(150)
                        }
                    }
                    val between = s.array("between")
                    assertTrue("$last is not between ${between[0]} and ${between[1]}", last in between[0].jsonPrimitive.long..between[1].jsonPrimitive.long)
                    settled = last
                }
                "resume" -> checkState(s.getValue("expect").jsonObject, put(settled, size))
                "state" -> checkState(s.getValue("expect").jsonObject, runBlocking { client.itemState(id) })
                "stateError" -> expectError(s) { runBlocking { client.itemState(id) } }
                "expectFile" -> {
                    val name = s.str("name")
                    val uri = host.files.data.keys.single { host.files.names[it] == name }
                    val bytes = host.files.bytes(uri)
                    assertEquals("Test phone", host.files.folders[uri])
                    val content = s.getValue("content")
                    if (content is JsonPrimitive) assertEquals(large.str("sha256"), hex(bytes)) else assertTrue(pattern(0, content.jsonObject.getValue("size").jsonPrimitive.long).contentEquals(bytes))
                }
                "expectNoFile" -> assertTrue(host.files.data.keys.none { host.files.names[it] == s.str("name") })
                "post" -> {
                    val kind = s.str("kind")!!
                    runBlocking { client.postItem(if (kind == "text") ItemRequest("text", text = s.str("text")) else ItemRequest("link", url = s.str("url"))) }
                }
                "expectReceived" -> assertEquals(s.array("items").map { it.jsonArray[0].text()!! to it.jsonArray[1].text()!! }, received.toList())
                "queue" -> if (s.str("kind") == "text") host.core.outbox.queueText(credentials.deviceId, s.str("text")!!) else host.core.outbox.queueLink(credentials.deviceId, s.str("url")!!)
                "poll" -> {
                    val items = runBlocking { client.outbox(0) }.items
                    polled = ArrayList(items.map { it.id })
                    assertEquals(s.array("items").map { it.jsonArray[0].text()!! to it.jsonArray[1].text()!! }, items.map { it.kind to (if (it.kind == "text") it.text!! else it.url!!) })
                }
                "ack" -> {
                    val index = s.getValue("index").jsonPrimitive.int
                    runBlocking { client.acknowledge(polled[index]) }
                    polled.removeAt(index)
                }
                else -> throw IllegalArgumentException(op)
            }
        }
    }
}
