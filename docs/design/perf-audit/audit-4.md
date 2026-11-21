# Audit-4: the third Windows performance re-audit (T3151)

- **Date:** 2026-11-18
- **Umbrella:** T2957
- **Commit measured:** 424c9e5ab (both builds rebuilt at HEAD)
- **Trigger:** 28 of audit-3's 92 open PA tasks closed (T3016-T3022,
  T3033-T3045, T3059-T3062, T3064, T3068, T3095, T3154), ahead of the
  2026-11-28 date.
- **Baseline:** [`baseline-4.json`](baseline-4.json), compared with
  [`baseline-3.json`](baseline-3.json). Method: [`README.md`](README.md).

- **Area re-audit:** 2026-11-21 at **c9af15802**. On 2026-11-18 all six
  Fable 5.2 auditors hit the account's rate limit, which reset on 2026-11-21.
  The audit specifies Fable, so no other model was substituted.
- **Next re-audit:** T3316 (audit-5). It is due **2026-11-28**, or sooner
  once 10 of the open PA tasks listed at the end of this file have closed.

**Produced by Fable 5.2.** There was one Fable 5.2 auditor per area
(`model: fable`, passed explicitly). Each was read-only, ran in parallel and
was given its area's audit-3 file. The owning turn checked every new finding
by reading the cited lines at HEAD before filing it. Findings that two areas
reported for the same lines were filed once. Each area's detail is in
`audit-4/<A>-findings.md`.

| Area | Fixed (all rounds) | of which incomplete | Still open | Changed | Wrong | New | Detail |
|---|---|---|---|---|---|---|---|
| R: renderer and GPU | 8 | R09 | 13 | R10 | 0 | R23, R24, R25 | [R-findings.md](audit-4/R-findings.md) |
| W: the win32 frontend | 7 | W01, W03 | 12 | 0 | 0 | W20-W23 | [W-findings.md](audit-4/W-findings.md) |
| M: memory and leaks | 7 | none | 8 | M12, M13 | 0 | M18, M19, M20 (= V32), M21 (= I22) | [M-findings.md](audit-4/M-findings.md) |
| I: IPC and the agent | 14 | I05, I06, I08, I14, I19, I20, I21 | 6 | I09 | 0 | I22, I23, I24 | [I-findings.md](audit-4/I-findings.md) |
| V: viewer panes | 13 | V12, V14 | 15 | 0 | V02, V10 | V31-V36 | [V-findings.md](audit-4/V-findings.md) |
| C: shared Zig core | 11 | C15 | 8 | C12 | 0 | C21, C22, C23 | [C-findings.md](audit-4/C-findings.md) |

**Fixed since audit-3**, with the fix diff read at HEAD:

| Area | Fixed |
|---|---|
| W | W17 (99efd0c58, T3095), which was the area's last open P1 |
| M | M07 (073c924a7, T1590, a task outside the PA list) |
| I | I02 (T3016), I03 (T3017), I04 and I18 (T3018), I07 (T3021) |
| I, incomplete | I05 (T3019), I06 (T3020), I08 (T3022) |
| V | V01 and V03-V09 (T3033, T3035-T3041), V11 and V26 (T3043), V13 (T3045) |
| V, incomplete | V12 (T3044, T3224, T3245) |
| C | C02 (T3059), C03 and C05 (T3060/T3062), C04 (T3061), C08-C10 (T3064) |
| C, incomplete | C15 (T3068) |

R02's residual T3074 also closed (1cde0416f, and e15858510 for the viewer
card). Nothing in the core renderer (`generic.zig`, `OpenGL.zig`,
`opengl/*`) changed since audit-3.

**Judged wrong:**

- **V02.** T3034 measured the WebView2 browser tree exiting about 5 s after
  the last viewer closes. It is already closed as `skipped(does not
  reproduce)`.
- **V10.** b4655e962 (T3042) fixed the delete order, and its own test records
  that the old order never leaked.

## Baseline-4 against baseline-3

