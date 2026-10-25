// macos/Tests/Ghostty/SkillComponentTests.swift
import Foundation
import Testing
@testable import Ghostty

struct SkillComponentTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func rollsBackOnPartialFailure() throws {
        let home = try tempHome()
        // Force the process-feedback write to fail by placing a directory where its SKILL.md should go.
        let pfPath = home.appendingPathComponent(".copilot/skills/process-feedback/SKILL.md")
        try FileManager.default.createDirectory(at: pfPath, withIntermediateDirectories: true)
        let c = SkillComponent(agent: .copilot, homeDirectoryURL: home, fileManager: .default)
        #expect(throws: (any Error).self) { try c.install() }
        // The first (ghoztty) skill must have been rolled back — no partial install left behind.
        let ghz = home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md")
        #expect(!FileManager.default.fileExists(atPath: ghz.path))
    }

    @Test func mixedStateReportsOutdated() throws {
        let home = try tempHome()
        let c = SkillComponent(agent: .copilot, homeDirectoryURL: home, fileManager: .default)
        try c.install()
        try FileManager.default.removeItem(at: home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md"))
        #expect(c.state() == .outdated)
    }

    @Test func installsBothSkillsIdempotentlyAndDetectsDrift() throws {
        let home = try tempHome()
        let c = SkillComponent(agent: .copilot, homeDirectoryURL: home, fileManager: .default)
        #expect(c.state() == .notInstalled)
        try c.install()
        #expect(c.state() == .installed)
        let ghz = home.appendingPathComponent(".copilot/skills/ghoztty/SKILL.md")
        let pf = home.appendingPathComponent(".copilot/skills/process-feedback/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: ghz.path))
        #expect(FileManager.default.fileExists(atPath: pf.path))
        try c.install() // idempotent
        #expect(c.state() == .installed)
        try "tampered <!-- ghoztty-managed -->".write(to: ghz, atomically: true, encoding: .utf8)
        #expect(c.state() == .outdated)
        try c.uninstall()
        #expect(c.state() == .notInstalled)
    }

    /// A skill is its directory: the reference files `SKILL.md` points the
    /// agent at are installed beside it, each with the marker, and go with it.
    @Test func installsEveryFileOfASkill() throws {
        let home = try tempHome()
        let c = SkillComponent(agent: .claude, homeDirectoryURL: home, fileManager: .default)
        try c.install()
        let dir = home.appendingPathComponent(".claude/skills/ghoztty")
        let bundled = try GhosttyAssets.skillFiles("ghoztty").map(\.path)
        #expect(bundled.count > 1, "the ghoztty skill ships reference files beside SKILL.md")
        for path in bundled {
            let text = try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
            #expect(text.contains(SkillComponent.marker), "\(path) carries the managed marker")
        }
        try c.uninstall()
        #expect(!FileManager.default.fileExists(atPath: dir.path), "an emptied skill directory goes too")
    }

    /// A reference file an earlier version shipped and this one does not is
    /// stale: it reads as outdated and an update removes it. A file of the
    /// user's in the same directory is never touched.
    @Test func anUpdateRemovesManagedFilesTheBundleNoLongerShips() throws {
        let home = try tempHome()
        let c = SkillComponent(agent: .claude, homeDirectoryURL: home, fileManager: .default)
        try c.install()
        let dir = home.appendingPathComponent(".claude/skills/ghoztty")
        let stale = dir.appendingPathComponent("old-reference.md")
        let mine = dir.appendingPathComponent("my-notes.md")
        try "old\n\(SkillComponent.marker)\n".write(to: stale, atomically: true, encoding: .utf8)
        try "my own notes".write(to: mine, atomically: true, encoding: .utf8)
        #expect(c.state() == .outdated)

        try c.install()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: mine.path))
        #expect(c.state() == .installed)

        try c.uninstall()
        #expect(FileManager.default.fileExists(atPath: mine.path), "the user's file survives uninstall")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path))
    }
}
