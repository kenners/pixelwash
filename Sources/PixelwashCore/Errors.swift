import Foundation

public enum ConversionError: Error, LocalizedError, Sendable {
    case notSetUp(String)
    case unreadableInput(String)
    case unsupportedDocument
    case encrypted
    case tooLarge
    case timedOut
    case sandboxFailed(Int32, String)
    case badStream(PixelStreamError)
    case output(String)

    public var errorDescription: String? {
        switch self {
        case .notSetUp(let what): "Pixelwash is not set up: \(what). Run `pixelwash setup`."
        case .unreadableInput(let why): "Could not read the file: \(why)"
        case .unsupportedDocument: "Unsupported or empty document"
        case .encrypted: "The document is password-protected"
        case .tooLarge: "The document has too many pages or a page is too large"
        case .timedOut: "Timed out"
        case .sandboxFailed(let code, let log):
            "The sandbox failed (exit \(code))" + (log.isEmpty ? "" : ": \(log)")
        case .badStream(let error): "The sandbox sent invalid data (\(error)); nothing was saved"
        case .output(let why): "Could not save the safe PDF: \(why)"
        }
    }
}
