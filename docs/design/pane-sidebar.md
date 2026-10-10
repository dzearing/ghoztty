# Pane sidebar

A per-window, vertical list of every pane in the window. A pane can be
**stashed** into it, which takes it out of the split grid without ending it,
and restored from it by click or drag. Pinned, the list is a flat panel down
the window's side; unpinned, it collapses to a raised rail of icons that opens
while the pointer is over it.

The problem, in the user's words: *"Right now I have a really difficult time
managing panes that I just want to minimize in the window."* Today a pane can
only be closed, which kills it, or covered by hero mode, which makes one pane
big and hides the rest. Nothing says "get this out of my way but keep it
running".

**Status:** agreed and being built. The interaction model was settled over an
interactive HTML mock (`temp/mocks/pane-sidebar/index.html`, not committed —
`temp/` is gitignored); everything under "The sidebar view" records what that
mock converged on, including the choices that were tried and dropped.

## The model: one roster, two states

The sidebar lists **every pane in the window**, in two sections:

```
┌─ PANES ─────────────── 📌 ┐
│ ▸ zsh — ~/git/ghoztty     │   ← in the grid; the focused pane is selected
│   claude — pane-sidebar ● │     ● busy
│   README.md               │
│ ───────────────────────── │
│   STASHED                 │
│   claude — relay   question│   ← out of the layout, still running
│   tail -f app.log         │
└───────────────────────────┘
```

| Gesture | On a grid row | On a stashed row |
|---|---|---|
| Click | Focus that pane | **Restore** it to where it was in the grid, and focus it |
| Drag into the grid | Move it (the same drop as the hover grab handle) | **Restore** it at the drop target |
| Drag into the stashed section | **Stash** it, at that position in the list | Reorder the stash |
| Drag to empty space or another window | Pop out / move, as today | Same, and it is no longer stashed |
| Hover button | `−` stash | `↩` restore |
| Right-click | Stash · Move to New Window · Close Pane | Restore · Swap with Focused Pane · Move to New Window · Close Pane |
| Trash mode on | red `×`: kill now, no confirmation | red `×`: kill now, no confirmation |

There is **no close button outside trash mode** (see Closing panes).

Dragging any pane, from its grab handle or its rearrange-mode header, onto the
sidebar stashes it. When a pane leaves the grid the remaining panes reflow to
fill its space, exactly as they do when a pane is closed.

**Vertical tabs are the extreme case, not a mode.** Stash everything except
one pane and the sidebar is a list of tabs: click a row and that pane comes
back. (A click restores a pane *beside* the others rather than swapping it in.
Alt-click a stashed row to **swap** it with the focused pane, which gives
one-pane-at-a-time switching for anyone who works that way.)

### Why this model won

- **No mode to enter.** The sidebar is always valid. You stash a pane the same
  way whether the sidebar is pinned, hidden, or in rearrange mode. The
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

A stashed pane is unmounted, exactly like a pane hidden behind a zoom. Its
`SurfaceView` keeps its last frame, and the core keeps its last grid size:

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
- **Pinning and unpinning** change the column's width, which resizes the
  grid's panes once each way — the same trade rearrange mode's header makes:
  the sidebar takes real space so that it never covers content. **Hovering
  the mini rail resizes nothing**: the card opens over the grid while the
  column stays mini (see Pinned and unpinned).

This will be verified by measuring a stashed surface's grid size before stash
and after restore (`ghostty_surface_size`), not assumed.

### Drop resolution: one resolver, a new target

Per the rearrange design's first principle, the sidebar is a new **drop
target** and a new **drag source** on the existing machinery. It does not get
its own resolution path.

```swift
enum PaneDropTarget {
    …
    /// Stash the dragged pane into this window's sidebar at `index`.
    case stash(window: PaneDropWindowRef, index: Int)
}

struct PaneDropCandidate {
    …
    let sidebarRect: CGRect?           // nil while the sidebar is hidden
    let stashRowRects: [CGRect]        // stashed rows, top to bottom
}
```

