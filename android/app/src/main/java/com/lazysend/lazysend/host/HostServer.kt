package com.lazysend.lazysend.host

import java.io.IOException
import java.io.InputStream
import java.net.BindException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import kotlin.concurrent.thread
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class PeerGone : CancellationException("The guest hung up.")

/** One accepted connection: the TLS socket, and what the router may do with it while a request is being served. */
class HostConnection(val socket: SSLSocket, val peer: String, private val scope: CoroutineScope) {
    val accepted = System.nanoTime()

    /** The request line and headers are in, so the time allowed for them no longer counts. */
    @Volatile
    var headDone = false

    /** When the write in progress began, in nanoseconds; 0 while none is. */
    @Volatile
    var writeStarted = 0L

    /** The answer is on its way, so the connection closing is expected. */
    @Volatile
    var finishing = false

    @Volatile
    var peerGone = false
        private set
    private var watching = false

    fun abort() {
        runCatching { socket.close() }
    }

    /**
     * Runs [block] and cancels it when the guest closes the connection. The guest sends nothing more once its request is
     * in, so anything that ends a read here (an end of stream, a reset) means it has gone. The read cannot be interrupted;
     * the server closing the socket after the answer ends it.
     */
    suspend fun <T> whileConnected(block: suspend () -> T): T = coroutineScope {
        val work = async { block() }
        watch { work.cancel(PeerGone()) }
        work.await()
    }

    @Synchronized
    private fun watch(onGone: () -> Unit) {
        if (watching) return
        watching = true
        scope.launch(Dispatchers.IO) {
            try {
                socket.soTimeout = 0
                val buffer = ByteArray(256)
                while (socket.inputStream.read(buffer) >= 0) continue
            } catch (e: IOException) {
                // Ends the wait below, like an end of stream.
            }
            if (!finishing) {
                peerGone = true
                onGone()
            }
        }
    }
}

class HostRequest(val head: RequestHead, val body: RequestBody, val peer: String, private val connection: HostConnection) {
    val peerGone: Boolean get() = connection.peerGone

    /** Ends the connection, which stops a read of its body that is blocked. */
    fun abort() = connection.abort()

    suspend fun <T> whileConnected(block: suspend () -> T): T = connection.whileConnected(block)
}

/**
 * The phone link server: TLS 1.2 or 1.3 over TCP with the host's own certificate, one request per connection, the small
 * HTTP/1.1 subset of [HostHttp], every request handed to the [HostRouter]. Peers the networks refuse, or that the limiter
 * blocks, are closed before TLS, and every step is bounded in time.
 */
