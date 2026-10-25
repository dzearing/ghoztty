# Pane sidebar

A per-window, vertical list of every pane in the window. A pane can be
**stashed** into it, which takes it out of the split grid without ending it,
and restored from it by click or drag. Expanded, the list is a flat panel down
the window's side; collapsed, it is a raised rail of one-letter icons. One
button at the top of the bar switches between the two; nothing opens on hover.

The problem, in the user's words: *"Right now I have a really difficult time
managing panes that I just want to minimize in the window."* Today a pane can
only be closed, which kills it, or covered by hero mode, which makes one pane
big and hides the rest. Nothing says "get this out of my way but keep it
running".

**Status:** built (branch `users/dzearing/pane-sidebar`). The interaction model was settled over an
interactive HTML mock (`temp/mocks/pane-sidebar/index.html`, not committed —
`temp/` is gitignored); everything under "The sidebar view" records what that
mock converged on, including the choices that were tried and dropped.

## The model: one roster, two states

The sidebar lists **every pane in the window**, in two sections:

```
┌─ PANES ─────────────── ◧ ┐
│ ▸ zsh — ~/git/ghoztty     │   ← in the grid; the focused pane is selected
│   claude — pane-sidebar ● │     ● busy
│   README.md               │
│ ───────────────────────── │   ← right after the last pane
│   STASHED                 │
│   claude — relay   question│   ← out of the layout, still running
│   tail -f app.log         │
└───────────────────────────┘
```

| Gesture | On a grid row | On a stashed row |
|---|---|---|
| Click | Focus that pane | **Restore** it to where it was in the grid, and focus it |
| Drag into the grid | Move it (the same drop as the hover grab handle) | **Restore** it at the drop target |
| Drag up or down the pane list | **Reorder the list** — the rows slide to make room; the grid does not change | **Restore** it, at that place in the list |
| Drag into the tray (below the divider) | **Stash** it, at that position in the tray | Reorder the tray |
| Drag to empty space or another window | Pop out / move, as today | Same, and it is no longer stashed |
| Hover buttons | `−` stash, `×` close | `↩` restore, `×` close |
| Right-click | Stash · Move to New Window · Close Pane | Restore · Swap with Focused Pane · Move to New Window · Close Pane |

`×` is the ordinary close (see Closing panes).

Dragging any pane, from its grab handle or its rearrange-mode header, into the
**tray** stashes it; onto the pane list above the tray, it takes that place in
the list. When a pane leaves the grid the remaining panes reflow to
fill its space, exactly as they do when a pane is closed.

**Vertical tabs are the extreme case, not a mode.** Stash everything except
one pane and the sidebar is a list of tabs: click a row and that pane comes
back. (A click restores a pane *beside* the others rather than swapping it in.
Alt-click a stashed row to **swap** it with the focused pane, which gives
one-pane-at-a-time switching for anyone who works that way.)

### Why this model won

- **No mode to enter.** The sidebar is always valid. You stash a pane the same
  way whether the sidebar is expanded, collapsed, hidden, or in rearrange mode. The
  complaint is about everyday pane management, and a feature you must switch
  into first would solve a different problem.
- **It reads as one macOS sidebar.** Finder, Mail, and Xcode's navigator are
  all a roster plus a selection: every item is listed, and the selected one is
  what the main area shows. Here the grid rows are the selection and the
  stashed rows are everything else. A list that held only stashed panes would
  look like a drawer.
- **It delivers the minimize that was asked for without rebuilding the split
  tree.** Stashing extends `SplitTree` the way zoom already does (see
  Architecture), so it does not replace the tree.

### Alternatives, and what it would cost to switch

These are recorded so that backing out of the chosen model is a decision we
can make later, not a rewrite.

**Alternative A: stash shelf only.** The list holds *only* stashed panes, and
grid panes are not listed.

- *What changes:* the sidebar view hides its grid section and becomes visible
  only when the stash is non-empty. Nothing else changes. The data model,
  drop target, session safety, CLI, and manifest are identical, because the
  grid section is derived from the tree and stores nothing.
- *Cost:* small, about a day, almost all of it in `PaneSidebarView`. The chosen
  model contains A, so switching to A removes code rather than replacing it.
- *Why not:* the sidebar would be empty most of the time and read as a drawer
  rather than an outline of the window. It would also lose the payoff of
  seeing every agent pane's state in one column.

**Alternative B: true vertical tabs.** The list becomes the main switcher. One
pane (or a group) fills the window, and the split grid becomes secondary.

- *What changes:* the window body shows one *group* at a time, so the model
  becomes a list of groups, each holding its own `SplitTree`. The controller's
  single `surfaceTree` would turn into a tab container, and every
  `controller.surfaceTree` call site (about 200 across 30 files: IPC, close
  intent, the session manifest, focus, App Intents, AppleScript) would need to
  say which group it means. Rearrange and hero mode would have to define what
  "the window's panes" means across groups.
- *Cost:* large, several weeks. It works against `SplitTree` instead of
  extending it. The stash flag from this design would not carry over; the
  group container would replace it.
