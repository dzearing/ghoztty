import SwiftUI

/// The header a pane grows in rearrange mode: a drag grip, the pane's title,
/// and a button that moves the pane out into its own window.
///
/// It takes real layout space at the very top of the pane, above the sticky
/// banner, which is why entering the mode resizes every terminal in the
/// window. That is the cost of a header that occludes nothing.
///
/// There is deliberately NO focus tint here. Ghostty already dims unfocused
/// splits (`unfocused-split-opacity`), so a second focus indicator would be
/// two answers to one question.
struct PaneHeaderView: View {
    @ObservedObject var pane: PaneView

    static let height: CGFloat = 24

    @State private var isDragging: Bool = false
    @State private var isHovering: Bool = false

    /// Whether this pane is allowed to leave its window. A window's last pane
    /// is not — see `PaneMoveCoordinator.canMove`.
    private var canPopOut: Bool {
        guard let controller = pane.contentView.window?.windowController
                as? BaseTerminalController else { return false }
        return PaneMoveCoordinator.canMove(pane: pane, from: controller)
    }

    var body: some View {
        ZStack {
            // The whole header is the drag source, so the title is grabbable
            // too and the grip is a hint rather than the only target.
            PaneDragSource(pane: pane, isDragging: $isDragging, isHovering: $isHovering)
                .contentShape(Rectangle())

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(isHovering || isDragging ? 1.0 : 0.6))

                Text(pane.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .allowsHitTesting(false)

            HStack {
                Spacer()
                Button {
                    popOut()
                } label: {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canPopOut ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .disabled(!canPopOut)
                .help("Move to New Window")
                .padding(.trailing, 8)
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
        }
        .opacity(isDragging ? 0.4 : 1.0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane header: \(pane.title)")
    }

    private func popOut() {
        guard let controller = pane.contentView.window?.windowController
                as? BaseTerminalController else { return }
        PaneMoveCoordinator.popOut(pane: pane, from: controller)
    }
}
