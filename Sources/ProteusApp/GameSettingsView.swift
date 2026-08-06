import SwiftUI
import ProteusCore

/// Everything a player can change about an installed game, in one window.
///
/// The controls are the same handful as before. What is new is that each one
/// sits next to the reason it holds the value it does. Proteus chose these
/// settings from what the game's own binary declared, and a setting whose
/// reasoning is visible is one a person can actually judge — the alternative
/// is a row of switches and a shrug, which is what every other tool offers.
struct GameSettingsView: View {
    @EnvironmentObject var state: AppState
    let game: InstalledGame
    @Environment(\.dismiss) private var dismiss

    @State private var settings = GameSettings()
    @State private var reasons: [GameSettings.Reason] = []
    @State private var note: String?
    @State private var busy = false
    @State private var confirming: Confirmation?

    private struct Confirmation: Identifiable {
        let id = UUID()
        let message: String
        let title: String
        let action: () -> Void
    }

    private var wrapper: Wrapper { Wrapper(bundle: game.url) }
    private var actions: GameActions { GameActions(wrapper: wrapper, gameName: game.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                whyItIsSetUpThisWay
                Divider()
                controls
                Divider()
                maintenance
                footer
            }
            .padding(24)
        }
        .frame(width: 500, height: 620)
        .onAppear {
            settings = GameSettings.read(from: wrapper)
            reasons = GameSettings.reasons(from: wrapper)
        }
        .alert(item: $confirming) { confirm in
            Alert(title: Text(confirm.message),
                  primaryButton: .destructive(Text(confirm.title)) { confirm.action() },
                  secondaryButton: .cancel(Text(S.keep)))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: game.icon).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.title3.weight(.semibold))
                Text(settings.renderer.summaryLocalised)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
        }
    }

    /// The recorded reasoning. Empty for games installed before this existed,
    /// which is what "Work it out again" is for.
    @ViewBuilder
    private var whyItIsSetUpThisWay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(S.whySetUp).font(.headline)
            if reasons.isEmpty {
                Text(S.noReasonsYet).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(reasons) { reason in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reason.what).font(.callout)
                            Text(reason.why).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button(S.reanalyse) { reanalyse() }
                .disabled(busy)
            Text(S.reanalyseHint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $settings.gamepadEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(S.gamepadToggle)
                    Text(S.gamepadHint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $settings.forceWindowed) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(S.windowedToggle)
                    Text(S.windowedHint).font(.caption).foregroundStyle(.secondary)
                }
            }
            if GameSettings.choices(for: settings.renderer).count > 1 {
                Picker(S.graphicsLabel, selection: $settings.renderer) {
                    ForEach(GameSettings.choices(for: settings.renderer), id: \.self) {
                        Text($0.summaryLocalised).tag($0)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(S.ifSomethingIsWrong).font(.headline)
            HStack(spacing: 8) {
                Button(S.verifyItWorks) { verify() }.disabled(busy)
                Button(S.openLogs) { state.revealLogs(game) }
                Button(S.openSaves) { state.revealSaves(game) }
            }
            HStack(spacing: 8) {
                Button(S.rebuildWindows) { confirmRebuild() }.disabled(busy)
                Button(S.deleteSaves, role: .destructive) { confirmDeleteSaves() }
            }
            Text(S.rebuildHint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(S.close) { dismiss() }
                Spacer()
                Button(S.saveChanges) { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
        }
    }

    // MARK: - Actions

    private func apply() {
        do {
            try settings.write(to: wrapper)
            note = S.savedNote
        } catch {
            note = "\(error)"
        }
    }

    /// Runs the whole analysis again against the installed game and applies
    /// what it concludes — including swapping the Wine engine if the game turns
    /// out to need DirectX 12, which is the one thing the first pass cannot
    /// know for an installer.
    private func reanalyse() {
        busy = true
        note = S.workingNote
        let bundle = game.url
        let name = game.name
        Task {
            let outcome = await state.reanalyse(bundle: bundle, name: name)
            settings = GameSettings.read(from: Wrapper(bundle: bundle))
            reasons = GameSettings.reasons(from: Wrapper(bundle: bundle))
            note = outcome
            busy = false
        }
    }

    private func verify() {
        busy = true
        note = S.workingNote
        let bundle = game.url
        Task.detached {
            let wrapper = Wrapper(bundle: bundle)
            let info = (try? wrapper.plist()) ?? [:]
            let program = info["Program Name and Path"] as? String ?? ""
            let flags = (info["Program Flags"] as? String ?? "").split(separator: " ").map(String.init)
            let verdict = SmokeTest(engine: WineEngine(wrapper: wrapper), wrapper: wrapper)
                .run(exeWindowsPath: program, arguments: flags)
            await MainActor.run {
                note = Lang.isSpanish ? (verdict.diagnosisES ?? "Arranca y abre ventana.")
                                      : (verdict.diagnosisEN ?? "It starts and opens a window.")
                busy = false
            }
        }
    }

    private func confirmRebuild() {
        let bundle = game.url, name = game.name
        confirming = Confirmation(message: S.rebuildConfirm(name), title: S.rebuildWindows) {
            busy = true
            note = S.workingNote
            Task.detached {
                try? GameActions(wrapper: Wrapper(bundle: bundle), gameName: name).rebuildWindows()
                await MainActor.run { note = S.settingsResetNote; busy = false }
            }
        }
    }

    private func confirmDeleteSaves() {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        let size = formatter.string(fromByteCount: actions.savedGamesSize())
        let bundle = game.url, name = game.name
        confirming = Confirmation(message: S.deleteSavesConfirm(name, size), title: S.deleteSaves) {
            try? GameActions(wrapper: Wrapper(bundle: bundle), gameName: name).deleteSavedGames()
            note = S.settingsResetNote
        }
    }
}

extension Prescription.Renderer {
    var summaryLocalised: String { Lang.isSpanish ? summaryES : summaryEN }
}
