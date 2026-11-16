# Audit-3, area W: the win32 frontend (T3101)

- **Date:** 2026-11-15
- **Commit audited:** d0d874326 (audit-2 was 879fba35a)
- **Input:** audit-3, a re-audit of `../audit-2/W-findings.md` (PA-W01..PA-W17),
  with `../audit-1/W-findings.md` for each id's full description
- **Scope:** `src/apprt/win32/` without the renderer presenters and the viewer
  panes

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. Nothing
was built, run or measured this turn. Every verdict is from reading the code
at HEAD and the fix commits' diffs; every cost is either quoted from a task
file (and said to be) or computed/inferred from the code.

## What moved since audit-2

`git diff --stat 879fba35a HEAD -- src/apprt/win32/`: 24 files, +2187 / -194.
Thirteen commits touched the area:

| Commit | Task | PA | What it did in this area |
|---|---|---|---|
| 19581323a | T2975 | R-area | a background tab's panes are marked `window_hidden` so they give back render targets (`Window.zig` `showTabIndex`, `setTabSurfacesVisible`) |
| e4bfd30f5 | T3105 | none (reliability) | IPC pipe instances overlapped, every read/write bounded at 5 s, 4 -> 16 listeners; new `ipc_pipe_io.zig` |
| ae9b1adb2 | T3104 | R-area | `PaneView.hideReleasing` for panes behind a zoom or in the stash |
| 546a81b1c | T3107 | viewer (out of scope) | `ViewerPane.zig`, `viewer_process.zig`, `webview2*.zig` |
| 2fe99e84f | T2986 | **PA-W02** | size-burst canvas: new `size_burst.zig`, `noteSizeStep`/`settleSizeBurst`/`dropDeskCanvas` in `Window.zig` |
| 66a526f79 | T2987 | **PA-W03** | band painters gated on the clip, persistent `caption_buf`/`strip_buf`; `chrome_comp.reaches`, `Mirror.builds/valid` |
| f51045ceb | T2988 | **PA-W04** | `invalidateTuckedStripName` + new `strip_label_memo.zig` |
| ad3cfa61d | T2989 | **PA-W05** | `scripts/perf-baseline.ps1` only (per-thread wakeups, cycle census) |
| c23205794 | T2990 | **PA-W06** | Activity Monitor sampler on a `reusable_thread.Pool` |
| 40297c800 | T3001 | PA-M01 | pane snapshot buffer + DIB released after a glide, drag or hero mode (`Surface.zig`, `Window.zig`, `PaneView.zig`) |
| 5a7fa1191 | T3002 | PA-M02 | desk and overlay buffers fit the window again outside a drag (`PaneDesk.zig`, `chrome_comp.zig`) |
| eaf1693b8 | T3126 | none (feature) | blade state persisted; `noteStackPersistChange` after every layout pass |
| cf941c648 | T3135 | none (perf port) | `inheritedCwd` answers locally; new `inherit_cwd.zig` |
| 09241982e | T3138 | none (main merge) | `hero_math.zig`, `mac_layout_blob.zig`, `session_layout.zig`, skill text; no `Window.zig`/`App.zig` change |

Files the open findings cite that are **byte-identical** to audit-2's
(`git diff --stat` empty): `PaneSidebar.zig`, `KeyStateIndicator.zig`,
`ReadonlyBadge.zig`, `BannerOverlay.zig`, `pane_grab_handle.zig`,
`PaneGrabHandle.zig`, `system_colors.zig`, `occlusion.zig`, `pane_pool.zig`,
`sheet_workers.zig`, `src/os/thread_stack.zig`, `src/os/reusable_thread.zig`.
`Window.zig` grew by about 170-190 lines above the painters, `App.zig` by 24,
`Surface.zig` by 3 above `init`; every line number below is re-read at HEAD.

## Verdicts

