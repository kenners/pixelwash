import Foundation

/// One page of raw pixels received from the sandbox.
public struct PixelPage: Sendable {
    public let index: Int
    public let width: Int
    public let height: Int
    /// `width * height * 3` bytes, RGB, row-major, no padding.
    public let rgb: Data
}

public enum PixelStreamError: Error, Equatable, Sendable {
    case invalidPageCount(Int)
    case invalidDimensions(page: Int, width: Int, height: Int)
    case truncated
    case trailingData
}

/// Incremental parser for the sandbox's pixel stream.
///
/// This is the trust boundary: everything the sandbox writes is attacker
/// controlled, so the parser accepts exactly one shape and nothing else.
///
///     u16 page_count
///     repeat: u16 width, u16 height, width*height*3 bytes
///
/// All integers are big-endian. Feed chunks of any size to `consume`, then
/// call `finish` once the stream has ended.
public struct PixelStreamParser: Sendable {
    public static let maxPages = 10_000
    public static let maxDimension = 10_000

    public private(set) var pageCount: Int?

    private enum State: Sendable {
        case pageCount
        case header
        case body(width: Int, height: Int)
        case done
        case failed(PixelStreamError)
    }

    private var state = State.pageCount
    private var buffer = Data()
    private var nextIndex = 0

    public init() {}

    /// Returns every page completed by this chunk.
    public mutating func consume(_ chunk: Data) throws(PixelStreamError) -> [PixelPage] {
        if case .failed(let error) = state { throw error }
        buffer.append(chunk)
        do {
            return try drain()
        } catch {
            state = .failed(error)
            buffer = Data()
            throw error
        }
    }

    /// Call when the stream ends. Throws unless every page arrived in full.
    public func finish() throws(PixelStreamError) {
        switch state {
        case .done: return
        case .failed(let error): throw error
        default: throw .truncated
        }
    }

    private mutating func drain() throws(PixelStreamError) -> [PixelPage] {
        var pages: [PixelPage] = []
        while true {
            switch state {
            case .pageCount:
                guard let count = takeUInt16() else { return pages }
                guard (1...Self.maxPages).contains(count) else { throw .invalidPageCount(count) }
                pageCount = count
                state = .header
            case .header:
                guard buffer.count >= 4 else { return pages }
                let width = takeUInt16()!
                let height = takeUInt16()!
                let valid = 1...Self.maxDimension
                guard valid.contains(width), valid.contains(height) else {
                    throw .invalidDimensions(page: nextIndex, width: width, height: height)
                }
                state = .body(width: width, height: height)
            case .body(let width, let height):
                let size = width * height * 3
                guard buffer.count >= size else { return pages }
                let rgb = Data(buffer.prefix(size))
                buffer = Data(buffer.dropFirst(size))
                pages.append(PixelPage(index: nextIndex, width: width, height: height, rgb: rgb))
                nextIndex += 1
                state = nextIndex == pageCount ? .done : .header
            case .done:
                guard buffer.isEmpty else { throw .trailingData }
                return pages
            case .failed(let error):
                throw error
            }
        }
    }

    private mutating func takeUInt16() -> Int? {
        guard buffer.count >= 2 else { return nil }
        let value = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
        buffer = Data(buffer.dropFirst(2))
        return value
    }
}
