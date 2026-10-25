import Testing
@testable import Ghostty

/// Pane names belong to their window (`TargetLookup`). These pin the order a
/// name is looked up in, and that an ambiguous one is never resolved at
/// random.
struct TargetLookupTests {
    private func pane(_ window: String, mine: Bool = false) -> TargetLookup.Candidate {
        .init(kind: .pane, windowName: window, inCallerWindow: mine)
    }

    private func window(_ name: String) -> TargetLookup.Candidate {
        .init(kind: .window, windowName: name, inCallerWindow: false)
    }

    /// Two windows each hold `draft`: the caller's own is the one meant.
    @Test func theCallersOwnPaneWins() {
        #expect(TargetLookup.pick([pane("a"), pane("b", mine: true)]) == .found(1))
    }

    /// Window names are global and come next.
    @Test func aWindowOfThatNameComesBeforePanesElsewhere() {
        #expect(TargetLookup.pick([pane("a"), window("draft")]) == .found(1))
        #expect(TargetLookup.pick([window("draft"), pane("b", mine: true)]) == .found(1))
    }

    /// "This window first", not "this window only": a name only one other
    /// window holds still reaches it — an orchestrator typing into a worker.
    @Test func aPaneOnlyOneOtherWindowHoldsIsFound() {
        #expect(TargetLookup.pick([pane("a")]) == .found(0))
    }

    /// Two other windows hold it, none is the caller's (or there is no
    /// caller: a plain shell, a `ghoztty://` link): ambiguous, named.
    @Test func panesInSeveralOtherWindowsAreAmbiguous() {
        #expect(TargetLookup.pick([pane("b"), pane("a")]) == .ambiguous(windows: ["a", "b"]))
        let error = TargetLookup.ambiguityError("draft", windows: ["a", "b"])
        #expect(error.contains("'a', 'b'"))
        #expect(error.contains("+list --json"))
    }

    @Test func nothingIsNotFound() {
        #expect(TargetLookup.pick([]) == .notFound)
    }

    /// The CLI sends the caller's pane as a top-level field; the server folds
    /// it into the arguments every handler reads — before `-e`, never in the
    /// user's command, and never over one the arguments already carry.
    @Test func theCallerPaneFieldBecomesAnArgument() {
        #expect(IPCRequest(action: "close", arguments: ["--target=draft"], callerPane: "P")
            .resolvedArguments == ["--target=draft", "--caller-pane=P"])
        #expect(IPCRequest(action: "split", arguments: ["--direction=down", "-e", "echo", "hi"], callerPane: "P")
            .resolvedArguments == ["--direction=down", "--caller-pane=P", "-e", "echo", "hi"])
        #expect(IPCRequest(action: "split", arguments: ["--caller-pane=Q"], callerPane: "P")
            .resolvedArguments == ["--caller-pane=Q"])
        #expect(IPCRequest(action: "list", arguments: nil, callerPane: "P").resolvedArguments == ["--caller-pane=P"])
        #expect(IPCRequest(action: "list", arguments: nil, callerPane: nil).resolvedArguments == nil)
    }
}
