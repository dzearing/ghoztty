import Cocoa
import Darwin
import GhosttyKit
import OSLog

class IPCServer {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: IPCServer.self)
    )

    private let ghostty: Ghostty.App
    private let socketPath: String
    private var listenSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.ipc", qos: .utility)

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        let uid = getuid()
        self.socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostty-\(uid).sock").path
    }

    func start() {
        queue.async { [weak self] in
            self?.bindAndListen()
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
        }
        unlink(socketPath)
        Self.logger.info("IPC server stopped")
    }

    private func bindAndListen() {
        // Remove stale socket
        unlink(socketPath)

        listenSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenSocket >= 0 else {
            let err = errno
            Self.logger.error("Failed to create IPC socket: \(String(cString: strerror(err))) (\(err))")
            return
        }

        fcntl(listenSocket, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Self.logger.error("IPC socket path too long: \(self.socketPath)")
            Darwin.close(listenSocket)
            listenSocket = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenSocket, sockaddrPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Self.logger.error("Failed to bind IPC socket: \(String(cString: strerror(err))) (\(err))")
            Darwin.close(listenSocket)
            listenSocket = -1
            return
        }

        chmod(socketPath, 0o600)

        guard listen(listenSocket, 5) == 0 else {
            let err = errno
            Self.logger.error("Failed to listen on IPC socket: \(String(cString: strerror(err))) (\(err))")
            Darwin.close(listenSocket)
            listenSocket = -1
            return
        }

        Self.logger.info("IPC server listening on \(self.socketPath)")

        let source = DispatchSource.makeReadSource(fileDescriptor: listenSocket, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenSocket >= 0 {
                Darwin.close(self.listenSocket)
                self.listenSocket = -1
            }
        }
        acceptSource = source
        source.resume()
    }

    private func acceptConnection() {
        let clientFd = Darwin.accept(listenSocket, nil, nil)
        guard clientFd >= 0 else { return }

        queue.async { [weak self] in
            self?.handleClient(fd: clientFd)
            Darwin.close(clientFd)
        }
    }

    private func handleClient(fd: Int32) {
        var lengthBytes: [UInt8] = [0, 0, 0, 0]
        let bytesRead = recv(fd, &lengthBytes, 4, MSG_WAITALL)
        guard bytesRead == 4 else {
            Self.logger.warning("IPC: failed to read message length")
            sendResponse(fd: fd, response: IPCResponse(success: false, error: "invalid message"))
            return
        }

        let length = UInt32(lengthBytes[0]) << 24
            | UInt32(lengthBytes[1]) << 16
            | UInt32(lengthBytes[2]) << 8
            | UInt32(lengthBytes[3])

        guard length > 0, length < 1_048_576 else {
            Self.logger.warning("IPC: invalid message length \(length)")
            sendResponse(fd: fd, response: IPCResponse(success: false, error: "invalid length"))
            return
        }

        var payload = Data(count: Int(length))
        let payloadRead = payload.withUnsafeMutableBytes { buf in
            recv(fd, buf.baseAddress!, Int(length), MSG_WAITALL)
        }
        guard payloadRead == Int(length) else {
            Self.logger.warning("IPC: incomplete message payload")
            sendResponse(fd: fd, response: IPCResponse(success: false, error: "incomplete message"))
            return
        }

        let request: IPCRequest
        do {
            request = try JSONDecoder().decode(IPCRequest.self, from: payload)
        } catch {
            Self.logger.warning("IPC: malformed JSON: \(error)")
            sendResponse(fd: fd, response: IPCResponse(success: false, error: "malformed JSON"))
            return
        }

        Self.logger.info("IPC: received action '\(request.action)'")
        let response = dispatchAction(request)
        sendResponse(fd: fd, response: response)
    }

    private func sendResponse(fd: Int32, response: IPCResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        var length = UInt32(data.count).bigEndian
        let lengthSent = withUnsafeBytes(of: &length) { buf in
            send(fd, buf.baseAddress!, 4, 0)
        }
        if lengthSent != 4 {
            Self.logger.warning("IPC: failed to send response length")
            return
        }
        let dataSent = data.withUnsafeBytes { buf in
            send(fd, buf.baseAddress!, data.count, 0)
        }
        if dataSent != data.count {
            Self.logger.warning("IPC: failed to send response payload")
        }
    }

    private func dispatchAction(_ request: IPCRequest) -> IPCResponse {
        switch request.action {
        case "new-window":
            return handleNewWindow(request)
        default:
            return IPCResponse(success: false, error: "unknown action: \(request.action)")
        }
    }

    struct ParsedArguments {
        var config: Ghostty.SurfaceConfiguration
        var splitDirection: String?
        var splitCommand: String?
    }

    private func handleNewWindow(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        DispatchQueue.main.async { [ghostty = self.ghostty] in
            let controller = TerminalController.newWindow(ghostty, withBaseConfig: parsed.config)

            if let splitDir = parsed.splitDirection,
               let direction = Self.parseSplitDirection(splitDir) {
                // Defer the split to the next run loop tick so the window's
                // surface view is fully initialized
                DispatchQueue.main.async {
                    guard let surfaceView = controller.focusedSurface else {
                        Self.logger.warning("IPC: no surface view for split")
                        return
                    }

                    var splitConfig = Ghostty.SurfaceConfiguration()
                    if let splitCommand = parsed.splitCommand {
                        splitConfig.command = splitCommand
                    }

                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyNewSplit,
                        object: surfaceView,
                        userInfo: [
                            "direction": direction,
                            Ghostty.Notification.NewSurfaceConfigKey: splitConfig,
                        ]
                    )
                }
            }
        }

        return .ok
    }

    private static func parseSplitDirection(_ value: String) -> ghostty_action_split_direction_e? {
        switch value.lowercased() {
        case "right": return GHOSTTY_SPLIT_DIRECTION_RIGHT
        case "down": return GHOSTTY_SPLIT_DIRECTION_DOWN
        case "left": return GHOSTTY_SPLIT_DIRECTION_LEFT
        case "up": return GHOSTTY_SPLIT_DIRECTION_UP
        default: return nil
        }
    }

    private func parseArguments(_ arguments: [String]) -> ParsedArguments {
        var result = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        var eFlag = false
        var commandParts: [String] = []

        for arg in arguments {
            if eFlag {
                commandParts.append(arg)
                continue
            }

            if arg == "-e" {
                eFlag = true
                continue
            }

            if let value = arg.dropPrefix("--working-directory=") {
                result.config.workingDirectory = String(value)
                continue
            }

            if let value = arg.dropPrefix("--command=") {
                result.config.command = String(value)
                continue
            }

            if let value = arg.dropPrefix("--split=") {
                result.splitDirection = String(value)
                continue
            }

            if let value = arg.dropPrefix("--split-command=") {
                result.splitCommand = String(value)
                continue
            }
        }

        if !commandParts.isEmpty {
            result.config.command = commandParts.joined(separator: " ")
        }

        return result
    }
}

private extension StringProtocol {
    func dropPrefix(_ prefix: String) -> SubSequence? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
    }
}