- *Why not:* it is the biggest build, it puts the session-safety landmine back
  (moving a pane between groups takes it out of a tree), and the chosen
  model's degenerate case already gives single-pane switching.

## Architecture

### A stashed pane never leaves the tree

This is the central decision. Everything else follows from it.

`SplitTree` already has view state that hides panes without removing them:
`zoomed`. When a pane is zoomed, the other leaves stay in `root`, and only
the zoomed subtree is mounted. Stashing works the same way: **`SplitTree`
gains `stashed: [ViewType.ID]`, an ordered list of leaf ids that stay in
`root` but are left out of the layout.**

```swift
struct SplitTree<ViewType> {
    let root: Node?
    let zoomed: Node?
    let stashed: [ViewType.ID]        // new: in root, not laid out; list order

    /// root with stashed leaves pruned and their parent splits collapsed.
    /// This is what TerminalSplitTreeView renders.
    var visible: Visible { … }

    func stashing(_ view: ViewType, at index: Int? = nil) throws -> Self
    func restoring(_ view: ViewType) -> Self       // back to its own slot
    func reorderingStash(_ view: ViewType, to index: Int) -> Self
}
```

The alternative was to physically remove stashed panes into a list on the
controller. It was rejected because every reason it fails is silent:

- **The session landmine.** `SessionCloseIntentPolicy` reads "a leaf left the
  tree" as a close and marks the agent session CLOSE-on-free. A pane that
  never leaves the tree never triggers it, for every path that exists today
  and every path added later. With physical removal, every stash and restore
  would have to declare itself the way `PaneMoveCoordinator.finishRelocation`
  does. Any path that forgot, such as a future IPC verb, a restore, or an
  undo, would kill a Claude Code session and look as if it had worked.
- **Every other "panes in this window" question.** IPC target resolution,
  `+list`, `+send-keys`, `+read`, `windowWillClose` (which ends a closed
  window's sessions), close confirmation (`needsConfirmQuit`), the session
  manifest, the activity-state aggregate in the window title, App Intents, and
  AppleScript all walk `surfaceTree`. Kept in the tree, a stashed pane is
  automatically still targetable, still counted, still confirmed on window
  close, and still persisted. With physical removal, each of those roughly 200
  call sites would need an audit, and any new code that walks the tree would
  quietly skip stashed panes.
- **Restore goes back to the same place.** Pruning a leaf collapses its parent
  split in the *visible* tree only. The full tree keeps the split, its
  direction, and its ratio, so restoring the pane brings back the exact layout
  it left. That is also what makes the geometry rule below achievable.

Session safety therefore does not depend on anything remembering to declare
it. That is still tested directly, not assumed (see Testing).

### What the projection means for each tree operation

Only *spatial* operations need to know about the projection. All of them are
pure and live on `SplitTree`:

| Operation | Runs on | Note |
|---|---|---|
| Render (`TerminalSplitTreeView`) | `visible` (of `zoomed` when zoomed) | |
| Divider drag, `resize_split`, `equalize_splits` | `visible`, then **lift the ratios** back | Each split in the visible tree corresponds to exactly one split in the full tree (the one whose two sides both still hold a visible leaf), so a ratio change maps back one to one |
| `goto_split` / `focusTarget` / spatial navigation | `visible` | A stashed pane cannot receive focus by direction |
| New split at a pane | full tree | The anchor pane is a leaf in both trees |
| Top-level insert (window-edge drop) | full tree | Wraps the root; stashed leaves stay hidden inside it |
| Remove (close) | full tree | Drops the id from `stashed` too |
| Hero mode | visible leaves | Hero mode's carousel covers the panes you are working with |
| `isSplit` checks (pop-out enabled, close-tab semantics) | visible | "Is there another pane on screen" |

**Invariants**, enforced in `SplitTree` and unit-tested:

1. **At least one pane is always visible** while the tree is non-empty.
   Stashing the last visible pane is refused. If closing a pane would leave
   only stashed panes, the most recently stashed one is restored in the same
   operation, so the window never shows an empty body.
2. `stashed` only ever names leaves that are in `root`. Any mutation that
   removes a leaf also removes it from `stashed`.
3. **Stashing the zoomed pane un-zooms it.** Stashing another pane while
   zoomed keeps the zoom.

### Mutation, undo, focus

Stash and restore are ordinary tree replacements through
`replaceSurfaceTree(_:undoAction:)`, registered as "Stash Pane" and "Restore
Pane". Undo works because stash state is part of the tree value. Stashing the
focused pane moves focus to the visible neighbor that `focusTarget` would pick
after a close. Restoring a pane focuses it only when the restore came from the
UI (click, drag, or shortcut). A CLI restore follows the `--focus` policy.

### Geometry: a stashed pane keeps its size

A stashed pane stays **mounted, invisible, behind the grid**, in the slot it
would occupy in the full (unstashed) layout (`StashedPaneSlots` in
`TerminalSplitTreeView`, laid out with the same `SplitView`s the grid uses).

The first build unmounted stashed panes, as a zoom does, on the theory that the
`SurfaceView` would keep its last frame. That held for a pane stashed while
on screen, and failed for a pane that was **stashed when its window opened**
(a session restore): it was never laid out, so its terminal was told it was
the 800×600 placeholder — 49×17 cells — the exact reflow this section exists to
prevent. Found in the debug app's agent log (`RESIZE … rows=17 cols=49` on
every relaunch, once per stashed terminal), reproduced by
`aPaneStashedAtLaunchGetsItsRealSlotSize`, fixed by mounting. (`.hidden()`
was tried first: a hidden SwiftUI subtree never mounts its AppKit views, so the
layer uses opacity 0 and sits behind the grid, which wins every hit test.)
Mounting also keeps a `window` for the stashed terminal, so window-scoped
actions from it still find their controller.

