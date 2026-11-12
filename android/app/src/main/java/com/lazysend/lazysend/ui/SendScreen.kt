package com.lazysend.lazysend.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.lazysend.lazysend.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SendScreen(pcName: String, notice: String?, onText: (String) -> Unit, onFiles: () -> Unit, onPhotos: () -> Unit, onBack: () -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.send_title, pcName)) },
                navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.back)) } },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text(stringResource(R.string.send_text_hint)) },
                modifier = Modifier.fillMaxWidth(),
                minLines = 3,
                maxLines = 8,
            )
            Button(
                onClick = {
                    onText(text)
                    text = ""
                },
                enabled = text.isNotBlank(),
            ) { Text(stringResource(R.string.send_text_button)) }
            if (notice != null) Text(notice, color = MaterialTheme.colorScheme.primary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onFiles) { Text(stringResource(R.string.pick_files)) }
                OutlinedButton(onClick = onPhotos) { Text(stringResource(R.string.pick_photos)) }
            }
        }
    }
}
