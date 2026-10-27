# Pane sidebar

A per-window list of **every pane in the window**, into which a pane can be
**stashed**: out of the split grid, still running. Read before touching
`PaneSidebar*`, sidebar drag-and-drop, `SplitTree.stashed`, or
`StashedPaneSlots`. Design, alternatives and the interactive mock's choices:
`docs/design/pane-sidebar.md`. CLI: `+stash` / `+restore` in
[cli-commands.md](cli-commands.md).

## Modes: collapsed ⇄ expanded

- Two modes, switched by ONE button, the header's first item, centered on the
  rail's width (`PaneSidebarView.toggleLeading`) so it does not move when
  toggled (`setPaneSidebarExpanded`). Both are ONE raised glass card, in the
  same margins (the grid's gutters), with the same top and height —
  **collapsed** at the 44pt rail's width, **expanded** at the panel's width
  (full rows). Every row is one height (`PaneSidebarRow.height`), so a pane's
  icon sits at the same height in both
  (`iconsStayAtTheSameHeightExpandedOrCollapsed`). **Nothing in the list
  touches**: a row's pill is inset `PaneSidebarRow.gap / 2` (2pt) top and
  bottom, as is a window header's hover fill, so any two items — pills, tiles,
  headers, the tray's well — are at least 4pt apart in both modes.
- **No pin, no hover-open**: hovering the rail opens nothing, because the rail
  is where its tiles are dragged.
- **Collapse/expand glides**: the grid's cards glide to their new places
  (`PaneStackState.noteColumnShift` → `PaneStageView.apply` seeds the glide
  from where they were on screen), each terminal held at its size and resized
  once after the motion, while the sidebar's width animates on the same curve
  and rail and panel crossfade (`PaneSidebarState.columnAnimation`).
- **The edge grip is the gutter beside the sidebar in both modes**
  (`PaneSidebarState.edgeGrip`: the grid's margin, elevated; the rail card's
  own margin, flat) — never over the rail's tiles. Expanded, it is ALL of the
  gutter between panel and panes and none of the panel
  (`PaneSidebarState.pinnedEdgeGrip`; `theExpandedSidebarResizesFromTheGutterBesideIt`,
  stops at the panel's widest). Dragging it resizes the panel; pulling the
  rail's gutter past the panel's minimum (180) brings the panel out at that
  width, and pushing the panel well under it (< 120) tucks it back into the
  rail, both ways within one drag (`PaneSidebarState.edgeDrag`; between the two
  it stops at its minimum).
- **The sidebar is a row's first item in a divider drag**: in a row spanning
  the grid, a gutter pushed left past every pane it has tucked away tucks the
  expanded sidebar into its rail as a pane tucks at its minimum
  (`BaseTerminalController.sidebarAwareRow`, after `dividerTuckGive` —
  24–80pt), and dragged back in the same drag brings it out; tucked, the row
  measures the room it gained (see [stacked-panes.md](stacked-panes.md)).
- **It must never change mode on its own**: every mode change is logged at
  `.notice` with its cause (category `PaneSidebar`). Only collapse/expand and
  hide/show change the column, so nothing else resizes a terminal.
- A window narrower than 720pt shows the rail even when expanded (its expand
  button is off). **Ctrl+Cmd+S** hides/shows the sidebar entirely.

## Rows and tiles

- A row (and a rail tile) names its pane the way a stacked strip does: the
  **banner's title** when it has one, else the pane's title
  (`PaneView.displayLabel`; see [stacked-panes.md](stacked-panes.md) → Strip
  labels). The subtitle is then the working directory — and the banner's
  first line only when the banner has no title. The all-windows search still
  matches the pane's own title. All-windows **window** names group by window
  title (`<project>: <worktree>`), which a pane banner has no say in.
- **A rail tile is its row with the text taken away**: the same pill (hover
  wash, accent selection), the same kind glyph at the same place — the rail
  card is exactly that pill (`railCardWidth` = 52) — so collapsing or
  expanding moves no icon.
- **A rail tile has a glassy rim** (`PaneSidebarRow.tileBorder`): a pane
  card's 0.5pt hairline, lit from above — white 22% along the top fading to 5%
  at the bottom on dark (32→10% hovered), black 10→4% on light, white 35→10%
  on the accent pill — so a bare glyph reads as a button without a solid
  outline. A full row has none. It lives in the rail, so it fades out with the
  rail as the panel crossfades in on expand and back in on collapse
  (`columnAnimation`) — never snapped at the mode switch
  (`railTilesHaveABorderThatFadesWithTheMode`).
- The glyph is in the pane's own hue (`PaneSidebarHue`: golden-ratio steps
  along its tree position; light and soft on a dark theme, deeper on a light
  one), a touch quieter unless its pane is focused or hovered. **Hovering a row
  or tile tints its pane in that hue** — a wash and a rim on the pane's card
  (`PaneSidebarHover`, `PaneSidebarHoverTint`: 10% wash, 45% rim), in over
  0.12s, out over 0.2s — so the sidebar says which pane an icon is.
- **A window always holds its panes**: this window's list starts with its
  header — the window's name (no "This Window" tag, which only all windows
  needs), its fold chevron, and on hover + and × — with its panes indented
  under it, as in all windows. In the rail the header is its + alone, in a
  slot exactly the header's height (`PaneSidebarRailAddSlot`,
  `PaneSidebarWindowHeader.height`), so collapsing or expanding still moves
  no icon.
