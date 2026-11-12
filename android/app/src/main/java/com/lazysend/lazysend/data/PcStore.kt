package com.lazysend.lazysend.data

import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import com.lazysend.lazysend.link.LinkJson

/** A paired PC. [secret] is the device secret as the PC issued it; on disk it is sealed. */
data class Pc(
    val id: String,
    val name: String,
    val fingerprint: String,
    val addresses: List<String>,
    val port: Int,
    val secret: String,
    val lastAddress: String? = null,
)

@Serializable
private data class PcRecord(
    val id: String,
    val name: String,
    val fingerprint: String,
    val addresses: List<String>,
    val port: Int,
    val sealedSecret: String,
    val lastAddress: String? = null,
)

@Serializable
private data class PcFile(val phoneId: String, val pcs: List<PcRecord> = emptyList())

/** The paired PCs and this phone's id, in a JSON file with each secret sealed by [seal]. */
class PcStore(private val file: File, private val seal: (String) -> String, private val open: (String) -> String?) {
    private val phone: String
    private val state: MutableStateFlow<List<Pc>>

    init {
        val saved = runCatching { LinkJson.decodeFromString<PcFile>(file.readText()) }.getOrNull()
        phone = saved?.phoneId ?: UUID.randomUUID().toString().replace("-", "")
        state = MutableStateFlow(saved?.pcs.orEmpty().mapNotNull { r ->
            open(r.sealedSecret)?.let { Pc(r.id, r.name, r.fingerprint, r.addresses, r.port, it, r.lastAddress) }
        })
        if (saved == null) save()
    }

    val phoneId: String get() = phone
    val pcs: StateFlow<List<Pc>> get() = state

    fun get(id: String): Pc? = state.value.firstOrNull { it.id == id }

    /** Pairing again with the same PC replaces its entry. */
    fun put(pc: Pc) {
        state.update { list -> list.filterNot { it.id == pc.id } + pc }
        save()
    }

    fun update(id: String, change: (Pc) -> Pc) {
        val before = state.value
        state.update { list -> list.map { if (it.id == id) change(it) else it } }
        if (state.value != before) save()
    }

    fun remove(id: String) {
        state.update { list -> list.filterNot { it.id == id } }
        save()
    }

    @Synchronized
    private fun save() {
        val records = state.value.map { PcRecord(it.id, it.name, it.fingerprint, it.addresses, it.port, seal(it.secret), it.lastAddress) }
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(LinkJson.encodeToString(PcFile(phone, records)))
        temp.renameTo(file)
    }
}
