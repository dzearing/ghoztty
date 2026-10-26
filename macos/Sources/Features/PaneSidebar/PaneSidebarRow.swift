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
    @Environment(\.paneSidebarEmphasized) private var windowIsKey
    @Environment(\.paneSidebarInteractive) private var isInteractive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The accent pill only while this window is key, and never for another
    /// window's focus — that one isn't focused HERE.
    private var isEmphasized: Bool { windowIsKey && !isForeign }

    private var onAccent: Bool { isSelected && isEmphasized }

    /// Every row's height, full or rail: one number, so a pane's icon sits at
    /// the same height whether the sidebar is expanded or collapsed.
    static let height: CGFloat = 38

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

    /// This pane's own color (`PaneSidebarHue`): its tile's tint, its row's
    /// icon, and the tint the pane takes while either is hovered.
    private var hue: Color { PaneSidebarHue.color(for: pane, in: owner) }

    // MARK: Full row

    private var fullRow: some View {
        let fill = rowFill
        return ZStack(alignment: .trailing) {
            HStack(alignment: .center, spacing: 7) {
                PaneSidebarIcon(pane: pane, isBusy: isBusy, color: iconColor)
                    .frame(width: 16, height: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(onAccent
                            ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                            : AnyShapeStyle(Color(nsColor: .labelColor)))
                    PaneSidebarSubtitle(pane: pane, title: displayTitle, onAccent: onAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                stateAccessories
                // Room for the trailing button, so text never runs under it.
                Color.clear.frame(width: trailingButtonWidth, height: 1)
            }
            .frame(height: Self.height - 1)
            .padding(.leading, SidePanelRow.textInset + indent)
            .padding(.trailing, SidePanelRow.textInset)
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
        .padding(.vertical, 0.5)
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
            if pane.activityState == .needsInput {
                PaneSidebarQuestionBadge(isOnAccent: onAccent)
            }
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

    /// On hover (this window's rows): −/↩, then ×.
    private var trailingButtonWidth: CGFloat {
        isForeign || !isHovered ? 0 : 18 * 2 + Self.trailingButtonSpacing
    }

    static let trailingButtonSpacing: CGFloat = 4

    /// −/↩ (stash/restore), then × — the ordinary close, as right-click →
    /// Close Pane: it asks first when something is running or the pane is
    /// on another machine, and is undoable. (It replaced the sidebar's trash
    /// mode, whose red × killed with no confirmation and no undo.)
    @ViewBuilder
    private var trailingButton: some View {
        if !isForeign && isHovered {
            HStack(spacing: Self.trailingButtonSpacing) {
                rowButton(isStashed ? "arrow.uturn.backward" : "minus",
                          help: isStashed ? "Restore" : "Stash",
                          action: isStashed ? restore : stash)
                rowButton("xmark", help: "Close pane", action: close)
            }
        }
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(onAccent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)
                .background(Circle().fill(onAccent ? Color.white.opacity(0.2) : Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Rail tile

    private var tile: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                PaneSidebarTileButton(
                    hue: hue,
                    isSelected: isSelected, isEmphasized: isEmphasized, isHovered: isHovered,
                    hasQuestion: pane.activityState == .needsInput)
                // One letter of the pane's name — the same name its row and
                // its stacked strip show — for every kind of pane.
                // Busy: a sheen sweeps diagonally across the tile — its own
                // glass sheen, moving — rather than through the letter.
                if isBusy && !reduceMotion {
                    // Faded in, so it never pops on when work starts.
                    PaneSidebarTileSheenLayer(cornerRadius: PaneSidebarTileButton.cornerRadius)
                        .accessibilityLabel("Busy")
                        .transition(.opacity.animation(.easeOut(duration: 0.25)))
                }
                // The pane kind's glyph, as its row shows it — the tile's hue
                // tells panes apart — muted unless it is the focused pane's.
                // Busy is the tile's sheen, so the glyph itself stays still.
                PaneSidebarIcon(
                    pane: pane, isBusy: false,
                    color: onAccent ? Color.white
                        : Color(nsColor: (isSelected && isEmphasized) || isHovered ? .labelColor : .secondaryLabelColor),
                    size: 15)
                .shadow(color: .black.opacity(onAccent ? 0.25 : 0), radius: 0.5, y: 0.5)
                interaction
            }
            .frame(width: 30, height: 30)
            .background(rowHover)

            if pane.bell && isStashed {
                Circle()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: 7, height: 7)
                    .offset(x: 1, y: -1)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .help(rowHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Interaction

    @ViewBuilder
    private var interaction: some View {
        if isInteractive { interactionView }
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

    /// The row's icon in the pane's hue, so a row and its pane's tile — and
    /// the tint hovering it gives the pane — are one color; muted unless its
    /// pane is the focused one (or hovered), as the tiles are.
    private var iconColor: Color {
        if onAccent { return .white }
        return (isSelected && isEmphasized) || isHovered ? hue : hue.opacity(0.55)
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
        case .needsInput: parts.append("has a question")
        case .idle: break
        }
        return parts.joined(separator: ", ")
    }
}

/// A rail tile: a small pane of glass, the pane banner's own
/// (`GlassCardBackground` — a see-through wash, the elliptical sheen, the
/// specular rim, a masked drop shadow scaled to its size), so the color
/// behind shows through it as it does through a banner — tinted with the
/// pane's own hue (`PaneSidebarHue`), so each tile is its own shade. Hover
/// deepens the tint; the selected pane's is deeper still, with a white rim.
/// A pane with a question gets an accent rim — no badge on the tile. All
/// static: nothing here animates.
struct PaneSidebarTileButton: View {
    var hue: Color? = nil
    let isSelected: Bool
    /// The window is key: only then is a selection the accent (as AppKit
    /// draws a sidebar's); otherwise it is the plain glass, thickened.
    var isEmphasized: Bool = true
    let isHovered: Bool
    let hasQuestion: Bool

    @Environment(\.colorScheme) private var colorScheme

    static let cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let accent = Color(nsColor: .controlAccentColor)
        let light = colorScheme == .light
        let wash = light ? Color.black : Color.white
        let selected = isSelected && isEmphasized
        // The focused pane's tile carries its hue; every other tile is a
        // muted shade of its own, lifted while hovered — as is the focused
        // one while the window is not key.
        let fill: Color = hue.map { hue in
            hue.opacity(selected ? 0.6 : isHovered ? 0.34 : isSelected ? 0.28 : 0.13)
        } ?? (selected
            ? accent.opacity(0.55)
            : wash.opacity(isSelected ? 0.16 : isHovered ? 0.12 : 0.07))
        Color.clear
            .modifier(GlassCardBackground(
                fill: AnyShapeStyle(fill), cornerRadius: Self.cornerRadius,
                shadowRadius: 2.5, shadowOffset: 1.5))
            .overlay {
                if hasQuestion {
                    shape.strokeBorder(accent.opacity(selected ? 0.95 : 0.85), lineWidth: 1.5)
                }
            }
            // The selection is a ring OUTSIDE the tile, a point clear of it,
            // so the tile's own glass edge stays whole.
            .overlay {
                if isSelected && hue != nil {
                    let gap: CGFloat = 1, line: CGFloat = 1.5
                    RoundedRectangle(cornerRadius: Self.cornerRadius + gap + line, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.75 : 0.4), lineWidth: line)
                        .padding(-(gap + line))
                }
            }
    }
}

/// A row's icon: the pane kind's glyph (the mock's icon set — see
/// `PaneSidebarSymbol`), shimmering while busy.
struct PaneSidebarIcon: View {
    @ObservedObject var pane: PaneView
    let isBusy: Bool
    let color: Color
    var size: CGFloat = 14

    var body: some View {
        let symbol = Self.symbol(for: pane)
        PaneSidebarGlyph(isBusy: isBusy, color: color, maskKey: "\(String(describing: symbol))@\(size)") {
            if let symbol {
                PaneSidebarSymbolView(symbol: symbol, size: size)
            } else {
                // An image pane: the mock has no glyph for one.
                Image(systemName: "photo")
                    .font(.system(size: size - 1.5))
                    .frame(width: size, height: size)
            }
        }
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
    /// How far the pointer has moved down since the drag began.
    @Published private(set) var dy: CGFloat = 0
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
