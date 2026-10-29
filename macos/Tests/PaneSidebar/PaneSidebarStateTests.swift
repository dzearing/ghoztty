import AppKit
import Combine
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
        #expect(!PaneSidebarSharedState.storedExpanded(defaults), "collapsed by default")
        defaults.set(true, forKey: "PaneSidebarPinned")
        #expect(PaneSidebarSharedState.storedExpanded(defaults))
        defaults.set(false, forKey: "PaneSidebarExpanded")
        #expect(!PaneSidebarSharedState.storedExpanded(defaults))
    }

    // MARK: Column

    @Test func theColumnIsTheRailPlusItsMargins() {
        #expect(State.columnWidth(for: .collapsed, panelWidth: 240, elevated: false) == State.railCardWidth + 2 * GlassCard.outerMargin)
    }

    @Test func elevatedRailSharesItsGapWithTheGrid() {
        // The grid's own margin is the gap after the rail, so the rail adds
        // none: rail-to-edge and rail-to-panes come out the same.
        let insets = State.railInsets(elevated: true)
        #expect(insets.leading == PaneElevation.margin)
        #expect(insets.vertical == PaneElevation.margin, "the rail's ends line up with the panes'")
        #expect(insets.trailing == 0)
        #expect(insets.leading == insets.trailing + PaneElevation.margin, "equal gutters either side")
        #expect(State.columnWidth(for: .collapsed, panelWidth: 240, elevated: true) == PaneElevation.margin + State.railCardWidth)
    }

    @Test func theColumnIsThePanelWhenExpanded() {
        // The rail's card at the panel's width, in the rail's margins.
        #expect(State.columnWidth(for: .expanded, panelWidth: 260, elevated: true) == PaneElevation.margin + 260)
        #expect(State.columnWidth(for: .expanded, panelWidth: 260, elevated: false) == 260 + 2 * GlassCard.outerMargin)
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

    /// The edge grip pulls the rail out once the panel would fit, and tucks
    /// the panel back in well under its minimum — with a band between where
    /// each stays what it is, so the edge does not flicker at one width.
    @Test func anEdgeDragPullsTheRailOutAndTucksThePanelIn() {
        #expect(State.edgeDrag(proposed: 100, isExpanded: false) == (false, nil), "short of the panel: still the rail")
        #expect(State.edgeDrag(proposed: 150, isExpanded: false) == (false, nil))
        #expect(State.edgeDrag(proposed: 200, isExpanded: false) == (true, 200), "past its minimum: out")
        #expect(State.edgeDrag(proposed: 9_000, isExpanded: true) == (true, State.maximumWidth))
        #expect(State.edgeDrag(proposed: 150, isExpanded: true) == (true, State.minimumWidth), "stops at its minimum")
        #expect(State.edgeDrag(proposed: 100, isExpanded: true) == (false, nil), "well under: tucked in")
    }

    @MainActor
    @Test func theRailsGripIsItsGutter() {
        #expect(State.edgeGrip(for: .collapsed, elevated: true) == (0, PaneElevation.margin))
        #expect(State.edgeReach(for: .collapsed, elevated: true) == PaneElevation.margin)
        #expect(State.edgeGrip(for: .collapsed, elevated: false) == (0, GlassCard.outerMargin),
                "flat: the card's own trailing margin")
        #expect(State.edgeReach(for: .collapsed, elevated: false) == 0)
    }

    @Test func thresholdsSitBetweenTheRailAndTheNarrowestPanel() {
        #expect(State.railCardWidth < State.expandThreshold)
        #expect(State.expandThreshold < State.minimumWidth)
    }

    // MARK: All-windows folds

    @Test func everyWindowIsFoldedUntilUnfolded() {
        #expect(State.isWindowFolded(isUnfolded: false, isSearching: false))
        #expect(!State.isWindowFolded(isUnfolded: true, isSearching: false))
    }

    @Test func aSearchUnfoldsEverything() {
        for isUnfolded in [false, true] {
            #expect(!State.isWindowFolded(isUnfolded: isUnfolded, isSearching: true))
        }
    }
}

