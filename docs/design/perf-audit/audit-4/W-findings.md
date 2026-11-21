# Audit-4, area W: the win32 frontend (T3151)

- **Date:** 2026-11-21
- **Commit audited:** c9af15802 (audit-3 was d0d874326)
- **Input:** audit-4, a re-audit of `../audit-3/W-findings.md` (PA-W01..PA-W19),
  with `../audit-1/W-findings.md` and `../audit-2/W-findings.md` for each id's
  original description
- **Scope:** `src/apprt/win32/` without the renderer presenters and the viewer
  panes

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. Nothing
was built, run or measured this turn. Every verdict is from reading the code
at HEAD and the fix commits' diffs; every cost is either quoted from a task
file or an earlier audit (and said to be) or computed/inferred from the code.

## Method

1. Read audit-3's file whole; took its 19 ids and its "Task action" column as
   the list to reconcile.
2. `git log --oneline d0d874326..HEAD -- src/apprt/win32` (64 commits) and a
   per-file log for every file an open finding cites, to split "file
   unchanged, cite stands" from "file moved, re-read".
3. For each id: re-located the cited functions at HEAD by name, read them, and
   re-traced the mechanism. For the one id closed since audit-3 (PA-W17,
   T3095) read the fix commit's source diff (`git show 99efd0c58`).
4. Read the whole `d0d874326..HEAD` diff of `Window.zig`, `Surface.zig`,
   `PaneView.zig`, `PaneDesk.zig`, `chrome_comp.zig`, `child_comp.zig`,
   `HeroCarousel.zig`, and the workspace half of `App.zig`'s
   (`:8091-8362` at HEAD, plus the `performAction` and `msgWndProc` hunks);
   read `workspace_host.zig`, `desk_fade.zig`, `hero_tile_card.zig` and
   `pane_pool.zig` where the diffs led.
5. Task states from the task files' front matter
   (`docs/design/windows-parity-tasks/T*.md`), not from commit messages.

## What moved since audit-3

`git diff --stat d0d874326 HEAD -- src/apprt/win32/`: 82 files, +11544 / -999.
Sixty-four commits touched the area. About half of the volume is the viewer
(out of scope: `ViewerPane.zig` +1381, `ViewerResourceServe.zig`,
`ViewerImageDecode.zig`, `ViewerDocumentRead.zig`, `viewer_*.zig`,
`webview2_iface.zig`, `git_run.zig`). In scope:

| Commit(s) | Task | PA | What it did in this area |
|---|---|---|---|
| 99efd0c58 | T3095 | **PA-W17** | `sheet_workers.zig:47` builds its pool with `thread_stack.poolOptions` (new, `src/os/thread_stack.zig:48-50`), so pool workers get the 64 KB commit |
| 1cde0416f | T3074 | area R/M | `chrome_comp.zig` and `child_comp.zig` take the process's one D3D11 device (`gl_comp_present.processDevice`) instead of creating one per window / per tree |
| 073c924a7 | T1590 | none (perf) | `App.performAction` `.config_change` returns early for a surface-scoped notification (`App.zig:9830-9852`): one chrome rebuild per reload, not one per pane plus one |
| 5ec8f8bc5 | T3178 | none (perf) | a pane drag arms only its own window's sidebar; another window's joins on the first move over it (`Window.zig` `setSidebarsDragActive`, `armSidebarUnder`) |
| d8a5c59c6 | T3022 | none (reliability) | `+new-remote-window` dials on a worker (`IpcServer.zig:430-445`, spawned with `thread_stack.config`), not on the GUI thread |
| 64e0ae1a6, bbcd629db, e57524b96, 3776d425f, 243aa61eb, c513c69cc, 7cc29cdb2, 191b35250, f809396dd, c26e98ba2, 383192882, a9a909d5c, f6c863aa5, 03dfd60a6, 27b38efd4, 330c5511a, 9f2c0f247, 48c6b3ede, 4ee8226d1 | T3180-T3187, T3191-T3194, T3200, T3202, T3203, T3205, T3206, T3212 | none (feature) | **single-window mode**: `workspace_host.zig` (new), `Window.surrenderWindow` / `adoptWindow` / `promoteToOwnWindow` / `releaseWindowBound` / `holdParkedPanes`, `App.showWorkspace` and friends, the park host HWND, `PARKED_RELAYOUT_TIMER_ID`, the shade crossfade (`desk_fade.zig`, `PaneDesk.fade`) |
| 4a2b60f70, f9c133ae8, 0fb5083b6 | T3131, T3132, T3279 | none (feature) | hero mode over a single pane, a fixed carousel width, `goto_window`; carousel tiles drawn as raised cards per pixel (`hero_tile_card.zig`, new) |
| 2e0351d7c, 85f10d2a3, 2ebcf125c, eb4ae2f66 | T3137, T3176, T3177, T3134 | none (feature) | restore order / front window, pane tint and typed title persisted (`markLayoutDirty` from `setUserTitle` and `applyBackgroundTint`), `tab_opened` |
| f0b350b27, a3e45d6e8, 4395f3411, b33a419bb, f72d768e1, 72719a498 | T1541, T1577, T1591, T3272, T1546, T3133 | none | dwell-lit tab, fresh-tab width release in `paintTabBar`, an invalidation counter, an activation log line, pop-out size, `user_input_sent` on the win32 key paths |

