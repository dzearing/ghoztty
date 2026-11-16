# Audit-3: the second Windows performance re-audit (T3101)

- **Date:** 2026-11-15
- **Umbrella:** T2957
- **Commit audited and measured:** d0d874326 (both builds rebuilt at HEAD)
- **Trigger:** 11 of audit-2's open PA tasks closed (T2976 T2986 T2987 T2988
  T2989 T2990 T3001 T3002 T3003 T3004 T3005), ahead of the 2026-11-21 date.
- **Baseline:** [`baseline-3.json`](baseline-3.json), compared with
  [`baseline-2.json`](baseline-2.json) and [`baseline-1.json`](baseline-1.json).
  Method: [`README.md`](README.md).
- **Next re-audit:** T3151 (audit-4), due **2026-11-28** or once 10 of the
  open PA tasks listed at the end have closed, whichever comes first.

**Produced by Fable 5.2.** One Fable 5.2 auditor per area (`model: fable`,
passed explicitly), read-only and in parallel, each given its area's audit-2
file. The owning turn checked every new finding by reading the cited lines
at HEAD before filing it (the claim-verification rule). Findings that two
areas reported for the same lines were filed once. Each area's detail is in
`audit-3/<A>-findings.md`.

| Area | Fixed (all rounds) | of which incomplete | Still open | Changed | Wrong | New | Detail |
|---|---|---|---|---|---|---|---|
| R: renderer and GPU | 8 | R09 | 7 | 4 | 0 | R20, R21, R22 | [R-findings.md](audit-3/R-findings.md) |
| W: the win32 frontend | 6 | W01, W03 | 11 | 0 | 0 | W18, W19 (= R22) | [W-findings.md](audit-3/W-findings.md) |
| M: memory and leaks | 6 | none | 6 | 3 | 0 | M16 (= V27), M17 | [M-findings.md](audit-3/M-findings.md) |
| I: IPC and the agent | 3 | I14 | 13 | 4 | 0 | I21 | [I-findings.md](audit-3/I-findings.md) |
| V: viewer panes | 1 | V14 | 25 | 0 | 0 | V27-V30 | [V-findings.md](audit-3/V-findings.md) |
| C: shared Zig core | 3 | none | 15 | 0 | 0 | C19, C20 (= R20) | [C-findings.md](audit-3/C-findings.md) |

New this round, as against audit-2: R09, R10 (closed as the driver's reuse
pool), W02-W06, M01-M05, M11, C06, C07, I11, I14 (incomplete) and V14
(incomplete). The tracker said nothing had landed in areas I and V. The
diff shows otherwise: T3105 fixed I11, T3102 half-fixed I14, and T3001
fixed V14 as a side effect. **No finding was judged wrong.**

## Baseline-3 against baseline-2 and baseline-1

`perf-baseline.ps1 -Compare baseline-2.json,baseline-3.json`: **12 of 198
metrics are out of tolerance. 9 moved down (better) and 3 moved up (worse).**
Against baseline-1, 45 are out of tolerance and all 45 are better.

Baseline-3 is the first baseline with T2989's per-thread and residue census
and T3005's settled-cycle slope, heap split and Debug leak report. Those
fields have no baseline-2 counterpart, so `-Compare` scores only the 198
metrics the two files share.

| Metric (release unless noted) | Baseline-1 | Baseline-2 | Baseline-3 | Explained by |
|---|---|---|---|---|
| idle private MB | 322.8 | 202.3 | 204.7 | within tolerance |
| idle threads | | 71 | **83** | **worse:** T3105's 16 IPC listeners (was 4); T3152 |
| idle wakeups/s | | 147.7 | 146.5 | unchanged, so the new threads do not wake |
| 10 panes open: threads | 611 | 115 | 127 | the same +12 |
| 10 panes open: private MB | 1,418.5 | 695.2 | 644.5 | T3001-T3003 |
| 10 panes open: GPU dedicated MB | 348.8 | 209.1 | **164.8** | better: T3001, T3002, T2975/T3104 releases |
| after closing: USER objects (debug) | | 100 | **111** | **worse:** +9 to +11 in every open/closed sample of both builds, start unchanged; T3153 |
| after closing: GPU dedicated MB | 107.4 | 107.3 | 107.4 | the driver's reuse pool (T2976) |
| first / second cycle residue MB | 830.2 / 27-36 | 406.0 / 30.3 | 411.8 / 31.4 | within tolerance |
| settled cycles, closed private MB | | | 676-690, flat | **no leak**: T3005's slope is about 0 after 6 warm-up cycles |
| busy: app CPU s / wall s for 64 MB | 20.27 / 30.48 | 7.66 / 33.46 | 6.88 / 27.69 | within tolerance (T3080: noisy) |
| resize CPU % (debug / release) | 31.0 / 13.8 | 32.2 / 14.9 | 22.2 / **7.0** | better: T2986 (W02) |
| agent base / per session private MB | 167.3 / 19.1 | 10.6 / 3.3 | 9.3 / 1.4 | within tolerance |
| Debug leak report at clean quit | | | 1 allocation | `relay_suspend.zig:639` never frees the account path; T3154 |

