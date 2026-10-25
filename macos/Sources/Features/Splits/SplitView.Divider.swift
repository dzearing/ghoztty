import SwiftUI

/// The AppKit grab handle for a split divider. The panes host AppKit views
/// (terminal surfaces, WKWebViews) that win hit-testing over any SwiftUI
/// gesture area, so the drag target must itself be an NSView layered above
/// them. Placed by SplitView over the divider line, spanning the visible
/// line plus a few points of grab zone on each side.
struct DividerHandle: NSViewRepresentable {
    let direction: SplitViewDirection
    /// Called on mouse-down, before the divider has moved at all.
    let onDragBegan: () -> Void
    /// Called during a drag with (cumulative delta in points, split at drag start).
    let onDragDelta: (CGFloat, CGFloat) -> Void
    /// Called when a drag finishes. Not called for a double-click.
    let onDragEnded: () -> Void
    /// Called on a double-click. When nil a double-click is treated as an
    /// ordinary drag, which is what a divider with nothing to reset to wants.
    let onDoubleClick: (() -> Void)?
    /// Called when the pointer enters or leaves the grab zone, for dividers that
    /// highlight on hover. The handle owns the cursor (see `resetCursorRects`),
    /// so it is also the honest source of "is the pointer on the target".
    var onHoverChanged: ((Bool) -> Void)? = nil
    /// Reads the current split fraction (captured at mouse-down).
    let currentSplit: () -> CGFloat
    /// Follow the drag to mouse-up even if this handle leaves the window
    /// mid-drag — a pane grid's divider does, when the drag collapses its row
    /// into a stack — so the gesture carries on (and can be undone) instead of
    /// stopping dead.
    var tracksModally: Bool = false

    func makeNSView(context: Context) -> DividerHandleView {
        let view = DividerHandleView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DividerHandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DividerHandleView) {
        view.direction = direction
        view.onDragBegan = onDragBegan
        view.onDragDelta = onDragDelta
        view.onDragEnded = onDragEnded
        view.onDoubleClick = onDoubleClick
        view.onHoverChanged = onHoverChanged
        view.currentSplit = currentSplit
        view.tracksModally = tracksModally
    }

    final class DividerHandleView: NSView, GutterBarOwner {
        var direction: SplitViewDirection = .horizontal
        var onDragBegan: (() -> Void)?
        var onDragDelta: ((CGFloat, CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        var currentSplit: (() -> CGFloat)?
        var tracksModally = false

        private var dragOrigin: CGPoint?
        private var dragStartSplit: CGFloat = 0.5

        /// What a person can drag shows itself (`GutterBar`).
        lazy var gutterBar = GutterBar(in: self)
        private var bar: GutterBar { gutterBar }
        static var barThickness: CGFloat { GutterBar.thickness }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            _ = bar
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Whether a bar shows, for tests.
        var showsBar: Bool { bar.shows }

        /// Where the bar that shows is, in window coordinates, for tests.
        var barInWindow: CGRect? { bar.inWindow }

        /// Whether the tracking area assumes the pointer inside, for tests.
        var trackingAssumesInside: Bool { bar.trackingAssumesInside }

        override func mouseEntered(with event: NSEvent) {
            bar.pointerEntered()
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            bar.pointerExited()
            onHoverChanged?(false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bar.noteWindow()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            bar.moved()
        }

        override func layout() {
            super.layout()
            bar.axis = direction
            bar.layout()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            bar.layout()
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                dragOrigin = nil
                onDoubleClick()
                return
            }
            dragOrigin = event.locationInWindow
            dragStartSplit = currentSplit?() ?? 0.5
            bar.axis = direction
            bar.beginDrag()
            onDragBegan?()
            guard tracksModally, let window else { return }
            // Our own loop, holding the window: AppKit sends drag events to
            // the view that took mouse-down only while it is in the window.
            let cursor: NSCursor = direction == .horizontal ? .resizeLeftRight : .resizeUpDown
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                cursor.set()
                if next.type == .leftMouseUp {
                    mouseUp(with: next)
                    break
                }
                mouseDragged(with: next)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragOrigin else { return }
            let location = event.locationInWindow
            // Window coordinates are y-up; a downward drag grows a vertical
            // split's top pane, so flip the vertical delta.
            let delta: CGFloat = switch direction {
            case .horizontal: location.x - dragOrigin.x
            case .vertical: dragOrigin.y - location.y
            }
            onDragDelta?(delta, dragStartSplit)
            bar.drag(to: location)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragOrigin != nil else { return }
            dragOrigin = nil
            bar.endDrag(at: event.locationInWindow)
            onDragEnded?()
        }

        override func resetCursorRects() {
            addCursorRect(
                bounds,
                cursor: direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }
}

extension SplitView {
    /// The split divider that is rendered and can be used to resize a split view.
    struct Divider: View {
        let direction: SplitViewDirection
        let visibleSize: CGFloat
        let invisibleSize: CGFloat
        let color: Color
        let split: CGFloat
        /// Called with the divider's new fractional position when it is adjusted
        /// from the keyboard via accessibility.
        let onAdjust: (CGFloat) -> Void

        private var visibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize
            case .vertical:
                return nil
            }
        }

        private var visibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize
            }
        }