Files the open findings cite that are **byte-identical** to audit-3's (empty
per-file log): `KeyStateIndicator.zig`, `ReadonlyBadge.zig`,
`BannerOverlay.zig`, `pane_grab_handle.zig`, `PaneGrabHandle.zig`,
`system_colors.zig`, `occlusion.zig`, `pane_pool.zig`, `activity_sample.zig`,
`size_burst.zig`, `strip_label_memo.zig`, `ipc_pipe_io.zig`,
`src/os/reusable_thread.zig`. `Window.zig` grew by about 60-700 lines above
each cited site (the hand-off block sits at `:7575-7830`), `App.zig` by
55-660, `Surface.zig` by 2-50, `PaneSidebar.zig` by about 30; every line
number below is re-read at HEAD.

## Verdicts

Confidence is **high** (cited lines read at HEAD, mechanism traced) unless a
row says otherwise.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-W01 | fixed (incomplete), remainder smaller | `src/os/thread_stack.zig:33-36`, `:48-50`; `src/os/reusable_thread.zig:60`, `:116`; still default: the short-lived `.{}` spawns (e.g. `App.zig:11444`, `:12284`, `:13446`) | 90e57ab70 as before. The pool half of the remainder is now closed (PA-W17). No new long-lived default-stack thread: the one new product spawn since audit-3 (`IpcServer.zig:432`) uses `thread_stack.config`; the one new `.{}` spawn (`git_run.zig:506`) is in a test | T2985 stays closed. Remainder is T3075 (todo, P2) only |
| PA-W02 | **fixed** (2fe99e84f), unchanged | `size_burst.zig:56-74`; `Window.zig:21208-21260` (`dropDeskCanvas`, `noteSizeStep`, `settleSizeBurst`), call `:23446`, timer `:23301-23303`, hand-off to the edge drag `:23517-23519`; `PaneDesk.zig:1194-1196` | Code identical in shape to audit-3's reading. One interaction to know: `SIZE_BURST_TIMER_ID` is in `window_timer_ids` (`Window.zig:7596-7603`), so a workspace hand-off mid-burst kills the settle timer; the surrendering side's `pane_desk.deinit` (`:2706`) drops the canvas with the desk, so nothing is left armed | T2986 closed. T3116 (todo) still owns the release measurement |
| PA-W03 | **fixed (incomplete)**, unchanged | gate `Window.zig:19885-19888`, `chromeBandReach` `:19930-19962`; `chrome_comp.zig:241-256` (`Mirror`), `:311` (`reaches`); still over-wide: `invalidateTabBar` `:19158-19170`, `invalidateCaption` `:19181-19187` | Gate and buffers as audit-3 found them. Remainder unchanged: (a) PA-W18; (b) per-title measurement every strip paint (`:19455`, `:19466`), T3117; (c) a region and a brush per tab per strip paint (`:20407`, `:20428`), PA-W14's family. `paintTabBar` gained an O(tabs) `fresh` pass (`:20303-20314`, T1577): two field reads per tab, no allocation | T2987 closed; T3117 (todo), T3143 (todo) open |
| PA-W04 | **fixed** (f51045ceb), unchanged | `Window.zig:19012-19013` (`onPaneTitleChanged`), `invalidateTuckedStripName` `:14984-14998`, memo recorded at `:14745` and `:14859`; `strip_label_memo.zig:34-57` | Unchanged shape. A parked workspace's hidden pane costs nothing here: `invalidateTuckedStripName` returns at `self.hwnd orelse return` (`:14985`) | T2988 closed. T3118 (todo) owns the unproven CPU criterion |
| PA-W05 | **fixed** (ad3cfa61d), unchanged | `scripts/perf-baseline.ps1:819` (`Get-ThreadCtx`), `:856` (`Get-ThreadIdentity`), `:870` (`Get-WakeupAttribution`) | Tooling only; the three functions are present at HEAD (the script grew above them through T3061/T3130/T3159/T3169/T3235). Not re-read line by line | T2989 closed. T3119, T3120 (both todo) |
| PA-W06 | **fixed** (c23205794), unchanged | `activity_sample.zig:157`, pool `:167`; `ActivityMonitor.zig:974` (close joins) | `activity_sample.zig` byte-identical; `ActivityMonitor.zig` gained only tooltip fields (T1548) | T2990 closed. T3122 (todo, P2) |
| PA-W07 | still open | `App.zig:1120` (set once), `:14521-14524`, `pollVisibility` `:1522-1530`; `occlusion.zig:115-156`; `Window.zig:4968` (`applyOcclusion`) | `VISIBILITY_TIMER_ID` appears only at `App.zig:353`, `:1120`, `:14521`; no `KillTimer` for it among the 20 in the file. A parked workspace is skipped by the loop (`w.hwnd orelse continue`, `:1526`), so single-window mode does not multiply the per-tick work | T2991 unchanged; update its line refs |
| PA-W08 | still open | `pane_grab_handle.zig:209-214`; `PaneGrabHandle.zig:226`, `:154` | files unchanged | T2992 unchanged |
| PA-W09 | still open | `Window.zig:1683-1685`, `chromePalette` `:1699-1705`, callers `:7992`, `:8018`, `:15077`, `:15910`, `:19551`, `:19673`, `:20177`; `system_colors.zig:146-153`, `:423-432` | `system_colors.zig` unchanged: `usesLightTheme` still opens, queries and closes the key per call; `chromePalette` still calls it per call (`:1704`) | T2993 unchanged; update line refs |
| PA-W10 | still open | `Window.zig:12276-12309`: `buildWith(gpa, ...)` `:12297`, `defer built.deinit(gpa)` `:12298`; an arena per call in `noteStackRows` `:12316-12321` (called at `:12285`) | unchanged shape; 24 call sites of `stackGrid()`/`stackGridOfTab(` | T2994 unchanged; update line refs |
| PA-W11 | still open, one new trigger | `PaneSidebar.zig:5417-5423` (cache stale on a new `desk_gen`, then `cache.release()`), `:1031-1035` (`deskPainted`) | Same mechanism. New: the single-window shade crossfade renders a new desk generation every frame for 350 ms, so the material is rebuilt per frame of it (PA-W23) | T2995 unchanged; update line refs |
| PA-W12 | still open | `Window.zig:14562-14574` (two brushes, two `stripFont` fonts per `paintStripBandsAndNames`); also `:10822`, `:11127`, `:11314`; `stripFont` `:14710-14729`; cached pair `:14954-14955` | unchanged shape | T2996 unchanged; update line refs |
| PA-W13 | still open | `KeyStateIndicator.zig:567-571`, `:310-319`, `:676-690`; `ReadonlyBadge.zig:175`, `:194-203`, `:208` | files unchanged | T2997 unchanged |
| PA-W14 | still open | `Window.zig:20077-20080` (`fillEllipse`: brush + pen), `:20125-20127` (strip button: region + brush), `:20407`, `:20428` (per tab); `PaneSidebar.zig:2381`, `:2389`, `:2401-2403`; `BannerOverlay.zig:1657`, `:1706-1707`, `:2210` | per-call create/delete. `brush_cache` is still imported by 12 files, none of them these painters | T2998 unchanged; update line refs |
| PA-W15 | still open | `Surface.zig:909`, `:912` (two `CreateEventW`), first errdefer `:961`; closed only in `deinit` `:1410-1417`; `Window.zig:4113-4114` (no destroy on a failed init) vs the guarded siblings `:4536-4540`, `:17616-17620` | unchanged shape. One more early exit now sits between the events and the first errdefer: `parent.hwnd orelse parent.app.parkHost() orelse return error.Win32Error` (`Surface.zig:920`) | T2999 unchanged; update line refs |
| PA-W16 | still open, one new consequence | `Surface.zig:1544-1547`, `parkWindow` `:1554-1571`, `takeParkedWindow` `:1575-1597`; `pane_pool.zig:64-66`, `:28` | `parkWindow` unchanged. In single-window mode the pool now outlives its workspace: see PA-W21 | T3000 unchanged; add PA-W21 to it or file it beside |
| PA-W17 | **fixed** (99efd0c58) | `sheet_workers.zig:45-47`; `src/os/thread_stack.zig:48-50` (`poolOptions`), tests `:138-171` | Diff read: `pool.init(thread_stack.poolOptions(std.heap.smp_allocator, want))`; `poolOptions` sets `.stack_size = config.stack_size`, the same commit hint `std.Thread.spawn` callers get. The new test measures a real pool worker's committed stack with std's options (>= 15 MB, positive control) and with `poolOptions` (<= 1 MB). `sheet_workers` is the only `Thread.Pool` in the area (the diff's only `Pool` line) | T3095 closed correctly (status done, commit recorded) |
| PA-W18 | still open | `Window.zig:19158-19170`, `:19181-19187`; gate `:19885-19888`, `:19951-19960`; `mergedChrome` `:2808-2810`; callers `:19315`, `:19333`, `:19343` (caption hover), `:21645-21646` region (strip hover), `:19053-19059` (`invalidateTabLabel`) | Both rects still span `right = 10000`. `invalidateTabBar()` now has 21 call sites; the new one is `setDwellLit` (T1541), during a pane drag only. A single-window workspace with a custom caption shows no strip (`tabBarShouldShow`, T3182), so `mergedChrome()` is false there and it does not pay this | T3143 (todo, P2) unchanged |
| PA-W19 | still open | `Surface.zig:2902` (free), `:2715-2722` (re-alloc); driver `Window.zig:8641-8681`, `hero_snap_schedule.zig:60` | unchanged. Reach is wider than at audit-3: hero mode now stays on over a single pane (T3131, `Window.zig:5158`), so a one-pane tab in hero mode pays it too | T3144 (todo, P2) unchanged |

No item is **wrong**. No item is **changed** in shape; PA-W11, PA-W16 and
PA-W19 each gained a caller or a consequence, noted in their rows.

## Fix-commit review

### 99efd0c58 (T3095, PA-W17): no regression found

- `poolOptions` passes the caller's allocator and job count through and adds
  only `stack_size`. The reserve is unchanged (16 MB), so worker depth is the
  same; `sheet_workers`' jobs are pixel loops with no deep recursion.
- No other `std.Thread.Pool` exists in `src/apprt/win32/` at HEAD.

### 1cde0416f (T3074): one thing for area R to confirm

- `chrome_comp.Host` and `child_comp.Tree` now draw and upload through the
  process's shared D3D11 device. The comment at `chrome_comp.zig` (the
  `d3d11-device` stage) argues renderer threads only copy and upload, which
  bind no pipeline state. Not checked here: whether the GUI thread's Direct2D
  draws now wait on the device's multithread lock behind renderer uploads
  during heavy output. Inferred risk only; no cite beyond the comment, so
  this is a note for area R/M, not a finding.

