package com.lazysend.lazysend.host

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.Timeline
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.link.DEFAULT_PORT
import com.lazysend.lazysend.transfer.LinkKind
import com.lazysend.lazysend.transfer.ReceivedFiles
import com.lazysend.lazysend.transfer.Subnet
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What the Receive screen shows of the pairing window open now. */
data class PairingInfo(val link: String, val shortCode: String, val matchDigits: String, val checkDigits: String, val expires: Long, val closed: Boolean = false)

data class ReceiveState(
    val running: Boolean = false,
    val port: Int = 0,
    /** The kind of link the first address is on ("Wi-Fi", "USB"), or null when this phone has no address to be reached on. */
    val link: String? = null,
    val pairing: PairingInfo? = null,
    val error: String? = null,
)

/**
 * Runs this phone as a host: the server while the Receive screen is open or a guest is paired, restarted with back-off when it
 * fails, the pairing window, the announcement on the network and the timeline entries for what arrives. Stopping is the
 * person's choice; leaving the Receive screen only stops it while no guest is paired.
 */
class HostController(
    root: File,
    files: ReceivedFiles,
    private val timeline: Timeline,
    hostId: () -> String,
    hostName: () -> String,
    freeSpace: () -> Long,
    private val identity: () -> HostIdentity,
    private val networks: HostNetworks = HostNetworks(),
    private val advertiser: HostAdvertiser? = null,
    private val notifyReceived: (id: Int, title: String, text: String) -> Unit = { _, _, _ -> },
    private val preferredPort: Int = DEFAULT_PORT,
    private val clock: () -> Long = System::currentTimeMillis,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    val core = HostCore(root, files, hostId, hostName, freeSpace, clock)
    private val fingerprintFile = File(root, "fingerprint.txt")
    private val hostingFile = File(root, "hosting")
    private val loaded = CompletableDeferred<Unit>()
    private val shown = MutableStateFlow(ReceiveState())
    private var supervisor: Job? = null
    @Volatile
    private var screenOpen = false

    @Volatile
    private var paused = false

    @Volatile
    private var key: HostIdentity? = null

    @Volatile
    internal var currentServer: HostServer? = null

    val state: StateFlow<ReceiveState> get() = shown

    // Hosting is wanted from start to stop, also while the server comes back after a failure.
    private val wanted = MutableStateFlow(false)
    private var retiring: Job? = null

    /** Hosting is wanted and a guest is paired, so something has to keep this process alive. */
    val keepAlive: StateFlow<Boolean> =
        combine(wanted, core.guests.guests) { w, g -> w && g.isNotEmpty() }.stateIn(scope, SharingStarted.Eagerly, false)

    init {
        core.inbox.onBegun = { file -> if (file.sourceId == null) begun(file) }
        core.inbox.onProgress = { file, bytes -> if (file.sourceId == null) timeline.update("in-${file.id}") { it.copy(bytes = bytes) } }
        core.inbox.onFinished = ::finished
        core.router.onText = { guest, kind, text ->
            val id = newId()
            timeline.add(
                TimelineEntry(id, clock(), Direction.Received, if (kind == "link") EntryKind.Link else EntryKind.Text, guest.name, text, state = EntryState.Done),
            )
            notifyReceived(id.hashCode(), guest.name, text)
        }
        core.router.onAcknowledged = { item ->
            timeline.update("out-${item.id}") { it.copy(state = EntryState.Done, detail = "", bytes = it.totalBytes) }
            timeline.save()
        }
        core.onGuestRemoved = { if (core.guests.guests.value.isEmpty() && !screenOpen) stop() }
        core.router.addresses = { networks.pairingAddresses() }
        scope.launch(Dispatchers.IO) {
            try {
                core.load()
            } finally {
                loaded.complete(Unit)
            }
        }
        scope.launch {
            // A guest pairing while the screen is open is a person to wait on; the window refreshes with the network.
            while (isActive) {
                val session = core.pairing.value
                if (paused && core.guests.guests.value.isEmpty() && (session == null || session.stateAt(clock()) != SessionState.Open)) {
                    // The person is away and the code has run out: nothing is left to wait for.
                    stop()
                } else if (screenOpen && !paused && shown.value.running) {
                    if ((session == null || session.stateAt(clock()) in listOf(SessionState.Used, SessionState.Expired)) && core.approval.value == null) core.openPairing()
                    publish()
                }
                delay(2000)
            }
        }
    }

    /** The Receive screen opened: listens, and shows a code. */
    fun open() {
        screenOpen = true
        paused = false
        start()
        if (shown.value.running) {
            ensurePairing()
            publish()
        }
    }

    // A screen that comes back, a rotation included, finds the code it left rather than a new one.
    private fun ensurePairing() {
        if (core.pairing.value?.stateAt(clock()) != SessionState.Open) core.openPairing()
    }

    /** The app went out of view with the Receive screen open: the code stays good until it runs out, and only what waits is declined. */
    fun pause() {
        paused = true
        core.declinePending()
    }

    /** The person left the Receive screen: no code is shown and what waits for an answer is declined. */
    fun leave() {
        screenOpen = false
        paused = false
        core.closePairing()
        shown.value = shown.value.copy(pairing = null)
        if (core.guests.guests.value.isEmpty()) stop()
    }

    /** The person stopped receiving, or there is nobody left to receive for. */
    fun stop() = halt(forget = true)

    /** The system ended the service for its time budget: hosting stays wanted, and resumes when the app is in front again. */
    fun suspendHosting() = halt(forget = false)

    /** Starts hosting again when it was wanted and a guest is paired; called while the app is in front, since only then may a service start. */
    fun resumeIfWanted() {
        if (hostingFile.exists() && core.guests.guests.value.isNotEmpty()) start()
    }

    private fun halt(forget: Boolean) {
        screenOpen = false
        paused = false
        core.closePairing()
        if (forget) hostingFile.delete()
        wanted.value = false
        supervisor?.cancel()
        retiring = supervisor
        supervisor = null
    }

    fun answer(allow: Boolean) {
        core.approval.value?.respond(allow)
    }

    /** Starts the server unless it is up; keeps it up until [stop], with a longer wait after each failure. */
    @Synchronized
    fun start() {
        if (supervisor?.isActive == true) return
        wanted.value = true
        runCatching { hostingFile.apply { parentFile?.mkdirs() }.writeText("1") }
        val previous = retiring
        supervisor = scope.launch {
            // The run being stopped puts its state and announcement away first, so it cannot undo this one.
            previous?.join()
            loaded.await()
            var wait = 1000L
            while (isActive) {
                val failed = CompletableDeferred<Throwable>()
                val server = try {
                    launchServer(failed)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    shown.value = ReceiveState(error = e.message ?: "Could not start.")
                    delay(wait)
                    wait = minOf(wait * 2, 30_000L)
                    continue
                }
                wait = 1000L
                try {
                    failed.await()
                } finally {
                    withContext(NonCancellable) {
                        advertiser?.unregister()
                        currentServer = null
                        server.stop()
                        shown.value = ReceiveState(error = if (failed.isCompleted) "The connection ended. Starting again." else null)
                    }
                }
                delay(wait)
                wait = minOf(wait * 2, 30_000L)
            }
        }
    }

    private suspend fun launchServer(failed: CompletableDeferred<Throwable>): HostServer {
        val key = identity().also { this.key = it }
        val fingerprint = hex(key.fingerprint)
        // A key that changed (a restore on another phone, where the Keystore key did not come along) is no key any guest pinned.
        val kept = runCatching { fingerprintFile.readText().trim() }.getOrNull()
        if (kept != fingerprint) {
            if (core.guests.guests.value.isNotEmpty()) core.forgetEveryone()
            fingerprintFile.writeAtomically(fingerprint)
        }
        core.router.fingerprint = { key.fingerprint }
        val server = HostServer(key.sslContext(), core.router, core.limiter, networks, clock)
        server.onFailed = { failed.complete(it) }
        val port = server.start(preferredPort)
        currentServer = server
        advertiser?.register(port, core.hostId(), core.hostName())
        shown.value = ReceiveState(running = true, port = port)
        if (screenOpen) {
            ensurePairing()
            publish()
        }
        return server
    }

    private fun publish() {
        val current = shown.value
        if (!current.running) return
        val addresses = networks.pairingAddresses()
        val label = networks.subnets().firstOrNull { it.address.hostAddress?.substringBefore('%') == addresses.firstOrNull() }
            ?.let { Subnet(it.name, 0, 0).kind().takeIf { kind -> kind != LinkKind.Other }?.label }
        val session = core.pairing.value
        val key = key ?: return
        val pairing = session?.takeIf { screenOpen }?.let {
            PairingInfo(
                pairingLink(core.hostId(), core.hostName(), key.fingerprint, addresses, current.port, it.tokenText),
                it.shortCodeText,
                Fingerprint.spaced(Fingerprint.matchCode(key.fingerprint, it.shortCode)),
                Fingerprint.spaced(Fingerprint.checkCode(key.fingerprint)),
                it.expires,
                it.stateAt(clock()) == SessionState.Closed,
            )
        }
        shown.value = current.copy(link = label, pairing = pairing)
    }

    /** The code was closed by too many wrong tries; the person asks for another. */
    fun newCode() {
        core.openPairing()
        publish()
    }

    fun removeGuest(id: String) {
        core.removeGuest(id)
    }

    /** Queues text for a guest; a lone http or https address goes as a link. Returns why it was refused, or null. */
    fun queueText(guest: Guest, text: String): String? {
        val trimmed = text.trim()
        return try {
            val item = if (isAcceptableUrl(trimmed) && ' ' !in trimmed) core.outbox.queueLink(guest.id, trimmed) else core.outbox.queueText(guest.id, text)
            queued(guest, item, if (item.kind == "link") EntryKind.Link else EntryKind.Text, item.url ?: item.text.orEmpty())
            null
        } catch (e: IllegalArgumentException) {
            "That is more than the 1 MB a note can hold. Send it as a file instead."
        } catch (e: Exception) {
            e.message ?: "Not queued."
        }
    }

    /** Copies what was picked or shared into this app's storage and queues it for a guest. */
    fun queueUris(guest: Guest, resolver: ContentResolver, uris: List<Uri>) {
        for (uri in uris) {
            try {
                var name = uri.lastPathSegment ?: "file"
                var size: Long? = null
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                    if (it.moveToFirst()) {
                        it.getString(0)?.let { n -> name = n }
                        if (!it.isNull(1)) size = it.getLong(1)
                    }
                }
                val item = core.outbox.queueFile(guest.id, name, resolver.getType(uri), size) { resolver.openInputStream(uri) ?: throw java.io.IOException("Cannot open $uri") }
                queued(guest, item, EntryKind.File, item.name.orEmpty())
            } catch (e: Exception) {
                // One file that cannot be read must not stop the ones behind it.
                timeline.add(
                    TimelineEntry(newId(), clock(), Direction.Sent, EntryKind.File, guest.name, uri.lastPathSegment ?: "file", state = EntryState.Failed, detail = e.message.orEmpty()),
                )
                timeline.save()
            }
        }
    }

    private fun queued(guest: Guest, item: OutboxItem, kind: EntryKind, title: String) {
        timeline.add(
            TimelineEntry(
                "out-${item.id}", clock(), Direction.Sent, kind, guest.name, title, detail = "Waiting for ${guest.name} to pick it up",
                state = EntryState.Active, totalBytes = item.size ?: 0, mime = item.mime,
            ),
        )
        timeline.save()
    }

    private fun begun(file: IncomingFile) {
        timeline.add(
            TimelineEntry(
                "in-${file.id}", clock(), Direction.Received, EntryKind.File, file.deviceName, file.name,
                state = EntryState.Active, totalBytes = file.size, mime = file.mime,
            ),
        )
    }

    private fun finished(file: IncomingFile) {
        if (file.sourceId != null) {
            // A gallery is thousands of files: one entry counts them.
            val id = galleryId(file.deviceId)
            val before = timeline.get(id)
            timeline.add(
                TimelineEntry(
                    id, clock(), Direction.Received, EntryKind.Gallery, file.deviceName, "Photos and videos", state = EntryState.Done,
                    count = (before?.count ?: 0) + 1, bytes = (before?.bytes ?: 0) + file.size,
                ),
            )
        } else {
            timeline.update("in-${file.id}") { it.copy(state = EntryState.Done, bytes = file.size, uri = file.uri) }
            notifyReceived(file.id.hashCode(), file.deviceName, file.name)
        }
        timeline.save()
    }

    private fun galleryId(guestId: String) = "gallery-in-$guestId"
}
