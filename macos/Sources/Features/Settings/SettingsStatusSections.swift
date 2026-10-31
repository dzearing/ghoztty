import AppKit
import SwiftUI

// MARK: - Keyboard: the shortcut guide

/// Opens the keyboard shortcut guide. The guide (and its `showKeyboardShortcuts:`
/// action) is its own feature; while nothing in the responder chain handles
/// that action this card is hidden, so Settings never shows a dead button.
struct ShortcutGuideCard: View {
    static let action = Selector(("showKeyboardShortcuts:"))

    static var isAvailable: Bool { NSApp.target(forAction: action, to: nil, from: nil) != nil }

    var body: some View {
        if Self.isAvailable {
            HStack(spacing: 12) {
                Image(systemName: "command")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient(colors: [.gray, Color(white: 0.3)], startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Shortcuts").font(.headline)
                    Text("Every shortcut, grouped and searchable, with your custom bindings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Shortcut Guide…") { NSApp.sendAction(Self.action, to: nil, from: nil) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Key bindings").font(.headline)
                Text("Key bindings are `keybind = trigger=action` lines in your config. They're listed under Advanced → All Settings (keybind), and `ghoztty +list-keybinds` prints every effective binding.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sessions & Agent

/// The local `ghoztty-agent` that keeps shells alive between launches. Read
/// without ever spawning it: the pid file first, and only a running agent is
/// asked for its sessions and build.
@MainActor
final class AgentStatusModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var runningBuild: String?
    @Published private(set) var sessions: Int?
    let bundledBuild = LocalAgentManager.bundledAgentVersion
    let socketPath = LocalAgentManager.Paths.current.socketFile.path

    func refresh() {
        running = LocalAgentManager.liveAgentPid(paths: .current) != nil
        guard running else {
            runningBuild = nil
            sessions = nil
            return
        }
        LocalAgentManager.shared.listLocalSessions { [weak self] list in
            self?.sessions = list.map(LocalAgentManager.aliveSessionCount)
        }
        LocalAgentManager.shared.sharedConnectionAsync { [weak self] connection in
            self?.runningBuild = connection?.agentBuildVersion
        }
    }

    var isStale: Bool {
        guard let runningBuild, let bundledBuild else { return false }
        return LocalAgentManager.agentIsStale(running: runningBuild, bundled: bundledBuild)
    }
}

struct AgentStatusSection: View {
    @StateObject private var status = AgentStatusModel()

    var body: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(status.running ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(status.running
                         ? "Running" + (status.sessions.map { " · \($0) session\($0 == 1 ? "" : "s")" } ?? "")
                         : "Not running — it starts with the first terminal")
                }
            }
            if let build = status.runningBuild {
                LabeledContent("Running build") {
                    Text(build + (status.isStale ? " — updates itself when no sessions need it" : ""))
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let bundled = status.bundledBuild {
                LabeledContent("This app’s agent") {
                    Text(bundled).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            LabeledContent("Socket") {
                Text(status.socketPath.replacingOccurrences(of: home, with: "~"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("The agent keeps your shells alive when the app quits or restarts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { status.refresh() }
    }
}

// MARK: - Remote machines

struct RemoteMachinesSection: View {
    @ObservedObject private var account = RelayAccount.shared
    @ObservedObject private var registry = MachineRegistry.shared
    /// MachineSettingsStore doesn't publish changes; bump to re-read.
    @State private var settingsRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if RelayAccountKeychain.isDisabled {
                SettingNotice(symbol: "info.circle",
                              text: "Remote machines are turned off on this Mac (GhosttyRelayDisable).",
                              tint: .secondary)
            }
            LabeledContent {
                Button("New Remote Window…") {
                    (NSApp.delegate as? AppDelegate)?.newRemoteWindow(nil)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.isSignedIn ? "Signed in as \(account.email ?? "your account")" : "Not signed in")
                    Text(account.isSignedIn
                         ? "Machines enrolled in your account appear below."
                         : "Sign in from New Remote Window (⇧⌘N) to reach your other machines.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            let remotes = registry.machines.filter { !$0.isLocalMachine }
            if !remotes.isEmpty {
                Divider()
                ForEach(remotes, id: \.settingsKey) { machine in
                    let settings = machine.settings
                    LabeledContent {
                        Button("Host Settings…") {
                            MachineHostSettings.prompt(machine)
                            settingsRevision += 1
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(machine.online == true ? Color.green : machine.online == false ? Color.secondary : Color.yellow)
                                    .frame(width: 7, height: 7)
                                Text(machine.name)
                            }
                            Text([
                                machine.online == nil ? "checking…" : machine.online == true ? "online" : "offline",
                                "folder: \(settings.workingDirectory ?? "remote default")",
                                "shell: \(settings.shell ?? "remote default")",
                            ].joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .id("\(machine.settingsKey)-\(settingsRevision)")
                }
            }
        }
        .task {
            await account.waitForInitialLoad()
            if account.isSignedIn { await registry.refreshFromRelay(quiet: true) }
        }
    }
}

// MARK: - Updates

struct VersionSection: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? ""
        let delegate = NSApp.delegate as? AppDelegate
        LabeledContent {
            Button("Check for Updates…") { delegate?.checkForUpdates(nil) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ghoztty \(version)")
                let last = delegate?.updateController.updater.lastUpdateCheckDate
                Text((build.isEmpty ? "" : "Build \(build). ")
                     + (last.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
