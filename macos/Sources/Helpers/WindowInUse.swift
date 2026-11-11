import AppKit

/// Whether a window can be seen, and whether it is the one in use, for work
/// that only matters to the eye.
///
/// Measured (`docs/reference/background-windows.md`): a Core Animation loop
/// keeps WindowServer rendering it in a window nobody can see, and a window
/// title costs a WindowServer transaction and a titlebar layout pass each time
/// it is set, seen or not. So the busy border and the sidebar's busy sheen move
/// only in the window in use, a hidden window's title and terminal frames wait
/// until it shows, and so on. What they show is never wrong, only still: state
/// (activity, notifications, the dock badge) is tracked as always.
@MainActor
enum WindowInUse {
    /// Endless decoration runs here: the key window, on screen. Every other
    /// window — behind it, minimized, on another Space, or every window while
    /// another app is active — holds still.
    static func animates(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if inUseForTesting.contains(window) { return true }
        return window.isKeyWindow && isOnScreen(window)
    }

    /// Windows a test has declared in use and seen. The test host is never
    /// the active app and its windows open behind other apps', so a test
    /// about something else (layout, drawing, the sheen) that needs its
    /// window drawing says so here rather than pulling the window in front
    /// of whatever the person at the machine is doing.
    /// Weak, so a closed window takes its mark with it.
    private static let inUseForTesting = NSHashTable<NSWindow>.weakObjects()

    static func setInUseForTesting(_ window: NSWindow, _ inUse: Bool) {
        if inUse {
            inUseForTesting.add(window)
        } else {
            inUseForTesting.remove(window)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: window)
    }

    /// Some part of the window's content can be seen. Minimized, hidden, on
    /// another Space, or covered (`WindowCoverage`) is not.
    static func isOnScreen(_ window: NSWindow) -> Bool {
        if inUseForTesting.contains(window) { return true }
        return window.occlusionState.contains(.visible) && !WindowCoverage.shared.isCovered(window)
    }

    /// Posted (object: the window) when `isOnScreen` may answer differently
    /// for it, beyond AppKit's own notifications in `changes`.
    static let didChangeNotification = Notification.Name("com.dzearing.ghoztty.windowInUseDidChange")

    /// The notifications after which `animates` or `isOnScreen` may answer
    /// differently. Minimizing changes the occlusion state; the app going
    /// inactive resigns its key window.
    static let changes: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didChangeOcclusionStateNotification,
        didChangeNotification,
    ]
}

/// Which windows are covered by the windows in front of them.
///
/// AppKit's own answer (`NSWindow.occlusionState`) counts a window as visible
/// while any pixel of it shows — and a window behind another of exactly its
/// frame always shows: its rounded corners and shadow peek out around the
/// front window's. Terminal windows that all fill the screen are the usual
/// layout, so behind the front one, AppKit called every one of them visible
/// and nothing they ran ever stopped. This asks the window list instead:
/// covered means opaque windows in front cover all of it but its corners.
///
/// Front-to-back order across apps changes without telling us, so this
/// re-checks on a slow timer as well as on our own windows' key, occlusion
/// and minimize events — not moves or resizes, which arrive every frame of a
/// drag: a window uncovered by a window moving away catches up within
/// `pollInterval`.
@MainActor
final class WindowCoverage {
    static let shared = WindowCoverage()

    /// How often the window list is re-read (~2ms a read).
    static let pollInterval: TimeInterval = 1

    /// How far in from each corner a window may show and still be covered:
    /// generous for the corner radius, which is all that peeks out of a
    /// same-size window behind another.
    static let cornerAllowance: CGFloat = 24

    private var covered: Set<Int> = []
    private var timer: Timer?
    private var refreshQueued = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func isCovered(_ window: NSWindow) -> Bool {
        start()
        return covered.contains(window.windowNumber)
    }

    /// Re-read the window list soon (once per run-loop turn, however many
    /// events ask).
    func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { WindowCoverage.shared.refresh() }
        }
        let center = NotificationCenter.default
        let windowEvents: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ]
        for name in windowEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowCoverage.shared.setNeedsRefresh() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WindowCoverage.shared.setNeedsRefresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        let now = Self.coveredWindows()
        guard now != covered else { return }
        let changed = now.symmetricDifference(covered)
        covered = now
        for number in changed {
            guard let window = NSApp.window(withWindowNumber: number) else { continue }
            NotificationCenter.default.post(name: WindowInUse.didChangeNotification, object: window)
        }
    }

    /// Our windows that the window list says are covered.
    private static func coveredWindows() -> Set<Int> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        let ourPID = Int(ProcessInfo.processInfo.processIdentifier)
        let screens = activeDisplayBounds()
        var front: [CGRect] = []
        var result: Set<Int> = []
        for entry in list {
            guard let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                .flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int
            else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            // Only ordinary windows: the menu bar, the Dock and notification
            // panels span the screen but are mostly see-through.
            guard layer == 0 else { continue }
            if pid == ourPID,
               isCovered(bounds, by: front, on: screens, corner: cornerAllowance) {
                result.insert(number)
            }
            // What covers the windows behind it: opaque, fully drawn windows.
            // Our own non-opaque ones (background opacity, blur) show through.
            let opaque = pid != ourPID || (NSApp.window(withWindowNumber: number)?.isOpaque ?? false)
            if alpha >= 1, opaque { front.append(bounds) }
        }
        return result
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// Whether `rect`, less a `corner`-sized square at each corner and
    /// whatever lies off every screen, is covered by `covers`. Pure, so it is
    /// tested (`WindowCoverageTests`).
    nonisolated static func isCovered(
        _ rect: CGRect, by covers: [CGRect], on screens: [CGRect], corner: CGFloat
    ) -> Bool {
        // The rect without its corners is the union of these two bands.
        var remaining = [
            rect.insetBy(dx: min(corner, rect.width / 2), dy: 0),
            rect.insetBy(dx: 0, dy: min(corner, rect.height / 2)),
        ].filter { !$0.isEmpty }
        for cover in covers {
            remaining = remaining.flatMap { subtract(cover, from: $0) }
            if remaining.isEmpty { return true }
        }
        // What is left may lie off screen, where nobody sees it either.
        return !remaining.contains { piece in
            screens.contains { !piece.intersection($0).isEmpty }
        }
    }

    /// `rect` minus `cut`, as up to four rects.
    nonisolated private static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
        let i = rect.intersection(cut)
        guard !i.isNull, !i.isEmpty else { return [rect] }
        var pieces: [CGRect] = []
        if i.minY > rect.minY { pieces.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: i.minY - rect.minY)) }
        if i.maxY < rect.maxY { pieces.append(CGRect(x: rect.minX, y: i.maxY, width: rect.width, height: rect.maxY - i.maxY)) }
        if i.minX > rect.minX { pieces.append(CGRect(x: rect.minX, y: i.minY, width: i.minX - rect.minX, height: i.height)) }
        if i.maxX < rect.maxX { pieces.append(CGRect(x: i.maxX, y: i.minY, width: rect.maxX - i.maxX, height: i.height)) }
        return pieces
    }
}

/// Calls `onChange` whenever its window may have started or stopped being the
/// one in use, or being seen. A view sets `window` from `viewDidMoveToWindow`.
@MainActor
final class WindowInUseObserver {
    private let onChange: () -> Void
    // Removed in `deinit`, which is not main-actor isolated;
    // NotificationCenter's removal is thread-safe.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            stop()
            guard let window else { return }
            tokens = WindowInUse.changes.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange() }
                }
            }
        }
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    private func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
