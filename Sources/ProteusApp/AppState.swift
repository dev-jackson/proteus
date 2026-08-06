import Foundation
import SwiftUI
import ProteusCore

/// One screen, one state machine. Every branch the user can end up in is
/// enumerated here so the view never has to guess what to show.
@MainActor
final class AppState: ObservableObject {

    enum Phase {
        case idle
        case analysing(URL)
        case review(InstallPipeline.Analysis, GameSource)
        case installing(InstallPipeline.Stage)
        case done(InstallPipeline.Outcome)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var editedName: String = ""
    @Published var games: [InstalledGame] = []
    @Published var isDropTargeted = false
    /// A short line shown beside the library after a menu action, so the menu
    /// does not act invisibly.
    @Published var actionNote: String?
    @Published var pendingConfirm: PendingConfirm?

    struct PendingConfirm: Identifiable {
        let id = UUID()
        let message: String
        let confirmTitle: String
        let action: () -> Void
    }

    private let pipeline = InstallPipeline()
    private var currentTask: Task<Void, Never>?
    /// Identity of the install currently in flight; see `install()`.
    private var currentRun: UUID?
    /// Where the in-flight install is being built, so its Wine processes can be
    /// stopped if the app goes away.
    private var installingApp: URL?

    init() {
        refreshLibrary()
        NotificationCenter.default.addObserver(forName: .proteusWillQuit, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopEverything() }
        }
    }

    /// Cancels the install and stops the Wine processes it started, so quitting
    /// the window does not leave an installer running invisibly.
    func stopEverything() {
        currentTask?.cancel()
        currentRun = nil
        guard case .installing = phase, let app = installingApp else { return }
        WineEngine(wrapper: Wrapper(bundle: app)).killServer()
    }

    // MARK: - Flow

    func accept(_ url: URL) {
        currentTask?.cancel()
        currentRun = nil
        phase = .analysing(url)
        currentTask = Task {
            do {
                let (analysis, source) = try await pipeline.analyze(url)
                guard !Task.isCancelled else { return }
                editedName = analysis.name
                phase = .review(analysis, source)
            } catch {
                phase = .failed(readable(error))
            }
        }
    }

    func install() {
        guard case .review(let analysis, let source) = phase else { return }
        let name = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .installing(.init(en: "Starting", es: "Empezando", fraction: 0))

        // Each run carries an identity. Progress arrives from the pipeline's
        // actor as a stream of hops onto the main actor, and the final result
        // arrives the same way — so "is this update still relevant?" cannot be
        // answered by looking at the current phase, which is exactly what left
        // the window sitting on "Ready" after the install had finished. The
        // identity answers it without depending on ordering.
        let runID = UUID()
        currentRun = runID
        installingApp = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent("\(name.isEmpty ? analysis.name : name).app")

        currentTask = Task {
            do {
                let outcome = try await pipeline.install(
                    source: source,
                    analysis: analysis,
                    name: name.isEmpty ? analysis.name : name
                ) { stage in
                    Task { @MainActor [weak self] in
                        guard let self, self.currentRun == runID else { return }
                        self.phase = .installing(stage)
                    }
                }
                guard currentRun == runID else { return }
                // Retire the run before publishing the result, so any progress
                // update still queued behind this one is discarded rather than
                // overwriting the finished state.
                currentRun = nil
                phase = .done(outcome)
                refreshLibrary()
            } catch {
                guard currentRun == runID else { return }
                currentRun = nil
                phase = .failed(readable(error))
            }
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        currentRun = nil
        editedName = ""
        phase = .idle
        refreshLibrary()
    }

    /// Errors surfaced to a player must say what went wrong in their words.
    /// ProteusCore's error types already describe themselves that way; errors
    /// bridged from Foundation read better through `localizedDescription`.
    private func readable(_ error: Error) -> String {
        if error is CocoaError || error is URLError { return error.localizedDescription }
        return String(describing: error)
    }

    // MARK: - Library

    func refreshLibrary() {
        games = InstalledGame.scan()
    }

    func play(_ game: InstalledGame) {
        NSWorkspace.shared.open(game.url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Where the game's own output went last time it ran.
    func revealLogs(_ game: InstalledGame) {
        let logs = game.url.appendingPathComponent("Contents/Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([logs])
    }

    /// Saved games live outside the app on purpose, so that deleting the app
    /// does not delete a hundred hours of progress.
    func revealSaves(_ game: InstalledGame) {
        let data = GameData(gameName: game.name)
        try? FileManager.default.createDirectory(at: data.root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([data.root])
    }

    /// Re-reads an installed game and applies whatever the analysis now
    /// concludes — the same work the installer does at step nine, on demand.
    func reanalyse(bundle: URL, name: String) async -> String {
        do {
            _ = try await pipeline.finishInterrupted(app: bundle) { _ in }
            refreshLibrary()
            return Lang.pick("Re-analysed and updated.", "Reanalizado y actualizado.")
        } catch {
            return "\(error)"
        }
    }

    /// Runs one of the three-dot menu items.
    func perform(_ action: GameMenuAction, on game: InstalledGame) {
        let wrapper = Wrapper(bundle: game.url)
        let actions = GameActions(wrapper: wrapper, gameName: game.name)

        switch action {
        case .copyReport:
            copy(actions.diagnosticReport())

        case .showInFinder:
            revealInFinder(game.url)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note(S.copiedNote)
    }

    /// Shows a line beside the library, then clears it. Without this the menu
    /// items that do their work silently look like they did nothing.
    private func note(_ text: String) {
        actionNote = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.actionNote == text { self?.actionNote = nil }
        }
    }

    func remove(_ game: InstalledGame) {
        // Into the Trash, not straight to oblivion: a mistaken click should be
        // recoverable, and the saves live inside the bundle.
        try? FileManager.default.trashItem(at: game.url, resultingItemURL: nil)
        refreshLibrary()
    }
}

/// A game Proteus built, discovered by the marker it writes into Info.plist.
struct InstalledGame: Identifiable, Hashable {
    let url: URL
    let name: String
    let renderer: String
    let sizeBytes: Int64

    var id: URL { url }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    var sizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }

    static func scan() -> [InstalledGame] {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"),
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var found: [InstalledGame] = []

        for root in roots {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.totalFileSizeKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            for entry in entries where entry.pathExtension == "app" {
                let plistURL = entry.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plistURL),
                      let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                else { continue }
                // Games built before the rename carry the old marker. Reading
                // both means an existing library does not empty itself the
                // moment the app is updated.
                let managed = (dict["ProteusManaged"] as? Bool == true)
                    || (dict["TandemManaged"] as? Bool == true)
                guard managed else { continue }
                found.append(InstalledGame(
                    url: entry,
                    name: dict["CFBundleName"] as? String ?? entry.deletingPathExtension().lastPathComponent,
                    renderer: dict["ProteusRenderer"] as? String
                        ?? dict["TandemRenderer"] as? String ?? "wined3d",
                    sizeBytes: directorySize(entry)))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bundles are large and cloned; report the logical size, which is what a
    /// user recognises as "how big is this game".
    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in e {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
