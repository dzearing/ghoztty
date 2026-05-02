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
    private var targetRegistry: [String: TargetEntry] = [:]

    private enum TargetEntry {
        case window(WeakRef<TerminalController>)
        case pane(controller: WeakRef<TerminalController>, surface: WeakRef<Ghostty.SurfaceView>)

        var controller: TerminalController? {
            switch self {
            case .window(let ref): return ref.value
            case .pane(let ref, _): return ref.value
            }
        }

        var surfaceView: Ghostty.SurfaceView? {
            switch self {
            case .window(let ref): return ref.value?.focusedSurface
            case .pane(_, let ref): return ref.value
            }
        }

        var isAlive: Bool {
            switch self {
            case .window(let ref): return ref.value != nil
            case .pane(_, let ref): return ref.value != nil
            }
        }
    }

    private class WeakRef<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        let uid = getuid()
        let suffix = Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG
            || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE
            ? "-debug" : ""
        self.socketPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostty\(suffix)-\(uid).sock").path
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
        case "split":
            return handleSplit(request)
        case "close":
            return handleClose(request)
        default:
            return IPCResponse(success: false, error: "unknown action: \(request.action)")
        }
    }

    struct ParsedArguments {
        var config: Ghostty.SurfaceConfiguration
        var splitDirection: String?
        var splitCommand: String?
        var target: String?
        var name: String?
        var title: String?
    }

    private func handleNewWindow(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        // Idempotent: if target exists and window is alive, focus it
        if let target = parsed.target {
            pruneStaleTargets()
            if let entry = targetRegistry[target], let controller = entry.controller {
                DispatchQueue.main.async {
                    controller.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                return .ok
            }
        }

        DispatchQueue.main.async { [ghostty = self.ghostty, weak self] in
            let controller = TerminalController.newWindow(ghostty, withBaseConfig: parsed.config)

            if let title = parsed.title {
                controller.titleOverride = title
            }

            if let target = parsed.target {
                self?.targetRegistry[target] = .window(WeakRef(controller))
                Self.logger.info("IPC: registered window target '\(target)'")
            }

            if let splitDir = parsed.splitDirection,
               let direction = Self.parseSplitDirection(splitDir) {
                DispatchQueue.main.async { [weak self] in
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

                    if let name = parsed.name, let newSurface = controller.focusedSurface {
                        self?.targetRegistry[name] = .pane(
                            controller: WeakRef(controller),
                            surface: WeakRef(newSurface)
                        )
                        Self.logger.info("IPC: registered pane target '\(name)'")
                    }
                }
            }
        }

        return .ok
    }

    private func handleSplit(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        // Idempotent: if --name exists and pane is alive, focus it
        if let name = parsed.name {
            pruneStaleTargets()
            if let entry = targetRegistry[name], let surface = entry.surfaceView {
                DispatchQueue.main.async {
                    if let controller = entry.controller {
                        controller.focusSurface(surface)
                    }
                }
                return .ok
            }
        }

        let directionStr = parsed.splitDirection ?? "right"
        guard let direction = Self.parseSplitDirection(directionStr) else {
            return IPCResponse(success: false, error: "invalid direction: \(directionStr)")
        }

        DispatchQueue.main.async { [weak self] in
            let controller: TerminalController?
            if let target = parsed.target {
                self?.pruneStaleTargets()
                controller = self?.targetRegistry[target]?.controller
                if controller == nil {
                    Self.logger.warning("IPC: target '\(target)' not found")
                }
            } else {
                controller = TerminalController.preferredParent
            }

            guard let controller else {
                Self.logger.warning("IPC: no controller found for split")
                return
            }

            guard let surfaceView = controller.focusedSurface else {
                Self.logger.warning("IPC: no focused surface for split")
                return
            }

            var splitConfig = Ghostty.SurfaceConfiguration()
            if let splitCommand = parsed.splitCommand {
                splitConfig.command = splitCommand
            }
            if let command = parsed.config.command {
                splitConfig.command = command
            }
            if let workingDirectory = parsed.config.workingDirectory {
                splitConfig.workingDirectory = workingDirectory
            }

            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyNewSplit,
                object: surfaceView,
                userInfo: [
                    "direction": direction,
                    Ghostty.Notification.NewSurfaceConfigKey: splitConfig,
                ]
            )

            // Register pane name after split creation
            if let name = parsed.name, let newSurface = controller.focusedSurface {
                self?.targetRegistry[name] = .pane(
                    controller: WeakRef(controller),
                    surface: WeakRef(newSurface)
                )
                Self.logger.info("IPC: registered pane target '\(name)'")
            }
        }

        return .ok
    }

    private func handleClose(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let target = parsed.target else {
            return IPCResponse(success: false, error: "--target is required for +close")
        }

        pruneStaleTargets()

        guard let entry = targetRegistry[target] else {
            // Idempotent: already gone
            return .ok
        }

        DispatchQueue.main.async { [weak self] in
            switch entry {
            case .pane(let controllerRef, let surfaceRef):
                if let controller = controllerRef.value, let surface = surfaceRef.value {
                    controller.closeSurface(surface, withConfirmation: false)
                }
            case .window(let controllerRef):
                controllerRef.value?.closeWindowImmediately()
            }
            self?.targetRegistry.removeValue(forKey: target)
        }

        return .ok
    }

    private func pruneStaleTargets() {
        targetRegistry = targetRegistry.filter { $0.value.isAlive }
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

            if let value = arg.dropPrefix("--target=") {
                result.target = String(value)
                continue
            }

            if let value = arg.dropPrefix("--direction=") {
                result.splitDirection = String(value)
                continue
            }

            if let value = arg.dropPrefix("--name=") {
                result.name = String(value)
                continue
            }

            if let value = arg.dropPrefix("--title=") {
                result.title = String(value)
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