Confidence is **high** (cited lines read at HEAD, mechanism traced) unless a
row says otherwise.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-W01 | fixed (incomplete), unchanged since audit-2 | `src/os/thread_stack.zig:33-36`; `src/os/reusable_thread.zig:60`, `:116`; still default: `sheet_workers.zig:46` and 29 short-lived `.{}` spawns (e.g. `App.zig:10783`, `:11623`, `:12785`) | 90e57ab70 as audit-2 found it. No new long-lived default-stack thread was added: `IpcServer.zig:253` (now 16 listeners) and the new sampler pool both use `thread_stack.config`. The two new `.{}` spawns (`ipc_pipe_io.zig:266`, `:280`) are in test blocks | T2985 stays closed. Remainder is T3075 (todo, P2) and T3095/PA-W17 (todo, P1) |
| PA-W02 | **fixed** (2fe99e84f) | `size_burst.zig:56-74`; `Window.zig:20466-20522` (`dropDeskCanvas`, `noteSizeStep`, `settleSizeBurst`), call `:22673`, timer `:22537`, hand-off to the edge drag `:22739-22741`; `PaneDesk.zig:1175-1177`, `:1202-1207` | The second `WM_SIZE` within 200 ms outside the modal loop arms the T2577 canvas; a 150 ms quiet timer drops it and invalidates the desk only if the canvas differs from the area. A lone maximize/restore arms nothing. See "Fix-commit review" for what was checked | T2986 closed correctly. Its CPU criterion is unproven (debug 28.3% vs 32.2%, inside tolerance); T3116 (todo) owns the release measurement |
| PA-W03 | **fixed (incomplete)** (66a526f79) | gate `Window.zig:19159-19164`, `chromeBandReach` `:19204-19236`; buffers `chrome_comp.zig:263-298`, used at `Window.zig:18800+` / `:19416+`; still over-wide: `invalidateTabBar` `:18435-18444`, `invalidateCaption` `:18455-18461` | Pane-area and divider paints now skip both painters, and neither painter creates a DC/DIB per paint. What remains: (a) in merged chrome both invalidation rects span `right = 10000` on the same row, so each reaches the other painter (PA-W18 below); (b) per-title `GetTextExtentPoint32W` every strip paint, T3117 (todo); (c) a region and a brush per tab per strip paint (`:19665`, `:19686`), which is PA-W14's family; (d) the buffers are exact-size, so every step of a width resize rebuilds both (as before the fix, no worse) | T2987 closed; T3117 open; file PA-W18 |
| PA-W04 | **fixed** (f51045ceb) | `Window.zig:18296-18297` (`onPaneTitleChanged`), `invalidateTuckedStripName` `:14358-14373`, memo recorded at `:14119` (`paintStripLabel`) and `:14233` (`stripLabelPic`); `strip_label_memo.zig:34-57` | A hidden pane's title change invalidates only its strip's tab rect, and nothing when the memo says the strip already shows that label or the pane is stashed / in a hero or zoomed tab. On the elevated style the names are laid over the desk bitmap per paint (`PaneDesk.zig:1601-1654`), so the strip repaint does not recompose the desk. With PA-W03's gate the resulting paint runs neither band painter | T2988 closed. Its CPU criterion is not demonstrated (inside noise on the debug test desktop); T3118 (todo) owns it |
| PA-W05 | **fixed** (ad3cfa61d) | `scripts/perf-baseline.ps1:563-641` (`Get-ThreadCtx`, `Get-ThreadIdentity`, `Get-WakeupAttribution`), `:846`; census `:645-712`, `:1080-1085` | Idle phase reports top-10 threads and per-group wakeups; cycle phase reports handle-type, window-class and thread-group deltas plus non-window USER objects. Tooling only | T2989 closed. Leads it produced: T3119, T3120 (both todo) |
| PA-W06 | **fixed** (c23205794) | `activity_sample.zig:157` (`reusable_thread.spawnPane(&sample_pool, ...)`), pool `:167`, join `:145-148`; `ActivityMonitor.zig:963-965` (close joins), field `:540` | One parked thread serves every sample; `join` waits for the job and frees it; the pool's spawn config is the 64 KB commit (`reusable_thread.zig:60`). Task file: 1 thread over 69 samples | T2990 closed. T3122 (todo, P2) owns the per-connect workers (`activity_probe_conn.zig:415`, `activity_dial.zig:189`, `activity_machines.zig:219`) |
| PA-W07 | still open | `App.zig:1065` (set once), `:13860-13863`, `pollVisibility` `:1467-1475`; `occlusion.zig:115-156`; `Window.zig:4788-4797` | `VISIBILITY_TIMER_ID` appears only at `App.zig:342`, `:1065`, `:13860`; never killed. T2989 measured the UI thread at ~10 wakeups/s idle, of which this timer is 4 | T2991 unchanged; update its line refs |
| PA-W08 | still open | `pane_grab_handle.zig:209-214`; `PaneGrabHandle.zig:226`, `:154` | file unchanged; `keepPolling` returns true first thing when `shown` | T2992 unchanged |
| PA-W09 | still open | `Window.zig:1619-1621`, `chromePalette` `:1635-1641`, callers `:14451`, `:15284`, `:18825`, `:18947`, `:19451`; `system_colors.zig:146-153`, `:423-432` | `usesLightTheme` opens, queries and closes the key per call; no cache. PA-W03's gate lowers how often the caption/strip callers (`:18825`, `:19451`) run, not the per-call cost | T2993 unchanged; update line refs |
| PA-W10 | still open | `Window.zig:11650-11682`: `buildWith(gpa, ...)` `:11671`, `defer built.deinit(gpa)` `:11672`; also an arena per call in `noteStackRows` `:11690-11695` (called at `:11659`) | unchanged shape; 24 call sites of `stackGrid()`/`stackGridOfTab(` in the file | T2994 unchanged; update line refs |
| PA-W11 | still open | `PaneSidebar.zig:5388-5392`, `:1031-1034` | file unchanged | T2995 unchanged |
| PA-W12 | still open | `Window.zig:13934-13948` (two brushes, two `stripFont` fonts per `paintStripBandsAndNames`); also `:10196`, `:10501`, `:10688`; `stripFont` `:14084-14103`; cached pair `:14326-14331` | unchanged shape | T2996 unchanged; update line refs |
| PA-W13 | still open | `KeyStateIndicator.zig:567-571`, `:310-319`, `:676-690`; `ReadonlyBadge.zig:175`, `:194-203`, `:208` | files unchanged | T2997 unchanged |
| PA-W14 | still open | `Window.zig:19351-19353` (`fillEllipse`: brush + pen), `:19399-19401` (strip button: region + brush), `:19665`, `:19686` (per tab); `PaneSidebar.zig:2350`, `:2358`, `:2370-2372`; `BannerOverlay.zig:1657`, `:1706-1707`, `:2210` | per-call create/delete. `brush_cache` is still imported only by the dialogs, `ActivityMonitor`, `App`, `Surface` and `whats_new_notes` (12 files), none of them these painters. The two `Window.zig` sites now run only when the paint reaches their band | T2998 unchanged; update line refs |
| PA-W15 | still open | `Surface.zig:907`, `:910` (two `CreateEventW`), first errdefer `:958`; `Window.zig:3951-3952` (no destroy on a failed init) vs the guarded sibling `:4366-4367` | unchanged shape | T2999 unchanged; update line refs |
| PA-W16 | still open | `Surface.zig:1534-1537`, `parkWindow` `:1544-1562`, helper path `:1006-1007`; `pane_pool.zig:64-66` | `parkWindow` still refuses only presenter panes, `own_layer`, a closing window or a wrong parent. T2989's census now measures it: the first cycle leaves 9 parked pane windows, and each parked renderer thread keeps an `NVOpenGLPbuffer` and an `IME` window (+18 windows) - quoted from T2989, not re-measured | T3000 unchanged (T2989 added a note to it) |
| PA-W17 | still open | `sheet_workers.zig:44-46`; reached from `PaneDesk.zig:2115-2117` | file unchanged: `pool.init(.{ .allocator = ..., .n_jobs = want })` with no `stack_size` | T3095 (todo, P1) |