- **No size is pushed on stash.** The pane is not resized to zero or to a
  placeholder, so its program sees no `SIGWINCH` at all.
- **Restoring to its own slot** (a click, or the shortcut) brings the pane
  back to the same rectangle when the rest of the layout hasn't changed, so
  restoring is not a reflow event for it. If the window was resized while the
  pane was stashed, it gets one resize to the new size, which is the same as
  any pane in a resized window.
- **The panes that remain get exactly one resize** on stash and one on
  restore. Their frames are not animated, because an animated split resize is
  a run of `SIGWINCH`s that makes a TUI repaint its conversation once per
  frame. The *sidebar row* animates; the grid snaps.
- **Collapsing and expanding** change the column's width, which resizes the
  grid's panes once each way — the same trade rearrange mode's header makes:
  the sidebar takes real space so that it never covers content. Nothing else
  changes the column (see Collapsed and expanded).

Verified by measurement, not assumed: `PaneSidebarWindowTests` reads
`ghostty_surface_size` before a stash, while stashed, and after restore (same
columns, rows, and pixels), and for a pane stashed at window creation (its
slot's size, never 49×17).

### Drop resolution: one resolver, a new target

Per the rearrange design's first principle, the sidebar is a new **drop
target** and a new **drag source** on the existing machinery. It does not get
its own resolution path.

```swift
enum PaneDropTarget {
    …
    /// Stash the dragged pane into this window's sidebar at `index`.
    case stash(window: PaneDropWindowRef, index: Int)
    /// Put it at `index` of the sidebar's pane list — the list, not the grid.
    case sidebarOrder(window: PaneDropWindowRef, index: Int)
}

struct PaneDropCandidate.Sidebar {
    let rect: CGRect                   // the drawn card or panel
    let paneRows: [(id, rect)]         // the pane list, top to bottom, as laid out
    let stashRows: [(id, rect)]        // the tray, top to bottom
    let trayTop: CGFloat?              // the tray's divider
    let windowGroups: [(window, rect)] // all-windows scope: other windows
}
```

**Precedence:** tab bar, then **sidebar**, then window edge band, then pane
zones, then a new window. The sidebar comes before the edge band because it is
chrome on top of the content, as the tab bar is. A point on it never also
means a pane. The sidebar is **two lists split at the tray's divider**: above
it a drop is `sidebarOrder` (a grid pane moves in the list, a stashed one is
restored into it, another window's joins this window there); below it, `stash`.
In both the index is the number of that list's rows, the dragged one aside,
whose middle is above the pointer. The rows are measured **as laid out**, not
as the drag slides them, so the index never moves under the pointer while the
rows animate.

**The rail is always a target.** Collapsed, the sidebar is still a column
of its own, so there is always something to drop on; no reveal gesture is
needed. (An earlier draft had a hidden overlay that a 500ms dwell at the left
edge slid in. The always-present rail made it unnecessary, and it was
dropped.) Only a sidebar the user hid outright with Ctrl+Cmd+S is not a
target.

**Dragging from a row** uses the same `PaneDragSource` (`NSDraggingSession`,
snapshot preview, Escape cancels) with the pane id on the pasteboard. The
existing resolver handles the drop. `PaneMoveCoordinator.apply` gains one
rule: a pane that is stashed in its source is un-stashed in the same tree
value that places it, so a restore-by-drag is one undo step. A row names its
window's controller explicitly when it starts the drag, because a stashed pane
is unmounted and has no `window` to find it through.

**Cross-window:** dropping window A's pane on window B's sidebar moves it to B
(top-level, on the right) and stashes it there, in one undo group. That goes
through `crossWindowCommit` → `finishRelocation`, the existing declaration
that a move is not a close. With the all-windows scope on, dropping a row onto
ANOTHER window's group in this window's sidebar is the same move — into that
window's grid — so a pane can be sent somewhere without dragging across the
screen.

### Remote and viewer panes

Both are ordinary leaves. They stash and restore the same way, and because
nothing leaves the tree and nothing is closed, `SessionDisconnectPolicy`'s
Disconnect prompt is never involved. A stashed viewer keeps its rendered page
and scroll position, and a stashed image keeps its zoom, because the
`ViewerView` instance is the same one.

## The sidebar view

### Look: the side-panel vocabulary, two containers

The viewer pane's table of contents and diff file tree are "the same card,
not a lookalike". The pane sidebar reuses the same vocabulary — and was
deliberately split between two containers for its two states:

- **Rows and header are shared, always**: `SidePanelRow` (`fillInset` 8,
  `textInset` 10, `verticalPadding` 7, radius 6; the accent selection pill
  while the window is key, the unemphasized fill otherwise, hover as a separate
  wash), `SidePanelCaption` for "PANES" / "STASHED", and
  `SidePanelResizeHandle` for drag-to-resize with a shared width preference.
- **Expanded is the same raised glass card, wider.** It was a flat panel
  edge to edge down the window's side (the mock had argued a floating card in
  a column reads as an overlay), but against the rail that put the list at a
  different top and height, with different row metrics, so every icon jumped
  when the sidebar was toggled; the user asked for one card in the window's
  gutters, like the panes.
- **Both are the raised glass card** — `SidePanelCard`'s shape, glass,
  opaque base, and `GlassCard.outerMargin` (12pt on every side) — as the
  rail. The card's opaque base becomes a parameter (it is hard-wired
  to the viewer document's colors today); the sidebar passes the terminal
  background, which is what it sits on.

The viewer panel lives in one pane's gutter; this one lives in the window's,
to the left of the split grid, spanning the full height below the titlebar.

### Header

`PANES` on the left (`SidePanelCaption`, aligned to the row labels), and three
borderless 24pt buttons on the right, styled exactly like the viewer nav bar's
chevrons (`.buttonStyle(.borderless)`, `.primary` glyph, no fill; pressing
dims it). On/off is read from the glyph itself, never from a blue tint:

| Button | Off | On |
|---|---|---|
| All windows | `macwindow.on.rectangle` | filled; caption reads **ALL WINDOWS** |
| Collapse | — | a window with its sidebar panel filled: collapses to the rail |

The collapse button comes FIRST, at the header's leading edge, centered on
the rail's width; the rail's one button — the same glyph, panel outlined,
which expands it (disabled in a window too narrow for the panel) — sits in
exactly that spot, so the button never moves when toggled. All windows is
there once it is expanded. (A trash button, which turned on an unconfirmed
kill mode, was removed in favour of a row's ordinary `×`.)

### Rows

```
 [icon] Title                         [state] [hover: − / ↩]
        subtitle
```

- **Icon:** `terminal` for a terminal; the viewer's kind otherwise
  (`doc.richtext` markdown, `globe` website, `photo` image, `plusminus` diff,
  `doc.text` code/HTML).
- **Title:** the pane's `title` (already `@Published` on `PaneView` for both
  kinds).
- **Subtitle:** the first line of the pane's **banner** with the markdown
  stripped, when it has one — the banner hooks keep it as a live
  title/goal/status, the most useful single line about an agent pane.
  Otherwise the working directory, `~`-abbreviated, or a viewer's location.
- **State**, using the human labels, never the machine tokens (`CLAUDE.md` →
  `+set-state`):
  - `busy`: **the icon shimmers.** The glyph is drawn as a dim base with a
    brighter band sweeping across it (~1.1s sweep, ~0.3s rest). No spinner,
    and no glow: a pulsing glow under the icon was tried and dropped — it was
    loud, and competed with the question badge. The base is solid under the
    band so the glyph is never partly blank (a single gradient that the band
    slid within left the icon clipped for most of each sweep). The title does
    not shimmer, so a list of several busy agents stays calm. Under Reduce
    Motion the glyph is drawn plain.
  - **Both endless animations — the shimmer and the question badge's
    breathing ring — run on Core Animation**, not SwiftUI
    (`PaneSidebarAnimationLayers.swift`): the glyph is drawn once into a mask
    and the band is a CA keyframe animation under it. A SwiftUI animation that
    never ends (`TimelineView(.animation)`, `.repeatForever`) re-runs the whole
    sidebar's update on the main thread every frame, in every window with a
    busy pane. Measured with ~40 windows and a dozen busy panes, that alone
    held the main thread at 86–99% of a core with nothing happening, and
    scrolling the all-windows list cost 31–50 ms of main-thread time a step;
    on CA it is under 1% at rest and ~8 ms a step with every window expanded.
  - `needs_input`: a **question** badge in the accent color — the same label
    the title suffix shows — gently pulsing on a stashed row. A stashed pane
    that goes from `busy` to `needs_input` is the row to look at next.
  - `idle`: nothing.
  - A **bell** on a stashed pane shows a dot until the pane is restored.

Right after the last pane, in the same scrolling list, are a hairline divider
and the **tray**: a "STASHED" caption (with a count) and the stashed rows. The
tray is always there in this window's list, since it is a drop target. (It was
first anchored at the bottom of the bar; that put it far from the panes it is
for.) A drag slides the list, the tray's header and the tray as ONE sequence
(`slideIndices`), so a row crossing from the list into the tray moves the
divider with the rows between, and the list's last row never runs over it.
During a drag with nothing stashed, an empty "Drop to stash — it keeps
running" slot appears so the target is visible.

