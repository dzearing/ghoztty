import AppKit
import SwiftUI

// MARK: - Window and group reorder (pure)

/// The geometry of a window row or project group dragged in the all-windows
/// list, over its siblings' frames as laid out (before any slide). Pure, so
/// pinned in `PaneSidebarItemDragTests`.
///
/// Siblings are the items the dragged one moves among: a group's windows, or
/// the list's top level (groups and lone windows). Unlike pane rows they are
/// not one height — a window shows its panes, a group its windows — so the
/// others slide by the DRAGGED item's pitch (`pitch`), and the index is read
/// off their midpoints by the dragged item's leading edge.
enum PaneSidebarItemReorder {
    /// The index, among the siblings without the dragged one, it would land
    /// at with its top at `top`: above every sibling before it whose middle
    /// its top has passed, below every one after it whose middle its bottom
    /// has passed. The leading edge, not the middle: a tall item held at
    /// the top of the list still goes above a short first one.
    static func target(top: CGFloat, dragged: Int, frames: [CGRect]) -> Int {
        guard frames.indices.contains(dragged) else { return 0 }
        let bottom = top + frames[dragged].height
        let staysAbove = frames[..<dragged].filter { $0.midY <= top }.count
        let passed = frames[(dragged + 1)...].filter { $0.midY < bottom }.count
        return staysAbove + passed
    }

    /// How far each sibling slides to make room: the dragged item's height
    /// and the gap that follows it (or, last, the one before it), so the
    /// list closes up exactly where it left.
    static func pitch(dragged: Int, frames: [CGRect]) -> CGFloat {
        guard frames.indices.contains(dragged) else { return 0 }
        let frame = frames[dragged]
        // A neighbour that is not laid out (`PaneSidebarItemDrag`'s stand-in,
        // far away) says nothing about the gap.
        let near = { (other: CGRect) in abs(other.midY - frame.midY) < frame.height + 200 }
        if frames.indices.contains(dragged + 1), near(frames[dragged + 1]) {
            return frames[dragged + 1].minY - frame.minY
        }
        if frames.indices.contains(dragged - 1), near(frames[dragged - 1]) {
            return frame.maxY - frames[dragged - 1].maxY
        }
        return frame.height
    }

    /// Where the dragged item's top will be laid out once it is moved to
    /// `target` (an index without it): down, it ends where the last sibling
    /// it passed ended; up, it starts where the first one it passed started.
    static func landingTop(dragged: Int, target: Int, frames: [CGRect]) -> CGFloat {
        guard frames.indices.contains(dragged) else { return 0 }
        let frame = frames[dragged]
        if target > dragged, frames.indices.contains(target) {
            return frame.minY + (frames[target].maxY - frame.maxY)
        }
        if target < dragged { return frames[target].minY }
        return frame.minY
    }

    /// Keeps the dragged item's top inside its siblings' span: dragged past
    /// the first or last, it stops there rather than leaving the list. It
    /// may also stay as low as `grabbed`, where it was picked up: a group
    /// drag folds the list up from under it, and the held header stays
    /// under the pointer rather than jumping to the shortened list's end.
    static func clamp(top: CGFloat, dragged: Int, frames: [CGRect], grabbed: CGFloat = -.infinity) -> CGFloat {
        guard frames.indices.contains(dragged), let first = frames.first, let last = frames.last else { return top }
        let lowest = Swift.max(last.maxY - frames[dragged].height, grabbed)
        return Swift.min(Swift.max(top, first.minY), Swift.max(first.minY, lowest))
    }
}

// MARK: - The drag

/// A window row or project group header being dragged up and down the
/// all-windows list to reorder it. The list's order is shared by every
/// window (`PaneSidebarSharedState.windowOrder`), so this reorders every
/// window's list — and only the LIST: no window and no pane moves on screen.
///
/// The same reorder the pane rows have (`PaneSidebarRowDrag`), on the same
/// pieces: the siblings' frames read as LAID OUT, outside their slide
/// (`PaneSidebarItemFrames`), the others sliding to make room on
/// `PaneSidebarOrder.shift`'s rule, and the dragged item following the
/// pointer up and down — kept in its list — then gliding into place. It moves
/// the item itself rather than a drawn copy, since a window drags its panes
/// with it. No `NSDraggingSession`: an item never leaves its list, so the
/// sidebar's own mouse tracking is its whole feed (`PaneSidebarItemDragView`,
/// then app-level event monitors that outlive the view).
///
/// Dragging a group folds every group first, so they are all one header high
/// and easy to place (with the fold's own animation), and puts the folds back
/// once it has landed. Dragging a window does the same with the windows: each
/// folds to its row, and the open ones open again once it has landed.
@MainActor
final class PaneSidebarItemDrag: ObservableObject {
    static let shared = PaneSidebarItemDrag()

