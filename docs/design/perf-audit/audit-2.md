# Audit-2: the first Windows performance re-audit (T3072)

- **Date:** 2026-11-14
- **Umbrella:** T2957
- **Commit audited and measured:** 879fba35a (both builds rebuilt at HEAD)
- **Trigger:** 10 audit-1 PA tasks closed (T2967 T2968 T2970 T2971 T2972
  T2973 T2974 T2985 T3015 T3058), ahead of the 2026-11-21 date.
- **Baseline:** [`baseline-2.json`](baseline-2.json), compared with
  [`baseline-1.json`](baseline-1.json). Method: [`README.md`](README.md).
- **Next re-audit:** T3101 (audit-3), due **2026-11-21** or once 10 of the
  open PA tasks listed at the end have closed, whichever comes first.

**Produced by Fable 5.2.** One Fable 5.2 auditor per area (`model: fable`,
passed explicitly), read-only and in parallel, each given its area's audit-1
file. Every NEW finding was then checked by the owning turn by reading the
cited lines at HEAD before it was filed or folded (the claim-verification
rule). The detail for each area is in `audit-2/<A>-findings.md`.

| Area | Fixed | Still open | Changed | Wrong | New PA ids | Detail |
|---|---|---|---|---|---|---|
| R: renderer and GPU | 7 | 7 | 3 | 0 | R18, R19 | [R-findings.md](audit-2/R-findings.md) |
| W: the win32 frontend | 1 | 14 | 1 | 0 | W17 | [W-findings.md](audit-2/W-findings.md) |
| M: memory and leaks | 0 | 9 | 3 | 0 | M13, M14, M15 | [M-findings.md](audit-2/M-findings.md) |
| I: IPC and the agent | 1 | 15 | 1 | 0 | I18, I19, I20 | [I-findings.md](audit-2/I-findings.md) |
| V: viewer panes | 0 | 20 | 4 | 0 | V25, V26 | [V-findings.md](audit-2/V-findings.md) |
| C: shared Zig core | 1 | 13 | 2 | 0 | C17, C18 | [C-findings.md](audit-2/C-findings.md) |
| **Total (102 audit-1 ids)** | **10** | **78** | **14** | **0** | **13 new** | |

## Baseline-2 against baseline-1

`perf-baseline.ps1 -Compare baseline-1.json,baseline-2.json`: **42 of 198
metrics out of tolerance, and all 42 moved down (better). No metric got worse
beyond tolerance, so no regression task was filed.**

Baseline-2 has the same phases as baseline-1. None of the tooling tasks that
add phases had landed: the viewer phase (T3033), per-thread attribution
(T2989), busy-phase counters (T3059), and leak slope and heap census (T3005).

| Metric (release unless noted) | Baseline-1 | Baseline-2 | Explained by |
|---|---|---|---|
| idle private MB | 322.8 | 202.3 | T2985 (W01), T2968 (R02) |
| 10 panes open: threads | 611 | 115 | T2968 (R02) |
| 10 panes open: private MB | 1,418.5 | 695.2 | T2985, T2968 |
| 10 panes open: handles | 3,349 | 1,406 | T2968 |
| 10 panes open: GPU dedicated MB | 348.8 | 209.1 | T2968, T2974 |
| first open/close cycle residue MB | 830.2 | 406.0 | T2985 |
| after closing: GPU dedicated MB | 107.4 | 107.3 | unchanged: PA-R10 (T2976) is still real |
| busy: app CPU s for 64 MB | 20.27 | 7.66 | T2972, T2973, T2967; noisy (T3080) |
| busy: wall s for 64 MB | 30.48 | 33.46 | within tolerance; conhost-bound |
| agent base private MB | 167.3 | 10.6 | T3015 (I01) |
| agent per session MB (+ console/shell) | 19.1 (+76.3) | 3.3 (+12.6) | T3015 |
| idle CPU % (debug / release) | 0.34 / 0.03 | 0.23 / 0.21 | within tolerance |
| resize CPU % (debug / release) | 31.0 / 13.8 | 32.2 / 14.9 | within tolerance; PA-W02 open |

## Every audit-1 PA id

Verdicts: **fixed** (with the commit), **open** (still true; the task stands),
**changed** (true but a different size or shape; the task got a note), and
**wrong** (none this round). Every task named here received an audit-2 note
in its progress log carrying the current lines.

### R (T2959)

| PA | Verdict | Task | What changed |
|---|---|---|---|
| R01 | fixed 8d2be0f7b | T2967 done | |
| R02 | fixed 29302f08c | T2968 done | DComp device still per pane: T3074 |
| R03 | open | T2969 | R02 dependency met; memory-only gain |
| R04 | fixed 2cdc77abe | T2970 done | |
| R05 | fixed 5672c7165 | T2971 done | |
| R06 | fixed 60ae989a0 | T2972 done | grow-only half is new R19 (T3098) |
| R07 | fixed 396aac1db | T2973 done | shrink half is T3090 |
| R08 | fixed 6711c4e45 | T2974 done | one hole, new R18 (T3096) |
| R09 | changed (smaller) at 879fba35a | T2975 done after the audit (19581323a) | current-size buckets, not high-water; the background-tab release landed after the audited commit, audit-3 verifies it |
| R10 | changed | T2976 | residue unchanged at 107 MB with the shared device; rewrite suspects |
| R11 | changed (narrower) | T2977 | an unchanged frame is a full draw; fix `needs_redraw` |
| R12 | open | T2978 | |
| R13 | open | T2979 | glide tick now 10.1 ms |
| R14-R17 | open | T2980-T2983 | |

### W (T2960)

