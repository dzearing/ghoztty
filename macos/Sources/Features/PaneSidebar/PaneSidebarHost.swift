import AppKit
import Combine
import SwiftUI

/// Lays out a terminal window's grid beside its pane sidebar.
///
/// The sidebar's COLUMN is a fixed-width spacer in front of the grid; the
/// sidebar itself is drawn in an overlay, which reaches past the column only
/// over the gutter its resize grip lies in. Only collapse/expand and
/// hide/show change the column — and so resize the window's terminals.
struct PaneSidebarContainer<Content: View>: View {
    @ObservedObject var state: PaneSidebarState
    let controller: BaseTerminalController
    @ViewBuilder let content: Content

    @State private var windowWidth: CGFloat = PaneSidebarState.narrowWindowWidth

    var body: some View {
        let mode = state.mode(windowWidth: windowWidth)
        let elevated = controller.ghostty.config.macosPaneStyle == .elevated
        let column = PaneSidebarState.columnWidth(for: mode, panelWidth: state.width, elevated: elevated)

        HStack(spacing: 0) {
            if mode != .hidden {
                Color.clear
                    .frame(width: column)
                    .accessibilityHidden(true)
            }
            content
        }
        // No SwiftUI animation on the column: the grid moves over by gliding
        // its cards (`PaneStackState.noteColumnShift`), each terminal resized
        // once, after the motion — never once per animation frame.
        .transaction { $0.animation = nil }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { windowWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { windowWidth = $0 }
        })
        .overlay(alignment: .topLeading) {
            if mode != .hidden {
                // The frame reaches past the column over the gutter its
                // resize grip lies in (`edgeGrip`): AppKit never hit-tests
                // the part of a view outside its parent's bounds. It is as
                // wide as the expanded panel needs in EITHER mode, and never
                // animated: the card glides inside it (`PaneSidebarCardGlide`).
                // Sized to the mode, SwiftUI animated its frame — origin and
                // all — on a collapse, and the card, its contents and the
                // grip swung off to the left and back. `hitTest` limits what
                // takes clicks to the card and its grip; the rest of it is
                // see-through and passes them to the grid.
                PaneSidebarHostRepresentable(
                    controller: controller, state: state, mode: mode,
                    canExpand: PaneSidebarState.canExpand(windowWidth: windowWidth))
                    .frame(width: PaneSidebarState.hostWidth(panelWidth: state.width, elevated: elevated))
                    .transaction { $0.animation = nil }
                    .frame(maxHeight: .infinity)
                    // Up beside the tab bar, which then starts at the
                    // sidebar's edge: the sidebar runs the window's height.
                    .padding(.top, -state.tabRowHeight)
            }
        }
    }
}

/// Mounts the sidebar in its own AppKit host view.
struct PaneSidebarHostRepresentable: NSViewRepresentable {
    let controller: BaseTerminalController
    @ObservedObject var state: PaneSidebarState
    let mode: PaneSidebarState.Mode
    let canExpand: Bool

    func makeNSView(context: Context) -> PaneSidebarHostView {
        PaneSidebarHostView(controller: controller, state: state, mode: mode, canExpand: canExpand)
    }

    func updateNSView(_ view: PaneSidebarHostView, context: Context) {
        view.mode = mode
        view.canExpand = canExpand
    }

    static func dismantleNSView(_ view: PaneSidebarHostView, coordinator: ()) {
        view.detach()
    }
}

/// The sidebar's AppKit host.
///
/// Why AppKit at all: the sidebar sits beside terminal surfaces and web
/// views, which are AppKit views and out-hit-test any SwiftUI content drawn
/// above them (the reason the split divider and the viewer panel's resize
/// handle are AppKit too). As its own `NSView` in a later z-position, the
/// host wins hit testing over its whole visible card and, by overriding
/// `hitTest`, NOTHING outside it: the transparent part of its frame passes
/// clicks straight through to the grid.
///
/// It also answers the drag session's drop geometry.
final class PaneSidebarHostView: NSView {
    weak var controller: BaseTerminalController?
    let state: PaneSidebarState
    let geometry = PaneSidebarGeometry()

