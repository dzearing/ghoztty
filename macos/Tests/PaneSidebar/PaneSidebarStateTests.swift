import AppKit
import Testing
@testable import Ghostty

/// The pane sidebar's layout rules and row text — pure, so pinned here.
struct PaneSidebarStateTests {
    typealias State = PaneSidebarState

    // MARK: Mode

    @Test func expandedInAWideWindowIsTheFlatPanel() {
        #expect(State.mode(isExpanded: true, isHidden: false, windowWidth: 1200) == .expanded)
    }

    @Test func collapsedIsTheRail() {
        #expect(State.mode(isExpanded: false, isHidden: false, windowWidth: 1200) == .collapsed)
    }

    @Test func aNarrowWindowShowsTheRailEvenWhenExpanded() {
        #expect(State.mode(isExpanded: true, isHidden: false, windowWidth: 700) == .collapsed)
        #expect(State.mode(isExpanded: true, isHidden: false, windowWidth: State.narrowWindowWidth) == .expanded)
        #expect(!State.canExpand(windowWidth: 700), "the rail's expand button is off there")
        #expect(State.canExpand(windowWidth: State.narrowWindowWidth))
    }

    @Test func hiddenWinsOverEverything() {
        #expect(State.mode(isExpanded: true, isHidden: true, windowWidth: 1200) == .hidden)
        #expect(State.mode(isExpanded: false, isHidden: true, windowWidth: 400) == .hidden)
    }

    /// The pin became collapse/expand: a stored pin (pinned = the flat full
    /// panel) reads as expanded, and the new key wins once there is one.
    @Test func aStoredPinReadsAsExpanded() throws {
        let defaults = try #require(UserDefaults(suiteName: "PaneSidebarStateTests-\(UUID().uuidString)"))
        #expect(!State.storedExpanded(defaults), "collapsed by default")
        defaults.set(true, forKey: "PaneSidebarPinned")
        #expect(State.storedExpanded(defaults))
        defaults.set(false, forKey: "PaneSidebarExpanded")
        #expect(!State.storedExpanded(defaults))
    }

    // MARK: Column

    @Test func theColumnIsTheRailPlusItsMargins() {
        #expect(State.columnWidth(for: .collapsed, panelWidth: 240, elevated: false) == 44 + 2 * GlassCard.outerMargin)
    }

    @Test func elevatedRailSharesItsGapWithTheGrid() {
        // The grid's own margin is the gap after the rail, so the rail adds
        // none: rail-to-edge and rail-to-panes come out the same.
        let insets = State.railInsets(elevated: true)
        #expect(insets.leading == PaneElevation.margin)
        #expect(insets.vertical == PaneElevation.margin, "the rail's ends line up with the panes'")
        #expect(insets.trailing == 0)
        #expect(insets.leading == insets.trailing + PaneElevation.margin, "equal gutters either side")
        #expect(State.columnWidth(for: .collapsed, panelWidth: 240, elevated: true) == PaneElevation.margin + 44)
    }

    @Test func theColumnIsThePanelWhenExpanded() {
        #expect(State.columnWidth(for: .expanded, panelWidth: 260, elevated: true) == 260)
    }

    @Test func hiddenTakesNoColumn() {
        #expect(State.columnWidth(for: .hidden, panelWidth: 260, elevated: false) == 0)
    }

    @Test func theRailsColumnDoesNotDependOnThePanelWidth() {
        let rail = State.columnWidth(for: .collapsed, panelWidth: 300, elevated: false)
        #expect(rail == State.railColumnWidth(elevated: false))
    }

    @Test func widthIsClamped() {
        #expect(State.clampWidth(10) == State.minimumWidth)
        #expect(State.clampWidth(10_000) == State.maximumWidth)
        #expect(State.clampWidth(250) == 250)
    }

    // MARK: Edge drag thresholds agree with the rail and panel sizes