No item is **wrong**. No item is **changed** in shape.

## Changed items

None. Three open items have better evidence than they had, all from T2989's
new baseline output (quoted from the task file, Debug build, NVIDIA box):

- **PA-W07.** The UI thread wakes ~10 times a second at idle, not the ~6
  audit-1 computed from the timers it found. Four of the ten are this poll.
  The other ~4 unexplained UI-thread wakeups are not attributed by any code
  I read; T3119 covers the driver threads, not these.
- **PA-W16.** Nine parked pane windows after the first cycle, as predicted.
- **PA-W05's old "unexplained" figures** are now explained: 87% of idle
  wakeups are NVIDIA driver threads; the per-cycle residue is Event +4,
  IoCompletion +3, USER +3 (T3120).

## Fix-commit review

### 2fe99e84f (T2986, PA-W02): no regression found

Read `size_burst.zig` whole and the three `Window.zig` functions.

- Per `WM_SIZE` the new cost is one `GetClientRect`, one `GetTickCount64`
  and, inside a burst, one `SetTimer`. Nothing allocates.
- A burst cannot leave the canvas up: every `.arm`/`.extend` re-arms the
  timer, and a failed `SetTimer` settles at once (`Window.zig:20491-20495`).
  `WM_ENTERSIZEMOVE` kills the timer and settles before taking the canvas
  (`:22739-22741`); a timer that fires inside a size loop returns without
  dropping the loop's canvas (`:20502`).