    /// The dragged item's key (`PaneSidebarWindowGrouping.key`), or nil.
    @Published private(set) var key: String?
    /// The keys it moves among, in the list's order, itself included.
    private(set) var siblings: [String] = []
    /// The sidebar it is dragged in.
    private(set) weak var controller: BaseTerminalController?

    /// What changes as the pointer moves, apart from what changes once per
    /// drag (`key`, `isSettling`): only the items that slide or lift observe
    /// it, so a pointer move redraws them and not every window's whole list.
    let motion = PaneSidebarItemDragMotion()

    /// Where the dragged item's top is drawn, in the sidebar's space
    /// (`PaneSidebarGeometry.space`).
    private(set) var top: CGFloat {
        get { motion.top }
        set { motion.top = newValue }
    }
    /// The index it would land at among the siblings without it.
    private(set) var target: Int? {
        get { motion.target }
        set { motion.target = newValue }
    }
    /// Let go: gliding into place, the order already changed.
    @Published private(set) var isSettling = false
    /// The siblings' laid-out frames, by key, from the list
    /// (`PaneSidebarItemFrames`): only while a drag is on.
    private(set) var frames: [String: CGRect] = [:]

    /// The pointer's distance below the item's top when it was grabbed:
    /// known once the list first reports its frames, which it does only
    /// while a drag is on.
    private var grab: CGFloat?
    /// The pointer, in the sidebar's space.
    private var pointer: CGFloat = 0
    /// Where the item's top was when it was grabbed.
    private var grabbedTop: CGFloat = -.infinity
    /// Settling: where the item is laid out after the move. Its frame is
    /// only re-read a pass later, and drawing it from the old one for that
    /// pass would flash it at the wrong place. On `motion`, so letting go
    /// redraws the items in the pass that reorders them: otherwise they keep
    /// their slide and lift for that pass, the dragged one a slot past its
    /// place and the one it passed slid up under the header above.
    private var landed: CGFloat? {
        get { motion.landed }
        set { motion.landed = newValue }
    }
    /// Settling: the glide has not started yet. It waits for the new order
    /// to be laid out (`framesChanged`): started any earlier, the pass that
    /// lays it out would run inside the glide's animation, and every item
    /// would ease out of its old slide rather than stand where it was drawn.
    private var awaitsGlide = false
    /// The group folds to put back after a group drag.
    private var foldsBefore: Set<String>?
    /// The open windows to put back after a window drag.
    private var unfoldedBefore: Set<UUID>?
    private var generation = 0

    static let settleDuration: TimeInterval = PaneSidebarRowDrag.settleDuration
    static let settleAnimation: Animation = PaneSidebarRowDrag.settleAnimation

    var isDragging: Bool { key != nil }

    /// Whether `controller`'s list is the one being dragged in.
    func isDragging(in controller: BaseTerminalController) -> Bool {
        key != nil && self.controller === controller
    }

    /// The dragged item's offset from where it is laid out.
    func liftOffset(_ key: String) -> CGFloat? {
        guard key == self.key else { return nil }
        guard grab != nil, let laidOut = landed ?? frames[key]?.minY else { return 0 }
        return top - laidOut
    }

    /// How far sibling `key` slides to make room, in points.
    func shift(_ key: String) -> CGFloat {
        guard let dragged = self.key, key != dragged, !isSettling,
              let source = siblings.firstIndex(of: dragged),
              let index = siblings.firstIndex(of: key)
        else { return 0 }
        let rows = PaneSidebarOrder.shift(index: index, source: source, target: target)
        return CGFloat(rows) * PaneSidebarItemReorder.pitch(dragged: source, frames: siblingFrames)
    }

    /// The siblings' frames, in order. A lazy list lays out only what is
    /// near the viewport: a sibling it has not laid out stands in at the far
    /// end it is on, so it counts as passed (above) or not (below).
    private var siblingFrames: [CGRect] {
        let known = siblings.indices.filter { frames[siblings[$0]] != nil }
        guard let first = known.first else { return siblings.map { _ in .zero } }
        return siblings.indices.map { index in
            frames[siblings[index]]
                ?? CGRect(x: 0, y: index < first ? -Self.farAway : Self.farAway, width: 0, height: 0)
        }
    }

