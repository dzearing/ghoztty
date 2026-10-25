import Foundation

enum GhosttyAssetsError: Error, LocalizedError {
    case missing(String)
    var errorDescription: String? {
        switch self {
        case .missing(let what): "Bundled Ghoztty asset missing: \(what)"
        }
    }
}

/// Reads the skill markdown + banner script bundled under `Ghoztty/` in the app
/// bundle's Resources. The bundle is the source of truth for the app-install path.
enum GhosttyAssets {
    static var rootURL: URL {
        get throws {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("Ghoztty", isDirectory: true),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw GhosttyAssetsError.missing("Ghoztty resources root")
            }
            return url
        }
    }

    /// Every file of a bundled skill — `SKILL.md` and the reference files it
    /// points the agent at, read only when needed — by path relative to the
    /// skill's directory, sorted. A skill is a directory, not one file: the
    /// `ghoztty` skill keeps a short core and moves the rest beside it so a
    /// session pays for what it reads, not for 54KB on every load.
    static func skillFiles(_ name: String) throws -> [(path: String, contents: String)] {
        let directory = try rootURL.appendingPathComponent("skills/\(name)", isDirectory: true)
        guard let paths = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            throw GhosttyAssetsError.missing("skill \(name)")
        }
        let files = try paths.filter { $0.hasSuffix(".md") }.sorted().map { path in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(path), encoding: .utf8) else {
                throw GhosttyAssetsError.missing("skill \(name)/\(path)")
            }
            return (path: path, contents: text)
        }
        guard files.contains(where: { $0.path == "SKILL.md" }) else {
            throw GhosttyAssetsError.missing("skill \(name)/SKILL.md")
        }
        return files
    }

    static func skillMarkdown(_ name: String) throws -> String {
        let url = try rootURL
            .appendingPathComponent("skills/\(name)/SKILL.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw GhosttyAssetsError.missing("skill \(name)")
        }
        return text
    }

    static func bannerScript() throws -> String {
        try hookScript(HookScripts.bannerName, describedAs: "banner script")
    }

    static func activityStateScript() throws -> String {
        try hookScript(HookScripts.activityStateName, describedAs: "activity-state script")
    }

    private static func hookScript(_ name: String, describedAs what: String) throws -> String {
        let url = try rootURL.appendingPathComponent("hooks/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw GhosttyAssetsError.missing(what)
        }
        return text
    }
}
