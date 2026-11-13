import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import PixelwashCore

func tempURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pixelwash-test-\(UUID().uuidString).\(ext)")
}

/// Renders into an RGB page using a drawing closure (origin bottom-left).
func drawPage(width: Int, height: Int, _ draw: (CGContext) -> Void) -> PixelPage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(ctx)
    let rgba = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
    var rgb = Data(capacity: width * height * 3)
    for i in 0..<(width * height) { rgb.append(contentsOf: [rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]]) }
    return PixelPage(index: 0, width: width, height: height, rgb: rgb)
}

func textPage(_ string: String) -> PixelPage {
    drawPage(width: 1240, height: 400) { ctx in
        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        ctx.textPosition = CGPoint(x: 80, y: 160)
        CTLineDraw(line, ctx)
    }
}

@Suite struct SafePDFWriterTests {
    @Test func pageCountAndSize() throws {
        let url = tempURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SafePDFWriter(url: url, jpegQuality: nil)
        let page = PixelPage(index: 0, width: 300, height: 150, rgb: Data(repeating: 200, count: 300 * 150 * 3))
        try writer.append(page, text: [])
        try writer.append(page, text: [])
        writer.close()
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount == 2)
        let box = try #require(doc.page(at: 0)).bounds(for: .mediaBox)
        #expect(box.width == 144 && box.height == 72)
    }

    @Test func rejectsPageWithWrongByteCount() throws {
        let url = tempURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SafePDFWriter(url: url, jpegQuality: nil)
        defer { writer.close() }
        let page = PixelPage(index: 0, width: 10, height: 10, rgb: Data(repeating: 0, count: 5))
        #expect(throws: (any Error).self) { try writer.append(page, text: []) }
    }

    @Test func ocrTextIsSearchable() throws {
        let url = tempURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = textPage("PIXELWASH 2026")
        let image = try SafePDFWriter.makeImage(page)
        let text = try TextRecognizer.recognize(image)
        #expect(!text.isEmpty)
        let writer = try SafePDFWriter(url: url, jpegQuality: nil)
        try writer.append(page, text: text)
        writer.close()
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.string?.contains("PIXELWASH") == true)
    }

    @Test func withoutTextLayerNothingIsSearchable() throws {
        let url = tempURL("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SafePDFWriter(url: url, jpegQuality: nil)
        try writer.append(textPage("PIXELWASH 2026"), text: [])
        writer.close()
        let doc = try #require(PDFDocument(url: url))
        #expect((doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func jpegIsSmallerThanLossless() throws {
        var noise = Data(count: 600 * 600 * 3)
        var seed: UInt32 = 12345
        for i in noise.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; noise[i] = UInt8(seed >> 24) }
        let page = PixelPage(index: 0, width: 600, height: 600, rgb: noise)
        var sizes: [Int] = []
        for quality in [nil, 0.5] as [Double?] {
            let url = tempURL("pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try SafePDFWriter(url: url, jpegQuality: quality)
            try writer.append(page, text: [])
            writer.close()
            sizes.append(try Data(contentsOf: url).count)
        }
        #expect(sizes[1] < sizes[0])
    }
}
