import AppKit
import SwiftUI

/// One pane in the sidebar: a full row in the expanded panel, a tile in the
/// collapsed rail.
///
/// The whole row is a drag source AND a button. Both are owned by an AppKit
/// view (`PaneSidebarRowInteraction`) rather than SwiftUI gestures: the drag
/// is the same `NSDraggingSession` source the grab handle uses (one drag
/// system, one resolver), and that source must own mouseDown — so the click
/// is reported from it too. The trailing action button sits OUTSIDE the
/// interaction view's frame, because an AppKit view out-hit-tests any SwiftUI
/// control drawn over it.
struct PaneSidebarRow: View {
    @ObservedObject var pane: PaneView
    let owner: BaseTerminalController
    let isStashed: Bool
    let isSelected: Bool
    /// In another window (all-windows scope): its selection is that window's
    /// focus, drawn unemphasized, and clicking raises that window.
    let isForeign: Bool
    let isRail: Bool
    let isBeingDragged: Bool
    /// Leading indent of the row's content (not its fill): a window's panes
    /// sit under its header in the all-windows outline.
    var indent: CGFloat = 0

    @State private var isHovered = false
    @ObservedObject private var rename = PaneSidebarRename.shared
    @Environment(\.paneSidebarEmphasized) private var windowIsKey
    @Environment(\.paneSidebarInteractive) private var isInteractive

    /// A terminal can be renamed here (`setUserTitle`); a viewer is named by
    /// its page.
    private var canRename: Bool { pane.surfaceView != nil }
    private var isEditing: Bool { rename.editing == PaneSidebarRename.key(pane: pane.id) }

    /// The accent pill only while this window is key, and never for another
    /// window's focus — that one isn't focused HERE.
    /// Another window's row is selected only as it is clicked
    /// (`PaneSidebarSharedState.clickedPane`), and then it is.
    private var isEmphasized: Bool { windowIsKey && (!isForeign || isSelected) }

    private var onAccent: Bool { isSelected && isEmphasized }

    /// Every row's height, full or rail: one number, so a pane's icon sits at
    /// the same height whether the sidebar is expanded or collapsed — and a
    /// window's header's (`PaneSidebarWindowHeader.height`), so every item of
    /// the list is one height. Its pill is `height - gap` (28: a title and a
    /// subtitle line), centered…
    static let height: CGFloat = 32
    /// …so no two pills — or a pill and anything next to it — ever touch.
    static let gap: CGFloat = 4

    var body: some View {
        Group {
            if isRail { tile } else { fullRow }
        }
        .opacity(isBeingDragged ? 0.4 : 1)
        // Hovered, the pane itself takes this row's hue (`PaneSidebarHover`).
        .onChange(of: isHovered) { hovered in
            if hovered && isInteractive {
                PaneSidebarHover.shared.hover(pane.id, color: hue)
            } else {
                PaneSidebarHover.shared.leave(pane.id)
            }
        }
        .onDisappear { PaneSidebarHover.shared.leave(pane.id) }
    }

    /// This pane's own color (`PaneSidebarHue`): its icon's, and the tint the
    /// pane takes while its row is hovered.
    private var hue: Color { PaneSidebarHue.color(for: pane, in: owner) }

    // MARK: Full row

