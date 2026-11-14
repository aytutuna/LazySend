package com.lazysend.lazysend.host

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo

/** Announces `_lazysend._tcp` with the TXT keys v, id and n while the host listens. */
class HostAdvertiser(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.RegistrationListener? = null

    @Synchronized
    fun register(port: Int, id: String, name: String) {
        unregister()
        val txtName = cleanName(name, 64)
        val info = NsdServiceInfo().apply {
            serviceName = serviceName(name)
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("v", "1")
            setAttribute("id", id)
            if (txtName.isNotEmpty()) setAttribute("n", txtName)
        }
        val registration = object : NsdManager.RegistrationListener {
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
        }
        // Finding this phone by name is a convenience; pairing by the code does not need it.
        listener = try {
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration)
            registration
        } catch (e: RuntimeException) {
            null
        }
    }

    companion object {
        // A DNS label, which an instance name is, holds 63 bytes.
        fun serviceName(name: String) = cleanName(name, 63).ifEmpty { "Lazy Send" }
    }

    @Synchronized
    fun unregister() {
        listener?.let { runCatching { nsd.unregisterService(it) } }
        listener = null
    }
}