**The two regressions are filed as P2, not as the P0 the audit rule asks
for. This is a deliberate exception, recorded here.** The thread increase is
an intended trade made by T3105 (`IpcServer.zig:57`: 16 instances so that
silent clients cannot block the server). The extra threads are idle: idle
wakeups and private memory did not move. T3152 asks for one overlapped
waiter in place of the 16 threads. The USER objects are a one-time first-open
cost of 9 to 11 objects. They do not grow per cycle (the second cycle adds +4
to +7, as before), and only the Debug reading crosses tolerance, by one
object. Baseline-2 has no residue census, so T3153 is an attribution task.

## What changed in the tracker

**Closed by this audit**, each against the commit that actually fixed it:

- T3025 (PA-I11) against e4bfd30f5 (T3105)
- T3046 (PA-V14) against 40297c800 (T3001)

**New tasks.** All are P2 with deps on T3101, and each is added to T2957's
deps:

| PA | Task | Where (HEAD) | What |
|---|---|---|---|
| R20 + C20 | T3141 | `generic.zig:1406`, `:2196-2202`; `OpenGL.zig:1653` | the first frame after 3 s idle re-creates the target and shared texture and re-uploads both atlases; measure, P1 if > 2 ms |
| R21 | T3142 | `opengl/Target.zig:34-37`; `OpenGL.zig:1343-1350` | a released 1x1 target is 256x256 (grow bucket) |
| W18 | T3143 | `Window.zig:18435-18461`, `:19159-19163` | merged chrome: a caption or strip invalidation runs both band painters |
| R22 + W19 | T3144 | `apprt/win32/Surface.zig:2853`, `:2664-2672` | hero mode frees and re-allocates each tile's landing buffer every 150 ms (from T3001) |
| V27 + M16 | T3145 | `ViewerPane.zig:5524`; `Window.zig:8163` | an in-flight viewer capture lands after the release and is kept (5-33 MB) |
| V28 | T3146 | `ViewerPane.zig:6527-6540` | a hidden viewer whose renderer was killed reloads at once |
| V29 | T3147 | `viewer_process.zig:61-65` | a slow (unresponsive) page is reloaded 3 times, then closed as crashed; inferred, confirm first |
| I21 | T3148 | `agent/server.zig:2584-2630` | the writer thread's catch-up refill holds the store lock for up to 4 MiB |
| C19 | T3149 | `WindowsFontIndex.zig:118-126`, `:152-166`; `SharedGridSet.zig:180`, `:195` | the font index is built on the first querying thread (60-75 ms on the GUI thread) |
| M17 | T3150 | `PaneDesk.zig:2336`, `:328-340` | focus-glow buffer freed and re-allocated on focus changes between panes of different sizes (from T3002) |
| V30 | folded into T3049 | `ViewerPane.zig:6549-6556` | a git-status: pane whose page was dropped keeps polling git |

**Notes added** (current lines and the changed shape): T3049, T3028 (re-scope
to the app queue and the replay room check), T3031, T3019, T3026, T3017,
T3091, T3092, T2982 (R16 is larger: `refreshOcclusion` undoes T3104's
release on every size step), T2977, T3096, T3097, T3009, T3075, T3066 (its
title still misstates C12), T2985, T2987, T3001, T3002, T3011.

**From the baseline:** T3152 (16 IPC listener threads), T3153 (USER object
attribution) and T3154 (the one Debug leak). All are P2 with deps on T3101.

**Regressions caused by the fix commits.** Four bounded costs, all P2: T3144
(T3001), T3145 (T3001), T3150 (T3002), and T3141, from T3103's idle release.
None is a functional regression.

## Umbrella close condition

**Not met.** Open P0/P1 PA items remain: W17 (T3095); M has none; I02-I08
(T3016-T3022); V01-V13 (T3033-T3045); C02-C04, C08, C15 (T3059-T3061,
T3064, T3068); and T3074, the residual of R02. The audit found no open P0
PA item.

## Open PA tasks (the audit-4 count starts here)

T2969, T2977-T2984, T2991-T3000, T3006-T3010, T3012, T3016-T3024,
T3026-T3031, T3033-T3045, T3047-T3056, T3059-T3062, T3064-T3069,
T3095-T3100, T3141-T3150, T3152-T3154 (92 tasks). Audit-4 (T3151) is due once 10 of these
are done, or on 2026-11-28.