`perf-baseline.ps1 -Compare baseline-3.json,baseline-4.json`: **28 of 398
metrics are out of tolerance.**

**CPU rows cannot be compared with baseline-3.** Baselines 1-3 read user time
only (T3111). Every `cpu_pct` row that crosses tolerance (idle, resize, agent
idle) is partly a method change. The exact cycle counter (`cpu_cycle_pct`) is
the comparable number, and baseline-3 has none. So the idle figure below is
compared with the ten T3111 runs at cbc185f67 (`t3111/*.json`) instead.

| Metric (release unless noted) | Baseline-3 | Baseline-4 | Reading |
|---|---|---|---|
| busy: wakeups/s while printing 64 MB | 34,427 | **4,280** | better: T3061 (one renderer wake per frame) and T3060 (batched reads) |
| busy: wakeups/s (debug) | 23,326 | **4,518** | better, same cause |
| busy: wall s for 64 MB (debug) | 39.4 | **26.2** | better |
| after-close private MB (debug) | 654.7 | **556.0** | better; private RW regions fall 60-100 MB in every cycle sample of both builds |
| idle threads | 83 | 83 | unchanged (T3152 still open) |
| idle wakeups/s | 146.5 | 142.6 | unchanged |
| USER objects after closing | 118 | 118 | unchanged (T3153 still open) |
| **idle app cycles, % of a core** | 0.47-0.59 at cbc185f67 | **0.90** (repeat 0.875) | **worse, about 1.6x: T3234** |
| **agent idle cycles, 1 session** | (0.05 user time) | **0.96** (repeat 1.00; debug 1.0) | **worse: T3235** |
| **agent base private MB** | 9.3 | **17.7** (repeat 17.7) | **worse, release only (debug 9.8): T3235**; likely T3017's fast allocator |
| agent per-session child private MB | 12.5 | 17.8 | worse, release only; folded into T3235 |
| resize CPU % | 7.0 | 46.7 | not comparable (kernel time now counted); baseline-4 is the first comparable reading |

**The two regressions are filed as P1, not the P0 the audit rule asks for.**
This is a deliberate exception. The controller put the single-window port
ahead of perf work on 2026-11-16, which is why T3151 itself is P1. Both
regressions were confirmed by a second run of that phase alone
(`-Build Release -Phase idle|agent`). The repeat agent run's
`per_session_child_private_mb` read 2,671 MB, which is a bad sample. T3235
asks for the reader to be made robust to it.

**What happened to the two regressions since:**

- **T3234 is closed as box drift** (6ab6112e7). The same 11-15 binary read
  0.69-0.74% on 11-18, against 0.50-0.55% on 11-15. T3242 asks for a
  cross-day comparison method.
- **T3235 is closed with the CPU half** (342064c1c), which cut the agent's
  process-table walk. The memory half is T3244, still open. This audit
  confirms it as PA-M21 = PA-I22.

## What changed in the tracker

**Closed by this audit:** T3007 (PA-M07), against 073c924a7 (T1590).

**New tasks.** Each has a dep on T3151 and is added to T2957's deps.

