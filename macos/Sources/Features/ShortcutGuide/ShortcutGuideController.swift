import Cocoa
import SwiftUI
import GhosttyKit

/// The keyboard shortcut guide window (Help → Keyboard Shortcuts,
/// `show_keyboard_shortcuts` — ⌘/ by default — and the command palette).
///
/// Other UI opens it with `ShortcutGuideController.shared.show()` or the
/// `AppDelegate.showKeyboardShortcuts(_:)` selector.
@MainActor
final class ShortcutGuideController: NSWindowController, NSWindowDelegate {
    static let shared = ShortcutGuideController()

    private let model: ShortcutGuideModel
    private var keyMonitor: Any?
    private var configObserver: NSObjectProtocol?

    /// Frame autosave key: the window remembers its size and position.
    private static let autosaveName = "ShortcutGuideWindow"

    private init() {
        let catalog = (NSApp.delegate as? AppDelegate)?.ghostty.config.config.map(KeybindCatalog.init(config:))
            ?? KeybindCatalog(effective: [], defaults: [], actionKeys: KeybindCatalog.libraryActionKeys())
        model = ShortcutGuideModel(catalog: catalog)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        window.identifier = NSUserInterfaceItemIdentifier("com.dzearing.ghoztty.shortcutGuide")
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        super.init(window: window)
        window.delegate = self

        model.onRun = { [weak self] row in self?.run(row) }
        window.contentView = NSHostingView(rootView: ShortcutGuideView(
            model: model,
            onOpenConfig: { (NSApp.delegate as? AppDelegate)?.ghostty.openConfigFile() },
            onPrint: { [weak self] in self?.printCheatSheet() }))

        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)

        // Reload when the config does, so customizations show up live.
        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard notification.object == nil,
                  let config = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config
            else { return }
            MainActor.assumeIsolated { self?.reload(config: config) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Showing

    /// Shows (or brings forward) the guide, with the search field focused.
    func show(config: Ghostty.Config? = nil) {
        if let config { reload(config: config) }
        installKeyMonitor()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.focusSearchToken += 1
    }

    /// Shows the guide filtered to `query` (e.g. a Settings link to one action).
    func show(query: String) {
        show()
        model.query = query
    }

    func reload(config: Ghostty.Config) {
        guard let cfg = config.config else { return }
        model.catalog = KeybindCatalog(config: cfg)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Keyboard

    /// ↑/↓ move the selection (even while typing in the search field), ↩ runs
    /// it, esc clears the search and then closes, ⌘F focuses the search.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch (event.keyCode, mods) {
        case (126, []): // ↑
            model.moveSelection(by: -1)
            return true
        case (125, []): // ↓
            model.moveSelection(by: 1)
            return true
        case (36, []), (76, []): // ↩, enter
            return model.runSelection()
        case (53, []): // esc
            if !model.query.isEmpty {
                model.query = ""
            } else if model.selection != nil {
                model.selection = nil
            } else {
                window?.performClose(nil)
            }
            return true
        case (3, [.command]): // ⌘F
            model.focusSearchToken += 1
            return true
        default:
            return false
        }
    }

    // MARK: First responder (⌘W while the guide is key)

    @IBAction func close(_ sender: Any) { window?.performClose(sender) }
    @IBAction func closeWindow(_ sender: Any) { window?.performClose(sender) }
    @objc func cancel(_ sender: Any?) { window?.performClose(sender) }

    // MARK: Running

    /// Runs a (safe) row's action where the user was working: the most recent
    /// terminal window is brought forward and the action performed there, as
    /// the command palette would.
    private func run(_ row: ShortcutRow) {
        guard row.isRunnable, let action = row.actions.first else { return }
        let controller = TerminalController.preferredParent
        controller?.window?.makeKeyAndOrderFront(nil)
        // Next turn, once that window is key, so menu-routed actions see it.
        DispatchQueue.main.async {
            if !ViewerKeyFallback.performPalette(action: action, in: controller) {
                NSSound.beep()
            }
        }
    }

    // MARK: Printing

    /// Prints a compact cheat sheet of every bound shortcut (Save as PDF from
    /// the print panel to export one).
    func printCheatSheet() {
        let text = Self.cheatSheet(model.catalog)
        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 40
        printInfo.rightMargin = 40
        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(text)
        view.isEditable = false
        view.drawsBackground = false
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: printInfo)
        op.jobTitle = "Ghoztty Keyboard Shortcuts"
        if let window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    /// The cheat sheet's text: each category, then title ⇥ keys per row.
    static func cheatSheet(_ catalog: KeybindCatalog) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 9.5)
        let keys = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 500)]
        para.paragraphSpacing = 1.5
        out.append(NSAttributedString(string: "Ghoztty Keyboard Shortcuts\n", attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold), .foregroundColor: NSColor.black]))
        let rows = catalog.rows().filter(\.isBound)
        for category in ShortcutCategory.allCases {
            let inCat = rows.filter { $0.category == category }
            guard !inCat.isEmpty else { continue }
            out.append(NSAttributedString(string: "\n\(category.title)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.black]))
            for row in inCat {
                let combo = row.bindings.map { b -> String in
                    if let family = b.familyKeys {
                        let mods = b.trigger.steps.first?.modifiers.map(\.glyph).joined() ?? ""
                        return mods + " + " + family.map(KeyTrigger.displayName(forKey:)).joined(separator: " ")
                    }
                    return b.trigger.display
                }.joined(separator: "  /  ")
                out.append(NSAttributedString(string: row.title, attributes: [
                    .font: body, .foregroundColor: NSColor.black, .paragraphStyle: para]))
                out.append(NSAttributedString(string: "\t\(combo)\n", attributes: [
                    .font: keys, .foregroundColor: NSColor.black, .paragraphStyle: para]))
            }
        }
        return out
    }
}
