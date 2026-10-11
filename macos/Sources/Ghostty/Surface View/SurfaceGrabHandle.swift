import SwiftUI

/// The hover-revealed grab handle at the top of a pane — EITHER kind.
///
/// One handle for terminals and viewers alike: the pane-kind wrappers below
/// only answer "is the pointer in this pane's top band" (each kind learns
/// where the pointer is differently); the drag source, the grip, and its two
/// states live here once. Viewer panes used to have no handle at all, so the
/// only way to drag one — onto the pane sidebar, say — was rearrange mode.
struct PaneGrabHandle: View {
    // Size of the actual drag handle; the hover reveal region is larger.
    static let handleSize = CGSize(width: 80, height: 12)

    // Reveal the handle anywhere within the top % of the pane height.
    static let hoverHeightFactor: CGFloat = 0.2

    /// The pane to drag. Nil while the pane is not in a terminal window.
    let pane: PaneView?

    /// The pointer is in the pane's top reveal band.
    let pointerInBand: Bool

    /// Whether the pointer is showing (hidden while typing in a terminal).
    let cursorVisible: Bool

    @EnvironmentObject private var ghostty: Ghostty.App

    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false

    var body: some View {
        ZStack {
            if let pane {
                PaneDragSource(
                    pane: pane,
                    isDragging: $isDragging,
                    isHovering: $isHovering
                )
                .frame(width: Self.handleSize.width, height: Self.handleSize.height)
                .contentShape(Rectangle())
            }

            if Self.reveals(
                cursorVisible: cursorVisible, isHovering: isHovering,
                isDragging: isDragging, pointerInBand: pointerInBand) {
                grip
                    .offset(y: -3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func reveals(
        cursorVisible: Bool,
        isHovering: Bool,
        isDragging: Bool,
        pointerInBand: Bool
    ) -> Bool {
        // If the cursor isn't visible, never show the handle
        guard cursorVisible else { return false }
        // If we're hovering or actively dragging, always visible
        return isHovering || isDragging || pointerInBand
    }

    /// Two states, so the handle reads as the thing you are about to grab:
    /// hovering the PANE fades it in translucent; hovering (or holding) the
    /// HANDLE makes it fully opaque — a solid fill a shade off the terminal
    /// background, full-strength dots, and a slight shadow.
    private var grip: some View {
        let engaged = isHovering || isDragging
        return Image(systemName: "ellipsis")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(engaged ? 1 : 0.6))
            .frame(width: 46, height: 14)
            .background(
                Capsule().fill(engaged ? solidFill : Color.gray.opacity(0.22)))
            .shadow(color: .black.opacity(engaged ? 0.35 : 0), radius: 2, y: 1)
            .animation(.easeOut(duration: 0.15), value: engaged)
    }

    /// The terminal background lifted (or, on a light theme, sunk) far
    /// enough to stand off it, and fully opaque.
    private var solidFill: Color {
        let background = OSColor(ghostty.config.backgroundColor)
        return Color(nsColor: background.isLightColor
            ? background.darken(by: 0.14)
            : background.lighten(by: 0.22))
    }

    /// The full-width hover band that reveals the drag handle.
    static func hoverRect(in bounds: CGRect) -> CGRect {
        guard !bounds.isEmpty else { return .zero }

        let hoverHeight = min(bounds.height, max(handleSize.height, bounds.height * hoverHeightFactor))
        return CGRect(
            x: bounds.minX,
            y: bounds.maxY - hoverHeight,
            width: bounds.width,
            height: hoverHeight
        )
    }

    /// Returns true when the pointer is inside the top hover band (bounds of
    /// a non-flipped view: the top is maxY).
    static func isInHoverRegion(_ point: CGPoint, in bounds: CGRect) -> Bool {
        hoverRect(in: bounds).contains(point)
    }
}

extension Ghostty {
    /// The grab handle on a terminal pane.
    struct SurfaceGrabHandle: View {
        @ObservedObject var surfaceView: SurfaceView

        /// The tree leaf wrapping this surface. Nil only while the surface
        /// is not mounted in a terminal window.
        private var pane: PaneView? {
            guard let controller = surfaceView.window?.windowController
                    as? BaseTerminalController else { return nil }
            return controller.surfaceTree.pane(for: surfaceView)
        }

        private var handleVisible: Bool {
            // Handle should always be visible in non-fullscreen
            guard let window = surfaceView.window else { return true }
            guard window.styleMask.contains(.fullScreen) else { return true }

            // If fullscreen, only show the handle if we have splits
            guard let controller = window.windowController as? BaseTerminalController else { return false }
            return controller.surfaceTree.isSplit
        }

        /// Whether the handle is revealed. Pure, so the rule is testable.
        ///
        /// The reveal band is the top of the PANE. With a banner, the top of
        /// the pane is the banner — and the terminal is inset below it, so a
        /// pointer there is outside the surface and reports no location. The
        /// banner reports it instead, and counts as in the band: otherwise
        /// the handle (drawn over the banner) vanished exactly where you
        /// reach for it.
        static func revealsHandle(
            cursorVisible: Bool,
            isHovering: Bool,
            isDragging: Bool,
            pointerOverBanner: Bool,
            mouseLocation: CGPoint?,
            surfaceBounds: CGRect
        ) -> Bool {
            PaneGrabHandle.reveals(
                cursorVisible: cursorVisible,
                isHovering: isHovering,
                isDragging: isDragging,
                pointerInBand: pointerInBand(
                    pointerOverBanner: pointerOverBanner,
                    mouseLocation: mouseLocation,
                    surfaceBounds: surfaceBounds))
        }

        static func pointerInBand(
            pointerOverBanner: Bool,
            mouseLocation: CGPoint?,
            surfaceBounds: CGRect
        ) -> Bool {
            if pointerOverBanner { return true }
            guard let mouseLocation else { return false }
            return PaneGrabHandle.isInHoverRegion(mouseLocation, in: surfaceBounds)
        }

        var body: some View {
            if handleVisible {
                PaneGrabHandle(
                    pane: pane,
                    pointerInBand: Self.pointerInBand(
                        pointerOverBanner: surfaceView.pointerOverBanner,
                        mouseLocation: surfaceView.mouseLocationInSurface,
                        surfaceBounds: surfaceView.bounds),
                    cursorVisible: surfaceView.cursorVisible)
            }
        }
    }
}

/// The grab handle on a viewer pane (a rendered document, an HTML page, a
/// website, an image, a diff). The viewer reports the pointer itself
/// (`ViewerView.mouseLocationInViewer`, from a tracking area that keeps
/// working over the web view).
struct ViewerGrabHandle: View {
    @ObservedObject var viewerView: ViewerView

    private var pane: PaneView? {
        guard let controller = viewerView.window?.windowController
                as? BaseTerminalController else { return nil }
        return controller.surfaceTree.first { $0.viewerView === viewerView }
    }

    var body: some View {
        PaneGrabHandle(
            pane: pane,
            pointerInBand: viewerView.mouseLocationInViewer.map {
                PaneGrabHandle.isInHoverRegion($0, in: viewerView.bounds)
            } ?? false,
            cursorVisible: true)
    }
}
