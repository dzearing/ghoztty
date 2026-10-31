import Foundation

/// Reads and writes the user's config file for the Settings window.
///
/// Every write re-reads the file from disk first, so an edit the user made
/// in their editor a moment ago is never clobbered by stale state; then it
/// applies one surgical `ConfigFileText` edit and writes the result back.
///
/// - A symlinked config (dotfiles) is written through the link, to its
///   target, so the link survives.
/// - The write is atomic and keeps the file's permissions.
/// - Before the first change in a session the current file is copied to
///   `backupDirectory` (timestamped; the newest `backupsKept` are kept).
/// - A missing file (and its directories) is created on first write.
final class ConfigFileStore {
    enum StoreError: Error, LocalizedError {
        case notUTF8(URL)

        var errorDescription: String? {
            switch self {
            case .notUTF8(let url): return "\(url.path) isn't UTF-8 text, so Settings won't edit it."
            }
        }
    }

    /// The config file as the app loads it (may be a symlink).
    let url: URL
    let backupDirectory: URL
    let backupsKept: Int
    private let fileManager: FileManager
    private let now: () -> Date

    /// Where this session's backup went, once one was made.
    private(set) var backupURL: URL?
    private var backupDone = false

    init(
        url: URL,
        backupDirectory: URL,
        backupsKept: Int = 10,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.url = url
        self.backupDirectory = backupDirectory
        self.backupsKept = backupsKept
        self.fileManager = fileManager
        self.now = now
    }

    /// The file the bytes live in: `url` with symlinks resolved.
    var targetURL: URL { url.resolvingSymlinksInPath() }

    /// The current contents (empty if the file doesn't exist yet).
    func read() throws -> ConfigFileText {
        let target = targetURL
        guard fileManager.fileExists(atPath: target.path) else { return ConfigFileText("") }
        let data = try Data(contentsOf: target)
        guard let text = String(data: data, encoding: .utf8) else { throw StoreError.notUTF8(target) }
        return ConfigFileText(text)
    }

    /// The result of one edit: the file before and after (equal if the edit
    /// was a no-op, in which case nothing was written).
    struct Change {
        let before: ConfigFileText
        let after: ConfigFileText
        var changed: Bool { before != after }
    }

    @discardableResult
    func edit(_ mutate: (inout ConfigFileText) throws -> Void) throws -> Change {
        let before = try read()
        var after = before
        try mutate(&after)
        let change = Change(before: before, after: after)
        guard change.changed else { return change }

        let target = targetURL
        try backUpIfNeeded(target)
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        let permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try Data(after.string.utf8).write(to: target, options: .atomic)
        if let permissions {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        return change
    }

    /// Copy the file aside once per session, before its first change. A
    /// missing or empty file has nothing worth keeping.
    private func backUpIfNeeded(_ target: URL) throws {
        guard !backupDone else { return }
        backupDone = true
        guard let size = (try? fileManager.attributesOfItem(atPath: target.path))?[.size] as? Int,
              size > 0 else { return }

        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var name = "\(target.lastPathComponent).\(formatter.string(from: now()))"
        var dest = backupDirectory.appendingPathComponent(name)
        var n = 2
        while fileManager.fileExists(atPath: dest.path) {
            name = "\(target.lastPathComponent).\(formatter.string(from: now()))-\(n)"
            dest = backupDirectory.appendingPathComponent(name)
            n += 1
        }
        try fileManager.copyItem(at: target, to: dest)
        backupURL = dest
        pruneBackups(prefix: target.lastPathComponent + ".")
    }

    private func pruneBackups(prefix: String) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: backupDirectory.path) else { return }
        // Timestamped names sort chronologically.
        let backups = names.filter { $0.hasPrefix(prefix) }.sorted()
        for name in backups.dropLast(backupsKept) {
            try? fileManager.removeItem(at: backupDirectory.appendingPathComponent(name))
        }
    }

    /// Backups of this config, newest first.
    func backups() -> [URL] {
        let prefix = targetURL.lastPathComponent + "."
        let names = (try? fileManager.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted(by: >).map { backupDirectory.appendingPathComponent($0) }
    }

    /// Put a backup's contents back (itself a change, so it is backed up too).
    func restore(_ backup: URL) throws {
        let data = try Data(contentsOf: backup)
        guard let text = String(data: data, encoding: .utf8) else { throw StoreError.notUTF8(backup) }
        try edit { $0 = ConfigFileText(text) }
    }
}
