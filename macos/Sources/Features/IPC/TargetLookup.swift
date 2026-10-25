import Foundation

/// Which open window or pane a `--target`/`--name` means.
///
/// Pane names belong to the window they were created in. They used to be one
/// namespace across every window, and that was the main way agents reported a
/// side pane that never opened: session A's `+split --name=draft` and session
/// B's same command, in another window, collided — B got exit 0 and "reused"
/// A's pane, in A's window, and a later `+close --target=draft` from B closed
/// it. Now two windows can each hold a pane called `draft`, and a name is
/// looked up in the CALLER's window first (`--caller-pane=`, the CLI's
/// `$GHOZTTY_PANE_ID`).
///
/// The order, for one name:
///
///   1. A pane of that name in the caller's window.
///   2. A window of that name. Window names stay global and unique.
///   3. A pane of that name in any other window — but only if exactly one
///      window has one. Two or more is AMBIGUOUS, and the command fails
///      naming the windows rather than pick one: picking would be acting on
///      some other agent's pane at random.
///
/// A caller with no pane (a plain shell, a `ghoztty://focus/` link) starts at
/// step 2. Pane ids never get here: a uuid names exactly one pane.
///
/// Pure, so the policy is testable without windows (`TargetLookupTests`).
enum TargetLookup {
    struct Candidate: Equatable {
        enum Kind: Equatable { case window, pane }
        var kind: Kind
        /// The name of the window the candidate is (`.window`) or is in.
        var windowName: String
        /// Whether that window is the caller's.
        var inCallerWindow: Bool
    }

    enum Pick: Equatable {
        /// `candidates[index]` is what the name means.
        case found(Int)
        /// Panes in several windows hold the name and none is the caller's.
        case ambiguous(windows: [String])
        case notFound
    }

    static func pick(_ candidates: [Candidate]) -> Pick {
        if let mine = candidates.firstIndex(where: { $0.kind == .pane && $0.inCallerWindow }) {
            return .found(mine)
        }
        if let window = candidates.firstIndex(where: { $0.kind == .window }) {
            return .found(window)
        }
        let panes = candidates.indices.filter { candidates[$0].kind == .pane }
        switch panes.count {
        case 0: return .notFound
        case 1: return .found(panes[0])
        default: return .ambiguous(windows: panes.map { candidates[$0].windowName }.sorted())
        }
    }

    /// What a command says when its name is ambiguous.
    static func ambiguityError(_ name: String, windows: [String]) -> String {
        let list = windows.map { "'\($0)'" }.joined(separator: ", ")
        return "'\(name)' names a pane in \(windows.count) windows (\(list)), so it is ambiguous here. "
            + "Run the command from a pane in the window you mean, or target the pane by its id "
            + "(`id` in `ghoztty +list --json`)."
    }
}