### 073c924a7 (T1590) and 5ec8f8bc5 (T3178): both remove work, no regression found

- T1590: a surface-scoped `config_change` returns before the per-window
  rebuild. The app-scoped one that ends every hard reload still runs it once.
- T3178: at drag start only the dragging window's sidebar is armed; the
  release loop walks every window but `setDragActive(false)` returns at once
  for an unarmed one.

### The single-window port (T3180-T3212): correct by reading, three costs filed

- Idle cost of a parked workspace is low by construction: its panes are
  `setWindowHidden(true)` + `setVisible(false)` (`Window.zig:7645-7653`), the
  visibility poll skips it, `scheduleSidebarSync` and every chrome
  invalidation return at `self.hwnd orelse return`, and `PaneView.setVisible`
  holds a parked pane hidden through layout passes (`PaneView.zig:299-301`).
- `updateWindowTitle` now computes `activityAggregate()` before its HWND
  check, and a workspace also calls `App.refreshWindowActivity`
  (`Window.zig:18808-18814`, `App.zig:8283-8288`): one enum read per pane of
  every workspace per title change. Too small to file.
- `PARKED_RELAYOUT_TIMER_ID` is re-armed per `WM_SIZE` only when more than one
  workspace exists (`Window.zig:23459-23460`) and fires once, 300 ms after the
  last step; each parked workspace then gets one `layoutSplits`. Bounded.