    @Test func thresholdsSitBetweenTheRailAndTheNarrowestPanel() {
        #expect(State.railCardWidth < State.expandThreshold)
        #expect(State.expandThreshold < State.minimumWidth)
    }

    // MARK: Transient state is never persisted

    @MainActor
    @Test func transientStateStartsOff() {
        let state = PaneSidebarState(isExpanded: true, isHidden: false)
        #expect(!state.isQuickKill, "a window must never come back in kill mode")
        #expect(!state.showsAllWindows, "the all-windows scope is off by default")
    }

    // MARK: All-windows folds

    @Test func otherWindowsStartFoldedAndThisOneOpen() {
        #expect(State.isWindowFolded(isThisWindow: false, isToggled: false, isSearching: false))
        #expect(!State.isWindowFolded(isThisWindow: true, isToggled: false, isSearching: false))
    }

    @Test func aToggleFlipsTheDefault() {
        #expect(!State.isWindowFolded(isThisWindow: false, isToggled: true, isSearching: false))
        #expect(State.isWindowFolded(isThisWindow: true, isToggled: true, isSearching: false))
    }

    @Test func aSearchUnfoldsEverything() {
        for isThisWindow in [false, true] {
            for isToggled in [false, true] {
                #expect(!State.isWindowFolded(isThisWindow: isThisWindow, isToggled: isToggled, isSearching: true))
            }
        }
    }

    @MainActor
    @Test func leavingAllWindowsForgetsTheFolds() {
        let state = PaneSidebarState(isExpanded: true, isHidden: false)
        state.showsAllWindows = true
        state.toggledWindows = [ObjectIdentifier(state)]
        state.showsAllWindows = false
        #expect(state.toggledWindows.isEmpty, "the next look starts from the default")
    }
}

struct PaneSidebarTextTests {
    typealias Text = PaneSidebarText

    // MARK: Monograms

    @Test func aMonogramIsOneLetterOfTheName() {
        #expect(Text.monogram(for: "relay") == "R")
        #expect(Text.monogram(for: "claude — relay") == "C")
        #expect(Text.monogram(for: "zsh") == "Z")
        #expect(Text.monogram(for: "npm run dev") == "N")
        #expect(Text.monogram(for: "2026 notes") == "2")
    }

    @Test func aLeadingGlyphIsSkipped() {
        // Claude Code titles its pane "✳ <task>"; a path opens with "~/".
        #expect(Text.monogram(for: "✳ Fix strip labels") == "F")
        #expect(Text.monogram(for: "⠂ Building") == "B")
        #expect(Text.monogram(for: "~/git/ghoztty") == "G")
        #expect(Text.monogram(for: "/tmp") == "T")
    }

    @Test func aNameWithNoLettersShowsWhatItHas() {
        #expect(Text.monogram(for: "~") == "~", "a shell sitting at home")
        #expect(Text.monogram(for: "  ") == "•")
        #expect(Text.monogram(for: "") == "•")
    }

    /// The tile is lettered from what the row and the stacked strip call the
    /// pane: its banner title when it has one.
    @Test func theMonogramFollowsTheBannerTitle() {
        let label = Text.label(title: "✳ claude", pwd: "/x", kind: "Terminal", banner: "## Sidebar reorder")
        #expect(Text.monogram(for: label) == "S")
        let untitled = Text.label(title: "zsh", pwd: "/x", kind: "Terminal", banner: "**Goal:** ship")
        #expect(Text.monogram(for: untitled) == "Z")
    }

    // MARK: Title

    @Test func aRealTitleIsKept() {
        #expect(Text.title("claude — relay", pwd: "/x", kind: "Terminal") == "claude — relay")
    }

    @Test func thePlaceholderGhostFallsBackToTheDirectory() {
        #expect(Text.title("👻", pwd: "/Users/me/git/ghoztty", kind: "Terminal") == "ghoztty")
        #expect(Text.title("  ", pwd: nil, kind: "Terminal") == "Terminal")
        #expect(Text.title("👻", pwd: "/", kind: "Terminal") == "Terminal")
    }

