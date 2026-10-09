import Testing
@testable import Ghostty

/// Every `ghoztty +…` command that creates or finds a window/pane used to
/// activate the app, raise the window, and move the caret into the new pane —
/// so an agent opening a side pane, or `/wt` opening a window, yanked the user
/// out of whatever they were doing. The default is now background, with
/// `--focus` to opt back in. What these pin is the flag vocabulary: the
/// default, the opt-in, and that the retired opt-out (`--no-activate`) is
/// still accepted and harmless, because callers in the wild pass it.
struct IPCFocusPolicyTests {
    @Test func noFlagIsBackground() {
        let parsed = IPCServer.parseArguments(["--target=dev", "--view=README.md"])
        #expect(parsed.focus == .background)
        #expect(!parsed.focus.activatesApp)
        #expect(!parsed.focus.raisesWindow)
        #expect(!parsed.focus.movesKeyboardFocus)
    }

    @Test func focusFlagIsForeground() {
        let parsed = IPCServer.parseArguments(["--focus", "--view=README.md"])
        #expect(parsed.focus == .foreground)
        #expect(parsed.focus.activatesApp)
        #expect(parsed.focus.raisesWindow)
        #expect(parsed.focus.movesKeyboardFocus)
    }

    /// `--no-activate` names what is now the default. It must not fail the
    /// command and must not leak into anything else (it used to fall through
    /// as nothing; it still does).
    @Test func noActivateIsAcceptedAsANoOp() {
        let parsed = IPCServer.parseArguments(["--no-activate", "--target=x", "-e", "zsh"])
        #expect(parsed.focus == .background)
        #expect(parsed.target == "x")
        #expect(parsed.config.command == "zsh")
    }

    /// A no-op flag cannot override an explicit request, in either order.
    @Test func focusWinsOverNoActivate() {
        #expect(IPCServer.parseArguments(["--focus", "--no-activate"]).focus == .foreground)
        #expect(IPCServer.parseArguments(["--no-activate", "--focus"]).focus == .foreground)
    }

    /// After `-e` everything is the command — `--focus` there is an argument
    /// to the program being run, not a request to focus.
    @Test func focusAfterDashEIsPartOfTheCommand() {
        let parsed = IPCServer.parseArguments(["-e", "mytool", "--focus"])
        #expect(parsed.focus == .background)
        #expect(parsed.config.command == "mytool --focus")
        #expect(IPCFocusPolicy.parse(["-e", "mytool", "--focus"]) == .background)
    }

    /// `+new-remote-window` has its own parser; it reads the same flag.
    @Test func remoteWindowArgumentsParseTheSameFlag() {
        #expect(IPCFocusPolicy.parse(["--host=h", "--port=1"]) == .background)
        #expect(IPCFocusPolicy.parse(["--host=h", "--port=1", "--focus"]) == .foreground)
        #expect(IPCFocusPolicy.parse(["--host=h", "--port=1", "--no-activate"]) == .background)
    }

    /// `--focus=true|false` spell the two states the way the rest of the
    /// CLI spells booleans; any other value is not a focus flag, rather than
    /// being guessed at.
    @Test func explicitBooleanSpellings() {
        #expect(IPCServer.parseArguments(["--focus=true"]).focus == .foreground)
        #expect(IPCServer.parseArguments(["--focus=false"]).focus == .background)
        #expect(IPCServer.parseArguments(["--focus", "--focus=false"]).focus == .background)
        #expect(IPCServer.parseArguments(["--focus=yes"]).focus == .background)
        #expect(IPCServer.parseArguments(["--focused"]).focus == .background)
    }
}
