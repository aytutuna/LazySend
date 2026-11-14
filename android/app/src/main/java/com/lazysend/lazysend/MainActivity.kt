package com.lazysend.lazysend

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.transfer.SendService
import com.lazysend.lazysend.ui.AppViewModel
import com.lazysend.lazysend.ui.LazySendTheme
import com.lazysend.lazysend.ui.MainActions
import com.lazysend.lazysend.ui.MainScreen
import com.lazysend.lazysend.ui.PairScreen
import com.lazysend.lazysend.ui.PcsScreen
import com.lazysend.lazysend.ui.PhotoAccess
import com.lazysend.lazysend.ui.ReceiveScreen
import com.lazysend.lazysend.ui.SendScreen
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch

private enum class Screen { Main, Pair, Send, Pcs, Receive }

class MainActivity : ComponentActivity() {
    private val model: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.STARTED) { model.watch() } }
        // The service that keeps hosting going with the screen off can only be started from the front.
        lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.STARTED) { model.keepHosting.collect { if (it) SendService.keepHosting(this@MainActivity) } } }
        setContent { LazySendTheme { App() } }
    }

    override fun onResume() {
        super.onResume()
        model.photoAccess(photoAccess(this))
    }

    @Composable
    private fun App() {
        var screen by rememberSaveable { mutableStateOf(Screen.Main) }
        val state by model.state.collectAsState()
        val pair by model.pair.collectAsState()
        val notice by model.notice.collectAsState()

        val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }
        LaunchedEffect(Unit) {
            val wanted = buildList {
                if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
                if (Build.VERSION.SDK_INT >= 37) add(LOCAL_NETWORK)
                if (Build.VERSION.SDK_INT <= 28) add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }.filter { ContextCompat.checkSelfPermission(this@MainActivity, it) != PackageManager.PERMISSION_GRANTED }
            if (wanted.isNotEmpty()) permissions.launch(wanted.toTypedArray())
        }

        val photoPermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            val access = photoAccess(this@MainActivity)
            model.photoAccess(access)
            if (access != PhotoAccess.None && pendingGallery) {
                model.selectedPc()?.let { SendService.syncGallery(this@MainActivity, it.id) }
            }
            pendingGallery = false
        }
        fun requestPhotos() = photoPermissions.launch(photoPermissionList())

        val files = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris -> send(uris) }
        val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris -> send(uris) }

        // Receiving runs while this screen is in front. Leaving the app only declines what waits; the code is closed when the person goes back.
        LaunchedEffect(screen) {
            if (screen == Screen.Receive) {
                repeatOnLifecycle(Lifecycle.State.STARTED) {
                    model.openReceive()
                    try {
                        awaitCancellation()
                    } finally {
                        if (!isChangingConfigurations) model.pauseReceive()
                    }
                }
            }
        }
        val receive by model.receive.collectAsState()

        fun goMain() {
            if (screen == Screen.Receive) model.leaveReceive()
            screen = Screen.Main
        }
        if (screen != Screen.Main) BackHandler { goMain() }
        when (screen) {
            Screen.Main -> MainScreen(
                state,
                MainActions(
                    onPair = {
                        model.startPairing()
                        screen = Screen.Pair
                    },
                    onPcs = { screen = Screen.Pcs },
                    onReceive = { screen = Screen.Receive },
                    onSend = { screen = Screen.Send },
                    onSelect = model::select,
                    onGallery = {
                        if (photoAccess(this@MainActivity) == PhotoAccess.None) {
                            pendingGallery = true
                            requestPhotos()
                        } else {
                            model.selectedPc()?.let { SendService.syncGallery(this@MainActivity, it.id) }
                        }
                    },
                    onStop = { SendService.stop(this@MainActivity) },
                    onAllowPhotos = { requestPhotos() },
                    onCopy = { copy(it) },
                    onOpen = { open(it) },
                ),
            )
            Screen.Pair -> PairScreen(
                pair,
                onCode = model::pair,
                onRetry = model::startPairing,
                onBack = { screen = Screen.Main },
            )
            Screen.Send -> SendScreen(
                pcName = state.pcs.firstOrNull { it.id == state.selected }?.name.orEmpty(),
                notice = notice,
                onText = model::sendText,
                onFiles = {
                    model.clearNotice()
                    files.launch("*/*")
                },
                onPhotos = {
                    model.clearNotice()
                    photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                },
                onBack = {
                    model.clearNotice()
                    screen = Screen.Main
                },
            )
            Screen.Receive -> ReceiveScreen(
                receive,
                onAnswer = model::answer,
                onCopy = { copy(it) },
                onShare = { share(it) },
                onStop = {
                    model.stopReceiving()
                    goMain()
                },
                onBack = { goMain() },
            )
            Screen.Pcs -> PcsScreen(
                state.pcs,
                onRemove = model::remove,
                onPair = {
                    model.startPairing()
                    screen = Screen.Pair
                },
                onBack = { screen = Screen.Main },
            )
        }
    }

    private var pendingGallery = false

    private fun send(uris: List<Uri>) {
        model.selectedGuest()?.let { return SendService.queueFiles(this, it.id, uris) }
        val pc = model.selectedPc() ?: return
        SendService.sendFiles(this, pc.id, uris)
    }

    private fun share(text: String) {
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
    }

    private fun copy(text: String) {
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(null, text))
    }

    private fun open(entry: TimelineEntry) {
        val intent = if (entry.kind == EntryKind.Link) {
            Intent(Intent.ACTION_VIEW, Uri.parse(entry.title))
        } else {
            Intent(Intent.ACTION_VIEW).setDataAndType(shareable(Uri.parse(entry.uri ?: return)), entry.mime ?: "*/*")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
        } catch (e: Exception) {
            // Nothing on this phone opens it.
        }
    }

    // Other apps are refused a file:// address, so files saved before Android 10 are handed over through a provider.
    private fun shareable(uri: Uri): Uri =
        if (uri.scheme == "file") FileProvider.getUriForFile(this, "$packageName.files", java.io.File(uri.path!!)) else uri

    companion object {
        const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"

        fun photoPermissionList(): Array<String> = when {
            Build.VERSION.SDK_INT >= 34 -> arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
            else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

        fun photoAccess(context: Context): PhotoAccess {
            fun granted(permission: String) = ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
            return when {
                Build.VERSION.SDK_INT >= 33 && granted(Manifest.permission.READ_MEDIA_IMAGES) && granted(Manifest.permission.READ_MEDIA_VIDEO) -> PhotoAccess.Full
                Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> PhotoAccess.Partial
                Build.VERSION.SDK_INT < 33 && granted(Manifest.permission.READ_EXTERNAL_STORAGE) -> PhotoAccess.Full
                else -> PhotoAccess.None
            }
        }
    }
}