        private var invisibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize + invisibleSize
            case .vertical:
                return nil
            }
        }

        private var invisibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize + invisibleSize
            }
        }

        private var pointerStyle: BackportPointerStyle {
            return switch direction {
            case .horizontal: .resizeLeftRight
            case .vertical: .resizeUpDown
            }
        }

        var body: some View {
            ZStack {
                Color.clear
                    .frame(width: invisibleWidth, height: invisibleHeight)
                    .contentShape(Rectangle()) // Makes it hit testable for pointerStyle
                Rectangle()
                    .fill(color)
                    .frame(width: visibleWidth, height: visibleHeight)
            }
            .backport.pointerStyle(pointerStyle)
            .onHover { isHovered in
                // macOS 15+ we use the pointerStyle helper which is much less
                // error-prone versus manual NSCursor push/pop
                if #available(macOS 15, *) {
                    return
                }

                if isHovered {
                    switch direction {
                    case .horizontal:
                        NSCursor.resizeLeftRight.push()
                    case .vertical:
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(axLabel)
            .accessibilityValue("\(Int(split * 100))%")
            .accessibilityHint(axHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                let adjustment: CGFloat = 0.025
                switch direction {
                case .increment:
                    onAdjust(min(split + adjustment, 0.9))
                case .decrement:
                    onAdjust(max(split - adjustment, 0.1))
                @unknown default:
                    break
                }
            }
        }

        private var axLabel: String {
            switch direction {
            case .horizontal:
                return "Horizontal split divider"
            case .vertical:
                return "Vertical split divider"
            }
        }

        private var axHint: String {
            switch direction {
            case .horizontal:
                return "Drag to resize the left and right panes"
            case .vertical:
                return "Drag to resize the top and bottom panes"
            }
        }
    }
}

/// A view that owns a draggable gutter's `GutterBar`.
@MainActor
protocol GutterBarOwner: NSView {
    var gutterBar: GutterBar { get }
}

/// What a draggable gutter shows (a split divider, a stack grip, a side
/// panel's edge): a bar down its middle, with a soft glow, while the pointer
/// is over it — and while it drags, at the edge it is dragging, which stops
/// where the edge stops (a pane's minimum, a panel's maximum, a strip that
/// has not come out yet) rather than running ahead with the pointer. The
/// gutter alone gave no sign it could be taken.
@MainActor
final class GutterBar {
    static let thickness: CGFloat = 4

    /// The bar of the drag under way, if any: one bar at a time. A gutter
    /// that appears under the pointer mid-drag (a strip's pane going back
    /// brings its grip back) showed its own hover bar beside the drag's.
    private static weak var active: GutterBar?

    /// Along which axis the gutter is dragged.
    var axis: SplitViewDirection = .horizontal

    var isHovered = false { didSet { show() } }

    private unowned let view: NSView
    /// The view's mouse-entered/exited tracking — during a drag too: a gutter
    /// under the pointer when the mouse comes up must know it is.
    private var trackingArea: NSTrackingArea?
    /// Whether AppKit takes the pointer to be inside the tracking area. It
    /// only sends mouse-exited when it does, so a hover found from geometry
    /// (`noteWindow`) that AppKit does not agree with re-arms the area, or
    /// the bar stays lit once the pointer leaves.
    private var trackedInside = false
    private let hover = CALayer()
    /// The bar while a drag is under way, drawn on the window rather than on
    /// the view: a drag can take its view out of the window (a grip whose
    /// pane comes out is replaced by the split's divider) and goes on
    /// without it.
    private let dragging = CALayer()
    private weak var dragWindow: NSWindow?
    /// The gutter, in window coordinates, as the drag found it.
    private var span: CGRect = .zero
    /// The gutter the drag is moving: this one, or — once a drag has
    /// replaced it — the one that took its place.
    private weak var tracked: NSView?
    /// Where the pointer is, in window coordinates.
    private var pointer: CGPoint = .zero
    /// Where the bar was last drawn along the axis, in window coordinates.
    private var lastBar: CGFloat?
    /// The drag's window's pane stage, found once per drag.
    private weak var stage: PaneStageView?