    var mode: PaneSidebarState.Mode {
        didSet {
            guard mode != oldValue else { return }
            render()
        }
    }

    /// The window is wide enough for the expanded panel.
    var canExpand: Bool {
        didSet { if canExpand != oldValue { render() } }
    }

    private var hosting: NSHostingView<AnyView>?
    private var cancellables: Set<AnyCancellable> = []

    /// The card's width as drawn while it collapses or expands; it follows
    /// the window's grid (`PaneSidebarCardGlide.stage`).
    let cardGlide = PaneSidebarCardGlide()

    /// The card's width as drawn now: mid-glide, between the two.
    var drawnCardWidth: CGFloat {
        cardGlide.width ?? PaneSidebarState.cardWidth(for: mode, panelWidth: state.width)
    }

    /// The edge grip as the card is drawn now, in window coordinates: where
    /// the drag's bar goes (`SidePanelResizeHandle.gutterInWindow`).
    var gripInWindow: CGRect {
        let card = cardRect
        let grip = PaneSidebarState.edgeGrip(for: mode, elevated: elevated)
        return convert(NSRect(x: card.minX + drawnCardWidth + grip.offset, y: card.minY,
                              width: grip.width, height: card.height), to: nil)
    }

    /// The sidebar is about to collapse or expand (`changingPaneSidebarColumn`):
    /// its card starts gliding in the same turn as the grid, not when SwiftUI
    /// next redraws the sidebar — a frame later, the grid had already moved
    /// under the card.
    func noteModeChange(to mode: PaneSidebarState.Mode) {
        cardGlide.update(mode: mode, width: PaneSidebarState.cardWidth(for: mode, panelWidth: state.width))
    }

    init(controller: BaseTerminalController, state: PaneSidebarState, mode: PaneSidebarState.Mode,
         canExpand: Bool = true) {
        self.controller = controller
        self.state = state
        self.mode = mode
        self.canExpand = canExpand
        super.init(frame: .zero)

        // Re-render on any state change.
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsLayout = true }
            .store(in: &cancellables)

        render()
        controller.paneSidebarHost = self
        cardGlide.stage = { [weak self] in
            guard let content = self?.window?.contentView else { return nil }
            func find(_ v: NSView) -> PaneStageView? {
                if let stage = v as? PaneStageView { return stage }
                for sub in v.subviews { if let stage = find(sub) { return stage } }
                return nil
            }
            return find(content)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    /// The representable is going away (the sidebar was hidden).
    func detach() {
        if controller?.paneSidebarHost === self { controller?.paneSidebarHost = nil }
    }

    private func render() {
        guard let controller else { return }
        let root = AnyView(PaneSidebarChrome(
            controller: controller, state: state, geometry: geometry, mode: mode, canExpand: canExpand,
            glide: cardGlide))
        if let hosting {
            hosting.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            // Beside the tab bar this view reaches up under the titlebar,
            // and its own insets for that (`tabRowHeight`) are the only ones
            // it should apply — not the window's safe area on top of them.
            if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.hosting = hosting
        }
    }

    // MARK: Footprint

    /// Where the sidebar is actually drawn, in this view's coordinates: the
    /// raised card inside its margin — the rail's width, or the panel's.
    var cardRect: NSRect {
        guard mode != .hidden else { return .zero }
        let insets = PaneSidebarState.railInsets(elevated: elevated)
        return NSRect(x: insets.leading, y: insets.vertical,
                      width: PaneSidebarState.cardWidth(for: mode, panelWidth: state.width),
                      height: Swift.max(0, bounds.height - 2 * insets.vertical))
    }

    /// Clicks land only on the drawn card (plus the resize handle's slop just
    /// outside its trailing edge); everything else falls through to the grid.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let card = cardRect
        let grip = PaneSidebarState.edgeGrip(for: mode, elevated: elevated)
        let edge = NSRect(x: card.maxX + grip.offset, y: card.minY, width: grip.width, height: card.height)
        guard card.union(edge).contains(local) else { return nil }
        return super.hitTest(point)
    }

    private var elevated: Bool { controller?.ghostty.config.macosPaneStyle == .elevated }