**Precedence:** tab bar, then **sidebar**, then window edge band, then pane
zones, then a new window. The sidebar comes before the edge band because it is
chrome on top of the content, as the tab bar is. A point on it never also
means a pane. Anywhere on the sidebar means stash, and the index is the gap
between stashed rows nearest the pointer. Dropping onto the grid section also
stashes, at the top of the stash, so a drop on the sidebar never does
nothing.

**The mini rail is always a target.** Unpinned, the sidebar is still a column
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
- **Pinned is a FLAT panel**, not a card: edge to edge down the window's left
  side, square, no shadow or rim, separated from the grid by a 1px rule in the
  split-divider color, on the terminal background lifted by the same wash the
  card uses. Pinned, the sidebar is part of the window, so it should read as
  one more column of it, not as something floating on it. (The first draft
  made it the glass card; the mock showed that a floating card in a column the
  grid is laid out beside reads as an overlay that isn't one.)
- **Unpinned is the raised glass card** — `SidePanelCard`'s shape, glass,
  opaque base, and `GlassCard.outerMargin` (12pt on every side) — collapsed to
  the mini rail. The card's opaque base becomes a parameter (it is hard-wired
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
| Trash | `trash` | `trash.fill` in system red; caption reads **CLICK × TO KILL** in red |
| Pin | `pin`, tilted 45° | `pin.fill`, upright (the tilt animates) |

In the mini rail the three stack vertically at the top of the card.

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
  - `needs_input`: a **question** badge in the accent color — the same label
    the title suffix shows — gently pulsing on a stashed row. A stashed pane
    that goes from `busy` to `needs_input` is the row to look at next.
  - `idle`: nothing.
  - A **bell** on a stashed pane shows a dot until the pane is restored.

The two sections share one list with a hairline divider and a "STASHED"
caption (with a count) that appears only when the stash is non-empty. During a
drag with nothing stashed, an empty "Drop to stash — it keeps running" slot
appears so the target is visible.

**While the sidebar is hidden,** a stashed pane asking a question still shows,
because the window title's activity suffix is aggregated across every leaf in
the tree and stashed panes are still in it.

### The mini rail

Unpinned, the card collapses to a 44pt rail (a 68pt column with its margins).
Every pane is a 28pt tile in the same order, the focused one in the selection
pill, and a hairline between the grid and stashed sections.

- **Tiles need labels.** Every terminal has the same icon, so a terminal tile
  shows a short **monogram** taken from the part of its title that tells panes
  apart: the text after an em dash if there is one (`claude — relay` → `RE`,
  `claude — pane-sidebar` → `PS`), else the command name (`zsh`, `npm`), up to
  three characters. Viewer tiles keep their kind glyph.
- **Activity rides as a corner badge**: a blue `?` (question) top-right, a dot
  (bell); busy is the same shimmer, on the monogram.
- **Hovering a tile** shows a label beside it: title, subtitle, which section
  it is in, and its state in words ("Has a question for you").

### Pinned and unpinned

| | Pinned | Unpinned |
|---|---|---|
| Look | Flat panel, full width | Raised glass card, collapsed to the mini rail |
| Column | `--sidebar-w` (default 240, drag the edge) | 68pt |
| Pointer over it | — | Opens to full width **over** the grid after a 140ms intent delay; contracts ~0.3s after the pointer leaves |
| Persisted | Yes, per window, in the session manifest | (the same flag) |
| Narrow window (< 720pt) | Shows the mini rail — the full panel would crowd the grid, the rail doesn't | Mini rail |

- **Pin is the expand/collapse control.** There is no separate collapse
  button; dragging the edge does the same thing (pull the rail past 120pt and
  it pins open; push the panel under 140pt and it unpins).
- **Unpinning never snaps shut under the pointer.** The pointer is on the pin
  when you click it, so the card stays open until the pointer leaves.
- **The hover-open card floats; the column does not widen.** Widening the
  column on hover would resize every terminal in the window — a `SIGWINCH` and
  a TUI redraw — each time the pointer passed by. Only pin/unpin, which are
  deliberate, change the column.
- The card never contracts out from under an open menu, a confirmation, or a
  drag.
- **Ctrl+Cmd+S hides or shows the sidebar entirely.** Hidden is persisted
  with the pin.
- An earlier draft had an *overlay* mode (unpinned = hidden; the shortcut
  slid a floating card in). The mini rail replaced it: it keeps every pane's
  state visible for 68pt and is always a drop target.

**Why the stash persists.** The viewer side panel's open/closed state is
deliberately ephemeral because restoring an overlay would hide the content it
covers. A **stash** is different: it is the window's layout, like a split
ratio or a zoom, and losing it on relaunch would hand back every pane you put
away. The **pin** and **hidden** flags are layout too (they size the column),
so they persist. The hover-open state, the trash mode, and the all-windows
scope are not persisted — the first two are transient by nature, and a window
should never come back in kill mode.

### All windows

A header toggle, **off by default**, that widens the roster from this window
to every Ghoztty window, so window management can happen from one list.

- The list is grouped by window: this window first (labelled *this window*),
  then the others front to back. A **group header** shows the window's name,
  its pane count, and a **question** badge when any pane in it has one. Click
  it to raise the window; the chevron folds the group.
- Another window's focused pane is shown in the unemphasized (gray) pill —
  it is that window's focus, not this one's.
- Clicking another window's row raises that window and focuses the pane (or
  restores it there, if stashed) — `IPCServer.focusTarget`, the same verb as
  `ghoztty://focus`.
