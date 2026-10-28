import Cocoa
import Darwin
import GhosttyKit
import OSLog
import SwiftUI

class IPCServer {
    private static let logger = Logger(
        subsystem: Bundle.loggerSubsystem,
        category: String(describing: IPCServer.self)
    )

    private let ghostty: Ghostty.App
    private let socketPath: String
    private var listenSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var sentinelSource: DispatchSourceFileSystemObject?
    private var sentinelDirFd: Int32 = -1
    private let queue = DispatchQueue(label: "com.dzearing.ghoztty.ipc", qos: .utility)
    /// Names → what they name. A window name is global (one window holds
    /// it); a pane name belongs to its window, so one name can list a pane in
    /// each of several windows (`TargetLookup`). Main thread only.
    private var targetRegistry: [String: [TargetEntry]] = [:]

    private enum TargetEntry {
        case window(WeakRef<TerminalController>)
        case pane(controller: WeakRef<TerminalController>, surface: WeakRef<Ghostty.SurfaceView>)
        case viewerPane(controller: WeakRef<TerminalController>, pane: WeakRef<PaneView>)

        var controller: TerminalController? {
            switch self {
            case .window(let ref): return ref.value
            case .pane(let ref, _): return ref.value
            case .viewerPane(let ref, _): return ref.value
            }
        }

        var surfaceView: Ghostty.SurfaceView? {
            switch self {
            case .window(let ref): return ref.value?.focusedSurface
            case .pane(_, let ref): return ref.value
            case .viewerPane: return nil
            }
        }

        /// The viewer pane wrapper, when this target is a viewer pane.
        var viewerPaneView: PaneView? {
            switch self {
            case .viewerPane(_, let ref): return ref.value
            default: return nil
            }
        }

        var isAlive: Bool {
            switch self {
            case .window(let ref): return ref.value != nil
            case .pane(_, let ref): return ref.value != nil
            case .viewerPane(_, let ref): return ref.value != nil
            }
        }

        /// The window, surface, or viewer pane this entry names.
        var object: AnyObject? {
            switch self {
            case .window(let ref): return ref.value
            case .pane(_, let ref): return ref.value
            case .viewerPane(_, let ref): return ref.value
            }
        }

        var isWindow: Bool {
            if case .window = self { return true }
            return false
        }

        /// The same pane, in `controller` — where it lives NOW, which a pane
        /// moved between windows has changed since it was registered.
        func moved(to controller: TerminalController) -> TargetEntry {
            switch self {
            case .window: return self
            case .pane(_, let surface): return .pane(controller: WeakRef(controller), surface: surface)
            case .viewerPane(_, let pane): return .viewerPane(controller: WeakRef(controller), pane: pane)
            }
        }

        /// Whether this entry names `pane`: a terminal by the surface it
        /// wraps, a viewer by identity. A collected weak ref names nothing —
        /// without that guard a viewer pane (`surfaceView` nil) matches every
        /// dead terminal entry.
        func names(_ pane: PaneView) -> Bool {
            switch self {
            case .window: return false
            case .pane(_, let ref): return ref.value != nil && ref.value === pane.surfaceView
            case .viewerPane(_, let ref): return ref.value === pane
            }
        }
    }