- A same-size `WM_SIZE` returns `.none` before touching the clock, so a move
  or a repeated size does not extend a burst.
- Minimize then restore inside 200 ms would arm (client 0x0 then the old
  size), but the canvas starts at the cached desk's size, so the settle finds
  it equal to the area and invalidates nothing.
- Interaction with T3002: `comp_backing.tight` and the buffer fit are off
  while `live != null` (`PaneDesk.zig:2553`, `:2576`), so a burst
  does not free and re-map per step; the settle paint does the one fit.
- By design the first step of every burst and any stepper slower than one
  step per 200 ms still take a new desk each step.

### 66a526f79 (T2987, PA-W03): correct, but its merged-chrome claim does not hold (PA-W18)

- The skip is sound. Painting to the window, a skipped painter's band is
  outside the clip. Painting to the caption mirror, a skip is allowed only
  while `caption_mirror.valid` (`Window.zig:19160`), and a rebuilt mirror
  starts `valid = false` (`chrome_comp.zig:263-309`, `deinit` keeps only
  `builds`). On a translucent window the buffer DC keeps the paint's clip box
  through the viewport offset (`Window.zig:1854-1908`), and an unpainted
  pixel resolves to "leave alone".
- `chromeBandReach` adds two `GetClientRect`s, one `GetClipBox` and two
  `caption_layout.layout` calls per paint; all arithmetic.
- New steady memory: two band-sized DIBs per window (`client_w x cap_h x 4`
  each, ~0.2 MB at 1400 px, ~0.6 MB at 3840 px). Bounded; freed in
  `releaseOwnedResources` (`Window.zig:2577-2578`).
- After any `WM_PRINTCLIENT` or direct-to-window paint the mirror is marked
  invalid, so the next mirror paint runs both painters once. Bounded.
- **The hole:** the commit comment at `Window.zig:19200-19203` says a hover
  on the caption cluster no longer re-lays out the tab run. It still does.
  See PA-W18.

