import AppKit
import WebKit

/// A viewer pane's web view. WebKit makes its web view first responder
/// whenever the page focuses an element — an `autofocus` field after a load,
/// a script's `focus()` — whatever pane the caret was in. The pane decides
/// whether that may happen (`mayTakeFocus`): a pane minimized into a blade
/// must not take the caret on its own, since focus brings a blade back out.
///
/// Gated where the caret moves, in the window's `makeFirstResponder`
/// (`TerminalWindow`, `QuickTerminalWindow`), not in `becomeFirstResponder`:
/// AppKit publishes the new first responder before it asks the view, so the
/// window's observers (`BaseTerminalController.publishFocusedPane`) had
/// already brought the blade out by the time a refusal could land — and the
/// refusal left the window itself holding the caret.
final class ViewerWebView: WKWebView {
    /// Asked each time the web view would become first responder; nil or
    /// true lets it.
    var mayTakeFocus: (() -> Bool)?

    /// Whether a window may make `responder` its first responder now.
    static func mayBecomeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let webView = responder as? ViewerWebView else { return true }
        return webView.mayTakeFocus?() ?? true
    }
}
