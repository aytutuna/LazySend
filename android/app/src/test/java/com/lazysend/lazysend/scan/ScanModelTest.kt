package com.lazysend.lazysend.scan

import com.lazysend.lazysend.R
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], application = android.app.Application::class)
class ScanModelTest {
    private val folders = ArrayList<File>()

    @After
    fun tearDown() {
        folders.forEach { it.deleteRecursively() }
    }

    private class FakeCamera(var photo: ByteArray?, override var ready: Boolean = true) : ScanCamera {
        var taken = 0

        override suspend fun takePhoto(): ByteArray? {
            taken++
            return photo
        }
    }

    private fun photo(shade: Int = 120) = RgbaImage.filled(120, 160, shade, shade, shade)

    private fun page(shade: Int = 120, id: UUID = UUID.randomUUID()) =
        PagePipeline.wholePage(photo(shade), CaptureFilter.Original, id)!!

    private fun jpeg(shade: Int = 120) = JpegEncoder.encode(photo(shade), false)!!

    private fun makeStore(): ScanPageStore {
        val folder = File(System.getProperty("java.io.tmpdir"), "scan-model-" + UUID.randomUUID())
        folders.add(folder)
        return ScanPageStore(folder)
    }

    private fun TestScope.model(
        store: ScanPageStore? = null,
        finder: CornerModel? = null,
        send: suspend (List<ScanPage>) -> String = { "Scan.pdf" },
        clock: () -> Long = { 0L },
        fixedLive: LiveQuadUpdate? = null,
    ): ScanModel {
        val dispatcher = StandardTestDispatcher(testScheduler)
        // Not backgroundScope: advanceUntilIdle leaves the work of that one alone.
        return ScanModel(CoroutineScope(dispatcher), store, finder, ScanFrameFeed(null), send, dispatcher, dispatcher, clock, fixedLive)
    }

    private fun TestScope.modelWith(shades: List<Int>, store: ScanPageStore? = null): ScanModel {
        val scan = model(store)
        for (shade in shades) scan.add(page(shade), byteArrayOf(shade.toByte()))
        return scan
    }

    private fun ScanModel.ids() = pages.value.map { it.id }

    private fun update(shouldCapture: Boolean) =
        LiveQuadUpdate(null, CaptureState.Captured, 1.0, 0.0, shouldCapture = shouldCapture)

    @Test
    fun pagesAreShownInTheOrderTheyWereTakenAndKeptInTheStore() = runTest {
        val store = makeStore()
        val scan = modelWith(listOf(10, 20, 30), store)
        scan.waitForDisk()
        assertEquals(scan.ids(), store.load().map { it.id })
        assertEquals(listOf<Byte>(10, 20, 30), scan.ids().map { store.source(it)!!.single() })
    }

    @Test
    fun aPageWrittenAfterTheScopeIsCancelledStillLands() = runTest {
        val store = makeStore()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = CoroutineScope(dispatcher)
        val scan = ScanModel(scope, store, null, ScanFrameFeed(null), { "Scan.pdf" }, dispatcher, dispatcher)
        advanceUntilIdle()
        val page = page(10)
        scan.add(page, jpeg(10))
        scope.cancel()
        advanceUntilIdle()
        assertEquals(listOf(page.id), store.load().map { it.id })
    }

    @Test
    fun aPageMovesEarlierAndLaterAndStopsAtTheEnds() = runTest {
        val scan = modelWith(listOf(10, 20, 30))
        val ids = scan.ids()
        scan.shift(ids[1], -1)
        assertEquals(listOf(ids[1], ids[0], ids[2]), scan.ids())
        scan.shift(ids[1], -1)
        assertEquals(listOf(ids[1], ids[0], ids[2]), scan.ids())
        repeat(3) { scan.shift(ids[1], 1) }
        assertEquals(listOf(ids[0], ids[2], ids[1]), scan.ids())
    }

