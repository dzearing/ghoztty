import Foundation
import Combine
import GhosttyKit
import SwiftUI

/// State behind the Settings window.
///
/// - `catalog`: every key with its docs and default (libghostty's schema).
/// - `effective`: what the running app actually uses (the live config).
/// - `file`: the user's editable config file — the source of truth. Settings
///   only ever changes it through one surgical `ConfigFileText` edit per
///   action, then reloads the config so the change applies live.
///
/// A value Ghostty would reject is never written: each new line is first
/// parsed by Ghostty itself (`ConfigValidator`) and a problem is shown on the
/// row instead.
@MainActor
final class SettingsModel: ObservableObject {
    /// One file Ghostty loads, in load order.
    struct Source: Equatable {
        let url: URL
        let text: ConfigFileText
        /// Reached through `config-file` rather than a default location.
        let included: Bool
    }

    /// The last change, for the "Saved · Show change · Undo" toast.
    struct LastChange: Equatable {
        let id = UUID()
        let message: String
        let removed: [String]
        let added: [String]
        let backedUpTo: URL?
        fileprivate let before: ConfigFileText
        fileprivate let after: ConfigFileText

        static func == (a: LastChange, b: LastChange) -> Bool { a.id == b.id }
    }

    let catalog: ConfigSchema
    let store: ConfigFileStore
    @Published private(set) var effective: ConfigSchema
    @Published private(set) var file: ConfigFileText
    @Published private(set) var sources: [Source] = []
    @Published private(set) var lastChange: LastChange?
    /// Row-level problems (an invalid value that wasn't written), by key.
    @Published var problems: [String: String] = [:]
    /// A problem with the file itself (unreadable, not UTF-8, …).
    @Published var fileError: String?

    private let reload: () -> Void
    private let liveConfig: () -> ghostty_config_t?
    private var observers: [NSObjectProtocol] = []

