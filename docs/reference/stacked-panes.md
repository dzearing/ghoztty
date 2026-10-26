# Stacked panes, gutters and resizing

Read before touching pane layout, stacking/minimizing, strips, gutters or
divider/grip drags, glides, or focus handoff between panes. Pane looks (glass,
tints) are in [pane-style.md](pane-style.md); dragging a pane or strip to a new
place is in [pane-rearrange.md](pane-rearrange.md).

Code: `PaneLayout.swift` (pure; `Features/Splits/PaneLayout.swift`), `PaneStackState.swift`, `PaneStage.swift`,
`PaneStackTab.swift`. Tests: `PaneLayoutTests`, `PaneStackStateTests`,
`PaneStackFuzzTests`, `PaneStackWindowTests` (real windows, real mouse events
for divider drags; captures to `/tmp/pane-stack-snapshots`).

## The rule

**A pane is never narrower than 225pt, or shorter than 125pt.** A row of panes that
cannot fit side by side at that minimum becomes a **stack**: as many panes as
fit stay on show (the **run**), and the rest are **minimized** into strips at
the edge they live on — the pane's own card at the strip's size (same glass,
rim and unfocused tint as any card on show), its content faded out and its
name down it. Nothing is ever squeezed below the minimum. Layout is one pure
function, `PaneLayout.compute`, used by the live grid AND the stashed-pane
slots, so a restored pane never reflows.

Rows nest (`a | (b / c)` is a row whose second item is a column), and each
keeps its own collapse. Zoom and hero show one pane, so nothing stacks.
**Flat style** stacks the same way, with square strips and a 1px line on its
grips.

**Ephemeral**: which panes are minimized and how a run's slots are sized are
not persisted. A relaunch starts from the focused pane with every row side by
side again where it fits.

## Strip labels

A strip is named by its pane's **banner title** when the banner has one, else
by the pane's own title (else its directory's name, else its kind) —
`PaneSidebarText.label`, the same name its pane sidebar row shows
(`PaneView.displayLabel`). The banner title wins because somebody chose it
(the banner hook sets it to the task), while Claude Code retitles the pane
(OSC 0/2) with whatever it is doing. It is live — `+set-banner`, OSC 7778 and
Cmd+R relabel the strip at once; clearing the banner (or a banner with no
title) brings the pane title back.

**What counts as a banner title** (`PaneSidebarText.bannerTitle`, pure) is
deliberately narrow, never just the first line: a heading on the first line
(`## Fix strip labels`), or a ONE-line banner opening with a bold run standing
alone or before ` · ` (`**Fix strip labels** · **Goal:** …`, the hook's OSC
fallback). Not titles: a bold label (`**Goal:** …`), a bold run followed by
prose (`**PR #12** — 3 files`), a bold line heading a multi-line banner
(`**Last result**`), a title-less table. Markdown is stripped (bold, code,
links → their label). Tests: `PaneSidebarTextTests`,
`aStripIsLabeledByItsBannerTitleLive` (reads the composited window).

## Focus brings a pane forward

There is no separate "bring forward" state. A strip click, `goto_split`, the
pane sidebar, `ghoztty://focus/…` all just focus the pane, and the row follows
(`PaneStackState.noteFocus`).

- It is a carousel, not a z-flip: the clicked card slides into the slot it
  takes and the cards it displaces slide to the slots it left, every card
  staying in tree order left to right. A strip click restores just that pane,
  sharing the space evenly; a pane on the far edge minimizes only when there
  is no room for one more.
- **Focusing a pane already on show never moves anything.** The run sticks
  (`PaneLayout.stickyRun`, from the run last laid out,
  `PaneStackState.shownRun`), and a strip brought forward slides it only as
  far as it takes. Focus history decides a run only when there is none to keep
  (a new row, the window grown or shrunk past a card).
- **Focus never MOVES onto a strip** unless the user asked for that pane:
  focusing one brings it out. (The caret can only sit in a strip by having
  stayed there — the caller of a side pane, below.) Every handoff picks the
  pane on show nearest the candidate (`paneOnShow`,
  `focusTargetAfterRemoving`): a close, Cmd-W in a viewer, a stash, the
  close from the sidebar, the window becoming key with nothing focused.
- Only a pane that **really has the caret** counts as focused to a stack
  (`PaneView.holdsKeyboardFocus`): `focusedPane` falls back to the last focused
  terminal while the caret is elsewhere, and that terminal may have been
  minimized since — reading it as focused would bring it back out.

## A side pane opened without focus comes on show

