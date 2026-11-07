// macos/Sources/Features/Setup/ClaudePluginMigration.swift
import Foundation
import OSLog

enum ClaudePluginMigrationError: Error, LocalizedError {
    case shellUnavailable
    case uninstallFailed(registration: String, exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case .shellUnavailable:
            "Could not run the claude command."
        case .uninstallFailed(let registration, let code):
            "`claude plugin uninstall \(registration)` exited \(code)."
        }
    }
}

/// The user's answer to "Switch Over / Keep Plugin". Nil means there is no
/// recorded answer: never asked, or asked by a build that stored only that the
/// question was answered, which cannot tell the two answers apart.
enum ClaudePluginChoice: String {
    case switched
    case kept
}

/// Hands Claude's `ghoztty` integration over from the standalone plugin to the
/// app, which now ships the same skills itself (tied to the installed Ghoztty
/// rather than to a separately-versioned marketplace release).
///
/// The plugin is removed through **Claude's own CLI**, never by deleting files
/// out of `~/.claude/plugins/cache`. That tree is Claude Code's package-manager
/// state — it carries `.in_use`/`.orphaned_at` sentinels and a versioned
/// manifest whose schema is not ours — so deleting a directory there leaves a
/// dangling entry the next marketplace sync may act on, and editing the manifest
/// means writing another tool's lockfile.
///
/// The plugin can come back after the hand-over (an old `dzearing-skills`
/// dependency reinstalled it), and even dead its registration closes
/// `RuntimeIntegrationFactory.isPluginManaged`. So this is not one-shot: every
/// launch runs `settleOnLaunch`, which clears what no longer works and keeps the
/// app's own copy current.
struct ClaudePluginMigration {
    /// Can this registration still load? Only Claude knows, so this comes from
    /// `claude plugin list --json`.
    enum Health: Equatable {
        /// Permanently unloadable: it supplies no skills or hooks, so there is
        /// nothing here for a user's choice to protect.
        case dead
        case live
        /// Failing for a reason that may pass (no network, marketplace clone
        /// not fetched yet), or missing from the list. Never acted on.
        case unknown
    }

    /// The standalone plugin's own marketplace. Its repo is gone, so nothing
    /// under it can ever recover, and while it stays registered `claude plugin
    /// marketplace update` keeps cloning a repo that no longer exists.
    static let retiredMarketplace = "ghoztty-claude-plugin"

    let homeDirectoryURL: URL
    let fileManager: FileManager

    /// Runs a command through the user's login shell and returns its exit code,
    /// or nil if the shell could not be launched. Injected so tests exercise the
    /// flow without a `claude` binary or a real plugin install.
    ///
    /// Blocking: call `run()` off the main thread.
    var runCommand: (String) -> Int32? = { LoginShell.run($0)?.exitCode }

    /// Runs a command for its stdout; nil if it could not run or exited non-zero.
    ///
    /// Blocking, like `runCommand`.
    var readCommand: (String) -> String? = { command in
        LoginShell.run(command).flatMap { $0.exitCode == 0 ? $0.stdout : nil }
    }

    /// Injected so tests stay out of the real runtime probe.
    var integrationState: (URL, FileManager) -> RuntimeIntegrationState = { home, fileManager in
        RuntimeIntegrationFactory.make(for: .claude, homeDirectoryURL: home, fileManager: fileManager).state()
    }

    var installIntegration: (URL, FileManager) -> IntegrationOutcome = { home, fileManager in
        AgentIntegrationService.install(agent: .claude, homeDirectoryURL: home, fileManager: fileManager)
    }

    private static let logger = Logger(subsystem: Bundle.loggerSubsystem, category: "AgentIntegration")

    private var pluginStateDirectory: URL {
        homeDirectoryURL.appendingPathComponent(".claude/ghoztty-banner")
    }

    private var appStateDirectory: URL {
        homeDirectoryURL.appendingPathComponent(".config/ghoztty/banner-state")
    }

    private var pluginSymlink: URL {
        homeDirectoryURL.appendingPathComponent(".claude/scripts/ghoztty-banner.sh")
    }

    var registrations: [String] {
        ClaudeHookSpec.externalPluginRegistrations(
            homeDirectoryURL: homeDirectoryURL, fileManager: fileManager)
    }

    var isNeeded: Bool { !registrations.isEmpty }

