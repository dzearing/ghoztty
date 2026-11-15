# Audit-2, area M: memory and leaks (T3072)

- **Date:** 2026-11-14
- **Commit audited:** 879fba35a
- **Input:** `../audit-1/M-findings.md` (PA-M01..PA-M12 at a8349acb1) and the
  M table in `../audit-1.md`
- **Produced by** Fable 5.2 (`claude-fable-5-2`), one auditor, read-only. No
  build, no test run, no app launch: every cost below is estimated, computed
  or inferred, never measured this turn.

**Method.** Every cited line was read at HEAD, not grepped. `git log
a8349acb1..HEAD` over the files the twelve findings cite shows only three
commits touching them: T2974 and T2970 in `src/renderer/Thread.zig`, and
T2973 in `scripts/perf-baseline.ps1`. `PageList.zig`, `Surface.zig` (win32),
`PaneDesk.zig`, `chrome_comp.zig`, `IpcHandlers.zig`, `App.zig` (win32),
`Window.zig`, `DirectoryProbe.zig`, `AgentIntegration.zig`, `cell.zig` and
`discovery.zig` are byte-identical to audit-1, so their line numbers still
hold. The ten fix commits named in the brief were then read for memory they
free, keep or add.

Confidence markers: **V** = read and traced at HEAD; **I** = inferred from
documented platform behavior on top of code that was read.

## Verdicts

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-M01 | still open (V) | `src/apprt/win32/Surface.zig:2656-2670` (buffer), `:2819-2844` (DIB), freed only at `:1387-1395` | `snapRequest` reallocs on a size change and nothing else frees; the DIB is deleted only on a size change or in deinit | T3001 unchanged |
| PA-M02 | still open (V) | `src/apprt/win32/PaneDesk.zig:2508-2510` (`desk_buf`, "Grown, never shrunk"), `:296` (`light_alloc`), `:1139-1152` (deinit); `src/apprt/win32/chrome_comp.zig:359-362` | no shrink, trim or `clearAndFree` anywhere in either file; T2974 trims only the renderer's GPU storage, not these CPU buffers | T3002 unchanged; add one line that T2974 did not cover it |
| PA-M03 | still open (V) | `src/terminal/PageList.zig:34`, `:327`, `:370-374` | `page_preheat = 4`, `std.heap.page_allocator` off Darwin, pool preheated with 4 | T3003 unchanged |
| PA-M04 | still open (V) | `src/terminal/PageList.zig:3459-3483` (memset at `:3476`, back to the pool at `:3477`); only `reset()` `:686-735` shrinks | unchanged file | T3004 unchanged |
| PA-M05 | changed (V) | `scripts/perf-baseline.ps1:503` (`foreach ($c in 1, 2)`), `:555` (delta at cycle 2) | the tool gap is intact, but the numbers it was filed on are stale and three new knobs exist | T3005: rewrite the evidence and the A/B list, see below |
| PA-M06 | still open (V) | `src/apprt/win32/IpcHandlers.zig:1369-1381` (lock, whole-screen selection, dump), `:1408` (tail) | unchanged file | T3006 unchanged |
| PA-M07 | still open (V) | `src/apprt/win32/App.zig:9202-9258` | the handler body never reads `target` | T3007 unchanged |
| PA-M08 | changed (V) | `src/apprt/win32/DirectoryProbe.zig:155`, `src/apprt/win32/AgentIntegration.zig:171` | both still `std.Thread.spawn(.{}, ...)`; since T2985 that default is the documented 16 MB commit while the thread lives | T3008: add the 16 MB transient commit and fold or link with T3075, see below |
| PA-M09 | still open (V), one more site | `src/renderer/Thread.zig:247`; `src/datastruct/blocking_queue.zig:102-105`; `src/termio/mailbox.zig:47-54`; new: `src/termio/Thread.zig:354-357` | renderer mailbox destroyed undrained; the termio drain mode pops and drops messages without freeing `write_alloc` payloads | T3009: add the termio drain-mode site |
| PA-M10 | still open (V), cost grew | `src/renderer/cell.zig:118-122` | unchanged; T2972 added a second CPU copy of the same cells (PA-M15) | T3010 unchanged; cross-link PA-M15 |
| PA-M11 | still open (V) | `src/font/discovery.zig:1050-1085` (`tryMatch`), `:959-1009` (directory walk), `:1091-1099` (`matches`) | unchanged file | T3011 unchanged |
| PA-M12 | still open (V) | `src/apprt/win32/Window.zig:2477-2484` (`deinit`) against `:21927-22019` (`onDestroy`) | `compDragThreadStop()` is called only at `:2479` and `:16598`; `onDestroy` cancels no dialog | T3012 unchanged |