**The row follows the pointer.** A row (or tile) being dragged is the row
itself, moved up or down with the pointer — never sideways, and kept inside
the bar — over a solid backing so it reads as on top; no drag image. It is
still `PaneDragSession`'s drag (the row's source draws no preview and feeds
the pointer's travel to `PaneSidebarRowDrag`); let go, it glides to where it
landed. The drop geometry is the rows **as laid out**: a row's frame is read
by a background outside its slide offset, since a reader inside an `.offset`
moves with it — which made the drop index chase the sliding rows.

**An empty tray is a visible target**: a faint dashed well with a tray glyph
(and "Drag a pane here to stash it" when expanded), always there in this
window's list, lit in the accent while a drag would land in it.

**Reordering.** The list has its own order (`PaneSidebarState.order`,
`PaneSidebarOrder`): dragging a row up or down changes the list and never the
grid. While a drag is over the sidebar the dragged row is lifted out, leaving
its gap, and the rows it passes slide by its height to open a gap where it
would land (`PaneSidebarOrder.shift`, a 0.2s bounded animation; none once the
drag ends, since the drop re-lays the list out where the rows were already
drawn). A row crossing between the list and the tray closes its gap in one and
opens one in the other; each list holds a row's worth of room at its end for
the whole drag, so nothing re-lays out under the pointer.
- A pane the order has never seen — a new split, a pane from another window —
  goes after its nearest tree neighbour the order knows (so a split appears
  beside the pane it came from), else before the next, else at the end.
