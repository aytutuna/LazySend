import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import LazySendScan

final class ScanPageTests: XCTestCase {
    private let truth = PhotoScenes.woodMap.corners(PhotoScenes.pageWidth, PhotoScenes.pageHeight)

    private func jpegSize(_ data: Data) throws -> (width: Int, height: Int, components: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let picture = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]))
        return (picture.width, picture.height, picture.colorSpace?.numberOfComponents ?? 0)
    }

    func testAPhotoIsCutOutAlongItsCornersAndKeepsThemForALaterCut() throws {
        let photo = PhotoScenes.woodScene()
        let page = try XCTUnwrap(PagePipeline.page(photo: photo, corners: truth, filter: .enhanced))
        XCTAssertEqual(page.corners, truth)
        let size = try jpegSize(page.jpeg)
        XCTAssertEqual(size.width, page.width)
        XCTAssertEqual(size.height, page.height)
        // An A4 sheet: 1.414 times as long as wide.
        XCTAssertEqual(Double(page.height) / Double(page.width), 1.4142, accuracy: 0.06)
        XCTAssertTrue((PagePipeline.minDPI...PagePipeline.maxDPI).contains(page.dpi))
    }

    func testGrayAndBlackAndWhiteFiltersMakeOneComponentJpegsAndOriginalKeepsColour() throws {
        let photo = PhotoScenes.woodScene()
        for filter in [CaptureFilter.grayscale, .blackAndWhite] {
            let page = try XCTUnwrap(PagePipeline.page(photo: photo, corners: truth, filter: filter))
            XCTAssertTrue(page.gray, "\(filter)")
            XCTAssertEqual(try jpegSize(page.jpeg).components, 1, "\(filter)")
        }
        let original = try XCTUnwrap(PagePipeline.page(photo: photo, corners: truth, filter: .original))
        XCTAssertFalse(original.gray)
        XCTAssertEqual(try jpegSize(original.jpeg).components, 3)
        var options = PerspectiveOptions()
        options.maxLongSide = PagePipeline.maxLongSide
        let cut = try XCTUnwrap(PerspectiveCorrector.correct(photo, quad: Quad.fromCorners(truth.corners), options: options))
        XCTAssertEqual(original.width, cut.image.width)
        XCTAssertEqual(original.height, cut.image.height)
    }

    func testTheWholePhotoIsOnlyFiltered() throws {
        let photo = PhotoScenes.woodScene()
        let page = try XCTUnwrap(PagePipeline.wholePage(photo: photo, filter: .original))
        XCTAssertEqual(page.width, photo.width)
        XCTAssertEqual(page.height, photo.height)
        XCTAssertEqual(page.corners, PageFinder.wholePhoto(width: photo.width, height: photo.height))
    }

    func testCornersThatOutlineNoPageMakeNoPage() {
        let photo = PhotoScenes.woodScene()
        let line = Quad(topLeft: CGPoint(x: 10, y: 10), topRight: CGPoint(x: 10, y: 10),
                        bottomRight: CGPoint(x: 10, y: 10), bottomLeft: CGPoint(x: 10, y: 10))
        XCTAssertNil(PagePipeline.page(photo: photo, corners: line, filter: .enhanced))
    }

    func testThePageDpiIsKeptWithinItsLimits() {
        XCTAssertEqual(PagePipeline.pageDPI(12, longSide: 1000), 50)
        XCTAssertEqual(PagePipeline.pageDPI(5000, longSide: 1000), 1200)
        XCTAssertEqual(PagePipeline.pageDPI(199.6, longSide: 1000), 200)
    }

    func testAPageThatMatchedNoPaperTakesTheUsualSheetsLongSide() {
        // 2339 px on A4's 11.69 in is 200 dpi, where Letter's 11 in makes it 213: never a made-up 15 in page.
        XCTAssertEqual(PagePipeline.pageDPI(nil, longSide: 2339, region: "DE"), 200)
        XCTAssertEqual(PagePipeline.pageDPI(Double.nan, longSide: 2339, region: "DE"), 200)
        XCTAssertEqual(PagePipeline.pageDPI(nil, longSide: 2339, region: "us"), 213)
        XCTAssertEqual(PagePipeline.pageDPI(nil, longSide: 3000, region: nil), 257)
        XCTAssertEqual(PagePipeline.pageDPI(nil, longSide: 100, region: "CA"), 50)
    }

    func testAPhotoFromTheCameraIsReadUprightByItsOrientationTag() throws {
        // A 40 x 20 picture stored as is, tagged "turned a quarter": read as 20 x 40.
        let wide = RgbaImage.filled(width: 40, height: 20, r: 200, g: 40, b: 40)
        let cg = try XCTUnwrap(wide.makeCGImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let read = try XCTUnwrap(PhotoReader.decode(data as Data))
        XCTAssertEqual(read.width, 20)
        XCTAssertEqual(read.height, 40)
        XCTAssertNil(PhotoReader.decode(Data([0, 1, 2, 3])))
    }
}