No PA-M item is fixed and none is wrong. Two changed in shape (M05, M08) and
two picked up an extra site or cost (M09, M10).

## Changed items

### PA-M05: the tool gap stands, the evidence is stale

- **Still true (V):** the cycle phase runs exactly two cycles
  (`perf-baseline.ps1:503`) and takes its one delta at cycle 2 (`:555`). No
  warm-up, no slope, no region census.
- **What moved:** the three numbers audit-1 used to argue for it were all
  produced by code that has since changed.
  - T2985 (90e57ab70) removed the 16 MB-per-thread commit; its message
    measures 547 MB less left behind after ten panes close.
  - T2968 (29302f08c) replaced the per-pane D3D11 device with one process
    device, so the "first-cycle residue is per-pane driver memory" inference
    (PA-R02) no longer describes HEAD.
  - T2974 (6711c4e45) makes GPU storage shrink one second after a size
    settles. The cycle phase samples 4 s after open and 3 s after close
    (`:535`, `:542`), so trims now land inside the sampled windows.
- **What T3005 should now say:**
  - Re-run the baseline first; do not carry the 29 MB / 390 MB / 14-22 MB
    figures forward.
  - The A/B list is now three knobs, not one: `GHOZTTY_COMP_PRESENT=0`,
    `GHOZTTY_COMP_SHARED_DEVICE=0`
    (`src/renderer/gl_comp_present.zig:112-124`) and
    `GHOZTTY_STORAGE_TRIM=0` (`src/renderer/storage_trim.zig:29-46`).
  - Keep the adaptive warm-up, 5-cycle slope and heap census as filed.
  - Add a closed-and-idle sample that is taken before any other pane
    presents, to settle PA-M14.

### PA-M08: a transient 16 MB commit on top of the stranded 64 KB

- **Still true (V):** `DirectoryProbe.zig:155` and
  `AgentIntegration.zig:171` spawn one detached OS thread per event.
- **What moved:** T2985 established and unit-tests
  (`src/os/thread_stack.zig:1-19`, `:88-101`) that `std.Thread.spawn(.{})`
  on Windows commits the full 16 MB stack for the thread's life. T2985 moved
  the long-lived threads to `thread_stack.config`; these two sites were not
  moved. So each directory poll and each agent re-check commits 16 MB of
  private bytes while it runs, not just the ~64 KB of driver memory audit-1
  counted.
- **Overlap:** T3075 (filed by T2985, P2) covers the remaining ~35 `.{}`
  sites in `src/apprt/win32` by switching them to `thread_stack.config`.
  That fixes the 16 MB but not the thread-per-event churn or the driver
  residue. Running both on `worker_pool` (which already spawns with
  `thread_stack.config` through `src/os/reusable_thread.zig:61`, `:116`)
  fixes all three.
- **What T3008 should now say:** cost is 16 MB commit while alive plus
  ~64 KB stranded per thread; fix is still `worker_pool`; note that doing so
  removes both sites from T3075's list.

### PA-M09: one more site

- `src/termio/Thread.zig:354-357`: when `flags.drain` is set the mailbox is
  emptied with `while (mailbox.pop()) |_| {}`. A `write_alloc` message
  (`src/termio/message.zig:101`) owns a heap buffer, and this path drops it
  unfreed. Same class as the filed defect (payload-owning messages discarded
  at shutdown), reached on every pane close that has a large write queued.
  Shared core, so it joins T3013's Mac half.

### PA-M10: cost is now paid twice

- Unchanged at `cell.zig:118-122`, but since T2972 the same cell data also
  lives in a per-buffer shadow copy (PA-M15). Starting rows at 1x no longer
  removes all of the per-pane CPU cell memory; T3010 and PA-M15 should be
  sized together.

## New findings

| Id | Pri | Finding |
|---|---|---|
| PA-M13 | P2 | A pane hidden behind another tab never runs the T2974 trim, so it keeps its high-water GPU storage until it is shown again |
| PA-M14 | P2 | A closed pane's swap chain and shared texture are released on the shared device with no flush, so their memory can outlive the pane while the app is idle (inferred) |
| PA-M15 | P2 | T2972's shadow copies double the CPU memory of every cell buffer, sized at 2x the high-water need, and never shrink |