    @Test
    fun pagesCanBeDraggedAndDeleted() = runTest {
        val scan = modelWith(listOf(10, 20, 30))
        val ids = scan.ids()
        scan.move(0, 2)
        assertEquals(listOf(ids[1], ids[2], ids[0]), scan.ids())
        scan.delete(scan.pages.value[1].id)
        assertEquals(listOf(ids[1], ids[0]), scan.ids())
    }

    @Test
    fun pagesComeBackInOrderWhenTheModelIsMadeAgain() = runTest {
        val store = makeStore()
        val scan = modelWith(listOf(10, 20, 30), store)
        val ids = scan.ids()
        scan.shift(ids[0], 1)
        scan.waitForDisk()
        val again = model(store)
        again.waitForDisk()
        assertEquals(listOf(ids[1], ids[0], ids[2]), again.ids())
        assertEquals(scan.pages.value[0], again.pages.value[0])
        assertNotNull(again.thumbnail(again.pages.value[0]))
    }

    @Test
    fun aPageTakenBeforeTheStoredOnesAreReadGoesAfterThem() = runTest {
        val store = makeStore()
        val first = modelWith(listOf(10, 20), store)
        first.waitForDisk()
        val again = model(store)
        val late = page(30)
        again.add(late, byteArrayOf(30))
        assertEquals(listOf(late.id), again.ids())
        again.waitForDisk()
        assertEquals(first.ids() + late.id, again.ids())
        assertEquals(first.ids() + late.id, store.load().map { it.id })
    }

    @Test
    fun aPageDeletedBeforeTheStoredOnesAreReadDoesNotComeBack() = runTest {
        val store = makeStore()
        val first = modelWith(listOf(10, 20), store)
        first.waitForDisk()
        val again = model(store)
        again.delete(first.ids()[0])
        again.waitForDisk()
        assertEquals(listOf(first.ids()[1]), again.ids())
        assertEquals(listOf(first.ids()[1]), store.load().map { it.id })
    }

    @Test
    fun anOrderChangedBeforeTheStoredOnesAreReadIsWrittenOnceTheyAre() = runTest {
        val store = makeStore()
        val first = modelWith(listOf(10, 20), store)
        first.waitForDisk()
        val again = model(store)
        val late = page(30)
        again.add(late, byteArrayOf(30))
        again.move(0, 0)
        again.waitForDisk()
        again.shift(late.id, -1)
        again.waitForDisk()
        assertEquals(listOf(first.ids()[0], late.id, first.ids()[1]), store.load().map { it.id })
    }

    @Test
    fun aDeletedPageStaysGoneAfterARelaunch() = runTest {
        val store = makeStore()
        val scan = modelWith(listOf(10, 20, 30), store)
        val ids = scan.ids()
        scan.delete(ids[1])
        scan.waitForDisk()
        assertNull(store.source(ids[1]))
        val again = model(store)
        again.waitForDisk()
        assertEquals(listOf(ids[0], ids[2]), again.ids())
    }

    @Test
    fun aDraggedOrderIsKeptAfterARelaunch() = runTest {
        val store = makeStore()
        val scan = modelWith(listOf(10, 20, 30), store)
        val ids = scan.ids()
        scan.move(0, 2)
        scan.waitForDisk()
        val again = model(store)
        again.waitForDisk()
        assertEquals(listOf(ids[1], ids[2], ids[0]), again.ids())
    }

    @Test
    fun aRecutReadsThePhotoFromTheStoreAndKeepsItsPlace() = runTest {
        val store = makeStore()
        val scan = model(store)
        val page = page(20)
        scan.add(page, jpeg(20))
        scan.waitForDisk()
        val again = model(store)
        again.waitForDisk()
        again.recut(again.pages.value[0])
        assertTrue(again.working.value)
        advanceUntilIdle()
        val request = again.pageEditing.value!!
        assertFalse(again.working.value)
        assertEquals(page.id, request.replacing)
        assertEquals(120, request.photo.width)
        assertEquals(160, request.photo.height)
    }