class HostServer(
    private val tls: SSLContext,
    private val router: HostRouter,
    private val limiter: RateLimiter,
    private val networks: HostNetworks,
    private val clock: () -> Long = System::currentTimeMillis,
    private val headMs: Long = HEAD_MS,
) {
    private val connections = HashSet<HostConnection>()
    private val gate = Any()
    internal var listener: ServerSocket? = null
        private set
    private var scope: CoroutineScope? = null

    @Volatile
    private var closed = true

    var port = 0
        private set

    /** Called when the listener stops without having been asked to, so the owner can start it again. */
    var onFailed: (Throwable) -> Unit = {}

    val running: Boolean get() = !closed

    val activeConnections: Int get() = synchronized(gate) { connections.size }

    /** Starts listening on [port] (any free port when it is 0 or taken) on every interface, or only on [address]. Returns the port. */
    fun start(port: Int = com.lazysend.lazysend.link.DEFAULT_PORT, address: InetAddress? = null): Int {
        check(closed) { "The server is already running." }
        val socket = try {
            bind(address, port)
        } catch (e: BindException) {
            if (port == 0) throw e
            bind(address, 0)
        }
        listener = socket
        this.port = socket.localPort
        closed = false
        val work = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope = work
        work.launch { watchWrites() }
        thread(name = "lazysend-accept", isDaemon = true) { acceptLoop(socket, work) }
        return this.port
    }

    private fun bind(address: InetAddress?, port: Int) = ServerSocket().apply {
        reuseAddress = true
        bind(if (address == null) InetSocketAddress(port) else InetSocketAddress(address, port), 32)
    }

    /** Stops listening at once, lets the requests being served finish for two seconds, then cuts off the rest. */
    suspend fun stop() {
        if (closed) return
        closed = true
        runCatching { listener?.close() }
        val deadline = System.nanoTime() + STOP_GRACE_NS
        while (System.nanoTime() < deadline && synchronized(gate) { connections.isNotEmpty() }) delay(50)
        synchronized(gate) { connections.toList() }.forEach { it.abort() }
        scope?.cancel()
        scope = null
        port = 0
    }

    private fun acceptLoop(listener: ServerSocket, work: CoroutineScope) {
        var failures = 0
        while (!closed) {
            val socket = try {
                listener.accept().also { failures = 0 }
            } catch (e: IOException) {
                if (closed) return
                // A connection reset while it was being accepted, or no file handle for a moment, is no reason to stop.
                if (!listener.isClosed && ++failures < 50) {
                    Thread.sleep(100)
                    continue
                }
                closed = true
                runCatching { listener.close() }
                synchronized(gate) { connections.toList() }.forEach { it.abort() }
                work.cancel()
                onFailed(e)
                return
            }
            try {
                admit(socket, work)
            } catch (e: Exception) {
                runCatching { socket.close() }
            }
        }
    }

    private fun admit(socket: Socket, work: CoroutineScope) {
        val remote = socket.inetAddress
        val peer = remote.hostAddress!!.substringBefore('%')
        val connection: HostConnection
        synchronized(gate) {
            if (connections.size >= MAX_CONNECTIONS || connections.count { it.peer == peer } >= MAX_PER_PEER ||
                !networks.allowsPeer(remote) || !networks.allowsLocal(socket.localAddress) || limiter.isBlocked(peer, clock())
            ) {
                socket.close()
                return
            }
            // Wrapped here, before any byte is read, so the handshake runs in the connection's own coroutine.
            socket.tcpNoDelay = true
            val secured = tls.socketFactory.createSocket(socket, null, socket.port, true) as SSLSocket
            secured.useClientMode = false
            secured.enabledProtocols = secured.supportedProtocols.filter { it == "TLSv1.3" || it == "TLSv1.2" }.toTypedArray()
            connection = HostConnection(secured, peer, work)
            connections.add(connection)
        }
        work.launch {
            try {
                serve(connection)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A guest that went away, timed out or failed the handshake: nothing to answer.
            } finally {
                connection.abort()
                synchronized(gate) { connections.remove(connection) }
            }
        }
    }

    // A write into a stalled connection has no timeout of its own, so one that makes no progress is closed; so is one that
    // has not sent its head in time.
    private suspend fun watchWrites() {
        while (true) {
            delay(500)
            val now = System.nanoTime()
            synchronized(gate) { connections.toList() }.forEach {
                val started = it.writeStarted
                if (started != 0L && now - started > IDLE_NS) it.abort()
                // A client that trickles its handshake or head a byte at a time stays under each read's timeout, not under this one.
                if (!it.headDone && now - it.accepted > headMs * 1_000_000L) it.abort()
            }
        }
    }

    private suspend fun serve(connection: HostConnection) {
        val socket = connection.socket
        socket.soTimeout = HANDSHAKE_MS
        socket.startHandshake()
        val input = socket.inputStream

        val buffer = ByteArray(HostHttp.MAX_HEAD + 4096)
        var filled = 0
        var parsed: Parsed
        val deadline = System.currentTimeMillis() + headMs
        while (true) {
            val left = deadline - System.currentTimeMillis()
            if (left <= 0) return
            socket.soTimeout = left.toInt()
            val read = input.read(buffer, filled, buffer.size - filled)
            if (read < 0) return
            filled += read
            parsed = HostHttp.parse(buffer, filled)
            if (parsed != Parsed.Incomplete) break
            if (filled == buffer.size) {
                parsed = Parsed.Invalid(431)
                break
            }
        }
        connection.headDone = true
        if (parsed is Parsed.Invalid) {
            write(connection, HostResponse.error(HostError(parsed.status, "badRequest", HostError.badRequest.message.orEmpty())))
            return
        }
        val head = (parsed as Parsed.Complete).head
        socket.soTimeout = IDLE_MS
        val body = RequestBody(
            input, head.contentLength ?: 0, buffer.copyOfRange(parsed.consumed, filled),
            if (head.expectsContinue) ({ writeBytes(connection, HostHttp.continueResponse) }) else null,
        )
        if ((head.contentLength ?: 0) <= MAX_SMALL_BODY) {
            // A small body, which pairing is, has this long in all rather than between two reads.
            var started = 0L
            body.beforeRead = {
                val now = System.currentTimeMillis()
                if (started == 0L) started = now
                val left = BODY_MS - (now - started)
                if (left <= 0) throw SocketTimeoutException("The body took too long.")
                socket.soTimeout = left.toInt()
            }
        }
        val request = HostRequest(head, body, connection.peer, connection)
        val response = try {
            router.handle(request)
        } catch (e: CancellationException) {
            // The guest hung up while the router waited for it; a cancelled server is another matter.
            if (!currentCoroutineContext().isActive) throw e
            return
        } catch (e: IOException) {
            return
        } catch (e: Exception) {
            HostResponse.error(HostError.serverError)
        }
        var written = false
        try {
            connection.finishing = true
            // A write into a closed socket still succeeds once; a guest that already hung up never gets the secret.
            if (response.written == null || !request.peerGone) {
                write(connection, response)
                written = true
            }
        } finally {
            response.stream?.close()
            response.written?.invoke(written)
        }
        // Leave the client its whole send when it is small, so closing does not cut off the answer.
        val dropUntil = System.currentTimeMillis() + DISCARD_MS
        body.beforeRead = {
            val left = dropUntil - System.currentTimeMillis()
            if (left <= 0) throw SocketTimeoutException("Dropping the body took too long.")
            socket.soTimeout = left.toInt()
        }
        try {
            body.discard(minOf(MAX_DISCARD, body.remaining))
        } catch (e: IOException) {
            // Closed below either way.
        }
    }

    private fun writeBytes(connection: HostConnection, bytes: ByteArray, off: Int = 0, len: Int = bytes.size) {
        connection.writeStarted = System.nanoTime()
        try {
            connection.socket.outputStream.write(bytes, off, len)
            connection.socket.outputStream.flush()
        } finally {
            connection.writeStarted = 0
        }
    }

    private fun write(connection: HostConnection, response: HostResponse) {
        writeBytes(connection, HostHttp.responseHead(response.status, response.headers, response.length))
        val source: InputStream? = response.stream
        if (source != null) {
            val buffer = ByteArray(256 * 1024)
            var left = response.length
            while (left > 0) {
                val n = source.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
                if (n < 0) throw IOException("The file ended before its announced length.")
                writeBytes(connection, buffer, 0, n)
                left -= n
            }
        } else if (response.body.isNotEmpty()) {
            writeBytes(connection, response.body)
        }
    }

    private companion object {
        const val MAX_CONNECTIONS = 16
        const val MAX_PER_PEER = 6
        const val HANDSHAKE_MS = 10_000
        const val HEAD_MS = 10_000L
        const val BODY_MS = 15_000L
        const val IDLE_MS = 30_000
        const val IDLE_NS = 30_000_000_000L
        const val DISCARD_MS = 5_000L
        const val MAX_DISCARD = 1024L * 1024
        const val STOP_GRACE_NS = 2_000_000_000L
    }
}
