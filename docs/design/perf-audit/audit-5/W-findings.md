# Audit-5, area W: the win32 frontend (T3316)

- **Date:** 2026-11-28
- **Commit audited:** 5eaac0760a (audit-4 was c9af15802)
- **Input:** audit-5, a re-audit of `../audit-4/W-findings.md` (PA-W01..PA-W23),
  with `../audit-1..3/W-findings.md` for each id's original description and
  `../audit-4.md` for the PA-id to task map
- **Scope:** `src/apprt/win32/` without the renderer presenters and the viewer
  panes

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. Nothing
was built, run or measured this turn. Every verdict is from reading the code
at HEAD and the diffs since audit-4; every cost is either quoted from a task
file or an earlier audit (and said to be) or computed/inferred from the code.

## Method

1. Read audit-4's file whole; took its 23 ids and its "Task action" column as
   the list to reconcile.
2. Task states from the task files' front matter
   (`docs/design/windows-parity-tasks/T*.md`, found by searching for each
   `PA-WNN`), not from commit messages. **No PA-W task closed since audit-4**:
   every one that was `todo` then is `todo` now, with `commits: []`. So there
   was no fix commit to read for this area.
3. `git diff --stat c9af15802 HEAD -- src/apprt/win32/` and
   `git log c9af15802..HEAD -- src/apprt/win32` (100 commits, about 60 of them
   outside the viewer and GTK work), then a per-file log for every file an
   open finding cites, to split "file unchanged, cite stands" from "file
   moved, re-read".
4. For each id: re-located the cited functions at HEAD by name, read them, and
   re-traced the mechanism.
5. For new findings, read the added lines of the commits that touch a paint,
   timer, poll, menu or allocation path: 7ce6815435 (T3761), 1198a9d55d
   (T2347), 53000ddfbc (T2333), b03b5a1e4e (T2239), 64bc8789b5 (T2618),
   0d17f51499 (T2335), 3bc0718992 (T2626), 733bf17846 (T2627), ddd2bd49c2
   (T2630), de91e717ed (T2122), 2cde7d60f7 (T2496), 02938fe529 (T1923),
   662847c217 (T1914), d6732bc4da (T3739), 0c0697d9bb (T1737), and the shell
   pickers f066635bf9 / acb452bfe7 / daa0609655 / aadf6d5bb6 (T3753, T3752,
   T3751, T3768); searched the whole area diff for new `Thread.spawn`,
   `SetTimer`, `FrameClock.arm`, `CreateFontW`, `CreateDIBSection`, registry
   and environment reads.

## What moved since audit-4

