import Foundation
import GhosttyKit

/// The configuration schema as libghostty describes it
/// (`ghostty_config_schema_json`, generated from `Config.zig` and its doc
/// comments). The Settings window builds on this rather than a hand-kept list,
/// so a key added to `Config.zig` shows up here with its docs and default.
struct ConfigSchema {
    struct Entry: Decodable, Equatable {
        enum Kind: String, Decodable {
            case bool, int, float, `enum`, union, flags, string, other
        }

        let key: String
        /// What `+show-config` prints after `key = `, one string per line.
        let values: [String]
        let kind: Kind
        let optional: Bool
        let repeatable: Bool
        /// Enum tags, flag names, or union tags.
        let options: [String]?
        let doc: String?

        /// The single value of a plain key ("" for an unset optional).
        var value: String { values.first ?? "" }

        /// The doc's first paragraph, joined onto one line — the row subtitle.
        var summary: String {
            guard let doc else { return "" }
            let first = doc.components(separatedBy: "\n\n").first ?? doc
            var text = first.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            // "…created. Valid values:" — drop a trailing lead-in to a list.
            if text.hasSuffix(":"), let stop = text.dropLast().lastIndex(of: ".") {
                text = String(text[...stop])
            }
            // Inline code marks read as noise in a one-line subtitle.
            return text.replacingOccurrences(of: "`", with: "")
        }
    }

    let entries: [Entry]
    private let byKey: [String: Entry]

    init(entries: [Entry]) {
        self.entries = entries
        self.byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    subscript(key: String) -> Entry? { byKey[key] }

    /// Decode the JSON from `ghostty_config_schema_json`.
    static func decode(_ json: Data) throws -> ConfigSchema {
        ConfigSchema(entries: try JSONDecoder().decode([Entry].self, from: json))
    }

    /// Describe a config: its effective values (and, with `docs`, its docs).
    static func describe(_ config: ghostty_config_t, docs: Bool) -> ConfigSchema? {
        let str = ghostty_config_schema_json(config, docs)
        defer { ghostty_string_free(str) }
        guard let ptr = str.ptr, str.len > 0 else { return nil }
        let data = Data(bytes: ptr, count: Int(str.len))
        return try? decode(data)
    }

    /// The catalog: every key with its docs and default values.
    static func defaults() -> ConfigSchema? {
        guard let cfg = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(cfg) }
        return describe(cfg, docs: true)
    }

    /// The config file the user edits — what "Open Config" opens — without
    /// creating it.
    static func preferredPath() -> String? {
        let str = ghostty_config_preferred_path()
        defer { ghostty_string_free(str) }
        guard let ptr = str.ptr, str.len > 0 else { return nil }
        return String(decoding: Data(bytes: ptr, count: Int(str.len)), as: UTF8.self)
    }
}

/// Checks config lines with Ghostty's own parser before Settings writes them,
/// so an invalid value is reported inline and never lands in the file.
enum ConfigValidator {
    /// Parse `lines` (e.g. `["font-size = abc"]`) on a scratch default config
    /// and return Ghostty's diagnostics, cleaned for display (no temp path).
    static func problems(in lines: [String]) -> [String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghoztty-settings-validate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)) != nil,
              let cfg = ghostty_config_new() else { return [] }
        defer { ghostty_config_free(cfg) }
        ghostty_config_load_file(cfg, file.path)

        var out: [String] = []
        for i in 0..<ghostty_config_diagnostics_count(cfg) {
            let message = String(cString: ghostty_config_get_diagnostic(cfg, UInt32(i)).message)
            out.append(clean(message, path: file.path))
        }
        return out
    }

    /// `/tmp/…/X:1:font-size: invalid value "abc"` → `invalid value "abc"`.
    static func clean(_ message: String, path: String) -> String {
        var text = message
        if let range = text.range(of: path) {
            text.removeSubrange(text.startIndex..<range.upperBound)
            // Drop ":<line>:" and a repeated "<key>:" prefix.
            text = text.replacingOccurrences(of: #"^:\d+:"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"^\s*[a-z0-9-]+:\s*"#, with: "", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