/// The sidebar state every window shares (`PaneSidebarSharedState`), and each
/// window's view of it (`PaneSidebarState`).
@MainActor
struct PaneSidebarSharedStateTests {
    /// A fresh defaults domain, so nothing reads or writes the app's own.
    private func defaults() -> UserDefaults {
        let name = "PaneSidebarSharedStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aChangeInOneWindowIsAChangeInEvery() {
        let shared = PaneSidebarSharedState(defaults: defaults())
        let a = PaneSidebarState(shared: shared), b = PaneSidebarState(shared: shared)
        var bChanged = 0
        let watch = b.objectWillChange.sink { bChanged += 1 }
        defer { watch.cancel() }

        a.isExpanded = true
        a.isHidden = true
        a.width = 300
        a.showsAllWindows = true
        a.filter = "relay"
        a.foldedProjects = ["ghoztty"]
        #expect(b.isExpanded && b.isHidden && b.width == 300)
        #expect(b.showsAllWindows && b.filter == "relay" && b.foldedProjects == ["ghoztty"])
        #expect(bChanged >= 6, "b's sidebar re-renders for each: \(bChanged)")
    }

    @Test func thePaneOrderIsEachWindowsOwn() {
        let shared = PaneSidebarSharedState(defaults: defaults())
        let a = PaneSidebarState(shared: shared), b = PaneSidebarState(shared: shared)
        a.order = [UUID()]
        #expect(b.order.isEmpty)
        #expect(a.windowID != b.windowID)
    }

    @Test func theLayoutAndTheOrderPersistTheScopeDoesNot() async throws {
        let store = defaults()
        let shared = PaneSidebarSharedState(defaults: store)
        shared.isExpanded = true
        shared.isHidden = true
        shared.width = 300
        shared.windowOrder = ["project:relay", "project:ghoztty"]
        shared.setShowsAllWindows(true)
        // The width is written once a drag pauses.
        try await Task.sleep(nanoseconds: 500_000_000)
        let relaunched = PaneSidebarSharedState(defaults: store)
        #expect(relaunched.isExpanded && relaunched.isHidden && relaunched.width == 300)
        #expect(relaunched.windowOrder == ["project:relay", "project:ghoztty"])
        #expect(!relaunched.showsAllWindows, "the all-windows scope starts off")
    }

    @Test func theLegacyPinReadsAsExpanded() {
        let store = defaults()
        store.set(true, forKey: PaneSidebarSharedState.legacyPinnedKey)
        #expect(PaneSidebarSharedState(defaults: store).isExpanded)
    }

    /// A window row's drag starting or landing redraws the list it is in —
    /// the window in use — and the others only when next key: observed by
    /// every window's view, it re-rendered every window's whole list as a
    /// drag began (a 0.3–0.7s stall with 20 windows).
    @Test func anItemDragRedrawsOnlyTheWindowInUse() {
        let shared = PaneSidebarSharedState(defaults: defaults())
        let drag = PaneSidebarItemDrag()
        let live = PaneSidebarState(shared: shared, roster: nil, itemDrag: drag)
        let background = PaneSidebarState(shared: shared, roster: nil, itemDrag: drag)
        background.isLive = { false }
        var redraws = (live: 0, background: 0)
        let a = live.objectWillChange.sink { redraws.live += 1 }
        let b = background.objectWillChange.sink { redraws.background += 1 }
        drag.objectWillChange.send()
        #expect(redraws.live == 1)
        #expect(redraws.background == 0, "a background window does not redraw")
        background.catchUp()
        #expect(redraws.background == 1, "it catches up when it is next key")
        _ = (a, b)
    }

    @Test func turningOnAllWindowsFoldsEveryWindowItWasTurnedOnFromToo() {
        let shared = PaneSidebarSharedState(defaults: defaults())
        let a = PaneSidebarState(shared: shared), b = PaneSidebarState(shared: shared)
        a.showsAllWindows = true
        // The same in both windows' lists: every window folded, a included.
        for viewer in [a, b] {
            #expect(viewer.isWindowFolded(a.windowID, isSearching: false))
            #expect(viewer.isWindowFolded(b.windowID, isSearching: false))
        }
        b.toggleWindowFold(b.windowID)
        #expect(!a.isWindowFolded(b.windowID, isSearching: false), "a fold in b shows in a")
    }