    private static let farAway: CGFloat = 1_000_000

    /// The laid-out siblings only, for the span the item is kept in.
    private var knownFrames: [CGRect] {
        siblings.compactMap { frames[$0] }
    }

    // MARK: Lifecycle

    /// Grab `key` in `controller`'s list, among `siblings`, the pointer at
    /// `screenY`.
    func begin(_ key: String, siblings: [String], in controller: BaseTerminalController, screenY: CGFloat) {
        guard siblings.contains(key), let y = controller.paneSidebarHost?.sidebarY(screenY: screenY) else { return }
        generation += 1
        self.key = key
        self.siblings = siblings
        self.controller = controller
        isSettling = false
        landed = nil
        grab = nil
        frames = [:]
        target = siblings.firstIndex(of: key)
        pointer = y
        HoverTrackingView.isHeld = true
    }

    func move(screenY: CGFloat) {
        guard key != nil, !isSettling, let y = controller?.paneSidebarHost?.sidebarY(screenY: screenY) else { return }
        pointer = y
        relayout()
    }

    /// The list reports its items' laid-out frames.
    func framesChanged(_ frames: [String: CGRect]) {
        guard let key, frames != self.frames else { return }
        self.frames = frames
        if isSettling {
            // The item's new place is laid out: measure from it (the glide
            // is already heading there).
            if let frame = frames[key] { landed = frame.minY }
            // Reported mid-update, before that layout is on screen: glide
            // from the next turn, once it is.
            let generation = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.glide()
            }
            return
        }
        if grab == nil, let frame = frames[key], let controller {
            // First frames: where in the item it was grabbed — before a
            // group drag folds the groups and moves it.
            grab = pointer - frame.minY
            top = frame.minY
            grabbedTop = frame.minY
            let shared = controller.paneSidebarState.shared
            if key.hasPrefix(PaneSidebarWindowGrouping.key(project: "")) {
                foldAllGroups(of: siblings, in: shared)
            } else {
                foldAllWindows(in: shared)
            }
        }
        relayout()
    }

    /// The pointer or the layout moved: the item follows the pointer, kept
    /// in its list, and the index follows the item.
    private func relayout() {
        // Before the list has reported its frames there is nothing to place
        // against: hold still.
        guard let key, let grab, let dragged = siblings.firstIndex(of: key),
              let frame = self.frames[key] else { return }
        let frames = siblingFrames
        let known = knownFrames
        let top = PaneSidebarItemReorder.clamp(
            top: pointer - grab, dragged: known.firstIndex(of: frame) ?? 0, frames: known, grabbed: grabbedTop)
        if top != self.top { self.top = top }
        let target = PaneSidebarItemReorder.target(top: top, dragged: dragged, frames: frames)
        if target != self.target { self.target = target }
    }

    /// Let go — or, with `commit` false, cancelled (Escape): the order
    /// changes (every window's list), and the item glides from the pointer to
    /// its place. A group drag's folds come back once it has landed.
    func end(commit: Bool) {
        guard let key, let controller, !isSettling,
              let source = siblings.firstIndex(of: key)
        else { return reset() }
        let frames = siblingFrames
        let target = commit && grab != nil ? (self.target ?? source) : source
        let landing = PaneSidebarItemReorder.landingTop(dragged: source, target: target, frames: frames)
        // One pass: the new order laid out, the item still drawn at the
        // pointer (`landed`), the others no longer slid.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSettling = true
            awaitsGlide = true
            landed = landing
            if target != source { controller.placeInAllWindowsList(key, at: target, among: siblings) }
        }
        // Unmoved, nothing new is laid out to wait for: the others only slide
        // back, which may as well ease with it. Moved, a list that never
        // reports its new layout (gone mid-drop) must not hold the drag.
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + (target == source ? 0 : Self.settleDuration)) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.glide()
        }
    }

    /// Settling, once its new place is laid out: glide the item from where
    /// it was let go to there, then end the drag.
    private func glide() {
        guard awaitsGlide, let landed else { return }
        awaitsGlide = false
        withAnimation(Self.settleAnimation) { top = landed }
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.reset()
        }
    }

    private func reset() {
        let folds = foldsBefore
        let unfolded = unfoldedBefore
        let shared = controller?.paneSidebarState.shared
        key = nil
        siblings = []
        controller = nil
        target = nil
        isSettling = false
        awaitsGlide = false
        landed = nil
        frames = [:]
        grab = nil
        grabbedTop = -.infinity
        foldsBefore = nil
        unfoldedBefore = nil
        HoverTrackingView.isHeld = false
        if let folds, let shared {
            withAnimation(PaneSidebarOutline.foldAnimation) { shared.foldedProjects = folds }
        }
        if let unfolded, let shared {
            withAnimation(PaneSidebarOutline.foldAnimation) { shared.unfoldedWindows = unfolded }
        }
    }

    /// A window is being dragged: fold every window to its row, so each is
    /// one row high and easy to place, remembering which were open.
    private func foldAllWindows(in shared: PaneSidebarSharedState) {
        unfoldedBefore = shared.unfoldedWindows
        guard !shared.unfoldedWindows.isEmpty else { return }
        withAnimation(PaneSidebarOutline.foldAnimation) { shared.unfoldedWindows = [] }
    }

    /// A group is being dragged: fold every group, so each is one header
    /// high, remembering how they were.
    private func foldAllGroups(of siblings: [String], in shared: PaneSidebarSharedState) {
        let prefix = PaneSidebarWindowGrouping.key(project: "")
        let projects = Set(siblings.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        foldsBefore = shared.foldedProjects
        withAnimation(PaneSidebarOutline.foldAnimation) {
            shared.foldedProjects.formUnion(projects)
        }
    }
}

