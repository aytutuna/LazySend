package com.lazysend.lazysend.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.lazysend.lazysend.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PcsScreen(pcs: List<PcRow>, onRemove: (String) -> Unit, onPair: () -> Unit, onBack: () -> Unit) {
    var removing by remember { mutableStateOf<PcRow?>(null) }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(stringResource(R.string.pcs_title)) }, navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.back)) } })
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (pcs.isEmpty()) Text(stringResource(R.string.pcs_empty))
            pcs.forEach { pc ->
                Card(Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(pc.name, style = MaterialTheme.typography.titleMedium)
                            Text(
                                if (pc.guest) stringResource(R.string.guest_row)
                                else pc.link?.let { stringResource(R.string.connected_over, it) } ?: stringResource(R.string.not_reachable, pc.name),
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        TextButton(onClick = { removing = pc }) { Text(stringResource(R.string.remove)) }
                    }
                }
            }
            Button(onClick = onPair) { Text(stringResource(R.string.pair_a_pc)) }
        }
    }
    removing?.let { pc ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text(stringResource(R.string.remove_pc_title, pc.name)) },
            text = { Text(if (pc.guest) stringResource(R.string.remove_guest_body, pc.name) else stringResource(R.string.remove_pc_body)) },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    onRemove(pc.id)
                }) { Text(stringResource(R.string.remove)) }
            },
            dismissButton = { TextButton(onClick = { removing = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
