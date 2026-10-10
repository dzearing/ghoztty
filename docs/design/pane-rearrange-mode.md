# Pane rearrange mode

A toggleable per-window mode (`Cmd+Shift+.`) in which every pane grows a
header with a drag grip and a pop-out button, and panes can be dragged to
re-split, swap, re-tab, pop out, and move between windows.

## What already exists

Roughly half of this ships today, inherited from upstream Ghostty. The design
below extends that machinery rather than standing up a second one.

| Piece | Where | State |
|---|---|---|
| Drag source (`NSDraggingSession`, snapshot preview, Escape-cancel) | `Ghostty/Surface View/SurfaceDragSource.swift` | Works, terminals only |
| Hover-revealed ellipsis grab handle | `Ghostty/Surface View/SurfaceGrabHandle.swift` | Works, terminals only |
| Four triangular quadrant drop zones | `Splits/TerminalSplitTreeView.swift` (`TerminalSplitDropZone`) | Works; tested in `Tests/Splits/TerminalSplitDropZoneTests.swift` |
| Same-window and cross-window pane moves | `Terminal/BaseTerminalController.swift` (`splitDidDrop`) | Works |
| Tear-off to a new window on drop-in-empty-space | `BaseTerminalController.ghosttySurfaceDragEndedNoTarget` | Works |
| Tab-bar hit test by screen point | `Helpers/Extensions/NSWindow+Extension.swift` (`tabButtonHit(atScreenPoint:)`) | Works |
| Tree primitives (`removing`, `inserting`, `swapping`, `replacing`) | `Splits/SplitTree.swift` | Works |
| Identity-preserving whole-tree rebuild | `IPC/RearrangeLayout.swift` | Works |

What is missing: the mode itself, persistent headers, the pop-out button,
center⇒swap, window-edge⇒top-level insert, tab-bar⇒new tab,
long-hover⇒switch tab, and viewer panes participating at all.

**`+rearrange` is not a source of move primitives.** It is a whole-tree
rebuild from a JSON layout. The reusable idea from it is that rebuilding a
tree out of the *same* `PaneView` instances preserves leaf identity — and so
the process, the scrollback, and a viewer's scroll position. Every mutation
below obeys that rule.

## Principles

1. **One resolver, both entry points.** The mode changes *affordances* only.
   Every pane drag — moded or not, from the persistent header or from the
   hover grab handle — goes through one drop-target resolver with the full
   set of targets. There is no moded drop behavior and unmoded drop behavior
   to drift apart.
2. **Headers are a source affordance; drop zones are a destination
   affordance.** Only the moded window grows headers. *Every* window is a
   valid destination for an in-flight drag, moded or not.
3. **A tab is a window.** macOS tabs are separate `NSWindow`s in an
   `NSWindowTabGroup`, each with its own `TerminalController` and its own
   `surfaceTree`. "Another tab" and "another window" are therefore the same
   code path: a different controller.
4. **Resolution is pure.** Point + geometry ⇒ a `Target` value, with no
   AppKit objects in the signature and no mutation. Applying a `Target` is a
   separate, `MainActor` step.

## The mode

`toggle_rearrange_mode`, default `Cmd+Shift+.` (verified unbound), scoped
`.surface` and modelled on `toggle_hero_mode` — the same wiring in
`Binding.zig`, `action.zig`, `command.zig`, `Config.zig`, `Surface.zig`, then
`Ghostty.App.swift` → `BaseTerminalController`, plus a `MainMenu.xib` item and
a `syncMenuShortcut` line.

State lives on the controller as `RearrangeModeState: ObservableObject`,
alongside `heroModeState`.

**On entry** the window's panes gain headers and the tab bar is forced visible
(`window.toggleTabBar(nil)` when `tabGroup?.isTabBarVisible == false`),
remembering that it was forced so exit can put it back.

**On exit** — the toggle again, `Escape`, or the menu item — headers go away
and the tab bar reverts to whatever it was.