`git diff --stat c9af15802 HEAD -- src/apprt/win32/`: 150 files, +23826 /
-10092. Most of the volume is file splits with no behavior change
(`IpcHandlers.zig` into `ipc_*.zig`, T1782; `ConfirmDialog.zig`, T1785;
`SessionRoster.zig`, T1783; the viewer's TOC and feedback bar) and the viewer
(out of scope). In scope, by what it does to cost:

| Commit(s) | Task | PA | What it did in this area |
|---|---|---|---|
| 7ce6815435 | T3761 | none (perf) | the visibility poll now also measures how much of each window shows (`occlusion.windowView`, `uncoveredArea`) and sets a per-window pace (`Window.applyView`, `syncPace`); task quotes fifty busy cascaded windows going from ~11 cores to ~1.4. Touches PA-W07's tick |
| 1198a9d55d | T2347 | none (perf) | a title/activity tick re-reads the all-windows sidebar roster only in the window in use; others mark `roster_stale` and catch up on activation (`PaneSidebar.refreshScopesLive`) |
| 53000ddfbc | T2333 | none (perf) | the rail's resting tile rims are cached per (size, theme, hover) instead of computed per pixel per paint (`pane_sidebar_rim_cache.zig`, cap 8) |
| b03b5a1e4e | T2239 | none (perf) | a divider drag no longer re-cuts the hidden popup region of a wash that is on the pane's visual (`DimOverlay`, `dim_math.regionStep`) |
| 02938fe529 | T1923 | area V | a glass viewer's sheet is copied from the window's desk (`sheet_workers.glassSheetFromDesk`); uses the existing pool, so PA-W17's fix covers it |
| 3bc0718992 | T2626 | none (feature) | on the compositor chrome path the busy lights are their own window-sized layer over the glow layers (`PaneDesk.sendLights`, `chrome_comp.Host.lightsUpload`): PA-W25 |
| 662847c217 | T1914 | none (feature) | `pane_sidebar.max_items` 64 -> 512; every buffer sized on it grew eightfold: PA-W26 |
| f066635bf9, acb452bfe7, daa0609655, aadf6d5bb6, 33081a9db0 | T3753, T3752, T3751, T3768, T3750 | none (feature) | shell pickers in the hamburger menu, the "+" dropdown, the pane context menu and the palette, each reading the installed-shell catalog from disk when opened: PA-W24 |
| d6732bc4da | T3739 | area R | `pane_pool.contextHome`: a reused pane window that carries a pixel format keeps its context on itself. Pool shape (PA-W16, PA-W21) unchanged |
| 0d17f51499, 64bc8789b5 | T2335, T2618 | none (feature) | the unfocused dim stacks over the badge, bell frame and hover tint, or is drawn inside the pane with its banner |
| de91e717ed | T2122 | none (feature) | a UI Automation provider for tucked strips, created only on `WM_GETOBJECT`; raises no events |
| 67dbbb4a59 | T1866 | none | tooltips are unowned windows (`tooltip_window.zig`), destroyed by hand in `releaseWindowBound` |
| 0c0697d9bb | T1737 | none (tooling) | a per-pane frame-interval probe; compiled out of non-debug builds (`Surface.FramePacingProbe`) |

Files the open findings cite that are **byte-identical** to audit-4's (empty
per-file diff): `ReadonlyBadge.zig`, `pane_grab_handle.zig`,
`PaneGrabHandle.zig`, `HeroCarousel.zig`, `hero_tile_card.zig`,
`desk_fade.zig`, `size_burst.zig`, `strip_label_memo.zig`,
`src/os/reusable_thread.zig`. Changed but not at the cited mechanism:
`system_colors.zig` (one `pub`), `KeyStateIndicator.zig` (tooltip creation
only; cites after line 407 moved up 17), `pane_pool.zig` (`contextHome`
added), `sheet_workers.zig`, `activity_sample.zig`, `occlusion.zig` (see
PA-W07). `Window.zig` grew by about 70-760 lines above each cited site,
`App.zig` by 45-480, `Surface.zig` by about 80-270, `PaneSidebar.zig` by
about 35-270, `PaneDesk.zig` by about 120; every line number below is re-read
at HEAD.

## Verdicts