- `holdParkedPanes` is deferred from every `layoutSplits` (`:9351`) but
  returns at `isParked()` (an `hwnd == null` test) for every window on show.
- Filed: PA-W20 (the hand-off rebuilds everything HWND-bound), PA-W21 (parked
  pane windows outlive a closed workspace), PA-W23 (the crossfade's per-frame
  desk).

### 0fb5083b6 (T3279): one new per-paint cost (PA-W22)

The carousel band was already rebuilt whole on any tile invalidation; the
tiles are now shaded per pixel on top of that. See PA-W22.

### 85f10d2a3 (T3176), 72719a498 (T3133): nothing on a hot path

`markLayoutDirty` (a debounced `SetTimer`, `App.zig:3024-3030`) is now called
from `setUserTitle` and `applyBackgroundTint`; all seven callers of the latter
are user or IPC actions, none per frame. `user_input_sent = true` on the
win32 key paths is one store per key.

## New findings

| PA | P | Where | Cost | Fix |
|---|---|---|---|---|
| PA-W20 | P2 | `Window.zig:7675-7731` (`surrenderWindow`), `:2690-2729` (`releaseWindowBound`), `:7738-7813` (`adoptWindow`); `App.zig:8164-8184` | inferred, not measured: every workspace switch frees and rebuilds the presenter, the chrome compositor host, the caption/strip/desk/overlay buffers, the sidebar window, three fonts, and re-parents every pane of both workspaces twice | measure first; then hand the size-keyed, HWND-bound objects over in `WindowBound` instead of destroying them |
| PA-W21 | P2 | `Surface.zig:1554-1571`, `:1575-1577`; `Window.zig:22885`, `:22895-22902`; `pane_pool.zig:28` | computed bound, inferred cost: up to 16 hidden pane HWNDs per workspace are never destroyed when that workspace closes in place, for the life of the shared window | drain the pool (`DestroyWindow` each) in `surrenderWindow` or in the in-place close |
| PA-W22 | P3 | `HeroCarousel.zig:140-262`, `:326-347`; `hero_tile_card.zig:132-157`, `:89-100`; `pane_elevation.zig:333-345`; trigger `Window.zig:8767-8772` | computed pixel count, inferred time: every carousel paint evaluates a `sqrt` and an `exp` per pixel over each visible tile plus its shadow reach, for all tiles, whichever one changed | cache the shadow/glow mask per tile size and state; paint only tiles the clip reaches |
| PA-W23 | P3 | `Window.zig:10409-10430`; `PaneDesk.zig:2598-2601`, `:2641-2656`, `:2678`; `PaneSidebar.zig:1031-1035`, `:5417-5423`; `desk_fade.zig:17` | computed rate, inferred time: about 20 full-window desk renders and 20 sidebar material rebuilds in the 350 ms after a switch between two differently shaded workspaces | fade by compositing two cached desks (or a compositor opacity), and keep the sidebar material across a fade |