### PA-M13: the trim only runs on a frame, and a hidden pane draws none (P2)

- **Where (V):** `src/renderer/Thread.zig:576-578` (`drawFrame` returns
  when `!flags.visible`), `:590-594` (`armStorageTrim` is called only after a
  drawn frame), `:609-621` (`trimCallback` forces a frame that the same early
  return then drops), `:818-821` (`renderCallback` skips hidden panes).
  The trim decision itself is made in `OpenGL.surfaceSize`
  (`src/renderer/OpenGL.zig:1309-1312`), which only runs inside a frame.
  A background tab reports hidden through `Surface.setVisible`
  (`src/apprt/win32/Surface.zig:1842-1862`).
- **Mechanism:** maximize a window (the active tab's panes grow their
  target, shared texture, swap chain and slot textures), switch tab within
  the one-second settle or at any time before restoring, then restore the
  window. The now-hidden tab's panes hold maximized-size storage. The armed
  timer fires once, is dropped by the visibility check, and nothing re-arms
  it. `releaseHiddenTargets` does not help: on Win32 it runs only when the
  whole window is hidden (`OpenGL.zig:1582-1591`), and it frees only the
  frame targets, never the presenter's shared texture or swap chain.
- **Cost (estimated, from T2974's own figures):** up to ~150 MB of GPU
  memory per 4K full-window pane, ~22-25 MB per 1400x860 pane, for every pane
  in a tab that was last shown at a larger size. It ends when the tab is
  next shown (first frame notes the size, the trim lands a second later).
- **Fix in brief:** when `.visible` goes false with `storage.oversized` set
  (or with the settle still pending), let one trim pass run before the pane
  goes quiet: rebuild the storage at the current client size without
  presenting. Alternatively allow `trimCallback`'s forced frame through the
  visibility check when its only purpose is the trim.
- **Risk:** low. Hero mode reads background tabs' targets, so the pass must
  rebuild and redraw, not drop.
- **Regression of:** T2974 (a gap in its coverage, not a new leak).

### PA-M14: no flush after a pane's D3D objects are released on the shared device (P2, inferred)

- **Where (V):** `src/renderer/gl_comp_present.zig:1101-1126`
  (`releaseCom`: releases the visual, target, swap chain, context and device,
  and nothing else), `:935-949` (`destroyShared`). The file contains no
  `Flush` or `ClearState` call at all.
- **Mechanism (I):** D3D11 destroys a released object lazily, when the
  immediate context is next flushed. Before T2968 each pane owned its device,
  so the pane's last release destroyed the device and everything on it.
  Since T2968 (`DeviceCache`, `:379-441`) the device and its one immediate
  context live for the process, so a closed pane's flip-model buffers and
  shared texture wait for some other pane's `Present` to flush them. T2970
  and T1935 mean idle panes no longer present at all, so in an idle app that
  flush may not come.
- **Cost (estimated):** the closed pane's swap-chain buffers plus its shared
  texture: roughly 3 x w x h x 4, ~15 MB at 1400x900 and ~100 MB at 4K, held
  until any remaining pane next presents. Not a leak: it is bounded and it
  ends on the next frame anywhere. It can show up as residue in exactly the
  closed-and-idle samples PA-M05 measures.
- **Fix in brief:** measure first (close a pane with every other pane idle,
  read GPU dedicated memory before and after poking a frame). If confirmed,
  call `ID3D11DeviceContext::Flush` at the end of `releaseCom` when
  `shared_device` is set, and after the trim's `destroyShared` only if the
  frame is then dropped before `Present`.
- **Risk:** low. One flush per pane close.
- **Regression of:** T2968, if the measurement confirms it.

### PA-M15: cell-buffer shadows (P2)

- **Where (V):** `src/renderer/opengl/buffer.zig:10` (`shadow_alloc =
  std.heap.page_allocator`), `:38-41` (the `shadow` field), `:83-91`
  (`prepareShadow` sizes it to the GL buffer's capacity), `:113-121` and
  `:144-152` (capacity becomes 2x the need and never comes down);
  `src/renderer/upload_diff.zig:46-55` (`reset` reallocates only on a
  capacity change).
- **Mechanism:** every buffer that is `sync`ed now keeps a CPU mirror the
  size of its GL data store. The stores for foreground cells
  (`frame.cells`, 32-byte `CellText`), background cells (`frame.cells_bg`,
  4 bytes a cell) and the two small ones grow to twice the largest frame
  ever synced. The T2974 settle trim covers render targets and swap chains,
  not these buffers, so a pane that was once large keeps a large GL buffer
  and now an equal block of private bytes beside it.
- **Cost (computed):** up to 2 x (glyphs x 32 + cells x 4) bytes of private
  commit per pane. A full 170x45 screen is ~0.55 MB; a full 480x120 screen is
  ~4.1 MB; both stay at the high-water size after the pane shrinks. This is
  on top of PA-M10's 3x row preallocation.
- **Fix in brief:** grow the store by a smaller factor (1.25x, or to the
  grid's exact cell count for `cells_bg`, whose size is known from the grid),
  and rebuild store plus shadow when a settled frame needs under a quarter of
  the capacity (the T2974 settle is the natural hook).
- **Risk:** low. A rebuild costs one full upload.
- **Regression of:** T2972. Small, and the shadows are freed correctly with
  their buffers (`buffer.zig:78-82`, reached from `FrameState.deinit`,
  `src/renderer/generic.zig:513-522`, including the lost-device rebuild at
  `:1139-1147`).

## Fix commits: what was checked

| Commit | Task | Memory verdict |
|---|---|---|
| 8d2be0f7b | T2967 | Clean. A pure counter (`generic.zig` `terminalStateRecycleDue`). Side note: the retained `RenderState` is recycled per 100,000 built frames, so an idle pane keeps it; that is upstream's rule, not a regression |
| 29302f08c | T2968 | Per-pane state is released: `Presenter.deinit` (`gl_comp_present.zig:1080-1085`) frees the interop handle, texture, swap chain, both handles and one device and context reference each. The `init` error paths were traced (`:680-682`, `:713-715`, `:742-746`, `:799-802`): no double release, no dropped handle. The cache keeps one device for the process by design. One finding: PA-M14 |
| 2cdc77abe | T2970 | Clean. No allocation; a timer stops |
| 5672c7165 | T2971 | Clean. A pure predicate that skips work; no cache added |
| 60ae989a0 | T2972 | One finding: PA-M15 |
| 396aac1db | T2973 | Clean. The dirty-row record is a fixed 32-entry ring inside `Atlas`. T3090 (atlas never shrinks) is already filed |
| 6711c4e45 | T2974 | The rebuild paths free what they replace: the target through `frame.resize` (`generic.zig:2036-2040`), the shared texture through `destroyShared` before `createShared`, the swap chain through `ResizeBuffers`, the slot through re-specifying its storage (`OpenGL.zig:1673-1676`). The timer is deinited (`Thread.zig:243`). Attempts are capped at 3 per settle, so it cannot loop. One finding: PA-M13 |
| 90e57ab70 | T2985 | Clean. Stacks grow into the 16 MB reserve and keep their high-water commit while a pooled thread is parked; that is at most what was committed before. Remaining `.{}` sites are T3075 and PA-M08 |
| fc7f7fdfb | T3015 | Clean (agent image only; spawn config change) |
| dacab7bec | T3058 | Clean. A comparison change in `src/Surface.zig`; no allocation |

## Checked and found clean

- `Presenter` lifetime on the shared device, success and failure paths.
- `upload_diff.Shadow` ownership: allocated on first sync, freed in
  `Buffer.deinit`, reset rather than leaked on a GL reallocation.
- `storage_trim.Settle`: no heap state.
- `Thread.deinit` deinitializes every timer it creates, including `trim_h`.
- `src/apprt/win32/ViewerPane.zig:11429`, `:11539`, `:12306`: three
  `std.Thread.spawn(.{})` serve threads that looked pane-lifetime are test
  fixtures (`TestPage`, `ReloadPage`, `PopupPage`), not product code.
- Audit-1's "Claims that did not survive" and "Checked and found clean"
  lists were not re-walked beyond the files the fix commits touched.

**Not covered:** anything that needs a run (all costs above), viewer
internals, the agent beyond T3015's spawn sites, and the Mac half of the
shared-core items.

## Suggested filing

- **PA-M13** -> new task, P2, seat win, follow-up of T2974
- **PA-M14** -> new task, P2, seat win, follow-up of T2968; first step is the
  measurement, and it can ride on T3005
- **PA-M15** -> new task, P2, seat win, follow-up of T2972; pair with T3010
- **T3005** -> rewrite the evidence and A/B list (PA-M05)
- **T3008** -> add the 16 MB transient commit; link T3075 (PA-M08)
- **T3009** -> add `src/termio/Thread.zig:354-357` (PA-M09)
- **T3002** -> note T2974 did not cover the CPU chrome buffers
