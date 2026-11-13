import Foundation
import PDFKit
import Synchronization
import Testing

@testable import PixelwashCore

/// Exercises the whole Mac-side pipeline with a stand-in for the sandbox.
@Suite struct ConverterTests {
    let dir: URL
    let input: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelwash-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        input = dir.appendingPathComponent("doc.pdf")
        try Data("untrusted".utf8).write(to: input)
    }

    func fake(_ chunks: [Data], exit: Int32 = 0) -> Converter {
        Converter { _, _, stdout in
            for chunk in chunks where !stdout(chunk) { break }
            return SandboxResult(exitCode: exit, log: "line one\nlast line")
        }
    }

    func filesInDir() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func goodStreamProducesPDF() async throws {
        let out = try await fake([makeStream([(150, 300), (300, 150)])]).convert(input, options: .init(ocr: false))
        #expect(out.lastPathComponent == "doc-safe.pdf")
        #expect(PDFDocument(url: out)?.pageCount == 2)
        #expect(try filesInDir() == ["doc-safe.pdf", "doc.pdf"])
    }

    @Test func garbageIsRejectedAndLeavesNothing() async throws {
        let garbage = Data(repeating: 0xff, count: 4096)
        await #expect(throws: ConversionError.self) { try await fake([garbage]).convert(input) }
        #expect(try filesInDir() == ["doc.pdf"])
    }

    @Test func truncatedStreamIsRejected() async throws {
        let stream = makeStream([(10, 10), (10, 10)])
        do {
            _ = try await fake([stream.dropLast(1)]).convert(input, options: .init(ocr: false))
            Issue.record("expected failure")
        } catch ConversionError.badStream(let error) {
            #expect(error == .truncated)
        }
        #expect(try filesInDir() == ["doc.pdf"])
    }

    @Test func trailingDataIsRejected() async throws {
        do {
            _ = try await fake([makeStream([(10, 10)]), Data([1])]).convert(input, options: .init(ocr: false))
            Issue.record("expected failure")
        } catch ConversionError.badStream(let error) {
            #expect(error == .trailingData)
        }
        #expect(try filesInDir() == ["doc.pdf"])
    }

    @Test(arguments: [2, 3, 4, 1, 137] as [Int32]) func exitCodesFailCleanly(code: Int32) async throws {
        do {
            _ = try await fake([], exit: code).convert(input)
            Issue.record("expected failure")
        } catch let error as ConversionError {
            switch (code, error) {
            case (2, .unsupportedDocument), (3, .encrypted), (4, .tooLarge): break
            case (_, .sandboxFailed(let c, let log)):
                #expect(c == code)
                #expect(log == "last line")
            default: Issue.record("unexpected \(error) for exit \(code)")
            }
        }
        #expect(try filesInDir() == ["doc.pdf"])
    }

    @Test func completeStreamWithFailingExitIsNotSaved() async throws {
        await #expect(throws: ConversionError.self) {
            try await fake([makeStream([(10, 10)])], exit: 1).convert(input, options: .init(ocr: false))
        }
        #expect(try filesInDir() == ["doc.pdf"])
    }

    @Test func runnerErrorLeavesNothing() async throws {
        let converter = Converter { _, _, _ in throw ConversionError.timedOut }
        await #expect(throws: ConversionError.self) { try await converter.convert(input) }
        #expect(try filesInDir() == ["doc.pdf"])
    }

    @Test func missingInputFails() async throws {
        await #expect(throws: ConversionError.self) {
            try await fake([]).convert(dir.appendingPathComponent("nope.pdf"))
        }
    }

    @Test func originalIsUntouched() async throws {
        _ = try await fake([makeStream([(10, 10)])]).convert(input, options: .init(ocr: false))
        #expect(try Data(contentsOf: input) == Data("untrusted".utf8))
    }

    @Test func reportsProgress() async throws {
        let events = Mutex<[String]>([])
        _ = try await fake([makeStream([(10, 10), (10, 10)])]).convert(input, options: .init(ocr: false)) { event in
            events.withLock { $0.append("\(event)".components(separatedBy: "(")[0]) }
        }
        #expect(events.withLock { $0 } == ["starting", "page", "page", "finished"])
    }
}
