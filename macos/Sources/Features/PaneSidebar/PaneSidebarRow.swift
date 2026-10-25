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
    let isQuickKill: Bool
    let isBeingDragged: Bool
    /// Leading indent of the row's content (not its fill): a window's panes
    /// sit under its header in the all-windows outline.
    var indent: CGFloat = 0

    @State private var isHovered = false
    @Environment(\.paneSidebarEmphasized) private var windowIsKey
    @Environment(\.paneSidebarInteractive) private var isInteractive

    /// The accent pill only while this window is key, and never for another
    /// window's focus — that one isn't focused HERE.
    private var isEmphasized: Bool { windowIsKey && !isForeign }

    private var onAccent: Bool { isSelected && isEmphasized }

    var body: some View {
        Group {
            if isRail { tile } else { fullRow }
        }
        .opacity(isBeingDragged ? 0.4 : 1)
    }

    // MARK: Full row

    private var fullRow: some View {
        let fill = rowFill
        return ZStack(alignment: .trailing) {
            HStack(alignment: .top, spacing: 7) {
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
            .padding(.vertical, SidePanelRow.verticalPadding)
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

    @ViewBuilder
    private var rowFill: some View {
        if isQuickKill && isHovered && !onAccent {
            RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .systemRed).opacity(0.12))
        } else {
            SidePanelRow.fill(isActive: isSelected, isHovered: isHovered, isEmphasized: isEmphasized)
        }
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

    /// Where a row's trailing button sits inside its fill. Shared with the
    /// all-windows header, whose × must line up with its panes' ×s.
    static let trailingButtonInset: CGFloat = SidePanelRow.textInset - 4

    /// −/↩ on hover (this window only); trash mode's red × always. There is
    /// NO close button outside trash mode — a stray click on the list must
    /// never end a session.
    private var trailingButtonWidth: CGFloat {
        if isQuickKill { return 18 }
        if isForeign { return 0 }
        return isHovered ? 18 : 0
    }

    @ViewBuilder
    private var trailingButton: some View {
        if isQuickKill {
            PaneSidebarKillButton(help: "Kill now — no confirmation") { kill() }
        } else if !isForeign && isHovered {
            Button(action: isStashed ? restore : stash) {
                Image(systemName: isStashed ? "arrow.uturn.backward" : "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(onAccent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(onAccent ? Color.white.opacity(0.2) : Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isStashed ? "Restore" : "Stash")
            .accessibilityLabel(isStashed ? "Restore" : "Stash")
        }
    }

    // MARK: Rail tile

    private var tile: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                PaneSidebarTileButton(
                    isSelected: isSelected, isEmphasized: isEmphasized, isHovered: isHovered,
                    hasQuestion: pane.activityState == .needsInput)
                // One letter of the pane's name — the same name its row and
                // its stacked strip show — for every kind of pane.
                let monogram = PaneSidebarText.monogram(for: displayTitle)
                PaneSidebarGlyph(isBusy: isBusy, color: onAccent ? .white : Color(nsColor: .labelColor),
                                 maskKey: monogram) {
                    Text(monogram)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
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

            if isQuickKill {
                PaneSidebarKillButton(size: 13, help: "Kill now — no confirmation") { kill() }
                    .offset(x: -23, y: -4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
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
    private func kill() { owner.killPane(pane) }

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

    private var isBusy: Bool { pane.activityState == .busy }

    private var displayTitle: String { pane.displayLabel }

    private var iconColor: Color {
        if onAccent { return .white }
        return isBusy ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor)
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

/// A rail tile drawn as a small raised button, the same for every pane: a
/// soft vertical gradient, a sheen across its top half, a hairline rim and a
/// short drop shadow. The selected pane's is the accent, lit the same way;
/// hover lifts it a little. A pane with a question gets an accent rim — no
/// badge on the tile. All static: nothing here animates.
struct PaneSidebarTileButton: View {
    let isSelected: Bool
    /// The window is key: only then is a selection the accent (as AppKit
    /// draws a sidebar's); otherwise it is the neutral button, lifted.
    var isEmphasized: Bool = true
    let isHovered: Bool
    let hasQuestion: Bool

    @Environment(\.colorScheme) private var colorScheme

    static let cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        let isSelected = self.isSelected && isEmphasized
        let isHovered = self.isHovered || (self.isSelected && !isEmphasized)
        let accent = Color(nsColor: .controlAccentColor)
        let base: [Color] = isSelected
            ? [accent.opacity(0.92), accent]
            : dark
                ? [Color.white.opacity(isHovered ? 0.20 : 0.15), Color.white.opacity(isHovered ? 0.10 : 0.06)]
                : [Color.white.opacity(isHovered ? 1 : 0.95), Color.black.opacity(isHovered ? 0.05 : 0.07)]
        shape
            .fill(LinearGradient(colors: base, startPoint: .top, endPoint: .bottom))
            // The sheen: light falling on the top half, gone by the middle.
            .overlay(
                shape.fill(LinearGradient(
                    stops: [
                        .init(color: .white.opacity(isSelected ? 0.32 : dark ? 0.16 : 0.55), location: 0),
                        .init(color: .white.opacity(0), location: 0.55),
                    ],
                    startPoint: .top, endPoint: .bottom)))
            // A rim: bright along the top edge, darker below — a bevel.
            .overlay(
                shape.strokeBorder(
                    hasQuestion
                        ? AnyShapeStyle(accent.opacity(isSelected ? 0 : 0.9))
                        : AnyShapeStyle(LinearGradient(
                            colors: [
                                .white.opacity(isSelected ? 0.45 : dark ? 0.22 : 0.9),
                                .black.opacity(isSelected ? 0.25 : dark ? 0.35 : 0.14),
                            ],
                            startPoint: .top, endPoint: .bottom)),
                    lineWidth: hasQuestion && !isSelected ? 1.5 : 0.75))
            .shadow(color: .black.opacity(dark ? 0.35 : 0.14), radius: 1.5, y: 1)
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
        view.onDragStateChanged = { _ in }
    }
}