A pane split off the pane with the caret that does not take it — every agent
`+split` (focus is opt-in), a banner link's Cmd-click side pane — was asked for,
so it must be seen. It is the **featured** pane (`PaneStackState.featured`),
ranked ahead even of the focused pane (`PaneStackState.ranks`, -1) wherever its
row has no room for every pane. Other panes minimize to make room; when even
that is not enough the CALLER becomes the strip — and **keeps the caret**.
(Previously, in a window with room for two cards but not three, ~640–950pt, the
new pane was born a strip nobody saw.) The feature ends with the next focus
change. Set by `newViewerSplit`, and by `newTerminalSplit` / `newSplit` when
`focus` is false. Tests: `aSidePaneOpenedWithoutFocusComesOnShow`,
`aSidePaneInARowWithRoomForOneTakesItAndTheCallerKeepsTheCaret`,
`aSidePaneOpenedWhileTheWindowIsCoveredIsThereWhenUncovered`.

## Elevation and paint order

The run is highest, and strips sit lower the farther they are from it, on both
sides — the run casts its shadow on the strip beside it, each strip on the
next one out. On either side of the run a tucked card is drawn at its strip's
size (`Leaf.isSliver`), so glides never move a card through another and no card
on show ever has one under its glass. Paint order is `Leaf.elevation`, not
tree order.

## Gutters: where resizers live

Every card on show is separated from the next by the same gutter
(`Metrics.gap`: 10pt elevated, 6pt flat), and so is the run from each group of
strips beside it — the grip that pulls a strip back out lives there. A run with
strips on both sides has one more such gutter than a run at an end, so its
cards are that much narrower there (they take it after the glide, one resize
each).

**Strips are blades**: no gap between two strips (`Metrics.bladeGap` = 0), and
a strip that has another between it and the run reaches 12pt under that one
(`Metrics.bladeTuck`), its rounded edge out of sight — overlaid bars, not pills
touching at their corners. Each still shows 36pt, its title centered on what
shows (`PaneCardView.titleRect`). Each casts a tight shadow that leans AWAY
from the run onto the blade behind it and stops at its own sides; the shadow
follows `collapse`, so it comes on as a card narrows into its strip rather than
snapping in when the glide lands.

**A strip that stays a strip never moves** when another pane collapses between
it and the run: in a glide it moves by its outer edge (the one that shows), and
takes its new reach under the newcomer (`bladeTuck`) only when the glide is
over, once the newcomer has landed over it — reaching out sooner put its edge
in the gutter ahead of the newcomer and jiggled a trailing strip's outer edge
(`PaneStageView.stepGlide`, `aStripStaysPutWhenAnotherCollapsesOntoIt`).

