# Audit-5, area R: renderer and GPU (T3316)

- **Date:** 2026-11-28
- **Commit audited:** 5eaac0760a (audit-4 was c9af15802)
- **Input:** audit-5, a re-audit of `../audit-4/R-findings.md` (PA-R01..PA-R25),
  with `../audit-1/R-findings.md` .. `../audit-3/R-findings.md` for the
  original descriptions

**Produced by Fable 5.2** (`claude-fable-5-2`), one read-only auditor.

**Method.** Every verdict comes from reading the cited code at HEAD and the
source diff of every commit that touched the area since audit-4. Nothing was
built, run or measured. A cost is marked *quoted* (from a task or commit
message), *computed* (from the code) or *inferred* (mechanism read, size not
known). Confidence per row: **high** = cited lines read at HEAD and the
mechanism traced; **medium** = lines read, but a runtime fact (driver, DWM,
thread timing) decides the size. Old cites were carried to HEAD by mapping
each line through `git diff -U0 c9af15802 HEAD` and reading the line it
landed on.

## What moved since audit-4

`git diff --stat c9af15802 HEAD` over the area (16 files, +2640 -209):

| File | Change |
|---|---|
| `src/renderer/pace.zig` | new, +127: `Pace` full/background/glimpse and the caps (T3761) |
| `src/renderer/Thread.zig` | +40: `pace` field (`:152`), `.pace` message (`:548`), `paceDelayMs` replaces `lowPowerDelayMs` (`:920-929`), `reset_cursor_blink` no longer forces a frame (`:456`) |
| `src/renderer/message.zig` | +5: the `.pace` message |
| `src/renderer/gl_comp_present.zig` | +194: `DeviceCache` is a pool of up to 8 devices (`:417-484`, T3746); the interop open moved to the top of `Presenter.init` (`:712-730`); stranded-pane retry table (`:1221`, T3739); `HRESULT = i32` |
| `src/renderer/OpenGL.zig` | +110: composition retry (`:1492-1502`, `:1596-1609`, T3739); window-presenter reclaim (`:1737-1783`, `:1862`, T2622); GTK release hooks (`:1624-1656`, compile-time off on win32) |
| `src/renderer/gl_window_presenter.zig` | +52: `SlotPair.reclaim` (T2622) |
| `src/renderer/generic.zig` | +60: `releaseFrameResources` split into `releaseQueuedFrames` / `releaseFramesNow` for GTK (T3645); the glass-pane test is a named constant. Win32 behavior unchanged; every line below `:830` moved by 13, below `:1500` by 54 |
| `src/renderer/comp_overlay.zig` | +49: `coverMatrix` / `setCoverLift` (T2618) |
| `src/renderer/gl_loader.zig` | +73: log-buffer fix (T1767), not a hot path |
| `src/apprt/win32/Surface.zig` | +878: `setPace` (`:2082-2089`), pixel-format rule for a reused window (`:1095-1114`, T3739), `adoptPaneDrawable` failure handling (`:1844-1873`), debug-only frame-pacing probe (T1737), dim/badge ordering (T2335, T2618), strip fill for a plain child (T2630). The rest is shell and folder work (area C/W) |
| `src/apprt/win32/Window.zig` | +967: `applyView` / `syncPace` (`:5153-5177`), `inUseChanged` calls `syncPace` (`:10627`). The occlusion, tab-switch, park and hero code is unchanged; line numbers moved by 182 to 796 |
| `src/apprt/win32/pane_pool.zig` | +44: `contextHome` (`:86-107`, T3739) |
| `src/apprt/win32/chrome_comp.zig` | +102: busy-light layer on the chrome host (`:1625-1691`, T2626), opt-in |
| `src/apprt/win32/WindowPresenter.zig` | +46: `PaneLink.composed` (`:317`, T2622), opt-in |
| `src/apprt/win32/PaneView.zig`, `resize_paint.zig` | viewer opening frame (T2635), `fillsUncoveredStrips` (T2630) |