    @Test func leavingAllWindowsForgetsTheFoldsAndTheSearch() {
        let shared = PaneSidebarSharedState(defaults: defaults())
        let a = PaneSidebarState(shared: shared), b = PaneSidebarState(shared: shared)
        a.showsAllWindows = true
        a.toggleWindowFold(b.windowID)
        a.filter = "x"
        b.showsAllWindows = false
        #expect(shared.unfoldedWindows.isEmpty, "the next look starts from the default")
        #expect(a.filter.isEmpty)
        b.showsAllWindows = true
        #expect(shared.unfoldedWindows.isEmpty, "turned on again, every window starts folded")
    }
}

struct PaneSidebarTextTests {
    typealias Text = PaneSidebarText

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

    @Test func aNameTheUserGaveItBeatsTheBannerTitle() {
        #expect(Text.label(title: "build", pwd: "/tmp", kind: "Terminal", banner: Self.hookBanner,
                           userTitle: "build") == "build")
        #expect(Text.label(title: "build", pwd: "/tmp", kind: "Terminal", banner: Self.hookBanner,
                           userTitle: nil) == "Strip label from banner title")
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

struct PaneSidebarWindowRollUpTests {
    @Test func aWindowIsBusyWhileAnyOfItsPanesWorks() {
        typealias A = PaneSidebarWindowActivity
        #expect(!A.isBusy(activity: [.idle, .idle], progress: [false, false]))
        #expect(A.isBusy(activity: [.idle, .busy], progress: [false, false]), "the hook says busy")
        #expect(A.isBusy(activity: [.idle, .idle], progress: [false, true]), "a progress report")
        #expect(!A.isBusy(activity: [.needsInput], progress: [false]), "a question is not work")
        #expect(!A.isBusy(activity: [], progress: []))
    }

    /// Open, a window's panes are under its row and show their own busy:
    /// the row rolls it up only folded. The rail's tile always does.
    @Test func aWindowRowShowsItsPanesBusyOnlyFolded() {
        typealias H = PaneSidebarWindowHeader
        #expect(H.showsBusy(isFolded: true, isBusy: true))
        #expect(!H.showsBusy(isFolded: false, isBusy: true))
        #expect(!H.showsBusy(isFolded: true, isBusy: false))
    }

    /// The window in use is selected in all windows, folded or not; open,
    /// its focused pane holds the accent, so its row is selected unaccented.
    @Test func theSelectedWindowsRowLooksSelected() {
        typealias H = PaneSidebarWindowHeader
        func sel(_ this: Bool, folded: Bool, clicked: Bool = false, all: Bool = true) -> H.Selection {
            H.selection(isThisWindow: this, isFolded: folded, isClicked: clicked, showsAllWindows: all)
        }
        #expect(sel(true, folded: true) == .accent)
        #expect(sel(true, folded: false) == .unemphasized)
        #expect(sel(false, folded: true) == .none)
        #expect(sel(false, folded: false, clicked: true) == .accent, "clicked, while it comes forward")
        // This window's own Panes list: its header is the list's title, and
        // its pane carries the selection while it is open.
        #expect(sel(true, folded: false, all: false) == .none)
        #expect(sel(true, folded: true, all: false) == .accent)
    }
}

struct PaneSidebarSheenTests {
    typealias Sheen = PaneSidebarSheen

    /// The band's light, in the row's coordinates, with the band layer's
    /// left edge at `x`.
    private func light(at x: CGFloat, width: CGFloat) -> ClosedRange<CGFloat> {
        let w = Sheen.bandWidthFactor * width
        return (x + Sheen.light.lowerBound * w)...(x + Sheen.light.upperBound * w)
    }

