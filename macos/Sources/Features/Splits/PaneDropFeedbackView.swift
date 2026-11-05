import SwiftUI

/// Live feedback for the pane drop that would happen right now.
///
/// A preview of each outcome, so they are never confusable:
///
/// - **Split** — a filled rectangle occupying exactly where the pane will
///   land, with a solid seam line on the edge the new divider will run along.
/// - **Swap** — the box in the middle of the pane that means it
///   (`PaneDropResolver.swapRect`), with a ⇄ glyph.
/// - **Top level** — the same fill as a split, but spanning the whole window
///   (`TopLevelDropOverlay`).
/// - **Insert** — the same fill, in the divider's gap, a seam down each side
///   (`InsertDropOverlay`).
struct PaneDropFeedbackView: View {
    let paneID: UUID

    @ObservedObject private var feedback = PaneDragSession.shared.dropFeedback

    var body: some View {
        GeometryReader { geometry in
            switch feedback.target {
            case .split(_, let target, let direction) where target == paneID:
                SplitDropFill(direction: direction, size: geometry.size)

            case .swap(_, let target) where target == paneID:
                SwapDropBox(size: geometry.size)

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

/// The box in the middle of a pane that swaps it: exactly where the pointer
/// means a swap.
struct SwapDropBox: View {
    let size: CGSize

    var body: some View {
        let box = PaneDropResolver.swapRect(in: CGRect(origin: .zero, size: size))
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.3))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 2)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: box.width, height: box.height)
        .position(x: box.midX, y: box.midY)
    }
}

/// Feedback for a top-level insert, which spans the whole window and so
/// belongs to no single leaf.
struct TopLevelDropOverlay: View {
    let windowRef: PaneDropWindowRef

    @ObservedObject private var feedback = PaneDragSession.shared.dropFeedback

    var body: some View {
        GeometryReader { geometry in
            if case .topLevel(let window, let side) = feedback.target, window == windowRef {
                SplitDropFill(direction: side, size: geometry.size)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Feedback for a pane dropped on a divider: the fill of a split where it
/// would land, with a seam down each side, the new dividers. Belongs to no
/// leaf (it is between two).
struct InsertDropOverlay: View {
    let windowRef: PaneDropWindowRef

    @ObservedObject private var feedback = PaneDragSession.shared.dropFeedback

    var body: some View {
        GeometryReader { geometry in
            if case .insert(let window, _, _, let direction, let landing) = feedback.target, window == windowRef,
               let rect = localRect(landing, in: geometry, windowRef: windowRef) {
                ZStack {
                    Rectangle().fill(Color.accentColor.opacity(0.3))
                    if direction == .horizontal {
                        HStack {
                            seam.frame(width: 2)
                            Spacer()
                            seam.frame(width: 2)
                        }
                    } else {
                        VStack {
                            seam.frame(height: 2)
                            Spacer()
                            seam.frame(height: 2)
                        }
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }

    private var seam: some View { Rectangle().fill(Color.accentColor) }
}

/// Feedback for a strip dropped in a slot of its row: an insertion bar down
/// the gutter it would land in. Belongs to no leaf (it is between two).
struct BladeDropOverlay: View {
    let windowRef: PaneDropWindowRef

    @ObservedObject private var feedback = PaneDragSession.shared.dropFeedback

    var body: some View {
        GeometryReader { geometry in
            if case .reorder(let window, _, _, let caret) = feedback.target, window == windowRef,
               let rect = localRect(caret, in: geometry, windowRef: windowRef) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 4)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// `screen` (AppKit screen coordinates, y up) in the space of the view
/// `geometry` is for, in `windowRef`'s window.
@MainActor
private func localRect(
    _ screen: CGRect,
    in geometry: GeometryProxy,
    windowRef: PaneDropWindowRef
) -> CGRect? {
    guard let window = PaneMoveCoordinator.controller(for: windowRef)?.window,
          let content = window.contentView else { return nil }
    let inWindow = window.convertFromScreen(screen)
    let flipped = CGRect(x: inWindow.minX, y: content.bounds.height - inWindow.maxY,
                         width: inWindow.width, height: inWindow.height)
    let origin = geometry.frame(in: .global).origin
    return flipped.offsetBy(dx: -origin.x, dy: -origin.y)
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