`Escape` is overloaded and resolves innermost-first: **during a drag it
cancels the drag** (`PaneDragSourceView`'s own escape monitor) and leaves the
mode on; with no drag in flight it exits the mode.

**Click-to-exit was dropped.** The first draft had a click in a pane's content
leave the mode. It is the weakest of the exits and the most invasive to build
— the terminal wants those clicks — and clicking a pane while rearranging
most often means "focus this one and carry on", not "I am finished". Three
exits are enough.

**The mode persists across drops.** Rearranging is usually several moves in a
row, so a drop does not exit. Focus follows the moved pane, and **the mode
follows the pane**: a drop into another window turns the mode on there too,
so the window you are now looking at is the one you can keep rearranging. The
source window stays in the mode as well — it is still a pile of panes you
were in the middle of sorting.

**Hero mode and rearrange mode are mutually exclusive.** Entering one exits
the other; hero mode already replaces the split tree view wholesale
(`TerminalSplitTreeView` branches on `heroModeState.isActive`).

## The header

24pt tall, at the very top of each pane, taking real layout space. The
existing sticky banner is pushed down below it, and the pane content below
that — so entering the mode does resize every terminal in the window
(`SIGWINCH`, one redraw), and exiting resizes them back. That is the accepted
cost of a header that occludes nothing.

```
┌──────────────────────────────────────────────┐
│ ☰  zsh — ~/git/ghoztty                    ⧉  │  24pt header
├──────────────────────────────────────────────┤
│  **Build status** · 3 failed                 │  existing banner, pushed down
├──────────────────────────────────────────────┤
│ $ █                                          │
│                                              │  pane content
└──────────────────────────────────────────────┘
```

- **Grip** (`line.3.horizontal`) on the left. The whole header *except* the
  pop-out button is the drag source, so the title is grabbable too.
- **Title** — the pane's `title` (already `@Published` on `PaneView` for both
  kinds), truncating. Headers double as labels, which is most of why the mode
  is legible at all.
- **Pop-out** (`macwindow.badge.plus`, tooltip "Move to New Window") on the
  right. Disabled when the window holds a single pane — the same guard the
  existing tear-off uses (`guard surfaceTree.isSplit`).
- **No focus tint.** The first draft called for one; it is redundant. Ghostty
  already dims unfocused splits (`unfocused-split-opacity`), so a second focus
  indicator in the header would be two answers to one question.

Both leaf kinds get it: `TerminalSplitLeaf` and `ViewerSplitLeaf` compose the
same `PaneHeaderView`.

## Drop targets

### The zone map

Resolution is a strict precedence over one screen point:

1. **Tab bar** of any candidate window.
2. **Window edge band** — 28pt inside the window's content rect.
3. **Pane zones** — the pane under the pointer.
4. **Nothing** ⇒ a new window at that point.

```
┌────────────────────────────────────────┐
│ ▓▓ tab bar: new tab (index = button)▓▓ │
├────────────────────────────────────────┤
│▒▒▒▒▒▒▒ window edge: top level ▒▒▒▒▒▒▒▒▒│ 28pt band
│▒┌──────────────────────────────────┐▒▒▒│
│▒│ ╲            above            ╱  │▒▒▒│
│▒│   ╲      ┌──────────┐      ╱     │▒▒▒│
│▒│ left     │   SWAP   │     right  │▒▒▒│
│▒│   ╱      └──────────┘      ╲     │▒▒▒│
│▒│ ╱            below            ╲  │▒▒▒│
│▒└──────────────────────────────────┘▒▒▒│
│▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒│
└────────────────────────────────────────┘
```

**Pane zones** keep today's triangular "nearest edge" map — diagonals corner
to corner, which is why the corners feel right — with a **centered swap
rectangle** inscribed in the middle. The rectangle is 34% of each dimension,
floored at 44pt and capped at 60% of the dimension, so a narrow pane still
has a hittable swap target and a huge pane does not turn mostly into one.

**The window edge band** is 28pt inside the *content* rect (the split-tree
area, excluding the titlebar) and beats the pane underneath it. In a band
corner, the nearer edge wins; on an exact tie, horizontal wins. The cost is
that the outermost 28pt of an edge pane can no longer mean "split that pane on
its outer side" — the rest of that triangle, inboard of the band, still does.

**The tab bar** is uniformly "make a tab": dropping anywhere on it moves the
pane into a **new tab of its own**, at the index of the tab button under the
pointer (or at the end over background or the `+` button). Dropping *into* an
existing tab's layout is reached by **long-hover**: resting over a tab button
for 500ms selects that tab (`tabGroup.selectedWindow = …`) and the drag
continues over the newly revealed layout. One rule for the bar, one gesture
for going deeper.

**Multi-window arbitration.** Candidates are gathered from every visible
terminal window; overlapping frames are resolved by window z-order, topmost
first.

**Self-drops are rejected.** Dragging a pane onto its own zones resolves to
`nil`, as does a swap with itself.