    @Test(arguments: [36.0, 240.0, 380.0])
    func aSweepStartsOffTheRowAndLeavesItEntirely(width: CGFloat) {
        let height = PaneSidebarRow.height - PaneSidebarRow.gap
        let (from, to) = Sheen.travel(width: width, height: height)
        #expect(light(at: from, width: width).lowerBound > width, "starts past the right edge")
        // Its top is `slant * height` right of its bottom.
        #expect(light(at: to, width: width).upperBound + Sheen.slant * height < 0,
                "ends past the left edge, top included")
        #expect(from > to, "right to left")
    }

    /// The drift covers the whole row at every point of its cycle — no bare
    /// corner, no gap — and a cycle moves it exactly one period left, so it
    /// loops without a jump.
    @Test(arguments: [36.0, 240.0, 380.0])
    func theDriftCoversTheRowAndLoopsSeamlessly(width: CGFloat) {
        let height = PaneSidebarRow.height - PaneSidebarRow.gap
        let drift = Sheen.Drift(width: width, height: height)
        #expect(drift.period >= width, "stretched: wider than the row")
        #expect(drift.from - drift.to == drift.period, "one period a cycle, right to left")
        for x in [drift.from, drift.to] {
            #expect(x <= 0 && x + Sheen.slant * height <= 0, "covers the left edge at bottom and top")
            #expect(x + drift.length >= width, "covers the right edge")
        }
        #expect(drift.locations.count % 2 == 1, "starts and ends on a trough")
        let periods = drift.length / drift.period
        #expect(periods == periods.rounded(), "whole periods, so the pattern repeats exactly")
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
        #expect(sections.map { $0.project ?? $0.windows[0].title } == ["Build logs", "zsh", "ghoztty", "relay"],
                "ungrouped windows first, then the groups")
        let ghoztty = sections[2]
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

/// The all-windows list's own order of windows and project groups
/// (`PaneSidebarWindowGrouping.sections(_:order:)`), reconciled against the
/// windows open now.
struct PaneSidebarWindowOrderTests {
    typealias G = PaneSidebarWindowGrouping
    typealias Order = PaneSidebarOrder

    /// Windows 1… titled in that order.
    private func windows(_ titles: [String]) -> [(id: Int, title: String)] {
        titles.enumerated().map { (id: $0.offset + 1, title: $0.element) }
    }

    /// What the list shows: a group as `[project]`, its windows indented.
    private func shown(_ sections: [G.Section<Int>]) -> [String] {
        sections.flatMap { section -> [String] in
            guard let project = section.project else { return section.windows.map(\.label) }
            return ["[\(project)]"] + section.windows.map { "  " + $0.label }
        }
    }

    private let titles = ["relay: main", "ghoztty: wt-2", "Build logs", "ghoztty: wt-10", "ghoztty: alpha"]

