import Foundation
import Testing

@testable import PixelwashCore

@Suite struct OutputNamingTests {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelwash-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @Test func appendsSafeSuffix() throws {
        let out = try OutputNaming.safeURL(for: dir.appendingPathComponent("report.docx"), explicit: nil)
        #expect(out.path == dir.appendingPathComponent("report-safe.pdf").path)
    }

    @Test func handlesNoExtensionAndDots() throws {
        #expect(try OutputNaming.safeURL(for: dir.appendingPathComponent("README"), explicit: nil).lastPathComponent == "README-safe.pdf")
        #expect(try OutputNaming.safeURL(for: dir.appendingPathComponent("a.b c.tar.pdf"), explicit: nil).lastPathComponent == "a.b c.tar-safe.pdf")
    }

    @Test func neverOverwrites() throws {
        FileManager.default.createFile(atPath: dir.appendingPathComponent("report-safe.pdf").path, contents: Data())
        let second = try OutputNaming.safeURL(for: dir.appendingPathComponent("report.docx"), explicit: nil)
        #expect(second.lastPathComponent == "report-safe 2.pdf")
        FileManager.default.createFile(atPath: second.path, contents: Data())
        let third = try OutputNaming.safeURL(for: dir.appendingPathComponent("report.docx"), explicit: nil)
        #expect(third.lastPathComponent == "report-safe 3.pdf")
    }

    @Test func explicitOutputMustNotExist() throws {
        let existing = dir.appendingPathComponent("out.pdf")
        FileManager.default.createFile(atPath: existing.path, contents: Data())
        #expect(throws: ConversionError.self) {
            try OutputNaming.safeURL(for: dir.appendingPathComponent("a.pdf"), explicit: existing)
        }
    }

    @Test func explicitOutputFolderMustExist() throws {
        #expect(throws: ConversionError.self) {
            try OutputNaming.safeURL(for: dir.appendingPathComponent("a.pdf"), explicit: dir.appendingPathComponent("missing/out.pdf"))
        }
    }

    @Test func explicitOutputIsUsed() throws {
        let want = dir.appendingPathComponent("chosen.pdf")
        #expect(try OutputNaming.safeURL(for: dir.appendingPathComponent("a.pdf"), explicit: want).path == want.path)
    }
}