Confidence is **high** (cited lines read at HEAD, mechanism traced) unless a
row says otherwise. Costs are as audit-4 recorded them (inferred unless
marked) where the mechanism did not change.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-W01 | fixed (incomplete), remainder slightly larger | `src/os/thread_stack.zig:33-36`, `:48-50`; still default: the short-lived `.{}` spawns, now 27 files in the area carry one, e.g. `App.zig:11899`, `:12739`, `:13922` | 90e57ab70 as before. Three new short-lived default-stack spawns since audit-4: `SettingsWindow.zig:427` (theme catalog, T3664), `RelayWindowRestore.zig:123` (T3352), `update_install.zig:394` (T3429 retry). None is long-lived, so the cost is a 16 MB commit for each one's lifetime (computed from PA-W01's mechanism) | T2985 stays closed. Remainder is T3075 (todo, P2); add the three sites |
| PA-W02 | **fixed** (2fe99e84f, T2986), unchanged | `Window.zig:21793-21832` (`dropDeskCanvas`, `noteSizeStep`, `settleSizeBurst`), call `:24242`, timer `:24097`, kill `:24313`; `SIZE_BURST_TIMER_ID` in `window_timer_ids` `:7837-7843` | Same shape as audit-4 | T2986 closed. T3116 (todo) still owns the release measurement |
| PA-W03 | **fixed (incomplete)**, unchanged | gate `Window.zig:20441`, `chromeBandReach` `:20486-20517`; still over-wide: `invalidateTabBar` `:19694-19706`, `invalidateCaption` `:19717-19723` | Remainder unchanged: (a) PA-W18; (b) per-title measurement every strip paint (`:20821` via `measureTitleText` `:20015`), T3117; (c) a region and a brush per tab per strip paint (`:20970`, `:20991`), PA-W14's family. New in `paintTabBar`: one chevron glyph beside "+" (`:20837`, T3768); `new_tab_shell.offered` is two field reads | T2987 closed; T3117 (todo), T3143 (todo) open |
| PA-W04 | **fixed** (f51045ceb, T2988), unchanged | `Window.zig:19540` (`onPaneTitleChanged`), `invalidateTuckedStripName` `:15386`; memo field `:1208`; `strip_label_memo.zig` unchanged | Unchanged shape | T2988 closed. T3118 (todo) owns the unproven CPU criterion |
| PA-W05 | **fixed** (ad3cfa61d, T2989), unchanged | `scripts/perf-baseline.ps1:819`, `:856`, `:870` | Tooling only; the three functions are present at HEAD at the same lines. Not re-read line by line | T2989 closed. T3119, T3120 (both todo) |
| PA-W06 | **fixed** (c23205794, T2990), unchanged | `activity_sample.zig:157`, pool `:167`; `ActivityMonitor.zig:548` | `activity_sample.zig` gained only a debug test seam (T1748) | T2990 closed. T3122 (todo, P2) |
| PA-W07 | **changed** (still open; each tick does more, and buys more) | `App.zig:1165` (set once), `:14997-15000`, `pollVisibility` `:1567-1576`; `occlusion.zig:172-217` (`windowView`), `:58-98` (`uncoveredArea`); `Window.zig:5153-5177` (`applyView`, `syncPace`) | `VISIBILITY_TIMER_ID` still appears only at `App.zig:363`, `:1165`, `:14997`; no `KillTimer`. Since T3761 (7ce6815435) each 250 ms tick also sums the uncovered area per window (no early exit on "some of it shows", which `fullyCovered` had only for the fully-covered case, so the same loop) and walks the active tab's panes in `syncPace` (`Surface.setPace` `Surface.zig:2082-2089` returns on an unchanged pace). Size change is small (inferred): one more pass over at most 64 rects and one compare per pane per window per tick. The poll is now load-bearing for the pace cap, so "stop the timer when nothing can change" has to keep the pace fresh too | T2991 unchanged in priority; update its line refs and note the pace dependency |
| PA-W08 | still open | `pane_grab_handle.zig:206` (`poll_ms` = 50); `PaneGrabHandle.zig:154`, `:141`, `:232` | files unchanged | T2992 unchanged |
| PA-W09 | still open | `Window.zig:1751-1753`, `chromePalette` `:1767-1773`, callers `:8234`, `:8260`, `:15552`, `:16436`, `:20107`, `:20229`, `:20733`; `system_colors.zig:146-153`, `:423-427` | `usesLightTheme` still opens, queries and closes the key per call; `chromePalette` still calls it per call (`:1772`) | T2993 unchanged; update line refs |
| PA-W10 | still open | `Window.zig:12613-12646`: `buildWith(gpa, ...)` `:12634`, `defer built.deinit(gpa)` `:12635`; an arena per call in `noteStackRows` `:12653-12658` (called at `:12622`) | unchanged shape; 26 call sites of `stackGrid()`/`stackGridOfTab(` (24 at audit-4) | T2994 unchanged; update line refs |
| PA-W11 | still open | `PaneSidebar.zig:5683-5687` (cache stale on a new `desk_gen`, then `cache.release()`), `:1065-1069` (`deskPainted`) | Same mechanism. The rim cache (T2333) is a different cache and does not cover the card material | T2995 unchanged; update line refs |
| PA-W12 | still open | `Window.zig:14921-14933` (two brushes, two `stripFont` fonts per `paintStripBandsAndNames`); also `:11113`, `:11439`, `:11626`; `stripFont` `:15112-15131`; cached pair `:15356-15357` | unchanged shape. `stripFace` (T2519) now picks the two brush colors; still two `CreateSolidBrush` per paint | T2996 unchanged; update line refs |
| PA-W13 | still open | `KeyStateIndicator.zig:550-554` (`tick`), `:310-319`, `:644`, DIB `:671`, `:706`; `ReadonlyBadge.zig:175`, `:194-203`, `:208`, DIB `:275` | `ReadonlyBadge.zig` unchanged; `KeyStateIndicator.zig` changed only in tooltip creation | T2997 unchanged; update line refs |
| PA-W14 | still open | `Window.zig:20631-20636` (`fillEllipse`: brush + pen), `:20681-20683` (strip button: region + brush), `:20970`, `:20991` (per tab), `:20254-20286`; `PaneSidebar.zig:2474`, `:2482`, `:2494-2496`; `BannerOverlay.zig:1664`, `:1713-1714`, `:2217` | per-call create/delete, unchanged | T2998 unchanged; update line refs |
| PA-W15 | still open | `Surface.zig:991`, `:994` (two `CreateEventW`), early exit `:1002`, first errdefer `:1043`; closed only in `deinit` `:1577-1584`; `Window.zig:4289-4290` (no destroy on a failed init) vs the guarded siblings `:4719-4722`, `:18149-18152` | unchanged shape | T2999 unchanged; update line refs |
| PA-W16 | still open | `Surface.zig:1711-1717`, `parkWindow` `:1723-1740`, `takeParkedWindow` `:1744-1766`; `pane_pool.zig:30` (`capacity`), `:148` (`drain`) | `parkWindow` unchanged. T3739 changed only where the next pane's context goes (`:1095`) | T3000 unchanged |
| PA-W17 | **fixed** (99efd0c58, T3095), unchanged | `sheet_workers.zig:47`; `src/os/thread_stack.zig:48-50` | Still the only `Thread.Pool` in the area; the new `glassSheetFromDesk` (T1923) uses the same pool | T3095 closed |
| PA-W18 | still open | `Window.zig:19694-19706`, `:19717-19723` (both `right = 10000`); gate `:20441`, `:20505-20515`; `mergedChrome` `:2932` | `invalidateTabBar()` now has 23 references (21 at audit-4) | T3143 (todo, P2) unchanged |
| PA-W19 | still open | `Surface.zig:3170` (free, via `freeSnapBufferLocked` `:3203-3207`), `:2983-2986` (re-alloc); driver `Window.zig:8902`, `:9146`, `HERO_SNAP_INTERVAL_MS` = 150 `:346` | unchanged | T3144 (todo, P2) unchanged |
| PA-W20 | still open | `Window.zig:7916-7973` (`surrenderWindow`), `:2798-2843` (`releaseWindowBound`), `:7979-8052` (`adoptWindow`); `WindowBound` `:7849-7860` (six fields); `App.zig:8373` (`showWorkspace`) | Same list destroyed and rebuilt; `releaseWindowBound` now also destroys the unowned tab tooltip (T1866). Each rebuilt sidebar is also larger (PA-W26) | T3304 (todo, P2) unchanged; update line refs |
| PA-W21 | still open | `Surface.zig:1723-1740`, `:1744-1746`; `Window.zig:23660`, `:23680-23684`, `:7958-7959`; `pane_pool.zig:148` | `drain` still has no caller in the area (searched `Window.zig`, `Surface.zig`, `App.zig`); the in-place close still runs `onDestroy` without `DestroyWindow` | T3305 (todo, P2) unchanged; update line refs |
| PA-W22 | still open | `HeroCarousel.zig:140-262`, `:326-347`; `hero_tile_card.zig:132-157`; `pane_elevation.zig:333`; trigger `Window.zig:8980` (`heroOnSnapReady`) | the two files are byte-identical | T3306 (todo, P3) unchanged |
| PA-W23 | still open | `Window.zig:10700-10721` (`deskFadeTick`), arm `:8050`; `PaneDesk.zig:2721-2726`, `:2769-2781`, `:2799`; `PaneSidebar.zig:1065-1069`, `:5683-5687`; `desk_fade.zig:17` | unchanged shape | T3307 (todo, P3) unchanged; update line refs |

