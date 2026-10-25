// macos/Sources/Features/Setup/SkillComponent.swift
import Foundation

/// Installs the bundled `ghoztty` and `process-feedback` skills into a runtime's
/// `skills/` directory. Portable: only the config dir differs per runtime.
///
/// A skill is a DIRECTORY: `SKILL.md` plus the reference files it tells the
/// agent to read on demand (`GhosttyAssets.skillFiles`). Every file carries
/// the managed marker, and a managed file the bundle no longer ships is
/// removed on update — otherwise a renamed reference file would linger, and
/// the agent would read a stale copy.
struct SkillComponent {
    static let marker = GhosttyManagedMarker.htmlComment
    static let skillNames = ["ghoztty", "process-feedback"]

    let agent: RuntimeAgent
    let homeDirectoryURL: URL
    let fileManager: FileManager

    private func skillDirectory(_ name: String) -> URL {
        agent.configDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent("skills/\(name)", isDirectory: true)
    }

    /// Each file the bundle ships for `name`, where it goes and what it holds.
    private func expected(_ name: String) throws -> [(url: URL, body: String)] {
        try GhosttyAssets.skillFiles(name).map { file in
            (url: skillDirectory(name).appendingPathComponent(file.path), body: file.contents + "\n\(Self.marker)\n")
        }
    }

    /// Managed files in the installed skill directory that are not in
    /// `keeping`: what an earlier version shipped and this one does not. A
    /// file without the marker is the user's and is never touched.
    private func strays(_ name: String, keeping: Set<URL>) -> [URL] {
        let directory = skillDirectory(name)
        guard let paths = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let kept = Set(keeping.map(\.standardizedFileURL))
        return paths.map { directory.appendingPathComponent($0) }.filter { url in
            !kept.contains(url.standardizedFileURL)
                && ((try? String(contentsOf: url, encoding: .utf8))?.contains(Self.marker) ?? false)
        }
    }

    func state() -> ComponentInstallState {
        var states: [ComponentInstallState] = []
        for name in Self.skillNames {
            guard let files = try? expected(name) else { return .outdated }
            states += files.map { ManagedFile.state(at: $0.url, expected: $0.body, marker: Self.marker) }
            if !strays(name, keeping: Set(files.map(\.url))).isEmpty { states.append(.outdated) }
        }
        if states.allSatisfy({ $0 == .installed }) { return .installed }
        if states.allSatisfy({ $0 == .notInstalled }) { return .notInstalled }
        return .outdated
    }

    func install() throws {
        // Render all up front so a missing bundled asset fails before any write.
        let rendered = try Self.skillNames.map { (name: $0, files: try expected($0)) }
        var written: [URL] = []
        do {
            for file in rendered.flatMap(\.files) {
                try ManagedFile.write(file.body, to: file.url, marker: Self.marker, mode: 0o600, fileManager: fileManager)
                written.append(file.url)
            }
        } catch {
            for url in written.reversed() {
                try? ManagedFile.removeIfManaged(at: url, marker: Self.marker, fileManager: fileManager)
            }
            throw error
        }
        for skill in rendered {
            for url in strays(skill.name, keeping: Set(skill.files.map(\.url))) {
                try ManagedFile.removeIfManaged(at: url, marker: Self.marker, fileManager: fileManager)
            }
        }
    }

    func uninstall() throws {
        for name in Self.skillNames {
            for url in strays(name, keeping: []) {
                try ManagedFile.removeIfManaged(at: url, marker: Self.marker, fileManager: fileManager)
            }
            // Only an emptied directory goes: a file of the user's keeps it.
            let directory = skillDirectory(name)
            if (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try? fileManager.removeItem(at: directory)
            }
        }
    }
}