`cell.zig`, `image.zig`, `link.zig`, `cursor.zig`, `storage_trim.zig`,
`wake_coalesce.zig`, `State.zig`, `low_power.zig`, `opengl/*`, `font/*`,
`child_comp.zig`, `viewer_toc_comp.zig`, `hero_snap_schedule.zig` and
`termio/Termio.zig` did not change (empty diff), so their line numbers are
audit-4's.

Commits and tasks:

| Commit | Task | What |
|---|---|---|
| 7ce6815435 | T3761 | panes outside the window in use draw at a cap: 20 fps, or 4 fps when under a quarter of the window shows |
| 459de62840 | T3746 | the shared D3D11 device is a pool; a pane whose interop open is refused takes the next device |
| d6732bc4da | T3739 | a reused window's context home follows the pixel format it carries; a stranded pane retries the composition path |
| 79307bd67b | T2622 | window presenter: a pane it is not composing redraws its untaken slot instead of waiting 2 x 20 ms |
| 0c0697d9bb | T1737 | frame-pacing probe, debug builds only |
| 64bc8789b5, 0d17f51499 | T2618, T2335 | the unfocused dim is drawn inside the pane and ordered over its chrome |
| 3bc0718992 | T2626 | the busy-light ring on the chrome host |
| ddd2bd49c2 | T2630 | strip fill for a pane without its own layer |
| ff16f1f3aa, f80c050bdc, b46c478b97.. | T3330, T3331, T3645 | Linux/GTK build and release path through shared `generic.zig` and `OpenGL.zig` |

No task named in audit-4's "Task action" column closed. T2969, T2977-T2983,
T3090, T3091, T3092, T3096, T3098, T3110, T3141, T3142, T3144, T3298, T3299
and T3300 are all `todo` with no commits. One of them, T2983 (PA-R17), was
fixed in passing by T3739 and can be closed.