Every resizer takes the mouse **in its gutter and nowhere else** (`Divider.gutter`, `StackHandle.gutter`): split
dividers, grips between cards, the grip where the run meets its strips, and the
pane sidebar's edge — expanded, ALL of the gutter between panel and panes and
none of the panel (`PaneSidebarState.pinnedEdgeGrip`;
`theExpandedSidebarResizesFromTheGutterBesideIt`); flat, or on the rail card,
just inside its edge. A click just inside a card's edge is the
card's — its grab handle sits at its top edge, and a strip is its own drag
source. Pinned by `everyResizerSitsInAGutter` /
`everyResizerOfAStackSitsInAGutter` (real windows: every resizer frame against
every card frame, plus hit-tests just inside each card's edges) and by
`PaneStackFuzzTests` in both styles.

## Dragging a gutter (`PaneLayout.dragged`)

**Every gutter of a row is one thing, and the row is a function of where the
gutter is.** A divider, a grip between cards on show, and a grip where the run
meets its strips (on any stacked row with strips on that side, collapsed by
the user or for want of room) all go through `PaneLayout.dragged`, computed
afresh every step from the row **as the drag found it**, never from the
previous step:

1. Items before the gutter get the space from the row's start to it; items
   after it get the rest.
2. Each side shows as many of its items as fit at their minimums, nearest the
   gutter first; the others become strips at that side's edge. A side with no
   room for even one is all strips, the gutter at their edge, the other side
   taking the rest.
3. The item beside the gutter takes up the slack; the others keep their sizes
   from when the drag began until the space runs out, then give way nearest
   first.
4. **A drag only collapses panes, and brings out at most one.** A side never
   shows more than it had on show when the drag began — or, if it was all
   strips, the one pane beside the gutter, pulled out. So a gutter dragged one
   way tucks that side's panes away one after another while the other side's
   panes grow and its strips stay strips; a strip pulled out by its gutter
   comes out alone, as far as the hand takes it, the strips behind it staying
   strips and panes on the other side tucking away to make room.
5. Dragged back, a gutter undoes exactly that: let go where it began, the row
   is as it was. A pane tucks away the moment it would go under its minimum;
   there is no resistance band (which would make the row depend on the path).

The row's state goes to `PaneStackState.show` (a `Pin` and slot shares), or,
all of it on show, to the tree's ratios (`SplitTree.settingRow`). It measures
in row coordinates, so `(a | b) | c` and `a | (b | c)` behave the same. (This
replaced three disagreeing, path-dependent mechanisms: a squeeze chain for
dividers, a one-strip-at-a-time pull for edge grips, a two-slot resize for
grips between cards.)

**Double-clicking a divider evens out the panes across it — in its direction
only** (`TerminalSplitOperation.equalize`, `SplitTree.equalized(only:)`): a
horizontal divider evens the heights and leaves every width as set, and the
other way round. `equalize_splits` itself still evens out both. Test:
`equalizedInOneDirectionKeepsTheOther`.

**The pane sidebar is a row's first item** in a divider drag
([pane-sidebar.md](pane-sidebar.md)): a gutter pushed past every pane it has
tucked away tucks the expanded sidebar into its rail.

**A row nested across the divider counts as it is laid out**: a column holding
a collapsed row (or one stacked for want of room) is only as wide as that row's
run and strips (`PaneStackState.laidOutPin`, through
`SplitTree.movingDivider(laidOut:)`). A collapsed row stays collapsed with room
to spare (a `Pin`).

Tests: `aGutterDraggedAcrossTheWholeRowAndBackIsCoherentThroughout` (a middle
gutter dragged to the left edge, the right edge, and back, every sampled frame
checked — no overlap, every gutter the row's, every card inside the row, one
bar — and the row as it was at the end),
`aStripPulledOutBringsOutItsPaneAlone`,
`aGutterDraggedNeverBringsStripsOutOnItsOtherSide`,
`aStripPulledFarBringsOutItsPaneAlone`,
`pullingTheLastStripOutOfAFullRowTucksTheFarPane`,
`aRunEdgeWithNoRoomForOneMoreIsStillAGrip`,
`aStripIsPulledBackOutByItsGutterLikeADivider`,
`aDividerBesideAColumnWithACollapsedRowResizesIt`; the rule's own cases in
`PaneLayoutTests` (`aGutterDragged…`).

## The gutter bar (`GutterBar`)

Every divider and grip (`DividerHandle`) and the edge of a side panel (the
pane sidebar's, a viewer's contents — `SidePanelResizeHandle`) shows a 4pt
accent bar with a soft glow down the middle of its gutter: half strength while
the pointer is over it, full while dragged.

- **The bar stays in the gutter**, never out at the pointer: it is drawn at the
  gutter being dragged as the layout leaves it, so it stops where the edge
  stops (a pane's minimum, a panel's widest/narrowest, a strip whose pane has
  not come out yet). When the gutter snaps (a pane tucks away, a strip comes
  out or goes back) it moves to the gutter that took its place, lit until
  mouse-up.
- While a drag is under way the bar is drawn on the window, not the handle,
  and above everything (`zPosition`): a grip can be replaced mid-drag, and
  panes' layers slide over it.
- One bar at a time: no gutter shows its hover bar while any drag is under way.
- When the dragged gutter is replaced, the bar goes to the gutter that moved
  the way the drag is going, nearest to where the bar was — not nearest the
  pointer (`theBarStaysWithTheGutterThatSnappedToTheEdge`).
- A gutter re-checks whether the pointer is over it whenever it moves in its
  window (`updateTrackingAreas`, which AppKit calls even when an ancestor
  moved), and every gutter in the window re-checks when a drag ends (a gutter
  that moved out from under a still pointer gets no mouse-exited). Tracking
  areas run during drags (`.enabledDuringMouseDrag`). Tests set their synthetic
  pointer with `GutterBar.pointerOverride`.

Tests: `aDividerShowsABarOnHoverThatFollowsTheDrag`,
`theBarStaysInTheGutterAsAStripComesOutAndGoesBack`,
`theBarStaysInTheGutterAsADividerCollapsesAPaneAndBack` (paced drags recorded
as the window server composites them: one bar in every frame while held, in
the gutter), `theExpandedSidebarResizesFromTheGutterBesideIt` (stops at the panel's
widest).

## Tree changes keep collapses

- **Adding or removing a pane never brings minimized panes back out** — in a
  row or a column — unless only one pane is left in that direction. Every tree
  change carries each collapse over to the row it became
  (`PaneStackState.rowsDidChange`, `Pin.carrying`): the same items with some
  gone, some joined, or moved within it — or with a column that emptied down to
  a row merged into it, each piece keeping the column's place (a strip if it
  was one). A collapsed row nested in that column keeps what it minimized: the
  merged run is what both show (`intersecting`). Exception: a merge never
  leaves the focused pane a strip, so a strip between it and the run comes out
  with it (a run is contiguous).
