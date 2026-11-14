# Audit-1, area M: memory and leaks (T2961)

- **Date:** 2026-11-14
- **Commit audited:** a8349acb1
- **Baseline:** `../baseline-1.json` (T2958)

**Produced by** three Fable 5.2 auditors (`claude-fable-5-2`, passed
explicitly) working read-only and in parallel:

1. **A: close-path ownership.** What every pane, tab, window and viewer
   (frontend side) close frees against what the open path allocated, the
   allocators each build uses, and what explains the first-cycle residue and
   the per-cycle growth.
2. **B: footprint, scrollback and caches.** Where the idle 325 MB and the
   ~110 MB per added pane go, how scrollback is sized and returned, and
   which caches have no cap.
3. **C: app-lifetime collections.** Registries, maps and lists in the win32
   app that could grow per pane, per IPC request or per config reload.

Areas W (T2960, `W-findings.md`) and R (T2959, `R-findings.md`) were read
first and are not re-reported. Viewer internals (T2963), IPC transport and
the agent (T2962) and the core hot paths (T2964) are other audits.

**Verification.** This turn read the cited lines for every surviving claim
before filing it. Two pairs were the same defect seen by two auditors and are
merged: A3 = B-02 (PA-M02), and A1 + C1 (PA-M05).

## What the area does and does not explain

- **No allocation leak was found on any close path.** All three auditors
  traced the pane, tab and window teardown and found every owned field
  freed (see "Checked and found clean"). The Debug build uses the GPA, and
  ReleaseFast uses the CRT heap. Their retention policies differ, yet both
  builds leave the same residue, so heap high-water is not the main cause.
- **The ~29 MB second-cycle growth is most likely a one-time driver fill,
  not a leak.** T2782's heap census (2026-11-08) found the same shape in
  `window-close-memory.ps1`: +12 MB of `PAGE_WRITECOMBINE` (the GPU driver's
  upload pool) plus ~6 MB of non-heap RW, with NT heaps flat, settling after
  cycle 4. In all four baseline-1 runs, `gpu_shared_mb` at close rises
  14-22 MB in the same step. The baseline takes its one delta at cycle 2,
  inside that fill window (PA-M05).
- **The ~390 MB first-cycle residue beyond PA-W01 is not in Zig-owned
  memory.** The best inference is driver memory from the per-pane GL, D3D11
  and DComp devices (PA-R02). PA-M05 is the measurement that settles it.
- **The ~60 MB per pane beyond thread stacks is mostly not ours either.**
  Terminal pages are ~2 MB at creation, renderer CPU buffers ~0.75 MB, and
  the font grid is shared. What remains fits PA-R02 (inferred).
- **Large pixel buffers we do own are kept at their largest size**: per-pane
  snapshots (PA-M01) and per-window desk and overlay buffers (PA-M02). At
  4K these are hundreds of MB.

## Findings

Each finding lists:

- **Where:** file and line
- **Cost:** measured, or estimated (and from what)
- **Fix**, **Risk**, **Pri:** priority
- **Task:** the parity task it was filed as

| Id | Pri | Finding | Task |
|---|---|---|---|
| PA-M01 | P1 | A pane keeps two full-size pixel copies of itself after any glide, drag ghost or hero capture | T3001 |
| PA-M02 | P1 | Each window keeps its desk and overlay pixel buffers at their largest size until it closes | T3002 |
| PA-M03 | P1 | The page pool commits up to ~7 MB beyond the scrollback limit per pane, and preheats 4 pages | T3003 |
| PA-M04 | P1 | Cleared scrollback is never returned until a reset or pane close | T3004 |
| PA-M05 | P1 | The baseline measures the leak delta inside a known one-time driver fill, and cannot say what is outside the heap | T3005 |
| PA-M06 | P2 | `+read` formats the whole scrollback on the UI thread to return the last 50 lines | T3006 |
| PA-M07 | P2 | Each pane's config change re-runs the whole app-level reload | T3007 |
| PA-M08 | P2 | The machine-chooser directory probe and the agent re-check spawn an OS thread per event | T3008 |
| PA-M09 | P2 | Renderer and termio mailboxes are destroyed without draining owned payloads | T3009 |
| PA-M10 | P2 | Renderer row lists preallocate 3x the column count per row | T3010 |
| PA-M11 | P2 | First use of a missing glyph opens every font file in the Fonts folder | T3011 |
| PA-M12 | P2 | `Window.onDestroy` and `Window.deinit` are drifted twins; `onDestroy` never cancels the open dialogs | T3012 |

