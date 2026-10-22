import Foundation


/// What `+split --name=<name>` does when a pane already holds that name.
///
/// The name is the idempotency key: re-running the same launch must not
/// duplicate the pane, so a matching request REUSES it. It used to reuse on the
/// name alone — silently, from any window, whatever was asked for — so a caller
/// asking for `--view=b.html` beside itself got exit 0 and nothing, while a
/// pane of the same name in another window went on showing `a.html`. Now:
///
///   * A request the existing pane already satisfies is reused, and the reply
///     says so and names the window — which may not be the caller's: pane
///     names are one namespace across every window (they are `--target`s), so
///     a second pane cannot take the name without orphaning the first.
///   * A request it does NOT satisfy — another `--view`, or a terminal where a
///     viewer stands (or the reverse) — fails, naming the pane, its window,
///     and what it shows. Retargeting the pane instead would hijack whatever
///     else put it there, often another agent in another window.
///
/// Pure, so the policy is testable without windows (`SplitNameCollisionTests`).
enum SplitNameCollision: Equatable {
    /// The existing pane is the answer; no split is created.
    case reuse(message: String)
    /// The request conflicts with the existing pane; the command fails.
    case conflict(error: String)

    /// What currently holds the name, and where.
    struct Existing: Equatable {
        var kind: Kind
        /// The `windowName` of the window holding it (the window itself, for
        /// `.window`).
        var windowName: String
        /// Whether that window is the one the split would have anchored in.
        var inAnchorWindow: Bool

        enum Kind: Equatable {
            case terminal
            /// `location` is what it shows now, `homeLocation` what it was
            /// opened with.
            case viewer(location: String, homeLocation: String)
            /// A WINDOW of that name: `--target`s and pane names are one
            /// namespace, so a pane cannot take it.
            case window
        }
    }

    static func decide(
        name: String,
        existing: Existing,
        requestedView: String?
    ) -> SplitNameCollision {
        let window = existing.inAnchorWindow
            ? "this window ('\(existing.windowName)')"
            : "window '\(existing.windowName)', not the window this split was for"

        let closeHint = "Use another --name, or close it first: ghoztty +close --target=\(name)"

        switch (existing.kind, requestedView) {
        case (.window, _):
            return .conflict(error: "'\(name)' is already the name of a window, so no pane can take it. Use another --name.")

        case (.terminal, nil):
            return .reuse(message: "pane '\(name)' already exists in \(window); reused it, no split created")

        case (.viewer(let location, let home), let view?) where matches(view, location: location, home: home):
            return .reuse(message: "pane '\(name)' already exists in \(window), showing \(view); reused it, no split created")

        case (.viewer(let location, _), let view?):
            return .conflict(error: "pane '\(name)' already exists in \(window), showing \(location), not \(view). "
                + closeHint)

        case (.viewer(let location, _), nil):
            return .conflict(error: "pane '\(name)' already exists in \(window) as a viewer pane showing \(location), "
                + "not a terminal. " + closeHint)

        case (.terminal, let view?):
            return .conflict(error: "pane '\(name)' already exists in \(window) as a terminal pane, so it cannot show \(view). "
                + closeHint)
        }
    }

    /// Whether the viewer satisfies a request for `view`. Its HOME counts as
    /// well as its current location: re-running the launch that opened it is
    /// the same request even after a redirect or a click moved the page.
    private static func matches(_ view: String, location: String, home: String) -> Bool {
        let wanted = normalized(view)
        return wanted == normalized(location) || wanted == normalized(home)
    }

    /// Spelling differences that name the same thing: a trailing slash
    /// (`https://x.com` vs `https://x.com/`, `/a/dir/`), and `file://` vs a
    /// bare path.
    private static func normalized(_ location: String) -> String {
        var value = location
        if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
            value = url.path
        }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
