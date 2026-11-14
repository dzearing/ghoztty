# Audit-1, area W: the win32 frontend (T2960)

- **Date:** 2026-11-14
- **Commit audited:** 3e92e7fbf
- **Baseline:** `../baseline-1.json` (T2958)

**Produced by** three Fable 5.2 auditors (`claude-fable-5-2`, passed
explicitly) working read-only and in parallel over `src/apprt/win32/`:

1. **A: idle wakeups, timers, message loop and threads.** `App.zig` run
   loop, `gui_pump`, `msg_timer`, every `SetTimer` and polling thread, and
   the threads each pane and window creates.
2. **B: chrome, tab strip and layered overlays.** Paint and repaint cost
   in `Window.zig`, the strip and caption modules, `PaneDesk`,
   `PaneSidebar`, and the overlay windows (banner, dim, hover tint, bell,
   key-state pill, read-only badge, scrollbar).
3. **C: resource lifetimes and idle polling.** GDI, USER and kernel
   handles, per-pane allocations and caches, and the process/CPU samplers.

The viewer panes (T2963) and the renderer and present path (T2959,
`R-findings.md`) were out of scope and are not re-reported.

**Verification.** This turn checked every surviving claim against the code
before filing it, by reading the cited lines, including Zig 0.15.2's own
`lib/std/Thread.zig` for PA-W01. Four pairs of findings were the same defect
seen by two auditors and are merged: A5 = C2 (PA-W06), A2 = C5 (PA-W07),
B7 = C4 (PA-W12), and B9 absorbs C4's brush half (PA-W14).

## What the area does and does not explain

- **Idle wakeups.** The frontend explains about 6 of the 164-213 context
  switches a second that baseline-1 measured with one idle pane: 4 from the
  250 ms visibility poll (PA-W07), about 1.7 from the cursor blink (PA-R04),
  and under 0.1 from minute-scale timers. The message loop blocks in
  `GetMessageW`; FrameClock, the four IPC listeners and parked pool threads
  all block. The other ~150 a second are presumably driver and OS threads,
  which no code reading can confirm: PA-W05 makes the baseline say.
- **Threads.** The frontend creates no per-pane threads. The core creates 3
  per pane (renderer, io, io-reader, `src/Surface.zig:1345/1353`,
  `src/termio/Exec.zig:167`), pooled on Windows (T2644). The other ~51 per
  pane are not Zig threads, which fits PA-R02's per-pane D3D11 and DComp
  devices.
- **Memory.** About 432 MB of the 825 MB the first cycle leaves behind is
  the 16 MB stack each parked pane thread commits (PA-W01).

## Findings

Each finding lists:

- **Where:** file and line
- **Cost:** measured, or estimated (and from what)
- **Fix**, **Risk**, **Pri:** priority
- **Task:** the parity task it was filed as

Nothing here needs a Mac half. PA-W01's file is shared, but only Windows
commits a thread's whole stack up front; macOS pthread stacks are committed
lazily. Everything else is win32-only.

| Id | Pri | Finding | Task |
|---|---|---|---|
| PA-W01 | P0 | Every Zig thread commits a full 16 MB stack; parked pane threads keep ~430 MB after close | T2985 |
| PA-W02 | P1 | A resize outside the modal size loop rebuilds the whole desk every step (~4 ms each) | T2986 |
| PA-W03 | P1 | Every chrome paint redraws caption and strip in full, with two DIB allocations, whatever was invalidated | T2987 |
| PA-W04 | P1 | A title change in a tucked pane of the active tab invalidates the whole window | T2988 |
| PA-W05 | P1 | The baseline cannot attribute idle context switches per thread, or diff handle and USER types | T2989 |
| PA-W06 | P1 | The Activity Monitor creates an OS thread per 1.5 s sample (~64 KB stranded each on NVIDIA) | T2990 |
| PA-W07 | P2 | The visibility poll wakes the UI thread 4 times a second forever, minimized or locked | T2991 |
| PA-W08 | P2 | The grab handle polls the pointer at 20 Hz for as long as it is shown | T2992 |
| PA-W09 | P2 | Every elevated chrome paint reads the light/dark theme from the registry three times | T2993 |
| PA-W10 | P2 | The pane stack grid is heap-built four or five times per chrome paint | T2994 |
| PA-W11 | P2 | The sidebar card material is rebuilt on every height step and desk generation | T2995 |
| PA-W12 | P2 | Strip-label fonts and brushes are created per paint although a cached pair exists | T2996 |
| PA-W13 | P2 | The key-state pill and read-only badge re-render per tick and per move; the pill ticks while occluded | T2997 |
| PA-W14 | P2 | Chrome painters create brushes, pens and regions per paint; `brush_cache` is used only by dialogs | T2998 |
| PA-W15 | P2 | A failed pane init leaks two event handles; the new-tab path also leaks the Surface | T2999 |
| PA-W16 | P2 | Closed pane windows are parked on the composition path, where parking saves nothing | T3000 |

