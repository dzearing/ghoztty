import SwiftUI

/// Live feedback for the pane drop that would happen right now.
///
/// Three outcomes get three visuals, so they are never confusable:
///
/// - **Split** — a filled rectangle occupying exactly where the pane will
///   land, with a solid seam line on the edge the new divider will run along.
/// - **Swap** — an outline and a ⇄ glyph, and deliberately NO fill: a fill
///   is the language of "insert here", and a swap inserts nothing.
/// - **Top level** — the same fill as a split, but spanning the whole window
///   (`TopLevelDropOverlay`).
struct PaneDropFeedbackView: View {
    let paneID: UUID
    let isDraggedPane: Bool

    @ObservedObject private var dragSession = PaneDragSession.shared

    var body: some View {
        GeometryReader { geometry in
            switch dragSession.target {
            case .split(_, let target, let direction) where target == paneID && !isDraggedPane:
                SplitDropFill(direction: direction, size: geometry.size)

            case .swap(_, let target) where target == paneID && !isDraggedPane:
                SwapDropOutline()

            case .swap where isDraggedPane:
                // The other half of the exchange: showing both ends is what
                // makes a swap read as a swap rather than a move.
                SwapDropOutline()

            default:
                EmptyView()
            }
        }
    }
}

/// The half-pane fill that shows where a split will put the pane.
struct SplitDropFill: View {
    let direction: SplitTree<PaneView>.NewDirection
    let size: CGSize

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            ZStack(alignment: seamAlignment) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.3))
                // The seam is where the new divider will run. Without it a
                // half-filled pane does not say which axis is being cut.
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(
                        width: isHorizontal ? 2 : nil,
                        height: isHorizontal ? nil : 2)
            }
            .frame(
                width: isHorizontal ? size.width / 2 : nil,
                height: isHorizontal ? nil : size.height / 2)
        }
    }

    private var isHorizontal: Bool {
        direction == .left || direction == .right
    }

    private var alignment: Alignment {
        switch direction {
        case .left: .leading
        case .right: .trailing
        case .up: .top
        case .down: .bottom
        }
    }

    /// The seam faces the middle of the pane — the side the divider lands on.
    private var seamAlignment: Alignment {
        switch direction {
        case .left: .trailing
        case .right: .leading
        case .up: .bottom
        case .down: .top
        }
    }
}

/// The outline that marks a pane as one end of a swap.
struct SwapDropOutline: View {
    var body: some View {
        ZStack {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 3)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(10)
                .background(.regularMaterial, in: Circle())
        }
    }
}

/// Feedback for a top-level insert, which spans the whole window and so
/// belongs to no single leaf.
struct TopLevelDropOverlay: View {
    let windowRef: PaneDropWindowRef

    @ObservedObject private var dragSession = PaneDragSession.shared

    var body: some View {
        GeometryReader { geometry in
            if case .topLevel(let window, let side) = dragSession.target, window == windowRef {
                SplitDropFill(direction: side, size: geometry.size)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Feedback for a strip dropped in a slot of its row: an insertion bar down
/// the gutter it would land in. Belongs to no leaf (it is between two).
struct BladeDropOverlay: View {
    let windowRef: PaneDropWindowRef

    @ObservedObject private var dragSession = PaneDragSession.shared

    var body: some View {
        GeometryReader { geometry in
            if case .reorder(let window, _, _, let caret) = dragSession.target, window == windowRef,
               let rect = local(caret, in: geometry) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 4)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }

    /// `screen` (AppKit screen coordinates, y up) in this view's space.
    private func local(_ screen: CGRect, in geometry: GeometryProxy) -> CGRect? {
        guard let window = PaneMoveCoordinator.controller(for: windowRef)?.window,
              let content = window.contentView else { return nil }
        let inWindow = window.convertFromScreen(screen)
        let flipped = CGRect(x: inWindow.minX, y: content.bounds.height - inWindow.maxY,
                             width: inWindow.width, height: inWindow.height)
        let origin = geometry.frame(in: .global).origin
        return flipped.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}

/// Feedback for a strip dropped at a screen's edge: the half of the screen
/// its new window would fill, as a translucent panel above everything.
@MainActor
final class TileDropPreview {
    static let shared = TileDropPreview()

    private var panel: NSPanel?

    func show(_ frame: CGRect) {
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
            view.layer?.borderWidth = 3
            view.layer?.cornerRadius = 12
            panel.contentView = view
            self.panel = panel
            return panel
        }()
        let inset = frame.insetBy(dx: 6, dy: 6)
        if panel.frame != inset { panel.setFrame(inset, display: true) }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Showing, at this frame (for tests).
    var shownFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }
}