### PA-M01: pane snapshot buffer and DIB live as long as the pane (P1)

- **Where:** `src/apprt/win32/Surface.zig:2655-2670` (buffer), `:2820-2844`
  (DIB), freed only in deinit at `:1385-1395`. Full-size requests come from
  `PaneView.zig:470` (`glideSnapRequest`), the opening path
  (`glideSnapRequestExact`) and the drag ghost.
- **Cost (estimated):** 2 x w x h x 4 bytes per pane that has ever glided,
  opened or been dragged: 10 MB at 1400x900, 29 MB at 2560x1400, 66 MB at
  4K.
- **Fix:** free both when the glide lands and when hero mode ends, under
  `snap_mutex`. The DIB already holds the pixels, so the buffer can go
  straight after publish.
- **Risk:** low. The next request reallocates, costing page faults on the
  first frame of a glide.

### PA-M02: window-sized chrome buffers only grow (P1)

- **Where:** `src/apprt/win32/PaneDesk.zig:2508-2510` ("Grown, never
  shrunk"), `scratch`, `scratch_desk`, `scratch_grad`, `quarter_buf`,
  `glow_px` (2n), and the DIBs, all on `std.heap.page_allocator`
  (`:295`), freed only in `deinit` (`:1140-1152`).
  `src/apprt/win32/chrome_comp.zig:359-362` (`Overlay.desk` and `.px`).
- **Cost (estimated):** 5 MB per buffer at 1400x900 and 33 MB at 4K. With
  5-8 live per window, that is ~25-40 MB at 1400x900 and ~165-265 MB at 4K.
  A window maximized once keeps the maximized size. How many are live at
  once depends on the style (inferred).
- **Fix:** trim to the current size when a drag or resize ends, or when the
  window is minimized or occluded, using the under-a-quarter rule the DIB
  already follows. Free the glow, overlay and scratch buffers when their
  feature goes idle.
- **Risk:** low to medium. These exist to avoid page faults mid-drag (T2520,
  T2946), so trim only at gesture end or idle.

### PA-M03: page pool arena overshoot and preheat of 4 (P1, shared file, Windows-only cost)

- **Where:** `src/terminal/PageList.zig:34` (`page_preheat = 4`), `:327`
  (`std.heap.page_allocator` off Darwin), `:369-374` (pool init). The arena
  grows each node by 1.5x, and Windows commits each node whole.
- **Cost (estimated):** a standard page is ~400 KB. A pane at the 10 MB
  default limit has ~17.7 MB committed, so ~7 MB is commit that is never
  touched. At creation, 4 pages commit ~2.1 MB where 1 holds the viewport.
  The alternate screen pays the same the first time a TUI runs.
- **Fix:** on Windows, give the page pool an allocator that reserves a range
  and commits per page, or allocates in fixed chunks. Preheat 1 when
  `max_scrollback == 0`.
- **Risk:** medium. This is the terminal's hot allocation path. Gate it on
  Windows. The page-zeroing assumption at `PageList.zig:727-729` must hold.
  macOS maps lazily, so no Mac half is owed.

### PA-M04: cleared scrollback is not returned (P1, shared core)

- **Where:** `src/terminal/PageList.zig:3470-3476` (`destroyNode` zeroes the
  page and puts it on the pool's free list). Only `reset()` (RIS,
  `:716-725`) shrinks the arena.
- **Cost (estimated):** a pane that filled its scrollback keeps 10 MB (17.7
  MB committed, per PA-M03) after `cls`. Ten panes that each ran one noisy
  build keep 100-177 MB. The memset also keeps freed pages in the working
  set.
- **Fix:** release the free-list excess when history is erased, or when the
  free list passes a few pages. With PA-M03's allocator this becomes a
  decommit of the freed pages.
- **Risk:** medium; shared core. Tracked pins and the zeroing invariant must
  survive. A Mac half is filed, because the code is shared.

### PA-M05: the baseline cannot tell a fill from a leak (P1, tooling)

- **Where:** `scripts/perf-baseline.ps1:483` (two cycles) and `:535` (the
  delta taken at cycle 2).
- **Evidence:** see "What the area does and does not explain". In all four
  baseline-1 runs, `gpu_shared_mb` at close rises 14-22 MB from cycle 1 to
  cycle 2.
- **Fix:**
  - Give the cycle phase the adaptive warm-up that `window-close-memory.ps1`
    has (`-MaxWarmup`, `:250`), and report the slope over at least 5
    settled cycles.
  - Add the region census (`-HeapCensus`: NT heap, write-combined, private
    non-heap, stack) at start, cycle-1 closed and the last closed sample.
  - Add an A/B with composition present off (`GHOZTTY_COMP_PRESENT=0`) to
    put a number on PA-R02's share of the first-cycle residue.
  - If the quit path returns through `main`, run Debug through N cycles and
    read the GPA leak report (`src/global.zig:183-187`).
- **Risk:** none. Distinct from PA-W05 (T2989), which adds per-thread
  context-switch and per-type handle and USER diffs.

### PA-M06 to PA-M12 (P2)

- **PA-M06** `src/apprt/win32/IpcHandlers.zig:1374-1381`: `+read` selects
  from the top of the screen and calls `dumpTextLocked` over the whole
  scrollback while holding the renderer's priority lock. Only then, at
  `:1408`, does `read_tail.tail` keep the requested lines. A 50k x 120
  scrollback costs ~6 MB of transient formatting per call, and the pane's
  renderer stalls for that long. An agent polling at 1 Hz churns ~360 MB a
  minute. Fix: start the selection `line_count` plus a margin above the
  bottom. A Mac check is filed, because the Swift `+read` was not read.
- **PA-M07** `src/apprt/win32/App.zig:9202-9258`: the `config_change`
  handler never reads `target`. The core sends it once per surface
  (`src/App.zig:139-141` to `src/Surface.zig:2598-2603`) and then for the
  app. Each delivery deep-clones the config, refreshes every window's chrome,
  re-registers the global hotkeys and refreshes Settings: 11x the work at 10
  panes. A surface-scoped soft reload also overwrites `App.config` with that
  surface's conditional-state variant. Fix: do app-level work only for
  `.app`.
- **PA-M08** `src/apprt/win32/DirectoryProbe.zig:155` (one detached thread
  per directory fetch; a 5 s poll while the chooser is open, inferred) and
  `src/apprt/win32/AgentIntegration.zig:171` (one per re-check, at most one
  a minute, triggered from pane init). Each costs ~64 KB of NVIDIA memory
  that is never returned (`worker_pool.zig:3-5`). The same shape as PA-W06.
  Fix: run both on `worker_pool`.
- **PA-M09** `src/renderer/Thread.zig:233`: `mailbox.destroy` frees only the
  queue (`src/datastruct/blocking_queue.zig:102-105`). Messages still queued
  that own memory leak: `.change_config` and `.pane_backdrop`
  (`src/renderer/message.zig:126-137`), and the termio side likewise
  (`src/termio/mailbox.zig:46-53`). Rare, since it needs a message to land
  between the last drain and the stop. Fix: pop and `deinit` each one before
  `destroy`. Shared core.
- **PA-M10** `src/renderer/cell.zig:118-122`: `fg_rows` starts each row at
  `columns * 3` capacity of 32-byte `CellText`. That is 0.73 MB at 170x45
  and ~5.5 MB at 480x120 per pane, where 1x is typical. Fix: start at 1x.
  Shared core. Pairs with PA-R12.
- **PA-M11** `src/font/discovery.zig:1050-1085`: fallback discovery calls
  `Face.initFile` on every `.ttf`, `.otf` and `.ttc` (up to 16 faces each)
  in the system and user Fonts folders, once per new missing codepoint. The
  cost is CPU (tens to hundreds of ms per first-seen codepoint, estimated),
  not memory. Fix: one family and coverage index per process.
- **PA-M12** `src/apprt/win32/Window.zig:2476-2484` against `:21927-22015`:
  `deinit` stops the composition drag thread and cancels the rename, banner
  and machine-chooser dialogs. `onDestroy`, the path a `+close` takes, does
  neither. Whether those dialogs free themselves when their owner is
  destroyed was not traced. Fix: one shared teardown, plus a test that
  closes a window with each dialog open.

## Dropped

- **B-06, "kitty image storage is 320 MB per screen with no process budget"**
  (`src/config/Config.zig:2493`). Verified, but dropped. It is bounded and
  enforced (`graphics_storage.zig:116-121`), only users who display images
  reach it, and the default is upstream's. Changing it is a user-visible
  default on both platforms, for a cost no baseline phase shows.

## Claims that did not survive verification

- **"The +28.8 MB is 64 KB x ~495 D3D driver threads exiting per cycle."**
  The arithmetic fits, but T2671's log entry records that
  `GHOZTTY_COMP_PRESENT=0` removes those threads without changing private
  bytes, and T2782's census put the growth in write-combined and non-heap
  regions.
- **"The Debug allocator never returns pages."** The Zig 0.15.2 GPA frees
  emptied buckets and large blocks.
- **"The page pool retains memory after close."** `PageList.deinit` frees
  oversized pages and then the pool (`:657-676`).
- **"Fonts or atlases load per pane."** The grid is shared and ref-counted
  through `SharedGridSet`. Only the GPU copy is per pane (PA-R03).
- **"The shaper cache, the IPC registry, titles, banners or `pushed_layouts`
  grow without bound."** The shaper cache is a fixed 256x8 table, and
  `IpcRegistry.forget` runs from `Surface.deinit` and `Window.deinit`. Each
  setter frees its previous string, and stale layout keys are removed on
  every sync.
- **"IPC requests leak their body, parse or response."** `serveOne` defers
  both frees, `dispatch` defers `parsed.deinit()`, and every handler has an
  arena with a deferred deinit.
- **"Config reload leaks the old config, brush or fonts."** It does not.
  The cost is redundancy (PA-M07).
- **"Process, thread, ConPTY or quit-pipe handles leak per pane."** Each is
  closed: `CommandCore.zig:415`, `Exec.zig:1234-1243`, `pty.zig:443-450`,
  and `Exec.zig:1538` and `:680`.
- **"Scrollback is unbounded on Windows."** It is enforced by page
  recycling (`PageList.zig:3158-3163`).

## Checked and found clean

Pane close (`win32/Surface.deinit` `:1347-1537`, core `Surface.deinit`
`:1420-1514`), termio (`Termio.deinit`, `Exec.ThreadData.deinit`,
`Subprocess.deinit`), renderer (`generic.deinit`, `OpenGL.threadExit`,
`gl_comp_present` `Presenter.deinit`), the refcounts (`PaneView.unref`,
`Surface.unref`), tab close (`Window.zig:4446-4523`, fixed-size per-tab
arrays), window close (`closeNow`, `cleanupAllSurfaces`,
`releaseOwnedResources`), close-undo (`finalize` drops everything),
`restore_claims`, `backdrop_pool` (6 buffers), the pane window pool (16),
mailbox capacities (fixed 64), and `syncSessionLayout` (arena).

**Not covered:** `ViewerPane.deinit` (T2963), `SessionRoster`,
`MachineConnectionPool`, the relay paths, `SplitTree` internals, and the
`FrameClock` per-HWND entries for parked panes.

## Filed as

- **PA-M01** -> T3001
- **PA-M02** -> T3002
- **PA-M03** -> T3003
- **PA-M04** -> T3004
- **PA-M05** -> T3005
- **PA-M06** -> T3006
- **PA-M07** -> T3007
- **PA-M08** -> T3008
- **PA-M09** -> T3009
- **PA-M10** -> T3010
- **PA-M11** -> T3011
- **PA-M12** -> T3012
- **Mac seat:** T3013 (validate PA-M04 and PA-M09 on macOS, shared core), T3014 (check the Swift `+read` for PA-M06)
- **PA-M03:** shared file, Windows-only cost; no Mac half is owed
