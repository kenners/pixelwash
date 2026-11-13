import AppKit
import SwiftUI

@main
struct PixelwashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Pixelwash", id: "main") {
            ContentView().environment(delegate.model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = QueueModel()

    /// Files dropped on the Dock icon or sent with Finder's "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        model.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Stop the running sandbox and remove its partial output before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isBusy else { return .terminateNow }
        Task {
            await model.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
