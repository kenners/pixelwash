import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds the safe PDF, one page of pixels at a time.
public final class SafePDFWriter {
    /// The sandbox renders at this resolution; it fixes the physical page size.
    public static let dpi: CGFloat = 150

    private let context: CGContext
    private let jpegQuality: Double?
    private var closed = false

    public init(url: URL, jpegQuality: Double?) throws {
        // No metadata: the output carries no title, author or creator.
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.output("cannot create \(url.path)")
        }
        self.context = context
        self.jpegQuality = jpegQuality
    }

    deinit { close() }

    public func append(_ page: PixelPage, text: [RecognizedText]) throws {
        var image = try Self.makeImage(page)
        if let jpegQuality { image = try Self.jpegEncoded(image, quality: jpegQuality) }

        let scale = 72 / Self.dpi
        var box = CGRect(x: 0, y: 0, width: CGFloat(page.width) * scale, height: CGFloat(page.height) * scale)
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        context.interpolationQuality = .none
        context.draw(image, in: box)
        drawInvisible(text, in: box)
        context.endPDFPage()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        context.closePDF()
    }

    /// Wraps validated RGB bytes as an image. Nothing here decodes a file format.
    public static func makeImage(_ page: PixelPage) throws -> CGImage {
        guard page.width > 0, page.height > 0, page.rgb.count == page.width * page.height * 3,
            let provider = CGDataProvider(data: page.rgb as CFData),
            let image = CGImage(
                width: page.width, height: page.height, bitsPerComponent: 8, bitsPerPixel: 24,
                bytesPerRow: page.width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw ConversionError.output("page \(page.index + 1) has inconsistent pixel data")
        }
        return image
    }

    /// Re-encodes as JPEG so Core Graphics embeds the compressed bytes directly.
    private static func jpegEncoded(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.output("cannot create JPEG encoder")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data),
            let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw ConversionError.output("JPEG encoding failed")
        }
        return jpeg
    }

    /// Draws each recognised line as invisible text over its position, so the
    /// PDF can be searched and selected without changing how it looks.
    private func drawInvisible(_ lines: [RecognizedText], in page: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setTextDrawingMode(.invisible)
        for item in lines {
            let rect = CGRect(
                x: item.box.minX * page.width, y: item.box.minY * page.height,
                width: item.box.width * page.width, height: item.box.height * page.height)
            guard rect.width > 0, rect.height > 0 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, max(rect.height * 0.8, 1), nil)
            let attributed = NSAttributedString(
                string: item.string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attributed)
            let natural = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard natural > 0 else { continue }
            // Stretch horizontally so the text spans exactly the recognised box.
            context.textMatrix = CGAffineTransform(scaleX: rect.width / natural, y: 1)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
            CTLineDraw(line, context)
        }
    }
}