    /// A screen y in the sidebar's own space (`PaneSidebarGeometry.space`,
    /// top-down from the hosting view's top), where its frames are read.
    func sidebarY(screenY: CGFloat) -> CGFloat? {
        guard let window, let hosting else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSPoint(x: 0, y: screenY))
        let local = hosting.convert(inWindow, from: nil)
        return hosting.isFlipped ? local.y : hosting.bounds.height - local.y
    }

    /// `sidebarY`'s inverse: a y in the sidebar's space, on screen.
    func screenY(sidebarY y: CGFloat) -> CGFloat? {
        guard let window, let hosting else { return nil }
        let local = NSPoint(x: 0, y: hosting.isFlipped ? y : hosting.bounds.height - y)
        return window.convertPoint(toScreen: hosting.convert(local, to: nil)).y
    }

    // MARK: Drop geometry

    /// The sidebar's droppable geometry in SCREEN coordinates, for
    /// `PaneDragSession`'s candidate windows.
    func dropGeometry() -> PaneDropCandidate.Sidebar? {
        guard mode != .hidden, let window, let hosting else { return nil }
        func toScreen(_ rect: CGRect) -> CGRect {
            window.convertToScreen(hosting.convert(rect, to: nil))
        }
        let card = window.convertToScreen(convert(cardRect, to: nil))
        return .init(
            rect: card,
            paneRows: geometry.rowFrames.filter { !$0.isStashed }.map { (id: $0.id, rect: toScreen($0.frame)) },
            stashRows: geometry.rowFrames.filter(\.isStashed).map { (id: $0.id, rect: toScreen($0.frame)) },
            // The tray's header's top: below the divider line is the tray.
            trayTop: geometry.trayFrame.map { toScreen($0).maxY },
            windowGroups: state.showsAllWindows
                ? geometry.groupFrames.map { (window: $0.window, rect: toScreen($0.frame)) }
                : [])
    }
}

/// The card or panel around `PaneSidebarView`, by mode — the two crossfading
/// as the card's width glides between them — and the edge grip, in the
/// gutter beside whichever is drawn.
private struct PaneSidebarChrome: View {
    @ObservedObject var controller: BaseTerminalController
    @ObservedObject var state: PaneSidebarState
    let geometry: PaneSidebarGeometry
    let mode: PaneSidebarState.Mode
    let canExpand: Bool

    /// The card's width as drawn: on a collapse or expand it glides there on
    /// the grid's clock (`PaneSidebarCardGlide`), so the gutter between the
    /// card and the panes holds while both move. The host's, so it outlives
    /// a re-render.
    @ObservedObject var glide: PaneSidebarCardGlide

