import Foundation

/// Whether a programmatic (`ghoztty +…`) command may take focus.
///
/// Agents and hooks create windows and panes while the user is working
/// somewhere else — another app, or another pane of this one. Every one of
/// those used to raise the window, activate the app, and move the caret into
/// the new pane, yanking the user out of what they were doing. So the IPC
/// default is `.background`: the surface appears, and focus stays exactly
/// where the user left it. `--focus` opts back into `.foreground`.
///
/// This is about the PROGRAMMATIC path only. A window or pane the user asked
/// for themselves (Cmd-N, Cmd-D, the menu, the command palette, File → Open,
/// the dock) focuses as it always has — those callers never consult this.
/// Neither does the `ghoztty://focus/<target>` URL scheme
/// (`IPCServer.focusTarget`), whose entire purpose is raising a window.
///
/// One flag covers all three levels of focus stealing because no caller has
/// wanted them separately: a new pane focused inside a window that stays
/// buried is invisible focus, and a raised window whose caret stayed in
/// another pane is a raise that half-happened.
enum IPCFocusPolicy: Equatable {
    /// The default. No app activation, no window raise, and the pane that
    /// had keyboard focus keeps it — for `+split` run from a pane, that is
    /// the caller's own pane.
    case background

    /// `--focus`: activate the app, raise the window, and move keyboard focus
    /// to the new (or, for an idempotent hit, the existing) pane.
    case foreground

    /// The flag that opts in. `--no-activate` used to be the opt-out; it is
    /// now the default and is accepted as a no-op so existing callers keep
    /// working (see `parse`).
    static let focusFlag = "--focus"
    static let legacyNoActivateFlag = "--no-activate"

    /// The policy an argument list asks for: the last focus flag before `-e`
    /// wins (everything after `-e` is the command being run). `--no-activate`
    /// changes nothing, in either order — it names the default, so it cannot
    /// meaningfully override an explicit `--focus`.
    static func parse(_ arguments: [String]) -> IPCFocusPolicy {
        var result: IPCFocusPolicy = .background
        for arg in arguments {
            if arg == "-e" { break }
            if let policy = fromFlag(arg) { result = policy }
        }
        return result
    }

    /// The policy one argument sets, or nil if it is not a focus flag.
    /// `--focus` and `--focus=true` opt in; `--focus=false` is the default
    /// spelled out. Any other value is not a focus flag at all, rather than
    /// a guess.
    static func fromFlag(_ arg: String) -> IPCFocusPolicy? {
        switch arg {
        case focusFlag, focusFlag + "=true": return .foreground
        case focusFlag + "=false": return .background
        default: return nil
        }
    }

    /// `NSApp.activate`.
    var activatesApp: Bool { self == .foreground }

    /// `makeKeyAndOrderFront` (or `showWindow`) on the window involved.
    var raisesWindow: Bool { self == .foreground }

    /// Make the new/target pane the first responder of its window.
    var movesKeyboardFocus: Bool { self == .foreground }
}
