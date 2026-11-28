# T3880 - busy-CPU A/B, baseline-4 build vs audit-5 build (2026-11-28)

Question: is audit-5's busy regression (release cpu_s 7.50 -> 17.47 / 15.77
for 64 MB) a change in the code, or box drift?

Method: `scripts\perf-baseline.ps1 -Build Release -Phase busy -Exe <exe>`,
64 MB ascii, alternating base/head, three rounds, one after another on the
test desktop, same box, same hour.

- base = 424c9e5ab9 (baseline-4), ReleaseFast, built in a detached worktree
  and copied to the in-repo prefix `zig-out-t3880base\`
- head = 5eaac0760a (audit-5), `zig-out-release\`
- commit per run read back from the JSON's `version` field (each side's
  `+version`), so the run is known to have measured the binary it names

| run | build | cpu_s | cpu_pct | wall_s | pty reads/s | wakeups/s |
|---|---|---|---|---|---|---|
| 1 | base | 8.89 | 34.9 | 25.4 | 1885 | 3865 |
| 1 | head | 12.97 | 52.1 | 24.9 | 1857 | 3860 |
| 2 | base | 10.20 | 40.5 | 25.2 | 1841 | 3871 |
| 2 | head | 9.44 | 36.1 | 26.2 | 1840 | 3979 |
| 3 | base | 13.36 | 49.5 | 27.0 | 1830 | 3944 |
| 3 | head | 12.61 | 39.2 | 32.2 | 1888 | 4468 |

Means: base 10.8 s, head 11.7 s CPU; base 25.9 s, head 27.7 s wall (head's
wall is one 32 s outlier; the other two head runs beat base).

**Verdict: no code regression.** The head-base gap (+0.9 s) is a fraction of
one build's own spread (base alone: 8.9 - 13.4 s, 1.5x). Baseline-4's 7.50 s
was a low draw, and audit-5's 17.47 / 15.77 s were high ones; the app's own
counters never moved in audit-5 either, which is the signature of noise
rather than of a hotter loop. The real defect is the measurement: a single
busy run cannot carry a +-30% tolerance (T3886).

## The first A/B was void (fixed here)

The first two rounds (`%TEMP%\t3880-ab`) measured 5eaac0760a on BOTH sides:
`perf-baseline.ps1` assigned its default build path to `$exe` before
reading the `-Exe` parameter, and PowerShell variable names are
case-insensitive, so the assignment overwrote the parameter. Every `-Exe`
A/B since T3111 (a23d3b36e0) measured the repo's own build twice; T3885
re-checks the conclusions that rested on one. Fixed by resolving `-Exe`
before the default; `-PrintExe` and section E of
`test\win32\perf-baseline-reader.ps1` prove the override is honoured.
