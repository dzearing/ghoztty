// macos/Tests/Ghostty/GhosttyAssetsTests.swift
import Foundation
import Testing
@testable import Ghostty

struct GhosttyAssetsTests {
    @Test func bundlesSkillsAndBannerScript() throws {
        #expect(try GhosttyAssets.skillMarkdown("ghoztty").contains("Ghoztty"))
        #expect(try GhosttyAssets.skillMarkdown("process-feedback").contains("feedback"))
        let script = try GhosttyAssets.bannerScript()
        #expect(script.hasPrefix("#!/bin/bash"))
    }

    /// These skills are vendored from the standalone Claude plugin, which
    /// installs its banner script at `~/.claude/scripts/ghoztty-banner.sh` (a
    /// symlink its own SessionStart hook re-points every session). The app
    /// installs to a stable, runtime-agnostic path instead, and a skill that
    /// still names the plugin's path tells the agent to run a script that does
    /// not exist wherever the plugin is absent — which is every Copilot install
    /// and every Claude install the app manages.
    ///
    /// Re-vendoring from a newer plugin release is a copy, so this is the check
    /// that the copy was rewritten rather than pasted.
    @Test func bundledSkillsNameTheAppsBannerPathNotThePlugins() throws {
        for name in SkillComponent.skillNames {
            for file in try GhosttyAssets.skillFiles(name) {
                #expect(!file.contents.contains(".claude/scripts/ghoztty-banner.sh"),
                        "\(name)/\(file.path) still points at the plugin-owned banner path")
                #expect(!file.contents.contains("CLAUDE_PLUGIN_ROOT"),
                        "\(name)/\(file.path) still references the plugin root")
            }
        }
    }

    /// The app installs these skills into every user's agent config, so a
    /// commit-message template carrying an AI-attribution trailer would put that
    /// trailer in their commits by default. That is the user's call, not a
    /// bundled default's.
    @Test func bundledSkillsCarryNoAIAttribution() throws {
        for name in SkillComponent.skillNames {
            for file in try GhosttyAssets.skillFiles(name) {
                let text = file.contents.lowercased()
                #expect(!text.contains("co-authored-by: claude"), "\(name)/\(file.path) carries a Co-Authored-By trailer")
                #expect(!text.contains("generated with [claude"), "\(name)/\(file.path) carries a generated-with footer")
            }
        }
    }

    /// The `ghoztty` skill is loaded into every session that lists it, so its
    /// core stays short and every file it points at exists.
    @Test func theGhozttySkillIsAShortCoreThatIndexesItsReferenceFiles() throws {
        let files = try GhosttyAssets.skillFiles("ghoztty")
        let core = try #require(files.first { $0.path == "SKILL.md" }?.contents)
        #expect(core.utf8.count < 6_000, "SKILL.md is \(core.utf8.count) bytes")
        let description = core.split(separator: "\n").first { $0.hasPrefix("description:") } ?? ""
        #expect(description.utf8.count < 400, "the description is paid in every session's skill list")
        for file in files where file.path != "SKILL.md" {
            #expect(core.contains("`\(file.path)`"), "SKILL.md's index names \(file.path)")
        }
    }
}
