// macos/Tests/Ghostty/ClaudePluginMigrationTests.swift
import Foundation
import Testing
@testable import Ghostty

struct ClaudePluginMigrationTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeManifest(_ json: String, in home: URL) throws {
        let dir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("installed_plugins.json"),
                       atomically: true, encoding: .utf8)
    }

    private static let twoMarketplaces = #"""
    {"version":2,"plugins":{
      "ghoztty@dzearing-claude-marketplace":[{"scope":"user","version":"0.8.0"}],
      "ghoztty@ghoztty-claude-plugin":[{"scope":"user","version":"0.8.0"}],
      "code-review@claude-plugins-official":[{"scope":"user"}]}}
    """#

    /// A recording runner: never shells out, remembers what it was asked to run.
    private final class Runner {
        var commands: [String] = []
        var exitCode: Int32 = 0
        func run(_ command: String) -> Int32? {
            commands.append(command)
            return exitCode
        }
    }

    // MARK: - Detection

    /// The plugin is registered through more than one marketplace in practice,
    /// and uninstalling one leaves the other owning the runtime.
    @Test func enumeratesEveryMarketplaceRegistration() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)

        let found = ClaudeHookSpec.externalPluginRegistrations(
            homeDirectoryURL: home, fileManager: .default)

        #expect(Set(found) == ["ghoztty@dzearing-claude-marketplace", "ghoztty@ghoztty-claude-plugin"])
    }

    @Test func migrationIsNotNeededWithoutThePlugin() throws {
        let home = try tempHome()
        try writeManifest(#"{"version":2,"plugins":{"code-review@claude-plugins-official":[{"scope":"user"}]}}"#, in: home)
        let runner = Runner()

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: runner.run)

        #expect(!migration.isNeeded)
    }

    // MARK: - Uninstall

    /// Removal goes through Claude's OWN cli, never by deleting files out of
    /// `~/.claude/plugins/cache`: that tree is Claude Code's package-manager
    /// state, and deleting it leaves a dangling manifest entry that the next
    /// marketplace sync may act on.
    @Test func uninstallsEachRegistrationThroughClaudesOwnCLI() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)
        let runner = Runner()

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: runner.run)
        try migration.uninstallPlugin()

        #expect(runner.commands.count == 2)
        #expect(runner.commands.allSatisfy { $0.hasPrefix("claude plugin uninstall ") })
        #expect(runner.commands.contains { $0.contains("ghoztty@dzearing-claude-marketplace") })
        #expect(runner.commands.contains { $0.contains("ghoztty@ghoztty-claude-plugin") })
    }

    /// A failed uninstall must leave the user exactly where they started: the
    /// plugin still owning the runtime, rather than half-removed with Ghoztty's
    /// copy layered on top.
    @Test func aFailedUninstallThrowsAndLeavesTheRestUntouched() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)
        let runner = Runner()
        runner.exitCode = 1

        let scripts = home.appendingPathComponent(".claude/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let link = scripts.appendingPathComponent("ghoztty-banner.sh")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: home.appendingPathComponent(".claude/plugins/cache/x/ghoztty/0.8.0/hooks/ghoztty-banner.sh").path)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: runner.run)

        #expect(throws: (any Error).self) { try migration.run() }
        // The symlink is only cleaned AFTER a successful uninstall. Asserted via
        // the link itself: `fileExists` follows it, and it points into a plugin
        // cache this test never created, so it would read false either way.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    /// A shell we could not launch is a failure, not a silent success.
    @Test func anUnavailableShellIsAFailure() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in nil })

        #expect(throws: (any Error).self) { try migration.uninstallPlugin() }
    }

    // MARK: - Symlink cleanup

    /// The plugin's SessionStart hook maintains
    /// `~/.claude/scripts/ghoztty-banner.sh` as a symlink into its own cache and
    /// re-points it every session. Once the plugin is gone nothing maintains it,
    /// so it dangles.
    @Test func removesTheSymlinkThatPointedIntoThePluginCache() throws {
        let home = try tempHome()
        let scripts = home.appendingPathComponent(".claude/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let link = scripts.appendingPathComponent("ghoztty-banner.sh")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: home.appendingPathComponent(".claude/plugins/cache/m/ghoztty/0.8.0/hooks/ghoztty-banner.sh").path)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.removeStalePluginSymlink()

        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }

    /// Only the plugin's own link is ours to remove. A real file at that path,
    /// or a link the user pointed somewhere else, belongs to them.
    @Test func leavesAScriptTheUserOwnsAlone() throws {
        let home = try tempHome()
        let scripts = home.appendingPathComponent(".claude/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)

        let real = scripts.appendingPathComponent("ghoztty-banner.sh")
        try "#!/bin/bash\necho mine\n".write(to: real, atomically: true, encoding: .utf8)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.removeStalePluginSymlink()

        #expect(FileManager.default.fileExists(atPath: real.path))
    }

    // MARK: - Banner state

    /// The plugin keys banner state by tty under `~/.claude/ghoztty-banner/`;
    /// the app's script uses `~/.config/ghoztty/banner-state/`. Carrying the
    /// files across means a pane mid-session keeps its banner instead of going
    /// blank until the next prompt.
    @Test func carriesBannerStateIntoTheAppsStateDirectory() throws {
        let home = try tempHome()
        let old = home.appendingPathComponent(".claude/ghoztty-banner")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try #"{"title":"one"}"#.write(to: old.appendingPathComponent("ttys001.json"), atomically: true, encoding: .utf8)
        try #"{"title":"two"}"#.write(to: old.appendingPathComponent("ttys002.json"), atomically: true, encoding: .utf8)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.migrateBannerState()

        let new = home.appendingPathComponent(".config/ghoztty/banner-state")
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("ttys001.json").path))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("ttys002.json").path))
        // Copied, not moved: if the user keeps the plugin after all, their state
        // is still where the plugin expects it.
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("ttys001.json").path))
    }

    /// State the app already wrote is newer than anything the plugin left.
    @Test func doesNotOverwriteStateTheAppAlreadyHas() throws {
        let home = try tempHome()
        let old = home.appendingPathComponent(".claude/ghoztty-banner")
        let new = home.appendingPathComponent(".config/ghoztty/banner-state")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try #"{"title":"stale"}"#.write(to: old.appendingPathComponent("ttys001.json"), atomically: true, encoding: .utf8)
        try #"{"title":"current"}"#.write(to: new.appendingPathComponent("ttys001.json"), atomically: true, encoding: .utf8)

        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.migrateBannerState()

        let text = try String(contentsOf: new.appendingPathComponent("ttys001.json"), encoding: .utf8)
        #expect(text.contains("current"))
    }

    /// Nothing to carry across is a no-op, not a failure.
    @Test func missingPluginStateIsNotAnError() throws {
        let home = try tempHome()
        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: { _ in 0 })
        try migration.migrateBannerState()
    }

    // MARK: - Whole flow

    @Test func aSuccessfulRunUninstallsCarriesStateAndClearsTheLink() throws {
        let home = try tempHome()
        try writeManifest(Self.twoMarketplaces, in: home)

        let old = home.appendingPathComponent(".claude/ghoztty-banner")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try #"{"title":"live"}"#.write(to: old.appendingPathComponent("ttys003.json"), atomically: true, encoding: .utf8)

        let scripts = home.appendingPathComponent(".claude/scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let link = scripts.appendingPathComponent("ghoztty-banner.sh")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: home.appendingPathComponent(".claude/plugins/cache/m/ghoztty/0.8.0/hooks/ghoztty-banner.sh").path)

        let runner = Runner()
        let migration = ClaudePluginMigration(
            homeDirectoryURL: home, fileManager: .default, runCommand: runner.run)
        try migration.run()

        #expect(runner.commands.count == 2)
        #expect(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".config/ghoztty/banner-state/ttys003.json").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
    }

    // MARK: - Launch cleanup

    private static let dead = "ghoztty@dzearing-claude-marketplace"
    private static let retired = "ghoztty@ghoztty-claude-plugin"

    /// Stands in for `claude`, changing the same files the real CLI changes.
    /// Behaviors recorded from Claude Code 2.1.319 against a throwaway home.
    private final class FakeClaude {
        let home: URL
        var listOutput: String?
        var commands: [String] = []
        var uninstallExitCode: Int32 = 0
        var installs = 0
        var state: RuntimeIntegrationState = .installed

        init(home: URL, listOutput: String?) {
            self.home = home
            self.listOutput = listOutput
        }

        private func edit(_ path: String, _ change: (inout [String: Any]) -> Void) {
            let url = home.appendingPathComponent(path)
            guard let data = FileManager.default.contents(atPath: url.path),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            change(&json)
            try? JSONSerialization.data(withJSONObject: json).write(to: url)
        }

        private func removeRegistration(where matches: (String) -> Bool) {
            edit(".claude/plugins/installed_plugins.json") { json in
                var plugins = json["plugins"] as? [String: Any] ?? [:]
                plugins = plugins.filter { !matches($0.key) }
                json["plugins"] = plugins
            }
            edit(".claude/settings.json") { json in
                var enabled = json["enabledPlugins"] as? [String: Any] ?? [:]
                enabled = enabled.filter { !matches($0.key) }
                json["enabledPlugins"] = enabled
            }
        }

        private var manifestKeys: [String] {
            ClaudeHookSpec.externalPluginRegistrations(homeDirectoryURL: home, fileManager: .default)
        }

        func run(_ command: String) -> Int32? {
            commands.append(command)
            let key = command.split(separator: " ").first { $0.contains("@") }?
                .trimmingCharacters(in: CharacterSet(charactersIn: "'")) ?? ""
            if command.hasPrefix("claude plugin uninstall") {
                guard uninstallExitCode == 0, manifestKeys.contains(key) else { return 1 }
                removeRegistration { $0 == key }
            } else if command.hasPrefix("claude plugin marketplace remove") {
                // Takes every plugin under the marketplace with it.
                removeRegistration { $0.hasSuffix("@ghoztty-claude-plugin") }
                edit(".claude/plugins/known_marketplaces.json") { $0["ghoztty-claude-plugin"] = nil }
            } else if command.hasPrefix("claude plugin disable") {
                edit(".claude/settings.json") { json in
                    var enabled = json["enabledPlugins"] as? [String: Any] ?? [:]
                    enabled[key] = false
                    json["enabledPlugins"] = enabled
                }
            }
            return 0
        }

        func read(_ command: String) -> String? {
            commands.append(command)
            return listOutput
        }

        func migration() -> ClaudePluginMigration {
            ClaudePluginMigration(
                homeDirectoryURL: home, fileManager: .default,
                runCommand: run, readCommand: read,
                integrationState: { _, _ in self.state },
                installIntegration: { _, _ in self.installs += 1; return .installed })
        }

        var mutations: [String] { commands.filter { !$0.hasPrefix("claude plugin list") } }
    }

    private func entry(_ id: String, error: String? = nil, marketplace: String = "m") -> String {
        guard let error else { return #"{"id":"\#(id)","enabled":true}"# }
        return #"{"id":"\#(id)","errors":["x"],"errorDetails":[{"type":"\#(error)","marketplace":"\#(marketplace)"}]}"#
    }

    private func staleHome(registrations: [String],
                           enabled: [String: Bool]? = nil,
                           retiredMarketplace: Bool = false) throws -> URL {
        let home = try tempHome()
        let keys = registrations.map { #""\#($0)":[{"scope":"user"}]"# }.joined(separator: ",")
        try writeManifest(#"{"version":2,"plugins":{\#(keys)}}"#, in: home)
        let settings: [String: Any] = ["enabledPlugins": enabled ?? Dictionary(
            uniqueKeysWithValues: registrations.map { ($0, true) })]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        let known = retiredMarketplace ? #"{"ghoztty-claude-plugin":{}}"# : "{}"
        try known.write(to: home.appendingPathComponent(".claude/plugins/known_marketplaces.json"),
                        atomically: true, encoding: .utf8)
        return home
    }

    private func enabledPlugins(in home: URL) throws -> [String: Bool] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["enabledPlugins"] as? [String: Bool] ?? [:]
    }

    @Test func classifiesHealthFromClaudesOwnReport() {
        let output = "[" + [
            entry("a@m", error: "plugin-not-found"),
            entry("b@m"),
            entry("c@m", error: "marketplace-load-failed"),
            entry("d@m", error: "generic-error"),
            entry("e@ghoztty-claude-plugin", error: "marketplace-load-failed"),
        ].joined(separator: ",") + "\n]"
        let health = ClaudePluginMigration.parseHealth(output.replacingOccurrences(of: "[{", with: "[\n{"))

        #expect(health["a@m"] == .dead)
        #expect(health["b@m"] == .live)
        // A marketplace that failed to load may just be offline.
        #expect(health["c@m"] == .unknown)
        #expect(health["d@m"] == .unknown)
        // The retired marketplace never comes back.
        #expect(health["e@ghoztty-claude-plugin"] == .dead)
    }

    /// `LoginShell` runs an interactive shell, so a chatty profile lands on
    /// stdout ahead of the JSON, including lines that open with a bracket.
    @Test func findsTheListThroughShellProfileNoise() {
        let output = "[oh-my-zsh] update available\nWelcome\n[\n\(entry("a@m"))\n]\n"
        #expect(ClaudePluginMigration.parseHealth(output)["a@m"] == .live)
        #expect(ClaudePluginMigration.parseHealth("not json").isEmpty)
    }

    /// The bug: the prompt was answered long ago, the plugin came back dead,
    /// and the app stayed locked out with nothing left to clear it.
    @Test func aDeadRegistrationAfterTheAnswerIsClearedAndTheIntegrationInstalled() throws {
        let home = try staleHome(registrations: [Self.dead], retiredMarketplace: true)
        let claude = FakeClaude(home: home, listOutput: "[\n\(entry(Self.dead, error: "plugin-not-found"))\n]")
        claude.state = .outdated

        let ask = claude.migration().settleOnLaunch(choice: nil, mayPrompt: true)

        #expect(!ask)
        #expect(claude.mutations == [
            "claude plugin uninstall '\(Self.dead)'",
            "claude plugin marketplace remove ghoztty-claude-plugin",
        ])
        #expect(!ClaudeHookSpec().isExternalPluginInstalled(homeDirectoryURL: home, fileManager: .default))
        #expect(claude.installs == 1)
    }

    /// End to end through the real factory: the gate opens and the skill lands.
    @Test func clearingADeadRegistrationReopensTheGateForTheRealInstall() throws {
        let home = try staleHome(registrations: [Self.dead])
        #expect(RuntimeIntegrationFactory.isPluginManaged(agent: .claude, homeDirectoryURL: home, fileManager: .default))

        let claude = FakeClaude(home: home, listOutput: "[\n\(entry(Self.dead, error: "plugin-not-found"))\n]")
        var migration = claude.migration()
        migration.integrationState = { home, fileManager in
            RuntimeIntegrationFactory.make(for: .claude, homeDirectoryURL: home, fileManager: fileManager, probe: .stub([.claude])).state()
        }
        migration.installIntegration = { home, fileManager in
            AgentIntegrationService.install(agent: .claude, homeDirectoryURL: home, fileManager: fileManager, probe: .stub([.claude]))
        }
        _ = migration.settleOnLaunch(choice: nil, mayPrompt: true)

        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/ghoztty/SKILL.md").path))
        #expect(migration.integrationState(home, .default) == .installed)
    }

    /// "Keep Plugin" kept a plugin that worked. A dead one supplies nothing, so
    /// leaving it would keep the user locked out of both copies.
    @Test func aDeadRegistrationIsClearedEvenForSomeoneWhoKeptThePlugin() throws {
        let home = try staleHome(registrations: [Self.dead])
        let claude = FakeClaude(home: home, listOutput: "[\n\(entry(Self.dead, error: "plugin-not-found"))\n]")

        _ = claude.migration().settleOnLaunch(choice: .kept, mayPrompt: true)

        #expect(claude.mutations == ["claude plugin uninstall '\(Self.dead)'"])
    }

    @Test func aWorkingPluginTheUserKeptIsLeftCompletelyAlone() throws {
        let home = try staleHome(registrations: [Self.retired], retiredMarketplace: true)
        let claude = FakeClaude(home: home, listOutput: "[\n\(entry(Self.retired))\n]")
        claude.state = .outdated

        let ask = claude.migration().settleOnLaunch(choice: .kept, mayPrompt: true)

        #expect(!ask)
        #expect(claude.mutations.isEmpty)
        #expect(claude.installs == 0)
    }

    /// The old flag cannot say which way they answered, so a working plugin with
    /// no recorded choice is a question, never a silent removal.
    @Test func aWorkingPluginWithNoRecordedChoiceAsks() throws {
        let home = try staleHome(registrations: [Self.retired], retiredMarketplace: true)
        let claude = FakeClaude(home: home, listOutput: "[\n\(entry(Self.retired))\n]")

        #expect(claude.migration().settleOnLaunch(choice: nil, mayPrompt: true))
        #expect(claude.mutations.isEmpty)
    }

    /// Before the CLI prompt is answered, a second modal would stack on it.
    @Test func theDialogWaitsForTheCLIPrompt() throws {
        let home = try staleHome(registrations: [Self.retired])
        let claude = FakeClaude(home: home, listOutput: "[\n\(entry(Self.retired))\n]")

        #expect(!claude.migration().settleOnLaunch(choice: nil, mayPrompt: false))
    }

    /// They already chose to switch, and it came back on its own.
    @Test func aPluginThatReturnsAfterSwitchingIsRemovedWithoutAsking() throws {
        let home = try staleHome(registrations: [Self.retired], retiredMarketplace: true)
        let claude = FakeClaude(home: home, listOutput: "[\n\(entry(Self.retired))\n]")
        claude.state = .notInstalled

        let ask = claude.migration().settleOnLaunch(choice: .switched, mayPrompt: true)

        #expect(!ask)
        #expect(claude.mutations.first == "claude plugin uninstall '\(Self.retired)'")
        #expect(claude.mutations.contains("claude plugin marketplace remove ghoztty-claude-plugin"))
        #expect(claude.installs == 1)
    }

    @Test func aFailedRemovalInstallsNothingAndDoesNotAsk() throws {
        let home = try staleHome(registrations: [Self.retired])
        let claude = FakeClaude(home: home, listOutput: "[\n\(entry(Self.retired))\n]")
        claude.uninstallExitCode = 1

        #expect(!claude.migration().settleOnLaunch(choice: .switched, mayPrompt: true))
        #expect(claude.installs == 0)
    }

    /// Offline, the marketplace fails to load. That says nothing about the
    /// plugin, and removing it would be a guess.
    @Test func aTransientFailureIsLeftForALaterLaunch() throws {
        let home = try staleHome(registrations: [Self.dead])
        let claude = FakeClaude(home: home, listOutput: "[\n\(entry(Self.dead, error: "marketplace-load-failed"))\n]")
        claude.state = .outdated

        #expect(!claude.migration().settleOnLaunch(choice: .switched, mayPrompt: true))
        #expect(claude.mutations.isEmpty)
        #expect(claude.installs == 0)
    }

    @Test func noReadableListMeansNoAction() throws {
        let home = try staleHome(registrations: [Self.dead])
        let claude = FakeClaude(home: home, listOutput: nil)

        #expect(!claude.migration().settleOnLaunch(choice: nil, mayPrompt: true))
        #expect(claude.mutations.isEmpty)
    }

    /// `marketplace remove` uninstalls every plugin under it, so while a
    /// registration there has not been cleared, it must wait.
    @Test func theRetiredMarketplaceStaysWhileAnUnresolvedPluginIsUnderIt() throws {
        let home = try staleHome(registrations: [Self.dead, Self.retired], retiredMarketplace: true)
        let list = "[\n\(entry(Self.dead, error: "plugin-not-found")),\(entry(Self.retired))\n]"
        let claude = FakeClaude(home: home, listOutput: list)

        _ = claude.migration().settleOnLaunch(choice: .kept, mayPrompt: true)

        #expect(claude.mutations == ["claude plugin uninstall '\(Self.dead)'"])
        #expect(ClaudeHookSpec.externalPluginRegistrations(homeDirectoryURL: home, fileManager: .default) == [Self.retired])
    }

    /// A machine with no plugin left but the marketplace still registered:
    /// `marketplace update` clones the retired repo from there.
    @Test func theRetiredMarketplaceGoesWithNoPluginInstalled() throws {
        let home = try staleHome(registrations: [], retiredMarketplace: true)
        let claude = FakeClaude(home: home, listOutput: nil)

        _ = claude.migration().settleOnLaunch(choice: nil, mayPrompt: true)

        #expect(claude.mutations == ["claude plugin marketplace remove ghoztty-claude-plugin"])
    }

    /// `uninstall` refuses a key with no manifest entry, so it goes through
    /// `disable`, and the `false` it leaves is not matched again.
    @Test func anOrphanedEnabledKeyIsDisabledOnce() throws {
        let home = try staleHome(registrations: [], enabled: [Self.dead: true, "other@m": true])
        let claude = FakeClaude(home: home, listOutput: nil)

        _ = claude.migration().settleOnLaunch(choice: nil, mayPrompt: true)
        _ = claude.migration().settleOnLaunch(choice: nil, mayPrompt: true)

        #expect(claude.mutations == ["claude plugin disable '\(Self.dead)' --scope user"])
        #expect(try enabledPlugins(in: home) == [Self.dead: false, "other@m": true])
    }

    /// A machine with nothing to clear still needs this: the skills and hooks
    /// otherwise stay at whatever version first wrote them.
    @Test func anOutdatedIntegrationIsRefreshedWithNoPluginInvolved() throws {
        let claude = FakeClaude(home: try tempHome(), listOutput: nil)
        claude.state = .outdated

        _ = claude.migration().settleOnLaunch(choice: nil, mayPrompt: true)

        #expect(claude.installs == 1)
        #expect(claude.commands.isEmpty)
    }

    /// `.notInstalled` is what the panel's Uninstall leaves. Reinstalling it on
    /// the next launch would undo the user's own action.
    @Test func anAbsentIntegrationStaysAbsentWhenNoPluginWasRemoved() throws {
        let claude = FakeClaude(home: try tempHome(), listOutput: nil)
        claude.state = .notInstalled

        _ = claude.migration().settleOnLaunch(choice: .switched, mayPrompt: true)

        #expect(claude.installs == 0)
    }

    @Test func aCurrentIntegrationIsNotRewritten() throws {
        let claude = FakeClaude(home: try tempHome(), listOutput: nil)

        _ = claude.migration().settleOnLaunch(choice: nil, mayPrompt: true)

        #expect(claude.installs == 0)
    }

    /// Keys come out of JSON files, so they must reach the shell as data.
    @Test func registrationsReachTheShellQuoted() throws {
        let key = "ghoztty@x'; touch pwned; '"
        let home = try tempHome()
        try writeManifest(#"{"version":2,"plugins":{"\#(key)":[{"scope":"user"}]}}"#, in: home)
        let runner = Runner()

        try ClaudePluginMigration(homeDirectoryURL: home, fileManager: .default, runCommand: runner.run)
            .uninstallPlugin()

        #expect(runner.commands == [#"claude plugin uninstall 'ghoztty@x'\''; touch pwned; '\'''"#])
    }
}
