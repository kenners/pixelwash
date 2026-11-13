import AppKit
import PixelwashCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(QueueModel.self) private var model
    @AppStorage("ocr") private var ocr = true
    @AppStorage("openWhenDone") private var openWhenDone = false
    @State private var isTargeted = false
    @State private var isChoosing = false
    @State private var showingSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dropZone
            if !model.items.isEmpty { queue }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Make text searchable (OCR)", isOn: $ocr)
                Toggle("Open safe PDF when done", isOn: $openWhenDone)
            }
            Text("Each document is opened in a throwaway virtual machine with no network. Originals are never changed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isSetUp else { return false }
            model.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .sheet(isPresented: $showingSetup) { SetupView().environment(model) }
        .onAppear { showingSetup = !model.isSetUp }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop documents here")
                .font(.title3)
            Button("Choose…") { isChoosing = true }
                .disabled(!model.isSetUp)
            if !model.isSetUp {
                Button("Finish setup…") { showingSetup = true }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        )
        .background(
            RoundedRectangle(cornerRadius: 12).fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear))
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.items) { item in
                        ItemRow(item: item)
                        Divider()
                    }
                }
            }
            // Grows with the list, then scrolls.
            .frame(height: min(CGFloat(model.items.count) * 47, 235))
            HStack {
                Spacer()
                if model.isBusy { Button("Cancel") { model.cancelAll() } }
                Button("Clear finished") { model.clearFinished() }
                    .disabled(!model.items.contains { $0.isFinished })
            }
            .controlSize(.small)
        }
    }
}

private struct ItemRow: View {
    let item: QueueModel.Item

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if case .done(let output) = item.state {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .starting, .converting: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        switch item.state {
        case .waiting: "Waiting"
        case .starting: "Opening in sandbox…"
        case .converting(let page, let total): "Converting page \(page) of \(total)"
        case .done(let output): "Saved \(output.lastPathComponent)"
        case .failed(let reason): "Failed: \(reason)"
        case .cancelled: "Cancelled"
        }
    }
}

/// First-run installation of the kernel, init image and sandbox image.
struct SetupView: View {
    @Environment(QueueModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var archive: URL?
    @State private var isChoosing = false
    @State private var isRunning = false
    @State private var log: [String] = []
    @State private var failure: String?

    private var needsArchive: Bool { Setup.status().contains { $0.name == "Sandbox image" && !$0.ok } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up Pixelwash").font(.title2.bold())
            Text("Pixelwash needs a Linux kernel, Apple's init image and its sandbox image. This is done once.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Setup.status(), id: \.name) { component in
                Label(component.name, systemImage: component.ok ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(component.ok ? .green : .secondary)
            }
            if needsArchive {
                HStack {
                    Button("Choose sandbox image…") { isChoosing = true }
                    Text(archive?.lastPathComponent ?? "build/pixelwash-sandbox.tar from `make image`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !log.isEmpty {
                Text(log.suffix(4).joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            HStack {
                if isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.disabled(isRunning)
                Button("Set Up") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || (needsArchive && archive == nil) || model.isSetUp)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { archive = url }
        }
    }

    private func run() {
        isRunning = true
        failure = nil
        let archive = archive
        Task {
            do {
                try await Setup.run(imageArchive: archive) { line in
                    Task { @MainActor in log.append(line) }
                }
            } catch {
                failure = error.localizedDescription
            }
            isRunning = false
            model.refreshSetup()
            if model.isSetUp { dismiss() }
        }
    }
}
