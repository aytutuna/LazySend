package com.lazysend.lazysend.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.lazysend.lazysend.R
import com.lazysend.lazysend.host.Approval
import com.lazysend.lazysend.host.ReceiveState

data class ReceiveUi(val host: ReceiveState = ReceiveState(), val approval: Approval? = null, val guests: List<String> = emptyList())

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReceiveScreen(
    ui: ReceiveUi,
    onAnswer: (Approval, Boolean) -> Unit,
    onCopy: (String) -> Unit,
    onShare: (String) -> Unit,
    onStop: () -> Unit,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.receive_title)) },
                navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.back)) } },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val host = ui.host
            val pairing = host.pairing
            when {
                host.error != null -> Text(host.error, color = MaterialTheme.colorScheme.error)
                !host.running || pairing == null -> Text(stringResource(R.string.receive_starting))
                else -> {
                    Text(stringResource(R.string.receive_hint), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (host.link == null) Text(stringResource(R.string.receive_no_network), color = MaterialTheme.colorScheme.error)
                    QrCode(pairing.link, Modifier.size(240.dp))
                    Text(stringResource(R.string.pair_check_code) + ": " + pairing.checkDigits, style = MaterialTheme.typography.bodyMedium)
                    Text(stringResource(R.string.receive_code_label), style = MaterialTheme.typography.labelLarge)
                    Text(pairing.shortCode, style = MaterialTheme.typography.headlineLarge, fontFamily = FontFamily.Monospace)
                    Text(stringResource(R.string.receive_digits, pairing.matchDigits), style = MaterialTheme.typography.bodyMedium)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { onCopy(pairing.link) }) { Text(stringResource(R.string.receive_copy_link)) }
                        OutlinedButton(onClick = { onShare(pairing.link) }) { Text(stringResource(R.string.receive_share_link)) }
                    }
                }
            }
            if (ui.guests.isNotEmpty()) {
                Text(stringResource(R.string.receive_paired_title), style = MaterialTheme.typography.titleSmall, modifier = Modifier.fillMaxWidth())
                ui.guests.forEach { Text(it, modifier = Modifier.fillMaxWidth()) }
            }
            Button(onClick = onStop) { Text(stringResource(R.string.receive_stop)) }
        }
    }
    ui.approval?.let { ApprovalDialog(it.guestName, it.digits) { allow -> onAnswer(it, allow) } }
}

/**
 * The question put to the person when a device presents a valid code. Only the two buttons answer it: tapping outside or
 * pressing back does nothing, and leaving the screen declines it on the host's side.
 */
@Composable
fun ApprovalDialog(guestName: String, digits: String, onAnswer: (Boolean) -> Unit) {
    AlertDialog(
        onDismissRequest = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
        title = { Text(stringResource(R.string.approve_title, guestName)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.approve_body))
                Text(digits, style = MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Monospace)
            }
        },
        confirmButton = { Button(onClick = { onAnswer(true) }) { Text(stringResource(R.string.allow)) } },
        dismissButton = { TextButton(onClick = { onAnswer(false) }) { Text(stringResource(R.string.dont_allow)) } },
    )
}

@Composable
private fun QrCode(text: String, modifier: Modifier) {
    val matrix = remember(text) {
        QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, mapOf(EncodeHintType.MARGIN to 2, EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M))
    }
    Canvas(modifier.aspectRatio(1f)) {
        drawRect(Color.White)
        val cell = size.width / matrix.width
        for (x in 0 until matrix.width) {
            for (y in 0 until matrix.height) {
                if (matrix[x, y]) drawRect(Color.Black, Offset(x * cell, y * cell), Size(cell + 0.5f, cell + 0.5f))
            }
        }
    }
}
