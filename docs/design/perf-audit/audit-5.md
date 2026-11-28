# Audit-5: the fourth Windows performance re-audit (T3316)

- **Date:** 2026-11-28
- **Umbrella:** T2957
- **Commit measured and audited:** 5eaac0760a (both builds rebuilt at HEAD)
- **Trigger:** the date (2026-11-28). Of audit-4's 94 open PA tasks, none
  had closed when this audit started. This audit closes one of them (T2983).
- **Baseline:** [`baseline-5.json`](baseline-5.json), compared with
  [`baseline-4.json`](baseline-4.json). Method: [`README.md`](README.md).
- **Next re-audit:** T3877 (audit-6). It is due **2026-12-05**, or sooner
  once 10 of the open PA tasks listed at the end of this file have closed.

**Produced by Fable 5.2.** There was one Fable 5.2 auditor per area
(`model: fable`, passed explicitly). Each was read-only, ran in parallel and
was given its area's audit-4 file. The owning turn checked every new finding
by reading the cited lines at HEAD before filing it. Findings that two areas
reported for the same lines were filed once. Each area's detail is in
`audit-5/<A>-findings.md`.

| Area | Fixed (all rounds) | of which incomplete | Still open | Changed | Wrong | New | Detail |
|---|---|---|---|---|---|---|---|
| R: renderer and GPU | 9 | R09 | 15 | R10 | 0 | R26-R29 | [R-findings.md](audit-5/R-findings.md) |
| W: the win32 frontend | 7 | W01, W03 | 15 | W07 | 0 | W24-W26 | [W-findings.md](audit-5/W-findings.md) |
| M: memory and leaks | 7 | none | 13 | M19 | 0 | M22, M23 (= R28) | [M-findings.md](audit-5/M-findings.md) |
| I: IPC and the agent | 14 | I05, I06, I08, I14, I19, I20, I21 | 10 | none | 0 | I25-I28 | [I-findings.md](audit-5/I-findings.md) |
| V: viewer panes | 13 | V12, V14 | 21 | none | V02, V10 | V37 | [V-findings.md](audit-5/V-findings.md) |
| C: shared Zig core | 11 | C15 | 12 | none | 0 | C24 (folded), C25 | [C-findings.md](audit-5/C-findings.md) |

**Fixed since audit-4:** one item. **R17** was fixed by d6732bc4da (T3739),
a correctness task, not by its own task. A reused window now gets
`SetPixelFormat` whenever its DC has no format (`Surface.zig:1095-1114`,
`windowPixelFormat` at `:1892-1896`). T2983 is closed against that commit.
No other PA task closed in the week. The loop's week went to the
single-window port and the Linux bring-up.

**Judged wrong:** V02 and V10, both unchanged since audit-4.

## Baseline-5 against baseline-4

`perf-baseline.ps1 -Compare baseline-4.json,baseline-5.json`: **42 of 536
metrics are out of tolerance.** Both baselines read CPU with the cycle
counter (T3111), so CPU rows compare. The two regressions below were
confirmed by a second run of those phases alone on the same day
(`-Build Release -Phase busy,viewer`).

| Metric (release unless noted) | Baseline-4 | Baseline-5 | Reading |
|---|---|---|---|
| idle `cpu_pct` | 1.28 | **0.60** | better; `cpu_cycle_pct` 0.90 -> 0.79 is within tolerance |
| idle cycles, debug | 0.88 | **0.39** | better |
| idle wakeups/s, debug | 144 | **92** | better (release 143 -> 133, within tolerance) |
| **agent idle cycles** | 0.96 (debug 1.00) | **0.17** (debug 0.22) | **better: T3235's CPU half (342064c1c) confirmed** |
| agent base private MB | 17.7 | 17.4 | unchanged; T3244 (PA-I22/M21) still open |
| viewer open, webview CPU % | 0.96 | 0.21 | better |
| viewer hidden, app CPU % | 0.91 | 1.43 | worse, just past tolerance; noted, not filed |
| **busy: app CPU s for 64 MB** | 7.50 | **17.47** (repeat 15.77) | **worse, about 2.1-2.3x: T3880** |
| busy: wall s | 26.0 | 32.6 (repeat 38.6) | worse; folded into T3880 |
| busy: app counters (reads, batches, renders, wakeups, fps, attributed Mcycles/s) | | | all within tolerance |
| **viewer open: app growth MB** | 6.0 | **50.4** (repeat 49.2) | **worse: T3881**; debug 8.2 -> 47.7 |
| viewer open: growth handles / USER / threads | 132 / 45 / 10 | 187 / 58 / 15 | worse; folded into T3881 |
| cycle settled private MB | -5.6 | +10.1 | worse, small; noted |
| cycle stack MB, **debug only** | 17.4 | 44.6 | worse, Debug only (release in tolerance): T3882 |

**Both regressions are filed as P1, not the P0 the audit rule asks for.**
This is the same exception audit-4 made: the controller put the
single-window port ahead of perf work, which is why this audit is P1. Each
task's first step is a same-day run of the baseline-4 binary (424c9e5ab).
T3234 was closed as box drift (T3242), and the busy phase's wall time is
sensitive to load from other lanes. In the busy regression the app's own
rates did not move. So the extra CPU is spread over a longer span, or it sits
outside the attributed threads. It is not a hotter loop.

