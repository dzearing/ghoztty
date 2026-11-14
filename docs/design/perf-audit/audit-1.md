# Audit-1: the Windows performance audit, rolled up (T2965)

- **Date:** 2026-11-14
- **Umbrella:** T2957 (user directive 2026-11-14: find and work down every
  Windows memory, GPU, CPU and leak win, as top priority)
- **Baseline:** [`baseline-1.json`](baseline-1.json) (T2958), with
  [`baseline-1-repeat.json`](baseline-1-repeat.json) as its repeatability check.
  The method behind every number is in [`README.md`](README.md).
- **Next re-audit:** T3072 (audit-2), due **2026-11-21** or once 10 of the
  tasks below have closed, whichever comes first.

**Produced by Fable 5.2.** Each area was audited by two or three Fable 5.2
auditors (`claude-fable-5-2`, passed explicitly), working read-only and in
parallel. The turn that owned the area checked every surviving claim against
the code before filing it, by reading the cited lines. This file is the
index. The detail behind each row (mechanism, risk, the claims that did not
survive, what was checked and found clean) is in the area's own file:

| Area | Audit task | Commit audited | Findings | Detail |
|---|---|---|---|---|
| R: renderer and GPU | T2959 | 4c8a7cd4f | 17 | [R-findings.md](audit-1/R-findings.md) |
| W: the win32 frontend | T2960 | 3e92e7fbf | 16 | [W-findings.md](audit-1/W-findings.md) |
| M: memory and leaks | T2961 | a8349acb1 | 12 | [M-findings.md](audit-1/M-findings.md) |
| I: IPC and the agent | T2962 | a9eac4671 | 17 | [I-findings.md](audit-1/I-findings.md) |
| V: viewer panes | T2963 | a229abc72 | 24 | [V-findings.md](audit-1/V-findings.md) |
| C: shared Zig core hot paths | T2964 | e9b6d84ea | 16 | [C-findings.md](audit-1/C-findings.md) |
| **Total** | | | **102** | |

By priority: **5 P0**, **45 P1**, **52 P2** (PA-M11 counted at P1, see area M). Every PA id maps to a task. No
finding was dropped at roll-up. One pair of tasks was a cross-area duplicate
and is folded (below). Line numbers are as of each area's audited commit, so a
re-audit re-reads them rather than trusting them.

## What baseline-1 shows, and which findings explain it

| Baseline-1 number | Explained by |
|---|---|
| ~323 MB private with one idle pane | PA-W01 (at least 128 MB of 16 MB thread stacks), PA-R02 (per-pane D3D11 + DComp device) |
| ~54 app threads per pane (611 with 10 panes) | PA-R02 (about 51 driver threads per device). The core makes 3 per pane |
| ~825 MB left after the first 10-pane open/close | PA-W01 (~432 MB of parked-thread stacks); the rest is a one-time driver fill, not proved a leak until PA-M05 measures it |
| ~50 MB of dedicated GPU memory left after closing | PA-R10 (cause unverified, bounded) |
| 160-210 context switches/s at idle | ~6/s explained (PA-W07, PA-R04); the rest is unattributed until PA-W05 |
| 64 MB of output takes ~30 s | conhost caps it at ~2 MB/s; PA-C03, PA-C04 and PA-C05 cut the app's CPU per byte, and PA-C02 attributes it |
| agent: ~19 MB per session, plus 60-76 MB in its console and shell | PA-I01 (16 MB stacks in agent and holder), PA-I17 |
| (not measured) viewers | PA-V01 adds the phase that every V finding's criteria quote |

## The five P0s

| PA | Finding | Task |
|---|---|---|
| PA-R01 | The render-state reset counter is never zeroed: after 100,000 frames every frame rebuilds everything (*shared*) | T2967 |
| PA-R02 | One D3D11 device and one DComp device per pane: about 54 threads and tens of MB each | T2968 |
| PA-W01 | Every Zig thread commits a full 16 MB stack; parked pane threads keep ~430 MB after close | T2985 |
| PA-I01 | Agent and holder threads commit 16 MB stacks: ~160 of the agent's 167 MB, 48-64 MB per session | T3015 |
| PA-C01 | NumLock or CapsLock makes every mouse move and keystroke a full rebuild (*shared*) | T3058 |


