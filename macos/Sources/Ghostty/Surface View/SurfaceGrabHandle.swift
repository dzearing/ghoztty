import SwiftUI

extension Ghostty {
    /// A grab handle overlay at the top of the surface for dragging a surface.
    struct SurfaceGrabHandle: View {
        // Size of the actual drag handle; the hover reveal region is larger.
        private static let handleSize = CGSize(width: 80, height: 12)

        // Reveal the handle anywhere within the top % of the pane height.
        private static let hoverHeightFactor: CGFloat = 0.2

        @ObservedObject var surfaceView: SurfaceView
        @EnvironmentObject private var ghostty: Ghostty.App

        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false

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

        private var ellipsisVisible: Bool {
            // If the cursor isn't visible, never show the handle
            guard surfaceView.cursorVisible else { return false }
            // If we're hovering or actively dragging, always visible
            if isHovering || isDragging { return true }

            // Require our mouse location to be within the top area of the
            // surface.
            guard let mouseLocation = surfaceView.mouseLocationInSurface else { return false }
            return Self.isInHoverRegion(mouseLocation, in: surfaceView.bounds)
        }

        var body: some View {
            if handleVisible {
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

                    if ellipsisVisible {
                        grip
                            .offset(y: -3)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }

        /// Two states, so the handle reads as the thing you are about to grab:
        /// hovering the PANE fades it in translucent; hovering (or holding)
        /// the HANDLE makes it fully opaque — a solid fill a shade off the
        /// terminal background, full-strength dots, and a slight shadow.
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
        private static func hoverRect(in bounds: CGRect) -> CGRect {
            guard !bounds.isEmpty else { return .zero }

            let hoverHeight = min(bounds.height, max(handleSize.height, bounds.height * hoverHeightFactor))
            return CGRect(
                x: bounds.minX,
                y: bounds.maxY - hoverHeight,
                width: bounds.width,
                height: hoverHeight
            )
        }

        /// Returns true when the pointer is inside the top hover band.
        private static func isInHoverRegion(_ point: CGPoint, in bounds: CGRect) -> Bool {
            hoverRect(in: bounds).contains(point)
        }
    }
}
