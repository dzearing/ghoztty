import Foundation

/// The text of a Ghostty config file, edited surgically.
///
/// The Settings window never rewrites the config from parsed state: it
/// changes only the lines for the key being set and leaves every other byte —
/// comments, blank lines, ordering, `config-file` includes, keys it doesn't
/// know, line endings — exactly as the user wrote them.
///
/// The grammar mirrors `LineIterator` in `src/cli/args.zig`: a line is
/// trimmed (spaces, tabs, CR); blank lines and lines starting with `#` are
/// ignored; `key = value` sets a key (the value trimmed, one pair of outer
/// double quotes stripped); a bare `key` is the flag form (`--key`). There are
/// no sections — conditional values live inside a value
/// (`theme = light:A,dark:B`). For a plain key the LAST line wins; for a
/// repeatable key (`keybind`, `font-family`, `palette`, …) every line adds a
/// value and an empty value resets the list.
struct ConfigFileText: Equatable {
    struct Line: Equatable {
        var text: String
        /// "\n", "\r\n", or "" for a last line with no newline.
        var ending: String
    }

    /// A line that sets a key.
    struct Entry: Equatable {
        let index: Int
        let key: String
        /// The value as Ghostty reads it (trimmed, outer quotes stripped).
        /// `nil` for the bare flag form.
        let value: String?
    }

    enum EditError: Error, Equatable, LocalizedError {
        case multiline(key: String)
        case lineTooLong(key: String)

        var errorDescription: String? {
            switch self {
            case .multiline(let key): return "A value for \(key) can't contain a line break."
            case .lineTooLong(let key): return "The line for \(key) would be longer than Ghostty reads (4096 bytes)."
            }
        }
    }

    /// Ghostty's `LineIterator.MAX_LINE_SIZE`, less the `--` it prepends.
    static let maxLineBytes = 4094

    private(set) var lines: [Line]
    /// The newline new lines get: the file's own (CRLF if most lines use it).
    let newline: String
    /// A UTF-8 byte-order mark the file started with, written back as-is.
    let bom: Bool

