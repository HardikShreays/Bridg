package com.bridg.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/**
 * NSD discovery for finding the Mac on the local network.
 *
 * The phone only browses. The Mac is the server: it advertises and listens.
 * Both sides advertising *and* browsing meant each one discovered itself.
 */
class ServiceDiscovery(context: Context) {

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var isDiscovering = false

    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var onServiceFound: ((NsdServiceInfo) -> Unit)? = null
    private var onServiceLost: ((NsdServiceInfo) -> Unit)? = null

    /** NSD allows only one resolve at a time; a second returns FAILURE_ALREADY_ACTIVE. */
    private var resolveInFlight = false
    private val pendingResolves = ArrayDeque<PendingResolve>()

    fun startDiscovery(onFound: (NsdServiceInfo) -> Unit, onLost: (NsdServiceInfo) -> Unit) {
        if (isDiscovering) return

        onServiceFound = onFound
        onServiceLost = onLost

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                isDiscovering = true
                Log.d(TAG, "Discovery started for $serviceType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                // NSD hands back the type with inconsistent leading/trailing dots
                // ("_bridg._tcp." vs "_bridg._tcp"), so an == check dropped every
                // service it found.
                if (!serviceInfo.serviceType.trim('.').equals(SERVICE_TYPE.trim('.'), ignoreCase = true)) {
                    return
                }
                Log.d(TAG, "Service found: ${serviceInfo.serviceName}")
                onServiceFound?.invoke(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Service lost: ${serviceInfo.serviceName}")
                onServiceLost?.invoke(serviceInfo)
            }

            override fun onDiscoveryStopped(serviceType: String) {
                isDiscovering = false
                Log.d(TAG, "Discovery stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                isDiscovering = false
                Log.e(TAG, "Discovery start failed: $errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Discovery stop failed: $errorCode")
            }
        }

        nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }

    fun stopDiscovery() {
        val listener = discoveryListener ?: return
        if (!isDiscovering) return
        try {
            nsdManager.stopServiceDiscovery(listener)
        } catch (e: Exception) {
            Log.w(TAG, "Error stopping discovery: ${e.message}")
        }
        isDiscovering = false
        discoveryListener = null
    }

    /** Resolve a discovered service to a host and port. Resolves are serialized. */
    fun resolveService(
        serviceInfo: NsdServiceInfo,
        onResolved: (host: java.net.InetAddress, port: Int) -> Unit,
        onFailed: (String) -> Unit
    ) {
        pendingResolves.addLast(PendingResolve(serviceInfo, onResolved, onFailed))
        pumpResolves()
    }

    private fun pumpResolves() {
        if (resolveInFlight) return
        val next = pendingResolves.removeFirstOrNull() ?: return
        resolveInFlight = true

        @Suppress("DEPRECATION")
        nsdManager.resolveService(next.info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                resolveInFlight = false
                next.onFailed("Resolve failed: $errorCode")
                pumpResolves()
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                resolveInFlight = false
                val host = serviceInfo.host
                val port = serviceInfo.port
                if (host != null && port > 0) next.onResolved(host, port)
                else next.onFailed("Invalid resolved service info")
                pumpResolves()
            }
        })
    }

    private data class PendingResolve(
        val info: NsdServiceInfo,
        val onResolved: (java.net.InetAddress, Int) -> Unit,
        val onFailed: (String) -> Unit
    )

    companion object {
        private const val TAG = "ServiceDiscovery"
        const val SERVICE_TYPE = "_bridg._tcp."
    }
}
