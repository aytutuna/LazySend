package com.lazysend.lazysend.ui

import android.app.Application
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lazysend.lazysend.BuildConfig
import com.lazysend.lazysend.LazySendApp
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.host.Approval
import com.lazysend.lazysend.host.Guest
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.PairingCode
import com.lazysend.lazysend.link.PairingCodeException
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/** Rows of the devices that are guests of this phone have this in front of their id, so a device that is both has two rows. */
private const val GUEST = "guest:"

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val graph = (app as LazySendApp).graph
    private val selected = MutableStateFlow<String?>(null)
    private val photoAccess = MutableStateFlow(PhotoAccess.None)
    private var pairJob: Job? = null

    val pair = MutableStateFlow<PairUi>(PairUi.Scanning)
    val notice = MutableStateFlow<String?>(null)

    val state: StateFlow<MainState> = combine(
        combine(graph.pcs.pcs, graph.host.core.guests.guests) { pcs, guests -> pcs to guests },
        graph.timeline.entries, graph.connector.current, selected, photoAccess,
    ) { (pcs, guests), entries, links, pick, access ->
        val rows = pcs.map { PcRow(it.id, it.name, links[it.id]?.label) } + guests.map { PcRow(GUEST + it.id, it.name, null, guest = true) }
        MainState(
            pcs = rows,
            selected = pick?.takeIf { id -> rows.any { it.id == id } } ?: rows.firstOrNull()?.id,
            entries = entries,
            photoAccess = access,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), MainState(emptyList(), null, emptyList()))

    val receive: StateFlow<ReceiveUi> = combine(graph.host.state, graph.host.core.approval, graph.host.core.guests.guests) { host, approval, guests ->
        ReceiveUi(host, approval, guests.map { it.name })
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ReceiveUi())

    /** True while this phone hosts with a guest paired: the screen that sees it asks for the service that keeps it going. */
    val keepHosting: StateFlow<Boolean> get() = graph.host.keepAlive

    fun select(id: String) {
        selected.value = id
    }

    fun photoAccess(access: PhotoAccess) {
        photoAccess.value = access
    }

    fun selectedPc(): Pc? = state.value.selected?.takeIf { !it.startsWith(GUEST) }?.let(graph.pcs::get)

    fun selectedGuest(): Guest? = state.value.selected?.takeIf { it.startsWith(GUEST) }?.let { graph.host.core.guests.get(it.removePrefix(GUEST)) }

    fun openReceive() = graph.host.open()

    fun pauseReceive() = graph.host.pause()

    /** The app is in front: hosting that was wanted and ended without the person stopping it starts again. */
    fun resumeHosting() {
        graph.notifications.clearPaused()
        graph.host.resumeIfWanted()
    }

    fun leaveReceive() = graph.host.leave()

    fun stopReceiving() = graph.host.stop()

    fun answer(approval: Approval, allow: Boolean) = approval.respond(allow)

    /** Asks every paired PC for what it has queued, for as long as the caller stays active. */
    suspend fun watch() = withContext(Dispatchers.IO) {
        graph.pcs.pcs.map { list -> list.map { it.id } }.distinctUntilChanged().collectLatest { ids ->
            coroutineScope {
                ids.forEach { id -> graph.pcs.get(id)?.let { launch { graph.receiver.watch(it) } } }
            }
        }
    }

    fun sendText(text: String) {
        val guest = selectedGuest()
        val pc = selectedPc()
        viewModelScope.launch(Dispatchers.IO) {
            notice.value = when {
                guest != null -> graph.host.queueText(guest, text) ?: getApplication<Application>().getString(R.string.note_sent)
                pc != null -> graph.sender.sendText(pc, text) ?: getApplication<Application>().getString(R.string.note_sent)
                else -> return@launch
            }
        }
    }

    fun clearNotice() {
        notice.value = null
    }

    fun startPairing() {
        pairJob?.cancel()
        pair.value = PairUi.Scanning
    }

    /** Pairs from the QR code's text or pasted pairing text; [extraAddress] is only used by debug builds. */
    fun pair(text: String, extraAddress: String?) {
        if (pairJob?.isActive == true || pair.value is PairUi.Paired) return
        val context = getApplication<Application>()
        pairJob = viewModelScope.launch(Dispatchers.IO) {
            val code = try {
                PairingCode.parse(text)
            } catch (e: PairingCodeException) {
                pair.value = PairUi.Failed(e.message.orEmpty())
                return@launch
            }
            pair.value = PairUi.Waiting(code.checkCode)
            val addresses = (code.addresses + listOfNotNull(extraAddress)).distinct()
            val reached = graph.connector.reachForPairing(addresses, code.port, code.pin)
            if (reached == null) {
                pair.value = PairUi.Failed(context.getString(R.string.pair_unreachable))
                return@launch
            }
            try {
                val reply = reached.client.pair(code.token, graph.pcs.phoneId, Build.MODEL, BuildConfig.VERSION_NAME)
                graph.pcs.put(Pc(code.desktopId, reply.desktopName, code.fingerprint, addresses, code.port, reply.deviceSecret, reached.host))
                selected.value = code.desktopId
                pair.value = PairUi.Paired(reply.desktopName)
            } catch (e: LinkException) {
                pair.value = PairUi.Failed(e.message.orEmpty())
            } catch (e: IOException) {
                pair.value = PairUi.Failed(context.getString(R.string.pair_unreachable))
            }
        }
    }

    /** Forgets the PC here and, when it can be reached, there too; a guest of this phone is forgotten here and finds out when it asks. */
    fun remove(id: String) {
        if (id.startsWith(GUEST)) {
            viewModelScope.launch(Dispatchers.IO) { graph.host.removeGuest(id.removePrefix(GUEST)) }
            return
        }
        val pc = graph.pcs.get(id) ?: return
        graph.pcs.remove(id)
        viewModelScope.launch(Dispatchers.IO) {
            val reached = graph.connector.connect(pc, search = false) as? com.lazysend.lazysend.transfer.Reach.Reached
            try {
                reached?.client?.forgetSelf()
            } catch (e: IOException) {
                // It will notice when this phone asks again and is turned away.
            } catch (e: LinkException) {
            }
            graph.connector.lost(id)
        }
    }
}