- Rows: grid panes (focused one selected), then — **right after the last of
  them**, under a divider, in the same scrolling list — the **tray** of
  stashed panes. An empty tray is still a visible target: a faint dashed well
  with a tray glyph ("Drag a pane here to stash it" when expanded), lit in the
  accent while a drag would land in it — and no "Stashed" caption, which the
  tray has only while it holds panes (with their count). In **all windows**
  the tray has no divider or caption at all, in either mode: a window's
  stashed panes simply follow its other panes, so collapsing or expanding
  moves nothing — and the empty tray's well shows only while a pane is
  dragged.
- Click focuses / restores to the exact slot it left; **Option-click** swaps a
  stashed pane with the focused one. Hovering an expanded row offers −/↩
  (stash/restore) and **×**; another window's rows offer the × alone. See
  *Closing from the sidebar* below.
- **Every item button** — a row's −/↩/×, a window row's and a project
  header's + and × — is one `PaneSidebarItemButton`: an 18pt circle whose wash
  deepens (8% → 18%; on the accent pill, white 20% → 35%) and whose glyph
  brightens to primary under the pointer, so it reads as clickable.

## Drag to reorder (both modes)

- A drag over the sidebar resolves to one of two lists, split at the tray's
  divider (`PaneDropCandidate.Sidebar.trayTop`): above it
  `PaneDropTarget.sidebarOrder` — a grid pane moves in the LIST ONLY (the grid
  never changes), a stashed pane is restored into it, another window's pane
  joins this window there; below it `.stash`. Any pane — a row, a tile, a grid
  pane's grab handle — goes into the tray to stash and out to restore; a row
  into the grid places it. ONE resolver, ONE drag (`PaneDragSession`), no
  parallel drop path.
- **A row dragged in the list only ever rearranges**
  (`PaneDragSession.isListDrag`): the pointer is held to its own sidebar before
  resolving, so letting go beside the bar, over the grid or past the window is
  the place in the list (or tray) level with the pointer — never a grid move
  or `.newWindow`. A pane's grab handle still drops anywhere.
- **The row itself follows the pointer — up and down only, kept inside the
  bar** — not a drag image (`PaneSidebarRowDrag`: the row's drag source draws
  no preview and feeds the pointer's travel; `PaneSidebarView.ghost` draws the
  row there, lifted, over a solid backing). Let go, it glides to where it
  landed. The others **slide by its height** to make room
  (`PaneSidebarOrder.shift`, a bounded 0.2s animation, none at the drop). The
  list, the tray's header and the tray slide as one sequence, so a row crossing
  into the tray moves the divider with it (`PaneSidebarView.slideIndices`).
- The index is read off the rows **as laid out**: each row's frame is measured
  by a background attached OUTSIDE its slide offset (`rowFrameReader`) — a
  reader inside an `.offset` moves with it, and the index then chases the
  sliding rows.