| PA | Task | Pri | Where (HEAD) | What |
|---|---|---|---|---|
| R23 | T3298 | P2 | `renderer/Thread.zig:744`, `:853-856`, `:760-765` | a pane that is not drawing (hidden, parked or low-power) still gets one renderer wake per output batch |
| R24 | T3299 | P3 | `renderer/Thread.zig:734-737` vs `:744` | a wakeup wait error returns before the coalescing flag clears (from T3061; area C reported it too) |
| R25 | T3300 | P3 | `gl_comp_present.zig:1076-1089`; `chrome_comp.zig:999-1007` | chrome draws share the device lock with pane presents (from T3074; opt-in) |
| C21 | T3301 | P3 | `termio/Exec.zig:1587`, `:1627-1650`, `:1681` | a 64 KiB parse in one lock hold, about 4 ms computed |
| C22 | T3302 | P2 | `scripts/perf-baseline.ps1:116`, `:1396-1401` | the busy phase has no row for the default agent path |
| C23 | T3303 | P3 | `termio/Exec.zig:1640-1649`; `read_coalesce.zig:38-49` | flood coalescing always waits out its 1 ms (from T3060) |
| W20 | T3304 | P2 | `Window.zig:7675-7731`, `:2690-2729`, `:7738-7813` | a single-window workspace switch rebuilds everything bound to the window |
| W21 | T3305 | P2 | `Surface.zig:1554-1570`; `Window.zig:22885-22902` | pooled pane windows outlive a workspace that closes in place |
| W22 | T3306 | P3 | `HeroCarousel.zig:140-262`; `hero_tile_card.zig:132-157` | every carousel paint re-shades every tile per pixel |
| W23 | T3307 | P3 | `Window.zig:10409-10430` | the workspace crossfade renders the full desk on each of about 20 frames |
| M18 | T3308 | P2 | `viewer_toc_comp.zig:170-184` | the T2772 leak order (commit before release), now run after every contents slide (from T3040) |
| M19 | T3309 | P3 | `chrome_comp.zig:2363-2390` | the same order, run on every workspace switch (opt-in chrome host) |
| M20 + V32 | T3310 | P2 | `ViewerPane.zig:7990-8002` | the glass buffer only grows and is kept while hidden, 6-41 MB (from T3041) |
| V31 | T3311 | P2 | `ViewerPane.zig:1176-1191` | pane close joins its workers without cancelling them first |
| V33 | T3312 | P3 | `ViewerPane.zig:2069-2070`, `:6576` | a pane hidden before its controller arrives is never trimmed |
| V35 | T3313 | P3 | `ViewerPane.zig:6596`; `viewer_scratch.zig:85-118` | the scratch folder is claimed and swept on the GUI thread |
| V36 | T3314 | P3 | `ViewerImageDecode.zig:146-159` | pictures from 2 MB to 512 MB are copied to `%TEMP%` on every open and save |
| I24 | T3315 | P3 | `agent/proc.zig:1350-1354`; `server.zig:231`, `:2712` | allocations over 32 KiB map and unmap pages every time |

**Folded into existing tasks (notes added):**

- V34 into T3250
- I23 into T3165
- M21 and I22 into T3244 (now in T2957's deps)
- M12 into T3012 (the surrender path)
- M13 into T3096 and T3091 (parked workspaces)
- C12 into T3066 (keep both halves)
- I09 into T3023 (smaller now)
- R10 unchanged, noted on T3110

**Regressions caused by fix commits.** None is a functional regression:

| Commit | Task | Regression |
|---|---|---|
| e15858510 | T3040 | M18 |
| 663e4a850 | T3041 | M20/V32 |
| 674561478 | T3017 | M21/I22, T3244 |
| 09c94632b | T3060 | C21, C23 |
| 5059acb10 | T3061 | R24 |
| T3224/T3245 | | V31 |

The single-window port (T3184 family, T3191/T3192) adds W20, W21, W23 and
M19, and widens M12/M13.

## Umbrella close condition

**Not met.** One P1 PA item is still open: T2984, the Mac half of audit-1's
renderer fixes. It is `seat: mac`. No open P0 PA item exists in any area. On
the Windows side every open PA item is P2 or P3. Baseline-4's two regressions
were T3234 (closed as drift) and T3235 (closed; its memory half is T3244).
T3244 is P2.

## Open PA tasks (the audit-5 count starts here)

T2969, T2977-T2984, T2991-T3000, T3006, T3008-T3010, T3012, T3023, T3024,
T3026-T3031, T3047-T3056, T3065-T3067, T3069, T3075, T3090-T3092,
T3096-T3100, T3110, T3117, T3141-T3150, T3152, T3153, T3165-T3167, T3219,
T3228, T3244, T3250, T3298-T3315 (94 tasks). Audit-5 (T3316) is due once 10
of these are done, or on 2026-11-28.
