// macos/Tests/Ghostty/BannerScriptInstallerTests.swift
import Foundation
import Testing
@testable import Ghostty

struct BannerScriptInstallerTests {
    private func tempHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installsToStablePathWithNeutralStateDir() throws {
        let home = try tempHome()
        let i = BannerScriptInstaller(homeDirectoryURL: home, fileManager: .default)
        #expect(i.state() == .notInstalled)
        try i.install()
        #expect(i.state() == .installed)
        let url = home.appendingPathComponent(".config/ghoztty/hooks/ghoztty-banner.sh")
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains(".config/ghoztty/banner-state"))
        #expect(!body.contains(".claude/ghoztty-banner"))
        // executable bit
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(mode == 0o700)
    }

    // T1904: an update's hook-script fix reaches the installed copy on launch.
    @Test func refreshRewritesAStaleOwnedScript() throws {
        let home = try tempHome()
        let i = BannerScriptInstaller(homeDirectoryURL: home, fileManager: .default)
        try i.install()
        let url = BannerScriptInstaller.scriptURL(homeDirectoryURL: home)
        try "#!/bin/sh\n\(BannerScriptInstaller.marker)\necho old help\n"
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(i.state() == .outdated)

        #expect(i.refreshIfOutdated() == .refreshed)
        #expect(i.state() == .installed)
        #expect(try String(contentsOf: url, encoding: .utf8) == GhosttyAssets.bannerScript())
        #expect(i.refreshIfOutdated() == .current)
    }

    @Test func refreshNeverSetsUpWhatWasNeverInstalled() throws {
        let home = try tempHome()
        let i = BannerScriptInstaller(homeDirectoryURL: home, fileManager: .default)
        #expect(i.refreshIfOutdated() == .notInstalled)
        let url = BannerScriptInstaller.scriptURL(homeDirectoryURL: home)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func refreshLeavesAUsersOwnScriptAlone() throws {
        let home = try tempHome()
        let i = BannerScriptInstaller(homeDirectoryURL: home, fileManager: .default)
        let dir = BannerScriptInstaller.directoryURL(homeDirectoryURL: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = BannerScriptInstaller.scriptURL(homeDirectoryURL: home)
        let mine = "#!/bin/sh\necho mine\n"
        try mine.write(to: url, atomically: true, encoding: .utf8)

        #expect(i.refreshIfOutdated() == .notInstalled)
        #expect(try String(contentsOf: url, encoding: .utf8) == mine)
    }

    @Test func bundledScriptHasNoClaudeStateDir() throws {
        #expect(try GhosttyAssets.bannerScript().contains(".config/ghoztty/banner-state"))
        #expect(try !GhosttyAssets.bannerScript().contains(".claude/ghoztty-banner"))
    }
}
