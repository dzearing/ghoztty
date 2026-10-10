import AppKit
import Combine
import SwiftUI

/// Lays out a terminal window's grid beside its pane sidebar.
///
/// The sidebar's COLUMN is a fixed-width spacer in front of the grid; the
/// sidebar itself is drawn in an overlay. That split is what lets the
/// unpinned card open over the grid on hover without the column — and so
/// every terminal in the window — changing width (a SIGWINCH and a TUI
/// redraw per pass of the pointer). Only pin/unpin change the column.
struct PaneSidebarContainer<Content: View>: View {
    @ObservedObject var state: PaneSidebarState
    let controller: BaseTerminalController
    @ViewBuilder let content: Content

    @State private var windowWidth: CGFloat = PaneSidebarState.narrowWindowWidth

    var body: some View {
        let mode = state.mode(windowWidth: windowWidth)
        let column = PaneSidebarState.columnWidth(for: mode, panelWidth: state.width)

        HStack(spacing: 0) {
            if mode != .hidden {
                Color.clear
                    .frame(width: column)
                    .accessibilityHidden(true)
            }
            content
        }
        // No animation on the column: the grid snaps, once, so each terminal
        // gets one resize rather than one per animation frame.
        .transaction { $0.animation = nil }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { windowWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { windowWidth = $0 }
        })
        .overlay(alignment: .topLeading) {
            if mode != .hidden {
                PaneSidebarHostRepresentable(controller: controller, state: state, mode: mode)
                    .frame(width: mode == .expanded
                           ? column
                           : state.width + 2 * GlassCard.outerMargin)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// Mounts the sidebar in its own AppKit host view.
struct PaneSidebarHostRepresentable: NSViewRepresentable {
    let controller: BaseTerminalController
    @ObservedObject var state: PaneSidebarState
    let mode: PaneSidebarState.Mode

    func makeNSView(context: Context) -> PaneSidebarHostView {
        PaneSidebarHostView(controller: controller, state: state, mode: mode)
    }

    func updateNSView(_ view: PaneSidebarHostView, context: Context) {
        view.mode = mode
    }

    static func dismantleNSView(_ view: PaneSidebarHostView, coordinator: ()) {
        view.detach()
    }
}

/// The sidebar's AppKit host.
///
/// Why AppKit at all: the sidebar sits beside — and, opened on hover, over —
/// terminal surfaces and web views, which are AppKit views and out-hit-test
/// any SwiftUI content drawn above them (the reason the split divider and the
/// viewer panel's resize handle are AppKit too). As its own `NSView` in a
/// later z-position, the host wins hit testing over its whole visible card
/// and, by overriding `hitTest`, NOTHING outside it: the transparent part of
/// its frame — where the closed rail leaves room for the open card — passes
/// clicks straight through to the grid.
///
/// It also owns the hover-open timing (an NSTrackingArea, which keeps working
/// over AppKit content) and answers the drag session's drop geometry.
final class PaneSidebarHostView: NSView {
    weak var controller: BaseTerminalController?
    let state: PaneSidebarState
    let geometry = PaneSidebarGeometry()

    var mode: PaneSidebarState.Mode {
        didSet {
            guard mode != oldValue else { return }
            if mode != .mini { state.isHoverOpen = false }
            render()
        }
    }

    private var hosting: NSHostingView<AnyView>?
    private var cancellables: Set<AnyCancellable> = []
    private var trackingArea: NSTrackingArea?
    private var openTimer: Timer?
    private var closeTimer: Timer?

    /// Live only while trash mode is on: Escape leaves it.
    private var escapeMonitor: Any?

    init(controller: BaseTerminalController, state: PaneSidebarState, mode: PaneSidebarState.Mode) {
        self.controller = controller
        self.state = state
        self.mode = mode
        super.init(frame: .zero)

        // Re-render on any state change; recompute tracking when the card's
        // footprint changes.
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.needsLayout = true
                self?.updateTrackingAreas()
            }
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
        openTimer?.invalidate()
        closeTimer?.invalidate()
        setEscapeMonitor(false)
        if controller?.paneSidebarHost === self { controller?.paneSidebarHost = nil }
    }

    private func render() {
        guard let controller else { return }
        let root = AnyView(PaneSidebarChrome(
            controller: controller, state: state, geometry: geometry, mode: mode))
        if let hosting {
            hosting.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
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
    /// flat panel fills the frame; the raised card sits inside its margin,
    /// as wide as the rail or — hover-open — the full panel.
    var cardRect: NSRect {
        switch mode {
        case .hidden:
            return .zero
        case .expanded:
            return bounds
        case .mini:
            let margin = GlassCard.outerMargin
            let width = state.isHoverOpen ? state.width : PaneSidebarState.railCardWidth
            return NSRect(x: margin, y: margin, width: width,
                          height: Swift.max(0, bounds.height - 2 * margin))
        }
    }

    /// Clicks land only on the drawn card (plus the resize handle's slop just
    /// outside its trailing edge); everything else falls through to the grid.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let slop = SidePanelResizeHandle.grabWidth
        let card = cardRect
        let edge = NSRect(x: card.maxX - slop / 2, y: card.minY, width: slop, height: card.height)
        guard card.union(edge).contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Hover-open (unpinned)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard mode == .mini else { return }
        let area = NSTrackingArea(
            rect: cardRect,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeTimer?.invalidate()
        guard mode == .mini, !state.isHoverOpen else { return }
        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(
            withTimeInterval: PaneSidebarState.hoverOpenDelay, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode == .mini, self.pointerIsOverCard else { return }
                self.state.isHoverOpen = true
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        openTimer?.invalidate()
        guard state.isHoverOpen else { return }
        scheduleClose()
    }

    private func scheduleClose() {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(
            withTimeInterval: PaneSidebarState.hoverCloseDelay, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Never contract out from under the pointer, a drag, or a
                // sheet the sidebar put up; try again shortly instead.
                if self.pointerIsOverCard
                    || PaneDragSession.shared.isDragging
                    || self.window?.attachedSheet != nil {
                    if !self.pointerIsOverCard { self.scheduleClose() }
                    return
                }
                self.state.isHoverOpen = false
            }
        }
    }

    private var pointerIsOverCard: Bool {
        guard let window else { return false }
        let inWindow = window.mouseLocationOutsideOfEventStream
        return cardRect.contains(convert(inWindow, from: nil))
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
            stashRows: geometry.rowFrames.map { (id: $0.id, rect: toScreen($0.frame)) },
            windowGroups: state.showsAllWindows
                ? geometry.groupFrames.map { (window: $0.window, rect: toScreen($0.frame)) }
                : [])
    }
}

/// The card or panel around `PaneSidebarView`, by mode.
private struct PaneSidebarChrome: View {
    @ObservedObject var controller: BaseTerminalController
    @ObservedObject var state: PaneSidebarState
    let geometry: PaneSidebarGeometry
    let mode: PaneSidebarState.Mode

    var body: some View {
        let background = controller.ghostty.config.backgroundColor
        let isLight = OSColor(background).isLightColor

        Group {
            switch mode {
            case .hidden:
                EmptyView()

            case .expanded:
                // PINNED: a flat panel — part of the window, not floating on
                // it. The terminal background lifted by the same wash the
                // glass card uses, and a 1px rule in the split-divider color.
                PaneSidebarView(
                    controller: controller, state: state, geometry: geometry,
                    isRail: false, isFlat: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(GlassCard.fill(isLightBackground: isLight))
                    .background(background)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(controller.ghostty.config.splitDividerColor)
                            .frame(width: 1)
                    }
                    .overlay(alignment: .trailing) { resizeHandle }

            case .mini:
                // UNPINNED: the raised glass card, as the rail or — under the
                // pointer — open to full width.
                let open = state.isHoverOpen
                PaneSidebarView(
                    controller: controller, state: state, geometry: geometry,
                    isRail: !open, isFlat: false)
                    .modifier(SidePanelCard(
                        width: open ? state.width : PaneSidebarState.railCardWidth,
                        maxHeight: .infinity,
                        accessibilityLabel: "Panes",
                        base: background,
                        isLightBase: isLight))
                    .overlay(alignment: .trailing) {
                        resizeHandle.padding(.vertical, GlassCard.outerMargin)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .animation(.easeOut(duration: 0.2), value: open)
            }
        }
        .coordinateSpace(name: PaneSidebarGeometry.space)
    }

    /// Drag the edge: resize the panel, or — past the thresholds — pin and
    /// unpin, the same as the pin button.
    private var resizeHandle: some View {
        PaneSidebarResizeHandle(
            currentWidth: {
                mode == .mini && !state.isHoverOpen ? PaneSidebarState.railCardWidth : state.width
            },
            onDrag: { dx, start in
                let proposed = start + dx
                switch mode {
                case .mini where !state.isHoverOpen:
                    if proposed > PaneSidebarState.expandThreshold {
                        controller.setPaneSidebarPinned(true)
                    }
                case .expanded:
                    if proposed < PaneSidebarState.collapseThreshold {
                        controller.setPaneSidebarPinned(false)
                    } else {
                        state.width = PaneSidebarState.clampWidth(proposed)
                    }
                default:
                    state.width = PaneSidebarState.clampWidth(proposed)
                }
            })
            .frame(width: SidePanelResizeHandle.grabWidth)
            .offset(x: SidePanelResizeHandle.grabWidth / 2 - (mode == .mini ? GlassCard.outerMargin : 0))
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
