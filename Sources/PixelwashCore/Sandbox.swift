import Containerization
import ContainerizationOCI
import Foundation
import Synchronization

public struct SandboxResult: Sendable {
    public let exitCode: Int32
    /// Sanitised tail of the sandbox's stderr. For debugging only; never trusted.
    public let log: String
}

/// Runs one process in a fresh, network-less, read-only Linux VM.
public enum Sandbox {
    /// Returning `false` from `stdout` aborts the run.
    public typealias Output = @Sendable (Data) -> Bool

    public struct Limits: Sendable {
        /// Allowed before the first output arrives (document conversion happens here).
        public var startup: Duration
        /// Allowed between chunks of output after that.
        public var idle: Duration = .seconds(120)

        public init(startup: Duration) { self.startup = startup }

        /// Two minutes, plus a second for every 100 KiB of input.
        public static func forInput(bytes: Int) -> Limits {
            Limits(startup: .seconds(120 + bytes / 102_400))
        }
    }

    /// - Parameter arguments: overrides the image's entry point (used by tests and `doctor`).
    public static func run(
        paths: SupportPaths = .default, input: Data, limits: Limits, arguments: [String]? = nil,
        stdout: @escaping Output
    ) async throws -> SandboxResult {
        guard Setup.isComplete(paths) else {
            let missing = Setup.status(paths).filter { !$0.ok }.map(\.name).joined(separator: ", ")
            throw ConversionError.notSetUp("missing \(missing)")
        }
        let reference = try String(contentsOf: paths.imageReference, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var manager = try await ContainerManager(
            kernel: Kernel(path: paths.kernel, platform: .linuxArm),
            initfsReference: Setup.initImage, root: paths.store)
        let image = try await manager.imageStore.get(reference: reference)

        let id = "pw-\(UUID().uuidString.lowercased())"
        let scratch = paths.containers.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let watchdog = Watchdog(limits: limits)
        let stderr = LogCollector()
        let rootfs = Mount.block(format: "ext4", source: paths.rootfs.path, destination: "/", options: ["ro"])

        let container: LinuxContainer
        do {
            container = try await manager.create(
                id, image: image, rootfs: rootfs, networking: false,
                vm: VMResources(cpus: 2, memoryInBytes: 4.gib())
            ) { config in
                config.cpus = 2
                config.memoryInBytes = 4.gib()
                config.hostname = "sandbox"
                config.interfaces = []
                config.dns = nil
                // The only writable space: in memory, gone when the VM stops.
                config.mounts.append(
                    .any(type: "tmpfs", source: "tmpfs", destination: "/tmp",
                        options: ["nosuid", "nodev", "mode=1777", "size=2g"]))
                if let arguments { config.process.arguments = arguments }
                config.process.user = .init(uid: 1000, gid: 1000)
                config.process.capabilities = LinuxCapabilities()
                config.process.noNewPrivileges = true
                config.process.terminal = false
                config.process.stdin = InputStream(data: input)
                config.process.stdout = OutputWriter(handler: stdout, watchdog: watchdog)
                config.process.stderr = stderr
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }

        watchdog.onAbort = { Task { try? await container.stop() } }

        let outcome: Result<ExitStatus, any Error>
        do {
            try await container.create()
            try await container.start()
            let status = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: ExitStatus?.self) { group in
                    group.addTask { try await container.wait() }
                    group.addTask {
                        try await watchdog.run()
                        return nil
                    }
                    var exit: ExitStatus?
                    while let finished = try await group.next() {
                        if let finished { exit = finished }
                        break
                    }
                    group.cancelAll()
                    return exit
                }
            } onCancel: {
                watchdog.abort(.cancelled)
            }
            outcome = .success(status ?? ExitStatus(exitCode: -1))
        } catch {
            outcome = .failure(error)
        }

        // Always tear down: the VM and its scratch folder never outlive the run.
        try? await container.stop()
        try? manager.delete(id)
        try? FileManager.default.removeItem(at: scratch)

        switch watchdog.reason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw ConversionError.timedOut
        case .rejected, nil: break
        }
        return SandboxResult(exitCode: try outcome.get().exitCode, log: stderr.text)
    }
}

/// Tracks the deadline and records why a run was aborted.
final class Watchdog: Sendable {
    enum Reason: Sendable { case timedOut, cancelled, rejected }

    private struct State {
        var deadline: ContinuousClock.Instant
        var reason: Reason?
        var onAbort: (@Sendable () -> Void)?
    }

    private let idle: Duration
    private let state: Mutex<State>

    init(limits: Sandbox.Limits) {
        idle = limits.idle
        state = Mutex(State(deadline: .now + limits.startup))
    }

    var reason: Reason? { state.withLock { $0.reason } }

    var onAbort: (@Sendable () -> Void)? {
        get { state.withLock { $0.onAbort } }
        set {
            let alreadyAborted = state.withLock { state -> Bool in
                state.onAbort = newValue
                return state.reason != nil
            }
            if alreadyAborted { newValue?() }
        }
    }

    /// Output arrived: allow another idle period.
    func touch() { state.withLock { $0.deadline = .now + idle } }

    func abort(_ reason: Reason) {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.reason == nil else { return nil }
            state.reason = reason
            return state.onAbort
        }
        action?()
    }

    /// Returns once the deadline has passed (after aborting), or throws on cancellation.
    func run() async throws {
        while true {
            let deadline = state.withLock { $0.deadline }
            if ContinuousClock.now >= deadline {
                abort(.timedOut)
                return
            }
            try await Task.sleep(until: deadline, clock: .continuous)
        }
    }
}

private struct InputStream: ReaderStream {
    let data: Data

    func stream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            var offset = data.startIndex
            while offset < data.endIndex {
                let end = min(offset + 65_536, data.endIndex)
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        }
    }
}

private final class OutputWriter: Writer, Sendable {
    let handler: Sandbox.Output
    let watchdog: Watchdog

    init(handler: @escaping Sandbox.Output, watchdog: Watchdog) {
        self.handler = handler
        self.watchdog = watchdog
    }

    func write(_ data: Data) throws {
        guard watchdog.reason == nil else { return }
        if handler(data) {
            watchdog.touch()
        } else {
            watchdog.abort(.rejected)
        }
    }

    func close() throws {}
}

/// Keeps a bounded, sanitised copy of stderr.
private final class LogCollector: Writer, Sendable {
    static let limit = 8192
    private let buffer = Mutex(Data())

    func write(_ data: Data) throws {
        buffer.withLock { buffer in
            buffer.append(data)
            if buffer.count > Self.limit { buffer = Data(buffer.suffix(Self.limit)) }
        }
    }

    func close() throws {}

    /// Printable ASCII and newlines only: this text came from the sandbox.
    var text: String {
        let bytes = buffer.withLock { $0 }.map { byte -> UInt8 in
            (byte == 0x0a || (0x20...0x7e).contains(byte)) ? byte : UInt8(ascii: "?")
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
