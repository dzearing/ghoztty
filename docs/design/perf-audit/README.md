# Windows performance audit (T2957)

This folder holds the performance audit of the Windows port: the measured
baselines, and the audit write-ups (`audit-N.md`, from T2965 onward).

## The baseline

`scripts\perf-baseline.ps1` measures, on the hidden test desktop and never
against an installed Ghoztty:

| Phase | What | How |
|---|---|---|
| `idle` | app CPU (% of one core), context switches/s, GPU engine %, memory | 1 window 1400x900, 1 cmd pane at its prompt, 10 s settle, then 60 s |
| `busy` | wall time, app CPU, GPU engine % while a pane prints 64 MB; `busy.perf` (the app's own counters) and `busy.wakeup_attribution` (CPU and context switches by thread) | a `+split` pane running `type` of a generated file, timed to a marker file; the busy app runs under `GHOZTTY_PERF=1` (T3059) |
| `resize` | app CPU and GPU engine % during resizes | `SetWindowPos` to a new size every 50 ms for 8 s |
| `cycle` | private bytes, working set, handles, GDI/USER objects, threads, GPU memory, child processes | at start, with 10 panes over 3 tabs, after closing them all; twice |
| `viewer` | the WebView2 tree (every `msedgewebview2.exe` under the app, by `--type=` role): process count, private bytes, CPU; app private bytes and GDI/USER growth; the residual tree and app leak after closing | 1 terminal plus 3 viewers split beside it (a 60-section markdown file, `git-status:` on a scratch repo, a static page from a loopback listener); `open` = 60 s shown; `hidden` = a new tab over them for 60 s; `after_close` = every viewer closed, the tree every 10 s for 90 s (T3033) |
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
absolute floor. Idle CPU has its own floor (`idle_cpu_pct`, ±0.05 points, two
clock ticks over 60 s; T3111), because at a few tenths of a percent the busy
floor of 0.5 let a 7x rise pass. Memory has ±15%. Handle and object counts
have ±10%.

### Reading busy.perf (T3059)

The busy app runs under `GHOZTTY_PERF=1` and `busy.perf` is parsed from the
counter lines it logs over the busy span (Debug: its stderr; release: the
sandbox `ghoztty.log`). Each line is a rate over a window of at least 1 s.

| Field | Source | Meaning |
|---|---|---|
| `reads_per_s`, `batches_per_s`, `pty_kb_per_s` | `perf pty` (`termio/Exec.zig`) | the pty reader's `ReadFile` calls, parse batches and bytes per second; mean over the busy pane's windows |
| `bytes_per_batch` | the same lines | total bytes / total batches: how much output each terminal-lock round parses |
| `queue_render_per_s` | `perf queue_render_per_s` (`termio/stream_handler.zig`) | render requests per second from the busiest stream handler |
| `render_notifies_per_s` | `notifies_per_s=` on the same line (T3061) | the wakeups those requests actually posted after coalescing (`renderer/wake_coalesce.zig`); before T3061 every request posted one, and the field is null on such a build. Under a flood it should sit near `renderer_wakeups_per_s`, not near `queue_render_per_s` |
| `renderer_wakeups_per_s` | `perf wakeups_per_s` (`renderer/Thread.zig`) | renderer thread wakeups per second; the MEDIAN over all renderer threads' windows, so the idle anchor pane does not drag it |
| `fps`, `fps_max_gap_ms` | `perf pane= fps=` (`renderer/OpenGL.zig`) | frames per second and the longest gap between frames, from the pane with the most windows |
| `agent_feed.*` | `perf agent_feed` (`termio/Remote.zig`) | only with `-BusyPersistence`: the agent data lane's kB, slices, feeds per second and its parse/lock/work/yield ms per second |
| `windows.*` | | how many counter windows each figure is built from (not compared) |

`-Compare` checks every `busy.perf` rate against the `perf_rate` tolerance
(±35%, floor 5); `fps_max_gap_ms` and the window counts are not compared.
`busy.wakeup_attribution` has the same shape as the idle one: per-thread
context switches and cycles over the busy span, grouped by thread name
(`io-reader`, `renderer`, `main`) or start module.

First reading (2026-11-17, 64 MB ASCII, both builds): about 29-31k reads/s at
about 94 bytes a batch, 29-32k `queue_render` calls/s, ~118 renderer wakeups/s
and ~119 fps. The `io-reader` threads carry about 27k of the ~31k context
switches/s, which confirms that the reader's per-batch syscalls explain the
busy wakeup rate (PA-C03, PA-C04).

### Reading idle CPU (T3111)

Windows charges `cpu_pct` (user + kernel time) in whole clock ticks of
15.625 ms to whatever thread the tick interrupts. Over the 60 s idle span one
tick is 0.026%, so an idle `cpu_pct` of 0.03 is ONE tick and 0.21 is eight: a
count of samples, not a measurement. `cpu_ticks` prints that count.
`cpu_cycle_pct` (and `mcycles_per_s`, per thread in
`wakeup_attribution.top_threads_by_cycles` / `by_group_cycles`) comes from the
exact cycle counter and is the number to compare. `timer_resolution_ms` is the
system clock interval at both ends of the span: another process's
`timeBeginPeriod(1)` changes it from 15.6 to 1 ms.

**Baselines 1-3 read user time only.** Until T3111 the reader took
`CreateTime + UserTime` for `user + kernel` (offset 0x20 of the process record
is CreateTime), so their `cpu_pct` and `cpu_s` leave kernel time out. Compare
CPU against a T3111-or-later JSON only.

## Files

- `baseline-1.json` is the first baseline (T2958, commit 4d1e6a270, both builds).
- `baseline-1-repeat.json` is a second run made straight after it. In the
  `-Compare` of the two, all 198 metrics are within tolerance. The leak deltas
  needed their own family (`delta_mb`), because the two runs read 27.3 MB and
  36.1 MB for the same delta. The script carries that family; the JSON
  files' own tolerance block predates it. Under T3111's tighter idle floor
  the two disagree on idle CPU (release 0.03 vs 0.18, debug 0.34 vs 0.13):
  the same code gave 1 and 7 clock ticks.
- `baseline-2.json` is the audit-2 baseline (T3072, commit 879fba35a, both
  builds). Against baseline-1, 42 of 198 metrics are out of tolerance, all of
  them better. See `audit-2.md`.
- `baseline-3.json` is the audit-3 baseline (T3101, commit d0d874326, both
  builds). It is the first with the per-thread and residue census (T2989) and
  the settled-cycle slope and Debug leak report (T3005). Against baseline-2,
  12 of 198 metrics are out of tolerance: 9 better, 3 worse. The worse ones are
  +12 idle threads (T3105's IPC listeners, T3152) and USER objects
  (T3153). See `audit-3.md`.
- `audit-1.md`, `audit-2.md` and `audit-3.md` are the audit write-ups; `audit-N/` holds each
  area's detail.

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