    @Test func noOrderIsByName() {
        #expect(shown(G.sections(windows(titles), order: [])) == [
            "Build logs", "[ghoztty]", "  alpha", "  wt-2", "  wt-10", "[relay]", "  main"])
    }

    /// Windows arrive frontmost first; the window you are in must not come
    /// out on top of others with the same name.
    @Test func sameNamedWindowsListTheSameWhicheverIsFrontmost() {
        let titles = ["~", "~", "ghoztty: main", "ghoztty: main", "~"]
        let open = windows(titles)
        let expected = shown(G.sections(open, order: []))
        let ids = G.sections(open, order: []).flatMap { $0.windows.map(\.id) }
        for front in open.indices {
            var frontFirst = open
            frontFirst.insert(frontFirst.remove(at: front), at: 0)
            #expect(shown(G.sections(frontFirst, order: [])) == expected)
            #expect(G.sections(frontFirst, order: []).flatMap { $0.windows.map(\.id) } == ids,
                    "window \(front + 1) frontmost")
        }
    }

    @Test func theOrderWinsAtBothLevels() {
        let order = ["project:relay", G.key(window: 3), "project:ghoztty",
                     G.key(window: 4), G.key(window: 2), G.key(window: 5)]
        #expect(shown(G.sections(windows(titles), order: order)) == [
            "Build logs", "[relay]", "  main", "[ghoztty]", "  wt-10", "  wt-2", "  alpha"])
    }

    /// The user's report: four windows under `projects`, three of them
    /// ungrouped (Claude-titled) windows the order kept right after the
    /// group — drawn as its windows, they stayed when it folded. However the
    /// order has them, ungrouped windows lead the list, groups after.
    @Test func ungroupedWindowsComeBeforeEveryGroup() {
        let open = windows(["projects: manager", "Prompt.md instructions", "Release status", "zecho: main"])
        #expect(shown(G.sections(open, order: [])) == [
            "Prompt.md instructions", "Release status", "[projects]", "  manager", "[zecho]", "  main"])
        let order = ["project:projects", G.key(window: 1), G.key(window: 3), G.key(window: 2), "project:zecho"]
        #expect(shown(G.sections(open, order: order)) == [
            "Release status", "Prompt.md instructions", "[projects]", "  manager", "[zecho]", "  main"],
                "dragged after the group: still above it, in their dragged order")
    }

    @Test func aNewWindowGoesAfterItsNameNeighbour() {
        // relay was dragged to the top; ghoztty's wt-10 above alpha and wt-2.
        let order = ["project:relay", "project:ghoztty", G.key(window: 3),
                     G.key(window: 4), G.key(window: 5), G.key(window: 2)]
        // wt-3 (id 6) opens: by name it follows wt-2, wherever that went.
        let opened = windows(titles + ["ghoztty: wt-3"])
        #expect(shown(G.sections(opened, order: order)) == [
            "Build logs", "[relay]", "  main", "[ghoztty]", "  wt-10", "  alpha", "  wt-2", "  wt-3"])
        // Nothing before it known: before the name neighbour after it.
        let first = windows(titles + ["ghoztty: aardvark"])
        #expect(shown(G.sections(first, order: order)).prefix(5) == ["Build logs", "[relay]", "  main", "[ghoztty]", "  wt-10"])
        #expect(G.sections(first, order: order)[2].windows.map(\.label) == ["wt-10", "aardvark", "alpha", "wt-2"],
                "it has no name neighbour before it the order knows, so it goes before alpha")
    }

    @Test func aNewGroupGoesAfterItsNameNeighbour() {
        let order = ["project:relay", "project:ghoztty", G.key(window: 3)]
        // "infra" sorts after "ghoztty", before "relay": it follows ghoztty.
        let opened = windows(titles + ["infra: prod"])
        #expect(shown(G.sections(opened, order: order)).prefix(5) == ["Build logs", "[relay]", "  main", "[ghoztty]", "  alpha"])
        let tops = G.sections(opened, order: order).map(\.id)
        #expect(tops == [G.key(window: 3), "project:relay", "project:ghoztty", "project:infra"])
    }

    @Test func closedWindowsDropOutAndArePrunedOnTheNextMove() {
        let order = ["project:relay", G.key(window: 3), "project:ghoztty", G.key(window: 9)]
        let open = windows(titles)
        // Window 9 is gone: not shown...
        #expect(!G.sections(open, order: order).flatMap(\.windows).contains { $0.id == 9 })
        // ...and dropped when the order is next written.
        let tops = G.sections(open, order: order).map(\.id)
        let moved = Order.moving("project:ghoztty", to: 0, visible: tops, order: order,
                                 existing: G.keys(G.sections(open, order: order)))
        #expect(moved == ["project:ghoztty", "project:relay", G.key(window: 3)])
    }

    @Test func movingAGroupKeepsItsWindowsOrder() {
        // ghoztty's windows were reordered; then the group is moved.
        let order = [G.key(window: 4), G.key(window: 5), G.key(window: 2)]
        let open = windows(titles)
        let tops = G.sections(open, order: order).map(\.id)
        let moved = Order.moving("project:ghoztty", to: 2, visible: tops, order: order,
                                 existing: G.keys(G.sections(open, order: order)))
        #expect(shown(G.sections(open, order: moved)) == [
            "Build logs", "[relay]", "  main", "[ghoztty]", "  wt-10", "  alpha", "  wt-2"])
    }

    /// `open` with window `id` retitled `title`.
    private func retitled(_ open: [(id: Int, title: String)], _ id: Int, _ title: String) -> [(id: Int, title: String)] {
        open.map { $0.id == id ? (id: id, title: title) : $0 }
    }

    /// The user's report: a window third in a never-dragged list, renamed,
    /// jumped to the top. A rename pins the list as shown, so nothing moves.
    @Test func renamingAWindowKeepsItsPlace() {
        let open = windows(["alpha", "beta", "gamma", "delta"])
        let before = G.sections(open, order: [])
        #expect(shown(before) == ["alpha", "beta", "delta", "gamma"])
        // gamma (id 3) → "aaa", which by name would go first.
        let order = G.renaming(window: 3, to: "aaa", in: before)
        #expect(shown(G.sections(retitled(open, 3, "aaa"), order: order)) == ["alpha", "beta", "delta", "aaa"])
        // Already dragged: still where it was.
        let dragged = [G.key(window: 4), G.key(window: 3), G.key(window: 1), G.key(window: 2)]
        let shownDragged = G.sections(open, order: dragged)
        #expect(shown(G.sections(retitled(open, 3, "zzz"), order: G.renaming(window: 3, to: "zzz", in: shownDragged)))
                == ["delta", "zzz", "alpha", "beta"])
    }

    /// A window the order has never seen (opened after the last drag) is
    /// placed by name; renamed, it must still not move.
    @Test func renamingAWindowTheOrderHasNotSeenKeepsItsPlace() {
        let order = [G.key(window: 2), G.key(window: 4), G.key(window: 1)]
        let open = windows(["alpha", "beta", "gamma", "delta"])
        let before = G.sections(open, order: order)
        // gamma (id 3), unseen, follows delta, its name neighbour.
        #expect(shown(before) == ["beta", "delta", "gamma", "alpha"])
        // As "bb" its name neighbour would be alpha, at the end.
        #expect(shown(G.sections(retitled(open, 3, "bb"), order: order)) == ["beta", "delta", "alpha", "bb"],
                "by name alone it moves")
        #expect(shown(G.sections(retitled(open, 3, "bb"), order: G.renaming(window: 3, to: "bb", in: before)))
                == ["beta", "delta", "bb", "alpha"])
    }

    @Test func renamingAGroupedWindowKeepsItsPlaceInTheGroup() {
        let open = windows(titles)
        let before = G.sections(open, order: [])
        // wt-10 (id 4) → "ghoztty: a", which by name would lead the group.
        let order = G.renaming(window: 4, to: "ghoztty: a", in: before)
        #expect(shown(G.sections(retitled(open, 4, "ghoztty: a"), order: order)) == [
            "Build logs", "[ghoztty]", "  alpha", "  wt-2", "  a", "[relay]", "  main"])
    }

    /// Typing a new `<project>: ` still moves a window into that group —
    /// that is what it asks for — and a group it creates goes where the
    /// window was among the groups (after the ungrouped windows).
    @Test func renamingAWindowIntoANewGroupPutsTheGroupWhereTheWindowWas() {
        let open = windows(["zeta", "beta", "gamma"])
        let before = G.sections(open, order: [])
        #expect(shown(before) == ["beta", "gamma", "zeta"])
        let order = G.renaming(window: 3, to: "aa: gamma", in: before)
        #expect(shown(G.sections(retitled(open, 3, "aa: gamma"), order: order)) == [
            "beta", "zeta", "[aa]", "  gamma"])
    }

    @Test func renamingAWindowOutOfAGroupPutsItWithTheUngroupedWindows() {
        let open = windows(titles)
        let before = G.sections(open, order: [])
        // alpha (id 5) leaves ghoztty: it joins the ungrouped windows on
        // top, after those above it — never left under the group.
        let order = G.renaming(window: 5, to: "alpha", in: before)
        #expect(shown(G.sections(retitled(open, 5, "alpha"), order: order)) == [
            "Build logs", "alpha", "[ghoztty]", "  wt-2", "  wt-10", "[relay]", "  main"])
    }

    @Test func renamingAGroupKeepsItsPlace() {
        let open = windows(titles)
        let before = G.sections(open, order: [])
        // ghoztty → "zz": by name it would go last, under relay.
        let order = G.renaming(project: "ghoztty", to: "zz", in: before)
        let renamed = open.map { window in
            G.split(window.title).map { $0.project == "ghoztty" ? (id: window.id, title: "zz: \($0.worktree)") : window } ?? window
        }
        #expect(shown(G.sections(renamed, order: order)) == [
            "Build logs", "[zz]", "  alpha", "  wt-2", "  wt-10", "[relay]", "  main"])
        // Emptied: its windows stand where the group was, in its order.
        let ungrouped = open.map { window in
            G.split(window.title).map { $0.project == "ghoztty" ? (id: window.id, title: $0.worktree) : window } ?? window
        }
        #expect(shown(G.sections(ungrouped, order: G.renaming(project: "ghoztty", to: "", in: before))) == [
            "Build logs", "alpha", "wt-2", "wt-10", "[relay]", "  main"])
    }

    @Test func renamingAGroupIntoAnotherMergesThem() {
        let open = windows(titles)
        let before = G.sections(open, order: [])
        let order = G.renaming(project: "ghoztty", to: "relay", in: before)
        let merged = open.map { window in
            G.split(window.title).map { $0.project == "ghoztty" ? (id: window.id, title: "relay: \($0.worktree)") : window } ?? window
        }
        #expect(shown(G.sections(merged, order: order)) == [
            "Build logs", "[relay]", "  alpha", "  wt-2", "  wt-10", "  main"])
    }

    /// A window opened after a rename pinned the list still lands beside
    /// its name neighbour.
    @Test func aWindowOpenedAfterARenameGoesAfterItsNameNeighbour() {
        let open = windows(titles)
        let order = G.renaming(window: 3, to: "Build logs 2", in: G.sections(open, order: []))
        let opened = windows(titles + ["ghoztty: wt-3"])
        #expect(G.sections(retitled(opened, 3, "Build logs 2"), order: order)
            .first { $0.project == "ghoztty" }!.windows.map(\.label) == ["alpha", "wt-2", "wt-3", "wt-10"])
    }

    @Test func aWindowMovesOnlyAmongItsSiblings() {
        let open = windows(titles)
        let ghoztty = G.sections(open, order: []).first { $0.project == "ghoztty" }!.windows.map(\.key)
        let moved = Order.moving(G.key(window: 4), to: 0, visible: ghoztty, order: [],
                                 existing: G.keys(G.sections(open, order: [])))
        #expect(shown(G.sections(open, order: moved)) == [
            "Build logs", "[ghoztty]", "  wt-10", "  alpha", "  wt-2", "[relay]", "  main"])
    }
}