    @Test
    fun aCutAgainAnsweredAfterItsPageWasDeletedDoesNotBringItBack() = runTest {
        val scan = modelWith(listOf(10, 20))
        val target = scan.pages.value[0]
        val request = CornerRequest(photo(10), byteArrayOf(10), target.corners, CaptureFilter.Original, target.id)
        scan.delete(target.id)
        scan.answer(request, CornerAnswer.Whole)
        advanceUntilIdle()
        assertEquals(1, scan.pages.value.size)
        assertTrue(scan.pages.value.none { it.id == target.id })
        assertFalse(scan.working.value)
    }

    @Test
    fun aRecutStillWorksForAPageThatCouldNotBeSaved() = runTest {
        // A file where the folder should be, so nothing can be written.
        val blocked = File(System.getProperty("java.io.tmpdir"), "scan-model-" + UUID.randomUUID())
        folders.add(blocked)
        blocked.writeText("")
        val scan = model(ScanPageStore(blocked))
        val page = page(40)
        scan.add(page, jpeg(40))
        scan.waitForDisk()
        advanceUntilIdle()
        assertEquals(ScanProblem.Res(R.string.scan_page_not_saved), scan.problem.value)
        scan.recut(scan.pages.value[0])
        advanceUntilIdle()
        assertEquals(page.id, scan.pageEditing.value!!.replacing)
    }

    @Test
    fun aPageCutAgainKeepsItsPlaceAndTakesTheNewCorners() = runTest {
        val scan = modelWith(listOf(10, 20, 30))
        val target = scan.pages.value[1]
        val corners = Quad(Pt(10.0, 10.0), Pt(100.0, 14.0), Pt(96.0, 150.0), Pt(12.0, 140.0))
        val request = CornerRequest(photo(20), byteArrayOf(20), target.corners, CaptureFilter.Original, target.id)
        scan.answer(request, CornerAnswer.Use(corners))
        advanceUntilIdle()
        assertEquals(3, scan.pages.value.size)
        assertEquals(target.id, scan.pages.value[1].id)
        assertEquals(corners, scan.pages.value[1].corners)
        assertTrue(scan.pages.value[1].width != target.width)
    }

    @Test
    fun aShotTheEditorIsOpenedForBecomesAPageWithUseWholePhoto() = runTest {
        val scan = model()
        scan.hasTarget = true
        scan.camera = FakeCamera(jpeg())
        scan.shoot()
        advanceUntilIdle()
        // No model: the page is not found, so the photo goes to the corner editor.
        val request = scan.shotEditing.value!!
        assertTrue(scan.pages.value.isEmpty())
        assertFalse(scan.working.value)
        assertNull(request.replacing)
        scan.answer(request, CornerAnswer.Whole)
        assertNull(scan.shotEditing.value)
        advanceUntilIdle()
        assertEquals(1, scan.pages.value.size)
        assertEquals(120, scan.pages.value[0].width)
        assertEquals(160, scan.pages.value[0].height)
    }

    @Test
    fun aLeftOutShotAddsNoPage() = runTest {
        val scan = modelWith(listOf(10))
        val request = CornerRequest(photo(), byteArrayOf(1), PageFinder.startCorners(120, 160), CaptureFilter.Original, null)
        scan.answer(request, CornerAnswer.Cancel)
        advanceUntilIdle()
        assertEquals(1, scan.pages.value.size)
        assertFalse(scan.working.value)
    }

    @Test
    fun aClearlyFoundShotIsCutOutAtOnce() = runTest {
        val scan = model(finder = ScanDemo.finder())
        scan.hasTarget = true
        scan.camera = FakeCamera(ScanDemo.photo)
        scan.shoot()
        advanceUntilIdle()
        assertNull(scan.shotEditing.value)
        assertEquals(1, scan.pages.value.size)
        assertEquals(CaptureFilter.Enhanced, scan.pages.value[0].filter)
    }

