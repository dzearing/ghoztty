# Audit-2, area W: the win32 frontend (T3072)

- **Date:** 2026-11-14
- **Commit audited:** 879fba35a
- **Input:** `../audit-1/W-findings.md` (PA-W01..PA-W16 as of 3e92e7fbf) and
  the W table in `../audit-1.md`

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. Nothing
was built, run or measured this turn: every verdict is from reading the code
at HEAD, and every cost below is carried from audit-1 or computed from the
code, never re-measured.

## Scope note: what moved since audit-1

`git diff --stat 3e92e7fbf..HEAD -- src/apprt/win32` is six one-line changes,
all from the PA-W01 fix (90e57ab70): `CompDragThread.zig`, `FrameClock.zig`,
`IpcServer.zig`, `QuickTerminalSlider.zig`, `WindowPresenter.zig` and
`activity_sample.zig` each gained an import and swapped `.{}` for
`thread_stack.config`. `Window.zig`, `PaneDesk.zig`, `PaneSidebar.zig`,
`Surface.zig`, `App.zig` and every overlay are byte-identical to audit-1, so
audit-1's line numbers still hold for them (only `activity_sample.zig` moved,
by one line). The renderer commits (T2968 29302f08c, T2974 6711c4e45) touch
only `src/renderer/` and `src/Surface.zig`; no frontend code path changed
with them.

## Verdicts

