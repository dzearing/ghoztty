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

| Where the pointer is released | Result |
|---|---|
| A quadrant of a pane | Split that pane on that side |
| The **center** of a pane | **Swap** the two panes in place |
| Within **28pt of the window's edge** | Insert at the **top level** of that window's tree, spanning the full side |
| The **tab bar** | Move the pane into a **new tab of its own**, at the index under the pointer |
| Anywhere else | Move the pane into a **new window** there |

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
window edge band beats the pane under it. **Long-hovering a tab button for
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
`PaneDragSession.swift`, `PaneMoveCoordinator.swift`, `PaneHeaderView.swift`.
Tests: `PaneDropResolverTests`, `SplitTreeRearrangeTests`,
`PaneMoveSessionSafetyTests`, `RearrangeModeStateTests`.