    @Test
    fun aShotThatCannotBeTakenOrReadSaysSo() = runTest {
        val scan = model()
        scan.hasTarget = true
        val camera = FakeCamera(null)
        scan.camera = camera
        scan.shoot()
        advanceUntilIdle()
        assertEquals(ScanProblem.Res(R.string.camera_photo_failed), scan.problem.value)
        assertFalse(scan.working.value)
        camera.photo = byteArrayOf(1, 2, 3)
        scan.shoot()
        assertNull(scan.problem.value)
        advanceUntilIdle()
        assertEquals(ScanProblem.Res(R.string.scan_photo_unreadable), scan.problem.value)
        assertFalse(scan.working.value)
        assertTrue(scan.pages.value.isEmpty())
    }

    @Test
    fun aPhotoIsTakenOnlyWithADeviceAReadyCameraAndNothingInTheWay() = runTest {
        val scan = model()
        val camera = FakeCamera(jpeg())
        assertFalse(scan.canShoot)
        scan.camera = camera
        assertFalse(scan.canShoot)
        scan.hasTarget = true
        assertTrue(scan.canShoot)
        camera.ready = false
        assertFalse(scan.canShoot)
        camera.ready = true
        scan.shoot()
        assertFalse(scan.canShoot)
        scan.shoot()
        advanceUntilIdle()
        assertEquals(1, camera.taken)
        // The editor is open for the shot: another is not taken.
        assertNotNull(scan.shotEditing.value)
        assertFalse(scan.canShoot)
    }

    @Test
    fun sendingTheScanEmptiesThePagesAndKeepsTheFileName() = runTest {
        val scan = modelWith(listOf(10, 20))
        scan.sent("Scan 2026-11-18 14.05.pdf", scan.ids())
        assertTrue(scan.pages.value.isEmpty())
        assertEquals("Scan 2026-11-18 14.05.pdf", scan.lastName.value)
        // The next page it takes clears the line about the last scan.
        scan.add(page(), byteArrayOf(1))
        assertNull(scan.lastName.value)
    }

    @Test
    fun sendingTheScanClearsItsPagesFromTheStore() = runTest {
        val store = makeStore()
        val scan = modelWith(listOf(10, 20), store)
        val ids = scan.ids()
        scan.sent("Scan.pdf", ids)
        scan.waitForDisk()
        assertTrue(store.load().isEmpty())
        assertNull(store.source(ids[0]))
        val again = model(store)
        again.waitForDisk()
        assertTrue(again.pages.value.isEmpty())
    }

    @Test
    fun aPageTakenWhileTheScanWasBeingSentSurvivesTheSend() = runTest {
        val store = makeStore()
        val scan = modelWith(listOf(10, 20), store)
        val sending = scan.ids()
        val late = page(30)
        scan.add(late, byteArrayOf(30))
        scan.sent("Scan.pdf", sending)
        assertEquals(listOf(late.id), scan.ids())
        scan.waitForDisk()
        assertEquals(listOf(late.id), store.load().map { it.id })
        assertEquals(30.toByte(), store.source(late.id)!!.single())
    }

    @Test
    fun doneSendsThePagesAndDisablesEditingWhileItDoes() = runTest {
        val gate = CompletableDeferred<String>()
        var sentPages = emptyList<ScanPage>()
        val scan = model(send = { sentPages = it; gate.await() })
        scan.add(page(10), byteArrayOf(10))
        scan.add(page(20), byteArrayOf(20))
        val ids = scan.ids()
        advanceUntilIdle()
        assertTrue(scan.canCrop.value)
        assertFalse(scan.busy.value)
        scan.done()
        advanceUntilIdle()
        assertTrue(scan.sending.value)
        assertFalse(scan.canCrop.value)
        assertTrue(scan.busy.value)
        // A second Done while one is going is ignored.
        scan.done()
        gate.complete("Scan 2026-11-18 14.05.pdf")
        advanceUntilIdle()
        assertEquals(ids, sentPages.map { it.id })
        assertFalse(scan.sending.value)
        assertTrue(scan.pages.value.isEmpty())
        assertEquals("Scan 2026-11-18 14.05.pdf", scan.lastName.value)
        assertTrue(scan.canCrop.value)
    }