    init(in view: NSView) {
        self.view = view
        view.wantsLayer = true
        for layer in [hover, dragging] {
            layer.cornerRadius = Self.thickness / 2
            layer.shadowOffset = .zero
            layer.shadowRadius = 5
            layer.shadowOpacity = 0.9
        }
        hover.opacity = 0
        view.layer?.addSublayer(hover)
        track(assumingInside: false)
        // Above every layer AppKit puts beside it on the window, whatever
        // order it puts them in: the panes' layers, re-sorted as a card
        // slides out or back, covered the bar mid-drag.
        dragging.zPosition = 10_000
    }

    var shows: Bool { hover.opacity > 0 || dragging.superlayer != nil }

    var trackingAssumesInside: Bool { trackingArea?.options.contains(.assumeInside) ?? false }

    /// The bar that shows, in window coordinates.
    var inWindow: CGRect? {
        if dragging.superlayer != nil, let host = dragWindow?.contentView?.superview {
            return host.convert(dragging.frame, to: nil)
        }
        return hover.opacity > 0 ? view.convert(hover.frame, to: nil) : nil
    }

    /// Where the pointer is, in the window's coordinates. A test, whose
    /// events are synthetic, says where its pointer is instead of the real
    /// one, which it cannot place.
    static var pointerOverride: CGPoint?

    /// A gutter that appears under the pointer (a drag just brought a pane
    /// out beside it) gets no mouse-entered: it is hovered all the same.
    func noteWindow() {
        guard let window = view.window else { return }
        let pointer = Self.pointerOverride ?? window.mouseLocationOutsideOfEventStream
        isHovered = view.bounds.contains(view.convert(pointer, from: nil))
        // A drag's end finds the pointer on the gutter it let go of, just as
        // AppKit sends that gutter a late mouse-exited: hovered by geometry,
        // outside by AppKit, which then never sends the exit that would put
        // the bar out. An area that assumes the pointer inside sends it.
        if isHovered != trackedInside { track(assumingInside: isHovered) }
    }

    /// AppKit's mouse-entered and mouse-exited, from the owner.
    func pointerEntered() {
        trackedInside = true
        isHovered = true
    }

    func pointerExited() {
        trackedInside = false
        isHovered = false
    }

