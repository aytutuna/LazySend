package com.lazysend.lazysend.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.lazysend.lazysend.R
import com.lazysend.lazysend.data.TimelineEntry

/** The clipboard tab: paste or type to put it on the chosen device's clipboard, and every text and link that went either way. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ClipboardScreen(
    target: PcRow?,
    entries: List<TimelineEntry>,
    problem: String?,
    onPaste: () -> Unit,
    onSendText: (String) -> Boolean,
    onPair: () -> Unit,
    actions: MainActions,
) {
    var draft by rememberSaveable { mutableStateOf("") }
    val keyboard = LocalSoftwareKeyboardController.current
    val recent = textEntries(entries)
    Scaffold(topBar = { TopAppBar(title = { Text(stringResource(R.string.tab_clipboard)) }) }) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (target == null) {
                            Text(stringResource(R.string.clip_pair_title), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Button(onClick = onPair) { Text(stringResource(R.string.pair_device)) }
                        } else {
                            Button(onClick = onPaste) { Text(stringResource(R.string.paste)) }
                            OutlinedTextField(
                                value = draft,
                                onValueChange = { draft = it },
                                modifier = Modifier.fillMaxWidth(),
                                placeholder = { Text(stringResource(R.string.clip_type_hint, target.name)) },
                                minLines = 1,
                                maxLines = 6,
                            )
                            Button(
                                onClick = {
                                    // Kept when it was not taken, so a text that is too long is not lost with the box.
                                    if (onSendText(draft)) {
                                        draft = ""
                                        keyboard?.hide()
                                    }
                                },
                                enabled = draft.isNotBlank(),
                            ) { Text(stringResource(R.string.send)) }
                            Text(stringResource(R.string.clip_hint, target.name), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            problem?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                        }
                    }
                }
            }
            if (recent.isEmpty()) {
                item { Text(stringResource(R.string.clip_empty), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
            items(recent, key = { it.id }) { Entry(it, actions) }
        }
    }
}
