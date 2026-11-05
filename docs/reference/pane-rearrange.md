# Pane rearrange mode and pane drag-and-drop

Read before touching pane dragging, drop targets (`PaneDropResolver`), moving
panes between windows/tabs, or `PaneMoveCoordinator`. Strip-drag targets are
here too; strip layout is in [stacked-panes.md](stacked-panes.md). Design:
`docs/design/pane-rearrange-mode.md`.


**Cmd+Shift+.** (menu: View → Toggle Rearrange Mode; command palette: "Toggle
Rearrange Mode") toggles a per-window mode in which every pane grows a 24pt
**header** — a drag grip on the left, the pane's title, and a button on the
right that moves the pane out into its own window. The **tab bar is forced
visible** while the mode is on, because it is a drop target. Exit with the
toggle again, **Escape**, or the menu item.

The header takes real layout space: a pane's sticky banner is pushed down
below it and the content below that, so entering and leaving the mode
**resizes every terminal in the window** (one `SIGWINCH` and redraw each way).
That is deliberate — a header that occludes nothing costs a reflow.

**Dragging a pane works with the mode off too.** The mode changes affordances,
never behavior: the hover-revealed grab handle at the top of a pane and the
moded header both start the same drag, and every drop goes through one
resolver. There is no "moded dropping" to drift from "unmoded dropping".

**A drag shows a ghost from its first move** (`PaneDragGhost`): a small card
of the pane — its background, a title strip, and its content — that hangs
below the pointer, held by the title, so the target under the pointer stays in
view. It is at most 220×150, in the pane's shape, for a terminal or a viewer
from either entry point. It has to be a card: a pane's background is drawn
behind the surface, so a terminal's snapshot alone is its glyphs on nothing (a
fresh pane measured 97% transparent). A strip and a list-dragged sidebar row
draw no ghost, because the real thing moves with the pointer; a stashed pane
is unmounted, so its sidebar row stands in.

**The grip owns the cursor.** Over the handle or header the pointer is an open
hand, and a closed hand during a drag. A cursor rect alone can't promise that:
the terminal's scroll view has its own document cursor rect over the whole
pane, and AppKit does not define which of two overlapping sibling rects wins.
So `PaneDragSourceView` also sets the cursor on `cursorUpdate` and on each move
over it, and restores the terminal's cursor on exit. A sidebar row keeps the
arrow (`showsGrabCursor`).

The tab bar is a target only when it is showing: with the mode off that means
the window has at least two tabs. The drag logs its milestones and any refusal
to the `pane-drag` category.

**The pointer feed publishes nothing.** Every pane and sidebar of every window
hangs off `PaneDragSession`, so a publish there is a redraw of all of them, and
moves arrive as fast as the pointer. The session publishes only `pane`, twice a
drag. The target goes to the overlays through `dropFeedback`, and to the one
sidebar it is in through that window's `PaneSidebarState.dropTarget`; a pane
leaf observes neither (`PaneDragFade` holds the fade). Geometry is re-read per
move, which is cheap, but `NSApp.orderedWindows` is not: it stalls for tens of
milliseconds every few calls, so the order is read at the start, after a dwell
switches tabs, and when the number of windows changes. Measured in the debug
build with 6 windows of 3 panes: about 150ms a move before, under 3ms after, and
about 50ms when a sidebar row boundary is crossed. Tests:
`aMoveRedrawsOnlyTheOverlays`, `aSidebarTargetReachesOnlyItsSidebar`,
`aWindowOpenedMidDragIsATarget`.