### Visual language

Three outcomes, three visuals, never confusable:

- **Split** (quadrant or window edge): a filled accent rectangle occupying
  exactly where the pane will land — half the target pane for a quadrant, a
  full-height/width strip at the window edge for a top-level insert — with a
  2pt solid accent line on the seam side so the insertion axis reads. This is
  today's overlay plus the seam line.
- **Swap** (center): both panes outlined with a 3pt accent border and a ⇄
  glyph centered in each. No fill; a fill would read as "insert here".
- **Tab bar**: a 3pt vertical accent caret between tab buttons at the target
  index. A tab button pulses while its long-hover timer runs.

The source pane dims to 40% for the duration of the drag.

## Architecture

### `PaneDropResolver` — pure

`WindowRef` is `ObjectIdentifier` of the destination `TerminalController` —
enough to name a window in a pure value, and resolvable back to the
controller by the coordinator without the resolver ever holding one.

```swift
enum PaneDropTarget: Equatable {
    case split(window: WindowRef, pane: UUID, direction: SplitTree<PaneView>.NewDirection)
    case swap(window: WindowRef, pane: UUID)
    case topLevel(window: WindowRef, side: SplitTree<PaneView>.NewDirection)
    case newTab(window: WindowRef, index: Int)
    case newWindow(at: CGPoint)
}

struct PaneDropCandidate {          // one per window, all rects in SCREEN coords
    let window: WindowRef
    let zOrder: Int
    let contentRect: CGRect
    let paneRects: [(id: UUID, rect: CGRect)]
    let tabBarRect: CGRect?
    let tabButtonRects: [CGRect]
}

enum PaneDropResolver {
    static func resolve(
        screenPoint: CGPoint,
        candidates: [PaneDropCandidate],
        dragged: UUID
    ) -> PaneDropTarget?

    /// Separate because it is a timer result, not a drop.
    static func hoveredTab(
        screenPoint: CGPoint,
        candidates: [PaneDropCandidate]
    ) -> (window: WindowRef, index: Int)?
}
```

No AppKit objects, no mutation, takes a **set** of candidate windows by
construction. `TerminalSplitDropZone`'s existing triangle math moves in here
and its tests come with it.

### `PaneDragSession` — app-scoped observable

Holds the dragged pane, the source controller, the live
`PaneDropTarget?`, and the long-hover timer. The drag source updates it from
`draggingSession(_:movedTo screenPoint:)` — a continuous screen-point feed
that already exists and already spans every window. Each window's overlay
observes it and draws the feedback for its own frame.

### `SplitTree.insertingAtTopLevel(view:side:)`

The one genuinely new tree primitive. A window-edge drop is not expressible as
`inserting(view:at:direction:)`, which splits ONE pane and so produces a view
only as tall (or wide) as the pane it split; this wraps the whole root. It
lives on `SplitTree` beside the other mutations rather than in the
coordinator, which also makes it testable with the existing `MockView`.

### `PaneMoveCoordinator` — `MainActor`, applies a target

One function per target, all of them rebuilding trees out of the existing
`PaneView` instances. Cross-controller moves are **remove from the source
first, then insert into the destination**, inside a single undo group.

Every insert — quadrant split and top-level alike — uses ratio `0.5`, the
same default `SplitTree.inserting` and `+split` already use. Removing the
dragged pane from its old position collapses its parent split into its
sibling (`SplitTree.removing`), so the panes left behind reclaim the space
rather than keeping a gap.

### Why not the alternatives

- **Per-leaf SwiftUI `DropDelegate`** (what exists) cannot see the window, so
  it cannot express an edge band; cannot see the tab bar, which is a private
  view in the titlebar outside the SwiftUI tree; and cannot arbitrate between
  overlapping windows. Keeping it alongside the new resolver would leave two
  resolution paths — the drift this design exists to avoid. So
  `SplitDropDelegate` and the per-leaf overlay are **deleted**, and feedback
  is rendered from one per-window overlay.
- **A hand-rolled mouse-tracking drag loop** would mean reimplementing the
  snapshot preview, Escape cancellation, spring-back, and cross-window pointer
  tracking that `NSDraggingSession` already provides.

### Commit path

`endedAt` is the single commit site. The window's `contentView` is registered
for `.ghosttyPaneId` and always answers `.move`, purely so the cursor reads
correctly and the drag does not spring back; its `performDrop` returns `true`
without acting. Drops over the tab bar land outside `contentView` and report
`operation == []`, which is fine — `endedAt` applies
`PaneDragSession.resolvedTarget` either way. One commit site means no chance
of double-applying, and no need to register a drag destination on AppKit's
private `NSTabBar`.

