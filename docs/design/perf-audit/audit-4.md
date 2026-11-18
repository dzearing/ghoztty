# Audit-4: the third Windows performance re-audit (T3151)

- **Date:** 2026-11-18
- **Umbrella:** T2957
- **Commit measured:** 424c9e5ab (both builds rebuilt at HEAD)
- **Trigger:** 28 of audit-3's 92 open PA tasks closed (T3016-T3022,
  T3033-T3045, T3059-T3062, T3064, T3068, T3095, T3154), ahead of the
  2026-11-28 date.
- **Baseline:** [`baseline-4.json`](baseline-4.json), compared with
  [`baseline-3.json`](baseline-3.json). Method: [`README.md`](README.md).

**Status: the baseline half is done; the area re-audit is not.** The six
Fable 5.2 area auditors (R W M I V C) were launched and every one was refused
at its first request: the account's Fable limit resets on 2026-11-21. The
audit is specified as a Fable 5.2 re-audit, so this turn did not substitute
another model. T3151 is parked until then (`requeue-after: 2026-11-21`). The
area files will go in `audit-4/<A>-findings.md`, and the verdict table and the
open-PA list will be added to this file.

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

## What changed in the tracker

- New: **T3234** (idle cycles, bisect cbc185f67..424c9e5ab) and **T3235**
  (agent idle CPU and release memory). Both are P1 and both are added to
  T2957's deps.
- No PA verdicts yet. Those come with the area re-audit.