- The order is per window (`PaneSidebarState.order`, reconciled by
  `PaneSidebarOrder.arranged`): a new pane goes after its tree neighbour (a
  split lands beside its parent), a stashed pane keeps its place for when it
  comes back, closed panes are pruned, and empty means tree order.
- Tests: `PaneSidebarOrderTests`, `PaneDropResolverSidebarTests`,
  `dragReordersTheListAndTheTrayStashesAndRestores` (both modes).

## Activity

- A **busy** pane's row — or tile — sheens, in two Core Animation layers
  (`PaneSidebarTileSheenLayer`), both slanted 45° (an upright band turned
  clockwise, "/": `PaneSidebarSheen.slant`, a shear) and both moving right to
  left, in phase across tiles:
  - the **glint**: a faint band of light (25%) sweeps across the pill every
    2s, starting and ending fully off it, top corner included
    (`PaneSidebarSheen.travel`);
  - the **drift**: a wide, soft, seamless gradient (`PaneSidebarSheen.Drift`:
    one period ≥ 1.5× the row, 2–8% white on dark, 1.5–5% black on light)
    sliding one period every 5s with no gap, inside a pane card's hairline rim (0.5pt, white 10%
    / black 8%), so a busy pill's silhouette is always visible — between
    glints, and on an expanded row — without hanging loose in the list.
  Both fade in and out together over 0.6s as work starts and stops
  (`PaneSidebarRow.busyFade`), never popping. No spinner, no glow, no glyph
  shimmer. Tests: `PaneSidebarSheenTests`.
- **Busy is `PaneView.isWorking`**: the hook-set activity state OR a progress
  report on screen (OSC 9;4 — what animates the pane's border,
  `SurfaceBusyBorder`), so an icon animates whenever its pane's border does.
- **The sidebar shows no question state** — no badge on a row, tile or window
  header (it was unreliable and was removed).
- Animations run on **Core Animation**, never an endless SwiftUI animation,
  which re-renders the whole sidebar every frame (measured: ~90% of the main
  thread at rest with 40 windows; `PaneSidebarAnimationLayers.swift`).

## All windows

- Header toggle (off by default) groups every window's panes. Its caption
  counts the windows. Every window starts **folded** except this one (search
  unfolds all; `PaneSidebarState.isWindowFolded`).
- Windows are **sorted by name** (Finder order; stable as focus moves), and a
  window titled **`<project>: <worktree>`** is grouped under a collapsible,
  **sticky** project header (a clear 6pt gap above and below its band —
  `PaneSidebarOutline.headerGap` — so it never touches a row's hover or the
  tray's well) and labeled by its worktree alone
  (`PaneSidebarWindowGrouping`, `PaneSidebarWindowGroupingTests`). Other
  windows sort among the projects at the top level.
- A **search field**: whitespace-separated terms, all of which must appear in a
  pane's window title, title, banner, or directory/location
  (`PaneSidebarFilter`); Return goes to the first hit, Escape clears.
- Switching scopes slides the lists past each other (this window on the left,
  all windows on the right).
- Hovering a **window** row or a **project** header puts + and × where its
  count was (+ adds — see *Adding from the sidebar*). A window's × closes that window (that tab, in a tab
  group); a project's closes every window under it — while searching, the
  matching windows it shows and counts.

## Adding from the sidebar