    @Test func aSubtitleThatRepeatsTheTitleIsDropped() {
        #expect(Text.distinct("~", from: "~") == nil)
        #expect(Text.distinct("~/git/x", from: "zsh") == "~/git/x")
        #expect(Text.distinct(nil, from: "zsh") == nil)
    }

    // MARK: Banner line

    @Test func theBannerLineIsPlainText() {
        #expect(Text.bannerLine("**Pane sidebar** — _building_ the `UI`") == "Pane sidebar — building the UI")
        #expect(Text.bannerLine("See [the PR](https://example.com/1) now") == "See the PR now")
    }

    @Test func theFirstMeaningfulLineWins() {
        #expect(Text.bannerLine("\n---\n**Title**\nmore") == "Title")
        #expect(Text.bannerLine("| a | b |\n|---|---|\nSummary") == "Summary")
        #expect(Text.bannerLine("**Goal**\\nsecond") == "Goal", "a literal \\n is a line break")
    }

    @Test func snakeCaseSurvivesUnderscoreStripping() {
        #expect(Text.bannerLine("run some_tool now") == "run some_tool now")
    }

    @Test func escapesKeepTheirCharacter() {
        #expect(Text.bannerLine(#"a \* star"#) == "a * star")
    }

    @Test func noBannerIsNil() {
        #expect(Text.bannerLine(nil) == nil)
        #expect(Text.bannerLine("   ") == nil)
    }

    @Test func aHeadingLineIsItsText() {
        #expect(Text.bannerLine("## Fix strip labels\n|  |  |\n|---|---|") == "Fix strip labels")
    }

    // MARK: Banner title

    /// What the banner hook writes on its CLI path, verbatim.
    static let hookBanner = "## Strip label from banner title\n|  |  |\n|---|---|\n"
        + "| **Goal** | Minimized pane strips show the banner title |\n| **Status** | Reading code · Working |"

    @Test func theHooksHeadingIsTheTitle() {
        #expect(Text.bannerTitle(Self.hookBanner) == "Strip label from banner title")
        #expect(Text.bannerTitle("## Fix strip labels\n|  |  |\n|---|---|\n| **Status** | Working |") == "Fix strip labels")
    }

    @Test func theHooksOSCLineGivesItsBoldTitle() {
        #expect(Text.bannerTitle("**Fix strip labels** · **Goal:** Label strips · **Status:** Working") == "Fix strip labels")
        #expect(Text.bannerTitle("**Fix strip labels**") == "Fix strip labels")
    }

    @Test func aBannerWithoutATitleHasNone() {
        // The hook with no title set: just its table, or its OSC labels.
        #expect(Text.bannerTitle("|  |  |\n|---|---|\n| **Prompt** | do the thing |\n| **Status** | Idle |") == nil)
        #expect(Text.bannerTitle("**Prompt:** do the thing · **Status:** Idle") == nil)
        // Prose, even prose that opens in bold, names no title.
        #expect(Text.bannerTitle("Deploying to staging") == nil)
        #expect(Text.bannerTitle("**PR #123** — _3 files_, +120/−45") == nil)
        #expect(Text.bannerTitle("**PR** [#12](https://example.com/12)") == nil)
        // A bold line heads a multi-line banner only as a label.
        #expect(Text.bannerTitle("**Last result**\n- [x] Fixed it") == nil)
        // A heading counts only on the first line.
        #expect(Text.bannerTitle("Status: ok\n## Later") == nil)
        #expect(Text.bannerTitle(nil) == nil)
        #expect(Text.bannerTitle("  \n ") == nil)
    }

    @Test func aHeadingNeedsItsSpaceAndText() {
        #expect(Text.bannerTitle("##Title") == nil)
        #expect(Text.bannerTitle("## ") == nil)
        #expect(Text.bannerTitle("####### Seven") == nil)
        #expect(Text.bannerTitle("# One") == "One")
        #expect(Text.bannerTitle("###### Six") == "Six")
    }

