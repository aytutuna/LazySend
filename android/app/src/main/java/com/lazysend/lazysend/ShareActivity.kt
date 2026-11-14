package com.lazysend.lazysend

import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import com.lazysend.lazysend.transfer.SendService

/** The Android share sheet entry: sends what was shared to a paired PC, or queues it for a phone paired with this one, and closes. */
class ShareActivity : androidx.activity.ComponentActivity() {
    private class Target(val name: String, val send: (List<Uri>, String?) -> Unit)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A rotation recreates this activity with the same intent; what was shared has been handled already.
        if (savedInstanceState != null) {
            finish()
            return
        }
        val graph = (application as LazySendApp).graph
        val targets = graph.pcs.pcs.value.map { pc ->
            Target(pc.name) { uris, text -> if (text != null) SendService.sendText(this, pc.id, text) else SendService.sendFiles(this, pc.id, uris) }
        } + graph.host.core.guests.guests.value.map { guest ->
            Target(guest.name) { uris, text -> if (text != null) SendService.queueText(this, guest.id, text) else SendService.queueFiles(this, guest.id, uris) }
        }
        when {
            targets.isEmpty() -> {
                Toast.makeText(this, R.string.share_no_pc, Toast.LENGTH_LONG).show()
                startActivity(Intent(this, MainActivity::class.java))
                finish()
            }
            targets.size == 1 -> deliver(targets.first())
            else -> {
                AlertDialog.Builder(this)
                    .setTitle(R.string.share_choose_pc)
                    .setItems(targets.map { it.name }.toTypedArray()) { _, which -> deliver(targets[which]) }
                    .setOnCancelListener { finish() }
                    .show()
            }
        }
    }

    private fun deliver(target: Target) {
        val uris = sharedUris()
        val text = if (uris.isEmpty()) intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() else null
        // The service keeps going after this activity is gone, which a coroutine of this activity would not.
        target.send(uris, text)
        Toast.makeText(this, getString(R.string.share_sending, target.name), Toast.LENGTH_SHORT).show()
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