extension BaseTerminalController {
    /// Every window with a sidebar, as the all-windows list lists them:
    /// this one included even before it is visible.
    var paneSidebarAllControllers: [BaseTerminalController] {
        let controllers = PaneRoster.shared.controllers
        return controllers.contains { $0 === self } ? controllers : [self] + controllers
    }

    /// The all-windows list's sections, in its order, unfiltered.
    var paneSidebarSections: [PaneSidebarWindowGrouping.Section<UUID>] {
        let titled = paneSidebarAllControllers.map {
            (id: $0.paneSidebarState.windowID, title: PaneSidebarText.windowTitle(of: $0))
        }
        return PaneSidebarWindowGrouping.sections(titled, order: paneSidebarState.shared.windowOrder)
    }

    /// Put the window or group `key` at `index` of `siblings` (the list it
    /// was dragged in, without it) in the all-windows list — every window's,
    /// since the order is shared. The list only: nothing moves on screen.
    func placeInAllWindowsList(_ key: String, at index: Int, among siblings: [String]) {
        let shared = paneSidebarState.shared
        let order = PaneSidebarOrder.moving(
            key, to: index, visible: siblings, order: shared.windowOrder,
            existing: PaneSidebarWindowGrouping.keys(paneSidebarSections))
        if order != shared.windowOrder { shared.windowOrder = order }
    }
}

/// `PaneSidebarItemDrag`'s per-pointer-move state.
@MainActor
final class PaneSidebarItemDragMotion: ObservableObject {
    @Published fileprivate(set) var top: CGFloat = 0
    @Published fileprivate(set) var target: Int?
    @Published fileprivate(set) var landed: CGFloat?
}

// MARK: - Drag source

/// A window row's or project header's AppKit half: click and drag. The
/// header's own controls (its disclosure chevron, its ×) sit OUTSIDE it,
/// since an AppKit view out-hit-tests any SwiftUI control drawn over it.
///
/// It owns mouseDown, which keeps the window's own drag handler out of it,
/// and the drag is its own mouse tracking: an item moves only within its
/// list, so there is nothing for an `NSDraggingSession` to carry.
final class PaneSidebarItemDragView: HoverTrackingView {
    var onClick: (() -> Void)?
    /// The drag began (past `PaneDragSourceView.dragThreshold`), at a screen y.
    var onBegin: ((CGFloat) -> Void)?
    var onMove: ((CGFloat) -> Void)?
    var onEnd: ((Bool) -> Void)?

    private var downLocation: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downLocation, let window else { return }
        let moved = hypot(event.locationInWindow.x - downLocation.x, event.locationInWindow.y - downLocation.y)
        guard moved >= PaneDragSourceView.dragThreshold else { return }
        self.downLocation = nil
        // From here the drag is the tracker's: an app-wide event feed that
        // outlives this view, which the list may re-create mid-drag.
        PaneSidebarItemDragTracker.start(onMove: onMove ?? { _ in }, onEnd: onEnd ?? { _ in })
        onBegin?(window.convertPoint(toScreen: downLocation).y)
        onMove?(window.convertPoint(toScreen: event.locationInWindow).y)
    }

    override func mouseUp(with event: NSEvent) {
        // A press that never became a drag is a click.
        if downLocation != nil { onClick?() }
        downLocation = nil
    }
}

