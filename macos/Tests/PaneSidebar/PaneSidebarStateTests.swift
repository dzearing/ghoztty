import AppKit
import Testing
@testable import Ghostty

/// The pane sidebar's layout rules and row text — pure, so pinned here.
struct PaneSidebarStateTests {
    typealias State = PaneSidebarState

    // MARK: Mode

    @Test func pinnedInAWideWindowIsTheFlatPanel() {
        #expect(State.mode(isPinned: true, isHidden: false, windowWidth: 1200) == .expanded)
    }

    @Test func unpinnedIsTheMiniRail() {
        #expect(State.mode(isPinned: false, isHidden: false, windowWidth: 1200) == .mini)
    }

    @Test func aNarrowWindowShowsTheRailEvenWhenPinned() {
        #expect(State.mode(isPinned: true, isHidden: false, windowWidth: 700) == .mini)
        #expect(State.mode(isPinned: true, isHidden: false, windowWidth: State.narrowWindowWidth) == .expanded)
    }

    @Test func hiddenWinsOverEverything() {
        #expect(State.mode(isPinned: true, isHidden: true, windowWidth: 1200) == .hidden)
        #expect(State.mode(isPinned: false, isHidden: true, windowWidth: 400) == .hidden)
    }

    // MARK: Column

    @Test func theColumnIsTheRailPlusItsMargins() {
        #expect(State.columnWidth(for: .mini, panelWidth: 240, elevated: false) == 44 + 2 * GlassCard.outerMargin)
    }

    @Test func elevatedRailSharesItsGapWithTheGrid() {
        // The grid's own margin is the gap after the rail, so the rail adds
        // none: rail-to-edge and rail-to-panes come out the same.
        let insets = State.railInsets(elevated: true)
        #expect(insets.leading == PaneElevation.margin)
        #expect(insets.vertical == PaneElevation.margin, "the rail's ends line up with the panes'")
        #expect(insets.trailing == 0)
        #expect(insets.leading == insets.trailing + PaneElevation.margin, "equal gutters either side")
        #expect(State.columnWidth(for: .mini, panelWidth: 240, elevated: true) == PaneElevation.margin + 44)
    }

    @Test func theColumnIsThePanelWhenPinned() {
        #expect(State.columnWidth(for: .expanded, panelWidth: 260, elevated: true) == 260)
    }

    @Test func hiddenTakesNoColumn() {
        #expect(State.columnWidth(for: .hidden, panelWidth: 260, elevated: false) == 0)
    }

    @Test func theColumnDoesNotDependOnHoverOpen() {
        // The hover-open card floats; there is no input for it to widen the
        // column with. Stated so a future signature change has to face it.
        let mini = State.columnWidth(for: .mini, panelWidth: 300, elevated: false)
        #expect(mini == State.railColumnWidth(elevated: false))
    }

    @Test func widthIsClamped() {
        #expect(State.clampWidth(10) == State.minimumWidth)
        #expect(State.clampWidth(10_000) == State.maximumWidth)
        #expect(State.clampWidth(250) == 250)
    }

    // MARK: Edge drag thresholds agree with the rail and panel sizes

    @Test func thresholdsSitBetweenTheRailAndTheNarrowestPanel() {
        #expect(State.railCardWidth < State.expandThreshold)
        #expect(State.expandThreshold < State.collapseThreshold)
        #expect(State.collapseThreshold < State.minimumWidth)
    }

    // MARK: Transient state is never persisted

    @MainActor
    @Test func transientStateStartsOff() {
        let state = PaneSidebarState(isPinned: true, isHidden: false)
        #expect(!state.isQuickKill, "a window must never come back in kill mode")
        #expect(!state.isHoverOpen)
        #expect(!state.showsAllWindows, "the all-windows scope is off by default")
    }
}

struct PaneSidebarTextTests {
    typealias Text = PaneSidebarText

    // MARK: Monograms

    @Test func theTextAfterAnEmDashNamesThePane() {
        #expect(Text.monogram(for: "claude — relay") == "RE")
        #expect(Text.monogram(for: "claude — pane-sidebar") == "PS")
        #expect(Text.monogram(for: "claude — windows-amd64") == "WA")
    }

    @Test func aPlainCommandUsesItsName() {
        #expect(Text.monogram(for: "zsh") == "zsh")
        #expect(Text.monogram(for: "npm run dev") == "npm")
        #expect(Text.monogram(for: "/bin/bash") == "bas")
    }

    @Test func anEmptyTitleStillGetsAMark() {
        #expect(Text.monogram(for: "") == "•")
    }

    @Test func aPathTitleUsesItsLastComponent() {
        #expect(Text.monogram(for: "~") == "~", "a shell sitting at home")
        #expect(Text.monogram(for: "~/git/ghoztty") == "gho")
        #expect(Text.monogram(for: "/tmp") == "tmp")
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

    // MARK: Subtitle

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
