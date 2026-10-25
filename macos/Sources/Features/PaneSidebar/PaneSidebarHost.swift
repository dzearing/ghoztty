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
                // the part of a view outside its parent's bounds. `hitTest`
                // limits the extra strip to the grip. Its width animates as
                // the sidebar collapses or expands, while the grid glides.
                PaneSidebarHostRepresentable(
                    controller: controller, state: state, mode: mode,
                    canExpand: PaneSidebarState.canExpand(windowWidth: windowWidth))
                    .frame(width: column + PaneSidebarState.edgeReach(for: mode, elevated: elevated))
                    .animation(PaneSidebarState.columnAnimation, value: mode)
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

    /// Live only while trash mode is on: Escape leaves it.
    private var escapeMonitor: Any?

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

        state.$isQuickKill
            .removeDuplicates()
            .sink { [weak self] on in self?.setEscapeMonitor(on) }
            .store(in: &cancellables)

        render()
        controller.paneSidebarHost = self
    }

    /// Escape leaves trash mode — innermost first: a drag in flight owns
    /// Escape (it cancels the drag), and only this window's sidebar answers.
    private func setEscapeMonitor(_ on: Bool) {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        guard on else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53,
                  self.window?.isKeyWindow == true,
                  !PaneDragSession.shared.isDragging,
                  self.state.isQuickKill else { return event }
            self.state.isQuickKill = false
            return nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    /// The representable is going away (the sidebar was hidden).
    func detach() {
        setEscapeMonitor(false)
        if controller?.paneSidebarHost === self { controller?.paneSidebarHost = nil }
    }

    private func render() {
        guard let controller else { return }
        let root = AnyView(PaneSidebarChrome(
            controller: controller, state: state, geometry: geometry, mode: mode, canExpand: canExpand))
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
    /// flat panel fills the frame; the raised rail card sits inside its
    /// margin.
    var cardRect: NSRect {
        switch mode {
        case .hidden:
            return .zero
        case .expanded:
            // The panel, without the strip the frame reserves past its edge
            // for the resize grip.
            return NSRect(x: 0, y: 0,
                          width: Swift.max(0, bounds.width - PaneSidebarState.edgeReach(for: mode, elevated: elevated)),
                          height: bounds.height)
        case .collapsed:
            let insets = PaneSidebarState.railInsets(elevated: elevated)
            return NSRect(x: insets.leading, y: insets.vertical, width: PaneSidebarState.railCardWidth,
                          height: Swift.max(0, bounds.height - 2 * insets.vertical))
        }
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
            trayTop: geometry.trayFrame.map { toScreen($0).midY },
            windowGroups: state.showsAllWindows
                ? geometry.groupFrames.map { (window: $0.window, rect: toScreen($0.frame)) }
                : [])
    }
}

/// The card or panel around `PaneSidebarView`, by mode — the two crossfading
/// as the host's width animates between them — and the edge grip, in the
/// gutter beside whichever is drawn.
private struct PaneSidebarChrome: View {
    @ObservedObject var controller: BaseTerminalController
    @ObservedObject var state: PaneSidebarState
    let geometry: PaneSidebarGeometry
    let mode: PaneSidebarState.Mode
    let canExpand: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch mode {
            case .hidden:
                EmptyView()
            case .expanded:
                panel.transition(.opacity)
            case .collapsed:
                rail.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The panel is wider than the host while it grows or shrinks: cut it
        // there rather than drawing over the grid.
        .clipped()
        .overlay(alignment: .topLeading) {
            if mode != .hidden { resizeHandle }
        }
        .animation(PaneSidebarState.columnAnimation, value: mode)
        .coordinateSpace(name: PaneSidebarGeometry.space)
    }

    private var elevated: Bool { controller.ghostty.config.macosPaneStyle == .elevated }

    /// EXPANDED: a flat panel — part of the window, not floating on it. The
    /// terminal background lifted by the same wash the glass card uses, and
    /// a 1px rule in the split-divider color.
    private var panel: some View {
        let background = controller.ghostty.config.backgroundColor
        let isLight = OSColor(background).isLightColor
        return PaneSidebarView(
            controller: controller, state: state, geometry: geometry,
            isRail: false, isFlat: true)
            .padding(.top, state.tabRowHeight)
            .frame(width: state.width)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            // Elevated: translucent, so the window's gradient runs under the
            // sidebar and the panel reads as part of the same surface the
            // panes are raised from. Flat: the terminal background, lifted,
            // and a 1px rule. Glass panes: no lifting wash either — it greys
            // the gradient out — just the panes' own neutral tint.
            .background(controller.ghostty.config.paneGlass
                ? AnyShapeStyle(Color.clear) : GlassCard.fill(isLightBackground: isLight))
            .background(background.opacity(elevated ? 0.38 : 1))
            // Its edge: in the elevated style, the same hairline a pane's rim
            // is drawn in, so the panel has an edge against the desk; flat,
            // the split-divider rule.
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(elevated
                        ? (isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.12))
                        : controller.ghostty.config.splitDividerColor)
                    .frame(width: 1)
            }
    }

    /// COLLAPSED: the raised glass card, icons only. It never opens on hover
    /// — the rail is where its icons are dragged.
    private var rail: some View {
        let background = controller.ghostty.config.backgroundColor
        let insets = railInsets
        return PaneSidebarView(
            controller: controller, state: state, geometry: geometry,
            isRail: true, isFlat: false, canExpand: canExpand)
            .padding(.top, state.tabRowHeight)
            .modifier(SidePanelCard(
                width: PaneSidebarState.railCardWidth,
                maxHeight: .infinity,
                accessibilityLabel: "Panes",
                base: background,
                isLightBase: OSColor(background).isLightColor,
                margins: EdgeInsets(
                    top: insets.vertical, leading: insets.leading,
                    bottom: insets.vertical, trailing: insets.trailing),
                isGlass: controller.ghostty.config.paneGlass))
            .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// The edge grip, in the gutter beside the drawn card (`edgeGrip`) —
    /// never over the sidebar. Dragged, it resizes the panel; past its
    /// minimum it pulls the rail out, and well under it tucks the panel back
    /// into the rail (`PaneSidebarState.edgeDrag`), within one drag, both
    /// ways.
    private var resizeHandle: some View {
        let grip = PaneSidebarState.edgeGrip(for: mode, elevated: elevated)
        let cardMaxX = mode == .collapsed
            ? railInsets.leading + PaneSidebarState.railCardWidth
            : state.width
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
                controller.setPaneSidebarExpanded(drag.expanded)
            })
            .frame(width: grip.width)
            .frame(maxHeight: .infinity)
            .padding(.vertical, mode == .collapsed ? railInsets.vertical : 0)
            .offset(x: cardMaxX + grip.offset)
    }

    private var railInsets: PaneSidebarState.RailInsets {
        PaneSidebarState.railInsets(elevated: elevated)
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
    }
}
