import Foundation

/// Where Pixelwash keeps its kernel, images and per-run scratch state.
public struct SupportPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/Pixelwash`, or `$PIXELWASH_HOME` if set.
    public static let `default`: SupportPaths = {
        if let override = ProcessInfo.processInfo.environment["PIXELWASH_HOME"], !override.isEmpty {
            return SupportPaths(root: URL(fileURLWithPath: override))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SupportPaths(root: base.appendingPathComponent("Pixelwash"))
    }()

    public var kernel: URL { root.appendingPathComponent("kernel/vmlinux") }
    /// Containerization's image store; also holds the init filesystem and per-container folders.
    public var store: URL { root.appendingPathComponent("store") }
    public var containers: URL { store.appendingPathComponent("containers") }
    public var initfs: URL { store.appendingPathComponent("initfs.ext4") }
    /// The sandbox image unpacked once; mounted read-only by every run.
    public var rootfs: URL { root.appendingPathComponent("sandbox-rootfs.ext4") }
    /// Records which image reference `rootfs` was unpacked from.
    public var imageReference: URL { root.appendingPathComponent("sandbox-image.txt") }
}