    @Test func theTitleIsPlainText() {
        #expect(Text.bannerTitle("## **Fix** the `strip` [label](https://example.com) _now_") == "Fix the strip label now")
        #expect(Text.bannerTitle("**Ship `v2`** · **Status:** ok") == "Ship v2")
        #expect(Text.bannerTitle("## Escaped \\* star") == "Escaped * star")
        #expect(Text.bannerTitle("## Keep some_tool") == "Keep some_tool")
    }

    @Test func aLiteralBackslashNIsALineBreakForTheTitle() {
        #expect(Text.bannerTitle("## Title\\n| a | b |") == "Title")
    }

    // MARK: Label

    @Test func theBannerTitleNamesThePane() {
        #expect(Text.label(title: "✳ Claude Code", pwd: "/tmp", kind: "Terminal", banner: Self.hookBanner)
                == "Strip label from banner title")
    }

    @Test func withoutABannerTitleThePaneTitleNamesIt() {
        #expect(Text.label(title: "✳ Claude Code", pwd: "/tmp", kind: "Terminal", banner: nil) == "✳ Claude Code")
        #expect(Text.label(title: "✳ Claude Code", pwd: "/tmp", kind: "Terminal",
                           banner: "|  |  |\n|---|---|\n| **Status** | Idle |") == "✳ Claude Code")
        #expect(Text.label(title: "👻", pwd: "/tmp/proj", kind: "Terminal", banner: "Just prose") == "proj")
    }

    // MARK: Subtitle

    @Test func aTitledBannerLeavesTheSubtitleToTheDirectory() {
        // The title already names the row; repeating it as the subtitle says
        // nothing.
        #expect(Text.subtitle(banner: Self.hookBanner, pwd: "/tmp", viewerLocation: nil) == "/tmp")
    }

    @Test func theBannerBeatsTheWorkingDirectory() {
        #expect(Text.subtitle(banner: "**Relay** cutover", pwd: "/tmp", viewerLocation: nil) == "Relay cutover")
    }

    @Test func theWorkingDirectoryIsAbbreviated() {
        let home = NSHomeDirectory()
        #expect(Text.subtitle(banner: nil, pwd: home + "/git/x", viewerLocation: nil) == "~/git/x")
    }

    @Test func aViewerShowsItsLocation() {
        #expect(Text.subtitle(banner: nil, pwd: nil, viewerLocation: "https://example.com") == "https://example.com")
    }
}

struct PaneSidebarShimmerTests {
    typealias Shimmer = PaneSidebarShimmer

    @Test func theBandStartsOffTheLeadingEdgeAndEndsOffTheTrailingOne() {
        #expect(Shimmer.bandPosition(at: 0) == 1)
        let endOfSweep = Shimmer.period * Shimmer.sweepFraction
        #expect(abs(Shimmer.bandPosition(at: endOfSweep)) < 0.0001)
    }

    @Test func itRestsAfterTheSweep() {
        let rest = Shimmer.period * (Shimmer.sweepFraction + 0.1)
        #expect(Shimmer.bandPosition(at: rest) == 0)
    }

    @Test func itRepeatsEveryPeriod() {
        #expect(abs(Shimmer.bandPosition(at: 0.3) - Shimmer.bandPosition(at: 0.3 + Shimmer.period)) < 0.0001)
    }

    @Test func atEitherEndTheBrightBandIsOffTheGlyph() {
        let width: CGFloat = 14
        let bandCenter = { (position: Double) -> CGFloat in
            Shimmer.offset(position: position, width: width) + width * Shimmer.bandWidthFactor / 2
        }
        // The band's bright middle sits half a glyph outside the glyph at
        // both ends, so the sweep enters and leaves rather than popping.
        #expect(bandCenter(1) <= -width / 2 + 0.0001)
        #expect(bandCenter(0) >= width + width / 2 - 0.0001)
    }
}

