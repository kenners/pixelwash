import Foundation
import Testing

@testable import PixelwashCore

func be16(_ v: Int) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }

/// Builds a well-formed stream for pages of the given sizes.
func makeStream(_ sizes: [(Int, Int)], fill: UInt8 = 0xff) -> Data {
    var d = be16(sizes.count)
    for (w, h) in sizes {
        d += be16(w) + be16(h) + Data(repeating: fill, count: w * h * 3)
    }
    return d
}

@Suite struct PixelStreamTests {
    @Test func validStreamOneByteAtATime() throws {
        let stream = makeStream([(3, 2), (1, 5)])
        var parser = PixelStreamParser()
        var pages: [PixelPage] = []
        for byte in stream { pages += try parser.consume(Data([byte])) }
        try parser.finish()
        #expect(parser.pageCount == 2)
        #expect(pages.map(\.index) == [0, 1])
        #expect(pages.map(\.width) == [3, 1])
        #expect(pages.map(\.height) == [2, 5])
        #expect(pages.map(\.rgb.count) == [18, 15])
    }

    @Test func validStreamInOneChunk() throws {
        var parser = PixelStreamParser()
        let pages = try parser.consume(makeStream([(4, 4), (2, 2), (1, 1)]))
        try parser.finish()
        #expect(pages.count == 3)
    }

    @Test(arguments: [0, 10_001]) func rejectsBadPageCount(count: Int) {
        var parser = PixelStreamParser()
        #expect(throws: PixelStreamError.invalidPageCount(count)) { try parser.consume(be16(count)) }
    }

    @Test(arguments: [(0, 5), (5, 0), (10_001, 5), (5, 10_001)]) func rejectsBadDimensions(w: Int, h: Int) {
        var parser = PixelStreamParser()
        #expect(throws: PixelStreamError.invalidDimensions(page: 0, width: w, height: h)) {
            try parser.consume(be16(1) + be16(w) + be16(h))
        }
    }

    @Test func rejectsTrailingData() throws {
        var parser = PixelStreamParser()
        #expect(throws: PixelStreamError.trailingData) {
            try parser.consume(makeStream([(1, 1)]) + Data([0]))
        }
    }

    @Test func rejectsTrailingDataInLaterChunk() throws {
        var parser = PixelStreamParser()
        _ = try parser.consume(makeStream([(1, 1)]))
        #expect(throws: PixelStreamError.trailingData) { try parser.consume(Data([0])) }
    }

    @Test(arguments: [0, 1, 2, 5, 8]) func finishDetectsTruncation(prefix: Int) throws {
        var parser = PixelStreamParser()
        _ = try parser.consume(makeStream([(1, 1)]).prefix(prefix))
        #expect(throws: PixelStreamError.truncated) { try parser.finish() }
    }

    @Test func staysFailedAfterError() {
        var parser = PixelStreamParser()
        #expect(throws: PixelStreamError.self) { try parser.consume(be16(0)) }
        #expect(throws: PixelStreamError.self) { try parser.consume(makeStream([(1, 1)])) }
        #expect(throws: PixelStreamError.self) { try parser.finish() }
    }
}