No item is **wrong**. One is **changed** (PA-W07, in size and in what depends
on it). No item was fixed since audit-4.

## Fix-commit review

No PA-W task closed since audit-4, so there is no PA fix commit to review.
The perf commits that landed in the area outside the PA list:

### 7ce6815435 (T3761): no regression found; PA-W07 now carries more

- `pollVisibility` calls `applyView` for every window with an HWND. For a
  window whose state did not change this is `applyOcclusion` (returns at
  `!was` when it stays visible, `Window.zig:5187`) and `syncPace` (one
  compare per pane).
- `occlusion.paceDisabled` caches its environment read (`occlusion.zig:119-127`).
- `inUseChanged` (`Window.zig:10622-10628`) repaints the sidebar on every
  activation or visibility flip; that predates this commit (T2909).

### 1198a9d55d (T2347), 53000ddfbc (T2333), b03b5a1e4e (T2239): all remove work

- T2347: only the activated window's all-windows sidebar re-reads per tick.
- T2333: the cache holds at most 8 tile-sized DIBs per sidebar
  (`pane_sidebar_rim_cache.zig`, `default_cap`), drained in `destroy`.
- T2239: a wash on the pane's visual owes its popup region instead of
  cutting it on each move.

### 3bc0718992 (T2626): one new memory cost on the compositor path (PA-W25)

