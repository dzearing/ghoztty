# T3111: the "7x" release idle CPU rise was a measurement artifact

**Verdict: no regression.** Release idle CPU did not rise between baseline-1
and baseline-2/3. The three baselines read 0.03%, 0.21% and 0.21%. Those
numbers were a count of clock ticks, and the reader leaked half of what it
claimed to read. Measured exactly, the baseline-1 code and HEAD cost the same,
thread for thread.

## What was wrong with the number

1. **Kernel time was never counted.** `PerfSnap.Read` summed offsets `0x20`
   and `0x28` of the `SYSTEM_PROCESS_INFORMATION` record as "user + kernel".
   `0x20` is `CreateTime`, a constant, and `0x28` is `UserTime`. So every
   `cpu_pct` in baselines 1-3 was **user time only**. This was verified against
   `Get-Process`: StartTime matches `0x20`, UserProcessorTime matches `0x28`,
   and PrivilegedProcessorTime matches `0x30`.
2. **What remained was a tick count.** Windows charges thread time in whole
   clock ticks of 15.625 ms to whichever thread the tick interrupts. Over the
   60 s idle span one tick is 0.026%. Baseline-1's 0.03% is **one tick**, and
   0.21% is eight. `baseline-1-repeat`, made straight after baseline-1 on the
   same commit, read 0.18% (seven ticks). The rise was already there in the
   same-commit repeat.
3. **The compare could not see it either way.** Idle CPU used the busy floor of
   ±0.5 points, so a 7x move on a 0.03 base was "within tolerance".

## The A/B

There were 5 release idle runs per side, interleaved head/base so that box
drift hit both sides alike, on the hidden test desktop with the fixed reader
(`scripts\perf-baseline.ps1 -Build Release -Phase idle`, base side via the new
`-Exe`). **base** is 4c8a7cd4f, the same `src/` as baseline-1's 107cfa871,
built ReleaseFast into its own worktree. **head** is 34d44bb3e. The system
timer read 1 ms at both ends of every run. Raw JSON: `t3111/`.

| run | cpu% (ticks) | user% (the old metric) | kernel% | ticks | **cycle%** | Mcyc/s | wakeups/s |
|---|---|---|---|---|---|---|---|
| base-1 | 0.47 | 0.23 | 0.23 | 18 | **0.536** | 16.08 | 138.7 |
| base-2 | 0.83 | 0.31 | 0.52 | 32 | **0.541** | 16.23 | 148.3 |
| base-3 | 0.44 | 0.05 | 0.39 | 17 | **0.502** | 15.07 | 144.4 |
| base-4 | 0.68 | 0.29 | 0.39 | 26 | **0.547** | 16.40 | 141.1 |
| base-5 | 0.44 | 0.21 | 0.23 | 17 | **0.517** | 15.50 | 147.5 |
| head-1 | 0.65 | 0.23 | 0.42 | 25 | **0.594** | 17.81 | 137.8 |
| head-2 | 0.70 | 0.18 | 0.52 | 27 | **0.560** | 16.80 | 142.1 |
| head-3 | 0.52 | 0.08 | 0.44 | 20 | **0.529** | 15.86 | 143.2 |
| head-4 | 0.52 | 0.21 | 0.31 | 20 | **0.538** | 16.13 | 146.4 |
| head-5 | 0.21 | 0.13 | 0.08 | 8 | **0.466** | 13.99 | 152.0 |

- **Exact cycles:** base averages 0.529% (range 0.502-0.547) and head averages
  0.537% (range 0.466-0.594). That is a +1.7% difference, inside the spread.
- **The old metric on the SAME base build** ranged from 0.05% to 0.31%, a 6x
  spread with nothing changed. That is the "7x rise".
- **The tick-charged total** ranged from 0.21% to 0.83% on one commit. The
  tick total never agrees with the cycle count for a single run. It only
  converges on average.

Per thread group (mean Mcycles/s and wakeups/s over 5 runs, from the new
`by_group_cycles`):

| group | base Mcyc/s | head Mcyc/s | base wake/s | head wake/s |
|---|---|---|---|---|
| ghoztty.exe [renderer] | 6.06 | 6.16 | 11.4 | 12.2 |
| nvoglv64.dll (GL driver) | 5.08 | 5.16 | 47.8 | 47.5 |
| nvwgf2umx.dll (D3D driver) | 4.14 | 4.22 | 75.1 | 74.7 |
| ghoztty.exe [main] | 0.51 | 0.51 | 11.4 | 11.2 |
| **total** | 15.80 ± 0.55 | 16.06 ± 1.40 | | |

No thread does more work per wakeup at HEAD, and none wakes more often.

## What changed in the instrument

- The reader takes user `0x28`, kernel `0x30` and cycles `0x18`.
  `-SelfTest` checks it against `Get-Process` for its own process.
- The idle phase records `cpu_user_pct`, `cpu_kernel_pct`, `cpu_ticks`,
  `cpu_cycle_pct`, `mcycles_per_s` and `timer_resolution_ms`. The wakeup
  attribution adds per-thread `mcycles_per_s` (QueryThreadCycleTime),
  `top_threads_by_cycles` and `by_group_cycles`.
- The `idle_cpu_pct` tolerance family (±max(0.05, 50%)) now flags baseline-1
  against baseline-3. It also flags baseline-1 against its own repeat, which is
  the honest reading of a one-tick number.
- `-Exe` measures a ghoztty.exe from another build tree, for commit A/B runs.
- Acceptance: `test\win32\perf-baseline-reader.ps1`.

## What the exact numbers show instead

Idle costs about 16 Mcycles/s (0.53% of one core at the nominal 3 GHz). About
60% of that is the NVIDIA driver's own threads, and 6 Mcycles/s is our
renderer, which wakes about 11 times a second with nothing changing on screen.
That cost was the same at baseline-1 and is not a regression. It is the
baseline figure to beat, and its own task looks into it.
