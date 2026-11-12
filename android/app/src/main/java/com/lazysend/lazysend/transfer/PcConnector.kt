package com.lazysend.lazysend.transfer

import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.data.PcStore
import com.lazysend.lazysend.link.Credentials
import com.lazysend.lazysend.link.Endpoint
import com.lazysend.lazysend.link.Hello
import com.lazysend.lazysend.link.LinkClient
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.decodeBase64Url
import java.io.IOException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient

sealed interface Reach {
    class Reached(val client: LinkClient, val host: String, val link: LinkKind) : Reach

    /** Nothing answered at any known address, by discovery or by looking around this phone's networks. */
    data object Unreachable : Reach

    /** The PC answered and does not know this phone any more. */
    data object Forgotten : Reach
}

/** Finds which address a paired PC answers on right now, and on which kind of link. */
class PcConnector(
    private val pcs: PcStore,
    private val nsd: NsdFinder?,
    private val http: OkHttpClient = OkHttpClient(),
) {
    private val links = MutableStateFlow<Map<String, LinkKind>>(emptyMap())

    /** The link each PC was last reached on; a PC is missing while it is out of reach. */
    val current: StateFlow<Map<String, LinkKind>> get() = links

    suspend fun connect(pc: Pc, search: Boolean = true): Reach {
        val result = findHost(pc, search)
        links.update { if (result is Reach.Reached) it + (pc.id to result.link) else it - pc.id }
        return result
    }

    /** Waits, trying again every [everyMs], until the PC answers; null when it was forgotten there. */
    suspend fun awaitReachable(pc: Pc, everyMs: Long = 5000): Reach.Reached? {
        while (true) {
            val current = pcs.get(pc.id) ?: return null
            when (val r = connect(current)) {
                is Reach.Reached -> return r
                Reach.Forgotten -> return null
                Reach.Unreachable -> delay(everyMs)
            }
        }
    }

    private suspend fun findHost(pc: Pc, search: Boolean): Reach {
        val pin = decodeBase64Url(pc.fingerprint) ?: return Reach.Unreachable
        val known = (listOfNotNull(pc.lastAddress) + pc.addresses).filter { '%' !in it }.distinct()
        var forgotten = false
        val tried = mutableSetOf<String>()
        suspend fun attempt(hosts: List<String>): Reach.Reached? {
            val r = race(hosts.filter { it !in tried }) { host -> attempt(pc, pin, host) }
            tried += hosts
            if (r == Reach.Forgotten) forgotten = true
            return r as? Reach.Reached
        }
        attempt(known)?.let { return it }
        if (forgotten) return Reach.Forgotten
        if (!search) return Reach.Unreachable
        attempt(nsd?.find(pc.id, 2500).orEmpty().filter { '%' !in it })?.let { return it }
        attempt(probeSubnets(pc.port).filter { '%' !in it })?.let { return it }
        return if (forgotten) Reach.Forgotten else Reach.Unreachable
    }

    private suspend fun race(hosts: List<String>, probe: suspend (String) -> Reach?): Reach? {
        if (hosts.isEmpty()) return null
        return coroutineScope {
            val answers = Channel<Reach?>(hosts.size)
            val jobs = hosts.map { host -> launch { answers.send(probe(host)) } }
            var forgotten = false
            repeat(hosts.size) {
                when (val answer = answers.receive()) {
                    is Reach.Reached -> {
                        jobs.forEach { it.cancel() }
                        return@coroutineScope answer
                    }
                    Reach.Forgotten -> forgotten = true
                    else -> Unit
                }
            }
            if (forgotten) Reach.Forgotten else null
        }
    }

    /** The first of [addresses] that answers with the PC's key, for pairing; its client has no credentials yet. */
    suspend fun reachForPairing(addresses: List<String>, port: Int, pin: ByteArray): Reach.Reached? =
        race(addresses.filter { '%' !in it }.distinct()) { host ->
            val client = LinkClient(Endpoint(host, port), pin, null, http)
            try {
                withTimeout(4000) { client.health() }
                Reach.Reached(client, host, linkKindFor(host, localSubnets()))
            } catch (e: LinkException) {
                null
            } catch (e: IOException) {
                null
            } catch (e: TimeoutCancellationException) {
                null
            }
        } as? Reach.Reached

    fun lost(pcId: String) = links.update { it - pcId }

    private suspend fun attempt(pc: Pc, pin: ByteArray, host: String): Reach? {
        val client = LinkClient(Endpoint(host, pc.port), pin, Credentials(pcs.phoneId, pc.secret), http)
        val hello: Hello = try {
            withTimeout(4000) { client.hello() }
        } catch (e: LinkException) {
            return if (e.status == 401) Reach.Forgotten else null
        } catch (e: TimeoutCancellationException) {
            return null
        } catch (e: IOException) {
            return null
        }
        pcs.update(pc.id) { it.copy(lastAddress = host, addresses = (it.addresses + hello.addresses).distinct().take(8)) }
        return Reach.Reached(client, host, linkKindFor(host, localSubnets()))
    }
}
