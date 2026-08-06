import SwiftUI

@main
struct ProteusApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Proteus", id: "main") {
            ContentView()
                .environmentObject(state)
                // Dropping a game onto the Dock icon is the same gesture as
                // dropping it on the window; route both to one place.
                .onReceive(NotificationCenter.default.publisher(for: .proteusOpenFile)) { note in
                    guard let url = note.object as? URL else { return }
                    state.accept(url)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

extension Notification.Name {
    static let proteusOpenFile = Notification.Name("ProteusOpenFile")
    static let proteusWillQuit = Notification.Name("ProteusWillQuit")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// An installer keeps running after the app that started it goes away: it
    /// is a separate Wine process, not a child window. Left alone it carries on
    /// writing into a bundle nobody is watching and sits in the Dock as "wine"
    /// until the machine restarts. Closing Proteus should close them too.
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .proteusWillQuit, object: nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .proteusOpenFile, object: url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