The re-audit that keeps this list true, T3072, is P0 as well.

## Every finding

Columns: **P** priority; **Where** the main site (more in the area file);
**Cost** with (m) measured, (e) estimated, (c) computed, (i) inferred;
**Fix** in brief. *Shared* means the Mac build runs the same code, and its
Mac half is named under the area.

### R: renderer and GPU (T2959)

Mac half: T2984 (R01, R04, R05, R07).

| PA | P | Where | Cost | Fix | Task |
|---|---|---|---|---|---|
| PA-R01 | P0 | `renderer/generic.zig:1365-1370` | (e) after 15-30 min of streaming, a full rebuild every frame, for good | reset the counter inside the `if` (upstream has it) | T2967 |
| PA-R02 | P0 | `gl_comp_present.zig:499`, `:590` | (m) 72 -> 611 threads, 323 -> 1418 MB private, 53 -> 349 MB GPU from 1 to 10 panes; per-device attribution (i) | one process-wide device, multithread-protected | T2968 |
| PA-R03 | P2 | `OpenGL.zig:473-477`, `opengl/shaders.zig:113-116` | (e) at least 1.25 MB atlas per pane plus context state | GL share group (after R02) | T2969 |
| PA-R04 | P1 | `renderer/Thread.zig:902-903`, `generic.zig:1664` | (e) 1.67 full frames/s per focused pane with a steady cursor | hash the blink phase only when the cursor blinks | T2970 |
| PA-R05 | P1 | `renderer/link.zig:76-83`, `generic.zig:1591` | (e) a viewport string and byte map every frame | check `needed` before building | T2971 |
| PA-R06 | P1 | `generic.zig:1993-1995`, `opengl/buffer.zig:96-119` | (e) ~260 KB and ~48 GL calls per frame at 160x45 | upload only dirty rows, in one call | T2972 |
| PA-R07 | P1 | `font/Atlas.zig:274`, `generic.zig:2005-2020` | (e) 256 KB-1 MB per new glyph per pane; never shrinks | upload the changed region; reclaim on clear | T2973 |
| PA-R08 | P1 | `opengl/Target.zig:86`, `gl_comp_present.zig:658-668` | (e) 22-25 MB per pane at 1400x860, ~150 MB after one 4K maximize | shrink on settle | T2974 |
| PA-R09 | P1 | `OpenGL.zig:1536-1544`, `Window.zig:4785-4790` | (e) 22-25 MB per background-tab pane | release surfaces on tab hide | T2975 |
| PA-R10 | P1 | suspects `pane_pool.zig:28`, per-HWND DComp target, driver | (m) 107.4 vs 57.6 MB dedicated after close; bounded | A/B three knobs to find the carrier | T2976 |
| PA-R11 | P2 | `generic.zig:1907`, `OpenGL.zig:1558-1566` | (m) 1.0-1.6% GPU on a 4090 | skip the re-present of an unchanged frame | T2977 |
| PA-R12 | P2 | `renderer/cell.zig:118-122` | (e) ~47 allocations, ~0.7 MB per resize step | reuse row lists (with T3010) | T2978 |
| PA-R13 | P2 | `generic.zig:2327`, `:2289`, `:2337` | (m) glide tick 12.8 ms vs an 8.3 ms period (T2820) | one copy, reuse the texture, no full rebuild | T2979 |
| PA-R14 | P2 | `opengl/Pipeline.zig:50-56` vs `:72-74` | an FBO and a VAO per pipeline teardown | delete them in `deinit` | T2980 |
| PA-R15 | P2 | `apprt/win32/Surface.zig:1735`, `:1751-1752` | (e) ~5 MB per pane, SwapBuffers fallback only | drop depth and stencil from the pixel format | T2981 |
| PA-R16 | P2 | `Window.zig:22388-22389`, `:8002` | small | throttle the walk; skip the heartbeat when occluded | T2982 |
| PA-R17 | P2 | `apprt/win32/Surface.zig:1019` | correctness hazard, found in passing | set the pixel format on a recycled window (or T3000) | T2983 |