/// The grab handle's reveal rule. The pane's top band is where you reach for
/// the handle — and with a banner, that band IS the banner, under which the
/// terminal can't see the pointer.
struct SurfaceGrabHandleRevealTests {
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)

    private func reveals(
        cursorVisible: Bool = true,
        hovering: Bool = false,
        overBanner: Bool = false,
        at location: CGPoint?
    ) -> Bool {
        Ghostty.SurfaceGrabHandle.revealsHandle(
            cursorVisible: cursorVisible, isHovering: hovering, isDragging: false,
            pointerOverBanner: overBanner, mouseLocation: location, surfaceBounds: bounds)
    }

    @Test func theTopBandOfTheTerminalReveals() {
        #expect(reveals(at: CGPoint(x: 300, y: 390)))   // non-flipped: top is maxY
        #expect(!reveals(at: CGPoint(x: 300, y: 100)))
    }

    @Test func aPointerOnTheBannerReveals() {
        // Over the banner the terminal reports no location at all — the bug.
        #expect(reveals(overBanner: true, at: nil))
    }

    @Test func aPointerNowhereHides() {
        #expect(!reveals(at: nil))
    }

    @Test func aHiddenCursorAlwaysHides() {
        #expect(!reveals(cursorVisible: false, overBanner: true, at: nil))
    }
}

struct PaneSidebarWindowGroupingTests {
    typealias G = PaneSidebarWindowGrouping

    @Test func aProjectColonWorktreeTitleSplits() {
        let parts = G.split("ghoztty: pane-sidebar")
        #expect(parts?.project == "ghoztty")
        #expect(parts?.worktree == "pane-sidebar")
    }

    @Test func otherTitlesDoNot() {
        #expect(G.split("zsh") == nil)
        #expect(G.split("ghoztty:") == nil, "no worktree")
        #expect(G.split(": main") == nil, "no project")
        #expect(G.split("http://localhost:3000") == nil, "a colon without a space after it")
        #expect(G.split(String(repeating: "x", count: 50) + ": y") == nil, "a sentence, not a project")
    }

    @Test func windowsAreSortedByNameAndGroupedByProject() {
        let sections = G.sections([
            (id: 1, title: "zsh"),
            (id: 2, title: "ghoztty: windows-amd64"),
            (id: 3, title: "relay: main"),
            (id: 4, title: "ghoztty: pane-sidebar"),
            (id: 5, title: "Build logs"),
            (id: 6, title: "ghoztty: main"),
        ])
        #expect(sections.map { $0.project ?? $0.windows[0].title } == ["Build logs", "ghoztty", "relay", "zsh"])
        let ghoztty = sections[1]
        #expect(ghoztty.windows.map(\.label) == ["main", "pane-sidebar", "windows-amd64"])
        #expect(ghoztty.windows.map(\.id) == [6, 4, 2])
        #expect(sections[0].windows[0].label == "Build logs", "an ungrouped window keeps its whole name")
    }

    @Test func numbersSortByValueAndCaseIsIgnored() {
        let sections = G.sections([
            (id: 1, title: "app: wt-10"), (id: 2, title: "app: wt-2"), (id: 3, title: "App2: x"),
        ])
        #expect(sections[0].windows.map(\.label) == ["wt-2", "wt-10"])
    }
}

struct PaneSidebarFilterTests {
    private func hit(_ query: String, _ fields: [String?]) -> Bool {
        PaneSidebarFilter.matches(PaneSidebarFilter.terms(query), in: fields)
    }

    @Test func aProjectNameKeepsEveryPaneInIt() {
        #expect(hit("ghoztty", ["ghoztty: pane-sidebar", "zsh", nil]))
        #expect(!hit("ghoztty", ["relay: main", "zsh", "~/git/relay"]))
    }