### PA-W01: every Zig thread commits a full 16 MB stack (P0)

- **Where:** Zig 0.15.2 `lib/std/Thread.zig:400`
  (`default_stack_size = 16 * 1024 * 1024`) and `:645-655`, which passes it
  to `CreateThread` with creation flags 0. Without
  `STACK_SIZE_PARAM_IS_A_RESERVATION`, Windows treats that size as the
  initial commit. `src/os/reusable_thread.zig:57` spawns every pooled pane
  thread with the default `SpawnConfig`; no `stack_size` override exists in
  `src/`.
- **Cost:** estimated, consistent with baseline-1. 48 MB of the ~121 MB each
  pane adds; ~432 MB (27 parked threads) of the 825 MB the first cycle leaves
  behind; at least 128 MB of the 323 MB idle private. Private bytes far exceed
  the working set at every cycle sample, which is the shape of committed but
  untouched stack.
- **Fix:** spawn with the reservation flag (or a small explicit commit) on
  Windows, for the pools first and then through a shared spawn helper.
  Confirm with a one-pool A/B before the rest.
- **Risk:** low with the reservation flag (maximum depth unchanged).

### PA-W02: non-modal resizes rebuild the desk every step (P1)

- **Where:** `Window.zig:22473` is the only caller that enables the canvas
  (`WM_ENTERSIZEMOVE`); `PaneDesk.zig:1127` falls back to a new desk per step.