### W: the win32 frontend (T2960)

No Mac half is owed: W01's file is shared but only Windows commits a stack up
front; the rest is win32-only.

| PA | P | Where | Cost | Fix | Task |
|---|---|---|---|---|---|
| PA-W01 | P0 | zig `lib/std/Thread.zig:400`, `:645-655`; `os/reusable_thread.zig:57` | (e) 48 of the ~121 MB each pane adds; ~432 MB of the first-cycle residue | spawn with `STACK_SIZE_PARAM_IS_A_RESERVATION` or a small commit | T2985 |
| PA-W02 | P1 | `Window.zig:22473`, `PaneDesk.zig:1127` | (e) ~4 ms per resize step; the resize phase's 13.8%/31.0% CPU | arm the canvas on any resize burst | T2986 |
| PA-W03 | P1 | `Window.zig:18978-18979`, DIBs at `:18619/:18633`, `:19207/:19227` | (e) two DIB allocations and N text measures per paint | skip painters outside the clip; keep the DIBs | T2987 |
| PA-W04 | P1 | `Window.zig:18101-18103` (before the guard at `:18112`) | (e) ~10 full chrome paints/s under a spinner title | invalidate the strip rect, on a real change only | T2988 |
| PA-W05 | P1 | `scripts/perf-baseline.ps1:264` | (m) ~150 idle switches/s, ~51 USER objects, 12 threads unexplained | per-thread deltas; per-type handle and USER diffs (tooling) | T2989 |
| PA-W06 | P1 | `activity_sample.zig:151` | (e) an OS thread per 1.5 s sample, ~64 KB stranded each on NVIDIA | a long-lived or pooled worker | T2990 |
| PA-W07 | P2 | `App.zig:1065`, `occlusion.zig:141-156` | (e) 4 wakeups/s forever, minimized or locked | stop the timer when nothing needs it | T2991 |
| PA-W08 | P2 | `pane_grab_handle.zig:209-213` | (e) 20 Hz while the handle shows | poll only while the pointer is near | T2992 |
| PA-W09 | P2 | `Window.zig:1619` -> `system_colors.zig:146-153` | three registry reads per elevated paint | cache; refresh on setting change | T2993 |
| PA-W10 | P2 | `Window.zig:11593` | a heap-built grid 4-5 times per paint | build once per paint | T2994 |
| PA-W11 | P2 | `PaneSidebar.zig:5388-5404` | material rebuilt per height step | keep the cache across size steps | T2995 |
| PA-W12 | P2 | `Window.zig:13769-13776` (cached pair at `:14153-14156`) | fonts and brushes per paint | use the cached pair | T2996 |
| PA-W13 | P2 | `KeyStateIndicator.zig:567-571`, `ReadonlyBadge.zig:175` | re-render per tick and move; ticks while occluded | render on change; stop when occluded | T2997 |
| PA-W14 | P2 | `Window.zig:19126-19128`, `PaneSidebar.zig:2350-2372`, `BannerOverlay.zig:1657` | GDI objects per paint | route through `brush_cache` | T2998 |
| PA-W15 | P2 | `apprt/win32/Surface.zig:904/907`, `Window.zig:3893-3894` | two event handles, and a Surface, per failed init | errdefer and destroy on failure | T2999 |
| PA-W16 | P2 | `apprt/win32/Surface.zig:1533` | parking saves nothing on the composition path | do not park there (also removes R17's hazard) | T3000 |

### M: memory and leaks (T2961)

No allocation leak was found on any close path. Mac halves: T3013 (M04, M09),
T3014 (check the Swift `+read` for M06).

| PA | P | Where | Cost | Fix | Task |
|---|---|---|---|---|---|
| PA-M01 | P1 | `apprt/win32/Surface.zig:2655-2670`, `:2820-2844` | (e) 10 MB per pane at 1400x900, 66 MB at 4K, after any glide or drag | free when the glide or hero mode ends | T3001 |
| PA-M02 | P1 | `PaneDesk.zig:2508-2510`, `chrome_comp.zig:359-362` | (e) 25-40 MB per window at 1400x900, 165-265 MB at 4K | trim at gesture end or idle | T3002 |
| PA-M03 | P1 | `terminal/PageList.zig:34`, `:327`, `:369-374` | (e) ~7 MB never-touched commit per full pane; 2.1 MB preheat | reserve-and-commit page allocator on Windows; preheat 1 | T3003 |
| PA-M04 | P1 | `PageList.zig:3470-3476` | (e) 10-17.7 MB kept per pane after `cls` | release the free-list excess | T3004 |
| PA-M05 | P1 | `scripts/perf-baseline.ps1:483`, `:535` | (m) GPU shared memory still rising 14-22 MB between cycles | adaptive warm-up, slope over 5 cycles, heap census, COMP_PRESENT A/B (tooling) | T3005 |
| PA-M06 | P2 | `apprt/win32/IpcHandlers.zig:1374-1381` | (e) ~6 MB transient per `+read` of a 50k-line pane, renderer stalled | select only the requested tail | T3006 |
| PA-M07 | P2 | `apprt/win32/App.zig:9202-9258` | 11x the reload work at 10 panes | app-level work only for the `.app` target | T3007 |
| PA-M08 | P2 | `DirectoryProbe.zig:155`, `AgentIntegration.zig:171` | ~64 KB NVIDIA memory stranded per thread | run on `worker_pool` | T3008 |
| PA-M09 | P2 | `renderer/Thread.zig:233`, `termio/mailbox.zig:46-53` | rare leak of queued payloads at stop | drain and deinit before destroy (*shared*) | T3009 |
| PA-M10 | P2 | `renderer/cell.zig:118-122` | (e) 0.73-5.5 MB per pane | start rows at 1x columns (*shared*, with T2978) | T3010 |
| PA-M11 | P1 | `font/discovery.zig:1050-1085` | (e) tens-hundreds of ms per first-seen missing codepoint | one family and coverage index per process | T3011 |
| PA-M12 | P2 | `Window.zig:2476-2484` vs `:21927-22015` | `+close` skips the dialog and drag-thread teardown | one shared teardown | T3012 |

PA-M11 was P2 in area M and is P1 here: it is the same defect as PA-C06/C07
(below), and area C found it also holds the grid's exclusive lock.

Dropped in the area, before filing: **B-06** (kitty image storage, 320 MB per
screen): bounded and enforced, upstream's default, and no baseline phase shows
it. See M-findings.md.

### I: IPC and the agent (T2962)

Mac half: T3032 (I02-I06, I14, I17). I01, I07, I12 and I16 are Windows-only.

| PA | P | Where | Cost | Fix | Task |
|---|---|---|---|---|---|
| PA-I01 | P0 | agent `session.zig:1724`, `main.zig:2971`, `server.zig:662`; holder `pty_host.zig:266` | (m totals) ~160 of 167.5 MB agent; 48-64 MB per holder | explicit stack sizes (or T2985's helper) | T3015 |
| PA-I02 | P1 | `client_mux.zig:209-216`, `connection.zig:4030-4062` | (e) 3 copies, 1 extra parse and thread hop per chunk; ~8 MB kept | route data frames directly; shrink past a threshold (*shared*) | T3016 |
| PA-I03 | P1 | `agent/main.zig:168`, `server.zig:870-874` | a mutex per allocation; up to 4 copies per chunk | `smp_allocator` outside Debug; owning enqueue (*shared*) | T3017 |
| PA-I04 | P1 | `agent/session.zig:493-496` | (e) a 64-bit divide per byte, under the store lock | two `@memcpy` segments (*shared*) | T3018 |
| PA-I05 | P1 | `agent/session.zig:1660-1662` | all sessions' output under one lock | per-session lock (*shared*) | T3019 |
| PA-I06 | P1 | `session.zig:1729`, `atomic_write.zig:90` | (e) 1-3 MB plus an fsync per changed pane per 30 s | write on detach/stop/checkpoint; serialise outside the lock (*shared*) | T3020 |
| PA-I07 | P1 | `pty_host.zig:328-341`, `pty_holder_child.zig:839-845` | (c) 5 wakeups/s per session | wait on the process handle | T3021 |
| PA-I08 | P1 | `IpcHandlers.zig:810`, `tcp_dial.zig:180` | (e) every window frozen up to ~30 s on a dead host | dial on a worker | T3022 |
| PA-I09 | P2 | `agent/foreground.zig:117` | a Toolhelp snapshot per session per 10 s | one snapshot per tick | T3023 |
| PA-I10 | P2 | `IpcServer.zig:396-409` | ~67 GUI wakeups/s for up to 3 s | wait on a bind event | T3024 |
| PA-I11 | P2 | `os/ipc_client.zig:147`, `IpcServer.zig:48` | four stalled clients lock the CLI out | overlapped read with a bound | T3025 |
| PA-I12 | P2 | `pipe_stream.zig:251-252`, `:278-279` | an event created and closed per I/O | cache one per direction | T3026 |
| PA-I13 | P2 | `LocalAgent.zig:1140`, `:590` | 100 ms sleep steps on the GUI thread | `WaitNamedPipeW`; worker or cache | T3027 |
| PA-I14 | P2 | `server.zig:822`, `connection.zig:1863-1885` | unbounded outbound queue | a byte cap with gap-fill resync (*shared*) | T3028 |
| PA-I15 | P2 | `pty_holder_child.zig:493`, `pty_host.zig:281-293` | (i) an exited shell's holder and conhost live on | measure, then close after the final ACK | T3029 |
| PA-I16 | P2 | `pty_child.zig:778-849` | a process handle per in-process ConPTY child | `CloseHandle` after the reap | T3030 |
| PA-I17 | P2 | `agent/session.zig:931-932`, `PageList.zig:34` | (e) ~1.6-2 MB committed per session at first byte | preheat 1 (ties to T3003) (*shared*) | T3031 |

### V: viewer panes (T2963)

Baseline-1 has no viewer phase, so every cost here is estimated or computed
until PA-V01 lands. Mac half: T3057 (V05's page side, V15).

| PA | P | Where | Cost | Fix | Task |
|---|---|---|---|---|---|
| PA-V01 | P1 | `scripts/perf-baseline.ps1` | nothing in this area is measured | a `viewer` phase (tooling) | T3033 |
| PA-V02 | P1 | `webview2.zig:494-503`, `App.zig:2848` | (e) 150-300 MB over ~4 processes for the rest of the session | release the environment 60 s after the last viewer | T3034 |
| PA-V03 | P1 | `ViewerPane.zig:1834-1849` | (e) 50-150 MB per hidden viewer | `MemoryUsageTargetLevel = Low`, then `TrySuspend` | T3035 |
| PA-V04 | P1 | `Window.zig:3997`, `:4425-4427` | (e) a renderer and page load per never-shown viewer | start on first show | T3036 |
| PA-V05 | P1 | `ViewerPane.zig:7461-7463`, `:7545-7553` | (e) ~3x file size per save, even hidden | skip unchanged; defer while hidden (page side *shared*) | T3037 |
| PA-V06 | P1 | `ViewerPane.zig:237`, `ViewerDiffProbe.zig:540-623` | (e) ~3 spawns/s, ~9% of a core while visible | cache the root; fingerprint first | T3038 |
| PA-V07 | P1 | `ViewerPane.zig:2296-2309`, `viewer_diff.zig:640-658` | (e) 32-40 MB transient at the cap, 8 MB kept | build UTF-16 directly; free after push | T3039 |
| PA-V08 | P1 | `viewer_toc_comp.zig:123-168` | (e) a D3D11 device per viewer that ever slid its card | release at slide end, or share R02's device | T3040 |
| PA-V09 | P1 | `ViewerPane.zig:7112-7130` | (c) 5 MB per paint at 1400x900, 33 MB at 4K | grow-only DIB, clip, skip under an opaque page | T3041 |
| PA-V10 | P1 | `ViewerFindBar.zig:764-768` | (i) a DIB leaked per find-card resize | delete the DC first | T3042 |
| PA-V11 | P1 | `ViewerPane.zig:4935-4941` | (c) ~195 MB transient for a 12 MP HEIC | stream the BMP; decode on a worker | T3043 |
| PA-V12 | P1 | `ViewerPane.zig:4822-4838`, `viewer_range.zig:27` | (e) 2x resource size; every terminal stalls on slow paths | file-backed stream; worker reads | T3044 |
| PA-V13 | P1 | `ViewerDiffProbe.zig:222-226`, `ViewerFeedbackSend.zig:157-160` | whole-app freeze up to tens of seconds (rare) | cancel flag; terminate the child | T3045 |
| PA-V14 | P1 | `ViewerPane.zig:5464-5468` | (c) 5-33 MB per viewer that ever glided | free at glide or hero end (viewer twin of M01) | T3046 |
| PA-V15 | P2 | `viewer.html:8-22`, `ViewerPane.zig:5133-5139` | 14 assets (~470 KB) re-read per pane | process-wide cache; lazy scripts (*shared*) | T3047 |
| PA-V16 | P2 | `ViewerPane.zig:2319-2320`, `ViewerDiffProbe.zig:600-617` | O(n²) numstat join | hash the join | T3048 |
| PA-V17 | P2 | `ViewerPane.zig:2146`, `:1291`, `:7526` | timers tick while hidden | kill on hide, re-arm on show | T3049 |
| PA-V18 | P2 | `ViewerPane.zig:5424`, `:5462` | a full-page PNG encode and decode per second | skip unchanged; scaled capture | T3050 |
| PA-V19 | P2 | `ViewerFeedbackBar.zig:1862-1870` | a fresh DIB per paint | reuse `GlassHeadCache` | T3051 |
| PA-V20 | P2 | `viewer_feedback_images.zig:113-130` | deleted chips' PNGs kept; Send copies all | prune; lend the bytes | T3052 |
| PA-V21 | P2 | `ViewerTOCPanel.zig:2283-2287`, `ViewerFindBar.zig:770-779` | re-measure and re-render per mouse move | cache widths; invalidate changed rows | T3053 |
| PA-V22 | P2 | `ViewerPane.zig:1244-1259` | composer and find windows created up front | create on first open | T3054 |
| PA-V23 | P2 | `ViewerPane.zig:2963`, `:5703-5710` | dead iframe proxies; asset dir walked per start | prune on navigation; resolve once | T3055 |
| PA-V24 | P2 | `WhatsNewNotesView.zig:250-272` | full layout per paint and scroll | cache lines per width | T3056 |

### C: shared Zig core hot paths (T2964)

Mac half: T3071 (C01, C08-C11, C15, C16). A correctness defect found in
passing, the Windows font discovery ignoring bold and italic, is T3070.

| PA | P | Where | Cost | Fix | Task |
|---|---|---|---|---|---|
| PA-C01 | P0 | `src/Surface.zig:2316-2321`, `input/key_mods.zig:106-113` | (e) 60-125 full rebuilds/s while the pointer moves, ~10-50% of a core, with NumLock on | compare against `mods.binding()` (*shared*) | T3058 |
| PA-C02 | P1 | `scripts/perf-baseline.ps1` (counters in `termio/Exec.zig:1548-1633`) | the busy phase's CPU is unattributed | run it with `GHOZTTY_PERF=1`; per-thread CPU (tooling) | T3059 |
| PA-C03 | P1 | `termio/Exec.zig:1568-1611` | (e) 10-16% of a core and most switches in a flood | atomic quit flag; adaptive coalescing (after C05) | T3060 |
| PA-C04 | P1 | libxev `iocp.zig:850-861`; `Termio.zig:1190-1192` | (c) 19-29k redundant posts/s | `render_pending` flag; notify after the parse | T3061 |
| PA-C05 | P2 | `src/pty.zig:417` | a 4 KB pipe holds ~2 ms of output | 64 KB-1 MB `nSize` | T3062 |
| PA-C06 | P1 | `font/discovery.zig:929-937`, `CodepointResolver.zig:167-213` | (e) 50-300 ms per missing codepoint, all panes on the grid stalled | an off-thread font index | T3011 (folded from T3063) |
| PA-C07 | P1 | `src/Surface.zig:3451-3462`, `SharedGridSet.zig:122-134` | (e) 40-200 ms of GUI thread per zoom step with `font-family` set | the same index | T3011 (folded from T3063) |
| PA-C08 | P1 | `src/Surface.zig:5623-5660`, `Screen.zig:2556-2650` | megabytes per cell crossed on a 1 MB line | cap the soft-wrap walk (*shared*) | T3064 |
| PA-C09 | P2 | `src/Surface.zig:5650-5654` | allocation before the mods check | return early when no link can match (*shared*) | T3064 |
| PA-C10 | P2 | `src/Surface.zig:5918-5926` | a re-match and full rebuild per event over a link | skip while the cell is unchanged (*shared*) | T3064 |
| PA-C11 | P2 | `src/Surface.zig:5969`, `Screen.zig:2414-2428` | pins re-tracked and a full rebuild per drag event | skip an unchanged selection (*shared*) | T3065 |
| PA-C12 | P2 | `src/Surface.zig:4304-4307` | a plain lock gives up the T114 priority | use the priority lock | T3066 |
| PA-C13 | P2 | `shaper/harfbuzz.zig:134-148`, `shaper/Cache.zig:67-78` | the grid write lock held across `hb_shape` | shape outside the lock | T3067 |
| PA-C14 | P2 | `font/shaper/run.zig:75`, `harfbuzz.zig:265-298` | the buffer filled before the cache check | check the cache first | T3067 |
| PA-C15 | P2 | `termio/Remote.zig:2590` | 2,048 lock cycles per 2 MB replay; the yield never runs | larger slices (*shared*) | T3068 |
| PA-C16 | P2 | `termio/stream_handler.zig:1283-1420` | full work and a GUI post per unchanged OSC 7 | repeat check (*shared*) | T3069 |

## Roll-up decisions (T2965)

- **Duplicate folded: T3063 into T3011.** PA-C06/C07 (area C) and PA-M11
  (area M) are one defect: Windows font discovery has no index. T3011, the
  older card, now carries area C's facts and validation criteria and is P1.
  T3063 is `skipped(duplicate of T3011)`.
- **Related but kept apart** (different sites, fixed separately):
  - PA-M10 (T3010) and PA-R12 (T2978): the same lines in `cell.zig`, one
    about capacity and one about reallocation. Each task notes the other.
  - PA-M01 (T3001) and PA-V14 (T3046): the same snapshot-lifetime shape in
    the terminal pane and the viewer pane.
  - PA-W06 (T2990) and PA-M08 (T3008): the same thread-per-event shape at
    different sites. Both are concrete sources of T2669's NVIDIA question,
    and T2669 now says so.
  - PA-W01 (T2985, app) and PA-I01 (T3015, agent and holder): one
    mechanism, different images.
  - PA-I17 (T3031) and PA-M03 (T3003): the agent's headless terminal
    inherits the preheat that T3003 changes.
  - The four tooling findings extend one script in different phases:
    PA-W05 (T2989), PA-M05 (T3005), PA-V01 (T3033), PA-C02 (T3059).
- **`parity-tasks.ps1 similar -All`** found no other cluster among these
  tasks.

## Re-audit cadence

T3072 is audit-2. It reruns the baseline and a Fable 5.2 re-audit, gives
every PA id above a verdict (fixed with its metric delta / still open /
wrong / changed), files new findings, files any regression against
baseline-1 as a P0, and ends by filing audit-3 the same way. It is parked
until **2026-11-21 or 10 closed PA tasks**, whichever comes first.
The tracker cannot yet re-queue a task on a date or a close count; T3073 adds
that. Until then, the morning triage checks the trigger.

T2957 closes when a re-audit finds no open P0/P1 PA item and no regression.