### 662847c217 (T1914): one new per-window memory cost (PA-W26)

## New findings

| PA | P | Where | Cost | Fix |
|---|---|---|---|---|
| PA-W24 | P3 | `SettingsWindow.zig:1600-1628`; `settings_controls.zig:332-341`; callers `Window.zig:22386-22391`, `:22633`, `Surface.zig:4737`, `:4633`, `:6902-6907` | computed count, inferred time: every hamburger-menu open, "+" dropdown, pane right-click and palette open re-reads PATH three times and stats one file per PATH directory per common shell not found early, on the GUI thread | cache the catalog; refresh it on a worker or on `WM_SETTINGCHANGE` |
| PA-W25 | P3 | `PaneDesk.zig:2622-2661` (`sendLights`), `:384`; `chrome_comp.zig:1634-1682`; `Window.zig:16065-16075` | computed: while any busy light is lit on a compositor-chrome window, a window-sized CPU buffer and a window-sized composition surface are held (8.3 MB each at 1920x1080) | size the layer to the rings' strips, or one small surface per ring |
| PA-W26 | P3 | `pane_sidebar.zig:580`; `PaneSidebar.zig:673`, `:724`, `:305`, `:657` | computed: each sidebar object carries `tip_text` of 512 x 192 UTF-16 units = 196,608 bytes (24,576 before), plus two more 512-entry arrays | allocate tip text per listed row, or keep a small fixed set and spill |

### PA-W24: every menu that lists shells walks PATH on the GUI thread (P3)

- **Where:** `SettingsWindow.installedShells` (`SettingsWindow.zig:1618-1628`)
  calls `shellProblem` once per entry of `settings_controls.common_shells`
  (three: `pwsh.exe`, `powershell.exe`, `cmd.exe`,
  `settings_controls.zig:187-191`). Each call reads `PATH` and `PATHEXT`
  from the environment into fresh heap copies (`SettingsWindow.zig:1601-1604`)
  and then `settings_controls.shellProblem` stats `<dir>\<program>` for each
  PATH directory until one exists (`settings_controls.zig:332-341`; the
  names carry an extension, so `hasExtMatch` adds nothing). Then up to three
  stats for Git Bash (`:1632-1643`) and a registry enumeration of the WSL
  distros (`wsl_distros.zig:74-98`: one `RegOpenKeyExW` + two
  `RegQueryValueExW` per distro).
- **Who pays:** every one of these, synchronously, before the menu shows:
  the hamburger / menu bar popup (`Window.openMenuBarAt`,
  `Window.zig:22386-22391`), the "+" dropdown (`:22633`), a right-click on a
  terminal pane (`Surface.zig:6902-6907`, through
  `pane_restart.installedChoices`, `pane_restart.zig:77-83`), every command
  palette open (`buildPaletteJumpEntries`, `Surface.zig:4737`), and the
  palette's shell step (`:4633`).
