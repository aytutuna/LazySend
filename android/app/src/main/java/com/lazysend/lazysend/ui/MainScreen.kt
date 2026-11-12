package com.lazysend.lazysend.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.Direction
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.EntryState
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.transfer.formatBytes

data class PcRow(val id: String, val name: String, val link: String?)

enum class PhotoAccess { Full, Partial, None }

data class MainState(
    val pcs: List<PcRow>,
    val selected: String?,
    val entries: List<TimelineEntry>,
    val photoAccess: PhotoAccess = PhotoAccess.Full,
)

class MainActions(
    val onPair: () -> Unit = {},
    val onPcs: () -> Unit = {},
    val onSend: () -> Unit = {},
    val onSelect: (String) -> Unit = {},
    val onGallery: () -> Unit = {},
    val onStop: () -> Unit = {},
    val onAllowPhotos: () -> Unit = {},
    val onCopy: (String) -> Unit = {},
    val onOpen: (TimelineEntry) -> Unit = {},
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(state: MainState, actions: MainActions) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
                actions = {
                    if (state.pcs.isNotEmpty()) TextButton(onClick = actions.onPcs) { Text(stringResource(R.string.paired_pcs)) }
                },
            )
        },
    ) { padding ->
        if (state.pcs.isEmpty()) {
            Empty(Modifier.padding(padding), actions.onPair)
            return@Scaffold
        }
        LazyColumn(
            Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item { Connection(state, actions) }
            if (state.entries.isEmpty()) {
                item { Text(stringResource(R.string.timeline_empty), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            items(state.entries, key = { it.id }) { Entry(it, actions) }
        }
    }
}

@Composable
private fun Empty(modifier: Modifier, onPair: () -> Unit) {
    Column(modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(stringResource(R.string.empty_title), style = MaterialTheme.typography.headlineSmall)
        Text(
            stringResource(R.string.empty_body),
            Modifier.padding(vertical = 12.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onPair) { Text(stringResource(R.string.pair_a_pc)) }
    }
}

@Composable
private fun Connection(state: MainState, actions: MainActions) {
    val pc = state.pcs.firstOrNull { it.id == state.selected } ?: state.pcs.first()
    Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (state.pcs.size > 1) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    state.pcs.forEach { FilterChip(selected = it.id == pc.id, onClick = { actions.onSelect(it.id) }, label = { Text(it.name) }) }
                }
            }
            Text(pc.name, style = MaterialTheme.typography.titleMedium)
            Text(
                if (pc.link != null) stringResource(R.string.connected_over, pc.link) else stringResource(R.string.not_reachable, pc.name),
                style = MaterialTheme.typography.bodyMedium,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = actions.onSend) { Text(stringResource(R.string.send)) }
                OutlinedButton(onClick = actions.onGallery) { Text(stringResource(R.string.send_all_photos)) }
            }
            if (state.photoAccess == PhotoAccess.Partial) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.photo_access_partial), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = actions.onAllowPhotos) { Text(stringResource(R.string.allow_all_photos)) }
                }
            }
        }
    }
}

@Composable
private fun Entry(entry: TimelineEntry, actions: MainActions) {
    val context = LocalContext.current
    val sent = entry.direction == Direction.Sent
    Card {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(if (sent) "↑" else "↓", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                Column(Modifier.weight(1f).padding(start = 10.dp)) {
                    Text(
                        entry.title,
                        maxLines = if (entry.kind == EntryKind.Text) 4 else 1,
                        overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodyLarge,
                    )
                    Text(
                        listOfNotNull(
                            if (sent) stringResource(R.string.sent_to, entry.pcName) else stringResource(R.string.received_from, entry.pcName),
                            DateUtils.formatDateTime(context, entry.time, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_MONTH),
                        ).joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            Status(entry)
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (entry.kind == EntryKind.Gallery) {
                    if (entry.state == EntryState.Active) TextButton(onClick = actions.onStop) { Text(stringResource(R.string.stop)) }
                    if (entry.state == EntryState.Paused || entry.state == EntryState.Failed) {
                        TextButton(onClick = actions.onGallery) { Text(stringResource(R.string.resume)) }
                    }
                }
                if (entry.kind == EntryKind.Text || entry.kind == EntryKind.Link) {
                    TextButton(onClick = { actions.onCopy(entry.title) }) { Text(stringResource(R.string.copy)) }
                }
                if (entry.kind == EntryKind.Link || (entry.kind == EntryKind.File && !sent && entry.state == EntryState.Done)) {
                    TextButton(onClick = { actions.onOpen(entry) }) { Text(stringResource(R.string.open)) }
                }
            }
        }
    }
}

@Composable
private fun Status(entry: TimelineEntry) {
    if (entry.kind == EntryKind.Gallery) {
        val line = when (entry.state) {
            EntryState.Done -> stringResource(R.string.gallery_done, entry.count) + entry.detail.let { if (it.isEmpty()) "" else " · $it" }
            else -> stringResource(R.string.gallery_progress, entry.count, entry.totalCount, formatBytes(entry.bytes), formatBytes(entry.totalBytes)) +
                entry.detail.let { if (it.isEmpty()) "" else " · $it" }
        }
        Text(line, style = MaterialTheme.typography.bodySmall)
        if (entry.state == EntryState.Active || entry.state == EntryState.Paused) {
            LinearProgressIndicator(progress = { fraction(entry.count.toLong(), entry.totalCount.toLong()) }, Modifier.fillMaxWidth())
        }
        return
    }
    when (entry.state) {
        EntryState.Active -> if (entry.kind == EntryKind.File) {
            LinearProgressIndicator(progress = { fraction(entry.bytes, entry.totalBytes) }, Modifier.fillMaxWidth())
            Text("${formatBytes(entry.bytes)} of ${formatBytes(entry.totalBytes)}", style = MaterialTheme.typography.bodySmall)
        }
        EntryState.Paused -> Text(stringResource(R.string.state_paused), style = MaterialTheme.typography.bodySmall)
        EntryState.Failed -> Text(
            listOf(stringResource(R.string.state_failed), entry.detail).filter { it.isNotEmpty() }.joinToString(": "),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
        )
        EntryState.Done -> Unit
    }
}

private fun fraction(done: Long, total: Long) = if (total <= 0) 0f else (done.toFloat() / total).coerceIn(0f, 1f)
