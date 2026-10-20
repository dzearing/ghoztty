import AppKit
import SwiftUI

/// The visible sliver of a pane tucked into a stack (see `PaneLayout`): a
/// dark strip down the card's leading edge with the pane's title running
/// along it, over the scrim that dims the card (`PaneCardView`). Clicking it
/// focuses the pane, which is what brings it forward — the stack's run
/// follows focus (`PaneStackState`).
///
/// The tab is an AppKit view hosting its SwiftUI face: the pane under it is an
/// AppKit view (a Metal terminal, a web view), and SwiftUI content drawn as a
/// sibling above one neither shows reliably nor wins the click.
final class PaneStackTabView: NSView {
    weak var pane: PaneView? {
        didSet { dragSource.pane = pane }
    }
    /// Hover lightens the card's scrim as well as the tab.
    var onHover: ((Bool) -> Void)?
    private var host: NSHostingView<PaneStackTabFace>?
    private let hover = PaneStackTabFace.Hover()

    /// A click brings the pane forward; a drag picks it up, with a strip's
    /// targets: a slot between the cards and strips of its row, a window's
    /// edge, or a screen's (`PaneDropResolver.resolveBlade`).
    private let dragSource = PaneDragSourceView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        dragSource.showsGrabCursor = false
        dragSource.isBlade = true
        dragSource.onClick = { [weak self] _ in self?.activate() }
        // No drag image: the card itself comes out of the stack and follows
        // the pointer, and settles back when it is dropped.
        dragSource.showsPreview = false
        dragSource.onDragMoved = { [weak self] point in self?.dragged(to: point) }
        dragSource.onDragFinished = { [weak self] in
            self?.dragStart = nil
            self?.card?.settle()
        }
        dragSource.autoresizingMask = [.width, .height]
        addSubview(dragSource)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Brings the pane forward")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(face: PaneStackTabFace) {
        var face = face
        face.hover = hover
        if let host {
            host.rootView = face
        } else {
            let host = NSHostingView(rootView: face)
            host.sizingOptions = []
            if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
            host.autoresizingMask = [.width, .height]
            host.frame = bounds
            addSubview(host, positioned: .below, relativeTo: dragSource)
            self.host = host
        }
        setAccessibilityLabel("Tucked pane: \(face.title)")
    }

    // The whole tab is one target; the face inside it is only drawing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? dragSource : nil
    }

    override func layout() {
        super.layout()
        dragSource.frame = bounds
    }

    // A click on a tab in a background window brings the pane forward in
    // that same click, as clicking a pane focuses it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }


    private func setHovered(_ hovered: Bool) {
        guard hover.isHovered != hovered else { return }
        hover.isHovered = hovered
        onHover?(hovered)
    }

    override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }

    /// Where the drag started, in screen points.
    private var dragStart: NSPoint?

    private var card: PaneCardView? {
        sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? PaneCardView }.first
    }

    private func dragged(to point: NSPoint) {
        let start = dragStart ?? point
        dragStart = start
        // Screen points run up; the stage runs down.
        card?.lift(by: CGSize(width: point.x - start.x, height: start.y - point.y))
    }

    private func activate() {
        setHovered(false)
        guard let pane else { return }
        Ghostty.moveFocus(to: pane)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Every tab mounted in a window, so a pane drag can find them on each
    /// mouse move without walking the view tree.
    private static let mounted = NSHashTable<PaneStackTabView>.weakObjects()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.mounted.remove(self)
        } else {
            Self.mounted.add(self)
        }
    }

    /// The tabs showing in `window`, by the pane each fronts. Only showing:
    /// every card keeps its tab view, hidden while it is on show, and a
    /// hidden tab — wherever it was last — is not where its pane is.
    static func all(in window: NSWindow) -> [UUID: PaneStackTabView] {
        var found: [UUID: PaneStackTabView] = [:]
        for tab in mounted.allObjects where tab.window === window && !tab.isHidden && tab.alphaValue > 0 {
            guard let pane = tab.pane else { continue }
            found[pane.id] = tab
        }
        return found
    }
}

/// What a tab looks like.
struct PaneStackTabFace: View {
    final class Hover: ObservableObject {
        @Published var isHovered = false
    }

    @ObservedObject var pane: PaneView
    let axis: PaneLayout.Direction
    let cornerRadius: CGFloat
    let background: Color
    let isLight: Bool
    var hover = Hover()

    var body: some View {
        HoverReader(hover: hover) { isHovered in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // A dark strip of the pane's own color: the card's scrim
                    // dims the pane, and the strip all but hides the few
                    // columns under the title so they don't compete with it.
                    shape.fill(strip)
                    label(in: geo.size, isHovered: isHovered)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
    }

    var title: String {
        pane.title.isEmpty ? "Pane" : pane.title
    }

    private var strip: Color {
        let base = OSColor(background).blended(withFraction: isLight ? 0.06 : 0.35, of: .black) ?? OSColor(background)
        return Color(nsColor: base).opacity(isLight ? 0.85 : 0.82)
    }

    private var shape: UnevenRoundedRectangle {
        switch axis {
        case .horizontal:
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: cornerRadius, bottomLeading: cornerRadius),
                style: .continuous)
        case .vertical:
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: cornerRadius, topTrailing: cornerRadius),
                style: .continuous)
        }
    }

    @ViewBuilder
    private func label(in size: CGSize, isHovered: Bool) -> some View {
        let text = Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(isLight
                             ? Color.black.opacity(isHovered ? 0.85 : 0.65)
                             : Color.white.opacity(isHovered ? 0.95 : 0.75))
            .lineLimit(1)
            .truncationMode(.middle)
        switch axis {
        case .horizontal:
            // Reads top to bottom, as a book spine on a shelf does, centered
            // down the strip; a title longer than the strip is cut in the
            // middle, keeping both ends of a path.
            let length = max(0, size.height - 24)
            text
                .frame(width: length)
                .rotationEffect(.degrees(90))
                .frame(width: size.width, height: size.height)
        case .vertical:
            text
                .frame(width: max(0, size.width - 24), alignment: .leading)
                .padding(.horizontal, 12)
                .frame(width: size.width, height: size.height, alignment: .leading)
        }
    }
}

/// Observes the tab's hover state (set by its AppKit view).
private struct HoverReader<Content: View>: View {
    @ObservedObject var hover: PaneStackTabFace.Hover
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(hover.isHovered) }
}
