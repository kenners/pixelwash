import Foundation
import Synchronization

public struct ConversionOptions: Sendable {
    /// Add an invisible, searchable text layer using on-device OCR.
    public var ocr = true
    /// `nil` stores pages losslessly; 0…1 re-encodes them as JPEG.
    public var jpegQuality: Double?
    /// Explicit output path. `nil` means `<name>-safe.pdf` beside the input.
    public var output: URL?

    public init(ocr: Bool = true, jpegQuality: Double? = nil, output: URL? = nil) {
        self.ocr = ocr
        self.jpegQuality = jpegQuality
        self.output = output
    }
}

public enum ConversionEvent: Sendable {
    case starting
    case page(Int, of: Int)
    case finished(URL)
}

/// Converts one untrusted document into a safe PDF.
public struct Converter: Sendable {
    /// Largest input accepted; the sandbox holds the document in memory.
    public static let maxInputBytes = 256 << 20

    public typealias Runner = @Sendable (_ input: Data, _ limits: Sandbox.Limits, _ stdout: @escaping Sandbox.Output)
        async throws -> SandboxResult

    private let runner: Runner

    public init(paths: SupportPaths = .default) {
        runner = { input, limits, stdout in
            try await Sandbox.run(paths: paths, input: input, limits: limits, stdout: stdout)
        }
    }

    /// For tests: substitute the sandbox.
    init(runner: @escaping Runner) { self.runner = runner }

    public func convert(
        _ input: URL, options: ConversionOptions = .init(),
        progress: @escaping @Sendable (ConversionEvent) -> Void = { _ in }
    ) async throws -> URL {
        // The document is only ever read as opaque bytes on this side.
        let data: Data
        do {
            data = try Data(contentsOf: input, options: .mappedIfSafe)
        } catch {
            throw ConversionError.unreadableInput(error.localizedDescription)
        }
        guard data.count <= Self.maxInputBytes else { throw ConversionError.tooLarge }

        let destination = try OutputNaming.safeURL(for: input, explicit: options.output)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".pixelwash-\(UUID().uuidString).partial")
        let sink = try PageSink(url: partial, options: options, progress: progress)
        defer { try? FileManager.default.removeItem(at: partial) }

        progress(.starting)
        let result: SandboxResult
        do {
            result = try await runner(data, .forInput(bytes: data.count)) { sink.receive($0) }
        } catch {
            sink.close()
            throw error
        }
        sink.close()

        if let streamError = sink.streamError { throw ConversionError.badStream(streamError) }
        if let writeError = sink.writeError { throw writeError }
        switch result.exitCode {
        case 0: break
        case 2: throw ConversionError.unsupportedDocument
        case 3: throw ConversionError.encrypted
        case 4: throw ConversionError.tooLarge
        default: throw ConversionError.sandboxFailed(result.exitCode, lastLine(of: result.log))
        }
        do { try sink.finish() } catch { throw ConversionError.badStream(error) }

        do {
            // Fails rather than overwrites if something appeared at the destination meanwhile.
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            throw ConversionError.output(error.localizedDescription)
        }
        progress(.finished(destination))
        return destination
    }

    private func lastLine(of log: String) -> String {
        String(log.split(separator: "\n").last ?? "").prefix(200).description
    }
}

/// Receives the sandbox's output, validates it, and writes PDF pages as they complete.
final class PageSink: Sendable {
    private struct State: @unchecked Sendable {
        var parser = PixelStreamParser()
        var writer: SafePDFWriter
        var streamError: PixelStreamError?
        var writeError: ConversionError?
    }

    private let state: Mutex<State>
    private let ocr: Bool
    private let progress: @Sendable (ConversionEvent) -> Void

    init(url: URL, options: ConversionOptions, progress: @escaping @Sendable (ConversionEvent) -> Void) throws {
        state = Mutex(State(writer: try SafePDFWriter(url: url, jpegQuality: options.jpegQuality)))
        ocr = options.ocr
        self.progress = progress
    }

    var streamError: PixelStreamError? { state.withLock { $0.streamError } }
    var writeError: ConversionError? { state.withLock { $0.writeError } }

    /// Returns `false` once the stream is rejected; the caller should stop the sandbox.
    func receive(_ data: Data) -> Bool {
        state.withLock { state in
            guard state.streamError == nil, state.writeError == nil else { return false }
            do {
                for page in try state.parser.consume(data) {
                    let text = ocr ? ((try? TextRecognizer.recognize(SafePDFWriter.makeImage(page))) ?? []) : []
                    try state.writer.append(page, text: text)
                    progress(.page(page.index + 1, of: state.parser.pageCount ?? 0))
                }
                return true
            } catch let error as PixelStreamError {
                state.streamError = error
            } catch let error as ConversionError {
                state.writeError = error
            } catch {
                state.writeError = .output(error.localizedDescription)
            }
            return false
        }
    }

    /// Throws unless every page arrived in full.
    func finish() throws(PixelStreamError) {
        let parser = state.withLock { $0.parser }
        try parser.finish()
    }

    func close() { state.withLock { $0.writer.close() } }
}