### PA-W20: a single-window workspace switch rebuilds everything bound to the HWND (P2)

- **Where:** `App.showWorkspace` (`App.zig:8164-8184`) runs
  `ho.from.surrenderWindow(park)` then `ho.to.adoptWindow(...)`.
  `surrenderWindow` (`Window.zig:7675-7731`) destroys the sidebar
  (`:7702-7705`), the grab handle and the resize overlay, hides and
  re-parents every pane to the park host (`:7717-7718`), and calls
  `releaseWindowBound` (`:2690-2729`): the presenter (`:2694`), the chrome
  compositor host (`:2698`), `caption_mirror`, `caption_buf`, `strip_buf`,
  `desk_overlay`, `overlay_scratch`, `flat_desk`, the whole `pane_desk`
  (`:2706`: desk, scratch, glow, sheets), the strip-label fonts and DC, and
  `tab_font` / `pill_font` / `rename_font`. `adoptWindow` (`:7738-7813`) then
  builds the adopter's own: `chrome_comp.create` (`:7757`), `createTabFont`
  (`:7761`), a `SetParent` plus `reownPopups` and a DPI refresh per pane
  (`:7766-7768`), `SWP_FRAMECHANGED` (`:7771`), `showTabIndex` (a full
  layout), `syncPaneSidebar` (a new sidebar window), `invalidateChrome` and a
  `RedrawWindow(... RDW_ALLCHILDREN)` (`:7808`).
