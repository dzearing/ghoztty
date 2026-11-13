# Memory: where it goes, what must free

Read before touching pane/window teardown, anything that stores a closure on
window-owned state, renderer swap-chain targets, or occlusion. Measured with
the scripted scenarios from the 2026-10 memory audit (`temp/memory-report/` in
the audit worktree; methodology there).

## Where memory goes

- **GPU memory dominates.** Each terminal pane's renderer keeps a swap chain of
  three frames (`GraphicsAPI.swap_chain_count`). While the pane is drawing,
  each frame holds a render target the size of the pane in pixels — an
  IOSurface — and its own copy of both font atlases (1–4 MB each). A
  default-size window on a Retina display that is drawing: ~70 MB of
  IOSurface, ~100 MB of physical footprint in all. A pane that has stopped
  drawing gives all of that back but the one frame on screen (below).
- **The GPU driver keeps a working pool per process**: about 225 MB (28
  objects of 8 MB, "Owned physical footprint (unmapped) (graphics)" in
  `footprint`) from the first Metal render pass in the process, whatever the
  size of what is drawn — a bare Metal program drawing one 64x64 frame gets
  the same. It turns reclaimable within ~2 s of the last render pass in the
  process and is gone after ~10 s, and comes back with the next one. Nothing
  in the app sizes it; it is dirty for as long as any pane (or SwiftUI effect)
  keeps drawing. Do not chase it as a leak.
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

## Panes that are not drawing give back their frames

A surface's swap-chain frames give back their render targets (shrunk to 1x1)
and their font atlas copies (`generic.Renderer.releaseFrameResources`) in two
cases. The next real draw finds each frame's target the wrong size and
re-creates it, as after a resize, and uploads the atlases again (~1 ms).

- **Idle**: on screen, but nothing drawn for `idle_release_ns` (3 s). The
  renderer wakes its thread on the first frame drawn after a release
  (`idle_arm`, from whichever thread drew it), the thread runs a one-shot
  timer, and `releaseIdleFrames` releases or asks to be called again; a
  surface sitting still has no timer running. The picture stays: the layer
  retains the IOSurface it shows (`Metal.presented_target_outlives_frame`),
  and the frames let go of their targets **without purging them**
  (`Target.deinitKeepingContents`). `Target.deinit` marks its IOSurface
  purgeable-empty, which blanks a layer still showing it — never use it for a
  target that may be on screen.
- **Hidden**: occluded (window covered, minimized, on another Space, app
  hidden), where `renderer.Thread.drawFrame` returns early. The frame on
  screen is purged too — by the frames if they still hold it, else through the
  layer (`IOSurfaceLayer.purgeContents`, on the main thread, skipped if a
  newer frame has been presented) — and the surface draws again when shown.

**Hidden is more than the window.** `BaseTerminalController
.syncOcclusionToSurfaceTree` tells each terminal it is visible only if its
window is on show, the pane is not stashed, and no other pane is zoomed over
it (`SurfaceView.setRendererVisible`, which passes on changes only). It runs
on window occlusion changes and on every tree change, so a pane stashed,
brought back, moved between windows, or created while the window is covered
starts out right. A stashed pane stays mounted at full size at zero opacity;
before this it drew every frame of its output. Viewer panes have no such
hook: a stashed viewer keeps its watchers and its WebContent process busy.

A blinking cursor (600 ms) or anything that draws more often than every 3 s
keeps its frames. Metal only — OpenGL re-presents its last target.

`ghostty_surface_frame_memory` reports what a surface's frames hold (target
bytes, atlas bytes, released). Measured on 21 panes in 10 windows, all idle:
IOSurface 337 → 143 MB, IOAccelerator 87 → 20 MB.

Tests: `PaneTeardownTests.anIdleTerminalGivesBackItsFramesAndKeepsItsPicture`,
`anIdleTerminalHiddenAndShownAgainIsDrawn`,
`aStashedOrZoomedOverTerminalDoesNotDraw`,
`anOccludedTerminalComesBackShowingItsLastFrame`,
`occludedTerminalsGiveBackTheirRenderTargets`.

## Cell buffers

A frame's Metal cell buffers grow to double what a frame needs
(`metal/buffer.zig` `grownByteLen`). Until v1.54 they grew to double that
times the element size (64x for text cells); Metal commits buffer pages on
first write, so that cost address space, not footprint.