The existing `ghosttySurfaceDragEndedNoTarget` notification is subsumed:
"dropped in empty space" is just `.newWindow(at:)`.

## Session safety

This is the sharpest correctness hazard. `SessionCloseIntentPolicy` buckets a
leaf that left a tree as `close` (mark the agent session CLOSE-on-free) and a
leaf present in a tree as `keepAlive` (clear the mark, clear any
`SessionDetachPin`). A cross-controller move fires that policy twice, once per
controller.

**Ordering is necessary but NOT sufficient**, which is a correction to this
design's first draft. Remove-from-source-then-insert-into-destination does fix
a plain move: the destination's `keepAlive` lands last and clears the source's
`close`. It cannot fix a cross-window **swap**, where each pane departs one
tree and arrives in the other — whichever controller is updated last, the
other one's departing pane is left marked, and a pane that is alive on screen
would have its session terminated when the view is finally freed. There is no
order that works.

So `PaneMoveCoordinator.finishRelocation` **declares the relocated panes
alive** once both trees are in place: it clears the close intent, clears the
detach pin, and un-marks the session. The policy's "left the tree ⇒ closed"
reading is a default for changes whose intent it cannot see; the coordinator
is the one thing that knows this was a move, so it says so, and ordering stops
being load-bearing. Ordering is still done, because it is free and it keeps
the common case correct even if the declaration were ever missed.

- The move never goes through `removeSurfaceNode` (that is the *close* path,
  with its own undo action and focus-retarget semantics). It calls
  `replaceSurfaceTree` directly on both controllers inside one undo group
  named "Move Pane".
- Pop-out to a new window is the same coordinator path with `.newWindow`.
- **A drag never closes a window.** A move that would empty the source window
  is refused (`PaneMoveCoordinator.canMove`): an emptied window closing as a
  side effect of a drag would bypass the close confirmation and the remote
  Disconnect prompt. That also disables the pop-out button on a lone pane.

`PaneMoveSessionSafetyTests` pins all of it, including a test that states the
swap hazard outright in both orders.

Remote and session-persistence panes need nothing beyond this: the pane keeps
its `PaneView`, its `SurfaceView`, and its bound session, and no
`SessionDisconnectPolicy` prompt is involved because nothing is closing.

## Viewer panes

A viewer is an ordinary leaf and must rearrange like any other. Two changes:

- `ViewerSplitLeaf` composes the same `PaneHeaderView`.
- The pasteboard payload becomes the **pane id** rather than the surface id —
  new UTI `com.dzearing.ghoztty.paneId` carrying `PaneView.id`, which is
  already a `UUID` for both kinds (and already mirrors the surface's UUID for
  terminals, so nothing keyed on that changes). `.ghosttySurfaceId` is
  internal-only and is replaced, not kept.

## Testing

Pure and unit-tested, per the constraint; the gesture itself is not
automatable and is not automated.

- `PaneDropResolverTests` (30 tests) — every zone; band-beats-pane
  precedence; band corner ties; points-not-fractions in the band; the swap
  rect's floor and cap on tiny and huge panes; tab-bar index selection;
  multi-window arbitration by z-order; self-drop rejection. Absorbs
  `TerminalSplitDropZoneTests`, which is deleted.
- `SplitTreeRearrangeTests` — top-level insert on each side (including that
  `.vertical`'s `left` is the TOP), that it spans the tree where a pane split
  nests, zoom clearing, removal collapse, swap, and leaf-identity preservation
  across every mutation.
- `PaneMoveSessionSafetyTests` — the cross-controller intent composition: the
  ordering rule for a plain move, the swap that no ordering fixes, the
  declaration that fixes both, and that a real close still marks.
- `RearrangeModeStateTests` — entry/exit and the tab-bar force-visible
  restore, including that re-entering does not forget it.

Manual verification is one debug window (`zig-out/Ghoztty-Debug.app`) driven
by hand. `/Applications/Ghoztty.app` is never touched; debug builds are killed
by exact absolute path.

## Out of scope

- Rearranging across the Quick Terminal.
- Dragging a whole *split subtree* (only leaves move).
- Reordering tabs by dragging a pane header onto the tab bar — the tab bar
  means "make a tab", and macOS already reorders tabs natively.
