import AppKit
import Foundation
import Observation
import PixelwashCore

/// The list of documents and the single worker that converts them in order.
@MainActor
@Observable
final class QueueModel {
    struct Item: Identifiable {
        enum State {
            case waiting
            case starting
            case converting(page: Int, of: Int)
            case done(URL)
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let url: URL
        var state = State.waiting

        var isFinished: Bool {
            switch state {
            case .done, .failed, .cancelled: true
            default: false
            }
        }
    }

    private(set) var items: [Item] = []
    private(set) var isSetUp = Setup.isComplete()
    private var worker: Task<Void, Never>?

    var isBusy: Bool { worker != nil }

    func refreshSetup() { isSetUp = Setup.isComplete() }

    func add(_ urls: [URL]) {
        // Only the path is used here; the file is never opened or previewed on the Mac.
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        items.append(contentsOf: files.map { Item(url: $0) })
        startIfNeeded()
    }

    func clearFinished() { items.removeAll { $0.isFinished } }

    func cancelAll() {
        for index in items.indices where !items[index].isFinished {
            if case .waiting = items[index].state { items[index].state = .cancelled }
        }
        worker?.cancel()
    }

    /// Cancels the running conversion and waits for the sandbox to be torn down.
    func shutDown() async {
        cancelAll()
        await worker?.value
    }

    private func startIfNeeded() {
        guard worker == nil, isSetUp else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    private func drain() async {
        let converter = Converter()
        while let index = items.firstIndex(where: { if case .waiting = $0.state { true } else { false } }) {
            let id = items[index].id
            let url = items[index].url
            let defaults = UserDefaults.standard
            let options = ConversionOptions(ocr: defaults.object(forKey: "ocr") as? Bool ?? true)
            update(id, .starting)
            do {
                let output = try await converter.convert(url, options: options) { [weak self] event in
                    guard case .page(let page, let total) = event else { return }
                    Task { @MainActor in self?.progress(id, page: page, of: total) }
                }
                update(id, .done(output))
                if defaults.bool(forKey: "openWhenDone") { NSWorkspace.shared.open(output) }
            } catch is CancellationError {
                update(id, .cancelled)
                return
            } catch {
                update(id, .failed(error.localizedDescription))
            }
        }
    }

    private func update(_ id: UUID, _ state: Item.State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    /// Progress arrives asynchronously, so never let it overwrite a final state.
    private func progress(_ id: UUID, page: Int, of total: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isFinished else { return }
        items[index].state = .converting(page: page, of: total)
    }
}