- A stashed pane keeps its place in the order, so restoring it brings it back
  to the same spot. Closed panes are pruned on the next move and never
  persisted.
- Until the first reorder the order is empty, which means the tree's order.
- It persists with the other sidebar layout (session manifest
  `paneSidebarOrder`, window restoration), by stable pane id.

**While the sidebar is hidden,** a stashed pane asking a question still shows,
because the window title's activity suffix is aggregated across every leaf in
the tree and stashed panes are still in it.

### The rail

Collapsed, the card is a 44pt rail (a 68pt column with its margins). Every
pane is a 28pt tile in the same order as the list, the focused one in the
selection pill, and the tray under a hairline at the bottom.

- **A tile is one letter**: the first letter or digit of what the pane is
  called (`PaneView.displayLabel` — its banner title, else its title, exactly
  as a stacked pane's strip is named), upper-cased, for every kind of pane
  (`PaneSidebarText.monogram`). A leading glyph is skipped — Claude Code
  titles its pane `✳ <task>`, a shell `~/…` — or every such pane would get
  the same tile; a name with no letters at all shows its first visible
  character. (It replaced a heuristic of up to three characters taken from
  after an em dash or from the command name, which named panes differently
  from their rows.) A tile carries a tooltip with its full name.
- **Every tile is a small pane of glass — the pane banner's own**
  (`PaneSidebarTileButton` on `GlassCardBackground`): a see-through wash, the
  elliptical sheen, the specular rim, a drop shadow scaled down to its size.
  The color behind shows through it as it does through a banner. The selected
  pane's is accent-tinted glass (plain glass, thickened, while the window is
  not key). All static — nothing on a tile animates but the busy shimmer. (A
  first take was an opaque bevelled button with a gradient; it read as a
  control from another app, not as Ghoztty's glass.)
- **Activity without badges on the letter**: a question is an accent rim
  round the tile — no `?` badge (it covered the letter and read as clutter);
  a bell is a dot; busy is the same shimmer, on the letter.
- **The rail never opens on hover.** It used to open to full width over the
  grid after a short intent delay; but the rail is where its tiles are
  dragged, and a card springing open under a drag is in the way of exactly
  that. The button at its top expands it.

### Collapsed and expanded

**One card.** Expanded is the rail's raised glass card at the panel's width —
the same margins (the grid's gutters), top and height — and every row is one
height, so a pane's icon sits at the same height in both modes. (Expanded was
first a flat edge-to-edge panel, which put it at a different height with
different row metrics: the icons jumped on every toggle.)

**A row dragged in the list only rearranges.** Its drag is a list drag
(`PaneDragSession.isListDrag`): the pointer is held to the bar before the
drop is resolved, so letting go beside it — over the grid, past the window —
lands the row at the place level with the pointer. It used to resolve like a
pane's grab handle, which made a release past the window a `.newWindow` and
took the pane away.

| | Expanded | Collapsed |
|---|---|---|
| Look | The raised glass card, at the panel's width | The same card: the rail |
| Column | `--sidebar-w` (default 240, drag the edge) | 68pt |
| Switched by | The button at the top of the bar | The same |
| Persisted | Yes, per window, in the session manifest | (the same flag) |
| Narrow window (< 720pt) | Shows the rail — the full panel would crowd the grid, the rail doesn't; the expand button is off | Rail |

- **One button, at the top of the bar** — or the gutter. The edge grip lies
  in the gutter beside the sidebar in both modes, never over it
  (`PaneSidebarState.edgeGrip`); its bar used to sit on the rail's tiles.
  Pulled past the panel's minimum the rail comes out at that width; pushed
  well under it (< 120pt) the panel tucks back into the rail; between the two
  it stops at its minimum (`edgeDrag`) — so the edge never flickers at one
  width, and one drag goes both ways.
- **It glides.** Collapse and expand move the grid's cards the way a strip
  coming out does: `PaneStackState.noteColumnShift` tells the stage the column
  is moving, the stage seeds its glide from where the cards are on screen and
  eases them to their new places, each terminal held at its size and resized
  once, after the motion. The sidebar's width animates on the same curve
  while rail and panel crossfade. It used to snap.
- **Only collapse/expand and hide/show change the column**, and so resize the
  window's terminals: each is something somebody chose.
- **Ctrl+Cmd+S hides or shows the sidebar entirely.** Hidden is persisted
  with the expanded flag.
- **It replaced a pin.** Pinned was the flat panel; unpinned was the rail,
  which opened over the grid while the pointer was over it. The pin and the
  hover-open card are gone. The persisted flag keeps its old name
  (`paneSidebarPinned`, and `PaneSidebarPinned` in UserDefaults as a fallback
  for the new `PaneSidebarExpanded`): pinned meant the full panel, which is
  what expanded is, so old state reads as-is.
- An earlier draft had an *overlay* mode (the shortcut slid a floating card
  in). The rail replaced it: it keeps every pane's state visible for 68pt and
  is always a drop target.

**Why the stash persists.** The viewer side panel's open/closed state is
deliberately ephemeral because restoring an overlay would hide the content it
covers. A **stash** is different: it is the window's layout, like a split
ratio or a zoom, and losing it on relaunch would hand back every pane you put
away. The **expanded** and **hidden** flags are layout too (they size the
column), and so is the list's **order**; all three persist. The all-windows
scope is not persisted.

### All windows

A header toggle, **off by default**, that widens the roster from this window
to every Ghoztty window, so window management can happen from one list.

- The list is an **outline**: each window is a parent row and its panes are
  its children, indented under it (chevron, then the window's name; the pane
  icons line up under the name). This window comes first (tagged *This
  Window*), then the others front to back. A header shows the window's name —
  a user-set title, else its focused pane's name, never the raw title with its
  activity suffix — its pane count, and a **question** badge when any pane in
  it has one. Click it to raise the window; the chevron folds the group.
  Windows are separated by a hairline.
- **Windows start folded** — one row per window, the overview this scope is
  for — except **this window**, which starts open: it holds the selection
  and the pane you are in. That is decided only when the list opens; focus
  moving later never unfolds anything, or the list would jump under the
  pointer. A window opened while the list is showing arrives folded. The
  state records the windows the user *flipped* from that default
  (`toggledWindows`, `PaneSidebarState.isWindowFolded`), and is forgotten
  when the scope is left, so each look starts from the default. **A search
  unfolds everything**, since a hit hidden inside a fold reads as no hit.
  Project groups still start open.
- The **ALL WINDOWS** caption carries a count of windows (not panes), in the
  same style as a project header's count.
- **Drop geometry is reported only during a drag.** Rows and groups publish
  their frames (for the drag resolver) in the panel's coordinate space,
  outside the scroll view, so the values change on every frame of a scroll,
  and each change rebuilt the window's key-view loop. Nothing reads them
  outside a drag.
- **Only this window has a selection.** The first build drew another window's
  focused pane in the gray pill; among its siblings that read as a "primary"
  pane with the others nested under it, so other windows show no selection.
- Clicking another window's row raises that window and focuses the pane (or
  restores it there, if stashed) — `IPCServer.focusTarget`, the same verb as
  `ghoztty://focus`.
