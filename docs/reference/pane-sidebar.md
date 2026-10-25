# Pane sidebar

Per-window list of every pane, and stashing. Read before touching
`PaneSidebar*`, `SplitTree.stashed`, or `StashedPaneSlots`. Design and the
alternatives considered: `docs/design/pane-sidebar.md`.


A per-window list of **every pane in the window**, into which a pane can be
**stashed**: out of the split grid, still running. Design:
`docs/design/pane-sidebar.md` (it records the alternatives and the choices
the interactive mock settled).

- **Pinned** (pin button, or drag the edge out) = a flat edge-to-edge panel the
  grid sits beside. **Unpinned** = the raised glass card collapsed to a 68pt
  **mini rail** of tiles that opens to full width while the pointer is over it.
  Dragging a pinned panel's edge only resizes it (min/max, never unpins).
  The hover-open card FLOATS over the grid — the column never widens on hover,
  so no terminal resizes; only pin/unpin change the column. A window narrower
  than 720pt shows the rail even when pinned. **Ctrl+Cmd+S** hides/shows the
  sidebar entirely.
- A row (and a rail tile's monogram) names its pane the way a stacked strip
  does: the **banner's title** when it has one, else the pane's title
  (`PaneView.displayLabel`; see Stacked panes). The subtitle is then the
  working directory — a titled banner's first line IS the title, so showing
  it again said nothing — and the banner's first line only when the banner
  has no title. The all-windows search still matches the pane's own title.
  The all-windows **window** names are not affected: they group by window
  title (`<project>: <worktree>`), which a pane banner has no say in.
- Rows: grid panes (focused one selected), then **STASHED**. Click focuses /
  restores to the exact slot it left; **Option-click** swaps a stashed pane with
  the focused one; drag a pane's grab handle onto the list to stash it, a row
  into the grid to place it (ONE resolver: `PaneDropTarget.stash` /
  `.joinWindow`). Hover offers only stash (−) / restore (↩). **There are no
  close buttons** except in **trash mode** (header trash button): a red × on
  every row that kills with no confirmation and no undo window; Escape leaves
  it. Right-click → Close Pane is the ordinary confirmed close.
- Activity: a **busy** pane's icon shimmers (no spinner, no glow); `needs_input`
  shows a **question** badge — the human label, never the machine token. Both
  animate on **Core Animation**, never an endless SwiftUI animation, which
  re-renders the whole sidebar every frame (measured: ~90% of the main thread
  at rest with 40 windows; `PaneSidebarAnimationLayers.swift`).
- **All-windows** header toggle (off by default) groups every window's panes.
  Its caption counts the windows. Every window starts **folded** except this
  one (search unfolds all; `PaneSidebarState.isWindowFolded`).
  Windows are **sorted by name** (Finder order; stable as focus moves), and a
  window titled **`<project>: <worktree>`** is grouped under a collapsible,
  **sticky** project header and labeled by its worktree alone
  (`PaneSidebarWindowGrouping`, `PaneSidebarWindowGroupingTests`). Other
  windows sort among the projects at the top level. All windows also brings a **search
  field**: whitespace-separated terms, all of which must appear in a pane's
  window title, title, banner, or directory/location (`PaneSidebarFilter`);
  Return goes to the first hit, Escape clears. Switching scopes slides the
  lists past each other (this window on the left, all windows on the right).
- **A stashed pane never leaves the tree** — `SplitTree.stashed` sits beside
  `zoomed`; the grid renders `visibleTree` and spatial ops lift their ratios
  back. That is what keeps stashing from marking a session CLOSE-on-free
  (`PaneStashSessionSafetyTests`) and keeps every tree walker (IPC, close
  confirmation, the manifest) seeing the pane.
- **A stashed pane keeps its geometry**: it stays mounted, invisible, behind the
  grid, in the slot it would occupy (`StashedPaneSlots`), so it is never sized
  to the 800×600 placeholder (49×17) — even when stashed at launch — and
  restoring it is not a reflow. Tested in `PaneSidebarWindowTests`.
- Persisted: the stash (manifest per-leaf `stashIndex`; `SplitTree` coding for
  AppKit restoration) and the pinned/hidden flags. Hover-open, trash mode and
  the all-windows scope are never persisted.
- Keybinds (macOS defaults): `toggle_pane_sidebar` Ctrl+Cmd+S, `stash_pane`
  Shift+Cmd+M, `restore_stashed_pane` (unbound); Window menu items for all three.
