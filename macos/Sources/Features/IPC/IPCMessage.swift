import Foundation

struct IPCRequest: Decodable {
    let action: String
    let arguments: [String]?
    /// The pane the command was run from (`$GHOZTTY_PANE_ID`), which every
    /// CLI command sends so a name is looked up in the caller's own window
    /// first (`TargetLookup`). A top-level field rather than an argument
    /// because it is additive both ways: an older app's decoder ignores it,
    /// where an extra argument would have become banner text in its
    /// `+set-banner`. Absent from an older CLI.
    let callerPane: String?

    private enum CodingKeys: String, CodingKey {
        case action, arguments
        case callerPane = "caller_pane"
    }

    init(action: String, arguments: [String]?, callerPane: String? = nil) {
        self.action = action
        self.arguments = arguments
        self.callerPane = callerPane
    }

    /// `arguments` with `callerPane` folded in as `--caller-pane=`, the one
    /// spelling every handler reads — unless an argument already says it.
    /// It goes in front of `-e`: everything from there on is the user's
    /// command, verbatim.
    var resolvedArguments: [String]? {
        guard let callerPane, !callerPane.isEmpty else { return arguments }
        var arguments = self.arguments ?? []
        let commandStart = arguments.firstIndex(of: "-e") ?? arguments.endIndex
        guard !arguments[..<commandStart].contains(where: { $0.hasPrefix("--caller-pane=") }) else {
            return arguments
        }
        arguments.insert("--caller-pane=\(callerPane)", at: commandStart)
        return arguments
    }
}

struct IPCResponse: Encodable {
    let success: Bool
    let error: String?
    let data: IPCData?
    /// One human-readable line saying what the command did, which the CLI
    /// prints to stdout on success (`+split`: created, or reused and where).
    /// Additive: an older CLI ignores it, and an older app never sends it.
    let message: String?

    init(success: Bool, error: String? = nil, data: IPCData? = nil, message: String? = nil) {
        self.success = success
        self.error = error
        self.data = data
        self.message = message
    }

    static let ok = IPCResponse(success: true)
}

enum IPCData: Encodable {
    case listState(ListStateData)
    case readResult(ReadResultData)

    struct ListStateData: Encodable {
        let windows: [WindowData]
    }

    struct WindowData: Encodable {
        let id: String
        let title: String
        let target: String?
        let focused: Bool
        let tabs: [TabData]
        /// The window's title was typed by the user, so `+rename` leaves it
        /// alone. Additive: an older app never sends it.
        let title_set_by_user: Bool
    }

    struct TabData: Encodable {
        let id: String
        let title: String
        let index: Int
        let selected: Bool
        let splits: SplitNodeData
    }

    indirect enum SplitNodeData: Encodable {
        case leaf(TerminalData)
        case split(direction: String, ratio: Double, left: SplitNodeData, right: SplitNodeData)

        private enum CodingKeys: String, CodingKey {
            case type, terminal, direction, ratio, left, right
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .leaf(let terminal):
                try container.encode("leaf", forKey: .type)
                try container.encode(terminal, forKey: .terminal)
            case .split(let direction, let ratio, let left, let right):
                try container.encode("split", forKey: .type)
                try container.encode(direction, forKey: .direction)
                try container.encode(ratio, forKey: .ratio)
                try container.encode(left, forKey: .left)
                try container.encode(right, forKey: .right)
            }
        }
    }

    struct TerminalData: Encodable {
        let id: String
        let title: String
        let working_directory: String
        let pid: Int
        let tty: String
        let name: String?
        let focused: Bool
        let exit_code: Int?
        /// Pane kind: "terminal" or "viewer".
        var pane_type: String = "terminal"
        /// The viewed file path or URL (viewer panes only).
        var url: String? = nil
        /// The pane's sticky banner text (terminal panes only; nil when none).
        var banner: String? = nil
        /// True when the pane is stashed in its window's pane sidebar: out of
        /// the layout, still running. Absent (not false) otherwise, like
        /// `banner` — an additive field older readers never see.
        var stashed: Bool? = nil
        /// The pane's activity state as its machine token (`idle`, `busy`,
        /// `needs_input` — the `+set-state` vocabulary, never the title's
        /// human label). Terminal panes only; absent for viewers, which have
        /// no activity state.
        var state: String? = nil

        private enum CodingKeys: String, CodingKey {
            case id, title, working_directory, pid, tty, name, focused, exit_code
            case pane_type = "type"
            case url
            case banner
            case stashed
            case state
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(working_directory, forKey: .working_directory)
            try container.encode(pid, forKey: .pid)
            try container.encode(tty, forKey: .tty)
            try container.encode(name, forKey: .name)
            try container.encode(focused, forKey: .focused)
            try container.encode(exit_code, forKey: .exit_code)
            try container.encode(pane_type, forKey: .pane_type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(banner, forKey: .banner)
            try container.encodeIfPresent(stashed == true ? true : nil, forKey: .stashed)
            try container.encodeIfPresent(state, forKey: .state)
        }
    }

    struct ReadResultData: Encodable {
        let text: String
    }

    private enum CodingKeys: String, CodingKey {
        case windows
        case text
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .listState(let data):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(data.windows, forKey: .windows)
        case .readResult(let data):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(data.text, forKey: .text)
        }
    }
}