Three + buttons, each a MANUAL surface: they focus as Cmd-N / Cmd-D do (the
CLI's background-by-default `IPCFocusPolicy` does not apply). The row and
header ones are `PaneSidebarItemButton`s beside the × (+ then ×, where the
count was, on hover); a click on one never starts a row drag or raises the
row's window through its tap.

- **Header +** (expanded panel only, left of the All-windows toggle; the
  rail's header is its expand button alone): a new window, exactly Cmd-N
  from this window's focused pane — its inherited config (working directory
  per `window-inherit-working-directory`), a random gradient
  (`PaneDeskVariant.forNewWindow`), a remote parent's machine
  (`newWindowInheritingRemote`). `newWindowFromSidebar`.
- **Project header +**: the same, opened from the group's **first window as
  listed** (so it starts in that window's focused pane's directory, on its
  machine), with a pinned title (`setWindowTitle`, as `+new-window --title`)
  of `<project>: new` — or the first free `new-2`, `new-3`, … checked against
  every window's title at click time (`PaneSidebarNewWindowName`) — so it
  lands in the group. `newWindowInGroupFromSidebar`.
- **Window row +**: raises that window and splits its focused pane in the
  **last direction split by hand**, app-wide (`PaneSplitMemory`, default
  right; not persisted). A split by hand is any that comes back from the core
  as `ghosttyNewSplit` — keybinds, the Split menu, the palette, a pane's
  context menu — or a viewer pane's Split item; programmatic splits
  (`ghoztty +split`, AppleScript, App Intents) call `newSplit` directly and
  never touch it, so an agent's layout doesn't skew it.
  `addPaneFromSidebar` → `splitFocusedPane` (what the Split menu items call).
- Tests: `PaneSidebarNewWindowNameTests`, `PaneSidebarAddWindowTests` (each
  + in real windows; manual split remembered, `+split` not).

## Closing from the sidebar

- **Every close from the sidebar asks nothing and takes no focus** — a pane's
  × (and right-click → Close Pane), a window's ×, a project's ×, in this
  window or any other. No running-process confirmation, no remote
  Close/Disconnect alert, no `makeKeyAndOrderFront`, no app activation.
- **It ends what it closes**: the panes' processes and their agent sessions
  — CLOSE-on-free, never a detach. A pane leaves its tree through
  `closeSurface(withConfirmation: false)` (the IPC `+close` path), so
  `surfaceTreeDidChange` marks it (`SessionCloseIntentPolicy`); a window
  closes with `closeTabImmediately` (`window.close()`, never
  `performClose`/`windowShouldClose`, which confirm), so `windowWillClose`
  marks every pane. Nothing pins a detach (`SessionDetachPin` is set only by
  answering Disconnect). Undo still works for the usual undo window; the
  sessions end when it expires.
- **A window's last pane closes the window** (`PaneSidebarClosePolicy`):
  through `closeSurface` the root would go to `closeTab`/`closeWindow`, which
  confirm.
- The window close runs on the next main-loop turn, so a window can close
  itself from its own sidebar.
- Tests: `PaneSidebarClosePolicyTests`, `PaneSidebarCloseWindowTests` (another
  window's pane, its last pane, a window, a group, the sidebar's own window —
  each closed, never made key, no sheet, `sessionClosesOnFree`).

## Stashing invariants

- **A stashed pane never leaves the tree** — `SplitTree.stashed` sits beside
  `zoomed`; the grid renders `visibleTree` and spatial ops lift their ratios
  back. That keeps stashing from marking a session CLOSE-on-free
  (`PaneStashSessionSafetyTests`) and keeps every tree walker (IPC, close
  confirmation, the manifest) seeing the pane.
- **A stashed pane keeps its geometry**: it stays mounted, invisible, behind
  the grid, in the slot it would occupy (`StashedPaneSlots`), so it is never
  sized to the 800×600 placeholder (49×17) — even when stashed at launch — and
  restoring it is not a reflow. Tested in `PaneSidebarWindowTests`.

## Persistence and keybinds

- Persisted: the stash (manifest per-leaf `stashIndex`; `SplitTree` coding for
  AppKit restoration), the expanded/hidden flags and the list's order
  (`paneSidebarOrder`, by pane id). The expanded flag is stored under its
  pre-rename name `paneSidebarPinned` (UserDefaults: `PaneSidebarExpanded`,
  falling back to `PaneSidebarPinned`) — pinned WAS the full panel, so old
  state decodes unchanged. The all-windows scope is never persisted.
- Keybinds (macOS defaults): `toggle_pane_sidebar` Ctrl+Cmd+S, `stash_pane`
  Shift+Cmd+M, `restore_stashed_pane` (unbound); Window menu items for all three.

The sidebar's look on glass (its card is an unfocused pane's card) is in
[pane-style.md](pane-style.md).