    private func track(assumingInside inside: Bool) {
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        var options: NSTrackingArea.Options = [
            .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .enabledDuringMouseDrag,
        ]
        if inside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: view, userInfo: nil)
        view.addTrackingArea(area)
        trackingArea = area
        trackedInside = inside
    }

    /// The gutter moved in its window (AppKit recomputes a view's tracking
    /// areas when it does — `updateTrackingAreas`): a gutter that moves out
    /// from under a still pointer gets no mouse-exited, and stayed lit as if
    /// a drag were still going on. Not while one is.
    func moved() {
        guard Self.active == nil else { return }
        noteWindow()
    }

    /// Down the middle of the gutter.
    func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paint(hover)
        let b = view.bounds, t = Self.thickness
        hover.frame = switch axis {
        case .horizontal: CGRect(x: b.midX - t / 2, y: 0, width: t, height: b.height)
        case .vertical: CGRect(x: 0, y: b.midY - t / 2, width: b.width, height: t)
        }
        CATransaction.commit()
    }

    func beginDrag() {
        Self.active = self
        dragWindow = view.window
        tracked = view
        span = view.convert(view.bounds, to: nil)
        pointer = CGPoint(x: span.midX, y: span.midY)
        lastBar = nil
        show()
        place()
    }

    /// The pointer moved to `point` (window coordinates): the bar goes to
    /// the edge as the step left it — now, and again once the layout has
    /// caught up with the step.
    func drag(to point: CGPoint) {
        pointer = point
        place()
        RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.place() }
    }

    /// `point`: where the pointer let go, in window coordinates.
    func endDrag(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragging.removeFromSuperlayer()
        CATransaction.commit()
        if Self.active === self { Self.active = nil }
        let window = dragWindow
        dragWindow = nil
        tracked = nil
        // Which gutter the pointer is over is asked again of every one in
        // the window, now and once the layout has caught up with the drag:
        // a gutter that came under the pointer mid-drag, or moved out from
        // under it, would otherwise keep a hover it no longer has, and look
        // as if the drag were still going on.
        isHovered = view.window != nil && view.bounds.contains(view.convert(point, from: nil))
        Self.recheckHover(in: window)
        RunLoop.main.perform(inModes: [.common]) { Self.recheckHover(in: window) }
    }

    /// The window's pane stage, if it has one.
    private static func stage(in host: NSView) -> PaneStageView? {
        if let stage = host as? PaneStageView { return stage }
        for sub in host.subviews {
            if let stage = stage(in: sub) { return stage }
        }
        return nil
    }

    private static func recheckHover(in window: NSWindow?) {
        guard let host = window?.contentView?.superview else { return }
        func walk(_ v: NSView) {
            (v as? GutterBarOwner)?.gutterBar.noteWindow()
            v.subviews.forEach(walk)
        }
        walk(host)
    }

    /// The cards moved under the drag on their own (a glide): put the bar
    /// back over its gutter.
    static func refreshActive() {
        active?.place()
    }

    /// At the middle of the gutter being dragged, across the gutter the drag
    /// began on — where it is drawn: mid-glide, the cards beside it are still
    /// on their way to where the layout puts them (`PaneStageView.shownGutter`).
    private func place() {
        guard dragWindow != nil, let host = dragWindow?.contentView?.superview else { return }
        if tracked?.window !== dragWindow { tracked = replacement(in: host) }
        guard let tracked else { return }
        let laidOut = tracked.convert(tracked.bounds, to: nil)
        if stage?.window !== dragWindow { stage = Self.stage(in: host) }
        let edge = stage?.shownGutter(laidOut, horizontal: axis == .horizontal) ?? laidOut
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if dragging.superlayer == nil {
            paint(dragging)
            host.layer?.addSublayer(dragging)
        }
        let t = Self.thickness
        let rect = switch axis {
        case .horizontal: CGRect(x: edge.midX - t / 2, y: span.minY, width: t, height: span.height)
        case .vertical: CGRect(x: span.minX, y: edge.midY - t / 2, width: span.width, height: t)
        }
        dragging.frame = host.convert(rect, from: nil)
        lastBar = axis == .horizontal ? edge.midX : edge.midY
        CATransaction.commit()
    }

    /// The gutter of the same kind, along the same axis and across the same
    /// span, that a drag put in place of the one it began on: the nearest to
    /// where the bar was, among those that lie the way the drag is going —
    /// a gutter that snaps (a pane tucking away) moves that way. Nearest the
    /// pointer, it took the gutter beside the one that snapped, which the
    /// pointer had come closer to.
    private func replacement(in host: NSView) -> NSView? {
        var found: [NSView] = []
        func walk(_ v: NSView) {
            if type(of: v) == type(of: view), !v.isHiddenOrHasHiddenAncestor,
               let owner = v as? GutterBarOwner, owner.gutterBar.axis == axis {
                found.append(v)
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        let toward = axis == .horizontal ? pointer.x : pointer.y
        let from = lastBar ?? toward
        func place(_ v: NSView) -> CGFloat? {
            let r = v.convert(v.bounds, to: nil)
            switch axis {
            case .horizontal:
                guard r.maxY > span.minY, r.minY < span.maxY else { return nil }
                return r.midX
            case .vertical:
                guard r.maxX > span.minX, r.minX < span.maxX else { return nil }
                return r.midY
            }
        }
        let placed = found.compactMap { v in place(v).map { (v, $0) } }
        let ahead = placed.filter { ($0.1 - from) * (toward - from) >= 0 }
        return (ahead.isEmpty ? placed : ahead).min { abs($0.1 - from) < abs($1.1 - from) }?.0
    }

    private func show() {
        // Half strength on hover; the drag's bar is the full one.
        hover.opacity = isHovered && Self.active == nil ? 0.5 : 0
    }

    private func paint(_ layer: CALayer) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.controlAccentColor.cgColor
            layer.backgroundColor = color
            layer.shadowColor = color
        }
    }
}