    private class WeakRef<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        // Single source of truth for this build's socket address — the same
        // value every pane's env advertises as GHOZTTY_IPC_SOCKET, so a CLI
        // run inside a pane dials the app that owns it.
        self.socketPath = IPCSocket.path
    }

    private var sentinelPath: String {
        socketPath + ".reset"
    }

    func start() {
        queue.async { [weak self] in
            self?.bindAndListen()
            self?.startSentinelMonitor()
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            sentinelSource?.cancel()
            sentinelSource = nil
            sentinelDirFd = -1
            if listenSocket >= 0 {
                Darwin.close(listenSocket)
                listenSocket = -1
            }
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

    // MARK: - Sentinel file monitoring

    private func startSentinelMonitor() {
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        sentinelDirFd = Darwin.open(dirPath, O_EVTONLY)
        guard sentinelDirFd >= 0 else {
            Self.logger.warning("IPC: failed to open directory for sentinel monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: sentinelDirFd,
            eventMask: .write,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.checkSentinel()
        }
        source.setCancelHandler { [dirFd = sentinelDirFd] in
            if dirFd >= 0 {
                Darwin.close(dirFd)
            }
        }
        sentinelSource = source
        source.resume()
    }

    private var isResetting = false

    private func checkSentinel() {
        guard FileManager.default.fileExists(atPath: sentinelPath) else { return }
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }

        Self.logger.info("IPC: sentinel file detected, resetting socket")

        // Tear down old listener
        acceptSource?.cancel()
        acceptSource = nil
        let oldFd = listenSocket
        listenSocket = -1
        if oldFd >= 0 {
            Darwin.close(oldFd)
        }

        // Rebind the socket
        bindAndListen()

        // Only remove sentinel if rebind succeeded
        if listenSocket >= 0 {
            unlink(sentinelPath)
            Self.logger.info("IPC: socket reset complete, sentinel removed")
        } else {
            Self.logger.error("IPC: socket rebind failed, sentinel retained")
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
        let response = dispatch(request)
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

    func dispatchPendingJson(_ json: String) {
        guard let data = json.data(using: .utf8) else {
            Self.logger.warning("IPC: pending JSON is not valid UTF-8")
            return
        }

        let request: IPCRequest
        do {
            request = try JSONDecoder().decode(IPCRequest.self, from: data)
        } catch {
            Self.logger.warning("IPC: pending JSON is malformed: \(error)")
            return
        }

        Self.logger.info("IPC: processing pending action '\(request.action)'")
        // On the IPC queue, like a socket request: handlers wait on work they
        // hand to the main thread (`+split` waits for its pane), so running
        // one ON main would wait on itself.
        queue.async { [weak self] in _ = self?.dispatch(request) }
    }

    func dispatch(_ request: IPCRequest) -> IPCResponse {
        let request = IPCRequest(action: request.action, arguments: request.resolvedArguments)
        switch request.action {
        case "new-window":
            return handleNewWindow(request)
        case "split":
            return handleSplit(request)
        case "close":
            return handleClose(request)
        case "rename":
            return handleRename(request)
        case "rearrange":
            return handleRearrange(request)
        case "list":
            return handleList()
        case "read":
            return handleRead(request)
        case "send-keys":
            return handleSendKeys(request)
        case "set-state":
            return handleSetState(request)
        case "set-banner":
            return handleSetBanner(request)
        case "reload":
            return handleReload(request)
        case "stash":
            return handleStash(request, restore: false)
        case "restore":
            return handleStash(request, restore: true)
        case "new-remote-window":
            return handleNewRemoteWindow(request)
        default:
            return IPCResponse(success: false, error: "unknown action: \(request.action)")
        }
    }

    struct ParsedArguments {
        var config: Ghostty.SurfaceConfiguration
        var splitDirection: String?
        var splitCommand: String?
        var splitColor: String?
        var target: String?
        var name: String?
        var title: String?
        var percent: Int?
        var pane: String?
        var color: String?
        var layout: String?
        var lines: Int?
        var shell: String?
        var state: String?
        /// Whether this command may take focus (`--focus`). Background by
        /// default — see `IPCFocusPolicy`.
        var focus: IPCFocusPolicy = .background
        // A path or http(s) URL to open as a viewer pane instead of a terminal
        // (mutually exclusive with command/-e).
        var view: String?
        // The pane the command was invoked FROM: `$GHOZTTY_PANE_ID`, forwarded
        // by the CLI as `--caller-pane=`. A DEFAULT anchor only — see
        // `callerAnchorPane`.
        var callerPane: String?
        // When true, `+new-window` mirrors the keyboard/menu "New Window" action:
        // it resolves the focused/preferred window as the parent and inherits its
        // REMOTE host + command + cwd (§WP4). Lets the inheriting path be driven
        // headlessly (the normal IPC path has no parent and never inherits).
        var fromFocused: Bool = false
    }

    private func handleNewWindow(_ request: IPCRequest) -> IPCResponse {
        var parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        // Wrap IPC commands in the user's shell so aliases and PATH are available
        if let command = parsed.config.command {
            parsed.config.command = wrapCommandInShell(command, shell: parsed.shell)
        }
        if let splitCommand = parsed.splitCommand {
            parsed.splitCommand = wrapCommandInShell(splitCommand, shell: parsed.shell)
        }

        // A viewer window has no command; reject the ambiguous combination.
        if parsed.view != nil, parsed.config.command != nil {
            return IPCResponse(success: false, error: "--view cannot be combined with --command/-e")
        }

        // Idempotent: if target exists and window is alive, it is the
        // answer. Raising it is the caller's choice (`--focus`); by default
        // finding it is a no-op, like every other programmatic path.
        //
        // Window names are global, and a pane's name is never a window's
        // (see `SplitNameCollision`): a `--target` a pane holds fails, rather
        // than "succeeding" without opening the window that was asked for.
        if let target = parsed.target {
            pruneStaleTargets()
            switch lookup(target, from: nil) {
            case .found(let entry) where entry.isWindow && entry.controller != nil:
                if parsed.focus.raisesWindow {
                    DispatchQueue.main.async { _ = Self.bringForward(entry) }
                }
                return .ok
            case .found, .ambiguous:
                return IPCResponse(
                    success: false,
                    error: "'\(target)' is already the name of a pane, so no window can take it. Use another --target.")
            case .notFound:
                break
            }
        }

        // T968: `--name` names a PANE (the first one, or the inline split's)
        // and is idempotent the way `+split --name` is: a live pane already
        // under that name is the answer rather than a second window opened.
        // `--target` decided first above, so this only answers when the
        // caller named no window.
        if parsed.target == nil, let name = parsed.name {
            pruneStaleTargets()
            if let entry = resolveTarget(name), entry.controller != nil {
                if parsed.focus.raisesWindow {
                    DispatchQueue.main.async { _ = Self.bringForward(entry) }
                }
                return .ok
            }
        }

        // T968: without `--split`, `--name` names the window's FIRST pane (the
        // pane this verb creates); with one it names the inline split pane.
        // Same rule as the win32 frontend's `newWindowFirstPaneName`.
        let firstPaneName: String? = parsed.splitDirection == nil
            ? parsed.name.flatMap { $0.isEmpty ? nil : $0 }
            : nil

        // Inject window/pane name env vars for the main surface
        if let target = parsed.target {
            parsed.config.environmentVariables["GHOZTTY_WINDOW_NAME"] = target
        }
        if let paneName = firstPaneName ?? parsed.target {
            parsed.config.environmentVariables["GHOZTTY_PANE_NAME"] = paneName
        }

        // Validate percent if provided
        let ratio: Double
        if let percent = parsed.percent {
            guard (1...99).contains(percent) else {
                return IPCResponse(success: false, error: "percent must be between 1 and 99, got \(percent)")
            }
            ratio = min(0.9, max(0.1, Double(100 - percent) / 100.0))
        } else {
            ratio = 0.5
        }

        // Convert color strings to Color values
        var config = parsed.config
        if let colorStr = parsed.color {
            if colorStr == "random", ghostty.config.macosPaneStyle == .elevated {
                // Elevated panes sit on the window's gradient: a random color
                // is a random GRADIENT — tones from the same ocean family —
                // and the terminals keep their theme. (An explicit hex is
                // still a terminal tint, as is `random` in the flat style.)
                config.deskVariant = .random()
            } else {
                let nsColor: NSColor? = colorStr == "random"
                    ? Self.randomDarkColor()
                    : NSColor(hex: colorStr)
                if let nsColor {
                    config.backgroundTint = Color(nsColor)
                    config.backgroundTintNSColor = nsColor
                }
            }
        }

        // `--from-focused`: mirror the keyboard/menu "New Window" action so the
        // new window inherits the focused window's REMOTE host + command + cwd
        // (§WP4). This is the only IPC path that resolves a parent; it builds the
        // window asynchronously (off-main cwd query) so we can't return its
        // controller for naming/registry — `--from-focused` is for the inheriting
        // case, not for `--target`/`--name` registration.
        if parsed.fromFocused {
            DispatchQueue.main.async { [ghostty = self.ghostty] in
                TerminalController.newWindowInheritingRemote(
                    ghostty,
                    withBaseConfig: config,
                    from: TerminalController.preferredParent?.window,
                    activate: parsed.focus.raisesWindow)
            }
            return .ok
        }

        // Viewer window: a one-pane tree whose leaf renders the file/URL.
        if let viewLocation = parsed.view {
            DispatchQueue.main.async { [ghostty = self.ghostty, weak self] in
                let pane = PaneView(viewer: ViewerView(
                    location: viewLocation,
                    originDirectory: parsed.config.workingDirectory))
                let controller = TerminalController.newWindow(
                    ghostty,
                    tree: SplitTree<PaneView>(view: pane),
                    activate: parsed.focus.raisesWindow)
                if parsed.focus.activatesApp {
                    NSApp.activate(ignoringOtherApps: true)
                }
                // Window titles track the focused *surface*; a viewer-only
                // window has none, so pin the viewer's title unless the
                // caller chose one.
                controller.titleOverride = parsed.title ?? pane.title
                if let target = parsed.target {
                    // Also adopt the target as the controller's window name so
                    // +list doesn't mint a second "window-N" alias (terminal
                    // windows get this via the GHOZTTY_WINDOW_NAME env var).
                    controller.windowName = target
                    self?.register(target, .window(WeakRef(controller)))
                    Self.logger.info("IPC: registered window target '\(target)'")
                }
                if let name = parsed.name {
                    self?.register(name, .viewerPane(
                        controller: WeakRef(controller),
                        pane: WeakRef(pane)))
                }
            }
            return .ok
        }

        let windowTint: Color? = config.backgroundTint
        DispatchQueue.main.async { [ghostty = self.ghostty, weak self] in
            let controller = TerminalController.newWindow(ghostty, withBaseConfig: config, activate: parsed.focus.raisesWindow)

            if let title = parsed.title, !title.isEmpty {
                // A CLI-set title is a WINDOW title: it pins the titlebar
                // and survives pane focus/title changes.
                controller.setWindowTitle(title)
            }

            // Apply color scheme after the surface has initialized
            if windowTint != nil {
                DispatchQueue.main.async {
                    if let surface = controller.focusedSurface {
                        Self.applyColorScheme(for: windowTint, to: surface)
                    }
                }
            }

            if let target = parsed.target {
                self?.register(target, .window(WeakRef(controller)))
                Self.logger.info("IPC: registered window target '\(target)'")
            }

            if let firstPaneName {
                // Same hop the inline split below takes: the first surface is
                // the controller's focused one once the window has settled.
                DispatchQueue.main.async { [weak self] in
                    guard let surfaceView = controller.focusedSurface else {
                        Self.logger.warning("IPC: no surface view to name '\(firstPaneName)'")
                        return
                    }
                    self?.register(firstPaneName, .pane(
                        controller: WeakRef(controller),
                        surface: WeakRef(surfaceView)
                    ))
                    Self.logger.info("IPC: registered pane target '\(firstPaneName)'")
                }
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

                    // Inject window/pane name env vars for the inline split
                    if let target = parsed.target {
                        splitConfig.environmentVariables["GHOZTTY_WINDOW_NAME"] = target
                    }
                    if let name = parsed.name {
                        splitConfig.environmentVariables["GHOZTTY_PANE_NAME"] = name
                    }

                    let splitTint: Color?
                    let splitNSColor: NSColor? = parsed.splitColor.flatMap {
                        $0 == "random" ? Self.randomDarkColor() : NSColor(hex: $0)
                    }
                    if let nsColor = splitNSColor {
                        splitConfig.backgroundTint = Color(nsColor)
                        splitConfig.backgroundTintNSColor = nsColor
                        splitTint = Color(nsColor)
                    } else {
                        splitTint = nil
                    }

                    let newView = controller.newSplit(
                        at: surfaceView,
                        direction: direction,
                        baseConfig: splitConfig,
                        ratio: ratio,
                        focus: parsed.focus.movesKeyboardFocus
                    ) { newView in
                        Self.presentIfAsked(
                            controller.surfaceTree.pane(for: newView), in: controller, parsed.focus)
                    }

                    if let newView {
                        Self.applyColorScheme(for: splitTint, to: newView)
                    }

                    if let name = parsed.name, let newView {
                        self?.register(name, .pane(
                            controller: WeakRef(controller),
                            surface: WeakRef(newView)))
                        Self.logger.info("IPC: registered pane target '\(name)'")
                    }
                }
            }
        }

        return .ok
    }

    private func handleSplit(_ request: IPCRequest) -> IPCResponse {
        var parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        // A viewer pane has no command; reject the ambiguous combination.
        if parsed.view != nil, parsed.config.command != nil {
            return IPCResponse(success: false, error: "--view cannot be combined with --command/-e")
        }

        // Wrap IPC commands in the user's shell so aliases and PATH are available
        if let command = parsed.config.command {
            parsed.config.command = wrapCommandInShell(command, shell: parsed.shell)
        }
        if let splitCommand = parsed.splitCommand {
            parsed.splitCommand = wrapCommandInShell(splitCommand, shell: parsed.shell)
        }

        // `--from-focused` is the inheriting split (see `splitAnchor`); it
        // takes no name.
        if parsed.fromFocused { parsed.name = nil }

        let tint: NSColor? = parsed.color.flatMap {
            $0 == "random" ? Self.randomDarkColor() : NSColor(hex: $0)
        }

        // Validate percent if provided
        let ratio: Double
        if let percent = parsed.percent {
            guard (1...99).contains(percent) else {
                return IPCResponse(success: false, error: "percent must be between 1 and 99, got \(percent)")
            }
            ratio = min(0.9, max(0.1, Double(100 - percent) / 100.0))
        } else {
            ratio = 0.5
        }

        let directionStr = parsed.splitDirection ?? "right"
        guard let direction = Self.parseSplitDirection(directionStr) else {
            return IPCResponse(success: false, error: "invalid direction: \(directionStr)")
        }

        // Where the pane goes, resolved now, so a missing one fails the
        // command and the reply can name the window.
        pruneStaleTargets()
        let anchor: SplitAnchor
        switch splitAnchor(parsed) {
        case .success(let found): anchor = found
        case .failure(let failure):
            Self.logSplit(parsed, anchor: nil, outcome: "failed: \(failure.message)")
            return IPCResponse(success: false, error: failure.message)
        }

        // Idempotent: if --name is already held in THIS window and is what
        // was asked for, it is the answer — and the reply says so. A request
        // it does not satisfy fails instead (see `SplitNameCollision`). A
        // pane of that name in another window does not count: pane names
        // belong to their window. Focusing a reused pane is the caller's
        // choice (`--focus`), as for `+new-window --target=`.
        if let name = parsed.name, let (entry, existing) = existingHolder(of: name, in: anchor.controller) {
            switch SplitNameCollision.decide(name: name, existing: existing, requestedView: parsed.view) {
            case .conflict(let error):
                Self.logSplit(parsed, anchor: anchor, outcome: "name collision: \(error)")
                return IPCResponse(success: false, error: error)
            case .reuse(let message):
                Self.logSplit(parsed, anchor: anchor, outcome: "reused: \(message)")
                if parsed.focus.movesKeyboardFocus {
                    DispatchQueue.main.async { _ = Self.bringForward(entry) }
                }
                return IPCResponse(success: true, message: message)
            }
        }

        // Split, and reply with what actually happened. The reply used to be
        // sent first ("created …") and the split run afterwards, where a
        // failure only logged — so an agent reported a side pane that never
        // opened. Now the reply waits (bounded) for the pane to exist and be
        // laid out, and says whether it is on show.
        let reply = SplitReply()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    reply.finish(.failure(SplitFailure("the IPC server is no longer available")))
                    return
                }
                self.performSplit(parsed, at: anchor, direction: direction, ratio: ratio, tint: tint) { result in
                    switch result {
                    case .failure(let failure):
                        reply.finish(.failure(failure))
                    case .success(let pane):
                        if let name = parsed.name {
                            if let surface = pane.surfaceView {
                                self.register(name, .pane(controller: WeakRef(anchor.controller), surface: WeakRef(surface)))
                            } else {
                                self.register(name, .viewerPane(controller: WeakRef(anchor.controller), pane: WeakRef(pane)))
                            }
                        }
                        Self.presentIfAsked(pane, in: anchor.controller, parsed.focus)
                        Self.whenLaidOut(pane, in: anchor.controller, deadline: .now() + 1) { onShow in
                            reply.finish(.success(SplitCreated(
                                paneID: pane.id, windowName: anchor.controller.windowName, onShow: onShow)))
                        }
                    }
                }
            }
        }

        switch reply.wait(timeout: Self.splitTimeout) {
        case nil:
            let error = "the split in window '\(anchor.windowName)' did not finish within "
                + "\(Int(Self.splitTimeout))s; it may still appear (check `ghoztty +list`)"
            Self.logSplit(parsed, anchor: anchor, outcome: "timed out")
            return IPCResponse(success: false, error: error)
        case .failure(let failure)?:
            Self.logSplit(parsed, anchor: anchor, outcome: "failed: \(failure.message)")
            return IPCResponse(success: false, error: failure.message)
        case .success(let created)?:
            let message = Self.createdMessage(parsed, created)
            Self.logSplit(
                parsed, anchor: anchor,
                outcome: "created \(created.paneID.uuidString)",
                onShow: created.onShow)
            return IPCResponse(success: true, message: message)
        }
    }

    /// How long `+split` waits for its pane. A local split is synchronous; an
    /// agent-backed one (session persistence, a remote machine) first asks
    /// the agent for the parent's cwd, normally a few milliseconds.
    private static let splitTimeout: TimeInterval = 10

    /// Where a `+split` lands: the window, the pane it splits beside, and the
    /// window's name for messages.
    private struct SplitAnchor {
        let controller: TerminalController
        let pane: PaneView
        let windowName: String
    }

    struct SplitFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// A pane a `+split` created.
    struct SplitCreated {
        let paneID: UUID
        let windowName: String
        /// Whether it is on show, as laid out; nil when the window had not
        /// laid it out within the wait (a window that is not on screen).
        let onShow: Bool?
    }

    /// The result of a split, handed from the main thread to the IPC thread
    /// waiting on it.
    private final class SplitReply {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var result: Result<SplitCreated, SplitFailure>?

        func finish(_ result: Result<SplitCreated, SplitFailure>) {
            lock.lock()
            defer { lock.unlock() }
            guard self.result == nil else { return }
            self.result = result
            done.signal()
        }

        func wait(timeout: TimeInterval) -> Result<SplitCreated, SplitFailure>? {
            _ = done.wait(timeout: .now() + timeout)
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    /// The window and pane a `+split` splits, resolved when the command is
    /// handled:
    ///
    ///   * `--from-focused`: the focused window's focused pane — the split a
    ///     Cmd-D would make.
    ///   * `--pane`, or the calling pane (`callerAnchorPane`): that pane.
    ///   * `--target`: that window's focused pane. The window's focused pane
    ///     may be a VIEWER, which has no SurfaceView, so this anchors on the
    ///     PANE; and a window that is not key has no live first responder, so
    ///     it falls back to the tree's first pane rather than to whichever
    ///     window the user happens to be looking at.
    ///   * nothing: the focused window, the same way.
    private func splitAnchor(_ parsed: ParsedArguments) -> Result<SplitAnchor, SplitFailure> {
        if parsed.fromFocused {
            return Self.onMain {
                guard let controller = TerminalController.preferredParent else {
                    return .failure(SplitFailure("no focused window to split"))
                }
                guard let pane = controller.focusedSurface.flatMap({ controller.surfaceTree.pane(for: $0) }) else {
                    return .failure(SplitFailure("the focused window has no focused terminal to split"))
                }
                return .success(SplitAnchor(controller: controller, pane: pane, windowName: controller.windowName))
            }
        }

        // No explicit anchor: split off the pane this command was invoked FROM
        // rather than whatever window is focused by the time we get here.
        if let paneName = parsed.pane ?? callerAnchorPane(parsed) {
            let entry: TargetEntry
            switch lookup(paneName, from: parsed.callerPane) {
            case .found(let found): entry = found
            case .notFound: return .failure(SplitFailure("pane '\(paneName)' not found"))
            case .ambiguous(let error): return .failure(SplitFailure(error))
            }
            return Self.onMain {
                guard let (owner, pane) = Self.paneAndController(for: entry),
                      let controller = owner as? TerminalController else {
                    if entry.isWindow, let controller = entry.controller {
                        return Self.windowAnchor(controller)
                    }
                    return .failure(SplitFailure("pane '\(paneName)' is no longer in a window"))
                }
                return .success(SplitAnchor(controller: controller, pane: pane, windowName: controller.windowName))
            }
        }

        if let target = parsed.target {
            switch lookup(target, from: parsed.callerPane) {
            case .found(let entry):
                guard let controller = entry.controller else {
                    return .failure(SplitFailure("target '\(target)' not found"))
                }
                return Self.onMain { Self.windowAnchor(controller) }
            case .notFound: return .failure(SplitFailure("target '\(target)' not found"))
            case .ambiguous(let error): return .failure(SplitFailure(error))
            }
        }

        return Self.onMain {
            guard let controller = TerminalController.preferredParent else {
                return .failure(SplitFailure("no Ghoztty window to split"))
            }
            return Self.windowAnchor(controller)
        }
    }

    @MainActor
    private static func windowAnchor(_ controller: TerminalController) -> Result<SplitAnchor, SplitFailure> {
        let pane = controller.focusedSurface.flatMap { controller.surfaceTree.pane(for: $0) }
            ?? controller.focusedViewerPane
            ?? controller.surfaceTree.visibleLeaves.first
        guard let pane else {
            return .failure(SplitFailure("window '\(controller.windowName)' has no pane to split"))
        }
        return .success(SplitAnchor(controller: controller, pane: pane, windowName: controller.windowName))
    }

    /// Create the split `parsed` asks for beside `anchor`, and call `finish`
    /// exactly once with the new pane or why there is none — after the
    /// agent's answer, for an agent-backed terminal split.
    @MainActor
    private func performSplit(
        _ parsed: ParsedArguments,
        at anchor: SplitAnchor,
        direction: SplitTree<PaneView>.NewDirection,
        ratio: Double,
        tint: NSColor?,
        finish: @escaping (Result<PaneView, SplitFailure>) -> Void
    ) {
        let controller = anchor.controller
        guard controller.surfaceTree.root?.node(view: anchor.pane) != nil else {
            finish(.failure(SplitFailure("the pane to split beside left window '\(anchor.windowName)' before the split")))
            return
        }
        let insertFailed = SplitFailure("could not insert the new pane into window '\(anchor.windowName)'")

        if let location = parsed.view {
            let viewer = ViewerView(location: location, originDirectory: parsed.config.workingDirectory)
            guard let pane = controller.newViewerSplit(
                atPane: anchor.pane, direction: direction, viewer: viewer, ratio: ratio)
            else { return finish(.failure(insertFailed)) }
            return finish(.success(pane))
        }

        // `--from-focused` passes NO config of its own, so `newSplit` performs
        // the full remote inheritance (connection + parent command + cwd).
        var config = Ghostty.SurfaceConfiguration()
        if !parsed.fromFocused {
            if let splitCommand = parsed.splitCommand { config.command = splitCommand }
            if let command = parsed.config.command { config.command = command }
            if let workingDirectory = parsed.config.workingDirectory { config.workingDirectory = workingDirectory }
            config.backgroundTint = tint.map { Color($0) }
            config.backgroundTintNSColor = tint
            for (key, val) in parsed.config.environmentVariables {
                config.environmentVariables[key] = val
            }
            if let name = parsed.name { config.environmentVariables["GHOZTTY_PANE_NAME"] = name }
        }
        let tintColor = config.backgroundTint

        // Terminal split anchored at a viewer pane: there is no surface to
        // inherit cwd/command from, so build a plain local one.
        guard let surface = anchor.pane.surfaceView else {
            guard let newView = controller.newTerminalSplit(
                atPane: anchor.pane, direction: direction, baseConfig: config, ratio: ratio,
                focus: parsed.focus.movesKeyboardFocus),
                  let pane = controller.surfaceTree.pane(for: newView)
            else { return finish(.failure(insertFailed)) }
            Self.applyColorScheme(for: tintColor, to: newView)
            return finish(.success(pane))
        }

        // An agent-backed split is created ASYNCHRONOUSLY (off-main cwd
        // inheritance) and returns nil here; `onFinish` reports either way.
        controller.newSplit(
            at: surface, direction: direction, baseConfig: config, ratio: ratio,
            focus: parsed.focus.movesKeyboardFocus,
            onFinish: { newView in
                guard let newView, let pane = controller.surfaceTree.pane(for: newView) else {
                    return finish(.failure(insertFailed))
                }
                if !parsed.fromFocused { Self.applyColorScheme(for: tintColor, to: newView) }
                finish(.success(pane))
            })
    }

    /// Call `body` once `pane` has been laid out in its window, with whether
    /// it is on show (false: a strip in a row with no room for it), or nil if
    /// that had not happened by `deadline` (a window that is not on screen).
    @MainActor
    private static func whenLaidOut(
        _ pane: PaneView,
        in controller: TerminalController,
        deadline: DispatchTime,
        _ body: @escaping (Bool?) -> Void
    ) {
        let stacks = controller.paneStackState.stacks
        let inAStack = stacks.contains { $0.items.joined().contains(pane.id) }
        if inAStack || pane.contentView.window != nil {
            return body(controller.paneStackState.stackMinimizing(pane.id) == nil)
        }
        guard DispatchTime.now() < deadline else { return body(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            whenLaidOut(pane, in: controller, deadline: deadline, body)
        }
    }

    /// What holds `name` where a `+split --name=` would land in `controller`,
    /// for `SplitNameCollision`: a pane of that name in that window, or a
    /// window of that name anywhere. Nil when the name is free there.
    private func existingHolder(
        of name: String,
        in controller: TerminalController
    ) -> (TargetEntry, SplitNameCollision.Existing)? {
        Self.onMain {
            let entries = (targetRegistry[name] ?? []).filter(\.isAlive)
            if let window = entries.first(where: \.isWindow), let holder = window.controller {
                return (window, .init(kind: .window, windowName: holder.windowName))
            }
            if !entries.contains(where: \.isWindow),
               let holder = TerminalController.all.first(where: { $0.windowName == name }) {
                return (.window(WeakRef(holder)), .init(kind: .window, windowName: holder.windowName))
            }
            guard let entry = entries.first(where: { liveController(of: $0) === controller }) else { return nil }
            let kind: SplitNameCollision.Existing.Kind
            switch entry {
            case .window:
                kind = .window
            case .pane:
                kind = .terminal
            case .viewerPane(_, let ref):
                guard let viewer = ref.value?.viewerView else { return nil }
                kind = .viewer(location: viewer.location, homeLocation: viewer.homeLocation)
            }
            return (entry.moved(to: controller), .init(kind: kind, windowName: controller.windowName))
        }
    }

    /// The reply to a `+split` that creates a pane: which pane, where, and —
    /// when it did not come on show — that it is a strip.
    static func createdMessage(_ parsed: ParsedArguments, _ created: SplitCreated) -> String {
        var message = parsed.name.map { "created pane '\($0)' (\(created.paneID.uuidString))" }
            ?? "created pane \(created.paneID.uuidString)"
        message += " in window '\(created.windowName)'"
        if let view = parsed.view { message += ", showing \(view)" }
        if created.onShow == false {
            message += "; it is minimized to a strip, since its row has no room for it on show"
        }
        return message
    }

    /// Every `+split`, persisted (`.notice`) so the next unexplained "I opened
    /// it in a side pane" can be read back with `/usr/bin/log show
    /// --predicate 'category == "IPCServer"'`.
    private static func logSplit(
        _ parsed: ParsedArguments,
        anchor: SplitAnchor?,
        outcome: String,
        onShow: Bool? = nil
    ) {
        let caller = parsed.callerPane ?? "-"
        let window = anchor?.windowName ?? "-"
        let pane = anchor?.pane.id.uuidString ?? "-"
        let name = parsed.name ?? "-"
        let view = parsed.view ?? "-"
        let shown = onShow.map { $0 ? "yes" : "NO (strip)" } ?? "unknown"
        logger.notice("""
            IPC +split: caller=\(caller, privacy: .public) window=\(window, privacy: .public) \
            anchor=\(pane, privacy: .public) name=\(name, privacy: .public) view=\(view, privacy: .public) \
            outcome=\(outcome, privacy: .public) onShow=\(shown, privacy: .public)
            """)
    }

    /// Run `body` on the main thread and return its result, from the IPC
    /// queue or from main itself.
    private static func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
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

        // The caller's own pane of that name first: `+close --target=draft`
        // from one window used to close another window's `draft`.
        let entry: TargetEntry
        switch lookup(target, from: parsed.callerPane) {
        case .found(let found): entry = found
        case .notFound: return .ok // Idempotent: already gone
        case .ambiguous(let error): return IPCResponse(success: false, error: error)
        }

        DispatchQueue.main.async { [weak self] in
            switch entry {
            case .pane(let controllerRef, let surfaceRef):
                if let controller = controllerRef.value, let surface = surfaceRef.value {
                    controller.closeSurface(surface, withConfirmation: false)
                }
            case .viewerPane(let controllerRef, let paneRef):
                if let controller = controllerRef.value, let pane = paneRef.value,
                   let node = controller.surfaceTree.root?.node(view: pane) {
                    // Viewers never have a running process; close silently.
                    controller.closeSurface(node, withConfirmation: false)
                }
            case .window(let controllerRef):
                controllerRef.value?.closeWindowImmediately()
            }
            self?.unregister(target, entry)
        }

        return .ok
    }

    private func handleRename(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let target = parsed.target else {
            return IPCResponse(success: false, error: "--target is required for +rename")
        }

        guard let newTitle = parsed.title else {
            return IPCResponse(success: false, error: "--title is required for +rename")
        }

        pruneStaleTargets()

        let entry: TargetEntry
        switch resolve(target, from: parsed.callerPane, missing: "target '\(target)' not found in registry") {
        case .entry(let found): entry = found
        case .failure(let response): return response
        }

        guard let controller = entry.controller else {
            return IPCResponse(success: false, error: "target '\(target)' is no longer alive")
        }

        // A title the user typed outranks any script's: leave it, and say
        // so (the skills that tag a title — `(prep)`, `(ready)` — ignore a
        // failed rename). Checked and set in one main-thread turn, so a
        // user rename can't land between them.
        let kept: String? = Self.onMain {
            guard controller.windowTitleSetByUser else {
                // A CLI rename is a WINDOW title: it pins the titlebar and
                // survives pane focus/title changes. An empty title clears
                // the pin so the titlebar falls back to the tab/pane title.
                controller.setWindowTitle(newTitle.isEmpty ? nil : newTitle)
                return nil
            }
            return controller.effectiveWindowTitleOverride ?? ""
        }
        if let kept {
            return IPCResponse(success: false, error: """
                window '\(target)' was renamed by the user ('\(kept)'); \
                +rename leaves a user's title alone until they clear it
                """)
        }

        Self.logger.info("IPC: renamed display title for '\(target)' to '\(newTitle)'")

        return .ok
    }

    private func handleSetState(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let target = parsed.target else {
            return IPCResponse(success: false, error: "--target is required for +set-state")
        }

        guard let stateStr = parsed.state else {
            return IPCResponse(success: false, error: "--state is required for +set-state")
        }

        let activityState: Ghostty.ActivityState
        switch stateStr {
        case "idle":
            activityState = .idle
        case "busy":
            activityState = .busy
        case "needs_input":
            activityState = .needsInput
        default:
            return IPCResponse(success: false, error: "invalid state '\(stateStr)': must be idle, busy, or needs_input")
        }

        pruneStaleTargets()

        let entry: TargetEntry
        switch resolve(target, from: parsed.callerPane, missing: "target '\(target)' not found in registry") {
        case .entry(let found): entry = found
        case .failure(let response): return response
        }

        guard let controller = entry.controller else {
            return IPCResponse(success: false, error: "target '\(target)' is no longer alive")
        }

        if case .viewerPane = entry {
            return IPCResponse(success: false, error: "target '\(target)' is a viewer pane, not a terminal")
        }

        DispatchQueue.main.async {
            // Set activity state on all surfaces in the window, or just the targeted pane
            switch entry {
            case .pane(_, let surfaceRef):
                if let surface = surfaceRef.value {
                    surface.activityState = activityState
                }
            case .viewerPane:
                break // rejected above
            case .window:
                for pane in controller.surfaceTree {
                    pane.surfaceView?.activityState = activityState
                }
            }
        }

        Self.logger.info("IPC: set activity state for '\(target)' to '\(stateStr)'")

        return .ok
    }

    /// Set or clear the sticky banner of a named pane or window. Banner text
    /// is any non-flag argument (multiple are joined with spaces); `--clear`
    /// or an empty text removes the banner. For a window target the banner
    /// applies to its focused pane (banners are per-pane).
    private func handleSetBanner(_ request: IPCRequest) -> IPCResponse {
        var target: String?
        var callerPane: String?
        var clear = false
        var textParts: [String] = []

        for arg in request.arguments ?? [] {
            if let value = arg.dropPrefix("--target=") {
                target = String(value)
            } else if let value = arg.dropPrefix("--caller-pane=") {
                callerPane = String(value)
            } else if arg == "--clear" {
                clear = true
            } else {
                textParts.append(arg)
            }
        }

        guard let target else {
            return IPCResponse(success: false, error: "--target is required for +set-banner")
        }

        // A literal `\n` in the text becomes a line break so multi-line
        // banners can be set from a single shell argument. Trim so a stray
        // trailing newline doesn't render as a blank line.
        let text = textParts.joined(separator: " ")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { clear = true }

        pruneStaleTargets()

        let entry: TargetEntry
        switch resolve(target, from: callerPane, missing: "target '\(target)' not found in registry") {
        case .entry(let found): entry = found
        case .failure(let response): return response
        }

        if case .viewerPane = entry {
            return IPCResponse(success: false, error: "target '\(target)' is a viewer pane, not a terminal")
        }

        var setError: String?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            defer { semaphore.signal() }

            guard let surface = entry.surfaceView else {
                setError = "target '\(target)' is no longer alive"
                return
            }
            surface.paneBanner = clear ? nil : text
        }
        semaphore.wait()

        if let setError {
            return IPCResponse(success: false, error: setError)
        }

        Self.logger.info("IPC: \(clear ? "cleared" : "set") banner for '\(target)'")

        return .ok
    }

    /// Reload a named viewer pane's content in place (`+reload`). Website
    /// viewers re-fetch from origin (bypassing caches); file viewers
    /// re-render the file preserving scroll. For a window target the reload
    /// applies to its focused pane. A terminal target is an error — there
    /// is nothing to reload.
    /// `+stash` / `+restore`: move a pane out of its window's layout into the
    /// pane sidebar, or back. Both idempotent, like every IPC command, and —
    /// like every one — `+restore` leaves focus alone unless given `--focus`.
    private func handleStash(_ request: IPCRequest, restore: Bool) -> IPCResponse {
        let verb = restore ? "+restore" : "+stash"
        var target: String?
        var callerPane: String?
        var focus = false
        for arg in request.arguments ?? [] {
            if let value = arg.dropPrefix("--target=") {
                target = String(value)
            } else if let value = arg.dropPrefix("--caller-pane=") {
                callerPane = String(value)
            } else if arg == "--focus" || arg == "--focus=true" {
                focus = true
            } else if arg == "--focus=false" {
                focus = false
            }
        }
        guard let target else {
            return IPCResponse(success: false, error: "--target is required for \(verb)")
        }

        pruneStaleTargets()
        let entry: TargetEntry
        switch resolve(target, from: callerPane, missing: "target '\(target)' not found in registry") {
        case .entry(let found): entry = found
        case .failure(let response): return response
        }
        if case .window = entry {
            return IPCResponse(
                success: false,
                error: "target '\(target)' is a window; \(verb) takes a pane (a name or pane id)")
        }

        var failure: String?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            defer { semaphore.signal() }
            MainActor.assumeIsolated {
                guard let (controller, pane) = Self.paneAndController(for: entry) else {
                    failure = "target '\(target)' is no longer alive"
                    return
                }
                guard controller.hasPaneSidebar else {
                    failure = "target '\(target)' is in the Quick Terminal, which has no pane sidebar"
                    return
                }
                if restore {
                    controller.restorePane(pane, focus: false)
                    if focus { controller.revealPane(pane) }
                    return
                }
                // Checked first so a refusal is an error message, not a beep.
                if !controller.surfaceTree.isStashed(pane) {
                    do {
                        _ = try controller.surfaceTree.stashing(pane)
                    } catch SplitTreeStashError.lastVisiblePane {
                        failure = "target '\(target)' is the last pane on screen in its window; "
                            + "a window always shows at least one pane"
                        return
                    } catch {
                        failure = "target '\(target)' is not in its window's layout"
                        return
                    }
                    controller.stashPane(pane)
                }
            }
        }
        semaphore.wait()

        if let failure {
            return IPCResponse(success: false, error: failure)
        }
        Self.logger.info("IPC: \(restore ? "restored" : "stashed") '\(target)'")
        return IPCResponse(success: true)
    }

    /// The pane a target names and the window that holds it NOW — found by
    /// walking the live windows rather than trusting the controller recorded
    /// at registration, which a pane moved between windows has left.
    @MainActor
    private static func paneAndController(for entry: TargetEntry) -> (BaseTerminalController, PaneView)? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            if let pane = controller.surfaceTree.first(where: { entry.names($0) }) {
                return (controller, pane)
            }
        }
        return nil
    }

    private func handleReload(_ request: IPCRequest) -> IPCResponse {
        var target: String?
        var callerPane: String?
        var reloadConfig = false
        for arg in request.arguments ?? [] {
            if let value = arg.dropPrefix("--target=") {
                target = String(value)
            } else if let value = arg.dropPrefix("--caller-pane=") {
                callerPane = String(value)
            } else if arg == "--config" {
                reloadConfig = true
            }
        }

        // `--config` is the app-wide form (T893): re-read the configuration
        // from disk, exactly as the Reload Configuration menu item does. It
        // names no pane, so combining it with `--target` is a mistake about
        // which reload was meant rather than two requests to run.
        if reloadConfig {
            guard target == nil else {
                return IPCResponse(
                    success: false,
                    error: "--config cannot be combined with --target")
            }

            DispatchQueue.main.sync {
                (NSApp.delegate as? AppDelegate)?.reloadConfig(nil)
            }
            Self.logger.info("IPC: reloaded configuration")
            return .ok
        }

        guard let target else {
            return IPCResponse(success: false, error: "--target is required for +reload")
        }

        pruneStaleTargets()

        let entry: TargetEntry
        switch resolve(target, from: callerPane, missing: "target '\(target)' not found in registry") {
        case .entry(let found): entry = found
        case .failure(let response): return response
        }

        var reloadError: String?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            defer { semaphore.signal() }

            let viewer: ViewerView?
            switch entry {
            case .viewerPane(_, let paneRef):
                viewer = paneRef.value?.viewerView
            case .pane:
                reloadError = "target '\(target)' is a terminal pane, nothing to reload"
                return
            case .window(let ref):
                guard let controller = ref.value else {
                    reloadError = "target '\(target)' is no longer alive"
                    return
                }
                let panes = Array(controller.surfaceTree)
                if let pane = controller.focusedViewerPane {
                    viewer = pane.viewerView
                } else if controller.focusedSurface == nil,
                          panes.count == 1, panes.first?.viewerView != nil {
                    // A never-focused window (e.g. a background IPC window) has
                    // no first responder; a lone viewer pane is unambiguous.
                    viewer = panes.first?.viewerView
                } else {
                    reloadError = "focused pane of '\(target)' is a terminal pane, nothing to reload"
                    return
                }
            }

            guard let viewer else {
                reloadError = "target '\(target)' is no longer alive"
                return
            }
            viewer.reloadContent()
        }
        semaphore.wait()

        if let reloadError {
            return IPCResponse(success: false, error: reloadError)
        }

        Self.logger.info("IPC: reloaded viewer '\(target)'")

        return .ok
    }

    /// Open a remote-machine window, dialing the agent at `--host=<h> --port=<p>`.
    ///
    /// This drives the EXACT same code path as the Cmd-Shift-N "New Remote
    /// Window" menu action (`AppDelegate.openRemoteWindow`): the dial + window
    /// open run on the MAIN thread, just like the menu. It exists so the remote
    /// window GUI flow can be triggered headlessly from the shell (macOS blocks
    /// synthesized keystrokes), making it scriptable and test-reproducible.
    ///
    /// We dispatch to main and block this IPC worker on a semaphore so the
    /// reply reflects whether the dial+open succeeded. Note: the dial itself is
    /// synchronous (it completes the handshake) and runs on the main thread —
    /// exactly as the menu does — so this faithfully reproduces any main-thread
    /// stall the menu path would hit.
    private func handleNewRemoteWindow(_ request: IPCRequest) -> IPCResponse {
        guard let arguments = request.arguments else {
            return IPCResponse(success: false, error: "--host and --port are required for +new-remote-window")
        }

        var host: String?
        var port: UInt16?
        var relay: String?
        var device: String?
        var token: String?
        var name: String?
        var workingDirectory: String?
        var shell: String?
        var command: String?
        // Opening in the background is the default here as everywhere; a
        // failed dial still shows its modal alert (that is a report of the
        // command failing, not a window it opened).
        let focus = IPCFocusPolicy.parse(arguments)
        for arg in arguments {
            if let value = arg.dropPrefix("--host=") {
                host = String(value)
            } else if let value = arg.dropPrefix("--port=") {
                port = UInt16(value)
            } else if let value = arg.dropPrefix("--relay=") {
                relay = String(value)
            } else if let value = arg.dropPrefix("--device=") {
                device = String(value)
            } else if let value = arg.dropPrefix("--token=") {
                token = String(value)
            } else if let value = arg.dropPrefix("--name=") {
                name = String(value)
            } else if let value = arg.dropPrefix("--working-directory=") {
                // REMOTE-native cwd/shell/command: forwarded into the agent
                // OPEN. Explicit flags override the machine's per-host
                // defaults (Machine.applyOpenDefaults). Empty values are
                // treated as absent so `--shell=` can't forward "".
                workingDirectory = value.isEmpty ? nil : String(value)
            } else if let value = arg.dropPrefix("--shell=") {
                shell = value.isEmpty ? nil : String(value)
            } else if let value = arg.dropPrefix("--command=") {
                command = value.isEmpty ? nil : String(value)
            }
        }

        // Relay path: --relay + --device dial through a rendezvous relay. Takes
        // precedence over the direct host:port path when both are present.
        let useRelay = (relay?.isEmpty == false) && (device?.isEmpty == false)
        if !useRelay {
            guard host?.isEmpty == false else {
                return IPCResponse(success: false, error: "--host is required (or use --relay + --device) for +new-remote-window")
            }
            guard let port, port != 0 else {
                return IPCResponse(success: false, error: "--port is required (or use --relay + --device) for +new-remote-window")
            }
            _ = port
        }

        var errorMessage: String?
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { semaphore.signal() }
            guard let appDelegate = NSApp.delegate as? AppDelegate else {
                errorMessage = "app delegate unavailable"
                return
            }
            if useRelay {
                // An explicit --token wins; otherwise resolve through the
                // WP-B2 seam (signed-in Google account's ID token, dev env
                // token fallback) — same sourcing as the Cmd-Shift-N dial.
                var resolvedToken = token ?? ""
                if resolvedToken.isEmpty {
                    resolvedToken = await RelayAccount.resolveToken() ?? ""
                }
                // Signed out (and no dev token, no explicit --token): refuse
                // BEFORE dialing — a tokenless relay dial is a guaranteed
                // 401. The CLI gets this as the command's error output; no
                // GUI alert from the IPC path.
                guard !resolvedToken.isEmpty else {
                    errorMessage = "not signed in: sign in via New Remote Window (Cmd-Shift-N) or pass --token= to open relay windows"
                    return
                }
                errorMessage = appDelegate.openRemoteWindow(
                    relay: relay!,
                    device: device!,
                    token: resolvedToken,
                    name: name,
                    // An explicit --name is a caller-supplied label: pin it so
                    // account renames don't overwrite it (Machine.namePinned).
                    namePinned: name != nil,
                    // Persist the registry name in the manifest entry so a
                    // restored window is re-registered under it (the restore
                    // path calls registerRestoredRemoteWindow).
                    ipcName: name,
                    workingDirectory: workingDirectory,
                    shell: shell,
                    command: command,
                    activate: focus.raisesWindow,
                    onOpen: { [weak self] controller in
                        // Register the window under its friendly name so
                        // +send-keys / +read / +close can target it (mirrors the
                        // +new-window --target path). The pill shows the
                        // machine's display name (the caller-supplied --name
                        // here, falling back to the agent-reported hostname);
                        // the registry key stays the --name for scriptability.
                        if let target = name {
                            self?.register(target, .window(WeakRef(controller)))
                            Self.logger.info("IPC: registered remote window target '\(target)'")
                        }
                    })
            } else {
                errorMessage = appDelegate.openRemoteWindow(
                    host: host!,
                    port: port!,
                    name: name,
                    workingDirectory: workingDirectory,
                    shell: shell,
                    command: command,
                    activate: focus.raisesWindow,
                    onOpen: { [weak self] controller in
                        // Same registration as the relay path above: expose
                        // the window under its friendly name so +send-keys /
                        // +read / +close can target TCP remote windows too.
                        if let target = name {
                            self?.register(target, .window(WeakRef(controller)))
                            Self.logger.info("IPC: registered remote window target '\(target)'")
                        }
                    })
            }
        }
        semaphore.wait()

        if let errorMessage {
            return IPCResponse(success: false, error: errorMessage)
        }
        return .ok
    }

    private func handleRead(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let name = parsed.name else {
            return IPCResponse(success: false, error: "--name is required for +read")
        }

        let lineCount = parsed.lines ?? 50

        pruneStaleTargets()

        let entry: TargetEntry
        switch resolve(name, from: parsed.callerPane, missing: "pane '\(name)' not found in registry") {
        case .entry(let found): entry = found
        case .failure(let response): return response
        }

        if case .viewerPane = entry {
            return IPCResponse(success: false, error: "pane '\(name)' is a viewer pane, not a terminal")
        }

        guard let surfaceView = entry.surfaceView else {
            return IPCResponse(success: false, error: "pane '\(name)' is no longer alive")
        }

        var resultText = ""
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            defer { semaphore.signal() }

            guard let surface = surfaceView.surface else { return }

            var text = ghostty_text_s()
            let sel = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                    x: 0,
                    y: 0),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                    x: 0,
                    y: 0),
                rectangle: false)

            guard ghostty_surface_read_text(surface, sel, &text) else { return }
            defer { ghostty_surface_free_text(surface, &text) }

            let fullText = String(cString: text.text)
            let allLines = fullText.components(separatedBy: "\n")

            // Take the last N lines, dropping any trailing empty line from the split
            let trimmed = allLines.last == "" ? Array(allLines.dropLast()) : allLines
            let lastLines = trimmed.suffix(lineCount)
            resultText = lastLines.joined(separator: "\n")
        }

        semaphore.wait()

        if resultText.isEmpty {
            return IPCResponse(success: false, error: "failed to read terminal content from '\(name)'")
        }

        let data = IPCData.readResult(IPCData.ReadResultData(text: resultText))
        return IPCResponse(success: true, data: data)
    }

    /// One run of `+send-keys` bytes, tagged with how the receiving program
    /// should understand it.
    struct SendKeysSegment: Equatable {
        enum Kind { case text, key }
        let kind: Kind
        let bytes: [UInt8]
    }

    /// Decode a `--segments=` payload: comma-separated runs, each a kind tag
    /// (`t` for text, `k` for a key) followed by that run's bytes in hex.
    ///
    /// Hex because the payload reaches us as a JSON string while the bytes it
    /// carries are arbitrary — control characters and non-UTF-8 sequences are
    /// exactly what `+send-keys` exists to deliver.
    ///
    /// Returns nil for anything malformed, which the caller treats as "use
    /// the flat `--keys=` payload" rather than as a failure.
    static func decodeSendKeysSegments(_ encoded: String) -> [SendKeysSegment]? {
        var segments: [SendKeysSegment] = []

        for field in encoded.split(separator: ",", omittingEmptySubsequences: false) {
            guard let tag = field.first else { return nil }
            let kind: SendKeysSegment.Kind
            switch tag {
            case "t": kind = .text
            case "k": kind = .key
            default: return nil
            }

            let hex = field.dropFirst()
            guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }

            var bytes: [UInt8] = []
            bytes.reserveCapacity(hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }

            segments.append(.init(kind: kind, bytes: bytes))
        }

        return segments.isEmpty ? nil : segments
    }

    private func handleSendKeys(_ request: IPCRequest) -> IPCResponse {
        guard let arguments = request.arguments, !arguments.isEmpty else {
            return IPCResponse(success: false, error: "arguments required for +send-keys")
        }

        var target: String?
        var callerPane: String?
        var text: String?
        var encodedSegments: String?

        for arg in arguments {
            if let value = arg.dropPrefix("--target=") {
                target = String(value)
            } else if let value = arg.dropPrefix("--caller-pane=") {
                callerPane = String(value)
            } else if let value = arg.dropPrefix("--keys=") {
                text = String(value)
            } else if let value = arg.dropPrefix("--segments=") {
                encodedSegments = String(value)
            }
        }

        guard let target else {
            return IPCResponse(success: false, error: "--target is required for +send-keys")
        }

        guard let text, !text.isEmpty else {
            return IPCResponse(success: false, error: "text is required for +send-keys")
        }

        // `--segments=` splits the same bytes at their text↔key boundaries so
        // text can be written as a paste and keys bare. The CLI only sends it
        // when there is a boundary to preserve, and an older CLI never sends
        // it at all, so falling back to the flat `--keys=` payload is the
        // normal path for a single-kind send rather than an error case.
        let segments = encodedSegments.flatMap(Self.decodeSendKeysSegments)

        pruneStaleTargets()

        let entry: TargetEntry
        switch resolve(target, from: callerPane, missing: "target '\(target)' not found") {
        case .entry(let found): entry = found
        case .failure(let response): return response
        }

        if case .viewerPane = entry {
            return IPCResponse(success: false, error: "target '\(target)' is a viewer pane, not a terminal")
        }

        var sendError: String?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            defer { semaphore.signal() }

            guard let surface = entry.surfaceView else {
                sendError = "target '\(target)' is no longer alive"
                return
            }
            guard let surfaceModel = surface.surfaceModel else {
                sendError = "target '\(target)' has no surface model"
                return
            }
            guard let segments else {
                surfaceModel.writePtyRaw(text)
                return
            }
            for segment in segments {
                switch segment.kind {
                case .text: surfaceModel.writePtyBracketed(segment.bytes)
                case .key: surfaceModel.writePtyRaw(segment.bytes)
                }
            }
        }
        semaphore.wait()

        if let sendError {
            return IPCResponse(success: false, error: sendError)
        }
        return .ok
    }

    // MARK: - Rearrange

    private func handleRearrange(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let layoutJSON = parsed.layout else {
            return IPCResponse(success: false, error: "--layout is required for +rearrange")
        }

        var result: IPCResponse = .ok
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async { [weak self] in
            defer { semaphore.signal() }

            MainActor.assumeIsolated {
                guard let self else {
                    result = IPCResponse(success: false, error: "IPC server no longer available")
                    return
                }

                self.pruneStaleTargets()

                // Resolve target controller
                let controller: TerminalController?
                if let target = parsed.target {
                    controller = self.resolveTarget(target, from: parsed.callerPane)?.controller
                    if controller == nil {
                        result = IPCResponse(success: false, error: "target window '\(target)' not found")
                        return
                    }
                } else if let callerController = self.callerAnchorController(parsed) {
                    // "Rearrange this window" means the caller's window, not
                    // whichever one the user has clicked into since. Same race
                    // as `+split`, same fix; the layout names panes that live in
                    // a particular window, so the focused-window guess made the
                    // command fail outright as often as it moved the wrong one.
                    controller = callerController
                } else {
                    controller = TerminalController.preferredParent
                    if controller == nil {
                        result = IPCResponse(success: false, error: "no focused window found")
                        return
                    }
                }

                guard let controller else { return }

                // Build the new tree out of the panes this window already has.
                // The EXISTING PaneView wrappers are reused, so leaf identity
                // (and therefore SwiftUI structural identity) is preserved
                // across the rearrange.
                let newRoot: SplitTree<PaneView>.Node
                switch RearrangeLayout.build(
                    layoutJSON: layoutJSON,
                    in: controller.surfaceTree,
                    resolve: { name in
                        // The layout names panes of THIS window: its own
                        // pane of each name is the one meant.
                        guard case .found(let entry) = self.lookupOnMain(name, scope: controller) else { return nil }
                        return .init(
                            surface: entry.surfaceView,
                            viewerPane: entry.viewerPaneView,
                            isAlive: entry.isAlive)
                    }
                ) {
                case .success(let root):
                    newRoot = root
                case .failure(let failure):
                    result = IPCResponse(success: false, error: failure.message)
                    return
                }

                // A STASHED pane the layout leaves out stays stashed — the
                // layout describes the grid, and a stash is not part of it.
                // It is carried into the new tree (top level, where it is
                // hidden anyway); one the layout DOES place is restored.
                let placed = Set(newRoot.leaves())
                let carried = controller.surfaceTree.stashedViews.filter { !placed.contains($0) }
                let rootWithStash = carried.reduce(SplitTree<PaneView>(root: newRoot, zoomed: nil, stashed: [])) {
                    $0.insertingAtTopLevel(view: $1, side: .right)
                }

                // Collect all current panes in the tree
                let currentPanes = Set(controller.surfaceTree.map { $0 })
                let keptPanes = Set(rootWithStash.map { $0 })
                let removedPanes = currentPanes.subtracting(keptPanes)

                // Focus stays where it was if the layout kept that pane, and
                // otherwise lands on the layout's first one. A focused VIEWER
                // is not `focusedSurface` (it has no surface); it is whichever
                // pane's content holds first responder.
                let focusedSurface = controller.focusedSurface
                let focusedPane = controller.surfaceTree.first { pane in
                    if let focusedSurface { return pane.surfaceView === focusedSurface }
                    return pane.contentIsFirstResponder
                }
                let newFocus: PaneView = if let focusedPane, keptPanes.contains(focusedPane) {
                    focusedPane
                } else {
                    newRoot.leftmostLeaf()
                }

                // Replace the tree
                let newTree = rootWithStash.withStash(carried.map(\.id))
                controller.replaceSurfaceTree(
                    newTree,
                    moveFocusTo: newFocus.surfaceView,
                    moveFocusFrom: focusedSurface,
                    undoAction: "Rearrange Layout"
                )

                // A viewer has no surface for `replaceSurfaceTree` to focus,
                // so it is focused the way the close path does it.
                if newFocus.surfaceView == nil {
                    DispatchQueue.main.async { Ghostty.moveFocus(to: newFocus) }
                }

                // Remove registry entries for panes no longer in the tree
                for pane in removedPanes {
                    for (name, entries) in self.targetRegistry {
                        for entry in entries where entry.names(pane) { self.unregister(name, entry) }
                    }
                }

                Self.logger.info("IPC: rearranged layout with \(keptPanes.count) panes")
            }
        }

        semaphore.wait()
        return result
    }

    private func handleList() -> IPCResponse {
        var windowsData: [IPCData.WindowData] = []
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async { [weak self] in
            defer { semaphore.signal() }

            MainActor.assumeIsolated {
                guard let self else { return }

                self.pruneStaleTargets()

                let scriptWindows = NSApp.scriptWindows
                let frontWindow = scriptWindows.first

                for scriptWindow in scriptWindows {
                    let isFocused = scriptWindow.stableID == frontWindow?.stableID

                    var tabsData: [IPCData.TabData] = []
                    for tab in scriptWindow.tabs {
                        guard let controller = tab.parentController else { continue }

                        let windowName = controller.windowName
                        self.ensureWindowRegistered(name: windowName, controller: controller)

                        let splitsData = self.buildSplitNodeData(
                            node: controller.surfaceTree.root,
                            focusedSurface: controller.focusedSurface,
                            controller: controller
                        )

                        tabsData.append(IPCData.TabData(
                            id: tab.idValue,
                            title: tab.title,
                            index: tab.index,
                            selected: tab.selected,
                            splits: splitsData
                        ))
                    }

                    let windowName = scriptWindow.preferredController?.windowName
                    windowsData.append(IPCData.WindowData(
                        id: scriptWindow.stableID,
                        title: scriptWindow.title,
                        target: windowName,
                        focused: isFocused,
                        tabs: tabsData,
                        title_set_by_user: scriptWindow.preferredController?.windowTitleSetByUser ?? false
                    ))
                }
            }
        }

        semaphore.wait()

        let data = IPCData.listState(IPCData.ListStateData(windows: windowsData))
        return IPCResponse(success: true, data: data)
    }

    /// Whether a window target name is already held — registered, or the
    /// display name of a live window other than `controller`. The restore
    /// path asks BEFORE building a window's surfaces, because the name is
    /// baked into each pane's `GHOZTTY_WINDOW_NAME` and must be the one the
    /// window actually ends up with.
    @MainActor
    func isWindowNameTaken(_ name: String, excluding controller: TerminalController? = nil) -> Bool {
        pruneStaleTargets()
        // A live window can hold the name without being in the registry yet
        // (fresh windows are only lazily registered on +list / first
        // targeting) — check both, or the restored window would become a
        // second holder of the same target name.
        let heldByLiveWindow = TerminalController.all.contains {
            $0 !== controller && $0.windowName == name
        }
        return targetRegistry[name]?.isEmpty == false || heldByLiveWindow
    }

    /// Re-register a RESTORED remote window under the IPC target name
    /// persisted in its `RemoteSessionManifest` entry, so `+read` /
    /// `+send-keys` / `+close --target=<name>` keep working across a
    /// quit/relaunch. If the name is already taken by a live target (the
    /// user opened a new window under the same name meanwhile), the existing
    /// registration wins — consistent with the CLI's idempotent named-target
    /// semantics — and the restored window is simply not re-registered.
    @MainActor
    func registerRestoredRemoteWindow(name: String, controller: TerminalController) {
        guard !isWindowNameTaken(name, excluding: controller) else {
            Self.logger.info("IPC: restored remote window not re-registered — target '\(name)' already in use")
            return
        }
        register(name, .window(WeakRef(controller)))
        // Adopt the name as the controller's display name too so +list shows
        // the persisted target instead of a fresh "window-N" alias.
        controller.windowName = name
        Self.logger.info("IPC: re-registered restored remote window target '\(name)'")
    }

    /// Re-register a RESTORED pane under the IPC target name persisted in
    /// its `SessionLayoutManifest` leaf (T06), so `+read` / `+send-keys` /
    /// `+close --target=<name>` keep working across a quit/relaunch. Same
    /// idempotent semantics as `registerRestoredRemoteWindow`, in the pane's
    /// own window (pane names belong to it): a live pane of that name already
    /// there wins, as does a window holding it, and the restored pane is
    /// skipped.
    @MainActor
    func registerRestoredPane(name: String, controller: TerminalController, surface: Ghostty.SurfaceView) {
        guard isPaneNameFree(name, in: controller) else {
            Self.logger.info("IPC: restored pane not re-registered — target '\(name)' already in use")
            return
        }
        register(name, .pane(controller: WeakRef(controller), surface: WeakRef(surface)))
        Self.logger.info("IPC: re-registered restored pane target '\(name)'")
    }

    /// Whether a pane in `controller` may take `name`: no window holds it,
    /// and no other live pane in that window does.
    @MainActor
    private func isPaneNameFree(_ name: String, in controller: TerminalController) -> Bool {
        pruneStaleTargets()
        return !(targetRegistry[name] ?? []).contains { $0.isWindow || liveController(of: $0) === controller }
    }

    @MainActor
    private func ensureWindowRegistered(name: String, controller: BaseTerminalController) {
        if targetRegistry[name]?.contains(where: \.isWindow) != true, let tc = controller as? TerminalController {
            register(name, .window(WeakRef(tc)))
        }
    }

    /// The name `+list` shows for a pane: its registered name, else its id —
    /// which needs no registering, since a pane id resolves on its own.
    @MainActor
    private func paneName(of object: AnyObject, id: UUID) -> String {
        for (name, entries) in targetRegistry where entries.contains(where: { $0.object === object }) {
            return name
        }
        return id.uuidString
    }

    @MainActor
    private func buildSplitNodeData(
        node: SplitTree<PaneView>.Node?,
        focusedSurface: Ghostty.SurfaceView?,
        controller: BaseTerminalController
    ) -> IPCData.SplitNodeData {
        guard let node else {
            return .leaf(IPCData.TerminalData(
                id: "",
                title: "",
                working_directory: "",
                pid: 0,
                tty: "",
                name: nil,
                focused: false,
                exit_code: nil
            ))
        }

        switch node {
        case .leaf(let pane):
            if let viewer = pane.viewerView {
                let paneName = paneName(of: pane, id: pane.id)
                return .leaf(IPCData.TerminalData(
                    id: pane.id.uuidString,
                    title: pane.title,
                    working_directory: "",
                    pid: 0,
                    tty: "",
                    name: paneName,
                    focused: false,
                    exit_code: nil,
                    pane_type: "viewer",
                    url: viewer.location,
                    stashed: controller.surfaceTree.isStashed(pane)
                ))
            }
            guard let view = pane.surfaceView else {
                return .leaf(IPCData.TerminalData(
                    id: pane.id.uuidString,
                    title: pane.title,
                    working_directory: "",
                    pid: 0,
                    tty: "",
                    name: nil,
                    focused: false,
                    exit_code: nil
                ))
            }
            let paneName = paneName(of: view, id: view.id)

            return .leaf(IPCData.TerminalData(
                id: view.id.uuidString,
                title: view.title,
                working_directory: view.pwd ?? "",
                pid: view.surfaceModel?.foregroundPID ?? 0,
                tty: view.surfaceModel?.ttyName ?? "",
                name: paneName,
                focused: view === focusedSurface,
                exit_code: view.exitCode.map { Int($0) },
                banner: view.paneBanner,
                // T574: read-only mode, the machine-readable half of the
                // badge the pane already shows. Absent when off, so the
                // field is additive for every existing caller.
                readonly: view.readonly ? true : nil,
                stashed: controller.surfaceTree.isStashed(pane),
                state: view.activityState.rawValue
            ))
        case .split(let split):
            let direction: String = switch split.direction {
            case .horizontal: "horizontal"
            case .vertical: "vertical"
            }
            return .split(
                direction: direction,
                ratio: split.ratio,
                left: buildSplitNodeData(
                    node: split.left,
                    focusedSurface: focusedSurface,
                    controller: controller
                ),
                right: buildSplitNodeData(
                    node: split.right,
                    focusedSurface: focusedSurface,
                    controller: controller
                )
            )
        }
    }

    /// Drop names whose window or pane is gone. Callable from the IPC queue
    /// or main; the registry itself is only touched on main.
    private func pruneStaleTargets() {
        Self.onMain {
            for (name, entries) in targetRegistry {
                let live = entries.filter(\.isAlive)
                if live.count != entries.count { targetRegistry[name] = live.isEmpty ? nil : live }
            }
        }
    }

    /// Record `name` for `entry`. A window name replaces the window that held
    /// it; a pane name replaces only the pane of that name in the SAME window
    /// (`TargetLookup`), and moves with the pane if it was registered under
    /// another name's entry before. Main thread only.
    private func register(_ name: String, _ entry: TargetEntry) {
        MainActor.assumeIsolated {
            var entries = (targetRegistry[name] ?? []).filter(\.isAlive)
            if entry.isWindow {
                entries.removeAll(where: \.isWindow)
            } else {
                let window = liveController(of: entry)
                entries.removeAll { other in
                    !other.isWindow && (other.object === entry.object || liveController(of: other) === window)
                }
            }
            entries.append(entry)
            targetRegistry[name] = entries
        }
    }

    /// Forget that `name` names `entry`'s window or pane (it is being closed).
    private func unregister(_ name: String, _ entry: TargetEntry) {
        guard var entries = targetRegistry[name] else { return }
        entries.removeAll { $0.object === entry.object || !$0.isAlive }
        targetRegistry[name] = entries.isEmpty ? nil : entries
    }

    /// The window `entry` is in now: a pane's by walking the live windows,
    /// since a pane can be moved to another one after it was named.
    @MainActor
    private func liveController(of entry: TargetEntry) -> TerminalController? {
        if case .window = entry { return entry.controller }
        return (Self.paneAndController(for: entry)?.0 as? TerminalController) ?? entry.controller
    }

    /// What a `--target`/`--name` resolved to.
    private enum Lookup {
        case found(TargetEntry)
        case notFound
        /// Panes in several windows hold the name; the error says which.
        case ambiguous(String)
    }

    /// Resolve a `--target`/`--name` the way `TargetLookup` says, for a
    /// command run from `callerPane` (`--caller-pane=`; nil for a caller with
    /// no pane, which searches every window).
    ///
    /// A string that parses as a uuid is a PANE ID (the `+list` leaf `id`,
    /// the pane's own `$GHOZTTY_PANE_ID`), found by walking the live windows;
    /// UUID parsing normalizes case. Anything else is a name: the registry's
    /// panes and windows, plus a scan of live windows by their own
    /// `windowName` — which is what makes an AUTO-NAMED window (`window-7`,
    /// minted for every Cmd-N window and exported as `$GHOZTTY_WINDOW_NAME`)
    /// targetable without a `+list` first. (Registration otherwise only
    /// happened at `+new-window --target=` time or when `+list` walked the
    /// tree, and callers that swallow stderr — the activity-state hooks do —
    /// saw the window simply never update.)
    ///
    /// Callable from the IPC queue or main: it runs on main, where the
    /// windows and the registry live.
    private func lookup(_ target: String, from callerPane: String?) -> Lookup {
        Self.onMain {
            let caller = callerPane.flatMap { pane -> TerminalController? in
                guard !pane.isEmpty, case .found(let entry) = lookupOnMain(pane, scope: nil) else { return nil }
                return entry.controller
            }
            return lookupOnMain(target, scope: caller)
        }
    }

    @MainActor
    private func lookupOnMain(_ target: String, scope: TerminalController?) -> Lookup {
        if let uuid = UUID(uuidString: target) {
            for controller in TerminalController.all {
                for pane in controller.surfaceTree where pane.id == uuid {
                    if let surface = pane.surfaceView {
                        return .found(.pane(controller: WeakRef(controller), surface: WeakRef(surface)))
                    }
                    return .found(.viewerPane(controller: WeakRef(controller), pane: WeakRef(pane)))
                }
            }
            // A well-formed uuid is a pane id or nothing; no window carries
            // one as its name.
            return .notFound
        }

        var entries: [TargetEntry] = (targetRegistry[target] ?? []).compactMap { entry in
            guard entry.isAlive, let controller = liveController(of: entry) else { return nil }
            return entry.moved(to: controller)
        }
        if !entries.contains(where: \.isWindow),
           let controller = TerminalController.all.first(where: { $0.windowName == target }) {
            let window = TargetEntry.window(WeakRef(controller))
            register(target, window)
            entries.append(window)
        }

        let candidates = entries.map { entry in
            TargetLookup.Candidate(
                kind: entry.isWindow ? .window : .pane,
                windowName: entry.controller?.windowName ?? "",
                inCallerWindow: scope != nil && entry.controller === scope)
        }
        switch TargetLookup.pick(candidates) {
        case .found(let index):
            return .found(entries[index])
        case .notFound:
            return .notFound
        case .ambiguous(let windows):
            Self.logger.notice("IPC: '\(target, privacy: .public)' is ambiguous: panes in \(windows, privacy: .public)")
            return .ambiguous(TargetLookup.ambiguityError(target, windows: windows))
        }
    }

    /// `lookup` for a caller that only needs the entry: nil when nothing (or
    /// more than one thing) answers to the name.
    private func resolveTarget(_ target: String, from callerPane: String? = nil) -> TargetEntry? {
        if case .found(let entry) = lookup(target, from: callerPane) { return entry }
        return nil
    }

    /// `lookup` as a handler wants it: the entry, or the reply to fail with —
    /// `missing` when nothing answers to the name, the ambiguity when panes in
    /// several windows do.
    private func resolve(_ target: String, from callerPane: String?, missing: String) -> Resolved {
        switch lookup(target, from: callerPane) {
        case .found(let entry): return .entry(entry)
        case .notFound: return .failure(IPCResponse(success: false, error: missing))
        case .ambiguous(let error): return .failure(IPCResponse(success: false, error: error))
        }
    }

    private enum Resolved {
        case entry(TargetEntry)
        case failure(IPCResponse)
    }

    /// Raise the window owning `target` and focus the pane within it, or do
    /// nothing at all if the target names nothing that is currently open —
    /// or names panes in several windows: a link has no caller pane, so the
    /// name is looked up across every window (`TargetLookup`), and an
    /// ambiguous one is reported rather than resolved at random. Returns why
    /// nothing was focused, or nil when it was.
    ///
    /// This is the whole of what the `ghoztty://` URL scheme can do (see
    /// `GhozttyURLScheme`), factored out so the untrusted caller shares the
    /// resolver — and therefore the naming system — with `--target`, rather
    /// than getting a parallel one. Never creates anything: a link that
    /// LAUNCHED the app finds an empty registry and correctly does nothing.
    ///
    /// Unlike every `ghoztty +…` command, this ALWAYS takes focus: a link
    /// click is a person asking to go somewhere, and raising is the whole
    /// verb. It does not consult `IPCFocusPolicy`.
    @MainActor
    @discardableResult
    func focusTarget(_ target: String) -> GhozttyURLScheme.Failure? {
        pruneStaleTargets()
        switch lookup(target, from: nil) {
        case .found(let entry) where entry.isAlive:
            return Self.bringForward(entry) ? nil : .targetNotFound(target)
        case .found, .notFound:
            return .targetNotFound(target)
        case .ambiguous(let error):
            return .ambiguousTarget(target, detail: error)
        }
    }

    /// Activate the app, raise the window owning `entry`, and focus the pane
    /// it names. Shared by the URL scheme and by the idempotent `+split
    /// --name=` / `+new-window --target=` hits when the caller passed
    /// `--focus` — so "focus an existing target" means one thing.
    @MainActor
    @discardableResult
    private static func bringForward(_ entry: TargetEntry) -> Bool {
        // A STASHED pane is restored first: raising a pane you can't see
        // raises nothing. `revealPane` restores, raises, and focuses.
        if let (owner, pane) = paneAndController(for: entry), owner.surfaceTree.isStashed(pane) {
            owner.revealPane(pane)
            return true
        }

        // A terminal pane goes through `focusSurface`, which also raises and
        // activates; a viewer pane has no surface, so it is made first
        // responder directly and its window raised.
        if let surface = entry.surfaceView, let controller = entry.controller {
            controller.focusSurface(surface)
        } else if let pane = entry.viewerPaneView {
            Ghostty.moveFocus(to: pane)
            pane.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if let controller = entry.controller {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            return false
        }
        return true
    }

    /// After a programmatic split, honor `--focus`: activate the app, raise
    /// the window, and give the new pane keyboard focus. With the default
    /// (background) there is nothing to do — the split kept focus where it
    /// was (`BaseTerminalController.keepingFirstResponder`).
    @MainActor
    static func presentIfAsked(
        _ pane: PaneView?,
        in controller: BaseTerminalController,
        _ focus: IPCFocusPolicy
    ) {
        guard let pane else { return }
        if focus.raisesWindow {
            controller.window?.makeKeyAndOrderFront(nil)
        }
        if focus.activatesApp {
            NSApp.activate(ignoringOtherApps: true)
        }
        if focus.movesKeyboardFocus {
            focusOnceSettled(pane, in: controller, deadline: .now() + 2)
        }
    }

    /// Move keyboard focus to `pane` once activation has landed.
    ///
    /// Moving it straight away loses when the app was INACTIVE: activation
    /// makes the window key a beat later, and the window's become-key handler
    /// (`BaseTerminalController.windowDidBecomeKey`) finds the window itself
    /// as first responder — the split re-parented the old pane — and restores
    /// the stale `focusedSurface`, the pane the caret was just taken from
    /// (measured). Waiting until the app is active, the window is key, and
    /// the pane is mounted puts this move after that restore. A deadline
    /// keeps a refused activation from leaving the pane unfocused for good.
    @MainActor
    private static func focusOnceSettled(
        _ pane: PaneView,
        in controller: BaseTerminalController,
        deadline: DispatchTime
    ) {
        guard let window = controller.window else { return }
        let settled = NSApp.isActive && window.isKeyWindow && pane.contentView.window === window
        if settled || DispatchTime.now() >= deadline {
            Ghostty.moveFocus(to: pane)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusOnceSettled(pane, in: controller, deadline: deadline)
        }
    }

    private func windowName(for controller: TerminalController) -> String? {
        for (name, entries) in targetRegistry where entries.contains(where: { $0.isWindow && $0.object === controller }) {
            return name
        }
        return nil
    }

    /// The registered window-target name for a controller, if any (session
    /// layout manifest: a restored window must stay addressable under the
    /// name `+new-window --target=` registered). Main-thread, like every
    /// registry write.
    @MainActor
    func registeredWindowName(forController controller: TerminalController) -> String? {
        windowName(for: controller)
    }

    /// The registered pane-target name for a surface, if any — nil when the
    /// pane was never named (unlike `paneNameForSurface`, which falls back
    /// to the surface UUID for `+list` display).
    @MainActor
    func registeredPaneName(forSurface view: Ghostty.SurfaceView) -> String? {
        for (name, entries) in targetRegistry where entries.contains(where: { $0.object === view }) {
            return name
        }
        return nil
    }

    @MainActor
    func registeredPaneName(forViewerPane pane: PaneView) -> String? {
        for (name, entries) in targetRegistry where entries.contains(where: { $0.object === pane }) {
            return name
        }
        return nil
    }

    /// Re-register a RESTORED viewer pane under its persisted IPC name.
    /// Same idempotent semantics as `registerRestoredPane`.
    @MainActor
    func registerRestoredViewerPane(name: String, controller: TerminalController, pane: PaneView) {
        guard isPaneNameFree(name, in: controller) else {
            Self.logger.info("IPC: restored viewer pane not re-registered — target '\(name)' already in use")
            return
        }
        register(name, .viewerPane(controller: WeakRef(controller), pane: WeakRef(pane)))
        Self.logger.info("IPC: re-registered restored viewer pane target '\(name)'")
    }

    private static func randomDarkColor() -> NSColor {
        let hue = CGFloat.random(in: 0...1)
        // Floors raised from 0.2...0.3 / 0.1...0.15: the old ranges landed every
        // window on the same near-black (brightest channel ~26-38/255, hue
        // imperceptible), so `--color=random` tints were indistinguishable.
        // These keep windows comfortably dark but lift them off pure black and
        // let the hue read.
        let saturation = CGFloat.random(in: 0.33...0.46)
        let brightness = CGFloat.random(in: 0.13...0.18)
        return NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private static func applyColorScheme(for tintColor: Color?, to surfaceView: Ghostty.SurfaceView) {
        guard let tintColor, let surface = surfaceView.surface else { return }
        let resolved = NSColor(tintColor).resolvedSRGB

        // Set terminal background color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        ghostty_surface_set_color(surface, 2, 0,
            UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))

        // Set foreground for contrast
        let fg: (UInt8, UInt8, UInt8) = resolved.isLightColor
            ? (0, 0, 0) : (255, 255, 255)
        ghostty_surface_set_color(surface, 1, 0, fg.0, fg.1, fg.2)

        // Adjust ANSI palette for contrast
        Ghostty.SurfaceView.adjustPaletteForContrast(surface: surface, background: resolved)
    }

    /// The pane a command with no explicit target should anchor at: the one it
    /// was invoked FROM (`$GHOZTTY_PANE_ID`, which the CLI forwards as
    /// `--caller-pane=`), or nil to keep the `preferredParent` focused-window
    /// fallback.
    ///
    /// This is the ONE place the app consumes the caller's pane, as
    /// `apprt.ipc.seedCallerPane` is the ONE place the CLI produces it. It
    /// exists because `preferredParent` is read on the main queue at HANDLE
    /// time: the user can switch windows between the CLI invocation and the
    /// app's turn, and an agent's command is asynchronous with respect to
    /// focus even when nobody touches anything.
    ///
    /// Three ways to get nil, all of them ordinary:
    ///
    ///   * The caller named an anchor of its own. `--target`, `--pane`, and
    ///     `--from-focused` all say where the command should land, and each
    ///     wins over the environment's default.
    ///   * Nothing was forwarded — a plain non-Ghoztty shell, or a pane baked
    ///     by an app/agent that predates the flag.
    ///   * The pane id no longer resolves. A script outliving its own pane is
    ///     normal, so this falls back rather than failing the command — which
    ///     is exactly why the CLI sends `--caller-pane=` and not `--pane=`,
    ///     where a name that resolves to nothing is a typo and a hard error.
    static func callerAnchorPane(
        _ parsed: ParsedArguments,
        isAlive: (String) -> Bool
    ) -> String? {
        guard parsed.target == nil,
              parsed.pane == nil,
              !parsed.fromFocused,
              let caller = parsed.callerPane,
              !caller.isEmpty,
              isAlive(caller)
        else { return nil }
        return caller
    }

    /// `callerAnchorPane` against the live registry.
    private func callerAnchorPane(_ parsed: ParsedArguments) -> String? {
        Self.callerAnchorPane(parsed, isAlive: { self.resolveTarget($0)?.isAlive == true })
    }

    /// The window owning the pane the command was invoked from, for the
    /// commands that act on a WINDOW rather than anchoring beside a pane.
    private func callerAnchorController(_ parsed: ParsedArguments) -> TerminalController? {
        guard let pane = callerAnchorPane(parsed) else { return nil }
        return resolveTarget(pane)?.controller
    }

    private static func parseSplitDirection(_ value: String) -> SplitTree<PaneView>.NewDirection? {
        switch value.lowercased() {
        case "right": return .right
        case "down": return .down
        case "left": return .left
        case "up": return .up
        default: return nil
        }
    }

    private func parseArguments(_ arguments: [String]) -> ParsedArguments {
        Self.parseArguments(arguments)
    }

    /// Pure: the IPC argument list → `ParsedArguments`. Static so tests can
    /// pin what each flag means without a running server.
    static func parseArguments(_ arguments: [String]) -> ParsedArguments {
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

            if let value = arg.dropPrefix("--view=") {
                result.view = String(value)
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

            if let value = arg.dropPrefix("--state=") {
                result.state = String(value)
                continue
            }

            if let value = arg.dropPrefix("--percent=") {
                result.percent = Int(value) ?? -1
                continue
            }

            if let value = arg.dropPrefix("--split-percent=") {
                result.percent = Int(value) ?? -1
                continue
            }

            if let value = arg.dropPrefix("--pane=") {
                result.pane = String(value)
                continue
            }

            if let value = arg.dropPrefix("--caller-pane=") {
                result.callerPane = String(value)
                continue
            }

            if let value = arg.dropPrefix("--env=") {
                let envStr = String(value)
                if let eqIdx = envStr.firstIndex(of: "=") {
                    let key = String(envStr[envStr.startIndex..<eqIdx])
                    let val = String(envStr[envStr.index(after: eqIdx)...])
                    result.config.environmentVariables[key] = val
                }
                continue
            }

            if let value = arg.dropPrefix("--color=") {
                result.color = String(value)
                continue
            }

            if let value = arg.dropPrefix("--lines=") {
                result.lines = Int(value)
                continue
            }

            if let value = arg.dropPrefix("--split-color=") {
                result.splitColor = String(value)
                continue
            }

            if let value = arg.dropPrefix("--layout=") {
                result.layout = String(value)
                continue
            }

            if let value = arg.dropPrefix("--shell=") {
                result.shell = String(value)
                continue
            }

            if let focus = IPCFocusPolicy.fromFlag(arg) {
                result.focus = focus
                continue
            }

            // The pre-`--focus` opt-out. Not focusing is now the default, so
            // it is accepted and does nothing (callers in the wild pass it).
            if arg == IPCFocusPolicy.legacyNoActivateFlag {
                continue
            }

            if arg == "--from-focused" {
                result.fromFocused = true
                continue
            }
        }

        if !commandParts.isEmpty {
            result.config.command = commandParts.joined(separator: " ")
        }

        return result
    }

    private func resolveShell(explicit: String?) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let configShell = ghostty.config.commandShell { return configShell }
        if let envShell = ProcessInfo.processInfo.environment["SHELL"], !envShell.isEmpty { return envShell }
        // Before the last-resort default, resolve the user's LOGIN shell from the
        // passwd DB (getpwuid → pw_shell). This is env-independent, so it does the
        // right thing for a non-zsh user even when $SHELL is absent — mirroring the
        // agent's own getpwuid fallback in pty_child.zig. Hard-coding /bin/zsh only
        // as the final resort keeps a sane default if passwd lookup fails.
        if let pw = getpwuid(getuid()), let shellPtr = pw.pointee.pw_shell {
            let loginShell = String(cString: shellPtr)
            if !loginShell.isEmpty { return loginShell }
        }
        return "/bin/zsh"
    }

    private func wrapCommandInShell(_ command: String, shell: String?) -> String {
        let shellPath = resolveShell(explicit: shell)
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "\(shellPath) -lic '\(escaped); exec \(shellPath) -li'"
    }
}

private extension StringProtocol {
    func dropPrefix(_ prefix: String) -> SubSequence? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
    }
}