| Where the pointer is released | Result |
|---|---|
| A triangle of a pane | Split that pane on that side |
| The **center box** of a pane | **Swap** the two panes in place |
| A **divider** (10pt either side of the gap's middle) | **Insert** in its gap, spanning its length, with a third of the space its split had; the two sides each give up their share |
| Within **28pt of the window's edge** | Insert at the **top level** of that window's tree, spanning the full side |
| The **tab bar** | Move the pane into a **new tab of its own**, at the index under the pointer |
| Anywhere else | Move the pane into a **new window** there |

A pane's targets are the pane as drawn (`PaneFootprint`), not its terminal: a
banner or rearrange header is on the pane, so the triangles, center box, dividers
and window edge all count it. Test: `aBannerIsPartOfItsPaneToADrop`.

**A spot that would change nothing doesn't react.** A split, divider or edge
that would leave the pane where it is has no target and no preview: the session
makes the move on a copy of the tree and compares the layouts, sizes aside, with
a run of splits on one axis read as one row
(`PaneMoveCoordinator.wouldLeaveInPlace`, `SplitTree.hasSameLayout`). So in
A | B, dragging A, B's left triangle, the divider and the window's left edge are
all quiet. Letting go there does nothing. A stashed pane is not on the grid, so
every place is new to it.

Each hover previews where the pane lands. A split, top-level insert and divider
insert fill that area with seams where the new dividers run; a swap fills the
center box itself, with a ⇄ glyph. A divider hides between panes overlapping in
a stack: there's no gap to drop in (`PaneDropCandidate.Divider.all`).

**A strip (a minimized pane) has its own targets** — it is a pane put away
in its row, so it gets the targets of putting it somewhere else in that row or
taking it out of the window, never a pane's quadrants or swap
(`PaneDropResolver.resolveBlade`, in this order):

| Where a strip is released | Result | Preview |
|---|---|---|
| Within **12pt of a screen's edge** | A **new window** holding the pane, **tiled** to that half of the screen's visible frame | A translucent accent panel over that half (`TileDropPreview`) |
| The **pane sidebar** | Stash it, as any pane | As any pane |
| A **slot of its own row** — the gutter between two of its cards or strips (reaching 24pt into each), or either end | **Move it there** within the row: on show between cards on show, a strip among strips; the row stays collapsed | An accent insertion bar down the gutter (`BladeDropOverlay`) |
| Within **28pt of a window's edge** | Insert at the **top level**, as any pane | As any pane |
| Anywhere else (over a pane, another window, the desktop) | **Nothing** — the card settles back | — |

The slots are read off the strips and cards on screen
(`PaneBladeDrag.slots`, from the row `PaneStackState.stackMinimizing` names);
a slot beside the strip's own place is left out. A strip that is one pane of a
minimized column leaves the column. Resize grips never compete: they live in
the gutters only, and a strip is a drag source of its own.

Pane zones use the pane's diagonals (nearest edge wins), with a centered swap
rectangle at 34% of each dimension — floored at 44pt so a narrow pane stays
hittable, capped at 60% so a small pane does not become mostly swap. The
window edge band beats a divider, and a divider beats the pane under it. **Long-hovering a tab button for
500ms selects that tab** so the drag can continue into its layout; that is the
only way to drop *into* an existing tab, since the bar itself always means
"make a tab".

**Cross-window and cross-tab drags are the same code path** — a macOS tab is
its own `NSWindow` with its own `TerminalController`, so "another tab" and
"another window" are both just a different controller. Resolution takes a
**set** of candidate windows and arbitrates overlaps by z-order.

**Viewer panes rearrange like any other leaf**, and terminal panes keep their
process, scrollback, and session: every mutation rebuilds the tree out of the
*existing* `PaneView` instances, the same identity-preserving rule
`+rearrange` follows.

**A drag never closes a window.** A move that would empty the source window is
refused, and the pop-out button is disabled on a lone pane — an emptied window
closing as a drag side effect would bypass close confirmation and the remote
Disconnect prompt.

**Moving a pane between windows must not end its session.**
`SessionCloseIntentPolicy` reads a leaf leaving a tree as "closed" and marks
its agent session CLOSE-on-free. Removing from the source before inserting
into the destination fixes a plain move, but **no ordering fixes a
cross-window swap** (each pane departs one tree and arrives in the other), so
`PaneMoveCoordinator.finishRelocation` explicitly declares the relocated panes
alive once both trees are in place. The coordinator is the one thing that
knows a move happened, so it says so.

Design: `docs/design/pane-rearrange-mode.md`. Code:
`macos/Sources/Features/Splits/PaneDropResolver.swift` (pure),
`PaneDragSession.swift`, `PaneDragSource.swift`, `PaneDragGhost.swift`,
`PaneMoveCoordinator.swift`, `PaneHeaderView.swift`.
Tests: `PaneDropResolverTests`, `SplitTreeRearrangeTests`,
`PaneMoveSessionSafetyTests`, `RearrangeModeStateTests`,
`PaneGrabHandleWindowTests` (a real `NSDraggingSession` blocks on the physical
button, so it covers each side of one and never starts it).