    /// One raised glass card in both modes — the rail's width collapsed, the
    /// panel's expanded — with the same margins, top and height, so a pane's
    /// icon is at the same height either way. Its width animates as it
    /// collapses or expands while the rail's tiles and the full rows
    /// crossfade inside it, each laid out at its own width (and cut by the
    /// card) so neither reflows on the way.
    var body: some View {
        let background = controller.ghostty.config.backgroundColor
        let insets = railInsets
        let target = PaneSidebarState.cardWidth(for: mode, panelWidth: state.width)
        let width = glide.width ?? target
        // Mid-glide both are drawn, each at its own width and place — the
        // panel's rows never re-lay out to the card's width, the rail's tiles
        // never move — and crossfade by how far the card is between the two
        // widths. At rest, only the mode's. (A SwiftUI opacity transition
        // here never ran: the rail replaced the panel in one frame.)
        let gliding = glide.width != nil
        let rail = PaneSidebarState.railCardWidth
        let open = gliding
            ? Swift.min(1, Swift.max(0, (width - rail) / Swift.max(1, state.width - rail)))
            : (mode == .expanded ? 1 : 0)
        ZStack(alignment: .topLeading) {
            if mode == .expanded || (gliding && mode != .hidden) {
                PaneSidebarView(
                    controller: controller, state: state, geometry: geometry,
                    isRail: false, isFlat: false)
                    .frame(width: state.width)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(open)
                    .allowsHitTesting(mode == .expanded)
            }
            if mode == .collapsed || (gliding && mode != .hidden) {
                PaneSidebarView(
                    controller: controller, state: state, geometry: geometry,
                    isRail: true, isFlat: false, canExpand: canExpand)
                    .frame(width: rail)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(1 - open)
                    .allowsHitTesting(mode == .collapsed)
            }
        }
        .padding(.top, state.tabRowHeight)
        // The panel or rail, laid out at its own width, cut by the card as
        // it is drawn: nothing of it shows past the card while it glides.
        .frame(width: width, alignment: .topLeading)
        .clipped()
        .modifier(PaneSidebarCard(
            width: width,
            margins: EdgeInsets(
                top: insets.vertical, leading: insets.leading,
                bottom: insets.vertical, trailing: insets.trailing),
            isElevated: elevated,
            isGlass: controller.ghostty.config.paneGlass,
            background: background))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if mode != .hidden { resizeHandle(cardWidth: width) }
        }
        // No SwiftUI animation: the card's width and the crossfade follow
        // the grid's glide (`PaneSidebarCardGlide`), frame by frame.
        .transaction { $0.animation = nil }
        .coordinateSpace(name: PaneSidebarGeometry.space)
        .onAppear { glide.update(mode: mode, width: target) }
        .onChange(of: PaneSidebarCardGlide.Key(mode: mode, width: target)) {
            glide.update(mode: $0.mode, width: $0.width)
        }
    }

    private var elevated: Bool { controller.ghostty.config.macosPaneStyle == .elevated }

    /// The edge grip, in the gutter beside the drawn card (`edgeGrip`) —
    /// never over the sidebar. Dragged, it resizes the panel; past its
    /// minimum it pulls the rail out, and well under it tucks the panel back
    /// into the rail (`PaneSidebarState.edgeDrag`), within one drag, both
    /// ways.
    private func resizeHandle(cardWidth: CGFloat) -> some View {
        let grip = PaneSidebarState.edgeGrip(for: mode, elevated: elevated)
        let cardMaxX = railInsets.leading + cardWidth
        return PaneSidebarResizeHandle(
            currentWidth: {
                mode == .collapsed ? PaneSidebarState.railCardWidth : state.width
            },
            onDrag: { dx, start in
                let drag = PaneSidebarState.edgeDrag(
                    proposed: start + dx, isExpanded: mode == .expanded)
                guard !drag.expanded || canExpand else { return }
                // The width first, so expanding glides the grid to it.
                if let width = drag.width, state.width != width { state.width = width }
                controller.setPaneSidebarExpanded(drag.expanded, cause: "edge drag")
            })
            .frame(width: grip.width)
            .frame(maxHeight: .infinity)
            .padding(.vertical, railInsets.vertical)
            .offset(x: cardMaxX + grip.offset)
    }

    private var railInsets: PaneSidebarState.RailInsets {
        PaneSidebarState.railInsets(elevated: elevated)
    }
}

/// The sidebar card's drawn width while it collapses or expands. It FOLLOWS
/// the grid: the grid glides over by the column's change at the same moment
/// (`PaneStackState.noteColumnShift`), and after each of its steps the card's
/// edge is put where the grid's leading edge is, less the gutter between them
/// (`PaneStageView.leadingLag`) — so the gutter holds and neither passes
/// under the other, whatever either clock does. Two easings run side by side
/// drifted apart by a frame or two: the card grew over the grid, or the grid
/// slid under the card. With no grid glide to follow (none came, or it is
/// over), it eases on its own, on the grid's curve (`PaneStageView.glideTime`).
/// Nil: not gliding, the card is its width.
@MainActor
final class PaneSidebarCardGlide: ObservableObject {
    struct Key: Equatable {
        let mode: PaneSidebarState.Mode
        let width: CGFloat
    }

    @Published private(set) var width: CGFloat?
    /// The grid's glide to follow, found when a glide begins.
    var stage: () -> PaneStageView? = { nil }
    /// The mode and width last seen: a mode change glides from that width.
    private var mode: PaneSidebarState.Mode?
    private var known: CGFloat?
    private var from: CGFloat = 0
    private var target: CGFloat = 0
    private var began: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var followed = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    /// How long it waits for the grid's glide to begin before going on alone.
    static let followWait: CFTimeInterval = 0.15