### f51045ceb (T2988, PA-W04): no regression found

- Per title tick of a hidden pane: `paneStripLabel` into a stack buffer, one
  Wyhash, a 32-entry scan, and on a real change `tuckedStrips` plus one
  `InvalidateRect`. Per strip paint: one hash and one scan.
- The memo is recorded by the paint, so a pending invalidation is never
  mistaken for "already showing". Entries for closed panes are never removed
  but the table is 32 fixed slots with round-robin eviction; the worst case
  is one extra strip repaint.

### ad3cfa61d (T2989, PA-W05): script only

No product code. The new snapshots run at phase boundaries, not inside the
timed idle window except for the two `Get-ThreadCtx` reads that bracket it.

### c23205794 (T2990, PA-W06): no regression found

- Each sample now allocates one job closure from `page_allocator`
  (`reusable_thread.zig:93`) and frees it at `join`: one page-granular
  allocation every 1.5 s while the panel is open. Negligible, and the same
  as every pooled pane thread.
- `sample_pool` keeps at most 4 parked threads (64 KB commit each) for the
  life of the process once a panel has been opened.

### e4bfd30f5 (T3105): no hot-path cost; 12 more idle threads

- Listeners go from 4 to 16 (`IpcServer.zig:57`, spawn `:253` with
  `thread_stack.config`). They block in an overlapped `ConnectNamedPipe`
  with an infinite wait (`ipc_pipe_io.zig:79-103`), so they add no wakeups.
  Cost (computed): 12 x 64 KB stack commit plus the one-time ~64 KB per
  thread the NVIDIA driver strands (T2644), about 1.5 MB, and 12 more threads
  in every thread count the baseline reports from here on.
- Each request now creates and closes one event per bounded read/write and
  one for the accept. Per CLI command, not per frame.
- After answering, the listener waits (up to 5 s) for the client to close
  before disconnecting (`ipc_pipe_io.zig:116-134`). The client already has
  its answer, so this costs instance availability, not latency; with 16
  instances that is not a practical limit.

### 19581323a (T2975) and ae9b1adb2 (T3104): nothing new on the frontend side

`setWindowHidden(true)` is an atomic store and `Surface.setVisible` forwards
only on a change (`Surface.zig:1846-1865`), so calling `hideReleasing` on
every hidden pane in every layout pass is free. The cost these two commits
move is on the renderer side (targets re-created and a full redraw on every
tab switch, unzoom and restore from stash); that belongs to area R and was
not traced here.

### 40297c800 (T3001, PA-M01): one new per-capture allocation in hero mode (PA-W19)

`heroSnapPublish` now frees the renderer's landing buffer after every
publish (`Surface.zig:2853`). In hero mode the next request, 150 ms later,
allocates it again (`:2666-2673`). See PA-W19. The release paths themselves
(`releaseIdleSnapshots`, `releaseSnapshot`) run once at the end of a glide,
drag or hero mode and are fine.

### 5a7fa1191 (T3002, PA-M02): bounded costs only

