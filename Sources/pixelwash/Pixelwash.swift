import ArgumentParser
import Foundation
import PixelwashCore
import Synchronization

@main
struct Pixelwash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pixelwash",
        abstract: "Convert untrusted documents into safe PDFs.",
        discussion: """
            Each document is opened inside a throwaway Linux virtual machine with no \
            network, flattened to pixels, and rebuilt as a new PDF on this Mac.
            """,
        version: "0.1.0",
        subcommands: [Convert.self, SetupCommand.self, Doctor.self],
        defaultSubcommand: Convert.self
    )
}

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert one or more documents to safe PDFs.")

    @Argument(help: "Documents to convert.", completion: .file())
    var files: [String]

    @Option(
        name: [.short, .long],
        help: "Output path (only with a single input). Default: <name>-safe.pdf beside the original.")
    var output: String?

    @Flag(name: .customLong("no-ocr"), help: "Do not add a searchable text layer.")
    var noOCR = false

    @Option(name: .long, help: "Store pages as JPEG at this quality (0-1) for smaller files. Default: lossless.")
    var jpeg: Double?

    func validate() throws {
        if output != nil && files.count > 1 {
            throw ValidationError("--output can only be used with a single input file.")
        }
        if let jpeg, !(0...1).contains(jpeg) {
            throw ValidationError("--jpeg must be between 0 and 1.")
        }
    }

    func run() async throws {
        let options = ConversionOptions(
            ocr: !noOCR, jpegQuality: jpeg, output: output.map { URL(fileURLWithPath: $0) })
        let files = self.files

        let work = Task { () -> Int in
            var failures = 0
            let converter = Converter()
            for path in files {
                let url = URL(fileURLWithPath: path)
                let name = url.lastPathComponent
                do {
                    let out = try await converter.convert(url, options: options) { event in
                        if case .page(let n, let total) = event { status("\(name): page \(n) of \(total)") }
                    }
                    finish("\(name): saved \(out.path)")
                } catch is CancellationError {
                    finish("\(name): cancelled")
                    return -1
                } catch {
                    finish("\(name): FAILED: \(error.localizedDescription)")
                    failures += 1
                }
            }
            return failures
        }

        // Ctrl-C cancels the conversion so the VM and partial output are cleaned up.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { work.cancel() }
        interrupt.resume()

        let failures = await work.value
        if failures < 0 { throw ExitCode(130) }
        if failures > 0 { throw ExitCode.failure }
    }
}

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup", abstract: "Install the kernel, init image and sandbox image.")

    @Option(name: .long, help: "Sandbox image archive produced by `make image`.", completion: .file())
    var image: String?

    func run() async throws {
        try await Setup.run(imageArchive: image.map { URL(fileURLWithPath: $0) }) { print($0) }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check the installation and prove the sandbox is isolated.")

    func run() async throws {
        print("Support folder: \(SupportPaths.default.root.path)")
        for component in Setup.status() {
            print("  \(component.ok ? "ok     " : "MISSING")  \(component.name)")
        }
        guard Setup.isComplete() else {
            print("Run `pixelwash setup --image <archive>` first.")
            throw ExitCode.failure
        }

        let start = ContinuousClock.now
        let probe = try await SandboxProbe.run()
        let seconds = Double((ContinuousClock.now - start).components.seconds)
        var checks: [(String, Bool)] = [
            ("Sandbox boots and runs (about \(Int(seconds)) s)", probe.exitCode == 0),
            ("No network device except loopback", probe.networkDevices == ["lo"]),
            ("No network routes", probe.routeCount == 0),
            ("Runs as an unprivileged user", probe.uid == 1000),
            ("System files are read-only", probe.rootIsReadOnly),
            ("Scratch space is available", probe.tmpIsWritable),
        ]
        checks += await SandboxProbe.lifecycleChecks().map { ($0.name, $0.ok) }
        for (name, ok) in checks { print("  \(ok ? "ok     " : "FAILED ")  \(name)") }
        if checks.contains(where: { !$0.1 }) { throw ExitCode.failure }
    }
}

private let isTerminal = isatty(STDERR_FILENO) != 0

/// Transient progress line (only when attached to a terminal).
private func status(_ line: String) {
    guard isTerminal else { return }
    FileHandle.standardError.write(Data("\r\u{1b}[K\(line)".utf8))
}

private func finish(_ line: String) {
    if isTerminal { FileHandle.standardError.write(Data("\r\u{1b}[K".utf8)) }
    print(line)
}