Confidence is high (cited lines read at HEAD) unless a row says otherwise.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-W01 | fixed, incomplete | `src/os/thread_stack.zig:33-36`; `src/os/reusable_thread.zig:60` (pool default), `:116` (spawn) | 90e57ab70: pools (renderer, io, io-reader, viewer-worker) and FrameClock, IpcServer, CompDragThread, QuickTerminalSlider, WindowPresenter, activity sampler, client_mux pump and the four connection threads spawn with a 64 KB commit. Not covered: ~30 short-lived `.{}` spawns (T3075) and the process-lifetime `std.Thread.Pool` in `sheet_workers.zig:46` (PA-W17, in no task) | T2985 stays closed; add PA-W17 to T3075 or file it |
| PA-W02 | still open | `Window.zig:22473` (only non-test `liveResize(true)`), `PaneDesk.zig:1110-1112`, `:1127-1132` | Unchanged code. `canvas()` returns the exact size when `live` is null, so a non-modal step still takes a new desk | T2986 unchanged; re-measure the resize-phase CPU before using baseline-1's 13.8% / 31.0% as the bar (see below) |
| PA-W03 | still open | `Window.zig:18978-18979`; DIBs `:18619/:18633`, `:19207/:19227`; region `:19462` | Both painters run unconditionally in `paintChromeRaw`; each creates a DC and a full-width DIB section per call | T2987 unchanged |
| PA-W04 | still open | `Window.zig:18101-18103`, guard at `:18112-18114` | Whole-window `InvalidateRect(wh, null, 0)` still sits above the unchanged-title return | T2988 unchanged |
| PA-W05 | still open | `scripts/perf-baseline.ps1:264-268` | The script changed since audit-1 only to add `-BusyText cjk` (T2973). `wakeups_per_s` is still one process-wide context-switch delta; no per-thread or per-type breakdown | T2989 unchanged; its "unexplained" counts (12 threads, +10 handles a cycle) predate T2968 and should be re-read from a fresh baseline |
| PA-W06 | still open, smaller | `activity_sample.zig:152` (spawn), `:145-146` (join) | Still one OS thread per sample. The spawn now uses `thread_stack.config`, so the 16 MB transient commit T2990 mentions is gone; the per-thread NVIDIA strand is what remains | T2990: drop the "plus a transient 16 MB commit" clause; line is now `:152` |
| PA-W07 | still open | `App.zig:1065`, `:1467-1475`; `occlusion.zig:141-156`; `Window.zig:4729-4731` | Timer set once, never killed (`VISIBILITY_TIMER_ID` appears only at `:342`, `:1065`, `:13836`) | T2991 unchanged |
| PA-W08 | still open | `pane_grab_handle.zig:209-214`; `PaneGrabHandle.zig:153-156` | `keepPolling` returns true first thing when `shown` | T2992 unchanged |
| PA-W09 | still open | `Window.zig:1614-1620`; `system_colors.zig:146-153`, `:423-438`; callers `:14256`, `:18649`, `:19248` (also `:15089`, `:18771`) | `usesLightTheme` opens, queries and closes the key on every call, no cache | T2993 unchanged |
| PA-W10 | still open | `Window.zig:11593-11594` | `buildWith(gpa, ...)` plus `defer built.deinit(gpa)` on every `stackGridOfTab` call | T2994 unchanged |
| PA-W11 | still open | `PaneSidebar.zig:5388-5392`, `:5404`; `:1031-1034` | `cache.release()` on any w/h/desk_gen change, then a new DIB section | T2995 unchanged |
| PA-W12 | still open | `Window.zig:13764-13776`, `:13912`; also `:10118`, `:10423`, `:10610`; cached pair `:14152-14156` | Two brushes and two `stripFont` fonts created and deleted per call | T2996 unchanged |
| PA-W13 | still open | `KeyStateIndicator.zig:567-571`, `:310-319`, `:676-690`; `ReadonlyBadge.zig:175`, `:194-203`, `:208`, `:226-235` | `tick` checks only `visible`/`layout.hidden`; `SetWindowPos` is unconditional; `measureLabel` does `GetDC(null)` per update | T2997 unchanged |
| PA-W14 | still open | `Window.zig:19126-19128`, `:19174-19176`; `PaneSidebar.zig:2350`, `:2358`, `:2370-2372`; `BannerOverlay.zig:1657`, `:1706-1707`, `:2210` | Per-call create/delete. `brush_cache` is imported by 12 files, none of them these painters (`Surface.zig` and `App.zig` import it for other uses) | T2998 unchanged |
| PA-W15 | still open | `Surface.zig:904`, `:907`, first errdefer `:955`; `Window.zig:3893-3894` vs the guarded sibling `:4308-4312` | No errdefer closes either event; the new-tab path has no `alloc.destroy` on a failed init | T2999 unchanged |
| PA-W16 | still open | `Surface.zig:1531-1534`, `parkWindow` `:1541-1559`, helper `:1003-1004`; `pane_pool.zig:28` | `parkWindow` refuses only presenter panes, `own_layer`, a closing window or a wrong parent; a helper-path pane is still parked | T3000 unchanged in shape; its "9 of the +60 USER objects" figure predates T2968 and needs a fresh cycle sample. T2983 (PA-R17) is still todo, so the pairing note stands |

No item is **wrong**. Two are **changed** in size only (PA-W06, and the cost
figures quoted by PA-W02, PA-W05 and PA-W16).

## PA-W01: fixed, and what the fix left

**The fix is real.** `thread_stack.config` is `.{ .stack_size = 64 * 1024 }`
on Windows (`src/os/thread_stack.zig:30-36`). It relies on Windows keeping
the PE header's 16 MB reserve when the commit asked for is below it; the
module's own tests measure both halves (`:91-104` commit under 1 MB with a
reserve of 16 MB or more, `:106-125` a 4 MB deep frame still grows).
`reusable_thread.Pool.spawn_config` defaults to it (`reusable_thread.zig:60`)
and `:116` spawns with it, so every pooled pane thread (renderer and io at
`src/Surface.zig:45-46`, io-reader at `src/termio/Exec.zig:36`) and the
viewer worker pool (`worker_pool.zig:23`) are covered.

**Spawn-site sweep at HEAD** (every `std.Thread.spawn`, `std.Thread.Pool`
and `CreateThread` in the app image outside `src/remote/agent`):

