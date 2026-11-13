import Containerization
import ContainerizationOCI
import CryptoKit
import Foundation

/// One-time installation of the pieces a conversion needs.
public enum Setup {
    public static let initImage = "ghcr.io/apple/containerization/vminit:0.54.0"

    // The kernel Apple's own container tooling uses, from a pinned Kata Containers release.
    static let kernelArchiveURL = URL(
        string: "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz")!
    static let kernelArchiveSHA256 = "647c7612e6edf789d5e14698c48c99d8bac15ad139ffaa1c8bb7d229f748d181"
    static let kernelArchiveMember = "./opt/kata/share/kata-containers/vmlinux-6.12.28-153"

    public struct Component: Sendable {
        public let name: String
        public let ok: Bool
    }

    public static func status(_ paths: SupportPaths = .default) -> [Component] {
        let fm = FileManager.default
        return [
            Component(name: "Linux kernel", ok: fm.fileExists(atPath: paths.kernel.path)),
            Component(name: "Init image", ok: fm.fileExists(atPath: paths.initfs.path)),
            Component(
                name: "Sandbox image",
                ok: fm.fileExists(atPath: paths.rootfs.path) && fm.fileExists(atPath: paths.imageReference.path)),
        ]
    }

    public static func isComplete(_ paths: SupportPaths = .default) -> Bool {
        status(paths).allSatisfy(\.ok)
    }

    /// Installs whatever is missing. `imageArchive` (an OCI archive from `make image`)
    /// is required the first time and replaces the sandbox image whenever given.
    public static func run(
        _ paths: SupportPaths = .default, imageArchive: URL?, log: @escaping @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: paths.kernel.path) {
            try await installKernel(paths, log: log)
        }

        log("Preparing init image \(initImage)…")
        // Pulls the init image if needed and builds its filesystem.
        let manager = try await ContainerManager(
            kernel: Kernel(path: paths.kernel, platform: .linuxArm), initfsReference: initImage, root: paths.store)

        if let imageArchive {
            try await installSandboxImage(paths, archive: imageArchive, store: manager.imageStore, log: log)
        } else if !(fm.fileExists(atPath: paths.rootfs.path) && fm.fileExists(atPath: paths.imageReference.path)) {
            throw ConversionError.notSetUp("no sandbox image; run `make image` then `pixelwash setup --image build/pixelwash-sandbox.tar`")
        }
        log("Setup complete.")
    }

    private static func installKernel(_ paths: SupportPaths, log: @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        log("Downloading Linux kernel archive (about 290 MB, one time)…")
        let (downloaded, response) = try await URLSession.shared.download(from: kernelArchiveURL)
        defer { try? fm.removeItem(at: downloaded) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ConversionError.notSetUp("kernel download failed")
        }
        log("Verifying checksum…")
        guard try sha256(of: downloaded) == kernelArchiveSHA256 else {
            throw ConversionError.notSetUp("kernel archive checksum mismatch; refusing to use it")
        }
        let scratch = paths.root.appendingPathComponent("kernel-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        try runTool("/usr/bin/tar", ["-xJf", downloaded.path, "-C", scratch.path, "--strip-components=5", kernelArchiveMember])
        let extracted = scratch.appendingPathComponent((kernelArchiveMember as NSString).lastPathComponent)
        try fm.createDirectory(at: paths.kernel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: extracted, to: paths.kernel)
        log("Kernel installed.")
    }

    private static func installSandboxImage(
        _ paths: SupportPaths, archive: URL, store: ImageStore, log: @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archive.path) else {
            throw ConversionError.notSetUp("image archive \(archive.path) not found")
        }
        log("Loading sandbox image…")
        let layout = paths.root.appendingPathComponent("image-load-\(UUID().uuidString)")
        try fm.createDirectory(at: layout, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: layout) }
        try runTool("/usr/bin/tar", ["-xf", archive.path, "-C", layout.path])
        guard let image = try await store.load(from: layout).first else {
            throw ConversionError.notSetUp("image archive contains no image")
        }

        log("Unpacking sandbox filesystem (this takes a minute)…")
        let staging = paths.root.appendingPathComponent("rootfs-\(UUID().uuidString).ext4")
        do {
            _ = try await EXT4Unpacker(capacityInBytes: 8.gib()).unpack(image, for: .current, at: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        if fm.fileExists(atPath: paths.rootfs.path) { try fm.removeItem(at: paths.rootfs) }
        // Every run attaches this file to its VM read-only. (Virtualization refuses a
        // file without write permission even for a read-only attachment, so the
        // protection is the attachment mode, not the file mode.)
        try fm.moveItem(at: staging, to: paths.rootfs)
        try image.reference.write(to: paths.imageReference, atomically: true, encoding: .utf8)
        log("Sandbox image installed: \(image.reference)")
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConversionError.notSetUp("\(path) failed with status \(process.terminationStatus)")
        }
    }
}