final class ScanPdfTests: XCTestCase {
    private func page(width: Int, height: Int, dpi: Int, gray: Bool, shade: UInt8) throws -> ScanPage {
        let image = RgbaImage.filled(width: width, height: height, r: shade, g: shade, b: shade)
        let jpeg = try XCTUnwrap(JpegEncoder.encode(image, gray: gray))
        return ScanPage(corners: PageFinder.wholePhoto(width: width, height: height), filter: .original,
                        jpeg: jpeg, width: width, height: height, dpi: dpi, gray: gray)
    }

    func testEveryPageIsOnePdfPageTheSizeItPrintsAt() throws {
        let first = try page(width: 600, height: 800, dpi: 100, gray: false, shade: 200)
        let second = try page(width: 800, height: 600, dpi: 200, gray: true, shade: 90)
        let data = ScanPdf.make([first, second])
        XCTAssertEqual(data.prefix(5), Data("%PDF-".utf8))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 2)
        let one = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(Double(one.width), 432, accuracy: 0.01)
        XCTAssertEqual(Double(one.height), 576, accuracy: 0.01)
        let two = try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(Double(two.width), 288, accuracy: 0.01)
        XCTAssertEqual(Double(two.height), 216, accuracy: 0.01)
    }

    func testThePagesJpegsAreEmbeddedAsTheyAre() throws {
        let color = try page(width: 64, height: 64, dpi: 100, gray: false, shade: 120)
        let gray = try page(width: 64, height: 64, dpi: 100, gray: true, shade: 120)
        let data = ScanPdf.make([color, gray])
        XCTAssertNotNil(data.range(of: color.jpeg))
        XCTAssertNotNil(data.range(of: gray.jpeg))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("/ColorSpace /DeviceRGB"))
        XCTAssertTrue(text.contains("/ColorSpace /DeviceGray"))
        XCTAssertEqual(text.components(separatedBy: "/DCTDecode").count - 1, 2)
    }

    func testThePagesAreDrawnFromTheirJpegs() throws {
        let dark = try page(width: 120, height: 160, dpi: 100, gray: true, shade: 20)
        let document = try XCTUnwrap(PDFDocument(data: ScanPdf.make([dark])))
        let pdfPage = try XCTUnwrap(document.page(at: 0))
        let box = pdfPage.bounds(for: .mediaBox)
        var buffer = [UInt8](repeating: 255, count: 60 * 80 * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 60, height: 80, bitsPerComponent: 8, bytesPerRow: 240,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.scaleBy(x: 60 / box.width, y: 80 / box.height)
            pdfPage.draw(with: .mediaBox, to: context)
            return true
        }
        XCTAssertTrue(drawn)
        XCTAssertLessThan(buffer[(40 * 60 + 30) * 4], 60)
    }

    func testTheCrossReferenceTableHasTheOffsetsOfItsObjects() throws {
        let data = ScanPdf.make([try page(width: 32, height: 32, dpi: 72, gray: true, shade: 100)])
        let text = String(decoding: data, as: UTF8.self)
        let start = try XCTUnwrap(text.components(separatedBy: "startxref\n").last?.split(separator: "\n").first.flatMap { Int($0) })
        XCTAssertTrue(String(decoding: data.dropFirst(start).prefix(4), as: UTF8.self) == "xref")
    }
}
