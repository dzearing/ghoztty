# Memory: where it goes, what must free

Read before touching pane/window teardown, anything that stores a closure on
window-owned state, renderer swap-chain targets, or occlusion. Measured with
the scripted scenarios from the 2026-10 memory audit (`temp/memory-report/` in
the audit worktree; methodology there).

## Where memory goes

- **GPU memory dominates.** Each terminal pane's renderer keeps a swap chain of
  three frames (`GraphicsAPI.swap_chain_count`), each with a render target the
  size of the pane in pixels — an IOSurface. A default-size window on a Retina
  display: ~70 MB of IOSurface per window, ~80 MB of GPU memory, ~100 MB of
  physical footprint in all. Font atlases and cell buffers are small next to it.
- Splitting a window does not multiply this: panes share the window's pixels,
  so a pane's targets shrink as it does.
- Terminal state (grid, scrollback pages) is heap; scrollback is capped per
  surface (`scrollback-limit`, 10 MB by default).
- Viewer panes run WebKit out of process: ~20–35 MB per WebContent process,
  plus a shared GPU and Networking process.
- The agent keeps a 2 MB output ring per session (`--ring-bytes`).

## Teardown invariants

- **A closed window frees every pane in it** — the `SurfaceView`, its
  `Ghostty.Surface` (which frees the core surface: renderer + IO threads, GPU
  targets) and, for agent-backed panes, the session CLOSE that only happens on
  free. Anything that outlives the close holds all of that.
- **A closure stored on window-owned state must not capture that state
  strongly**, nor the tree for longer than the state lives. `PaneStackState`
  stores the grid's layout closure (`noteGrid` → `layoutGrid`); capturing the
  state strongly made it retain itself and, through the captured tree, every
  pane (v1.44.0–v1.50.0, ~85 MB per closed window, unbounded).
- `leaks`/`heap` cannot see through Swift indirect-enum boxes
  (`SplitTree.Node`) or SwiftUI's attribute graph: a pane retained that way
  shows no owner but AppKit's own per-view notification block. Count live
  instances (`heap <pid> | grep SurfaceView`) and bisect rather than trust the
  reference tree.
- Run-loop timers and app-wide event monitors outlive their owner unless
  stopped: a repeating timer's block must invalidate itself once its weak owner
  is gone (`PaneStageView.startGlideTimer`, `PaneSidebarCardGlide.start`).
- **A closed terminal frees its core when its close can no longer be undone**
  (`undo-timeout` past), not when its view deinits: `ClosedPaneRelease`,
  scheduled from `surfaceTreeDidChange` for every leaf the close plan closes,
  calls `SurfaceView.releaseClosedSurface()` — the child process exits (or
  the agent session closes, per the close intent), and the IO/renderer
  threads and render targets go. A pane back in any window's tree by then
  (undone, moved) is left alone; a pane closed again restarts the clock
  (`PaneView.pendingRelease`).
- Test: `PaneTeardownTests` (window close, closed split while its view is
  held, undone close, failed viewer insert, freed glide).

### Known, not fixed

- **Closing a split leaves up to ~2 of that window's closed pane views
  alive until the window's tree next changes shape** (or the window closes).
  Present at least since v1.30.0. The chain runs pane ← its leaf node ← an
  old split node ← memory `leaks` cannot attribute (SwiftUI's attribute
  graph, by its pages). Not the undo stack, not the pane sidebar, not
  `layoutGrid`, not the view hierarchy. Since the core is released on the
  close's clock (above), what stays is an inert view of a few KB — no
  process, threads or render targets. Viewer panes are NOT covered by that
  release: a held closed viewer keeps its WebContent process.

## Hidden windows drop their render targets

An occluded surface (window covered, minimized, on another Space, app hidden)
draws nothing (`renderer.Thread.drawFrame` returns early), so on occlusion the
renderer shrinks every swap-chain target to 1×1
(`generic.Renderer.releaseHiddenTargets`). The picture survives: the layer
retains the IOSurface it displays (`Metal.presented_target_outlives_frame`),
and un-occluding presents nothing new until something changes, when each frame
re-creates its target as after a resize. Metal only — OpenGL re-presents its
last target. Test: `PaneTeardownTests.anOccludedTerminalComesBackShowingItsLastFrame`.