- **A pane joining a collapsed row keeps it collapsed** (a split — Cmd-D,
  `+split` —, a drop, a restored stash). One landing beside or between the
  panes on show is on show with them: a split of a pane on show shows both
  where they fit, else the focused one, and the pane it pushed out becomes a
  strip. One landing among the strips is a strip until focused. A split
  *across* the row (`d` becomes `d / e`) changes no slot. A pane moved within
  the row keeps the same panes on show; a swap swaps what is on show
  (`PaneStackState.swap`), and a pane dropped on a strip takes its place there,
  minimized — the caret goes to the pane that came out of the strip. Focus
  landing before or after the tree change gives the same row.
- **A pane leaving a collapsed row keeps it collapsed** (closed, stashed,
  moved away): the panes still on show take its space and the strips stay
  strips; closing the only pane on show brings out the strip before it (else
  after). Pins are keyed by the row's pane set; a row no longer on screen has
  no pin.
- **Undo puts back the stack state saved with the tree**
  (`PaneStackState.Saved`, taken by `replaceSurfaceTree`), so an undone close
  brings the row back exactly. (Keeping old rows' pins instead came back stale.)
- `PaneStackFuzzTests` drives random sequences of collapse, widen, focus,
  split, close, close-and-undo, swap and resize, in rows, columns and nested
  rows, both styles, checking these rules after every step.

## Glides: a change in what is on show

**Nothing slides on its own clock.** A strip's pane coming out or going back, a
pane tucking away — by a drag, a strip click, a split or a close — is a
**glide** (`PaneStageView.glide`): every card and strip eases from where it is
drawn toward where the layout puts it (about 90% in 0.15s), all re-placed
together every frame, so a card, its sheet and its content move as one and the
gutters hold their width. Under a drag the layout keeps changing and each frame
eases toward its latest — the target is retargeted mid-motion, never a tween
corrected at its end. (A Core Animation slide used to run against the hand.)

- **A pane going into its strip narrows into it** as a card, rim and glass all
  round, its content pinned to its far edge and cut by the card; **content
  fades out and title fades in** as it narrows (`PaneCardView.collapse`: by how
  much wider than a strip it is drawn, over its last 120pt). Coming out is the
  reverse. At the strip there is nothing left to change
  (`aPaneCollapsesIntoAGlassStripWithNothingSnapping`, which also checks the
  strip reads as glass against the desk). The flat style fills its strips.
- **What a card's content is held at.** Under a drag: where the layout puts it
  now (the larger of that and its size when the glide began, for a card on show
  at both ends) — holding the first target left content short of a growing card
  (`aFastPullKeepsTheGlideOnTheHand`). In a glide no drag began: the size it had
  (a strip's pane at its last size on show) until the glide is over, when every
  card takes its size in one transaction — **one resize per terminal, after the
  motion** (`aResizingSlideResizesEachTerminalOnceAfterIt`, recorded at the
  display's frame rate, frames in `/tmp/pane-stack-snapshots/frames`; fails on a
  frame where the still card flashes).
- **A minimized pane is never resized**: it keeps its last on-show size, and
  takes its slot's size once, when the glide bringing it forward ends.
- **A glide lasts the drag and settles after it**: a card that has caught up
  rests until the next step; on release the cards glide on to where they were
  headed. "The drag is over" (`PaneStackState.isGesturing`) lands 50ms after
  mouse-up, since a fast hand outruns the grid
  (`aFastPullLetGoOfSettlesWithoutASnap`). The stage observes `isGesturing`
  itself — the end of a drag does not always bring a grid redraw.
- **Every item glides**, strips included, by the rect it is drawn in
  (`pullingTheLastStripOutOfAFullRowSettlesWhole`). The drag's bar is drawn
  over the gutter as the cards draw it (`PaneStageView.shownGutter`).
- Tests: `aStripPulledOutFollowsTheHandWithNothingSliding` (every card sampled
  through a hand-paced drag: nothing on its own clock, the gutter its width,
  the pane seen on its way in, the bar over the drawn gutter).

## Dragging a strip

Drag a strip to pick its pane up: the card itself follows the pointer (no drag
image, past a 5pt threshold, so a wobbly click is a click). A strip has
**targets of its own** (`PaneDropResolver.resolveBlade`, table in
[pane-rearrange.md](pane-rearrange.md)): a slot in its row, a window edge, a
screen edge (tile into a new window), the pane sidebar (stash). Over a pane
there is nothing: no split quadrants, no swap. Strips are still drop targets
for a NORMAL pane drag (`PaneDragSession` uses the strip's rect for a minimized
pane — only a strip that is showing). The pane sidebar lists minimized panes
like any other; clicking one focuses (restores) it.