- Covered: `CompDragThread.zig:147`, `FrameClock.zig:123`, `IpcServer.zig:269`,
  `QuickTerminalSlider.zig:116`, `WindowPresenter.zig:228`,
  `activity_sample.zig:152`, `src/remote/client_mux.zig:233`,
  `src/remote/connection.zig:1364/1371/1377/1387`, `relay_hosting.zig:173`,
  `relay_revoke_pending.zig:346`, `relay_suspend.zig:600`.
- Explicit already: `src/crash/windows.zig:131` (raw `CreateThread` with
  `report_stack_bytes`).
- Still `.{}`, short-lived, owned by T3075 (todo, P2): `App.zig:10759`,
  `:11599`, `:12761`; `AgentIntegration.zig:155/171/359/488`;
  `AgentIntegrationsDialog.zig:667`; `ArpOrphanSweep.zig:61`;
  `DirectoryProbe.zig:155`; `LocalAgent.zig:245`;
  `MachineConnectionPool.zig:577`; `PathInstaller.zig:45`;
  `RelayAccountRow.zig:89`; `RemoteReconnect.zig:511/909`;
  `RestoreAllLocal.zig:155`; `RestoreAllRelay.zig:304/472`;
  `SessionRoster.zig:420`; `ShareMachineRow.zig:150/357`;
  `activity_dial.zig:189`; `activity_machines.zig:219`;
  `activity_probe_conn.zig:415`; `url_scheme.zig:124`;
  `ViewerFeedbackSend.zig:202`; `src/os/open.zig:74`;
  `src/crash/sentry.zig:72`.
- Still default and NOT in any task: `sheet_workers.zig:46` (PA-W17 below).
- Test-only, no action: `gui_pump.zig:140`, `PaneDesk.zig:3014`,
  `strip_face.zig:767`, `ViewerPane.zig:11429/11539/12306`.

**A correction for T3075's text.** It lists "ViewerPane serve threads" among
the transient workers. The three `ViewerPane.zig` sites are the `start`
methods of `TestPage` (`:11390`) and its sibling fixtures, which sit among
the file's test blocks (confidence medium: read the spawn sites and the
struct names, did not trace every caller). They do not need converting.

**The audit T3075 plans would miss PA-W17.** Its source audit is specified
as failing on a new `std.Thread.spawn(.{`. A `std.Thread.Pool` never spells
that string. The check should also flag `Pool.init` without `stack_size`.

## Cost figures that need a fresh baseline

- **PA-W02.** The mechanism is untouched, but the "13.8% release / 31.0%
  debug" resize-phase CPU that T2986's second criterion compares against
  was measured before T2967 (full-frame redraw after ~100k frames), T2972
  (changed-cell uploads) and T2974 (storage trim) changed what the renderer
  does on each resize step. The desk's ~4 ms a step is now an unknown share
  of a different total. Take baseline-2's resize phase as the bar.
  T2974 does not add work inside a burst: its trim waits for one second of
  stillness (commit message and `src/renderer/storage_trim.zig`, not
  re-derived here; confidence medium).
- **PA-W05.** T2968 took ten panes from 611 threads to 116 (its commit
  message). The "12 threads and +10 handles per cycle that no frontend code
  explains" was most likely the per-pane device, so the unexplained
  remainder is probably much smaller. The tooling gap itself is unchanged.
- **PA-W16.** Same reason: the USER-object residue after a cycle was
  measured with per-pane devices alive.

## New findings

| PA | P | Where | Cost | Fix |
|---|---|---|---|---|
| PA-W17 | P1 | `src/apprt/win32/sheet_workers.zig:46`; zig 0.15.2 `lib/std/Thread/Pool.zig:30`, `:59` | computed: up to 4 threads x 16 MB = 64 MB private, for the life of the process, from the first desk compose of 64k px or more | pass `.stack_size = thread_stack.config.stack_size` to `pool.init` |