    init(_ contents: String) {
        var text = contents
        bom = text.hasPrefix("\u{FEFF}")
        if bom { text.removeFirst() }

        var lines: [Line] = []
        var crlf = 0, lf = 0
        var current = ""
        var iterator = text.unicodeScalars.makeIterator()
        var pendingCR = false
        // Walk scalars so a lone "\r" stays part of its line's text (Ghostty
        // only splits on "\n") while "\r\n" is recognized as one ending.
        while let scalar = iterator.next() {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" {
                    lines.append(Line(text: current, ending: "\r\n"))
                    current = ""
                    crlf += 1
                    continue
                }
                current.unicodeScalars.append("\r")
            }
            switch scalar {
            case "\r": pendingCR = true
            case "\n":
                lines.append(Line(text: current, ending: "\n"))
                current = ""
                lf += 1
            default: current.unicodeScalars.append(scalar)
            }
        }
        if pendingCR { current.unicodeScalars.append("\r") }
        if !current.isEmpty { lines.append(Line(text: current, ending: "")) }

        self.lines = lines
        self.newline = crlf > lf ? "\r\n" : "\n"
    }

    var string: String {
        (bom ? "\u{FEFF}" : "") + lines.map { $0.text + $0.ending }.joined()
    }

    // MARK: Reading

    /// Parse one line the way Ghostty does. `nil` for blank lines and comments.
    static func parse(_ line: String) -> (key: String, value: String?)? {
        let trimmed = line.trimmingCharacters(in: Self.lineWhitespace)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return (trimmed, nil) }
        let key = trimmed[..<eq].trimmingCharacters(in: Self.lineWhitespace)
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: Self.lineWhitespace)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    /// Ghostty trims spaces, tabs and CR around a line (`whitespace ++ "\r"`).
    private static let lineWhitespace = CharacterSet(charactersIn: " \t\r")

    var entries: [Entry] {
        lines.enumerated().compactMap { index, line in
            guard let (key, value) = Self.parse(line.text) else { return nil }
            return Entry(index: index, key: key, value: value)
        }
    }

    func entries(for key: String) -> [Entry] {
        entries.filter { $0.key == key }
    }

    /// The value the file gives a plain key (its last line), if it sets it.
    func value(for key: String) -> String?? {
        guard let last = entries(for: key).last else { return nil }
        return .some(last.value)
    }

    /// The values the file adds for a repeatable key, in order, honoring an
    /// empty-value reset (only the values after the last reset count).
    func values(for key: String) -> [String] {
        var out: [String] = []
        for entry in entries(for: key) {
            let value = entry.value ?? ""
            if value.isEmpty { out.removeAll() } else { out.append(value) }
        }
        return out
    }

    // MARK: Editing

    /// Set a plain (non-repeatable) key. Rewrites the LAST line that sets it
    /// (the one Ghostty honors), keeping its indentation, and leaves earlier
    /// lines alone — they are already overridden. Appends if the key is unset.
    mutating func set(_ key: String, _ value: String) throws {
        let line = try Self.render(key, value)
        if let last = entries(for: key).last {
            lines[last.index].text = indentation(of: last.index) + line
        } else {
            append([line])
        }
    }

    /// Remove every line that sets `key`, so it goes back to its default.
    mutating func remove(_ key: String) {
        removeLines(entries(for: key).map(\.index))
    }

    /// Make a repeatable key's lines produce exactly `values`, with the
    /// smallest change: the longest run of existing lines that already
    /// matches `values` in order stays untouched (and so do the comments
    /// between them), other lines for the key are removed, and each new value
    /// goes just before the next kept line — or after the last kept one,
    /// where the key first appeared, or at the end.
    mutating func setList(_ key: String, _ values: [String]) throws {
        let rendered = try values.map { try Self.render(key, $0) }
        let existing = entries(for: key)
        let matched = Self.longestCommonSubsequence(existing.map { $0.value ?? "" }, values)
        let indent = existing.first.map { indentation(of: $0.index) } ?? ""

        var before: [Int: [String]] = [:]   // line index → new lines inserted before it
        var after: [Int: [String]] = [:]    // line index → new lines inserted after it
        var atEnd: [String] = []
        for (j, line) in rendered.enumerated() where !matched.contains(where: { $0.1 == j }) {
            if let next = matched.first(where: { $0.1 > j }) {
                before[existing[next.0].index, default: []].append(indent + line)
            } else if let previous = matched.last {
                after[existing[previous.0].index, default: []].append(indent + line)
            } else if let first = existing.first {
                before[first.index, default: []].append(indent + line)
            } else {
                atEnd.append(line)
            }
        }
        let keptLines = Set(matched.map { existing[$0.0].index })
        let removed = Set(existing.map(\.index)).subtracting(keptLines)

        let terminated = lines.last.map { !$0.ending.isEmpty } ?? true
        var out: [Line] = []
        for (index, line) in lines.enumerated() {
            out += (before[index] ?? []).map { Line(text: $0, ending: newline) }
            if !removed.contains(index) {
                var line = line
                if line.ending.isEmpty { line.ending = newline }
                out.append(line)
            }
            out += (after[index] ?? []).map { Line(text: $0, ending: newline) }
        }
        out += atEnd.map { Line(text: $0, ending: newline) }
        if !terminated, !out.isEmpty { out[out.count - 1].ending = "" }
        lines = out
    }

    /// Index pairs (into `a`, into `b`) of a longest common subsequence.
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return pairs
    }

    /// Set (or with `nil`, remove) one keyed entry of a repeatable key whose
    /// values are `subkey=rest` — a `keybind` trigger, a `palette` index, an
    /// `env` name. `subkeyOf` extracts (and normalizes) an entry's subkey, so
    /// `cmd+k` and `super+k` can be the same keybind; `normalize` must apply
    /// the same normalization to `subkey`. The last matching line is
    /// rewritten in place and earlier matches removed; with no match the new
    /// line goes after the key's last line, or at the end.
    mutating func setKeyed(
        _ key: String,
        subkey: String,
        rest: String?,
        subkeyOf: (String) -> String? = ConfigFileText.subkeyBeforeEquals,
        normalize: (String) -> String = { $0 }
    ) throws {
        let target = normalize(subkey)
        let matches = entries(for: key).filter { entry in
            guard let value = entry.value else { return false }
            return subkeyOf(value) == target
        }
        guard let rest else {
            removeLines(matches.map(\.index))
            return
        }
        let line = try Self.render(key, "\(subkey)=\(rest)")
        if let last = matches.last {
            lines[last.index].text = indentation(of: last.index) + line
            removeLines(matches.dropLast().map(\.index))
        } else if let lastOfKey = entries(for: key).last {
            insert([indentation(of: lastOfKey.index) + line], at: lastOfKey.index + 1)
        } else {
            append([line])
        }
    }

    /// Add one value to a repeatable key, after its last line (or at the end).
    mutating func add(_ key: String, _ value: String) throws {
        let line = try Self.render(key, value)
        if let last = entries(for: key).last {
            insert([indentation(of: last.index) + line], at: last.index + 1)
        } else {
            append([line])
        }
    }

    // MARK: Helpers

    /// `0=#1d1f21` → `0`, `FOO=bar` → `FOO`: the text before the first `=`.
    static func subkeyBeforeEquals(_ value: String) -> String? {
        value.firstIndex(of: "=").map { String(value[..<$0]).trimmingCharacters(in: lineWhitespace) }
    }

    /// `key = value`, quoting the value when Ghostty would otherwise change it
    /// (surrounding whitespace is trimmed, one pair of outer quotes stripped).
    static func render(_ key: String, _ value: String) throws -> String {
        guard !value.contains(where: { $0.isNewline }) else { throw EditError.multiline(key: key) }
        let needsQuotes = value != value.trimmingCharacters(in: lineWhitespace)
            || (value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\""))
        let line = "\(key) = " + (needsQuotes ? "\"\(value)\"" : value)
        guard line.utf8.count <= maxLineBytes else { throw EditError.lineTooLong(key: key) }
        return line
    }

    private func indentation(of index: Int) -> String {
        String(lines[index].text.prefix { $0 == " " || $0 == "\t" })
    }

    private mutating func removeLines(_ indices: [Int]) {
        for index in indices.sorted(by: >) {
            let removed = lines.remove(at: index)
            // Removing the unterminated last line must not leave the new
            // last line with a dangling newline the file didn't have.
            if index == lines.count, removed.ending.isEmpty, !lines.isEmpty {
                lines[lines.count - 1].ending = ""
            }
        }
    }

    private mutating func insert(_ texts: [String], at index: Int) {
        if index >= lines.count { append(texts); return }
        lines.insert(contentsOf: texts.map { Line(text: $0, ending: newline) }, at: index)
    }

    private mutating func append(_ texts: [String]) {
        guard !texts.isEmpty else { return }
        // Terminate an unterminated last line first; never glue onto it.
        let hadTrailingNewline = lines.last.map { !$0.ending.isEmpty } ?? true
        if let last = lines.indices.last, lines[last].ending.isEmpty {
            lines[last].ending = newline
        }
        lines += texts.map { Line(text: $0, ending: newline) }
        if !hadTrailingNewline { lines[lines.count - 1].ending = "" }
    }
}