- **Cost:** count computed: a shell that is not installed (PowerShell 7 on a
  stock box) costs one stat per PATH directory, so with 40 PATH entries about
  40-45 `statFile` calls, 6 environment copies and the registry walk per
  open. Time inferred, not measured: low single-digit milliseconds on local
  disks; unbounded when PATH holds an unreachable network or removable
  directory, where each stat waits on the redirector with the GUI thread
  blocked. Before T3752/T3753 a right-click and the hamburger read no files.
- **Introduced by:** acb452bfe7 (T3752, context menu and palette rows),
  f066635bf9 (T3753, hamburger and "+" right-click), daa0609655 (T3751,
  palette step), aadf6d5bb6 (T3768, the chevron reuses `:22633`). Features,
  not a regression from a fix.
- **Fix:** keep one catalog on `App`, built on a worker at first use and
  dropped on `WM_SETTINGCHANGE` (an environment change broadcasts one) and on
  a timer of minutes; menus read the cached list. "A shell installed while
  the app runs is in the next one" (the comment at `Window.zig:22384-22385`)
  then becomes "in the one after".
- **Risk:** low.
- **Confidence:** high on the path and the count; medium on the time.
- **Cross-area:** none known.

### PA-W25: a lit busy light holds a window-sized layer twice on the compositor chrome path (P3)

- **Where:** `Window.syncLightsApart` (`Window.zig:16065-16075`) turns
  `pane_desk.lights_apart` on when the desk is on the compositor visual, the
  glow is on compositor layers, the window is opaque and the host has a desk
  visual. `PaneDesk.sendLights` (`PaneDesk.zig:2622-2661`) then keeps
  `lights_px` at `w * h` u32 for the whole composed desk (`:2636-2642`,
  zero-filled once), and `chrome_comp.Host.lightsUpload`
  (`chrome_comp.zig:1634-1682`) creates a `w` x `h` premultiplied
  composition surface for it (`:1652-1663`).
- **Mechanism:** the rings cover thin strips along one card's edge
  (`busy_light.strips`), but the layer and its backing buffer are the size of
  the desk. Per frame only the strips are cleared, re-laid and uploaded
  (`:2644-2658`), so the per-frame cost is fine; the standing cost is the
  two full-size allocations.
- **Cost:** computed: 4 bytes per desk pixel in process memory and the same
  again as a composition surface: 8.3 MB + 8.3 MB at 1920x1080, 33 MB + 33 MB
  at 3840x2160, per window with at least one lit ring. A ring is lit while a
  pane reports itself busy, which for an agent pane is most of a working
  session. Both are released when the last ring goes out (`:2627-2633`,
  `lightsHide`). Reach: only windows with a chrome compositor host, which is
  opt-in today (`chrome_comp.enabled`, the `GHOZTTY_COMP_CHROME` knob,
  `chrome_comp.zig:71`, `:88-91`); the default GDI path draws rings into the
  desk and pays nothing here. That is why this is P3 and not P2; it becomes
  P2 the day the host is on by default.
- **Introduced by:** 3bc0718992 (T2626). A feature fix, not a PA fix.
- **Fix:** give each ring its own visual sized to its card's bounding strips
  (the glow layers already work per card), or keep one layer but back it
  with a surface cropped to the union of the lit cards.
- **Risk:** low to medium (visual ordering against the glow layers is what
  T2626 was about).
- **Confidence:** high on the sizes; medium on how long a ring stays lit.
- **Cross-area:** touches area R/M's GPU-memory accounting; no existing id
  found for it.

### PA-W26: each pane sidebar carries 512 fixed slots of tooltip text (P3)

- **Where:** `pane_sidebar.max_items` went from 64 to 512
  (`pane_sidebar.zig:580`, T1914). `PaneSidebar` is a heap object
  (`PaneSidebar.zig:822`) with inline arrays sized on it:
  `tip_text: [max_items][tips.tip_cap]u16` (`:673`, `tip_cap` = 192,
  `pane_sidebar_tips.zig:47`), `fades: [max_items]FadeSlot` (`:724`), and
  the optional `drag: ?DragMotion` (`:657`) whose `shifts` is
  `[max_items]RowShift` (`:305`).