A tool defect surfaced along the way: `-Compare` against a run with only
some phases counts the missing metrics as out of tolerance ("472 of 74").
That is T3883.

## What changed in the tracker

**Closed by this audit:** T2983 (PA-R17), against d6732bc4da (T3739).

**New tasks.** Each has a dep on T3316 and is added to T2957's deps.

| PA | Task | Pri | Where (HEAD) | What |
|---|---|---|---|---|
| R26 | T3862 | P2 | `Window.zig:5153-5177`; `renderer/Thread.zig:456`, `:548` | each window activation change forces a frame on every pane of the active tab and rebuilds released storage (from T3761) |
| R27 | T3863 | P3 | `Window.zig:5171-5176` | `syncPace` only reaches the active tab; a switched-to tab keeps a stale cap up to 250 ms |
| R28 + M23 | T3864 | P3 | `gl_comp_present.zig:421`, `:440-469`, `:712-723` | pooled D3D11 devices are never released, and each pane past a device's limit pays a refused open (from T3746) |
| R29 | T3865 | P3 | `renderer/OpenGL.zig:1759-1766` | opt-in presenter: a pane it does not compose redraws with no throttle (from T2622) |
| W24 | T3866 | P3 | `SettingsWindow.zig:1600-1628` | every menu open rebuilds the shell catalog on the GUI thread (PATH stats, WSL registry walk) |
| W25 | T3867 | P3 | `PaneDesk.zig:2622-2661`; `chrome_comp.zig:1634-1682` | busy lights hold two window-sized buffers (opt-in chrome host; from T2626) |
| W26 | T3868 | P3 | `PaneSidebar.zig:673` | 512 sidebar items x tooltip text = 196 KB per sidebar (from T1914) |
| M22 | T3869 | P2 | `Window.zig:24420-24423` vs `:23680-23684` | an in-place workspace close never detaches its UIA strips provider: a leak, and a dangling Window pointer a screen reader can call into |
| I25 | T3870 | P3 | `agent/agent_log.zig:97-142`; `server.zig:1858` | each agent log line reopens the directory and file, one under the store lock |
| I26 | T3871 | P3 | `agent/server.zig:3116-3160`; `web_tunnel.zig:435-484` | tunnelled bodies as 1 MiB base64 control frames ahead of terminal output |
| I27 | T3872 | P3 | `agent/web_tunnel.zig:152`, `:490-495` | a thread and a fresh http client per tunnelled request (cert store rescan) |
| I28 | T3873 | P3 | `agent/server.zig:1133`, `:1170` | the writer's wire buffer keeps its largest batch's capacity |
| V37 | T3874 | P3 | `ViewerPane.zig:5840-5859` | an opening viewer decodes each capture before checking it is wanted, up to 8 times (from T2635) |
| C25 | T3875 | P3 | `src/Surface.zig:1247-1268`; `os/agent_exec_argv.zig:51-109` | `-e` quoting walks PATH x PATHEXT on the GUI thread (from T3402) |
| baseline | T3880 | P1 | busy phase | busy CPU about 2.1-2.3x baseline-4 |
| baseline | T3881 | P1 | viewer phase | three viewers grow the app by about 50 MB instead of 6 MB |
| baseline | T3882 | P3 | cycle phase, Debug | Debug committed stack 17 -> 45 MB |

**Outside the PA list:**

- **T3876** (P2 fix): the agent's `freeUnlinked`
  (`agent/session.zig:1504-1511`) walks the session table with no lock held
  (`liveCount` at `:1288-1295`). Area I's auditor raised it as a correctness
  note. A rehash or free that runs at the same time makes the walk read freed
  memory in the shipped agent.
- **T3883** (P3 infra): the `-Compare` count defect above.

**Folded into existing tasks (notes added):**

- C24 into T3298
- R26's trigger noted on T3141
- M06's move to shared code on T3006
- M16/V27's second asker on T3145
- M19's lights surface on T3309
- W01's three new spawns on T3075
- W07's pace dependency on T2991
- M14's pooled devices on T3097
- M22's teardown on T3012
- Audit-4 corrections that were never applied, now on T3167, T3023, T3031,
  T3148 and T3165
- Moved cites on T3051, T3250 and T3228

**Where the new findings come from.** The pace work (T3761) adds R26, R27
and C24. The device pool (T3746) adds R28/M23. The single-window port adds
M22, and the shell pickers (T3751-T3753) add W24. None of them reverses a
perf fix.

## Umbrella close condition

**Not met.** The two confirmed baseline regressions (T3880, T3881) are open
at P1, and T2984 (the Mac half of audit-1's renderer fixes, `seat: mac`)
is still open at P1. No area auditor found an open P0 or P1 PA item on the
Windows side. Every open area item is P2 or P3.

## Open PA tasks (the audit-6 count starts here)

T2969, T2977-T2982, T2984, T2991-T3000, T3006, T3008-T3010, T3012, T3023,
T3024, T3026-T3031, T3047-T3056, T3065-T3067, T3069, T3075, T3090-T3092,
T3096-T3100, T3110, T3117, T3141-T3150, T3152, T3153, T3165-T3167, T3219,
T3228, T3244, T3250, T3298-T3315, T3862-T3875 (107 tasks). Audit-6 (T3877)
is due once 10 of these are done, or on 2026-12-05. The baseline
regressions T3880-T3882 are tracked on T2957 directly.
