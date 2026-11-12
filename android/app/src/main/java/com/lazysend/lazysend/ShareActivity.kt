package com.lazysend.lazysend

import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.lifecycle.lifecycleScope
import com.lazysend.lazysend.data.Pc
import com.lazysend.lazysend.transfer.SendService
import kotlinx.coroutines.launch

/** The Android share sheet entry: sends what was shared to a paired PC and closes. */
class ShareActivity : androidx.activity.ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val graph = (application as LazySendApp).graph
        val pcs = graph.pcs.pcs.value
        when {
            pcs.isEmpty() -> {
                Toast.makeText(this, R.string.share_no_pc, Toast.LENGTH_LONG).show()
                startActivity(Intent(this, MainActivity::class.java))
                finish()
            }
            pcs.size == 1 -> deliver(pcs.first())
            else -> {
                val names = pcs.map { it.name }.toTypedArray()
                AlertDialog.Builder(this)
                    .setTitle(R.string.share_choose_pc)
                    .setItems(names) { _, which -> deliver(pcs[which]) }
                    .setOnCancelListener { finish() }
                    .show()
            }
        }
    }

    private fun deliver(pc: Pc) {
        val graph = (application as LazySendApp).graph
        val uris = sharedUris()
        val text = if (uris.isEmpty()) intent.getStringExtra(Intent.EXTRA_TEXT) else null
        if (text != null) {
            lifecycleScope.launch {
                graph.sender.sendText(pc, text)
                finish()
            }
            Toast.makeText(this, getString(R.string.share_sending, pc.name), Toast.LENGTH_SHORT).show()
            return
        }
        SendService.sendFiles(this, pc.id, uris)
        Toast.makeText(this, getString(R.string.share_sending, pc.name), Toast.LENGTH_SHORT).show()
        finish()
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableExtra(Intent.EXTRA_STREAM),
        )
        Intent.ACTION_SEND_MULTIPLE ->
            (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM))
                .orEmpty()
        else -> emptyList()
    }
}
