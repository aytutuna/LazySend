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
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.runtime.collectAsState
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.lazysend.lazysend.data.EntryKind
import com.lazysend.lazysend.data.TimelineEntry
import com.lazysend.lazysend.scan.ScanDemo
import com.lazysend.lazysend.transfer.SendService
import com.lazysend.lazysend.transfer.shareableUri
import com.lazysend.lazysend.ui.AppViewModel
import com.lazysend.lazysend.ui.CameraScreen
import com.lazysend.lazysend.ui.ClipboardScreen
import com.lazysend.lazysend.ui.LazySendTheme
import com.lazysend.lazysend.ui.MainActions
import com.lazysend.lazysend.ui.MainScreen
import com.lazysend.lazysend.ui.PairScreen
import com.lazysend.lazysend.ui.PcsScreen
import com.lazysend.lazysend.ui.PhotoAccess
import com.lazysend.lazysend.ui.ReceiveScreen
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch

private enum class Tab { Camera, Files, Clipboard }

private enum class Screen { Main, Pair, Pcs, Receive }

class MainActivity : ComponentActivity() {
    private val model: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Read before the view model is first used, which builds the scan model with or without the demo.
        if (BuildConfig.DEBUG) ScanDemo.configure(intent)
        enableEdgeToEdge()
        lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.STARTED) { model.watch() } }
        // The service that keeps hosting going with the screen off can only be started from the front.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                model.resumeHosting()
                launch { model.resendKept() }
                model.keepHosting.collect { if (it) SendService.keepHosting(this@MainActivity) }
            }
        }
        setContent { LazySendTheme { App() } }
    }

    override fun onResume() {
        super.onResume()
        model.photoAccess(photoAccess(this))
        localNetworkDenied = isLocalNetworkDenied(this)
    }

    @Composable
    private fun App() {
        var tab by rememberSaveable { mutableStateOf(Tab.Camera) }
        var scanning by rememberSaveable { mutableStateOf(BuildConfig.DEBUG && ScanDemo.on) }
        val scanFilter by model.scanFilter.collectAsState()
        val scanAuto by model.scanAuto.collectAsState()
        var screen by rememberSaveable { mutableStateOf(Screen.Main) }
        // The camera asks for its permission once the start-up requests have been answered, as two requests at once cancel each other.
        var startupAsked by rememberSaveable { mutableStateOf(false) }
        var cameraAsked by rememberSaveable { mutableStateOf(false) }
        val state by model.state.collectAsState()
        val pair by model.pair.collectAsState()

        val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            localNetworkDenied = isLocalNetworkDenied(this@MainActivity)
            startupAsked = true
        }
        LaunchedEffect(Unit) {
            val wanted = buildList {
                if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
                if (Build.VERSION.SDK_INT >= 37) add(LOCAL_NETWORK)
                if (Build.VERSION.SDK_INT <= 28) add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }.filter { ContextCompat.checkSelfPermission(this@MainActivity, it) != PackageManager.PERMISSION_GRANTED }
            if (wanted.isNotEmpty()) permissions.launch(wanted.toTypedArray()) else startupAsked = true
        }

        val photoPermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            val access = photoAccess(this@MainActivity)
            model.photoAccess(access)
            if (access != PhotoAccess.None && pendingGallery) {
                model.selectedPc()?.let { SendService.syncGallery(this@MainActivity, it.id) }
            }
            if (access != PhotoAccess.None) model.resumeFeeds()
            if (access != PhotoAccess.None && pendingFeed) model.startFeed()
            pendingGallery = false
            pendingFeed = false
        }
        fun requestPhotos() = photoPermissions.launch(photoPermissionList())

        val files = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris -> model.sendPicked(uris, photos = false) }
        val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris -> model.sendPicked(uris, photos = true) }

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
        fun openTab(next: Tab) {
            if (next != Tab.Files) goMain()
            tab = next
        }
        fun pairDevice() {
            model.startPairing()
            screen = Screen.Pair
            tab = Tab.Files
        }
        if (tab == Tab.Files && screen != Screen.Main) BackHandler { goMain() }
        val shot by model.shot.collectAsState()
        val cameraProblem by model.cameraProblem.collectAsState()
        val clipProblem by model.clipProblem.collectAsState()
        val saveCameraPhotos by model.saveCameraPhotos.collectAsState()
        val target = state.pcs.firstOrNull { it.id == state.selected }
        val tabs = listOf(
            Triple(Tab.Camera, R.drawable.ic_tab_camera, R.string.tab_camera),
            Triple(Tab.Files, R.drawable.ic_tab_files, R.string.tab_files),
            Triple(Tab.Clipboard, R.drawable.ic_tab_clipboard, R.string.tab_clipboard),
        )
        Scaffold(
            bottomBar = {
                NavigationBar {
                    tabs.forEach { (item, icon, label) ->
                        NavigationBarItem(
                            selected = tab == item,
                            onClick = { openTab(item) },
                            icon = { Icon(painterResource(icon), null) },
                            label = { Text(stringResource(label)) },
                        )
                    }
                }
            },
        ) { padding ->
            Box(Modifier.padding(padding).consumeWindowInsets(padding)) {
                when (tab) {
                    Tab.Camera -> CameraScreen(
                        canAsk = startupAsked,
                        asked = cameraAsked,
                        onAsked = { cameraAsked = true },
                        targets = state.pcs,
                        selected = state.selected,
                        entries = state.entries,
                        shot = shot,
                        problem = cameraProblem,
                        onSelect = model::select,
                        onPair = ::pairDevice,
                        onHistory = { openTab(Tab.Files) },
                        newFile = model::newPhotoFile,
                        onTaken = model::photoTaken,
                        onFailed = model::cameraFailed,
                        onClearProblem = model::clearCameraProblem,
                        format = state.format,
                        onFormat = model::photoFormat,
                        scan = model.scan,
                        scanning = scanning,
                        onScanning = { scanning = it },
                        scanFilter = scanFilter,
                        onScanFilter = model::setScanFilter,
                        scanAuto = scanAuto,
                        onScanAuto = model::setScanAuto,
                    )
                    Tab.Clipboard -> ClipboardScreen(
                        target = target,
                        entries = state.entries,
                        problem = clipProblem,
                        onPaste = model::paste,
                        onSendText = model::sendClipText,
                        onPair = ::pairDevice,
                        actions = MainActions(onCopy = { copy(it) }, onOpen = { open(it) }),
                    )
                    Tab.Files -> when (screen) {
                        Screen.Main -> MainScreen(
                            state,
                            MainActions(
                                onPair = {
                                    model.startPairing()
                                    screen = Screen.Pair
                                },
                                onPcs = { screen = Screen.Pcs },
                                onReceive = { screen = Screen.Receive },
                                onPhotos = { photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) },
                                onFiles = { files.launch("*/*") },
                                onFormat = model::photoFormat,
                                onSelect = model::select,
                                onGallery = {
                                    if (photoAccess(this@MainActivity) == PhotoAccess.None) {
                                        pendingGallery = true
                                        requestPhotos()
                                    } else {
                                        model.selectedPc()?.let { SendService.syncGallery(this@MainActivity, it.id) }
                                    }
                                },
                                onResume = { entry ->
                                    if (entry.kind == EntryKind.Gallery) model.resumeGallery(entry.id) else model.resend(entry.id)
                                },
                                onFeed = {
                                    if (photoAccess(this@MainActivity) == PhotoAccess.None) {
                                        pendingFeed = true
                                        requestPhotos()
                                    } else {
                                        model.startFeed()
                                    }
                                },
                                onStopFeed = model::stopFeed,
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
                        Screen.Receive -> ReceiveScreen(
                            receive,
                            onAnswer = model::answer,
                            onCopy = { copy(it) },
                            onShare = { share(it) },
                            onNewCode = model::newCode,
                            localNetworkDenied = localNetworkDenied,
                            onAllowNetwork = { permissions.launch(arrayOf(LOCAL_NETWORK)) },
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
                            saveCameraPhotos = saveCameraPhotos,
                            onSaveCameraPhotos = { on ->
                                model.saveCameraPhotos(on)
                                // Before Android 10 the gallery needs the storage permission, so it is asked for again here.
                                if (on && Build.VERSION.SDK_INT <= 28 &&
                                    ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
                                ) permissions.launch(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE))
                            },
                        )
                    }
                }
            }
        }
    }

    private var pendingGallery = false
    private var pendingFeed = false

    // From Android 17 other devices on the network reach this phone only with the local network permission.
    private var localNetworkDenied by mutableStateOf(false)

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
            Intent(Intent.ACTION_VIEW).setDataAndType(shareableUri(this, Uri.parse(entry.uri ?: return)), entry.mime ?: "*/*")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
        } catch (e: Exception) {
            // Nothing on this phone opens it.
        }
    }

    companion object {
        const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"

        fun isLocalNetworkDenied(context: Context) =
            Build.VERSION.SDK_INT >= 37 && ContextCompat.checkSelfPermission(context, LOCAL_NETWORK) != PackageManager.PERMISSION_GRANTED

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
