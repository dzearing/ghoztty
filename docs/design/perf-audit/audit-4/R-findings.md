# Audit-4, area R: renderer and GPU (T3151)

- **Date:** 2026-11-21
- **Commit audited:** c9af15802 (audit-3 was d0d874326)
- **Input:** audit-4, a re-audit of `../audit-3/R-findings.md` (PA-R01..PA-R22),
  with `../audit-1/R-findings.md` and `../audit-2/R-findings.md` for the
  original descriptions

**Produced by Fable 5.2** (`claude-fable-5-2`), one read-only auditor.

**Method.** Every verdict comes from reading the cited code at HEAD and, for
each task closed since audit-3, the source diff of its fix commit. Nothing was
built, run or measured. A cost is marked *quoted* (from a task or commit
message), *computed* (from the code) or *inferred* (mechanism read, size not
known). Confidence per row: **high** = cited lines read at HEAD and the
mechanism traced; **medium** = lines read, but a runtime fact (driver, DWM,
thread timing) decides the size.

## What moved since audit-3

`git diff --stat d0d874326 HEAD` over the area:

| File | Change |
|---|---|
| `src/renderer/wake_coalesce.zig` | new, +142: one flag per renderer wakeup (T3061) |
| `src/renderer/Thread.zig` | +11: `wakeup_pending` (`:60`), cleared at the top of `wakeupCallback` (`:744`) |
| `src/renderer/State.zig` | +19: `hasPriorityWaiters` (`:88-90`), one atomic load (T3068) |
| `src/renderer/gl_comp_present.zig` | +23: `processDevice` (`:459-466`), `DeviceCache` doc rule (`:394-401`) |
| `src/apprt/win32/chrome_comp.zig`, `child_comp.zig` | own `D3D11CreateDevice` removed; both take `processDevice()` (T3074) |
| `src/apprt/win32/viewer_toc_comp.zig` | the same for the viewer contents card (T3040) |
| `src/apprt/win32/PaneView.zig` | `setVisible` holds a parked workspace's panes (`:299-308`, T3192) |
| `src/apprt/win32/Surface.zig` | +150, none of it in the GL, pixel-format or snapshot code; line numbers moved |
| `src/apprt/win32/Window.zig` | +1103: single-window mode (park, surrender, adopt); the occlusion and hero code is unchanged, line numbers moved |

`src/renderer/generic.zig`, `OpenGL.zig`, `opengl/*`, `cell.zig`, `image.zig`,
`link.zig`, `cursor.zig`, `storage_trim.zig`, `upload_diff.zig`, `font/*`,
`comp_overlay.zig`, `comp_tree.zig`, `apprt/win32/pane_pool.zig`,
`hero_snap_schedule.zig` and `WindowPresenter.zig` did not change (empty
diff), so their line numbers are audit-3's. `Thread.zig` cites are audit-3's
plus 7 (below `:60`) or plus 11 (below `:744`).

Commits and tasks:

| Commit | Task | What |
|---|---|---|
| 1cde0416f | T3074 (PA-R02 residual) | chrome host and sidebar/child host take the process D3D11 device; per-pane DComp device kept on a measured decision |
| e15858510 | T3040 | adds `processDevice`; the viewer contents card uses it |
| 5059acb10 | T3061 (PA-C04) | output-driven renderer wakeups are coalesced; the request moves after the parse and the unlock |
| 2b92c79da | T3068 | `State.hasPriorityWaiters`; the rest is `termio/Remote.zig` (area C/I) |
| c513c69cc | T3192 | a parked workspace's panes take the hidden release and are held by `PaneView.setVisible` |
| 4ee8226d1 | T3203 | parked panes are sized and scaled for the window they will appear in |
| 99efd0c58 | T3095 | sheet worker pool stacks (not renderer code; area M) |

No task named in audit-3's "Task action" column closed except T3074. T2969,
T2977-T2983, T3090, T3091, T3092, T3096, T3098, T3110 and the three filed for
audit-3's new findings (T3141, T3142, T3144) are all `todo` with no commits.