- Drag a row into this grid to bring the pane here; drag one of this window's
  rows onto another window's group to send it there. Both are the existing
  cross-window move.
- In the rail, windows are separated by a hairline.

### Closing panes

**A row's `×` is the ordinary close.** Hovering an expanded row offers `−`
(stash) or `↩` (restore), and `×`. The `×` goes through the normal close path
— the same as right-click → Close Pane: confirmation when something is
running, Disconnect for remote panes, and undo — so a stray click costs at
most a dialog or an Undo. (Middle-click-to-close, the browser convention, was
tried and removed: there is no undo for a click you did not mean.)

**There is no trash mode any more.** It was a header button that gave every
row a red `×` which killed with no confirmation and no undo window. The
user asked for a close button on the rows instead; with one there, the
unconfirmed kill had no reason to exist.

### The grab handle

The hover-revealed grab handle at the top of every pane (`PaneGrabHandle`,
for terminals and viewers alike) is the everyday way to drag a pane onto the
sidebar. Viewer panes had none before — a doc, HTML page, or website could only
be dragged in rearrange mode — so the handle was factored into one shared view;
each pane kind only reports whether the pointer is in its top band (a viewer
through a tracking area that keeps working over the web view; a terminal also
counts its banner, under which the surface can't see the pointer). It
has two states: hovering the PANE fades it in translucent; hovering the HANDLE
makes it fully opaque — a solid fill, full-strength dots, a slight shadow — so
it reads as the thing you are about to grab. It stays opaque while held.

### Keyboard and menus

All actions are new keybinding actions, wired along the trail in
`pane-rearrange-mode.md` → "The mode" (`Binding.zig`, `action.zig`,
`command.zig`, `Config.zig`, `Surface.zig`, `Ghostty.App.swift`,
`BaseTerminalController`, `MainMenu.xib`, `syncMenuShortcut`). Each action is
classified `.window`, so a focused viewer forwards it (`ViewerKeyFallback`).

| Action | Default | Menu |
|---|---|---|
| `toggle_pane_sidebar` | **Ctrl+Cmd+S** (the system "Show Sidebar" chord in Finder, Mail, and Notes) | Window → Show/Hide Pane Sidebar |
| `stash_pane` | **Shift+Cmd+M** (Cmd+M minimizes the window; Shift+Cmd+M stashes the pane) | Window → Stash Pane |
| `restore_stashed_pane` | none by default; restores the top of the stash | Window → Restore Stashed Pane |

All three sit together in the Window menu after Toggle Rearrange Mode, and the
defaults are macOS-only (the sidebar is). Neither chord collided with a
system symbolic hotkey or a registered global hotkey on the development
machine (Zecho, which took Shift+Cmd+R, now uses Shift+Cmd+1).

Both default chords are unbound in Ghoztty's default config and main menu (no
`s` or `m` bindings exist; the menu has only Cmd+M, Minimize).

