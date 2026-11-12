package com.lazysend.lazysend.transfer

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/** Looks for the PC's `_lazysend._tcp` announcement on the local network. */
class NsdFinder(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)

    /** The addresses of every announcement heard within [timeoutMs], by the TXT `id` of the PC that made it. */
    @Suppress("DEPRECATION")
    suspend fun find(timeoutMs: Long): Map<String, List<String>> {
        val hosts = mutableMapOf<String, MutableList<String>>()
        val waiting = ArrayDeque<NsdServiceInfo>()
        var resolving = false
        var discovery: NsdManager.DiscoveryListener? = null

        withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine { done ->
                fun resolveNext() {
                    val info = synchronized(waiting) {
                        if (resolving || waiting.isEmpty()) return
                        resolving = true
                        waiting.removeFirst()
                    }
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                            synchronized(waiting) { resolving = false }
                            resolveNext()
                        }

                        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                            val id = serviceInfo.attributes["id"]?.toString(Charsets.UTF_8)
                            val host = serviceInfo.host?.hostAddress
                            synchronized(waiting) { resolving = false }
                            if (id != null && host != null) synchronized(hosts) { hosts.getOrPut(id) { mutableListOf() } += host }
                            resolveNext()
                        }
                    })
                }

                val listener = object : NsdManager.DiscoveryListener {
                    override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                        if (done.isActive) done.resumeWith(Result.success(Unit))
                    }

                    override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
                    override fun onDiscoveryStarted(serviceType: String) = Unit
                    override fun onDiscoveryStopped(serviceType: String) = Unit
                    override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

                    override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                        synchronized(waiting) { waiting.addLast(serviceInfo) }
                        resolveNext()
                    }
                }
                discovery = listener
                nsd.discoverServices("_lazysend._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
            }
        }
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        return synchronized(hosts) { hosts.mapValues { it.value.toList() } }
    }
}