## Verdicts

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| R01 | **fixed** (high) | `renderer/generic.zig:76-81`, call at `:1634` | 8d2be0f7b. Unchanged. | T2967 stays closed. |
| R02 | **fixed**; the tracked residual is now fixed too (high for code, medium for the measured numbers) | `renderer/gl_comp_present.zig:402-450` (`DeviceCache`), `:459-466` (`processDevice`); `apprt/win32/chrome_comp.zig:999-1007`; `child_comp.zig:212-220`; `viewer_toc_comp.zig:135`; per-pane DComp device still at `gl_comp_present.zig:775-777` | 29302f08c, then 1cde0416f (T3074) and e15858510 (T3040): neither host calls `D3D11CreateDevice` any more (the import and constants are deleted in the diff), both take a referenced device from the cache. *Quoted* from T3074: 3 windows 257 -> 95 threads, private bytes about 392 -> 313 MB with `GHOZTTY_COMP_CHROME=1`. The DComp device per pane stays: T3074 measured 8 threads for two extra one-pane windows in total and decided not to share it. That decision is recorded in the task, so nothing is left open under R02. | T2968, T3074 stay closed. See PA-R25 for the one thing the sharing adds. |
| R03 | **still open** (high) | `renderer/OpenGL.zig:482-488`, `opengl/shaders.zig:116-119`, `generic.zig:499-512`, `:580-601` | Unchanged. No share group; per-pane programs and atlas copies. | T2969 unchanged (todo, P2). |
| R04 | **fixed** (high) | `renderer/cursor.zig:77-87`, `generic.zig:1927-1936`, `Thread.zig:871`, `:1079` | 2cdc77abe. Unchanged; Thread lines moved by 11. | T2970 stays closed. |
| R05 | **fixed** (high) | `renderer/link.zig:63-75`, `:96`; `generic.zig:1823` | 5672c7165. Unchanged. | T2971 stays closed. |
| R06 | **fixed** for uploads (high) | `renderer/opengl/buffer.zig:83-100`, `:124-128`, `:159-166` | 60ae989a0. Unchanged. Grow-only half is PA-R19. | T2972 stays closed. |
| R07 | **fixed** for steady state; the idle caveat is PA-R20 (high) | `generic.zig:2303-2321`, `:4198-4228`, `:580-601` | 396aac1db. Unchanged. | T2973 stays closed. |
| R08 | **fixed** (high) | `renderer/OpenGL.zig:1309-1312`, `:1356-1382`; `gl_comp_present.zig:1007-1015`; `Thread.zig:624`, `:632-652`; `generic.zig:2252-2279` | 6711c4e45. Unchanged; `gl_comp_present.zig` lines below `:402` moved by 23, Thread lines by 7. | T2974 stays closed. |
| R09 | **fixed (incomplete)**, remainder tracked; now also covers a parked workspace (high) | `apprt/win32/Window.zig:5029-5038` (tab switch), `:4655-4664` (`setTabSurfacesVisible`), `:7645-7653` (`parkPaneHidden`), `:7661-7664`, `:9351`; `PaneView.zig:299-308`; `OpenGL.zig:1589-1593`, `:1646-1658`; `generic.zig:1478-1546` | 19581323a still as audit-3 read it. New: c513c69cc (T3192) sends every pane of every tab of a parked workspace through the same release (`setWindowHidden(true)` then `setVisible(false)`), and `PaneView.setVisible` refuses to show a pane whose window is parked, so a layout pass or a `+split` made while parked cannot bring the targets back. Not freed, as before: the composition swap chain and the window-presenter slot textures. A parked workspace therefore holds one full-size swap chain per pane for as long as it is parked. | T2975 stays closed. T3091, T3092 (todo): add "and every pane of a parked workspace (T3192)" to the scope. |
| R10 | **changed** (audit-3's verdict stands): closed as not ours (medium) | no renderer source; `docs/design/windows-parity-tasks/T2976.md` | Nothing new. T3110 is still `todo` and was not re-measured with the idle release on. | T3110 unchanged; audit-3's note (per-context driver state, points at PA-R03) still not in the task. |
| R11 | **still open** (high) | `generic.zig:1986`, `:3438`, `:2170-2191`; `Thread.zig:913-941`; `OpenGL.zig:1661-1669`; `gl_comp_present.zig:1076-1089` | Unchanged. T3061 does not touch it: an unchanged frame let through by the 500 ms bound is still a full draw, and still re-creates released storage when such frames are over 3 s apart. T3061 does remove one source of them: the wakeup is now posted after the parse, so a renderer no longer wakes ahead of the output it was woken for. | T2977 unchanged (todo, P2). |
| R12 | **still open** (high) | `renderer/cell.zig:118-122` | Unchanged. | T2978 unchanged. |
| R13 | **still open** (high) | `generic.zig:2630`, `:2590`, `:2638`; `image.zig:906` | Unchanged. | T2979 unchanged. |
| R14 | **still open** (high) | `renderer/opengl/Pipeline.zig:51-57` vs `:73-75` | Unchanged: `deinit` destroys the program only. | T2980 unchanged. |
| R15 | **still open** (high) | `apprt/win32/Surface.zig:1764-1765`; helper `:1650-1666`; fallback `:1672-1690` | Unchanged apart from line numbers. | T2981: re-cite lines. |
| R16 | **still open**, one new caller (high for the mechanism, medium for the size) | `apprt/win32/Window.zig:23425-23426` (`WM_SIZE`), `:4994-5000` (`refreshOcclusion`), `:4951-4958` (`setActiveTabVisible`), `:8641-8648` (`heroSnapTick` checks `IsIconic` only), `:8843`, `:9435`, `:14017` (`hideReleasing`), `:7792` (new caller) | Both halves unchanged: `refreshOcclusion` still ends in `setActiveTabVisible(true)` when the window is neither hidden nor was occluded, so every size step re-shows zoom-covered and stashed panes that the layout then re-hides. New caller: `adoptWindow` calls it before `showTabIndex` on every workspace switch; that is one show/hide cycle per switch, not per step, and a real transition, so it is correct there. | T2982 unchanged (todo, P2); re-cite lines. |
| R17 | **still open** (high) | `apprt/win32/Surface.zig:1025` | Unchanged apart from the line number. | T2983: re-cite line. |
| R18 | **still open** in audit-3's reduced form (high) | `OpenGL.zig:1312`; `generic.zig:2185-2191`, `:2256`; `storage_trim.zig:114-119`, `:27`; `generic.zig:1419-1436` | Unchanged. | T3096 unchanged (todo, P2). |
| R19 | **still open** (high) | `renderer/opengl/buffer.zig:114-121`, `:144-151`, `:83-90` | Unchanged. | T3098 unchanged. |
| R20 | **still open** (high for the mechanism, medium for the size) | `generic.zig:1406`, `:1517-1533`, `:2174`, `:2196-2202`, `:2260-2279`, `:2303-2321`, `:4204-4210`; `OpenGL.zig:1653`; `gl_comp_present.zig:1008-1015`, `:905-954` | Unchanged. Still not timed. | T3141 (todo, P2). |
| R21 | **still open** (high) | `OpenGL.zig:1343-1350`; `opengl/Target.zig:34-37`; `generic.zig:1529`, `:522` | Unchanged: `capacityFor(1, true)` is 256. | T3142 (todo, P2). |
| R22 | **still open** (high) | `apprt/win32/Surface.zig:2902` (free in `heroSnapPublish`), `:2714-2722` (`snapRequest` allocates), `:2791` (`heroSnapCommit` clears the flag first); `hero_snap_schedule.zig:60` | Unchanged apart from line numbers. | T3144 (todo, P2); re-cite lines. |

## Changed items

### PA-R02: the residual is closed

- `chrome_comp.Host.init` (`:999-1007`) and `child_comp.Tree.init`
  (`:212-220`) take `gl_comp_present.processDevice()`; the caller owns one
  reference on the device and one on the context, both covered by an
  `errdefer release`.
- `processDevice` (`gl_comp_present.zig:459-466`) honours
  `GHOZTTY_COMP_SHARED_DEVICE=0` by building a private device, so the A/B
  still works for the hosts.
- The safety rule is written at `gl_comp_present.zig:394-401`: only the GUI
  thread binds pipeline state; renderer threads copy, upload and present.
  Read against the pane path, that holds: the only context calls there are
  `CopyResource`, `CopySubresourceRegion` (`:1076`, `:1081`) and the swap
  chain `Present` (`:1089`).

### PA-R09: a parked workspace is a hidden one

See the table row. What a parked pane holds is audit-3's "kept" list
unchanged: swap chain (T3091), 256x256 placeholder (PA-R21), cell buffers
(PA-R19), programs and context (PA-R03), DComp device.

## Fix-commit review

- **1cde0416f (T3074):** correct as read. No leak on the error paths. A lost
  shared device is rebuilt once by `DeviceCache.acquire` (`gl_comp_present.zig:411-420`) and
  each host picks the fresh one up on its own rebuild. One side effect:
  PA-R25.
- **e15858510 (T3040):** the renderer part is `processDevice`; correct.
- **5059acb10 (T3061):** the flag protocol is sound for the frame path. The
  renderer clears the flag before it reads anything (`Thread.zig:744`), the
  producer notifies only on a clear-to-set transition
  (`wake_coalesce.zig:41-52`), and a failed notify clears the flag again.
  Wakeups that bypass the flag only add wakeups. Two gaps: PA-R23 (the
  coalescing does nothing for a pane whose wakeup does not draw) and PA-R24
  (the error return sits above the clear).
- **2b92c79da (T3068):** `hasPriorityWaiters` is one atomic load. No renderer
  cost.
- **c513c69cc (T3192):** correct as read. `holdParkedPanes` runs as a `defer`
  at the end of every `layoutSplits` (`Window.zig:9351`) but returns on
  `hwnd != null` for every window that has one (`:7623-7625`, `:7662`), so an
  ordinary window pays one compare.
- **4ee8226d1 (T3203):** the settle timer (`Window.zig:23459-23460`,
  300 ms) lays parked workspaces out once after a resize of the shared
  window, not per step. Their panes are hidden, so each gets a `.resize` and
  one wakeup that builds nothing (`Thread.zig:853-856`).

## New findings

### PA-R23: output to a pane that is not drawing still wakes its renderer per batch; T3061's coalescing only works for a pane that draws (P2)

- **Where:** `renderer/Thread.zig:744` (flag cleared on every wakeup),
  `:853-856` (`renderCallback` returns at once while hidden), `:760-765`
  (low-power: the wakeup arms a timer and returns); `wake_coalesce.zig:41-52`
  (a request notifies whenever the flag is clear);
  `termio/Termio.zig:1114`, `:1124-1126`, `:1145`, `:1188` (`queueOutputRender` after every parsed batch).
- **Mechanism:** the coalescing window is the time between the renderer
  clearing the flag and its next wakeup. For a visible pane that is one
  frame of work, so about one notify per frame. For a hidden pane (a
  background tab, a covered or minimized window, a zoom-covered or stashed
  pane, a parked workspace) the wakeup does no work: clear the flag, drain an
  empty mailbox, return. The flag is clear again within microseconds and the
  IO thread's next batch posts another notify. The same holds in low-power
  mode while the present cap is pending. So a build running in a background
  tab still pays one `PostQueuedCompletionStatus` plus libxev's guard mutex
  on the IO thread, and one renderer-thread wake, per output batch.
- **Cost:** up to the batch rate. T3061 measured 31.5k requests/s under a
  flood and 118.6 notifies/s after the fix (*quoted*), on a visible pane. The
  hidden-pane rate was not measured; it is bounded by how fast the renderer
  thread can turn its loop (*inferred*). Not a regression (before T3061
  every batch notified), but the case most likely to flood unattended gets
  none of the gain.
- **Fix:** do not clear the flag on a wakeup that will not build a frame.
  Clear it in `renderCallback` after the `visible` check (and, for
  low-power, when the deferred timer fires), and clear it when `.visible`
  turns true. The catch-up on show already exists (`frame_stale`,
  `Thread.zig:447-470`), so a hidden pane needs no output wakeups at all.
- **Risk:** medium. A lost wakeup is a frozen pane (T40), so the change
  needs the concurrent test in `wake_coalesce.zig` extended with a
  hide/show transition.

### PA-R24: an error from the wakeup wait returns before the coalescing flag is cleared (P3)

- **Where:** `renderer/Thread.zig:735-738` (error return, `.rearm`) above
  `:744` (`consume`).
- **Mechanism:** introduced by 5059acb10. If the Async wait completes with an
  error, the callback returns with `wakeup_pending` still set. Every later
  output request then sees the flag set and posts nothing
  (`wake_coalesce.zig:46`), so the pane repaints only when something else
  wakes it (focus, resize, the blink timer of a focused pane). Before T3061
  the next batch simply notified again.
- **Cost:** none in normal running; a frozen pane if the error ever fires
  (*inferred*; no known trigger on IOCP).
- **Fix:** call `consume` before the error check.
- **Risk:** none.

### PA-R25: the GUI thread's chrome draws now share one device lock with every pane's copy and present (P3)

- **Where:** `gl_comp_present.zig:394-401` (the rule), `:1076-1089` (pane
  `CopyResource` and `Present(1, 0)` on the shared immediate context);
  `chrome_comp.zig:999-1007`, `:1174-1188` (Direct2D `BeginDraw`..`EndDraw`
  on the same device); `child_comp.zig:212-226`.
- **Mechanism:** introduced by 1cde0416f. With multithread protection on,
  each immediate-context call takes the device's lock. Before T3074 the
  chrome and sidebar hosts had private devices and never waited on a pane.
  Now a Direct2D flush or a layer upload on the GUI thread can wait behind a
  renderer thread's copy or present, and the reverse.
- **Cost:** not known (*inferred*). The pane calls are short and the chrome
  host is opt-in (`GHOZTTY_COMP_CHROME=1`, `chrome_comp.zig:85-88`), so this
  matters only if the chrome host becomes the default. Which thread
  `child_comp`'s `Layer.setPixels` runs on was not traced.
- **Fix:** none now. When `GHOZTTY_COMP_CHROME` is proposed as the default,
  time a caption repaint during a flood in several panes, shared device on
  and off (`GHOZTTY_COMP_SHARED_DEVICE=0`).
- **Risk:** none.

## Checked and found clean

| Checked | Result |
|---|---|
| T3061 losing the frame for the last batch of output | The clear is above the mailbox drain and the terminal read (`Thread.zig:744` vs `:753`, `:768`), so output parsed after it finds the flag clear and notifies. |
| T3061 and the idle release | The idle timer is armed from the draw path, not the wakeup; fewer wakeups change nothing there. |
| T3061 request ordering | The request is now made after the parse and after the unlock (`Termio.processOutput`), so the renderer no longer wakes onto a held mutex. A wakeup that slips in between costs at most one extra unchanged frame, which `presentDecision` skips inside 500 ms. |
| T3192 on ordinary windows | `holdParkedPanes` is one null compare per layout pass (`Window.zig:7623-7625`). |
| T3192 leaving a parked pane drawing | `parkPaneHidden` sets `window_hidden` before `setVisible(false)`; later layout passes are held by `PaneView.setVisible` (`:299-303`) and re-held by the `defer` at `Window.zig:9351`. |
| T3203 parked relayout stalling the GUI thread on a frame wait | The pass runs from a timer with no live layout around it; `shouldPresentSynchronously` (`resize_paint.zig:223-230`) needs `in_live_resize` or `in_live_layout`. Medium: the timer path's `in_live_layout` was read as unset, not traced through every callee. |
| Shared device handed to three more hosts | References balance on every error path read; `acquire` never hands out a removed device (`gl_comp_present.zig:411-420`). |
| A parked workspace in hero mode | Its heartbeat timer is killed on surrender (`Window.zig:7597`, `:7686`); it keeps its thumbnails, which hero mode still needs on return. |

## Not covered

- Nothing was measured. PA-R23's hidden-pane notify rate, PA-R20's first
  frame time and PA-R16's race all need a box.
- The window presenter path and tree mode (both opt-in) were not re-read;
  no commit touched them.
- The Mac halves (Metal, kqueue Async under T3061: T3229) were not checked.
- `termio/*` beyond the T3061 diff belongs to area C.

## Summary

Counts over the 22 existing ids:

- **fixed (all rounds):** 8 (R01, R02, R04, R05, R06, R07, R08, R09). None
  is new this round; R02's tracked residual (T3074) closed with 1cde0416f.
- **incomplete:** 1 of those 8 (R09; the remainder is T3091 and T3092, and
  now also applies to parked workspaces)
- **still open:** 13 (R03, R11, R12, R13, R14, R15, R16, R17, R18, R19, R20,
  R21, R22); R16 gained one caller, the rest are unchanged code
- **changed:** 1 (R10, closed as a driver pool in audit-3; T3110 untouched)
- **wrong:** 0
- **new:** 3 (PA-R23 P2, PA-R24 P3, PA-R25 P3)

Regressions from fix commits: PA-R24 (5059acb10) and PA-R25 (1cde0416f),
both P3. No renderer source under `src/renderer/generic.zig`, `OpenGL.zig`
or `opengl/` changed this round, so every open R finding there is exactly
as audit-3 left it and every task for it is still `todo`.

Open P0/P1 in this area: none. PA-R20 (T3141) remains the one that could
become P1, if the first frame after a pause measures over about 2 ms.
