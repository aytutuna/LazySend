#if os(iOS)
import LazySendKit
import XCTest
@testable import LazySendIOS

final class GalleryTests: XCTestCase {
    private let taken = Date(timeIntervalSince1970: 1_700_000_000)

    private func resource(_ kind: String, _ name: String, _ uti: String, size: Int64 = 1000) -> ResourceInfo {
        ResourceInfo(localIdentifier: "A1B2/L0/001", kind: kind, filename: name, uti: uti, creationDate: taken, size: size)
    }

    func testAPhotoBecomesOneItem() {
        let entries = galleryEntries([resource("photo", "IMG_0001.HEIC", "public.heic", size: 2_500_000)])
        XCTAssertEqual(entries, [
            GalleryEntry(sourceId: "A1B2/L0/001#photo", kind: "photo", name: "IMG_0001.HEIC", mime: "image/heic", modified: taken, sizeHint: 2_500_000),
        ])
    }

    func testALivePhotoBecomesAPhotoAndAVideo() {
        let entries = galleryEntries([
            resource("photo", "IMG_0002.HEIC", "public.heic"),
            resource("pairedVideo", "IMG_0002.MOV", "com.apple.quicktime-movie"),
        ])
        XCTAssertEqual(entries.map(\.sourceId), ["A1B2/L0/001#photo", "A1B2/L0/001#pairedVideo"])
        XCTAssertEqual(entries.map(\.name), ["IMG_0002.HEIC", "IMG_0002.MOV"])
        XCTAssertEqual(entries[1].mime, "video/quicktime")
    }

    func testEditsAndAdjustmentsAreLeftOut() {
        let entries = galleryEntries([
            resource("photo", "IMG_0003.JPG", "public.jpeg"),
            resource("other", "FullSizeRender.JPG", "public.jpeg"),
            resource("other", "Adjustments.plist", "com.apple.property-list"),
        ])
        XCTAssertEqual(entries.map(\.name), ["IMG_0003.JPG"])
        XCTAssertEqual(entries[0].mime, "image/jpeg")
    }

    func testAssetsSavedByTheAppAreNotSentBack() {
        let saved = ResourceInfo(localIdentifier: "SAVED/L0/001", kind: "photo", filename: "IMG_0009.JPG", uti: "public.jpeg", creationDate: taken, size: 10)
        let entries = galleryEntries([resource("photo", "IMG_0005.JPG", "public.jpeg"), saved], skipping: ["SAVED/L0/001"])
        XCTAssertEqual(entries.map(\.name), ["IMG_0005.JPG"])
    }

    func testSavedAssetsSurviveARelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lazysend-\(UUID().uuidString)/saved.json")
        let first = SavedAssets(file: file)
        first.insert("A/L0/001")
        first.insert("B/L0/001")
        XCTAssertEqual(SavedAssets(file: file).all, ["A/L0/001", "B/L0/001"])
    }

    func testAVideoKeepsItsName() {
        let entries = galleryEntries([resource("video", "IMG_0004.MOV", "com.apple.quicktime-movie")])
        XCTAssertEqual(entries.map(\.sourceId), ["A1B2/L0/001#video"])
    }

    func testProgressFillsTheEntryAndShowsTheLink() {
        var entry = TimelineEntry(id: "gallery-pc", direction: .sent, kind: .gallery, pcName: "Office PC", title: "Photos and videos")
        entry.apply(GalleryProgress(phase: .looking, count: 0, totalCount: 40, bytes: 0, totalBytes: 0, failed: 0), pcName: "Office PC", link: nil)
        XCTAssertEqual(entry.totalCount, 40)
        XCTAssertEqual(entry.detail, "Looking for what is new")
        entry.apply(GalleryProgress(phase: .sending, count: 10, totalCount: 40, bytes: 500, totalBytes: 2000, failed: 0), pcName: "Office PC", link: .wifi)
        XCTAssertEqual([entry.count, entry.totalCount], [10, 40])
        XCTAssertEqual([entry.bytes, entry.totalBytes], [500, 2000])
        XCTAssertEqual(entry.detail, "Wi-Fi")
        XCTAssertEqual(entry.state, .active)
    }

    func testWaitingKeepsTheEntryActiveAndNamesThePc() {
        var entry = TimelineEntry(id: "gallery-pc", direction: .sent, kind: .gallery, pcName: "Office PC", title: "Photos and videos", count: 3, totalCount: 9)
        entry.apply(GalleryProgress(phase: .waiting, count: 3, totalCount: 9, bytes: 10, totalBytes: 90, failed: 0), pcName: "Office PC", link: .wifi)
        XCTAssertEqual(entry.state, .active)
        XCTAssertEqual(entry.detail, "Waiting for Office PC")
    }

    func testFinishingCountsWhatWasSentAndWhatWasNot() {
        var entry = TimelineEntry(id: "gallery-pc", direction: .sent, kind: .gallery, pcName: "Office PC", title: "Photos and videos",
                                  bytes: 10, totalBytes: 100, count: 5, totalCount: 12)
        entry.finish(.finished(sent: 6, failed: 2), pcName: "Office PC")
        XCTAssertEqual(entry.state, .done)
        XCTAssertEqual(entry.count, 10)
        XCTAssertEqual(entry.bytes, 100)
        XCTAssertEqual(entry.detail, "2 could not be sent")
        entry.finish(.finished(sent: 12, failed: 0), pcName: "Office PC")
        XCTAssertEqual(entry.detail, "")
        XCTAssertEqual(entry.count, 12)
    }

    func testForgottenAndFullDiskFailTheEntry() {
        var entry = TimelineEntry(id: "gallery-pc", direction: .sent, kind: .gallery, pcName: "Office PC", title: "Photos and videos")
        entry.finish(.forgotten, pcName: "Office PC")
        XCTAssertEqual(entry.state, .failed)
        XCTAssertEqual(entry.detail, "Office PC no longer knows this phone.")
        entry.finish(.diskFull("The PC is almost full."), pcName: "Office PC")
        XCTAssertEqual(entry.detail, "The PC is almost full.")
    }

    func testASyncCutOffByTheSystemResumesButAStoppedOneDoesNot() {
        let paused = TimelineEntry(id: "gallery-office-pc-1", direction: .sent, kind: .gallery, pcName: "Office PC", title: "Photos and videos", state: .paused)
        let done = TimelineEntry(id: "gallery-other-pc", direction: .sent, kind: .gallery, pcName: "Other", title: "Photos and videos", state: .done)
        let file = TimelineEntry(id: "out-1", direction: .sent, kind: .file, pcName: "Office PC", title: "a.pdf", state: .paused)
        XCTAssertEqual(galleryToResume([file, done, paused], pending: true), "office-pc-1")
        XCTAssertNil(galleryToResume([file, done, paused], pending: false))
        XCTAssertNil(galleryToResume([file, done], pending: true))
    }
}
#endif