- **Mechanism:** the two controllers share one HWND of one size, but nothing
  size-keyed is handed over; `WindowBound` (`:7608-7618`) carries only six
  flags. Every pane of the surrendering workspace gives back its render
  targets (`parkPaneHidden`, `:7645-7653`) and every pane of the adopter
  re-creates them and redraws in full (the T2975 path audit-3 noted for a
  tab switch).
- **Cost:** inferred, not measured; no task file of the port (T3191-T3194)
  records a switch time. The parts are each known to be non-trivial: a desk
  render is a full-window gradient upscale (`PaneDesk.ensureDesk`), the
  sidebar material is PA-W11's rebuild, and a compositor host is a DComp
  target plus D2D resources. A workspace switch is the single-window
  counterpart of a tab switch, which pays none of the chrome half.
- **Fix:** measure the hand-off first (`drag_perf`-style QPC around
  `showWorkspace`). If it shows, extend `WindowBound` to carry the objects
  that are a function of the HWND and its size only: the chrome host, the
  caption/strip band buffers, the presenter, and the fonts (scale is the
  window's). The desk and sidebar are per-workspace in content (variant,
  rows) but their buffers could move too.
- **Risk:** medium; a handed-over buffer that still holds the old
  workspace's pixels must be marked invalid (`caption_mirror.valid = false`
  already exists for this).
- **Confidence:** high on what is destroyed and rebuilt (all three functions
  read whole); low on the magnitude.

### PA-W21: parked pane windows outlive a workspace that closes in place (P2)

