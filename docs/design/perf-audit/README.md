# Windows performance audit (T2957)

This folder holds the performance audit of the Windows port: the measured
baselines, and the audit write-ups (`audit-N.md`, from T2965 onward).

## The baseline

`scripts\perf-baseline.ps1` measures, on the hidden test desktop and never
against an installed Ghoztty:

| Phase | What | How |
|---|---|---|
| `idle` | app CPU (% of one core), context switches/s, GPU engine %, memory | 1 window 1400x900, 1 cmd pane at its prompt, 10 s settle, then 60 s |
| `busy` | wall time, app CPU, GPU engine % while a pane prints 64 MB | a `+split` pane running `type` of a generated file, timed to a marker file |
| `resize` | app CPU and GPU engine % during resizes | `SetWindowPos` to a new size every 50 ms for 8 s |
| `cycle` | private bytes, working set, handles, GDI/USER objects, threads, GPU memory, child processes | at start, with 10 panes over 3 tabs, after closing them all; twice |
| `agent` | `ghoztty-agent.exe` idle CPU, memory per session, handles across detach/attach | persistence on, 4 extra sessions, 3 app kill/relaunch cycles |

Each number in the JSON sits beside a `method` string. A number the box could
not read is `null` with a `*_reason` field. Each build runs in its own child
process under `Set-GhozttyTestIsolation -ReleaseSandbox`: a private app pipe,
a private agent lineage, and a private `LOCALAPPDATA`. That isolation applies
to the Debug build as well, so the agent being measured is always the run's
own.

```powershell
# both builds (zig-out Debug, and zig-out-release ReleaseFast) -> one JSON
powershell -NoProfile -File scripts\perf-baseline.ps1 -Out temp\perf.json
# one build or one phase
powershell -NoProfile -File scripts\perf-baseline.ps1 -Build Release -Phase cycle
# repeatability / regression: every metric of b against a, within tolerance
powershell -NoProfile -File scripts\perf-baseline.ps1 -Compare docs\design\perf-audit\baseline-1.json,temp\perf.json
```

The ReleaseFast build is the launch-upgrade staging build:
`zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release`.
Rebuild it at the commit you are measuring. The script runs whatever binary
is there, and the JSON records which version that was.

The tolerances are in the script, and every JSON carries a copy. CPU and GPU
engine time are noisy: their tolerance is ±50-75% relative, with a small
absolute floor. Memory has ±15%. Handle and object counts have ±10%.

## Files

- `baseline-1.json` is the first baseline (T2958, commit 4d1e6a270, both builds).
- `baseline-1-repeat.json` is a second run made straight after it. In the
  `-Compare` of the two, all 198 metrics are within tolerance. The leak deltas
  needed their own family (`delta_mb`), because the two runs read 27.3 MB and
  36.1 MB for the same delta. The script carries that family; the JSON
  files' own tolerance block predates it.

What baseline-1 already shows. These numbers are measured, not explained;
explaining them is the area audits' job:

- about 323 MB private with one idle pane, in Debug and ReleaseFast alike
- about 54 app threads per terminal pane (611 with 10 panes)
- the first open/close of 10 panes leaves about 825 MB behind; the second
  leaves 27-36 MB
- 64 MB of `type` output takes about 30 s (about 2 MB/s)
- 160-210 context switches/s at idle
- the agent: about 19 MB per session, plus 60-76 MB in the session's console
  and shell processes