## Pane style: elevated on an ocean gradient

Tried in the mock (Flat vs Elevated · Dusk / Ocean / Aurora / Graphite) and
chosen: **Elevated · Ocean**, as the default, with `macos-pane-style = flat`
to opt out. Each pane is a slightly raised rounded card on a soft gradient —
blue pooling at the top-leading corner, teal at the bottom-trailing, over deep
slate (pale counterparts on a light terminal theme) — "the simplicity of the
ocean option". One 10pt spacing is every gutter — pane to pane (still the divider),
pane to window edge, and around the rail, which takes no trailing margin
of its own because the grid's margin is that gap. (The first build used an 8pt
gap beside a 10pt margin, and the rail's own 12pt card margin on top of the
grid's: three numbers that read as uneven. Now one constant,
`PaneElevation.margin`, with `gap` defined as it.)

**Cmd-N picks a random gradient by default**, so windows opened side by side
are easy to tell apart (`PaneDeskVariant.forNewWindow`; programmatic windows,
moved panes, and restored windows are unaffected).

**`--color=random` becomes the window's gradient.** In this style a new window
opened with `--color=random` keeps its terminals' theme color and instead gets
its own desk in ONE random hue from the whole wheel (the tones
`--color=random` always drew from): a soft spotlight from just above the top
center (the mock page's own background), a base running from the top-leading
corner toward the bottom-trailing one, and a shade pooling in that corner — so
it gets progressively darker toward the bottom-trailing corner on a dark theme
and lighter on a light one. Every layer is the same hue; only saturation and
brightness vary. History: the first build kept every variant within the
blue/teal family, and seen through 10pt gutters windows opened side by side
were indistinguishable ("the color is the same"); the second used ocean's
two-pool shape with a neighboring second hue, which lit the bottom-trailing
corner instead of darkening it and read as duo-toned. Ocean, the default,
keeps its two pools. It persists as a seed (`PaneDeskVariant`), and the palette is derived from
the seed for the CURRENT theme, so a window keeps its character across a
light/dark switch and a session restore. The expanded sidebar panel goes
translucent over the same gradient instead of carrying its own 1px rule. Cost:
roughly a column or two per split, which is the trade for the depth.

## CLI

Extends the contract in `CLAUDE.md` → "Pane identity" and "Naming" without
changing any existing field.

- **Everything keeps working on a stashed pane** (`+send-keys`, `+read`,
  `+set-banner`, `+set-state`, `+close`, `+reload`, pane-id and registered-name
  targeting) because target resolution walks the tree and the pane is still in
  it.
- **`+list`** marks stashed leaves `[stashed]` in the tree output, and adds
  `"stashed": true` to the leaf object in `--json`. The field is omitted when
  false, the same convention as `banner`.
- **New: `ghoztty +stash --target=<pane>`** and **`ghoztty +restore
  --target=<pane>`**. Agents that open helper panes (log tails, dev servers)
  can put them away themselves. Both are idempotent, like every other command.
  `+restore` follows the `--focus` policy and does not take focus unless asked.
  `+stash` on the last visible pane exits 1 with an error that names the
  invariant.
- **Commands that need a visible pane restore it first.** `+split` anchored at
  a stashed pane restores the anchor, because a new pane beside an invisible
  one is invisible itself. `ghoztty://focus/<stashed pane>` and the `--focus`
  idempotent hits restore it, because raising a pane you cannot see raises
  nothing.
- **`+rearrange`** rebuilds the tree from a layout. A stashed pane that the
  layout omits stays stashed, and one that the layout places is restored.

## Session restore

`SessionLayoutManifest.Entry` gains two additive, optional fields:

- `stashedPaneIDs: [String]?`: the ordered stash, keyed by the stable pane id
  (the leaf's `surfaceID`, which is `$GHOZTTY_PANE_ID`), the same keying
  per-pane banners use.
- `paneSidebarPinned: Bool?` (true = expanded; the name predates collapse/expand)
- `paneSidebarHidden: Bool?`
- `paneSidebarOrder: [UUID]?`: the list's own order, by stable pane id

On restore, the tree is rebuilt with the full topology, so stashed leaves come
back in their slots, and then `stashed` is applied. An older app reading a
newer manifest ignores both fields and shows every pane in the grid, which
loses no panes. `SplitTree`'s own `Codable` (window restoration) gains a
`stashed` key the same way, encoded as paths like `zoomed`.

## Testing

Pure and unit-tested, following the existing pattern. Drags are verified by
inspection and by the user's feel test, not by synthetic events (synthetic
`CGEvent` drags do not drive these gestures).

- **`PaneStashSessionSafetyTests`**, written first, before the feature
  works. It is shaped like `PaneMoveSessionSafetyTests`: it feeds a stash
  and a restore through `SessionCloseIntentPolicy.plan` and asserts nothing
  lands in `close`. It also asserts that a stash followed by a real close of
  the stashed pane does mark it, so the test can't pass by marking nothing.
- **`SplitTreeStashTests`**: the projection (collapse, nested, everything but
  one), ratio lifting for divider/resize/equalize, restore to the exact slot
  and ratio, all three invariants, zoom interaction, `Codable` round-trip,
  focus navigation skipping stashed leaves, and leaf identity across every
  mutation.
- **`PaneDropResolverTests`**: the `.stash` target, its precedence over the
  edge band, its index math, a hidden sidebar resolving as before, and the
  left-edge dwell.
- **`PaneSidebarStateTests`**: collapsed/expanded mode, the narrow-window
  fallback, the pin → expanded migration, and which state persists.
- **`PaneSidebarOrderTests`**: the list's order against the tree (new,
  stashed and closed panes) and the slide of each row during a drag.