## Verdicts

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| R01 | **fixed** (high) | `renderer/generic.zig:89-94`, call at `:1688` | 8d2be0f7b. Unchanged apart from line numbers. | T2967 stays closed. |
| R02 | **fixed** (high); the one device is now a pool | `renderer/gl_comp_present.zig:417-484` (`DeviceCache`), `:502-509` (`processDevice`); `apprt/win32/chrome_comp.zig:1015-1023`; `child_comp.zig:212-220`; `viewer_toc_comp.zig:135`; per-pane DComp device `gl_comp_present.zig:835-837` | 29302f08c, 1cde0416f, e15858510 as before. 459de62840 (T3746) keeps the sharing and adds devices only when a driver refuses one more interop open (*quoted*: the 16th on NVIDIA), so up to 15 panes still share one device. See PA-R28 for what the pool adds. | T2968, T3074 stay closed. |
| R03 | **still open** (high) | `renderer/OpenGL.zig:495-501`, `opengl/shaders.zig:116-119`, `generic.zig:512-525`, `:593-614` | Unchanged. No share group; per-pane programs and atlas copies. | T2969 unchanged (todo, P2). |
| R04 | **fixed** (high) | `renderer/cursor.zig:77-87`, `generic.zig:1981-1990`, `Thread.zig:889`, `:1097` | 2cdc77abe. Unchanged. 7ce6815435 adds to it: the output-driven `reset_cursor_blink` no longer forces a frame (`Thread.zig:456`). | T2970 stays closed. |
| R05 | **fixed** (high) | `renderer/link.zig:63-75`, `:96`; `generic.zig:1877` | 5672c7165. Unchanged. | T2971 stays closed. |
| R06 | **fixed** for uploads (high) | `renderer/opengl/buffer.zig:83-100`, `:124-128`, `:159-166` | 60ae989a0. Unchanged. Grow-only half is PA-R19. | T2972 stays closed. |
| R07 | **fixed** for steady state; the idle caveat is PA-R20 (high) | `generic.zig:2357-2375`, `:4252-4282`, `:593-614` | 396aac1db. Unchanged. | T2973 stays closed. |
| R08 | **fixed** (high) | `renderer/OpenGL.zig:1324-1327`, `:1371-1397`; `gl_comp_present.zig:1061-1069`; `Thread.zig:641`, `:649-669`; `generic.zig:2306-2333` | 6711c4e45. Unchanged. | T2974 stays closed. |
| R09 | **fixed (incomplete)**, remainder tracked (high) | `apprt/win32/Window.zig:5240-5249` (tab switch), `:4838-4848` (`setTabSurfacesVisible`), `:7886-7894` (`parkPaneHidden`), `:7902-7905`, `:9616`; `PaneView.zig:300-309`; `OpenGL.zig:1624-1629`, `:1696-1708`; `generic.zig:1491-1600` | 19581323a and c513c69cc as audit-4 read them. The release body moved into `releaseFramesNow` (`generic.zig:1540-1600`) with no change on win32. Not freed, as before: the composition swap chain and the window-presenter slot textures. | T2975 stays closed. T3091, T3092 unchanged (todo, P2). |
| R10 | **changed** (audit-3's verdict stands): closed as not ours (medium) | no renderer source; `docs/design/windows-parity-tasks/T2976.md` | Nothing new. T3110 is still `todo`. | T3110 unchanged. |
| R11 | **still open** (high) | `generic.zig:2040`, `:3492`, `:2224-2245`; `Thread.zig:931-959`; `OpenGL.zig:1711-1719`; `gl_comp_present.zig:1130-1143` | Unchanged. One source of unchanged forced frames was removed (the blink reset, above) and one was added (PA-R26). | T2977 unchanged (todo, P2). |
| R12 | **still open** (high) | `renderer/cell.zig:118-122` | Unchanged. | T2978 unchanged. |
| R13 | **still open** (high) | `generic.zig:2684`, `:2644`, `:2692`; `image.zig:906` | Unchanged apart from line numbers. | T2979: re-cite lines. |
| R14 | **still open** (high) | `renderer/opengl/Pipeline.zig:51-57` vs `:73-75` | Unchanged. | T2980 unchanged. |
| R15 | **still open** (high) | `apprt/win32/Surface.zig:1966-1967`; helper `:1819-1835`; fallback `:1841-1873` | Unchanged apart from line numbers. Since T3739 a reused window that already carries the format keeps its pane's context on the window (`:1095-1097`), so such a pane holds the depth and stencil buffers from the start rather than only after a fallback. | T2981: re-cite lines. |
| R16 | **still open** (high for the mechanism, medium for the size) | `apprt/win32/Window.zig:24221-24222` (`WM_SIZE`), `:5205-5211` (`refreshOcclusion`), `:5133-5140` (`setActiveTabVisible`), `:8902-8909` (`heroSnapTick`), `:9108`, `:9700`, `:14376` (`hideReleasing`), `:8033` (`adoptWindow`) | Unchanged apart from line numbers: `refreshOcclusion` still ends in `setActiveTabVisible(true)` when the window is neither hidden nor was occluded. | T2982 unchanged (todo, P2); re-cite lines. |
| R17 | **fixed** (high) | `apprt/win32/Surface.zig:1095-1097`, `:1111-1114`; `pane_pool.zig:86-107` | d6732bc4da (T3739). The skip was `reused == null`; it is now `home.set_format`, which is true whenever the reused window's DC reports no pixel format (`windowPixelFormat`, `Surface.zig:1892-1896`). A window parked by a helper-path pane therefore gets `SetPixelFormat` before a non-helper pane's context is made on it. T3739 hit this exact hazard on a user's box (a blank pane). | **Close T2983**, citing d6732bc4da. |
| R18 | **still open** in audit-3's reduced form (high) | `OpenGL.zig:1327`; `generic.zig:2239-2245`, `:2310`; `storage_trim.zig:114-119`, `:27`; `generic.zig:1432-1449` | Unchanged. | T3096 unchanged (todo, P2). |
| R19 | **still open** (high) | `renderer/opengl/buffer.zig:114-121`, `:144-151`, `:83-90` | Unchanged. | T3098 unchanged. |
| R20 | **still open**, and reached more often (high for the mechanism, medium for the size) | `generic.zig:1419`, `:1571-1587`, `:2228`, `:2250-2256`, `:2314-2333`, `:2357-2375`, `:4258-4264`; `OpenGL.zig:1703`; `gl_comp_present.zig:1062-1069`, `:959-1008` | Unchanged code, still not timed. New trigger: PA-R26 makes every window activation and deactivation a "first frame after a pause" for every idle pane of the active tab. | T3141 (todo, P2): add PA-R26 as a caller. |
| R21 | **still open** (high) | `OpenGL.zig:1358-1365`; `opengl/Target.zig:34-37`; `generic.zig:1583`, `:535` | Unchanged: `capacityFor(1, true)` is 256. | T3142 (todo, P2). |
| R22 | **still open** (high) | `apprt/win32/Surface.zig:3170` (free in `heroSnapPublish`), `:2982-2990` (`snapRequest` allocates), `:3059` (`heroSnapCommit` clears the flag first); `hero_snap_schedule.zig:60` | Unchanged apart from line numbers. | T3144 (todo, P2); re-cite lines. |
| R23 | **still open**, one more case (high for the mechanism, medium for the size) | `renderer/Thread.zig:761` (flag cleared on every wakeup), `:871-874` (hidden returns), `:777-783` (a capped pane arms a timer and returns); `wake_coalesce.zig:41-52`; `termio/Termio.zig:1114`, `:1124-1126`, `:1145`, `:1188` | Unchanged mechanism. 7ce6815435 puts every pane of a background window in the "wakeup does no work" class: while its cap timer is pending, each output batch still clears the flag and wakes the thread to find the timer armed. *Quoted* from T3761: 50 busy cascaded windows cost 137% of a core after the cap, about 2.7% each; part of that is these wakeups (*inferred*, not split out). | T3298 (todo, P2): add "and a pane held by a pace cap (T3761)" to the scope; the fix is the same (clear the flag when the held frame is built). |
| R24 | **still open** (high) | `renderer/Thread.zig:752-755` (error return) above `:761` (`consume`) | Unchanged. | T3299 (todo, P3); re-cite lines. |
| R25 | **still open** (medium) | `gl_comp_present.zig:409-416` (the rule), `:1130-1143` (pane copy and present); `chrome_comp.zig:1015-1023`, `:1190-1204`; `child_comp.zig:212-226` | Two changes in size, neither in mechanism. Smaller: the hosts take pool device 0 only (`processDevice` -> `acquire`, `gl_comp_present.zig:434-436`), so panes on a later pooled device no longer share their lock. Larger: the opt-in chrome host has a new periodic drawer, the busy-light layer (`chrome_comp.zig:1634-1683`, driven from `Window.zig:16070-16095`), which uploads on the shared device while a light is lit. | T3300 (todo, P3): add the busy-light layer to the "time this before making the chrome host the default" list. |

## Changed items

### PA-R02: one shared device became a pool of at most eight

- `DeviceCache.acquire` is `acquireAt(0)` (`gl_comp_present.zig:434-436`).
  `Presenter.init` opens the GL interop on the device first (`:712-713`) and,
  when the driver refuses, releases its references and asks for the next
  slot (`:714-723`, `nextPoolIndex` `:489-493`).
- References balance on the retry: the refused device and context are
  released before the next `acquireAt` (`:717-718`); the `errdefer`s for
  `dev`, `ctx` and the interop handle are registered after the loop
  (`:724-730`), so a later failure frees exactly one of each.
- A removed pooled device is rebuilt in its own slot (`:445-454`), as slot 0
  was.

### PA-R17: fixed by a correctness task, not by its own

See the table row. The fix is wider than audit-1 asked for: it also keeps a
format-carrying reused window off the helper path, because a context made
against the helper's format could not always be moved onto such a window.
Cost of that choice: such a pane's window is a GL drawable again, so its
moves wait on its GPU work (the T2788 cost, *quoted* there as slow glide
batches 4% -> 45%). It applies only to a window whose earlier pane fell back
to SwapBuffers, which T3746 made rare; `Surface.zig:1088-1094` records the
reasoning.

## Fix-commit review

- **7ce6815435 (T3761):** the cap itself is sound. A capped pane's wakeup
  arms `render_c` once (`Thread.zig:777-783`) and the timer builds one frame
  with everything that arrived; `deferMs` never returns 0 (`pace.zig:70`); a
  forced frame goes straight through; a hidden pane still returns at
  `Thread.zig:871-874`. The apprt side is one `inUse()` read and one compare
  per pane per poll (`Window.zig:5165-5177`, `Surface.zig:2082-2089`), and
  the window-coverage walk it reads (`occlusion.zig:172-217`) is the walk the
  visibility poll already made, now returning an area (area W, PA-W07). Two
  side effects: PA-R26 and PA-R27.
- **459de62840 (T3746):** correct as read (above). One side effect: PA-R28.
- **d6732bc4da (T3739):** correct as read. The retry is bounded at five
  attempts over 80 s (`gl_comp_present.zig:1221-1226`) and costs one
  integer compare per frame when none is scheduled (`OpenGL.zig:1494-1495`:
  `comp == null and comp_retry_at_ms != 0` short-circuits before the clock
  read). `adoptPaneDrawable` puts the context back on the helper when the
  move fails (`Surface.zig:1867`), so the renderer thread is never left
  without a current context.
- **79307bd67b (T2622):** the loop cannot spin. `SlotPair.acquire` answers
  null only while a frame is pending (`gl_window_presenter.zig:97-102`), and
  `reclaim` answers null only when none is (`:132-138`), so the `continue`
  at `OpenGL.zig:1765` is followed by a successful `acquire`. One side
  effect: PA-R29.
- **0c0697d9bb (T1737):** `markFrameShown` records under
  `comptime frame_pacing_enabled` (`Surface.zig:7909`, `:7924`), which is
  `build_config.is_debug`; a release build carries an empty struct.
- **T3645 (GTK) in shared code:** `releaseFrameResources` asks
  `queueAppThreadRelease` behind a `comptime @hasDecl`
  (`generic.zig:1507-1509`); on win32 the function is
  `if (comptime apprt.runtime != apprt.gtk) return false`
  (`OpenGL.zig:1652-1653`), so the win32 path is the same code as before.

## New findings

### PA-R26: every window activation and deactivation forces a full frame from every terminal pane of the active tab, and re-creates the storage an idle pane had given back (P2)

- **Where:** `apprt/win32/Window.zig:24869-24872` (`WM_ACTIVATE` ->
  `inUseChanged`), `:10622-10628` (`inUseChanged` -> `syncPace`),
  `:5165-5177` (`syncPace` sends each pane its pace);
  `apprt/win32/Surface.zig:2082-2089` (`setPace`); `src/Surface.zig:4728-4736`
  (`paceCallback`: mailbox push and `queueRender`);
  `renderer/Thread.zig:456` (every message except the blink reset sets
  `force_frame`), `:548` (`.pace`), `:937-945` (`shouldPresent`: forced
  presents); `renderer/generic.zig:2224-2256` (`redraw_after_release` makes
  the frame a full draw and restarts the idle clock).
- **Mechanism:** introduced by 7ce6815435. A window's pace is `full` only
  while it is activated, so clicking into another application flips it to
  `background` and clicking back flips it to `full`. Each flip is one
  `.pace` message per terminal pane of the active tab, and every mailbox
  message forces the next frame past the present decision. The comment at
  `Thread.zig:546-547` wants that for a rising pace (held output draws now).
  It is not needed for a falling pace, and not for a pane that has no held
  output. Before T3761 an activation change forced a frame only from the
  pane that gained or lost focus. For a pane idle for more than 3 s the
  forced frame is PA-R20's first frame after a pause: the render target,
  the shared texture and both atlas textures are created and uploaded
  again, drawn in full, presented, and released again 3 s later.
- **Cost:** one draw and present per visible terminal pane per activation
  flip (*computed*); for idle panes also one target allocation and two
  atlas uploads each (*computed* from PA-R20, whose time is still not
  measured). A window with eight idle panes pays eight re-creations each
  time the user alt-tabs away and eight more on the way back. It also
  defeats the idle release's memory gain for a user who switches windows
  more often than every 3 s.
- **Fix:** do not force a frame for `.pace`. In `drainMailbox`, exempt
  `.pace` from `force_frame` the way `reset_cursor_blink` is, and when the
  pace rises fire the pending cap timer at once (or run `renderCallback`
  once if `render_c` is active). A pane with nothing held then does nothing.
- **Risk:** low. Needs the T3761 harness (section D) to prove held output
  still lands on activation.
- **Overlap:** feeds PA-R20 (T3141) and PA-R11 (T2977).

### PA-R27: a pane outside the active tab keeps the pace its window had when the tab was last in front (P3)

- **Where:** `apprt/win32/Window.zig:5171-5176` (`syncPace` walks
  `tab_trees[self.active_tab]` only), `:5226-5249` (`showTabIndex` does not
  call it); callers of `syncPace` are `:5156` and `:10627` only;
  `apprt/win32/App.zig:366` (`VISIBILITY_POLL_MS = 250`), `:1574`.
- **Mechanism:** introduced by 7ce6815435. A tab that goes behind while its
  window is in the background keeps `background` or `glimpse` on its panes'
  renderer threads. When the user activates the window and then switches to
  that tab, nothing sends the new pace until the next visibility poll. The
  first frame is forced by `.visible`, but output arriving in the next up
  to 250 ms waits for the stale cap: up to 250 ms for a `glimpse` pane
  (4 fps), 50 ms for a `background` one. That includes the echo of the
  first keys typed after the switch.
- **Cost:** up to 250 ms of added latency on the first output after a tab
  switch, once per switch, only for a tab last shown in a background window
  (*computed*).
- **Fix:** call `syncPace` at the end of `showTabIndex`, and wherever a pane
  joins a window's active tab (a pane moved between windows carries its old
  window's pace the same way).
- **Risk:** none; `setPace` forwards changes only.

### PA-R28: pooled D3D11 devices are never released, and every pane past the first device's limit pays a refused open (P3)

- **Where:** `renderer/gl_comp_present.zig:421` (`pool_max = 8`),
  `:440-469` (`acquireAt` creates on first use and keeps one reference),
  `:479-483` (`dropEntry`: reached only for a removed device and from the
  test-only `deinit`), `:712-723` (the refused open and the move to the next
  slot).
- **Mechanism:** introduced by 459de62840. The pool grows when a pane's
  interop open is refused and never shrinks: a session that once had 16
  panes open keeps a second D3D11 device, with the driver threads and
  memory a device carries, for the life of the process, after the panes are
  gone. Each new pane tries slot 0 first, so while slot 0 is full every new
  pane makes one failed `wglDXOpenDeviceNV` per full device ahead of it and
  logs one line (`:716`).
- **Cost:** one idle D3D11 device per 15 panes of peak, at most 7 extra
  (*computed*); the size of one is not known here (*inferred*; T3074
  *quoted* 3 windows going 257 -> 95 threads when two private devices per
  window were dropped, which bounds it at tens of threads). The refused
  open's time is not known.
- **Fix:** none needed below 16 panes. If it matters: drop a pooled device
  above slot 0 when its last pane releases it (the cache's own reference is
  the only one left), and remember the slot that last accepted an open so a
  new pane starts there.
- **Risk:** low; the drop must hold the cache mutex against a concurrent
  `acquireAt`.

### PA-R29: window presenter path: a drawing pane the presenter does not compose has no frame throttle left (P3)

- **Where:** `renderer/OpenGL.zig:1759-1766` (`presAcquire` reclaims and
  returns at once), `:1862` (`presPublish` skips the notify);
  `apprt/win32/WindowPresenter.zig:317`, `:58` (`MAX_PANES = 64`).
- **Mechanism:** introduced by 79307bd67b. Before T2622 such a pane waited
  2 x 20 ms and dropped the frame, which also capped it near 25 frames a
  second. Now it draws every frame into its untaken slot with no wait and
  no vsync, at whatever rate its wakeups arrive. A pane behind a tab or
  folded in a stack is told it is hidden and does not draw, so the case
  left is a visible pane the presenter leaves out: the 65th pane of a
  window (and the debug hook `GHOZTTY_PRESENTER_UNCOMPOSED`).
- **Cost:** one full draw per wakeup for frames nobody sees (*inferred*);
  only on the opt-in window presenter path and only past 64 panes.
- **Fix:** when `composed` is false, build the frame at the `glimpse` cap,
  or mark the pane hidden from `WindowPresenter.sync`.
- **Risk:** none now. Record it for the day the window presenter is
  proposed as the default.

## Checked and found clean

| Checked | Result |
|---|---|
| T3761 losing held output | A capped wakeup arms `render_c` unless it is already active (`Thread.zig:779-781`); the timer runs `renderCallback`, which reads the terminal fresh. Output parsed after the flag clear notifies again. |
| T3761 and a hidden pane | `renderCallback` checks `visible` before `last_build` (`Thread.zig:871-876`), so a hidden pane's timer does not build and does not move the cap's clock. |
| T3761 on the window in use | `capMs(false, _, .full)` is null (`pace.zig:50-59`), so `paceDelayMs` returns at its first line and the path is audit-4's. |
| T3761 on macOS and GTK | No apprt sends `.pace` there, so `pace` stays `full` (`Thread.zig:152`). |
| T3746 reference counts across the retry loop | Read; balanced (see "Changed items"). |
| T3746 and the compositor hosts | `processDevice` still hands out slot 0 (`gl_comp_present.zig:502-509`); a host never lands on a later device. |
| T3739 retry cost on a healthy pane | `comp_retry_at_ms` is 0, so `compBegin` reads no clock (`OpenGL.zig:1494-1495`). |
| T2622 busy loop | Cannot spin (see the fix-commit review). |
| GTK release split in `generic.zig` | The win32 path is unchanged code under a new function name; `releaseQueuedFrames` has no win32 caller. |
| `comp_overlay.setCoverLift` | Commits only on a change (`comp_overlay.zig:580-587`). |
| Strip fill for a plain child (T2630) | Runs only inside a live resize or live layout, as the layered fill did (`Surface.zig:5981-5985`); the added log line is `log.debug`. |

## Not covered

- Nothing was measured. PA-R26's re-creation time is PA-R20's, still
  untimed; PA-R23's wake rate for a capped pane and PA-R28's per-device
  cost need a box.
- `src/apprt/gtk/` and the GTK-only branches of the shared renderer were
  read only far enough to confirm they compile out on win32.
- The Mac half of T3761 (T3780) and the Linux half (T3781) are not built.
- The dim, badge and busy-light chrome changes (T2335, T2618, T2626) were
  read for their use of the compositor only; their window-ordering calls
  belong to area W.
- `occlusion.zig` belongs to area W (PA-W07); only its new return value was
  read.

## Summary

Counts over the 25 existing ids:

- **fixed (all rounds):** 9 (R01, R02, R04, R05, R06, R07, R08, R09, R17).
  New this round: R17, by d6732bc4da (T3739); its task T2983 is still
  `todo` and should be closed.
- **incomplete:** 1 of those 9 (R09; the remainder is T3091 and T3092)
- **still open:** 15 (R03, R11, R12, R13, R14, R15, R16, R18, R19, R20, R21,
  R22, R23, R24, R25). R20 and R23 each gained a caller from T3761; R25
  changed in size both ways; the rest are unchanged code.
- **changed:** 1 (R10, closed as a driver pool in audit-3; T3110 untouched)
- **wrong:** 0
- **new:** 4 (PA-R26 P2, PA-R27 P3, PA-R28 P3, PA-R29 P3)

Regressions from fix commits: PA-R26 and PA-R27 (7ce6815435, T3761), PA-R28
(459de62840, T3746), PA-R29 (79307bd67b, T2622). None undoes the gain of the
commit it came from.

Open P0/P1 in this area: none. PA-R20 (T3141) remains the one that could
become P1 if the first frame after a pause measures over about 2 ms, and
PA-R26 now decides how often that frame is paid.
