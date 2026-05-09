import Foundation

struct IPCRequest: Decodable {
    let action: String
    let arguments: [String]?
}

struct IPCResponse: Encodable {
    let success: Bool
    let error: String?
    let data: IPCData?

    init(success: Bool, error: String? = nil, data: IPCData? = nil) {
        self.success = success
        self.error = error
        self.data = data
    }

    static let ok = IPCResponse(success: true)
}

enum IPCData: Encodable {
    case listState(ListStateData)

    struct ListStateData: Encodable {
        let windows: [WindowData]
    }

    struct WindowData: Encodable {
        let id: String
        let title: String
        let target: String?
        let focused: Bool
        let tabs: [TabData]
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
    }

    private enum CodingKeys: String, CodingKey {
        case windows
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .listState(let data):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(data.windows, forKey: .windows)
        }
    }
}
