package com.lazysend.lazysend.host

import com.lazysend.lazysend.transfer.Asset
import com.lazysend.lazysend.transfer.ReceivedFiles
import java.io.File
import java.io.InputStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** A pairing waiting for the person's answer, with the digits both screens show. */
class Approval(val guestName: String, val platform: String, val digits: String) {
    internal val answer = CompletableDeferred<Boolean>()

    /** The first answer counts; a later one, or a dismissal after it, changes nothing. */
    fun respond(allow: Boolean) {
        answer.complete(allow)
    }
}

/**
 * Everything the host keeps and decides apart from the sockets: the guests, what they send and what waits for them, the
 * pairing window and the question put to the person. Android's lifecycle and the network sit around it in
 * [HostController], so this runs on a plain JVM.
 */
class HostCore(
    root: File,
    files: ReceivedFiles,
    val hostId: () -> String,
    val hostName: () -> String,
    freeSpace: () -> Long,
    private val clock: () -> Long = System::currentTimeMillis,
    assets: () -> List<Asset>? = { null },
    openAsset: (Asset) -> InputStream = { throw java.io.IOException("No library.") },
    scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    hosting: () -> Boolean = { true },
) {
    val guests = GuestStore(File(root, "guests.json"))
    val gallery = GalleryIndex(File(root, "index"))
    val inbox = Inbox(File(root, "incoming"), files, gallery, freeSpace, clock)
    val outbox = Outbox(File(root, "outbox.json"), File(root, "outgoing"), clock, freeSpace)
    val sent = SendLog(File(root, "sent.json"), clock)
    val feed = GalleryFeed(outbox, GalleryIndex(File(root, "feed-index")), File(root, "feeds.json"), scope, assets, openAsset, hosting = hosting)
    val limiter = RateLimiter()
    val router = HostRouter(guests, inbox, outbox, gallery, sent, limiter, hostId, hostName, clock)

    private val session = MutableStateFlow<PairingSession?>(null)
    private val question = MutableStateFlow<Approval?>(null)

    /** The pairing window open now, if any. */
    val pairing: StateFlow<PairingSession?> get() = session

    /** The pairing waiting for an answer, if any. */
    val approval: StateFlow<Approval?> get() = question

    var onGuestRemoved: (Guest) -> Unit = {}

    /** Reads what an earlier run left in the inbox; may hash a file, so call it off the main thread. */
    fun load() = inbox.load()

    init {
        router.currentPairing = { session.value?.takeIf { it.stateAt(clock()) == SessionState.Open } }
        router.approve = { pair, digits ->
            val asked = Approval(cleanName(pair.phoneName).ifEmpty { "Phone" }, cleanName(pair.platform), digits)
            question.value = asked
            try {
                asked.answer.await()
            } finally {
                // Declined, answered, timed out or hung up on: the prompt goes either way.
                asked.respond(false)
                question.compareAndSet(asked, null)
            }
        }
        router.onGuestRemoved = { removeGuest(it.id) }
        feed.reconcile(guests.guests.value.map { it.id }.toSet())
    }

    fun openPairing(): PairingSession = PairingSession(clock()).also { fresh ->
        session.value?.close()
        session.value = fresh
    }

    fun closePairing() {
        session.value?.close()
        session.value = null
        declinePending()
    }

    /** The person left or the host stopped without answering: what waits is declined. */
    fun declinePending() {
        question.value?.respond(false)
    }

    /** Forgets the guest, and what it had begun and not finished and what waited for it. Files it sent stay. */
    fun removeGuest(id: String) {
        val guest = guests.get(id) ?: return
        guests.remove(id)
        inbox.removeDevice(id)
        sent.removeDevice(id)
        feed.forget(id)
        outbox.clear(id)
        onGuestRemoved(guest)
    }

    /** Every pairing is dropped, as when this phone's key changed and no guest holds the right fingerprint any more. */
    fun forgetEveryone() {
        guests.guests.value.forEach {
            inbox.removeDevice(it.id)
            sent.removeDevice(it.id)
            feed.forget(it.id)
        }
        guests.clear()
        outbox.clearAll()
    }
}