- `fitList` (`PaneDesk.zig:328-340`) and `Overlay.fit` (`chrome_comp.zig:403`)
  copy the kept prefix into the fresh allocation although every caller
  rewrites the whole buffer next (`ensureDesk`, `ensureQuarter`, the
  overlay's `@memset`). That is one wasted copy of the new size per shrink
  of more than half, i.e. per restore from maximized. Not worth a task.
- Outside a drag or burst, every new-size desk now frees `scratch` and
  `scratch_desk` when they hold 256 KB or more (`ensureDesk`, `PaneDesk.zig:2576`), and the next
  compose grows them back from the page allocator. That adds page faults to
  a step that already costs ~4 ms, and PA-W02's fix keeps such steps to the
  first and last of a burst.
- `glowLayer` and `ensureQuarter` call `fitList` unconditionally. When focus
  moves from a large pane to one under half its area and back, the glow
  buffer is released and re-grown (a few MB of fresh pages per focus change).
  Deliberate memory-for-time trade; inferred, not measured.

### eaf1693b8 (T3126), cf941c648 (T3135), 09241982e (T3138)

- T3126 adds `noteStackPersistChange` to every `layoutSplits` pass
  (`Window.zig:8932`). `collapseStamp`
  (`pane_stack_state.zig:549-562`) hashes only pinned rows; it marks the
  layout dirty only when the stamp moves, and that save is debounced.
- T3135 removes a blocking agent round trip from the GUI thread for local
  session-persistence panes (task file: 264 us -> 2 us, up to 1.5 s against
  a busy agent). It adds one `log.info` per tab/split.
- T3138 touches no paint, timer or thread code in this area.

## New findings

| PA | P | Where | Cost | Fix |
|---|---|---|---|---|
| PA-W18 | P2 | `Window.zig:18435-18444`, `:18455-18461`; gate `:19159-19163`, `:19204-19236` | inferred: one unneeded band painter per chrome invalidation in merged chrome (every tab hover change, every caption-button hover change, every tab-label change, ~10 Hz under a spinner title in the active pane) | clamp the two invalidation rects at the seam when merged |
| PA-W19 | P2 | `Surface.zig:2853` (free), `:2666-2673` (re-alloc); driver `Window.zig:8067-8105`, `hero_snap_schedule.zig:58-63` | computed rate, inferred cost: one `thumb_w x thumb_h x 4` allocation and free per terminal pane per 150 ms while a hero tab is quiet (about 6.7 a second per pane, ~0.3 MB each at a 350 x 220 thumbnail) | free the landing buffer only when no hero tab reads it |

### PA-W18: in merged chrome a caption or strip invalidation still runs both band painters (P2)

- **Where:** `invalidateTabBar` (`Window.zig:18435-18444`) invalidates
  `left = 0, right = 10000` of the strip row. `invalidateCaption`
  (`:18455-18461`) invalidates `left = 0, right = 10000` of the caption row.
  In merged chrome (`mergedChrome`, `:2684-2686`: any custom-caption window
  showing a tab strip, i.e. two or more tabs) the two rows are the same row.
  `chromeBandReach` (`:19204-19236`) splits that row at `band_left`: caption
  `[band_left, client_w)`, strip `[0, band_left)`. A rect spanning the whole
  row reaches both, so `paintChromeRaw` (`:19161-19162`) runs both painters.
- **Who pays:** `handleNcMouseMove`/`handleNcMouseLeave` call
  `invalidateCaption` on every caption-button hover change (`:18589`,
  `:18607`), which re-lays out and re-composites every tab; the strip hover
  path calls `invalidateTabBar` (`:20902`), which rebuilds the caption; and
  `onPaneTitleChanged` -> `invalidateTabLabel` -> `invalidateTabBar`
  (`:18313`, `:18337-18343`) does the same on every title change of a tab's
  focused pane. `invalidateTabBar()` has 20 call sites.
- **Cost:** inferred, not measured. One full painter that changes no pixel:
  a `client_w x cap_h` fill plus buttons for the caption, or every tab's
  per-pixel shape, text measurement, region and brush for the strip. T2987's
  own summary named this case ("invalidateTabBar, right = 10000, which also
  repaints the caption"); the gate was added but the rects were not narrowed.
  The comment at `:19200-19203` claims the saving.
- **Fix:** when `mergedChrome()`, give `invalidateTabBar` `right =
  band_left` and `invalidateCaption` `left = band_left`. Callers that change
  the seam itself (the remote pill's width, `captionPill`) must invalidate
  both; the doc comment at `:2955-2960` says that path
  already repaints "the chrome and not just the caption". The existing
  `chrome-paint-clip.ps1` probe (`chrome-painter name= n=`) can assert it.
- **Risk:** low; a missed seam mover shows as a stale band, which the
  chrome pixel scripts cover.
- **Confidence:** high on the mechanism (both rects, the gate and three
  callers read). Not checked: whether any of the 20 `invalidateTabBar`
  callers rely on the caption repainting as a side effect.

### PA-W19: a hero tab re-allocates every terminal thumbnail's landing buffer on every capture (P2)

- **Where:** T3001 added `if (!self.snap_requested.load(.acquire))
  self.freeSnapBufferLocked();` at the end of `heroSnapPublish`
  (`Surface.zig:2853`). `snapRequest` allocates whenever
  `snap_buffer.len != len` (`:2666-2673`), which after that free is every
  time. `Window.heroSnapTick` (`Window.zig:8067-8105`) offers every leaf of
  the hero tab a capture each 150 ms heartbeat, and a terminal takes one
  every 150 ms while the window is quiet (`hero_snap_schedule.zig:58-63`,
  `Surface.zig:2689-2700`).
- **Cost:** the rate is computed from the code: one allocation and one free
  of `thumb_w x thumb_h x 4` bytes per terminal pane per 150 ms, for as long
  as a hero tab is on show and idle. Before 40297c800 the buffer was
  allocated once per thumbnail size (the field comment at `Surface.zig:635`
  still says the GUI thread "pre-sizes" it). The time per pair depends on
  the app allocator's large-allocation path, which I did not trace; if it
  maps fresh pages each time, the renderer's readback also takes the page
  faults. Small in absolute terms (inferred: well under 1% of a core for ten
  panes), which is why this is P2.
- **Fix:** in `heroSnapPublish`, keep the buffer when the pane's tab is in
  hero mode (the carousel will ask again in 150 ms) and free it only for
  one-shot captures (glide, drag ghost). `releaseIdleSnapshots` already
  frees everything when hero mode ends (`Window.zig:8068`, `:8838`).
- **Risk:** low. T3001's memory criterion is about pane-sized glide and
  ghost snapshots; a thumbnail-sized buffer per hero tile is ~0.3 MB.
- **Confidence:** high on the alloc/free per capture (both sites and the
  scheduler read); medium on the cost.
- **Overlap:** T3001 is PA-M01, so area M's audit may report the same line.

No other new finding survived. Candidates read and dropped: the per-request
event creation in `ipc_pipe_io`, the sampler's job closure, `collapseStamp`
per layout pass, the strip memo's hashing, and `chromeBandReach` per paint
are all too small to file.

## Summary

- **Fixed:** 4 (PA-W02, PA-W04, PA-W05, PA-W06)
- **Fixed (incomplete):** 2 (PA-W01, unchanged since audit-2: remainder in
  T3075 and T3095; PA-W03: remainder in T3117 and new PA-W18)
- **Still open:** 11 (PA-W07 to PA-W17)
- **Changed:** 0
- **Wrong:** 0
- **New:** 2 (PA-W18 P2, PA-W19 P2)

Open P0/P1 in area W:

- **PA-W17 / T3095 (P1):** the sheet worker pool's 16 MB default stacks,
  `sheet_workers.zig:46`. The only P1 left; a one-field fix.

No open P0. Everything else open is P2: PA-W07 to PA-W16 (T2991-T3000),
PA-W18, PA-W19, and the follow-ups the fixes filed (T3075, T3116, T3117,
T3118, T3119, T3120, T3122).

Unproven by measurement, per their own task files: the CPU drop of PA-W02
(T3116) and of PA-W04 (T3118). Both fixes do strictly less work per step by
reading the code; neither has a number beyond noise yet.

## Not done

- No build, test or measurement.
- The renderer-side cost of T2975/T3104's release-and-redraw on tab switch,
  unzoom and unstash was not traced (area R).
- The viewer-pane changes (T3107) were not read (out of scope).
- Per-message allocation in the input and mouse paths was not re-read; none
  of the thirteen commits touched it.