    init(
        catalog: ConfigSchema,
        store: ConfigFileStore,
        reload: @escaping () -> Void,
        liveConfig: @escaping () -> ghostty_config_t?
    ) {
        self.catalog = catalog
        self.store = store
        self.reload = reload
        self.liveConfig = liveConfig
        self.effective = liveConfig().flatMap { ConfigSchema.describe($0, docs: false) } ?? catalog
        self.file = (try? store.read()) ?? ConfigFileText("")
        refreshSources()

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange, object: nil, queue: .main
        ) { [weak self] note in
            // App-level changes only (surface-level ones carry an object).
            guard note.object == nil else { return }
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Re-read the live config and every config file.
    func refresh() {
        if let live = liveConfig(), let described = ConfigSchema.describe(live, docs: false) {
            effective = described
        }
        do {
            file = try store.read()
            fileError = nil
        } catch {
            fileError = error.localizedDescription
        }
        refreshSources()
    }

    // MARK: Reading

    func doc(_ key: String) -> ConfigSchema.Entry? { catalog[key] }

    /// The effective value of a plain key. When the user's file sets it and
    /// no later file overrides it, that line IS the effective value — so read
    /// it straight from the file, which also shows a change at once rather
    /// than after the reload round-trip.
    func value(_ key: String) -> String {
        if catalog[key]?.repeatable != true, overridingSource(key) == nil,
           case .some(let fileValue) = file.value(for: key) {
            return fileValue ?? "true"
        }
        return effective[key]?.value ?? catalog[key]?.value ?? ""
    }

    /// The effective values of a repeatable key. For a key with no default
    /// values (`font-family`, `font-feature`, `env`, …) that only the user's
    /// file sets, the file's lines are the whole list — read them directly so
    /// a change shows at once.
    func values(_ key: String) -> [String] {
        let fileValues = file.values(for: key)
        let defaultsEmpty = catalog[key]?.values.allSatisfy(\.isEmpty) ?? true
        let setElsewhere = sources.filter { !$0.text.entries(for: key).isEmpty }.count > 1
        if !fileValues.isEmpty, defaultsEmpty, !setElsewhere { return fileValues }
        return effective[key]?.values ?? catalog[key]?.values ?? []
    }

    func defaultValue(_ key: String) -> String { catalog[key]?.values.joined(separator: ", ") ?? "" }

    /// The user's file sets this key.
    func isSetInFile(_ key: String) -> Bool { !file.entries(for: key).isEmpty }

    /// Differs from the default — set here or in another file.
    func isModified(_ key: String) -> Bool {
        isSetInFile(key) || (effective[key]?.values ?? []) != (catalog[key]?.values ?? [])
    }

    /// A file Ghostty loads AFTER the user's file that also sets `key`: it
    /// wins, so an edit here would be silently overridden. Settings shows
    /// such a key read-only and points at that file instead.
    func overridingSource(_ key: String) -> Source? {
        guard let mine = mainSourceIndex
        else { return nil }
        return sources[(mine + 1)...].last { !$0.text.entries(for: key).isEmpty }
    }

    /// For a keyed repeatable entry (a keybind trigger, a palette index).
    func overridingSource(_ key: String, subkey: String, subkeyOf: (String) -> String?) -> Source? {
        guard let mine = mainSourceIndex
        else { return nil }
        return sources[(mine + 1)...].last { source in
            source.text.entries(for: key).contains { $0.value.flatMap(subkeyOf) == subkey }
        }
    }

    /// Where the user's own file sits in the load order.
    private var mainSourceIndex: Int? {
        let target = store.targetURL.standardizedFileURL.path
        return sources.lastIndex { $0.url.resolvingSymlinksInPath().standardizedFileURL.path == target }
    }

    /// Keys the curated pages don't show but that the user's files set.
    var keysSetInFiles: Set<String> {
        Set(sources.flatMap { $0.text.entries.map(\.key) })
    }

    // MARK: Writing

    /// Set a plain key. Returns false (and records a row problem) if Ghostty
    /// rejects the value; nothing is written then.
    @discardableResult
    func set(_ key: String, _ value: String) -> Bool {
        if let source = overridingSource(key) {
            problems[key] = "Set in \(source.url.lastPathComponent), which loads after your config — change it there."
            return false
        }
        guard validate(key, lines: [value]) else { return false }
        return apply(key, message: "Saved \(key)") { try $0.set(key, value) }
    }

    /// Back to the default: remove the key from the user's file.
    func reset(_ key: String) {
        problems[key] = nil
        apply(key, message: "Reset \(key) to its default") { $0.remove(key) }
    }

    /// Make a repeatable key's lines in the user's file exactly `values`.
    @discardableResult
    func setList(_ key: String, _ values: [String]) -> Bool {
        guard validate(key, lines: values) else { return false }
        return apply(key, message: "Saved \(key)") { try $0.setList(key, values) }
    }

    /// Set or remove one keyed entry of a repeatable key.
    @discardableResult
    func setKeyed(
        _ key: String,
        subkey: String,
        rest: String?,
        subkeyOf: @escaping (String) -> String? = ConfigFileText.subkeyBeforeEquals,
        normalize: @escaping (String) -> String = { $0 },
        problemKey: String? = nil
    ) -> Bool {
        let problemKey = problemKey ?? key
        if let source = overridingSource(key, subkey: normalize(subkey), subkeyOf: subkeyOf) {
            problems[problemKey] = "\(subkey) is set in \(source.url.lastPathComponent), which loads after your config — change it there."
            return false
        }
        if let rest {
            guard validate(problemKey, configKey: key, lines: ["\(subkey)=\(rest)"]) else { return false }
        }
        problems[problemKey] = nil
        return apply(problemKey, message: "Saved \(key)") {
            try $0.setKeyed(key, subkey: subkey, rest: rest, subkeyOf: subkeyOf, normalize: normalize)
        }
    }

    /// Append a raw value to a repeatable key (Add Custom Binding).
    @discardableResult
    func add(_ key: String, _ value: String, problemKey: String? = nil) -> Bool {
        guard validate(problemKey ?? key, configKey: key, lines: [value]) else { return false }
        return apply(problemKey ?? key, message: "Saved \(key)") { try $0.add(key, value) }
    }

    /// Put the file back the way it was before the last change — only if it
    /// hasn't been edited since, so Undo never clobbers someone else's edit.
    func undoLastChange() {
        guard let change = lastChange else { return }
        do {
            let current = try store.read()
            guard current == change.after else {
                fileError = "The config file changed since — open it to undo by hand."
                return
            }
            try store.edit { $0 = change.before }
            lastChange = nil
            afterWrite()
        } catch {
            fileError = error.localizedDescription
        }
    }

    func dismissLastChange() { lastChange = nil }

    func restoreBackup(_ url: URL) {
        do {
            let change = try store.restore(url)
            record(change, message: "Restored \(url.lastPathComponent)")
            afterWrite()
        } catch {
            fileError = error.localizedDescription
        }
    }

    // MARK: Internals

    private func validate(_ problemKey: String, configKey: String? = nil, lines values: [String]) -> Bool {
        let key = configKey ?? problemKey
        do {
            let lines = try values.map { try ConfigFileText.render(key, $0) }
            if let problem = ConfigValidator.problems(in: lines).first {
                problems[problemKey] = problem
                return false
            }
        } catch {
            problems[problemKey] = error.localizedDescription
            return false
        }
        problems[problemKey] = nil
        return true
    }

    @discardableResult
    private func apply(_ key: String, message: String, _ edit: (inout ConfigFileText) throws -> Void) -> Bool {
        do {
            let change = try store.edit(edit)
            guard change.changed else { return true }
            record(change, message: message)
            afterWrite()
            return true
        } catch {
            problems[key] = error.localizedDescription
            return false
        }
    }

    private func record(_ change: ConfigFileStore.Change, message: String) {
        let diff = Self.lineDiff(change.before, change.after)
        lastChange = LastChange(
            message: message,
            removed: diff.removed,
            added: diff.added,
            backedUpTo: store.backupURL,
            before: change.before,
            after: change.after)
    }

    private func afterWrite() {
        fileError = nil
        file = (try? store.read()) ?? file
        refreshSources()
        reload()
    }

    /// Lines only in `a` / only in `b` (multiset difference — enough for the
    /// toast, which shows what one surgical edit touched).
    static func lineDiff(_ a: ConfigFileText, _ b: ConfigFileText) -> (removed: [String], added: [String]) {
        var counts: [String: Int] = [:]
        for line in a.lines { counts[line.text, default: 0] += 1 }
        var added: [String] = []
        for line in b.lines {
            if let n = counts[line.text], n > 0 { counts[line.text] = n - 1 } else { added.append(line.text) }
        }
        var remaining = counts
        let removed = a.lines.compactMap { line -> String? in
            guard let n = remaining[line.text], n > 0 else { return nil }
            remaining[line.text] = n - 1
            return line.text
        }
        return (removed, added)
    }

    // MARK: Sources (which files Ghostty loads, in order)

    private func refreshSources() {
        sources = Self.loadSources(main: store.targetURL)
    }

    /// The default files (XDG then App Support, each legacy name first, as in
    /// `Config.loadDefaultFiles`), then `config-file` includes in the order
    /// Ghostty processes them (`loadRecursiveFiles`: after all default files,
    /// nested includes appended). Paths are relative to the including file;
    /// a leading `?` marks an optional include.
    static func loadSources(main: URL, defaults: [URL]? = nil) -> [Source] {
        var out: [Source] = []
        var seen = Set<String>()
        func read(_ url: URL) -> ConfigFileText? {
            let resolved = url.resolvingSymlinksInPath()
            guard let data = try? Data(contentsOf: resolved), let text = String(data: data, encoding: .utf8) else { return nil }
            return ConfigFileText(text)
        }

        var queue: [(URL, ConfigFileText)] = []
        let defaultFiles = defaults ?? defaultFileURLs()
        for url in defaultFiles {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !seen.contains(key), let text = read(url) else { continue }
            seen.insert(key)
            out.append(Source(url: url, text: text, included: false))
            queue.append((url, text))
        }
        // The main file may not exist yet; it still anchors relative includes.
        let mainKey = main.resolvingSymlinksInPath().standardizedFileURL.path
        if !seen.contains(mainKey) {
            seen.insert(mainKey)
            let text = read(main) ?? ConfigFileText("")
            out.append(Source(url: main, text: text, included: false))
            queue.append((main, text))
        }

        var index = 0
        while index < queue.count {
            let (url, text) = queue[index]
            index += 1
            for include in text.values(for: "config-file") {
                var path = include
                if path.hasPrefix("?") { path.removeFirst() }
                if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
                let expanded = (path as NSString).expandingTildeInPath
                let target = expanded.hasPrefix("/")
                    ? URL(fileURLWithPath: expanded)
                    : url.deletingLastPathComponent().appendingPathComponent(expanded)
                let key = target.resolvingSymlinksInPath().standardizedFileURL.path
                guard !seen.contains(key), let includedText = read(target) else { continue }
                seen.insert(key)
                out.append(Source(url: target, text: includedText, included: true))
                queue.append((target, includedText))
            }
        }
        return out
    }

    static func defaultFileURLs() -> [URL] {
        let xdgBase = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let xdg = xdgBase.appendingPathComponent("ghostty", isDirectory: true)
        var urls = [xdg.appendingPathComponent("config"), xdg.appendingPathComponent("config.ghostty")]
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let bundle = Bundle.main.bundleIdentifier {
            let dir = support.appendingPathComponent(bundle, isDirectory: true)
            urls += [dir.appendingPathComponent("config"), dir.appendingPathComponent("config.ghostty")]
        }
        return urls
    }
}