/// A window or group dragged in the all-windows list (`PaneSidebarItemReorder`):
/// siblings of different heights.
struct PaneSidebarItemReorderTests {
    typealias R = PaneSidebarItemReorder

    /// Lone windows `a`, `b`, then groups `p`, `q`: each stays on its side.
    @Test func aDragStaysOnItsSideOfTheTopLevel() {
        let isGroup = [false, false, true, true]
        #expect(R.banded(3, dragged: 0, isGroup: isGroup) == 1, "a lone window stops at the last lone slot")
        #expect(R.banded(0, dragged: 1, isGroup: isGroup) == 0)
        #expect(R.banded(0, dragged: 3, isGroup: isGroup) == 2, "a group stops below the lone windows")
        #expect(R.banded(3, dragged: 2, isGroup: isGroup) == 3)
    }

    /// A 30pt group, a 100pt window, a 30pt group — 6pt apart.
    private let frames = [
        CGRect(x: 0, y: 0, width: 200, height: 30),
        CGRect(x: 0, y: 36, width: 200, height: 100),
        CGRect(x: 0, y: 142, width: 200, height: 30),
    ]

    @Test func theIndexIsReadOffTheMiddlesByTheLeadingEdge() {
        #expect(R.target(top: 0, dragged: 0, frames: frames) == 0)
        // Down: its bottom (top + 30) past the window's middle (86).
        #expect(R.target(top: 57, dragged: 0, frames: frames) == 1)
        #expect(R.target(top: 55, dragged: 0, frames: frames) == 0)
        #expect(R.target(top: 150, dragged: 0, frames: frames) == 2)
        // Up: its top past the window's middle, then the first group's.
        #expect(R.target(top: 90, dragged: 2, frames: frames) == 2)
        #expect(R.target(top: 60, dragged: 2, frames: frames) == 1)
        #expect(R.target(top: 10, dragged: 2, frames: frames) == 0)
        // The window (100pt) held at the very top goes above the 30pt group.
        #expect(R.target(top: 0, dragged: 1, frames: frames) == 0)
    }