    /// The card's mode and width now. A new mode glides from the width it
    /// is drawn at; a new width while gliding is eased toward.
    func update(mode: PaneSidebarState.Mode, width to: CGFloat) {
        defer { self.mode = mode; known = to }
        if let drawn = width ?? known, self.mode != nil, mode != self.mode, abs(to - drawn) >= 0.5 {
            width = drawn
            from = drawn
            target = to
            began = CACurrentMediaTime()
            last = began
            followed = false
            start(following: stage())
        } else if width != nil {
            target = to
        }
    }

    private func start(following stage: PaneStageView?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = stage.map {
            NotificationCenter.default.addObserver(forName: PaneStageView.didStep, object: $0, queue: nil) { [weak self] note in
                MainActor.assumeIsolated { self?.follow(note.object as? PaneStageView) }
            }
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// After a grid step: the card's edge where the grid's leading edge is.
    private func follow(_ stage: PaneStageView?) {
        guard width != nil else { return }
        guard let lag = stage?.leadingLag else {
            // The grid's glide is over: so is this one.
            if followed { finish() }
            return
        }
        followed = true
        set(target + lag)
    }

    /// The timer: hold for the grid's glide to begin; with none to follow,
    /// ease alone.
    private func step() {
        guard let current = width else { return finish() }
        let now = CACurrentMediaTime()
        defer { last = now }
        if followed { return }
        if stage() != nil, now - began < Self.followWait { return }
        let k = 1 - exp(-(now - last) / PaneStageView.glideTime)
        let next = current + (target - current) * k
        if abs(target - next) < 0.5 { finish() } else { set(next) }
    }

    /// Between where it began and where it is going, never past either.
    private func set(_ next: CGFloat) {
        width = Swift.min(Swift.max(next, Swift.min(from, target)), Swift.max(from, target))
        // The drag's bar, if any, stays on the edge as it is drawn.
        GutterBar.refreshActive()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        width = nil
        GutterBar.refreshActive()
    }
}

/// `SidePanelResizeHandle`, the viewer panel's edge-drag view, for SwiftUI.
private struct PaneSidebarResizeHandle: NSViewRepresentable {
    let currentWidth: () -> CGFloat
    let onDrag: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> SidePanelResizeHandle {
        let view = SidePanelResizeHandle()
        configure(view)
        return view
    }

    func updateNSView(_ view: SidePanelResizeHandle, context: Context) {
        configure(view)
    }

    private func configure(_ view: SidePanelResizeHandle) {
        view.widthAtDragStart = currentWidth
        view.onDrag = onDrag
        view.gutterInWindow = { [weak view] in view?.enclosingSidebarHost?.gripInWindow }
    }
}

private extension NSView {
    /// The pane sidebar host this view is in.
    var enclosingSidebarHost: PaneSidebarHostView? {
        var view = superview
        while let v = view {
            if let host = v as? PaneSidebarHostView { return host }
            view = v.superview
        }
        return nil
    }
}

/// The sidebar's card. In the elevated style it is an UNFOCUSED PANE's card
/// (`PaneCard`): the same corner radius, hairline rim, glass sheet and shadow
/// as the panes beside it, so it reads as one more card on the desk. (It was
/// the viewer side panel's glass card — rounder, with a specular rim and a
/// thinner sheet — and stood out from the panes.) The flat style, whose panes
/// have no card, keeps the side panel's.
private struct PaneSidebarCard: ViewModifier {
    let width: CGFloat
    let margins: EdgeInsets
    let isElevated: Bool
    let isGlass: Bool
    let background: Color

    func body(content: Content) -> some View {
        let isLight = OSColor(background).isLightColor
        if isElevated {
            content
                .font(.system(size: 12))
                .frame(width: width, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .modifier(PaneCard(
                    isElevated: true, isGlass: isGlass, isFocused: false,
                    background: background, isLight: isLight))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Panes")
                .padding(margins)
        } else {
            content.modifier(SidePanelCard(
                width: width,
                maxHeight: .infinity,
                accessibilityLabel: "Panes",
                base: background,
                isLightBase: isLight,
                margins: margins,
                isGlass: isGlass))
        }
    }
}