- **Cost:** computed: `tip_text` alone is 512 x 192 x 2 = 196,608 bytes per
  sidebar, up from 24,576; the other two add roughly 10-25 KB (element sizes
  inferred, not computed). So about 0.2 MB of committed heap per window that
  shows a sidebar, of which a ten-pane window uses under 4 KB. Fifty windows
  (T3761's scene) is about 10 MB. In single-window mode the object is freed
  and re-allocated on every workspace switch (PA-W20). The pages are not
  touched until a row's tip is written (`:6218-6221`), so working set grows
  only with rows listed; the commit charge is paid up front.
- **Introduced by:** 662847c217 (T1914). Its comment accounts for the
  drag resolver's stack arrays (about 330 KB, `Window.zig:6368-6376`) but
  not for the sidebar object.
- **Fix:** hold tip text in a list grown to the roster's length (the roster
  is already an `ArrayListUnmanaged`, `:545`), or build a row's tip when the
  tooltip asks for it (`TTN_GETDISPINFO`) instead of storing all of them.
- **Risk:** low.
- **Confidence:** high on the size; this is small, filed because it is a
  clean eightfold step from one constant.

No other new finding survived. Candidates read and dropped as too small or
not on a shipping path: `syncPace` per poll, the chevron in `paintTabBar`,
`seatDimOverChrome`'s z-order walks (only a popup wash pays), the strip UIA
provider (built on demand, no events), the frame-pacing probe (debug builds
only), `debugGlowStall` (debug builds only), `RELAY_SID_TIMER_ID` (500 ms,
bounded by a tick count, killed at `App.zig:8902`), the `Layout` struct's
four zero-filled 512-entry arrays per sidebar layout
(`pane_sidebar.zig:669-677`, about 4.5 KB of fill), and the three new
default-stack worker spawns (counted under PA-W01).

## Summary

- **Fixed (all rounds):** 5 (PA-W02, PA-W04, PA-W05, PA-W06, PA-W17); new
  this round: none
- **Fixed (incomplete):** 2 (PA-W01: remainder T3075, three more sites;
  PA-W03: remainder T3117 and PA-W18/T3143)
- **Still open:** 15 (PA-W08 to PA-W16, PA-W18 to PA-W23)
- **Changed:** 1 (PA-W07: the poll does more per tick and the pace cap now
  depends on it)
- **Wrong:** 0
- **New:** 3 (PA-W24 P3, PA-W25 P3, PA-W26 P3)

Open P0/P1 in area W: none.

Everything open is P2 or P3: PA-W07 to PA-W16 (T2991-T3000), PA-W18 (T3143),
PA-W19 (T3144), PA-W20 (T3304), PA-W21 (T3305), PA-W22 (T3306), PA-W23
(T3307), the three new findings (no task yet), and the follow-ups earlier
fixes filed (T3075, T3116, T3117, T3118, T3119, T3120, T3122). None of them
moved since audit-4: in a week of 100 commits to the area, no PA-W task was
picked up.

No fix commit since audit-4 introduced a regression that was found. Three
feature commits introduced new costs: the shell pickers (PA-W24), the busy
lights' compositor layer (PA-W25) and the 512-pane roster cap (PA-W26).

Still unproven by measurement, per their own task files: the CPU drop of
PA-W02 (T3116) and of PA-W04 (T3118).

## Not done

- No build, test or measurement. PA-W24's time and PA-W20's switch cost each
  need a number before their priority is settled.
- The viewer-pane changes and the file splits (`ipc_*.zig`,
  `confirm_dialog_*.zig`, `session_roster_*.zig`) were not read beyond
  confirming they are moves.
- The renderer side of T3761 (`src/renderer/pace.zig`, `Thread.zig`) and of
  T2622 / T3739 was not traced (area R).
- `SettingsWindow.zig` (+517) was read only at the shell and font pickers
  and the theme worker spawn; the font menu's DirectWrite enumeration
  (`font_families.load`, T3766) runs when the Settings page asks and was not
  costed.
- The sidebar fold transition (96106560d6, T2349) and the see-through
  backdrop (32f7f31001, T1905) were skimmed for timers and allocations only.
- `App.zig`'s restore and relay-manifest hunks (T3352, T3389, T3755) run
  once per launch or sign-in and were not read line by line.