    @Test
    fun aFailedSendKeepsThePagesAndSaysWhy() = runTest {
        var reason: String? = "That device is not paired any more."
        val scan = model(send = { throw java.io.IOException(reason) })
        scan.add(page(10), byteArrayOf(10))
        scan.done()
        advanceUntilIdle()
        assertEquals(1, scan.pages.value.size)
        assertFalse(scan.sending.value)
        assertEquals(ScanProblem.Message("That device is not paired any more."), scan.problem.value)
        reason = null
        scan.done()
        advanceUntilIdle()
        assertEquals(ScanProblem.Res(R.string.scan_not_sent), scan.problem.value)
        assertEquals(1, scan.pages.value.size)
    }

    @Test
    fun theCameraTakesFramesOnlyWhileAttachedAndNotCovered() {
        assertTrue(ScanModel.flows(attached = true, covered = false))
        assertFalse(ScanModel.flows(attached = true, covered = true))
        assertFalse(ScanModel.flows(attached = false, covered = false))
    }

    @Test
    fun aDecisionThatCannotBeActedOnIsForgottenSoThePageCanBeDecidedOnAgain() {
        val yes = update(true)
        assertEquals(AutoShot.Take, ScanModel.autoShot(yes, auto = true, canShoot = true, inGrace = false))
        // A shot being made, no device, or the wait after the camera started: forgotten, not left as taken.
        assertEquals(AutoShot.Forget, ScanModel.autoShot(yes, auto = true, canShoot = false, inGrace = false))
        assertEquals(AutoShot.Forget, ScanModel.autoShot(yes, auto = true, canShoot = true, inGrace = true))
        // Auto off: the decision stands for when it is turned on. No decision: nothing.
        assertEquals(AutoShot.None, ScanModel.autoShot(yes, auto = false, canShoot = true, inGrace = false))
        assertEquals(AutoShot.None, ScanModel.autoShot(update(false), auto = true, canShoot = false, inGrace = false))
    }

    @Test
    fun theShutterWaitsOutTheGraceAfterTheCameraStartsThenTakesThePage() = runTest {
        var now = 10_000L
        val demo = update(false)
        val scan = model(clock = { now }, fixedLive = demo)
        scan.hasTarget = true
        val camera = FakeCamera(jpeg())
        scan.camera = camera
        scan.setLive(attached = true, covered = false)
        assertEquals(demo, scan.live.value)
        now += 1000
        scan.apply(update(true))
        advanceUntilIdle()
        assertEquals(0, camera.taken)
        now += 1000
        scan.apply(update(true))
        advanceUntilIdle()
        assertEquals(1, camera.taken)
    }

    @Test
    fun aCoverOnlyStopsTheFramesAndDetachingClearsTheOutline() = runTest {
        val demo = update(false)
        val scan = model(fixedLive = demo)
        scan.setLive(attached = true, covered = false)
        assertEquals(demo, scan.live.value)
        scan.setLive(attached = true, covered = true)
        assertNull(scan.live.value)
        scan.setLive(attached = true, covered = false)
        assertEquals(demo, scan.live.value)
        scan.setLive(attached = false, covered = false)
        assertNull(scan.live.value)
    }

    @Test
    fun theFilterIsKeptForALaterCut() = runTest {
        val scan = model()
        scan.add(PagePipeline.wholePage(photo(), CaptureFilter.Grayscale)!!, ByteArray(0))
        assertEquals(CaptureFilter.Grayscale, scan.pages.value[0].filter)
        assertTrue(scan.pages.value[0].gray)
        assertNotNull(scan.thumbnail(scan.pages.value[0]))
    }
}
