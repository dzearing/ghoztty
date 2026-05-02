import Foundation

struct IPCRequest: Decodable {
    let action: String
    let arguments: [String]?
}

struct IPCResponse: Encodable {
    let success: Bool
    let error: String?

    init(success: Bool, error: String? = nil) {
        self.success = success
        self.error = error
    }

    static let ok = IPCResponse(success: true)
}