### PA-W17: the sheet worker pool commits 16 MB a worker, forever (P1)

- **Where:** `sheet_workers.zig:46`:
  `pool.init(.{ .allocator = std.heap.smp_allocator, .n_jobs = want })`,
  with `want = @min(cpus -| 1, max_workers)` and `max_workers = 4` (`:33`,
  `:44`). `std.Thread.Pool.Options.stack_size` defaults to
  `std.Thread.SpawnConfig.default_stack_size` (`Pool.zig:30`) and is handed
  straight to each worker's spawn config (`Pool.zig:59`). That is the same
  16 MB-as-initial-commit path PA-W01 described.
- **When it is paid:** the pool is created by `pool_once` on first use
  (`:53`, `:130`) and never torn down ("lives for the process", `:13-14`).
  The desk's ordinary compose passes `.auto` (`PaneDesk.zig:1908`), and
  `.auto` calls `sheet_workers.shared()` as soon as the rects to compose
  cover `min_parallel_px` = 65,536 px (`PaneDesk.zig:2039-2041`,
  `sheet_workers.zig:26`), about a 256 x 256 area. `strip_face.zig:256`
  and the glass viewer sheet (`ViewerPane.zig:7126`) reach it too. So on
  the elevated pane style any window larger than a thumbnail pays it on an
  early paint.
- **Cost:** computed, not measured. 4 x 16 MB = 64 MB of committed,
  untouched stack on any box with five or more CPUs; 16 MB a worker below
  that. It is steady-state private bytes, not a transient, which is why it
  rates above T3075's P2 short-lived threads. T2985's own A/B idle figure
  (201.7 MB private after the fix) would include it if the idle window had
  composed a desk; that was not checked.
- **Why audit-1 missed it:** audit-1 searched for `stack_size` overrides
  and `std.Thread.spawn` sites; the pool spawns inside std.
- **Fix:** one field on the `init` call. The workers run pure per-row
  pixel arithmetic, so the 64 KB commit with the 16 MB reserve is ample.
  Add a `Pool.init` clause to T3075's source audit.
- **Risk:** none beyond PA-W01's.
- **Confidence:** high on the mechanism (both files read); medium on "paid
  by every normal window", which rests on the `.auto` call site being the
  common compose path.

No other new finding survived. Nothing in the frontend changed since audit-1
apart from the six spawn lines, so there is no new code to audit; the sweep
below re-read the areas audit-1 called clean.

## Regressions from fix commits

None found in area W. 90e57ab70 changes only the spawn config at each site.

## Checked and found clean

- **The visibility tick body** (`App.zig:1467-1475`, `refreshLowPower`
  `:1480-1485`): returns before the config reload unless the effects
  decision flipped; `occlusion.disabled()` is cached (`occlusion.zig:90-98`).
  The cost stays what PA-W07 says, no more.
- **Short timer constants** in `App.zig` and `Window.zig` (250 ms layout
  sync debounce, 400 ms retry, 150 ms hero snap, 16 ms hero, focus-glow and
  stack-slide ticks, 250 ms sidebar sync): the same set audit-1 reviewed;
  none is new and none was changed.
- **No frontend thread uses a raw Win32 thread or thread-pool API**
  (`CreateThread`, `QueueUserWorkItem`, `CreateThreadpool*`,
  `RegisterWaitForSingleObject`) in `src/apprt/win32`, `src/os`,
  `src/termio` or `src/renderer`; the only raw `CreateThread` is the crash
  reporter's, with an explicit size.
- **The non-Windows spawn path** (`reusable_thread.zig:46`) keeps `.{}` on
  purpose; pthread stacks commit lazily.

## Not done

- No build, test or measurement. Baseline-2 has to supply every number.
- New-finding search was limited to the thread sweep, the visibility tick
  and the timer constants. Per-message allocation in the input and mouse
  paths, and the overlay windows beyond the lines PA-W13/W14 cite, were not
  re-read this turn.