- Drag a row into this grid to bring the pane here; drag one of this window's
  rows onto another window's group to send it there. Both are the existing
  cross-window move.
- In the mini rail, windows are separated by a hairline; the hover label
  names the window.

### Closing panes

**No close buttons, unless the trash is on.** Hovering a row offers only `−`
(stash) or `↩` (restore). A stray click on the list can never end a session.
(Middle-click-to-close, the browser convention, was tried and removed for the
same reason.) Right-click → Close Pane remains, and goes through the normal
close path — confirmation when something is running, Disconnect for remote
panes, undo.

**Trash mode** (the trash button): every row, rail tile, and — with the
all-windows scope — window header gets a solid red `×`, and hovering a row
tints it red. One click **kills**: no confirmation, and **no undo window** —
the agent session is ended immediately rather than at undo-expiry, because
"just kill the terminal" is the point. The row fades out and a "Killed …"
notice appears. The mode stays on so several panes can be cleared in a row;
the trash button again or Escape leaves it. Never persisted.

### The grab handle

The hover-revealed grab handle at the top of every pane
(`SurfaceGrabHandle`) is the everyday way to drag a pane onto the sidebar. It
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
| `toggle_pane_sidebar` | **Ctrl+Cmd+S** (the system "Show Sidebar" chord in Finder, Mail, and Notes) | View → Show/Hide Pane Sidebar |
| `stash_pane` | **Shift+Cmd+M** (Cmd+M minimizes the window; Shift+Cmd+M stashes the pane) | Window → Stash Pane |
| `restore_stashed_pane` | none by default; restores the top of the stash | Window → Restore Stashed Pane |

Both default chords are unbound in Ghoztty's default config and main menu (no
`s` or `m` bindings exist; the menu has only Cmd+M, Minimize).

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
- `paneSidebarPinned: Bool?`

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
- **`PaneSidebarStateTests`**: pin/overlay state, the narrow-window fallback,
  and which state persists.
- **IPC**: `+list` JSON shape, plus `+stash`/`+restore` idempotency and the
  last-visible-pane error.
- **Layout**: the offscreen `NSHostingView` harness for the sidebar's geometry
  (card margins against a TOC card, row metrics, pinned gutter width).
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