- **Where:** a closing pane's HWND is parked in its controller's pool when
  the controller has a window (`Surface.parkWindow`, `Surface.zig:1554-1571`;
  `win.pane_pool.give`, `:1568`). The pool is read only by `take`
  (`:1577`); `pane_pool.zig`'s `drain` has no caller in the area (the two
  `pane_pool.` uses at `Surface.zig:1568` and `:1577` are the only ones).
  The pool's comment (`Surface.zig:1541-1543`) relies on the windows being
  "destroyed with the top-level if nothing takes it".
- **Mechanism:** in single-window mode the top-level is not destroyed when a
  workspace closes: `closeNow` (`Window.zig:22880-22903`) takes
  `closeWorkspace(self) == .in_place` (`:22885`) and runs `onDestroy`
  directly with no `DestroyWindow` (`:22897-22902`). `surrenderWindow`
  re-parents the workspace's live panes (`eachPane`, `:7717-7718`) but not
  its pooled HWNDs, which stay hidden children of the shared window. Once
  the controller is freed nothing holds their handles.
- **Cost:** computed bound: up to `pane_pool.capacity` = 16 HWNDs per closed
  workspace, for the life of the shared window (in single mode, the app's).
  They are filled only by panes closed one at a time while the workspace was
  on show (`mayPark` refuses while `win.closing`). Per-window weight is
  inferred: a hidden child window with a pixel format; audit-3 quoted T2989
  finding 9 parked pane windows after one 10-pane cycle.
- **Fix:** in `surrenderWindow` (or the in-place close), `DestroyWindow`
  every pooled HWND and empty the pool; a parked workspace cannot use them
  anyway (`takeParkedWindow` returns null without `win.hwnd`, `:1576`).
- **Risk:** low.
- **Confidence:** high on the missing drain and the no-`DestroyWindow` close
  path; medium on the per-window cost.

### PA-W22: every hero carousel paint shades every visible tile per pixel (P3)

- **Where:** `HeroCarousel.paint` (`HeroCarousel.zig:140-262`) creates a
  band-sized DIB section per paint (`:167`) and paints every tile that
  intersects the carousel region (`:242`, a test against the whole region,
  not the paint's clip). `paintTile` (`:326-347`) now calls
  `hero_tile_card.paintUnder` (`:346`), which walks the tile's rect grown by
  `reachPx + 1` on each side and for each pixel computes a rounded-rect
  distance (`hero_tile_card.zig:89-100`, one `@sqrt`) and
  `pane_elevation.shadowAlpha` (`pane_elevation.zig:333-345`, one `@exp`),
  twice on the selected tile (`:143-152`), then a float lerp per channel.
- **Who pays:** `heroOnSnapReady` invalidates one tile's rect when its
  snapshot changed (`Window.zig:8767-8772`), up to once per 150 ms per busy
  pane; that paint re-shades all visible tiles. The card's own footprint is
  shaded too although the picture then covers it (fully, at alpha 255, on the
  selected tile).
- **Cost:** pixel count computed: per tile `(w + 2r)(h + 2r)` with
  `r = ceil(12 * scale) + 1`; a 130 DIP carousel (T3131's default) at 100%
  with eight tiles on show is on the order of 10^5 shaded pixels per paint,
  four times that at 200%. Time inferred, not measured: a few milliseconds
  per paint in a release build, at up to ~7 paints a second while any tile's
  pane is producing output. Before T3279 a tile was one region, one
  `AlphaBlend` and one `RoundRect`.
- **Fix:** the shadow and glow depend only on tile size, state and scale:
  render the mask once per (size, state) and blend it; skip the interior;
  and skip tiles outside `GetClipBox`.
- **Risk:** low.
- **Confidence:** high on the per-pixel work and the all-tiles repaint;
  medium on the time.

### PA-W23: the workspace shade crossfade renders a full desk and a sidebar material per frame (P3)

- **Where:** `adoptWindow` arms `DESK_FADE_TIMER_ID` on the frame clock
  (`Window.zig:7809`); `deskFadeTick` (`:10409-10430`) sets a new
  `pane_desk.fade.keep` and calls `repaintPaneDesk` and `sb.repaint()`.
  `ensureDesk` treats a changed `fade` as a stale desk
  (`PaneDesk.zig:2598-2601`), renders two small gradients and blends them
  (`:2641-2656`), runs the full-size upscale, and bumps `desk_gen`
  (`:2674-2678`). A new `desk_gen` makes the sidebar's material cache stale
  (`PaneSidebar.zig:5417-5423`), so each frame also pays PA-W11's rebuild.
- **Cost:** rate computed: `desk_fade.duration_ms` = 350 (`desk_fade.zig:17`),
  one render per distinct `keep` value per frame, about 20 at 60 Hz. The
  blend itself is done at the small size (the comment at
  `PaneDesk.zig:2644-2646` says a sixteenth of the full-size cost); what
  stays per frame is the window-sized upscale, the desk blit and the sidebar
  material. Time inferred; audit-3 put one new-size desk at ~4 ms. Only when
  the two workspaces have different shades, the style is elevated and OS
  animations are on (`desk_fade.owed`, `:23-26`).
- **Fix:** keep the two full-size desks for the fade and blend them (one
  pass, no upscale), or fade a compositor layer where the desk is on one;
  exempt the sidebar material from `desk_gen` during a fade and rebuild it
  once at the end.
- **Risk:** low; bounded animation.
- **Confidence:** high on the per-frame path; medium on the time.

No other new finding survived. Candidates read and dropped as too small:
the activity roll-up per title change, the `fresh` pass in `paintTabBar`,
`holdParkedPanes` per layout, the settle-timer re-arm per `WM_SIZE`, the
three `GetAsyncKeyState` calls and one log line per window activation
(T3272), `markLayoutDirty` from tint and title, and the per-dial thread in
`IpcServer`.

## Summary

- **Fixed (all rounds):** 5 (PA-W02, PA-W04, PA-W05, PA-W06, PA-W17); new
  this round: PA-W17 (99efd0c58, T3095)
- **Fixed (incomplete):** 2 (PA-W01: remainder T3075; PA-W03: remainder
  T3117 and PA-W18/T3143)
- **Still open:** 12 (PA-W07 to PA-W16, PA-W18, PA-W19)
- **Changed:** 0
- **Wrong:** 0
- **New:** 4 (PA-W20 P2, PA-W21 P2, PA-W22 P3, PA-W23 P3)

Open P0/P1 in area W: none. PA-W17 was the last P1 and is fixed.

Everything open is P2 or P3: PA-W07 to PA-W16 (T2991-T3000), PA-W18 (T3143),
PA-W19 (T3144), the four new findings (no task yet), and the follow-ups
earlier fixes filed (T3075, T3116, T3117, T3118, T3119, T3120, T3122).

No fix commit since audit-3 introduced a regression that was found. Two
feature commits introduced new costs: the single-window hand-off (PA-W20,
PA-W21, PA-W23) and the hero tile cards (PA-W22).

Still unproven by measurement, per their own task files: the CPU drop of
PA-W02 (T3116) and of PA-W04 (T3118).

## Not done

- No build, test or measurement. PA-W20, PA-W22 and PA-W23 each need a
  number before their priority is settled.
- The viewer-pane changes (about half the area's diff: T3035-T3045, T3224,
  T3241, T3245) were not read (out of scope).
- The renderer side of a workspace hand-off (targets released on park,
  re-created on adopt) and the shared-device contention question under
  1cde0416f were not traced (area R).
- The restore half of `App.zig`'s diff (`restorePass`, `tickPacedRestore`,
  `restoreWindow`: T3137, T3187) was skimmed for timers and allocations only;
  it runs once per launch.
- Per-message allocation in the input and mouse paths was not re-read beyond
  the T3133 key-path hunks.