    @Test func othersSlideByTheDraggedItemsPitch() {
        #expect(R.pitch(dragged: 0, frames: frames) == 36, "its height and the gap after it")
        #expect(R.pitch(dragged: 1, frames: frames) == 106)
        #expect(R.pitch(dragged: 2, frames: frames) == 36, "last: the gap before it")
    }

    @Test func itLandsWhereTheItemsItPassedWere() {
        // The first group down past the window: ends where the window ended.
        #expect(R.landingTop(dragged: 0, target: 1, frames: frames) == 106)
        #expect(R.landingTop(dragged: 0, target: 2, frames: frames) == 142)
        // The last group up to the top.
        #expect(R.landingTop(dragged: 2, target: 0, frames: frames) == 0)
        #expect(R.landingTop(dragged: 1, target: 1, frames: frames) == 36, "dropped where it was")
    }

    @Test func itStaysInItsList() {
        #expect(R.clamp(top: -50, dragged: 0, frames: frames) == 0)
        #expect(R.clamp(top: 500, dragged: 0, frames: frames) == 142)
        #expect(R.clamp(top: 500, dragged: 1, frames: frames) == 72)
        // The list folded up from under it: it may stay where it was held.
        #expect(R.clamp(top: 300, dragged: 2, frames: frames, grabbed: 260) == 260)
        #expect(R.clamp(top: 200, dragged: 2, frames: frames, grabbed: 260) == 200)
    }
}