- **Cost:** estimated ~4 ms a step (the repo's note at `PaneDesk.zig:1102`);
  the baseline resize phase (13.8% CPU release, 31.0% debug) is this path.
- **Fix:** arm the canvas on any burst of size changes; settle on a quiet
  timer. **Risk:** medium.

### PA-W03: chrome paints ignore the clip (P1)

- **Where:** `Window.zig:18978-18979`; DIBs at `:18619/:18633` and
  `:19207/:19227`; a region per tab at `:19462`.
- **Cost:** estimated two DIB allocations and N text measurements per paint.
- **Fix:** skip painters outside `GetClipBox`; keep the DIBs; cache widths.
  **Risk:** low.

### PA-W04: a hidden pane's title change repaints the whole window (P1)

- **Where:** `Window.zig:18101-18103`, before the unchanged-title guard at
  `:18112`.
- **Cost:** estimated ~10 full chrome paints a second under a spinner title
  in a tucked pane; PA-W03, W09, W10 and W12 all ride on it.
- **Fix:** invalidate the strip rect only, and only on a real change.
  **Risk:** low.

### PA-W05: the baseline cannot attribute what remains (P1, tooling)

- **Where:** `scripts/perf-baseline.ps1:264` sums context switches over all
  threads; the cycle phase reports totals, not types.
- **Cost:** measured: ~150 idle switches a second, ~51 USER objects, 12
  threads and +10 handles per cycle that no frontend code explains.
- **Fix:** per-thread deltas grouped by module and name; a per-type handle
  and USER diff. **Risk:** none.

### PA-W06 to PA-W16 (P1 and P2)

The full where, cost, fix and risk of each is in its task's Summary
(T2990-T3000); the headline row is in the table above. In brief:

- **PA-W06** `activity_sample.zig:151`, one thread per sample, joined at
  `:145`; `worker_pool.zig:3-5` records the NVIDIA cost per thread. Fix: a
  pooled or long-lived worker.
- **PA-W07** `App.zig:1065`, a 250 ms timer never killed; each tick walks the
  z-order per window (`occlusion.zig:141-156`). Distinct from PA-R16.
- **PA-W08** `pane_grab_handle.zig:209-213`, `keepPolling` is true whenever
  the handle is shown.
- **PA-W09** `Window.zig:1619` to `system_colors.zig:146-153`, uncached
  registry read.
- **PA-W10** `Window.zig:11593`, GPA-built grid per call, 4-5 calls a paint.
- **PA-W11** `PaneSidebar.zig:5388-5404`, cache released on every size or
  desk generation.
- **PA-W12** `Window.zig:13769-13776`, also `:10118`, `:10423`, `:10610`;
  the cached pair is at `:14153-14156`.
- **PA-W13** `KeyStateIndicator.zig:567-571`, `:676/:688`;
  `ReadonlyBadge.zig:175`, `:189`, `:208`.
- **PA-W14** `Window.zig:19126-19128`, `:19174-19176`;
  `PaneSidebar.zig:2350-2372`; `BannerOverlay.zig:1657`, `1706`, `2210`.
- **PA-W15** `Surface.zig:904/907` (no errdefer; first errdefer at `:955`);
  `Window.zig:3893-3894` (no destroy on failure).
- **PA-W16** `Surface.zig:1533` parks the window; on the helper path
  (`Surface.zig:1003-1004`) it never had a pixel format to save. Also removes
  the PA-R17 hazard (T2983).

## Claims that did not survive verification

- **A4, "drop thread pooling for the io and io-reader pools; only the
  renderer touches GL".** Rejected. `src/termio/Exec.zig:33-35` records that
  ANY thread exiting while a GL context is alive strands NVIDIA driver memory,
  so the io-reader pooling is load-bearing. PA-W01 shrinks what a parked
  thread costs instead.
- **A, "comp_overlay.zig does not exist, so the R audit's ~55-threads
  citation needs re-checking".** Wrong: it is `src/renderer/comp_overlay.zig`,
  and the note is at `:879`.
- **"A 60 Hz UI timer runs at idle"**, **"the IPC listeners poll"**,
  **"applyOcclusion re-lays out every 250 ms"**, **"the termios poll runs on
  Windows"**: each rejected by auditor A from the code (all 16 ms timers are
  animation-scoped; the listeners block in `ConnectNamedPipe`; a visible
  window returns at `Window.zig:4735`; the poll is compiled out at
  `src/termio/Exec.zig:200`).
- **"Whole-window RedrawWindow storms"**, **"the banner reallocates per
  frame"**, **"caption and strip are double-invalidated on WM_SIZE"**:
  rejected by auditor B (config/mode changes only; the present bitmap only on
  change; the two invalidations coalesce).
- **"Close-undo leaks panes"**, **"the class brush leaks on config change"**,
  **"process-tree or CPU sampling runs at idle"**: rejected by auditor C
  (entries are finalized on expiry; the old brush is deleted; no sampler runs
  without its panel or chooser open).

## Checked and found fine

Message loop (blocking `GetMessageW`, coalesced core wakeups,
`App.zig:2383`, `:2881-2892`); FrameClock waits `INFINITE` when idle; busy
light, hero heartbeat, key-state, agent-watch, layout-refresh and sidebar
motion timers all stop when idle; per-pane overlays destroy their windows,
fonts and timers in `Surface.deinit`; DPI and theme changes free the old fonts
and brushes; popup menus and deferred window positioning are paired; pane-keyed
collections are pruned; no hooks, raw input or `timeBeginPeriod` anywhere in
the frontend.