    /// One launch's work, off the main thread. Returns true when the caller
    /// should show the Switch Over / Keep Plugin dialog.
    ///
    /// Dead registrations go whatever the user answered: "Keep Plugin" kept a
    /// plugin that worked, and a dead one has nothing left to keep. A plugin
    /// that still loads is theirs to decide about, so it follows the recorded
    /// choice, and with no recorded choice they are asked.
    ///
    /// `mayPrompt` only holds the dialog back. The rest is silent, so it runs
    /// regardless.
    func settleOnLaunch(choice: ClaudePluginChoice?, mayPrompt: Bool) -> Bool {
        let swept = sweepLeftovers()
        var removedPlugin = swept.removedPlugin

        if !swept.live.isEmpty {
            switch choice {
            case .kept:
                return false
            case nil:
                return mayPrompt
            case .switched:
                // They chose to switch and it came back, so asking again would
                // only repeat the question. A failure retries next launch.
                do {
                    try run()
                    removedPlugin = true
                } catch {
                    Self.logger.error("could not remove the returned plugin: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
        }

        // Anything left is `.unknown`: the gate is still closed, so wait.
        guard !isNeeded else { return false }
        refreshIntegration(afterRemovingPlugin: removedPlugin)
        return false
    }

    /// Clears what no longer works and reports what still does.
    func sweepLeftovers() -> (removedPlugin: Bool, live: [String]) {
        var removedPlugin = false
        var health: [String: Health] = [:]

        let found = registrations
        if !found.isEmpty {
            health = readCommand("claude plugin list --json").map(Self.parseHealth) ?? [:]
            for registration in found where health[registration] == .dead {
                if runCommand("claude plugin uninstall \(Self.shellQuoted(registration))") == 0 {
                    removedPlugin = true
                    Self.logger.info("uninstalled dead Claude plugin registration \(registration, privacy: .public)")
                } else {
                    Self.logger.error("could not uninstall dead registration \(registration, privacy: .public)")
                }
            }
        }

        if removedPlugin && !isNeeded {
            try? migrateBannerState()
            try? removeStalePluginSymlink()
        }
        clearRegistrationResidue()
        return (removedPlugin, registrations.filter { health[$0] == .live })
    }

    /// The two things `claude plugin uninstall` can leave behind. Best effort:
    /// both are retried next launch, and neither blocks the integration.
    private func clearRegistrationResidue() {
        // Removing a marketplace also uninstalls every plugin under it, so it
        // must wait until nothing the user may want is left there. This reads
        // `known_marketplaces.json` because the CLI cannot remove an entry that
        // only `extraKnownMarketplaces` declares (it exits `not_configured`),
        // and such an entry never reaches the repo: neither a startup nor
        // `marketplace update` clones it.
        if retiredMarketplaceIsRegistered,
           !registrations.contains(where: { Self.marketplace(ofRegistration: $0) == Self.retiredMarketplace }) {
            if runCommand("claude plugin marketplace remove \(Self.retiredMarketplace)") != 0 {
                Self.logger.error("could not remove the retired Claude marketplace")
            }
        }

        // `uninstall` refuses a key with no manifest entry (`not_installed`), so
        // `disable` is the only CLI route. It leaves the key set to false, which
        // Claude ignores and this no longer matches.
        for key in orphanedEnabledKeys {
            if runCommand("claude plugin disable \(Self.shellQuoted(key)) --scope user") != 0 {
                Self.logger.error("could not disable orphaned plugin key \(key, privacy: .public)")
            }
        }
    }

    /// Keeps the app's skills and hooks matching the running build, which is
    /// what "the app owns them" means: nothing else ever refreshes them.
    ///
    /// `.notInstalled` is left alone unless a plugin was just removed. That is
    /// how the panel's Uninstall reads, and a user who never set the integration
    /// up did not ask for it. Removing the plugin is different: this is its
    /// replacement. Silent, because a launch-time failure repeats every launch.
    private func refreshIntegration(afterRemovingPlugin removedPlugin: Bool) {
        let state = integrationState(homeDirectoryURL, fileManager)
        guard removedPlugin ? state != .installed : state == .outdated else { return }
        let outcome = installIntegration(homeDirectoryURL, fileManager)
        Self.logger.info("refreshed the Claude integration: \(outcome.label, privacy: .public)")
    }

    private var retiredMarketplaceIsRegistered: Bool {
        let url = homeDirectoryURL.appendingPathComponent(".claude/plugins/known_marketplaces.json")
        return jsonObject(at: url)?[Self.retiredMarketplace] != nil
    }

    /// `ghoztty` keys still enabled in `settings.json` with no manifest entry.
    private var orphanedEnabledKeys: [String] {
        let url = homeDirectoryURL.appendingPathComponent(".claude/settings.json")
        guard let enabled = jsonObject(at: url)?["enabledPlugins"] as? [String: Any] else { return [] }
        let installed = Set(registrations)
        return enabled.compactMap { key, value in
            guard value as? Bool == true,
                  ClaudeHookSpec.name(ofRegistration: key) == ClaudeHookSpec.externalPluginName,
                  !installed.contains(key)
            else { return nil }
            return key
        }
    }

    private func jsonObject(at url: URL) -> [String: Any]? {
        fileManager.contents(atPath: url.path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Health by registration, from `claude plugin list --json`.
    ///
    /// `plugin-not-found` is the one permanent failure a marketplace reports.
    /// Every other error may be transient, except under the retired marketplace,
    /// where nothing can recover.
    static func parseHealth(_ output: String) -> [String: Health] {
        var health: [String: Health] = [:]
        for entry in pluginEntries(in: output) {
            guard let id = entry["id"] as? String else { continue }
            let details = entry["errorDetails"] as? [[String: Any]] ?? []
            let errors = entry["errors"] as? [Any] ?? []
            if details.contains(where: { $0["type"] as? String == "plugin-not-found" }) {
                health[id] = .dead
            } else if details.isEmpty && errors.isEmpty {
                health[id] = .live
            } else {
                health[id] = marketplace(ofRegistration: id) == retiredMarketplace ? .dead : .unknown
            }
        }
        return health
    }

    /// The JSON array in the output. `LoginShell` runs an interactive shell, so
    /// anything the user's profile prints comes first on stdout.
    private static func pluginEntries(in output: String) -> [[String: Any]] {
        let lines = output.components(separatedBy: .newlines)
        let opening = lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "[" || trimmed == "[]"
        }
        guard let opening,
              let data = lines[opening...].joined(separator: "\n").data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries
    }

    private static func marketplace(ofRegistration key: String) -> String? {
        key.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init)
    }

    /// Keys come from JSON files, so they reach the shell as data.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Uninstall FIRST. Everything after it is cleanup that only makes sense
    /// once the plugin is actually gone, so a failure here leaves the user
    /// exactly where they started rather than half-migrated.
    func run() throws {
        try uninstallPlugin()
        try migrateBannerState()
        try removeStalePluginSymlink()
        clearRegistrationResidue()
    }

    func uninstallPlugin() throws {
        for registration in registrations {
            guard let code = runCommand("claude plugin uninstall \(Self.shellQuoted(registration))") else {
                throw ClaudePluginMigrationError.shellUnavailable
            }
            guard code == 0 else {
                throw ClaudePluginMigrationError.uninstallFailed(registration: registration, exitCode: code)
            }
            Self.logger.info("uninstalled external Claude plugin \(registration, privacy: .public)")
        }
    }

    /// Carry the plugin's per-tty banner state into the app's state directory so
    /// a pane mid-session keeps its banner instead of blanking until the next
    /// prompt.
    ///
    /// Copies rather than moves, and never overwrites: a file the app already
    /// wrote is newer than anything the plugin left behind, and leaving the
    /// originals in place means a user who reinstalls the plugin finds its state
    /// where it expects.
    func migrateBannerState() throws {
        guard let names = try? fileManager.contentsOfDirectory(atPath: pluginStateDirectory.path) else { return }
        try fileManager.createDirectory(at: appStateDirectory, withIntermediateDirectories: true)
        for name in names where name.hasSuffix(".json") {
            let destination = appStateDirectory.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: pluginStateDirectory.appendingPathComponent(name), to: destination)
        }
    }

    /// The plugin's SessionStart hook maintains
    /// `~/.claude/scripts/ghoztty-banner.sh` as a symlink into its own cache,
    /// re-pointing it every session. With the plugin gone nothing maintains it
    /// and it dangles, so anything still invoking that path silently does
    /// nothing.
    ///
    /// Only a symlink INTO the plugin cache is ours to remove. A real file
    /// there, or a link the user aimed somewhere else, is theirs.
    func removeStalePluginSymlink() throws {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: pluginSymlink.path),
              destination.contains("/plugins/cache/")
        else { return }
        try fileManager.removeItem(at: pluginSymlink)
        Self.logger.info("removed the plugin's stale banner symlink")
    }
}