| PA | Verdict | Task | What changed |
|---|---|---|---|
| W01 | fixed 90e57ab70 (incomplete) | T2985 done | ~30 short-lived spawns (T3075) and the sheet pool (new W17, T3095) |
| W02-W05 | open | T2986-T2989 | cost figures predate T2968; re-baseline |
| W06 | changed (smaller) | T2990 | the per-sample thread now has the small stack |
| W07-W16 | open | T2991-T3000 | |

### M (T2961)

| PA | Verdict | Task | What changed |
|---|---|---|---|
| M01-M04 | open | T3001-T3004 | |
| M05 | changed | T3005 | its evidence predates three fixes; re-baseline, three-knob A/B |
| M06, M07 | open | T3006, T3007 | |
| M08 | changed | T3008 | sites still `.{}`: 16 MB while alive (T3075) |
| M09 | changed (one more site) | T3009 | `termio/Thread.zig:354-357` drain drops payloads |
| M10-M12 | open | T3010-T3012 | M10 cross-linked to T3098 |

### I (T2962)

| PA | Verdict | Task | What changed |
|---|---|---|---|
| I01 | fixed fc7f7fdfb | T3015 done | no gap with T2985 in the agent or holder |
| I02, I03 | open | T3016, T3017 | I02 gains the agent mirror `mux.zig:123-146` |
| I04 | changed (wider) | T3018 | three per-byte modulo loops, not one |
| I05-I17 | open | T3019-T3031 | I06 is the history file, two fsyncs; I13 is worker-only |

### V (T2963)

| PA | Verdict | Task | What changed |
|---|---|---|---|
| V01-V04 | open | T3033-T3036 | |
| V05 | changed (wider) | T3037 | all four file modes reload unconditionally |
| V06, V07 | open | T3038, T3039 | |
| V08 | changed | T3040 | take T2968's device via T3074, or deinit at slide end |
| V09, V10 | open | T3041, T3042 | V10 still inferred |
| V11 | changed (one more copy) | T3043 | plus new V26 |
| V12-V14 | open | T3044-T3046 | |
| V15 | changed (count) | T3047 | 12 assets, ~399 KB |
| V16-V24 | open | T3048-T3056 | |

### C (T2964)

| PA | Verdict | Task | What changed |
|---|---|---|---|
| C01 | fixed dacab7bec | T3058 done | covers all three `modsChanged` callers; live check T3076 |
| C02-C11 | open | T3059-T3062, T3011, T3064, T3065 | lines moved; re-cited in the notes |
| C12 | changed | T3066 | no code honours priority waiters; cost is four lock cycles per key |
| C13, C14 | open | T3067 | |
| C15 | changed, **raised to P1** | T3068 | the priority handoff is unreachable (below) |
| C16 | open | T3069 | |

**PA-C15 in plain terms.** The agent-backed pane (the shipped default) was
built to step aside for typing and the window between small slices of output
(T111b/T114). It never does: the drain hands the parser at most 1 KB
(`Remote.zig:2589`, `:2620`), and the step-aside only runs when more than the
4 KB slice size is left over (`:2236`, `:2276-2280`). So every "priority" lock
in the app is a plain lock. Verified by reading. Not yet measured.

## New findings

| PA | P | Where (HEAD) | Cost | Task |
|---|---|---|---|---|
| W17 | P1 | `sheet_workers.zig:46` | up to 4 x 16 MB committed stacks for the life of the app (computed) | T3095 |
| R18 + M13 | P2 | `OpenGL.zig:1312`; `renderer/Thread.zig:576-594` | a hidden pane never trims; trim attempts spent on re-present frames | T3096 |
| M14 | P2 | `gl_comp_present.zig:1101-1126` | a closed pane's GPU memory may wait for another present (inferred) | T3097 |
| R19 + M15 | P2 | `opengl/buffer.zig:83-91`, `:113-121` | cell buffers and their T2972 shadows never shrink | T3098 |
| C17 | P2 | `Surface.zig:2321-2344`, `:3817-3839` | a full rebuild per real modifier press and release (*shared*) | T3099 |
| C18 | P2 | `renderer/link.zig:61-110` | per-frame link regexes while a link can highlight (*shared*) | T3100 |
| V25 | P2 | `ViewerFeedbackSend.zig:202` | a 16 MB-stack thread per feedback report | folded into T3075 |
| V26 | P2 | `ViewerPane.zig:4874`, `:4936` | HEIC/TIFF read whole on the GUI thread, then decoded again | folded into T3043 |
| I18 | P2 | `pty_host_proto.zig:381-385` | per-byte copy under the holder mutex | folded into T3018 |
| I19 | P2 | `client_mux.zig:273-296` | unbounded mux fifo | folded into T3016 |
| I20 | P2 | `server.zig:1610-1613`, `:2497-2500` | up to 2 MB copied three times per reattach, under the store lock | folded into T3017 / T3019 |

Regressions caused by the fix commits: none beyond tolerance in the baseline.
Three bounded costs were introduced by fixes, all P2: R18/M13 (T2974), M14
(T2968, inferred) and R19/M15 (T2972).

## Tracker changes

- New tasks T3095-T3100 and audit-3 T3101, each with deps on T3072 and added
  to T2957's deps.
- T3068 raised P2 -> P1 (C15).
- An audit-2 note on every changed task, every task that gained a folded
  finding, and every closed task's verdict.

## Umbrella close condition

**Not met.** Open P0/P1 PA items remain (for example T2986-T2990,
T3001-T3005, T3011, T3016-T3022, T3033-T3046, T3059-T3061, T3064, T3068,
T3095). No regression was found.

## Open PA tasks (the audit-3 count starts here)

T2969, T2976-T2983, T2986-T3012, T3016-T3031, T3033-T3056, T3059-T3062,
T3064-T3069, T3095-T3100. Audit-3 (T3101) is due once 10 of these are done,
or on 2026-11-21.