/// A window dragged into or out of a project group (`PaneSidebarCrossDrop`):
/// where it lands, and the name it takes.
struct PaneSidebarCrossDropTests {
    typealias C = PaneSidebarCrossDrop

    /// lone `a`, then `[p]` with `p1` and `p2`, lone `b`, then folded `[q]`:
    /// every row 32pt, the list without the dragged window.
    private let rows: [C.Row] = {
        let items: [(String, String?, Bool)] = [
            ("window:a", nil, false),
            ("project:p", "p", true), ("window:p1", "p", false), ("window:p2", "p", false),
            ("window:b", nil, false),
            ("project:q", "q", true),
        ]
        return items.enumerated().map { index, item in
            C.Row(key: item.0, project: item.1, isHeader: item.2,
                  frame: CGRect(x: 0, y: CGFloat(index) * 32, width: 200, height: 32))
        }
    }()

    @Test func underAHeaderOrBetweenItsWindowsItJoinsTheGroup() {
        #expect(C.destination(rows: rows, slot: 0, top: 0) == .topLevel(index: 0))
        #expect(C.destination(rows: rows, slot: 2, top: 64) == .group("p", index: 0))
        #expect(C.destination(rows: rows, slot: 3, top: 96) == .group("p", index: 1))
        // Between two lone items: the top level.
        #expect(C.destination(rows: rows, slot: 1, top: 32) == .topLevel(index: 1))
    }

    @Test func pastAGroupsLastWindowTheSlotIsSplitInHalf() {
        // After `p2` (96…128), before `b` (128): upper half joins `p`'s end,
        // lower half lands after the group, at the top level.
        #expect(C.destination(rows: rows, slot: 4, top: 100) == .group("p", index: 2))
        #expect(C.destination(rows: rows, slot: 4, top: 120) == .topLevel(index: 2))
        // Past a folded group's header, at the end of the list: the same.
        #expect(C.destination(rows: rows, slot: 6, top: 165) == .group("q", index: 0))
        #expect(C.destination(rows: rows, slot: 6, top: 190) == .topLevel(index: 4))
    }

    /// Ungrouped windows lead the list: let go at the top level below a
    /// group, a window lands at the end of them, and the gap opens there.
    @Test func belowAGroupItLandsAtTheEndOfTheUngroupedWindows() {
        let rows = [
            C.Row(key: "window:a", project: nil, isHeader: false, frame: CGRect(x: 0, y: 0, width: 200, height: 32)),
            C.Row(key: "window:b", project: nil, isHeader: false, frame: CGRect(x: 0, y: 32, width: 200, height: 32)),
            C.Row(key: "project:p", project: "p", isHeader: true, frame: CGRect(x: 0, y: 64, width: 200, height: 32)),
            C.Row(key: "window:p1", project: "p", isHeader: false, frame: CGRect(x: 0, y: 96, width: 200, height: 32)),
        ]
        #expect(C.banded(.topLevel(index: 3), slot: 4, rows: rows) == (.topLevel(index: 2), 2))
        #expect(C.banded(.topLevel(index: 1), slot: 1, rows: rows) == (.topLevel(index: 1), 1), "among them: as is")
        #expect(C.banded(.group("p", index: 1), slot: 4, rows: rows) == (.group("p", index: 1), 4), "joining: as is")
    }

    @Test func itsNameSaysWhichGroupItIsIn() {
        #expect(C.title(label: "main", in: .group("ghoztty", index: 0)) == "ghoztty: main")
        #expect(C.title(label: "main", in: .topLevel(index: 3)) == "main")
    }
}
