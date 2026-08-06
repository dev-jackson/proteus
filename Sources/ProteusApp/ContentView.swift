import SwiftUI
import UniformTypeIdentifiers
import ProteusCore

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.22), value: phaseKey)
            if !state.games.isEmpty, isIdle {
                Divider()
                LibraryStrip()
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $state.isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle:
            DropZone()
        case .analysing:
            Waiting(message: S.analysing)
        case .review(let analysis, _):
            ReviewCard(analysis: analysis)
        case .installing(let stage):
            InstallProgress(stage: stage)
        case .done(let outcome):
            DoneCard(outcome: outcome)
        case .failed(let message):
            FailureCard(message: message)
        }
    }

    private var isIdle: Bool {
        if case .idle = state.phase { return true }
        return false
    }

    /// Only the identity of the phase should drive animation; re-animating on
    /// every progress tick makes the whole panel shiver.
    private var phaseKey: String {
        switch state.phase {
        case .idle: return "idle"
        case .analysing: return "analysing"
        case .review: return "review"
        case .installing: return "installing"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard case .idle = state.phase, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in state.accept(url) }
        }
        return true
    }
}

// MARK: - Drop zone

struct DropZone: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
                    .foregroundStyle(state.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(state.isDropTargeted ? Color.accentColor : Color.secondary)
                    Text(S.dropTitle)
                        .font(.title2.weight(.medium))
                    Text(S.dropSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
            }
            .frame(height: 230)
            .padding(.horizontal, 40)
            .scaleEffect(state.isDropTargeted ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: state.isDropTargeted)

            Button(S.chooseFile) { pickFile() }
                .buttonStyle(.link)
            Spacer()
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = S.dropSubtitle
        if panel.runModal() == .OK, let url = panel.url {
            state.accept(url)
        }
    }
}

// MARK: - Waiting

struct Waiting: View {
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(message).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Review

struct ReviewCard: View {
    @EnvironmentObject var state: AppState
    let analysis: InstallPipeline.Analysis

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                    TextField(S.nameLabel, text: $state.editedName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .semibold))
                }

                factsGrid

                VStack(alignment: .leading, spacing: 10) {
                    Text(S.whatItNeeds).font(.headline)
                    if analysis.prescription.reasons.isEmpty {
                        Label(S.nothingExtra, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(analysis.prescription.reasons, id: \.self) { reason in
                            RequirementRow(reason: reason)
                        }
                        Text(S.handledAutomatically)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }

                if analysis.prescription.needsRosetta { NoteRow(text: S.rosettaNote, icon: "cpu") }
                if analysis.prescription.is32Bit { NoteRow(text: S.thirtyTwoBitNote, icon: "info.circle") }

                HStack {
                    Button(S.cancel) { state.reset() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(S.install) { state.install() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .padding(.top, 4)
            }
            .padding(30)
        }
    }

    private var factsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text(S.typeLabel).foregroundStyle(.secondary)
                Text(typeLabel)
            }
            GridRow {
                Text(S.programLabel).foregroundStyle(.secondary)
                Text("\(analysis.mainExecutable.lastPathComponent) · \(analysis.architecture)")
            }
            if let engine = analysis.prescription.engineName {
                GridRow {
                    Text(S.engineLabel).foregroundStyle(.secondary)
                    Text(engine)
                }
            }
            GridRow {
                Text(S.graphicsLabel).foregroundStyle(.secondary)
                Text(analysis.prescription.renderer.rawValue)
            }
            GridRow {
                Text(S.controlsLabel).foregroundStyle(.secondary)
                Text(controlsLabel)
            }
            GridRow {
                Text(S.downloadLabel).foregroundStyle(.secondary)
                Text(analysis.downloadBytes > 0
                     ? ByteCountFormatter.string(fromByteCount: analysis.downloadBytes, countStyle: .file)
                     : S.noDownload)
            }
        }
        .font(.callout)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    /// Which devices the game talks to. Keyboard is always in the list: no
    /// Windows game is unplayable without it, and saying so reassures more
    /// than it informs.
    private var controlsLabel: String {
        var devices = [S.keyboard]
        if analysis.prescription.usesMouse { devices.append(S.mouse) }
        if analysis.prescription.usesGamepad { devices.append(S.gamepad) }
        return devices.joined(separator: ", ")
    }

    private var typeLabel: String {
        switch analysis.kind {
        case "installer": return analysis.installerFramework.map { "\(S.typeInstaller) · \($0)" } ?? S.typeInstaller
        case "disc": return S.typeDisc
        default: return S.typePortable
        }
    }
}

