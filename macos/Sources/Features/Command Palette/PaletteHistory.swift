import Foundation

@MainActor
final class PaletteHistory {
    static let shared = PaletteHistory()

    private var history: [String: TimeInterval] = [:]
    private let fileURL: URL

    private init() {
        let configDir: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configDir = (xdg as NSString).appendingPathComponent("ghostty")
        } else {
            configDir = NSString("~/.config/ghostty").expandingTildeInPath
        }

        fileURL = URL(fileURLWithPath: configDir).appendingPathComponent("palette-history.json")
        load()
    }

    func recordUsage(for identifier: String) {
        history[identifier] = Date().timeIntervalSince1970
        save()
    }

    func recentIdentifiers(limit: Int = 10) -> [String] {
        history
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return
        }
        history = dict
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