/// The pointer feed of a window row's or project header's drag: local event
/// monitors for the drag, the release and Escape, so the drag goes on even
/// if the view it started in is re-created or scrolled away mid-drag.
@MainActor
private enum PaneSidebarItemDragTracker {
    private static var monitor: Any?

    static func start(onMove: @escaping (CGFloat) -> Void, onEnd: @escaping (Bool) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { event in
            switch event.type {
            case .leftMouseDragged:
                let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
                    ?? NSEvent.mouseLocation
                onMove(point.y)
                return nil
            case .leftMouseUp:
                stop()
                onEnd(true)
                return nil
            case .keyDown where event.keyCode == 53: // Escape
                stop()
                onEnd(false)
                return nil
            default:
                return event
            }
        }
    }

    static func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// `PaneSidebarItemDragView` for SwiftUI.
struct PaneSidebarItemDragSource: NSViewRepresentable {
    let key: String
    let siblings: [String]
    let controller: BaseTerminalController
    let help: String
    let onClick: () -> Void

    func makeNSView(context: Context) -> PaneSidebarItemDragView {
        let view = PaneSidebarItemDragView()
        configure(view)
        return view
    }

    func updateNSView(_ view: PaneSidebarItemDragView, context: Context) {
        configure(view)
    }

    private func configure(_ view: PaneSidebarItemDragView) {
        let (key, siblings, controller) = (key, siblings, controller)
        view.toolTip = help
        view.onClick = onClick
        view.onBegin = { y in
            PaneSidebarItemDrag.shared.begin(key, siblings: siblings, in: controller, screenY: y)
        }
        view.onMove = { y in PaneSidebarItemDrag.shared.move(screenY: y) }
        view.onEnd = { commit in PaneSidebarItemDrag.shared.end(commit: commit) }
    }
}

extension View {
    /// Makes a window row or project header clickable and draggable
    /// everywhere but its leading `leading` and trailing `trailing` points,
    /// where its own controls are.
    func paneSidebarItemDrag(
        key: String,
        siblings: [String],
        controller: BaseTerminalController,
        leading: CGFloat,
        trailing: CGFloat,
        help: String,
        onClick: @escaping () -> Void
    ) -> some View {
        modifier(PaneSidebarItemDragOverlay(
            key: key, siblings: siblings, controller: controller,
            leading: leading, trailing: trailing, help: help, onClick: onClick))
    }
}

private struct PaneSidebarItemDragOverlay: ViewModifier {
    let key: String
    let siblings: [String]
    let controller: BaseTerminalController
    let leading: CGFloat
    let trailing: CGFloat
    let help: String
    let onClick: () -> Void

    @Environment(\.paneSidebarInteractive) private var isInteractive

    func body(content: Content) -> some View {
        content.overlay {
            if isInteractive {
                HStack(spacing: 0) {
                    Color.clear.frame(width: leading).allowsHitTesting(false)
                    PaneSidebarItemDragSource(
                        key: key, siblings: siblings, controller: controller, help: help, onClick: onClick)
                    Color.clear.frame(width: trailing).allowsHitTesting(false)
                }
            }
        }
    }
}

/// A window or group of the all-windows list while one of them is dragged:
/// the dragged one drawn where the pointer has it, lifted over the rest; the
/// others slid to make room (`PaneSidebarItemDrag.shift`) — a short bounded
/// animation, none once it lands, as `PaneSidebarShift`.
///
/// It observes the drag's `motion`, so a pointer move redraws the items, not
/// the list around them.
///
/// It also reports the item's frame AS LAID OUT (`PaneSidebarItemFrames`),
/// from outside its offset, and raises the dragged one OUTERMOST — a z-index
/// under other modifiers does not reach its siblings.
struct PaneSidebarItemShift: ViewModifier {
    let key: String
    let drag: PaneSidebarItemDrag
    @ObservedObject private var motion: PaneSidebarItemDragMotion
    let isActive: Bool
    /// Lifted, it is drawn over a solid backing and a shadow: a window, so
    /// it reads as on top of the rows it passes. Not a group's parts — its
    /// header is already its own glass band, and its gaps are empty space.
    var showsBacking: Bool

    init(key: String, drag: PaneSidebarItemDrag, isActive: Bool, showsBacking: Bool = true) {
        self.key = key
        self.drag = drag
        self.motion = drag.motion
        self.isActive = isActive
        self.showsBacking = showsBacking
    }

