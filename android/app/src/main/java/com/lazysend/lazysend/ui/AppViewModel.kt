package com.lazysend.lazysend.ui

import android.app.Application
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.lazysend.lazysend.BuildConfig
import com.lazysend.lazysend.LazySendApp
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.link.LinkException
import com.lazysend.lazysend.link.PairingCode
import com.lazysend.lazysend.link.PairingCodeException
import java.io.IOException
import kotlinx.coroutines.Job
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

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val graph = (app as LazySendApp).graph
    private val selected = MutableStateFlow<String?>(null)
    private val photoAccess = MutableStateFlow(PhotoAccess.None)
    private var pairJob: Job? = null

    val pair = MutableStateFlow<PairUi>(PairUi.Scanning)
    val notice = MutableStateFlow<String?>(null)

    val state: StateFlow<MainState> = combine(graph.pcs.pcs, graph.timeline.entries, graph.connector.current, selected, photoAccess) { pcs, entries, links, pick, access ->
        MainState(
            pcs = pcs.map { PcRow(it.id, it.name, links[it.id]?.label) },
            selected = pick?.takeIf { id -> pcs.any { it.id == id } } ?: pcs.firstOrNull()?.id,
            entries = entries,
            photoAccess = access,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), MainState(emptyList(), null, emptyList()))

    fun select(id: String) {
        selected.value = id
    }

    fun photoAccess(access: PhotoAccess) {
        photoAccess.value = access
    }

    fun selectedPc(): Pc? = state.value.selected?.let(graph.pcs::get)

    /** Asks every paired PC for what it has queued, for as long as the caller stays active. */
    suspend fun watch() {
        graph.pcs.pcs.map { list -> list.map { it.id } }.distinctUntilChanged().collectLatest { ids ->
            coroutineScope {
                ids.forEach { id -> graph.pcs.get(id)?.let { launch { graph.receiver.watch(it) } } }
            }
        }
    }

    fun sendText(text: String) {
        val pc = selectedPc() ?: return
        viewModelScope.launch {
            notice.value = graph.sender.sendText(pc, text) ?: getApplication<Application>().getString(R.string.note_sent)
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
        pairJob = viewModelScope.launch {
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

    /** Forgets the PC here and, when it can be reached, there too. */
    fun remove(id: String) {
        val pc = graph.pcs.get(id) ?: return
        graph.pcs.remove(id)
        viewModelScope.launch {
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