    @Test func everyTermMustMatchSomewhere() {
        let fields: [String?] = ["ghoztty: pane-sidebar", "claude — pane-sidebar", "Pane sidebar — building"]
        #expect(hit("ghoztty claude", fields))
        #expect(!hit("ghoztty relay", fields))
    }

    @Test func caseAndAccentsDoNotMatter() {
        #expect(hit("CAFE", ["café logs"]))
    }

    @Test func anEmptyQueryMatchesEverything() {
        #expect(hit("   ", ["anything"]))
        #expect(PaneSidebarFilter.terms("  a  b ") == ["a", "b"])
    }
}

/// The sidebar's own order of a window's panes (`PaneSidebarOrder`).
struct PaneSidebarOrderTests {
    typealias Order = PaneSidebarOrder
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    @Test func noOrderIsTheTreesOrder() {
        #expect(Order.arranged([a, b, c], by: []) == [a, b, c])
    }

    @Test func theOrderWins() {
        #expect(Order.arranged([a, b, c], by: [c, a, b]) == [c, a, b])
    }

    @Test func aNewPaneGoesAfterItsTreeNeighbour() {
        // d was split off b (tree a, b, d, c); the list had c first.
        #expect(Order.arranged([a, b, d, c], by: [c, a, b]) == [c, a, b, d])
        // Two new panes in a row stay together, in tree order.
        #expect(Order.arranged([a, d, e, b], by: [b, a]) == [b, a, d, e])
    }

    @Test func aNewPaneFirstInTheTreeGoesBeforeItsNeighbour() {
        #expect(Order.arranged([d, a, b], by: [b, a]) == [b, d, a])
    }

    @Test func panesNotOnShowAreLeftOut() {
        #expect(Order.arranged([a, c], by: [c, b, a]) == [c, a])
    }

    @Test func movingPutsThePaneAtTheIndex() {
        let all: Set = [a, b, c]
        #expect(Order.moving(a, to: 2, visible: [a, b, c], order: [], existing: all) == [b, c, a])
        #expect(Order.moving(c, to: 0, visible: [a, b, c], order: [], existing: all) == [c, a, b])
        #expect(Order.moving(b, to: 99, visible: [a, b, c], order: [], existing: all) == [a, c, b], "clamped")
    }

    /// A stashed pane keeps its place, so restoring it brings it back there.
    @Test func aStashedPaneKeepsItsPlaceThroughAMove() {
        // b is stashed; the list shows a, c, d.
        let moved = Order.moving(d, to: 0, visible: [a, c, d], order: [a, b, c, d], existing: [a, b, c, d])
        #expect(moved == [d, a, b, c])
        #expect(Order.arranged([a, b, c, d], by: moved) == [d, a, b, c], "b comes back after a")
    }

    @Test func aClosedPaneIsPrunedOnTheNextMove() {
        let moved = Order.moving(c, to: 0, visible: [a, c], order: [a, b, c], existing: [a, c])
        #expect(moved == [c, a])
    }

    // MARK: Shift

    @Test func rowsSlideToMakeRoom() {
        // Row 0 dragged down to land at 2: rows 1 and 2 slide up, row 3 stays.
        #expect((0...3).map { Order.shift(index: $0, source: 0, target: 2) } == [0, -1, -1, 0])
        // Row 3 dragged up to land at 1: rows 1 and 2 slide down.
        #expect((0...3).map { Order.shift(index: $0, source: 3, target: 1) } == [0, 1, 1, 0])
        // Dropped where it was: nothing moves.
        #expect((0...3).map { Order.shift(index: $0, source: 2, target: 2) } == [0, 0, 0, 0])
    }

    @Test func aRowComingInOpensAGapAndOneLeavingClosesIt() {
        #expect((0...2).map { Order.shift(index: $0, source: nil, target: 1) } == [0, 1, 1])
        #expect((0...2).map { Order.shift(index: $0, source: 0, target: nil) } == [0, -1, -1])
    }
}