    private var fullRow: some View {
        let fill = rowFill
        return ZStack(alignment: .trailing) {
            HStack(alignment: .center, spacing: 7) {
                PaneSidebarIcon(pane: pane, color: iconColor)
                    .frame(width: Self.iconWidth, height: 15)
                VStack(alignment: .leading, spacing: 1) {
                    if isEditing {
                        PaneSidebarRenameField(initial: displayTitle, font: .systemFont(ofSize: 12)) { name in
                            rename.editing = nil
                            guard let name = name?.trimmingCharacters(in: .whitespaces),
                                  name != displayTitle else { return }
                            // Empty: back to the terminal's own title.
                            pane.surfaceView?.setUserTitle(name)
                        }
                        .frame(height: 15)
                    } else {
                        Text(displayTitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(onAccent
                                ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                                : AnyShapeStyle(Color(nsColor: .labelColor)))
                    }
                    PaneSidebarSubtitle(pane: pane, title: displayTitle, onAccent: onAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                stateAccessories
                // Room for the trailing button, so text never runs under it.
                Color.clear.frame(width: trailingButtonWidth, height: 1)
            }
            .frame(height: Self.height - Self.gap)
            .padding(.leading, SidePanelRow.textInset + indent)
            .padding(.trailing, SidePanelRow.textInset)
            .background(PaneSidebarBusySheen(isBusy: isBusy))
            .background(fill)
            // Hover is the WHOLE row, button included. The drag source below
            // stops short of the button, so hover measured there ended the
            // moment the pointer reached the button — which hid it.
            .background(rowHover)
            // The drag source + click target, everywhere except the button.
            // An OVERLAY, so it takes exactly the row's size and can never
            // stretch the row taller.
            .overlay {
                HStack(spacing: 0) {
                    interaction
                    Color.clear
                        .frame(width: trailingButtonWidth + (trailingButtonWidth > 0 ? SidePanelRow.textInset : 0))
                        .allowsHitTesting(false)
                }
            }

            trailingButton
                .padding(.trailing, Self.trailingButtonInset)
        }
        .padding(.horizontal, SidePanelRow.fillInset)
        .padding(.vertical, Self.gap / 2)
        .help(rowHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowFill: some View {
        SidePanelRow.fill(isActive: isSelected, isHovered: isHovered, isEmphasized: isEmphasized)
    }

    @ViewBuilder
    private var stateAccessories: some View {
        HStack(spacing: 5) {
            if pane.bell && isStashed {
                Circle()
                    .fill(onAccent ? Color.white : Color(nsColor: .controlAccentColor))
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Bell")
            }
        }
        .frame(height: 15)
    }

    /// Where a row's trailing buttons sit inside its fill.
    static let trailingButtonInset: CGFloat = SidePanelRow.textInset - 4

    /// On hover: the pencil (a terminal), −/↩, then × (another window's
    /// rows: no −/↩).
    private var trailingButtonWidth: CGFloat {
        guard isHovered, !isEditing else { return 0 }
        let count = (canRename ? 1 : 0) + (isForeign ? 0 : 1) + 1
        return CGFloat(count) * PaneSidebarItemButton.size + CGFloat(count - 1) * Self.trailingButtonSpacing
    }

    static let trailingButtonSpacing: CGFloat = 4

    /// The pencil (renames a terminal in place), −/↩ (stash/restore), then ×
    /// — which closes the pane outright, in this
    /// window or another (`closePaneFromSidebar`: no confirmation, no focus
    /// taken, its session ended). Another window's rows offer only the ×.
    @ViewBuilder
    private var trailingButton: some View {
        if isHovered && !isEditing {
            HStack(spacing: Self.trailingButtonSpacing) {
                if canRename {
                    PaneSidebarItemButton(symbol: "pencil", help: "Rename pane", onAccent: onAccent) {
                        rename.editing = PaneSidebarRename.key(pane: pane.id)
                    }
                }
                if !isForeign {
                    PaneSidebarItemButton(
                        symbol: isStashed ? "arrow.uturn.backward" : "minus",
                        help: isStashed ? "Restore" : "Stash",
                        onAccent: onAccent,
                        action: isStashed ? restore : stash)
                }
                PaneSidebarItemButton(symbol: "xmark", help: "Close pane", onAccent: onAccent, action: close)
            }
        }
    }

    // MARK: Rail tile

    /// The icon's width, and the rail's: a tile is a full row with its text
    /// taken away — the same pill (`fillInset` from the card), the same icon
    /// at the same place (`textInset` into the pill) — so collapsing or
    /// expanding the sidebar moves no icon (`PaneSidebarState.railCardWidth`
    /// is exactly the pill around it).
    static let iconWidth: CGFloat = 16

    private var tile: some View {
        ZStack(alignment: .topTrailing) {
            PaneSidebarTilePill(
                isSelected: isSelected, isEmphasized: isEmphasized, isBusy: isBusy, isHovered: $isHovered
            ) {
                PaneSidebarIcon(pane: pane, color: iconColor)
                    .frame(width: Self.iconWidth, height: 15)
                interaction
            }

            if pane.bell && isStashed {
                Circle()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: 7, height: 7)
                    .offset(x: 1, y: 3)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, SidePanelRow.fillInset)
        .padding(.vertical, Self.gap / 2)
        .help(rowHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A pane card's hairline.
    static let rimWidth: CGFloat = 0.5

    /// Lit from above: the top edge at about twice the pane rim's strength,
    /// the bottom at about half of it.
    static func rim(onAccent: Bool, emphasized: Bool, scheme: ColorScheme) -> LinearGradient {
        let (top, bottom): (Color, Color) = if onAccent {
            (.white.opacity(0.35), .white.opacity(0.1))
        } else if scheme == .dark {
            (.white.opacity(emphasized ? 0.32 : 0.22), .white.opacity(emphasized ? 0.1 : 0.05))
        } else {
            (.black.opacity(emphasized ? 0.16 : 0.1), .black.opacity(emphasized ? 0.08 : 0.04))
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    static let busyFade: Animation = .easeInOut(duration: 0.6)

    // MARK: Interaction

    @ViewBuilder
    private var interaction: some View {
        // Renamed in place: the field takes the clicks.
        if isInteractive && !isEditing { interactionView }
    }

    @ViewBuilder
    private var rowHover: some View {
        if isInteractive { HoverTrackingArea(isHovered: $isHovered) }
    }

    private var interactionView: some View {
        PaneSidebarRowInteraction(
            pane: pane,
            owner: owner,
            followsPointer: !isForeign,
            onClick: click,
            menu: contextMenu)
    }

    private func click(_ event: NSEvent) {
        if isForeign {
            // Selected at once, while its window comes forward.
            PaneSidebarSharedState.shared.clickedPane = pane.id
            owner.revealPane(pane)
            return
        }
        if isStashed {
            if event.modifierFlags.contains(.option) {
                owner.exchangeStashedPane(pane)
            } else {
                owner.restorePane(pane)
            }
        } else {
            owner.window?.makeKeyAndOrderFront(nil)
            Ghostty.moveFocus(to: pane)
        }
    }

    private func stash() { owner.stashPane(pane) }
    private func restore() { owner.restorePane(pane) }
    private func close() { owner.closePaneFromSidebar(pane) }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let actions = PaneSidebarMenuActions(pane: pane, owner: owner)
        if isStashed {
            menu.addItem(actions.item("Restore", #selector(PaneSidebarMenuActions.restore)))
            if !isForeign {
                let swap = actions.item("Swap with Focused Pane", #selector(PaneSidebarMenuActions.exchange))
                swap.keyEquivalentModifierMask = [.option]
                menu.addItem(swap)
            }
        } else if !isForeign {
            menu.addItem(actions.item(
                "Stash Pane", #selector(PaneSidebarMenuActions.stash),
                enabled: owner.surfaceTree.visibleLeaves.count > 1))
        } else {
            menu.addItem(actions.item("Show Pane", #selector(PaneSidebarMenuActions.reveal)))
        }
        menu.addItem(.separator())
        menu.addItem(actions.item(
            "Move to New Window", #selector(PaneSidebarMenuActions.popOut),
            enabled: PaneMoveCoordinator.canPopOut(pane: pane, from: owner)))
        menu.addItem(.separator())
        menu.addItem(actions.item("Close Pane", #selector(PaneSidebarMenuActions.close)))
        // NSMenu holds items' targets weakly; the actions object must live as
        // long as the menu does.
        objc_setAssociatedObject(menu, &PaneSidebarMenuActions.key, actions, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }

    // MARK: Text

    private var isBusy: Bool { pane.isWorking }

    private var displayTitle: String { pane.displayLabel }

    /// The icon in the pane's hue — the same in a row and a tile, and the
    /// tint hovering it gives the pane. A touch quieter unless its pane is
    /// the focused one (or hovered), never so far as to lose the contrast.
    private var iconColor: Color {
        if onAccent { return .white }
        return (isSelected && isEmphasized) || isHovered ? hue : hue.opacity(0.8)
    }

    private var rowHelp: String {
        if isForeign {
            return isStashed ? "Raise its window and restore it there" : "Raise its window and focus it"
        }
        if isStashed { return "Click to restore · ⌥-click to swap with the focused pane" }
        return "Click to focus"
    }

    private var accessibilityText: String {
        var parts = [displayTitle]
        if isStashed { parts.append("stashed") }
        switch pane.activityState {
        case .busy: parts.append("busy")
        case .needsInput, .idle: break
        }
        return parts.joined(separator: ", ")
    }
}

/// A row's icon: the pane kind's glyph (the mock's icon set — see
/// `PaneSidebarSymbol`). Busy is the row's sheen, not the glyph's.
struct PaneSidebarIcon: View {
    @ObservedObject var pane: PaneView
    let color: Color
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let symbol = Self.symbol(for: pane) {
                PaneSidebarSymbolView(symbol: symbol, size: size)
            } else {
                // An image pane: the mock has no glyph for one.
                Image(systemName: "photo")
                    .font(.system(size: size - 1.5))
                    .frame(width: size, height: size)
            }
        }
        .foregroundStyle(color)
    }

    static func symbol(for pane: PaneView) -> PaneSidebarSymbol? {
        guard let viewer = pane.viewerView else { return .terminal }
        return switch viewer.mode {
        case .markdown, .code, .html: .document
        case .diff: .diff
        case .image: nil
        case .web: .globe
        }
    }
}

/// The row's second line. A separate view so it can observe the terminal
/// (for its working directory) or the viewer (for its location) directly.
private struct PaneSidebarSubtitle: View {
    @ObservedObject var pane: PaneView
    /// The row's title: a subtitle that only repeats it (a shell titled
    /// "~" sitting in ~) is dropped rather than shown twice.
    let title: String
    let onAccent: Bool

    var body: some View {
        Group {
            if let surface = pane.surfaceView {
                TerminalSubtitle(surface: surface, banner: pane.paneBanner, title: title, onAccent: onAccent)
            } else if let viewer = pane.viewerView {
                ViewerSubtitle(viewer: viewer, title: title, onAccent: onAccent)
            }
        }
    }

    private struct TerminalSubtitle: View {
        @ObservedObject var surface: Ghostty.SurfaceView
        let banner: String?
        let title: String
        let onAccent: Bool

        var body: some View {
            // A banner line is prose — cut its tail. A path keeps both ends.
            let isBanner = PaneSidebarText.bannerTitle(banner) == nil && PaneSidebarText.bannerLine(banner) != nil
            line(PaneSidebarText.distinct(
                    PaneSidebarText.subtitle(banner: banner, pwd: surface.pwd, viewerLocation: nil),
                    from: title),
                 onAccent, truncation: isBanner ? .tail : .middle)
        }
    }

    private struct ViewerSubtitle: View {
        @ObservedObject var viewer: ViewerView
        let title: String
        let onAccent: Bool

        var body: some View {
            line(PaneSidebarText.distinct(
                    PaneSidebarText.subtitle(banner: nil, pwd: nil, viewerLocation: viewer.location),
                    from: title),
                 onAccent, truncation: .middle)
        }
    }
}

@ViewBuilder
private func line(_ text: String?, _ onAccent: Bool, truncation: Text.TruncationMode) -> some View {
    if let text {
        Text(text)
            .font(.system(size: 10.5))
            .lineLimit(1)
            .truncationMode(truncation)
            .foregroundStyle(onAccent
                ? AnyShapeStyle(Color.white.opacity(0.75))
                : AnyShapeStyle(Color(nsColor: .secondaryLabelColor)))
    }
}

/// Target/action shims for the row's context menu.
@MainActor
private final class PaneSidebarMenuActions: NSObject {
    static var key: UInt8 = 0

    let pane: PaneView
    weak var owner: BaseTerminalController?

    init(pane: PaneView, owner: BaseTerminalController) {
        self.pane = pane
        self.owner = owner
    }

    func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc func restore() { owner?.restorePane(pane) }
    @objc func exchange() { owner?.exchangeStashedPane(pane) }
    @objc func stash() { owner?.stashPane(pane) }
    @objc func reveal() { owner?.revealPane(pane) }
    @objc func popOut() {
        guard let owner else { return }
        PaneMoveCoordinator.popOut(pane: pane, from: owner)
    }
    @objc func close() { owner?.closePaneFromSidebar(pane) }
}

/// The row's AppKit half: drag source, click, right-click menu, hover.
struct PaneSidebarRowInteraction: NSViewRepresentable {
    let pane: PaneView
    let owner: BaseTerminalController
    /// The row itself follows the pointer up and down its list while it is
    /// dragged (`PaneSidebarRowDrag`), instead of a drag image. Off for
    /// another window's row in the all-windows list.
    var followsPointer: Bool = true
    let onClick: (NSEvent) -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> PaneDragSourceView {
        let view = PaneDragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ view: PaneDragSourceView, context: Context) {
        configure(view)
    }

    private func configure(_ view: PaneDragSourceView) {
        view.pane = pane
        view.controller = owner
        view.onClick = onClick
        view.menuProvider = menu
        view.showsGrabCursor = false
        view.showsPreview = !followsPointer
        view.isListDrag = followsPointer
        guard followsPointer else {
            view.onDragStateChanged = { _ in }
            view.onDragMoved = nil
            view.onDragFinished = nil
            return
        }
        let pane = pane
        view.onDragStateChanged = { [weak view] dragging in
            guard dragging, let view, let window = view.window, let down = view.downLocation else { return }
            PaneSidebarRowDrag.shared.begin(pane, screenY: window.convertPoint(toScreen: down).y)
        }
        view.onDragMoved = { point in PaneSidebarRowDrag.shared.move(screenY: point.y) }
        view.onDragFinished = { PaneSidebarRowDrag.shared.finish(pane) }
    }
}

/// A sidebar row being dragged: the row itself follows the pointer up and
/// down its list — never sideways — drawn over the list by
/// `PaneSidebarDragGhost` while the row in the list leaves its gap. The drag
/// is still `PaneDragSession`'s (resolver, targets, drop); this is only
/// where the row is drawn. Let go, the row glides from the pointer to where
/// it landed (`isSettling`), then the list draws it again.
@MainActor
final class PaneSidebarRowDrag: ObservableObject {
    static let shared = PaneSidebarRowDrag()

    @Published private(set) var pane: PaneView?
    /// The pointer's travel: published apart, observed only by the drawn
    /// row, so a move redraws it and not every window's sidebar.
    let motion = Motion()
    /// How far the pointer has moved down since the drag began.
    private(set) var dy: CGFloat {
        get { motion.dy }
        set { motion.dy = newValue }
    }

    @MainActor
    final class Motion: ObservableObject {
        @Published fileprivate(set) var dy: CGFloat = 0
    }
    /// Let go: gliding to its place in the list.
    @Published private(set) var isSettling = false
    /// The dragged row as laid out (before any slide), in the sidebar's
    /// coordinate space — where it was, and after the drop where it landed.
    @Published var frame: CGRect?

    private var startY: CGFloat = 0
    private var generation = 0

    static let settleDuration: TimeInterval = 0.22
    static let settleAnimation: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: settleDuration)

    func begin(_ pane: PaneView, screenY: CGFloat) {
        generation += 1
        self.pane = pane
        startY = screenY
        dy = 0
        isSettling = false
    }

    func move(screenY: CGFloat) {
        guard pane != nil, !isSettling else { return }
        // Screen coordinates grow up; the list's grow down.
        dy = startY - screenY
    }

    func finish(_ pane: PaneView) {
        guard self.pane === pane else { return }
        isSettling = true
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.pane = nil
            self.isSettling = false
            self.dy = 0
            self.frame = nil
        }
    }
}

/// A pane tinted with its sidebar hue while its tile or row is hovered: a
/// wash and a rim in that color, faded in quickly and back out — bounded
/// animations, nothing running at rest.
struct PaneSidebarHoverTint: View {
    let paneID: UUID
    let cornerRadius: CGFloat

    @ObservedObject private var hover = PaneSidebarHover.shared

    var body: some View {
        let on = hover.pane == paneID
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // Half of what it first was: a hint of the pane's hue, not a
            // paint job.
            shape.fill(hover.color.opacity(0.1))
            shape.strokeBorder(hover.color.opacity(0.45), lineWidth: 2)
        }
        .opacity(on ? 1 : 0)
        .animation(on ? PaneSidebarHover.fadeIn : PaneSidebarHover.fadeOut, value: on)
    }
}

// MARK: - Item button

/// A sidebar item's action button — a pane row's −/↩ and ×, a window row's
/// and a project header's × — in one style: an 18pt circle whose wash
/// deepens and whose glyph brightens under the pointer, so it reads as
/// clickable.
struct PaneSidebarItemButton: View {
    static let size: CGFloat = 18

    /// A header's × stands where its count ends (`textInset` from its
    /// fill), a row's × closer to the edge (`trailingButtonInset`): shifted
    /// by the difference, the two line up in one column.
    static var headerOffset: CGFloat {
        SidePanelRow.textInset - PaneSidebarRow.trailingButtonInset
    }

    let symbol: String
    let help: String
    /// On the accent selection pill: white, not the secondary label color.
    var onAccent = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(glyph)
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(wash))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Not `.onHover`, as for the rows (see `HoverTrackingView`).
        .background(HoverTrackingArea(isHovered: $isHovered))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(help)
        .accessibilityLabel(help)
    }

    private var glyph: AnyShapeStyle {
        if onAccent { return AnyShapeStyle(Color.white.opacity(isHovered ? 1 : 0.85)) }
        return isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var wash: Color {
        onAccent
            ? Color.white.opacity(isHovered ? 0.35 : 0.2)
            : Color.primary.opacity(isHovered ? 0.18 : 0.08)
    }
}

/// A rail tile's pill: the row's fill (hover wash, selection), the busy
/// sheen and the glassy rim, around a glyph — what every rail tile is, a
/// pane's (`PaneSidebarRow`) or, in all windows, a window's
/// (`PaneSidebarWindowTile`), so the two read as one kind of thing.
struct PaneSidebarTilePill<Content: View>: View {
    let isSelected: Bool
    let isEmphasized: Bool
    let isBusy: Bool
    @Binding var isHovered: Bool
    @ViewBuilder let content: Content

    @Environment(\.paneSidebarInteractive) private var isInteractive
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack { content }
            .frame(maxWidth: .infinity)
            .frame(height: PaneSidebarRow.height - PaneSidebarRow.gap)
            .background(PaneSidebarBusySheen(isBusy: isBusy))
            .background(SidePanelRow.fill(isActive: isSelected, isHovered: isHovered, isEmphasized: isEmphasized))
            .overlay(rim)
            .background { if isInteractive { HoverTrackingArea(isHovered: $isHovered) } }
    }

    /// A tile's rim, so a bare glyph on the rail reads as a button. Rail
    /// only: a full row has its text to say that. Glassy, as a pane card's
    /// rim is (`PaneCard.glassCard`): the same 0.5pt hairline at the same
    /// strength, lit from above — brighter along the top edge, fading down
    /// it — rather than one solid line. It fades with the rail itself as the
    /// sidebar expands or collapses (the rail and the panel crossfade on
    /// `PaneSidebarState.columnAnimation`), never snapping at the mode switch.
    private var rim: some View {
        RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
            .strokeBorder(PaneSidebarRow.rim(onAccent: isSelected && isEmphasized, emphasized: isHovered,
                                             scheme: colorScheme),
                          lineWidth: PaneSidebarRow.rimWidth)
            .allowsHitTesting(false)
    }
}

/// Busy: a slanted band of light sweeps across a pill from right to left
/// over a slow, soft drift — the same on a row, a tile and a window's row,
/// so a tile is its row without the text.
struct PaneSidebarBusySheen: View {
    let isBusy: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isBusy && !reduceMotion {
            // Faded in and out, slowly, so it never pops on or off as work
            // starts and stops.
            PaneSidebarTileSheenLayer(cornerRadius: SidePanelRow.cornerRadius)
                .accessibilityLabel("Busy")
                .transition(.opacity.animation(PaneSidebarRow.busyFade))
        }
    }
}