    func body(content: Content) -> some View {
        let lift = isActive ? drag.liftOffset(key) : nil
        let slide = isActive ? drag.shift(key) : 0
        let isLifted = lift != nil && !drag.isSettling && showsBacking
        content
            .background {
                if isLifted {
                    // Solid under the glass while it is held, so it reads as
                    // on top of what it passes rather than mixed with it.
                    RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                        .overlay(
                            RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.06)))
                        .padding(.horizontal, SidePanelRow.fillInset)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                        .transition(.opacity)
                }
            }
            .offset(y: lift ?? slide)
            .animation(isActive && lift == nil && !drag.isSettling ? PaneSidebarShift.animation : nil, value: slide)
            .paneSidebarItemFrame(key, isOn: isActive)
            .zIndex(lift != nil ? 1 : 0)
    }
}

/// Window and group frames in the all-windows list, by key, as laid out:
/// reported only while one is dragged, from a reader attached OUTSIDE the
/// item's slide, as the pane rows' are.
struct PaneSidebarItemFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        // A group is its header and its windows, reported apart: one rect.
        value.merge(nextValue()) { $0.union($1) }
    }
}

extension View {
    /// Reports this view's frame under `key` while `isOn`.
    @ViewBuilder
    func paneSidebarItemFrame(_ key: String, isOn: Bool) -> some View {
        background {
            if isOn {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PaneSidebarItemFrames.self,
                        value: [key: proxy.frame(in: .named(PaneSidebarGeometry.space))])
                }
            }
        }
    }
}

// MARK: - Scroll position

/// The all-windows list's scroll position, shared by every window. Kept
/// cheap: scrolling a list only records where it is (the last list scrolled
/// wins); a list takes it up when its window becomes key, or when it
/// appears (switched to, expanded, a new window). Nothing moves in the
/// window in use, and no other window scrolls along frame by frame.
///
/// The rail and the panel lay the list out differently (no project headers
/// in the rail), so each keeps its own position. "This window" lists differ
/// window to window, so they are not synced at all.
@MainActor
final class PaneSidebarScrollSync {
    static let shared = PaneSidebarScrollSync()

    private var offsets: [Bool: CGFloat] = [:]

    func offset(isRail: Bool) -> CGFloat { offsets[isRail] ?? 0 }

    fileprivate func scrolled(isRail: Bool, to y: CGFloat) {
        offsets[isRail] = y
    }
}

/// Inside the all-windows list's scroll view: reports its scrolling and
/// applies the others' (`PaneSidebarScrollSync`).
final class PaneSidebarScrollSyncView: NSView {
    var isRail = false
    private weak var clipView: NSClipView?
    private var observers: [NSObjectProtocol] = []
    private var isApplying = false

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window, let clip = enclosingScrollView?.contentView else { return }
        clipView = clip
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            // After the list has caught up (`PaneSidebarState.catchUp`) and
            // laid out, so the position is measured against the list as it
            // now is: a row clicked in another window lands in the same spot.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.catchUp() }
            }
        })
        // Appearing: start where the others are, once laid out.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.catchUp() }
        }
    }

    private func boundsChanged() {
        guard !isApplying, let clip = clipView else { return }
        PaneSidebarScrollSync.shared.scrolled(isRail: isRail, to: clip.bounds.origin.y)
    }

    /// Go to where the lists are.
    func catchUp() {
        apply(PaneSidebarScrollSync.shared.offset(isRail: isRail))
    }

    /// Scroll to `y`, clamped to the list.
    func apply(_ y: CGFloat) {
        guard let clip = clipView, let scrollView = enclosingScrollView,
              let document = scrollView.documentView else { return }
        let maxY = Swift.max(0, document.frame.height - clip.bounds.height)
        let target = Swift.min(Swift.max(y, 0), maxY)
        guard abs(clip.bounds.origin.y - target) > 0.5 else { return }
        isApplying = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        isApplying = false
    }

    /// The scroll view's position, for tests.
    var scrollOffset: CGFloat? { clipView?.bounds.origin.y }
}

/// `PaneSidebarScrollSyncView` for SwiftUI.
struct PaneSidebarScrollSyncAnchor: NSViewRepresentable {
    let isRail: Bool

    func makeNSView(context: Context) -> PaneSidebarScrollSyncView {
        let view = PaneSidebarScrollSyncView()
        view.isRail = isRail
        return view
    }

    func updateNSView(_ view: PaneSidebarScrollSyncView, context: Context) {
        view.isRail = isRail
    }
}