/// A requirement is only trustworthy if it says where it came from, so the
/// evidence travels with it rather than living in a log the user never opens.
struct RequirementRow: View {
    let reason: Prescription.Reason

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(Lang.isSpanish ? reason.requirementES : reason.requirement)
                Text(reason.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct NoteRow: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Progress

struct InstallProgress: View {
    let stage: InstallPipeline.Stage

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(Lang.isSpanish ? stage.es : stage.en)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let fraction = stage.fraction {
                ProgressView(value: fraction).frame(width: 320)
            } else {
                ProgressView().frame(width: 320)
            }
            if let detail = stage.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(30)
    }
}

// MARK: - Done

struct DoneCard: View {
    @EnvironmentObject var state: AppState
    let outcome: InstallPipeline.Outcome

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: verified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(verified ? Color.green : Color.orange)
                    .padding(.top, 30)

                Text(S.readyTitle(outcome.name)).font(.title2.weight(.semibold))
                Text(S.readyBody).foregroundStyle(.secondary)

                if verified {
                    VStack(spacing: 4) {
                        Label(S.startedChecked, systemImage: "checkmark.seal")
                        if let input = outcome.input {
                            Label(Lang.isSpanish ? input.summaryES : input.summaryEN,
                                  systemImage: "keyboard")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }

                if !verified, let verdict = outcome.verdict,
                   let diagnosis = Lang.isSpanish ? verdict.diagnosisES : verdict.diagnosisEN {
                    NoteRow(text: diagnosis, icon: "exclamationmark.triangle")
                        .padding(.horizontal, 30)
                }

                HStack(spacing: 12) {
                    Button(S.play) { NSWorkspace.shared.open(outcome.appPath) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button(S.showInFinder) { state.revealInFinder(outcome.appPath) }
                        .controlSize(.large)
                }

                if !outcome.warnings.isEmpty {
                    DisclosureGroup(S.notes) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(outcome.warnings, id: \.self) { warning in
                                Text("• \(warning)").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 30)
                }

                Button(S.startOver) { state.reset() }
                    .buttonStyle(.link)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var verified: Bool { outcome.verdict?.passed ?? false }
}

// MARK: - Failure

struct FailureCard: View {
    @EnvironmentObject var state: AppState
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.red)
            Text(S.somethingWentWrong).font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
            Button(S.tryAgain) { state.reset() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(30)
    }
}

// MARK: - Library

struct LibraryStrip: View {
    @EnvironmentObject var state: AppState
    @State private var pendingRemoval: InstalledGame?
    @State private var showingSettings: InstalledGame?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(S.library)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let note = state.actionNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(state.games) { game in
                        GameTile(game: game,
                                 onPlay: { state.play(game) },
                                 onSettings: { showingSettings = game },
                                 onRemove: { pendingRemoval = game },
                                 onAction: { state.perform($0, on: game) })
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
        }
        .sheet(item: $showingSettings) { game in
            GameSettingsView(game: game).environmentObject(state)
        }
        .alert(item: $state.pendingConfirm) { confirm in
            Alert(title: Text(confirm.message),
                  primaryButton: .destructive(Text(confirm.confirmTitle)) { confirm.action() },
                  secondaryButton: .cancel(Text(S.keep)))
        }
        .alert(item: $pendingRemoval) { game in
            Alert(title: Text(S.removeConfirm(game.name)),
                  primaryButton: .destructive(Text(S.removeAction)) { state.remove(game) },
                  secondaryButton: .cancel(Text(S.keep)))
        }
    }
}

struct GameTile: View {
    let game: InstalledGame
    let onPlay: () -> Void
    let onSettings: () -> Void
    let onRemove: () -> Void
    let onAction: (GameMenuAction) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: game.icon)
                    .resizable()
                    .frame(width: 52, height: 52)

                // The menu appears on hover rather than living there
                // permanently: five tiles each wearing a button is a toolbar,
                // not a shelf of games.
                if hovering {
                    Menu {
                        menuContents
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.55))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18, height: 18)
                    .offset(x: 7, y: -5)
                }
            }
            Text(game.name)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 84)
            Text(game.sizeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        // Double-click, like every other icon on the machine. A single click
        // launching a game was a surprise, and surprises in a launcher are
        // never the good kind.
        .onTapGesture(count: 2) { onPlay() }
        .onHover { hovering = $0 }
        .help(S.doubleClickToPlay)
        .contextMenu { menuContents }
    }

    /// Five items. Everything else moved into the settings panel, where each
    /// control sits beside the reason it exists — a menu of twelve verbs is a
    /// worse place to explain anything than a window with room to write.
    @ViewBuilder
    private var menuContents: some View {
        Button(S.play, action: onPlay)
        Divider()
        Button(S.settings, action: onSettings)
        Button(S.copyReport) { onAction(.copyReport) }
        Button(S.showInFinder) { onAction(.showInFinder) }
        Divider()
        Button(S.remove, role: .destructive, action: onRemove)
    }
}

/// What the three-dot menu can ask for. Kept as a value so the tile stays a
/// view and the work stays in the state object.
enum GameMenuAction {
    case copyReport
    case showInFinder
}
