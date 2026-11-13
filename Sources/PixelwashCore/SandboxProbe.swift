import Foundation
import Synchronization

/// Boots the sandbox with a tiny shell script and reports what it can see.
/// Used by `pixelwash doctor` and the integration tests to prove isolation.
public struct SandboxProbe: Sendable {
    public let exitCode: Int32
    public let networkDevices: [String]
    public let routeCount: Int?
    public let uid: Int?
    public let rootIsReadOnly: Bool
    public let tmpIsWritable: Bool

    static let script = """
        echo net=$(ls /sys/class/net | tr '\\n' ' ')
        echo routes=$(tail -n +2 /proc/net/route | wc -l)
        echo uid=$(id -u)
        if touch /probe 2>/dev/null; then echo root=writable; else echo root=readonly; fi
        if touch /tmp/probe 2>/dev/null; then echo tmp=writable; else echo tmp=readonly; fi
        """

    public static func run(paths: SupportPaths = .default) async throws -> SandboxProbe {
        let collected = Mutex(Data())
        let result = try await Sandbox.run(
            paths: paths, input: Data(), limits: .init(startup: .seconds(60)),
            arguments: ["/bin/sh", "-c", script]
        ) { chunk in
            collected.withLock { $0.append(chunk) }
            return true
        }
        var facts: [String: String] = [:]
        for line in String(decoding: collected.withLock { $0 }, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { facts[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return SandboxProbe(
            exitCode: result.exitCode,
            networkDevices: (facts["net"] ?? "").split(separator: " ").map(String.init),
            routeCount: facts["routes"].flatMap { Int($0) },
            uid: facts["uid"].flatMap { Int($0) },
            rootIsReadOnly: facts["root"] == "readonly",
            tmpIsWritable: facts["tmp"] == "writable")
    }

    /// Checks that a misbehaving sandbox is always stopped and leaves nothing behind.
    public static func lifecycleChecks(paths: SupportPaths = .default) async -> [(name: String, ok: Bool)] {
        func leftovers() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: paths.containers.path)) ?? [])
                .filter { $0.hasPrefix("pw-") }.count
        }
        let before = leftovers()
        let sleeper = ["/bin/sleep", "60"]
        var results: [(name: String, ok: Bool)] = []

        // A sandbox that never produces output is stopped at its time limit.
        var start = ContinuousClock.now
        var timedOut = false
        do {
            _ = try await Sandbox.run(paths: paths, input: Data(), limits: .init(startup: .seconds(3)), arguments: sleeper) { _ in true }
        } catch ConversionError.timedOut {
            timedOut = true
        } catch {}
        results.append(("Stopped at the time limit", timedOut && ContinuousClock.now - start < .seconds(20)))

        // A sandbox whose output is rejected is stopped immediately.
        start = ContinuousClock.now
        let rejected = try? await Sandbox.run(
            paths: paths, input: Data(), limits: .init(startup: .seconds(60)),
            arguments: ["/bin/sh", "-c", "echo x; sleep 60"]
        ) { _ in false }
        results.append(("Stopped when its output is rejected", rejected != nil && ContinuousClock.now - start < .seconds(20)))

        // Cancelling stops the sandbox.
        let task = Task {
            try await Sandbox.run(paths: paths, input: Data(), limits: .init(startup: .seconds(60)), arguments: sleeper) { _ in true }
        }
        try? await Task.sleep(for: .seconds(3))
        start = ContinuousClock.now
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true } catch {}
        results.append(("Stopped when cancelled", cancelled && ContinuousClock.now - start < .seconds(20)))

        results.append(("Nothing left behind afterwards", leftovers() == before))
        return results
    }
}