- **`PaneSidebarTextTests`**: names, subtitles, and the one-letter monogram.
- **`PaneSidebarWindowTests.dragReordersTheListAndTheTrayStashesAndRestores`**:
  in both modes, a real window driven through `PaneDragSession` — a reorder
  (the rows slide while it is held; the grid unchanged), into the tray, and
  back out to the top of the list.
- **IPC**: `+list` JSON shape, plus `+stash`/`+restore` idempotency and the
  last-visible-pane error.
- **Layout**: the offscreen `NSHostingView` harness for the sidebar's geometry
  (card margins against a TOC card, row metrics, expanded gutter width).
  Geometry from that harness is reliable; glass and color are not, and those
  are checked by eye in the debug app.
- **Geometry property**: the measured grid size of a stashed terminal is
  unchanged across stash and restore with an unchanged layout.

## Out of scope

- **The Quick Terminal.** It has no window chrome for a sidebar to live in.
  Its tree supports stash structurally, but the commands are disabled there
  rather than half-working.
- **Stashing a whole split subtree.** Only leaves stash, as only leaves move.
- **Reordering grid rows in the list.** Grid order is derived from the layout,
  in reading order. Changing it is what dragging in the grid does.


### Glass panes (`macos-pane-glass`, default on)

Tried in the mock as a "Glass panes" toggle with a tint slider; the user chose
**50%**, then lowered it to **40%** after living with it in the app. A pane is a translucent sheet tinted with the terminal's own (neutral)
background — Liquid Glass on macOS 26 — so the spotlight-to-shade progression
of the desk reads through every pane rather than only in the gutters, and the
desk runs up under the titlebar so the window is one surface. A blur alone does
nothing here (the gradient has no detail to frost); the tint and the sheet's
edge are what make it read as glass.

Making it real took removing every opaque layer between the gradient and the
eye, each found by capturing the window (ScreenCaptureKit, own process) and
probing: the terminal renderer's background (now zeroed, as for the
`macos-glass-*` blur styles), the banner strip's base fill, the viewer
template's page and `.markdown-body` backgrounds plus the web view's own,
macOS 26's titlebar backdrop (`titlebarAppearsTransparent`), the window
content stopping at the titlebar (`.fullSizeContentView`), and a debug-only
warning strip whose color background reached up behind the titlebar. Websites
and local HTML pages keep their own backgrounds: a page that sets none was
written for white. Cells a program colors explicitly stay opaque unless
`background-opacity-cells` is set.
