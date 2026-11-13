import Foundation

public enum OutputNaming {
    /// Where the safe PDF for `input` should go. Never returns an existing path.
    ///
    /// Only the file *name* of the untrusted input is used here, never its contents.
    public static func safeURL(for input: URL, explicit: URL?) throws -> URL {
        let fm = FileManager.default
        if let explicit {
            var isDir: ObjCBool = false
            let folder = explicit.deletingLastPathComponent().path
            guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
                throw ConversionError.output("the folder \(folder) does not exist")
            }
            guard !fm.fileExists(atPath: explicit.path) else {
                throw ConversionError.output("\(explicit.path) already exists")
            }
            return explicit
        }
        let folder = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(stem)-safe.pdf")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-safe \(n).pdf")
            n += 1
        }
        return candidate
    }
}
