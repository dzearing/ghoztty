# Audit-4, area M: memory and leaks (T3151)

- **Area:** M, memory and leaks (whole app, Windows build)
- **Date:** 2026-11-21
- **This file:** audit-4, a re-audit of `../audit-3/M-findings.md`
- **Commit audited:** c9af15802 (audit-3 was d0d874326)
- **Input:** `../audit-3/M-findings.md` (PA-M01..PA-M17), `../audit-4.md`
  (baseline-4), and `../audit-1/M-findings.md` / `../audit-2/M-findings.md`
  for the original descriptions
- **Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. No
  build, no test run, no app launch: every cost below is computed or
  inferred from the code, or quoted from a fix commit, a task file or
  baseline-4. None was measured this turn.

**Method.** Every cited line was read at HEAD, not grepped. `git log
d0d874326..HEAD` was read over the files the seventeen PA-M ids cite, and
the task file of every id was read for its status. For each commit since
audit-3 that changes what memory is held (T1590, T3017, T3040, T3041, T3074,
T3095, T3183, T3191/T3192, T3235) the source hunks were read and the code at
HEAD traced. No fix is claimed from a commit message.

Confidence markers: **V** = read and traced at HEAD; **I** = inferred from
documented platform behavior, or from a mechanism this repo measured on a
sibling path, on top of code that was read.

## What moved since audit-3

`git diff --stat d0d874326 HEAD` over the files the PA-M ids cite, plus the
new files that hold memory:

| File | Lines | Commits (task) |
|---|---|---|
| `src/apprt/win32/App.zig` | +833 | 073c924a7 (T1590) closes PA-M07; T3191 (workspaces) |
| `src/apprt/win32/Window.zig` | +1103 | T3191, T3192 (`surrenderWindow`, `releaseWindowBound`), T3183, T3279 |
| `src/apprt/win32/ViewerPane.zig` | +1381 | 663e4a850 (T3041, `glass_buf`), T3035, T3224, T3245 (area V) |
| `src/apprt/win32/viewer_toc_comp.zig` | +43 / -44 (net) | e15858510 (T3040) |
| `src/apprt/win32/chrome_comp.zig` | +31 | 1cde0416f (T3074) |
| `src/apprt/win32/PaneDesk.zig` | +40 | f6c863aa5 (T3183, `scratch_fade`) |
| `src/apprt/win32/IpcHandlers.zig` | +213 | not the `+read` path (lines moved only) |
| `src/apprt/win32/Surface.zig` | +150 | not the snapshot path (lines moved only) |
| `src/renderer/gl_comp_present.zig` | +23 | T3040, T3074 (`processDevice`, a comment) |
| `src/renderer/Thread.zig` | +11 | 5059acb10 (T3061) |
| `src/os/thread_stack.zig` | +47 | 99efd0c58 (T3095, `poolOptions`) |
| `src/remote/agent/main.zig`, `proc.zig`, `session.zig` | +16, +147, +648 | 674561478 (T3017), 342064c1c (T3235) |
| `scripts/perf-baseline.ps1` | +1026 | T3033, T3059, T3111, T3130, T3235 |

Unchanged since audit-3: `src/terminal/PageList.zig`, `page_pool.zig`,
`src/font/*`, `src/renderer/cell.zig`, `generic.zig`, `OpenGL.zig`,
`opengl/buffer.zig`, `upload_diff.zig`, `src/datastruct/blocking_queue.zig`,
`src/termio/mailbox.zig`, `src/termio/Thread.zig`,
`src/apprt/win32/DirectoryProbe.zig`.

No task in the PA-M list closed since audit-3: T3006-T3010, T3012, T3096,
T3097, T3098, T3145 (PA-M16, filed as PA-V27) and T3150 (PA-M17) are all
`todo` with no commits. PA-M07 was fixed by a task outside the list (T1590).

## Verdicts

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-M01 | **fixed** (V, high), as audit-3 | `src/apprt/win32/Surface.zig:2870-2902` (publish frees the landing buffer), `:2912-2933` (`releaseSnapshot`); `src/apprt/win32/Window.zig:13517-13526` (`releaseIdleSnapshots`), called at `:13548` (glide end), `:8643` and `:9417` (hero exit); `:6641` (drag end) | snapshot code unchanged, lines moved | T3001 stays done |
| PA-M02 | **fixed** (V, high), as audit-3 | `src/apprt/win32/PaneDesk.zig:336-348` (`fitList`), `:2609-2616`, `:2625` (`ensureDesk`); `src/apprt/win32/chrome_comp.zig:400-415` (`Overlay.fit`) | T3183 added `scratch_fade` (`:2644-2656`): a sixteenth-size gradient, allocated during a workspace fade, freed by the first desk build after it (`:2656`), and in `deinit` (`:1240`). Desk buffers do not change size across fade frames, so `fitList` does not reallocate | T3002 stays done |
| PA-M03 | **fixed** (V, high), as audit-3 | `src/terminal/PageList.zig:40`, `:84-87`; `src/terminal/page_pool.zig:140-154` | files unchanged | T3003 stays done |
| PA-M04 | **fixed** on Windows (V, high), as audit-3 | `src/terminal/PageList.zig:53`, `:3509-3520`; `src/terminal/page_pool.zig:99-107` | files unchanged | T3004 stays done. Mac half T3013 still `todo` |
| PA-M05 | **fixed** (V, high), as audit-3 | `scripts/perf-baseline.ps1:101-104` (`-SettledCycles`), `:751-760` (region census), `:769` (slope), `:1579-1581` | the settle-then-slope method is intact; T3130 added a per-allocation split of `private_rw` (`:635-718`) | T3005 stays done |
| PA-M06 | still open (V, high) | `src/apprt/win32/IpcHandlers.zig:1427-1436` (priority lock, whole-screen selection, dump), `:1462` (tail) | same code, new lines | T3006: new lines |
| PA-M07 | **fixed** by 073c924a7, T1590 (V, high) | `src/apprt/win32/App.zig:9830-9909`, the gate at `:9848-9851` | the handler now returns at once for a `.surface` target; the config clone, brush, every window's `onConfigChange`, Settings, hotkeys run once, for `.app`. The second half of the finding (one pane's conditional config overwriting `App.config`) is gone with it | **Close T3007 as fixed by T1590** (it is still `todo`) |
| PA-M08 | still open (V, high) | `src/apprt/win32/DirectoryProbe.zig:155`, `src/apprt/win32/AgentIntegration.zig:155`, `:171` | still `std.Thread.spawn(.{}, ...)`. T3095 fixed the pool (`sheet_workers.zig:47`), not these | T3008: add `:155` |
| PA-M09 | still open (V, high), in audit-3's shape | `src/renderer/Thread.zig:274`; `src/termio/Thread.zig:358-361`; `src/termio/mailbox.zig:131-139` | three places a queued payload is dropped; nothing moved | T3009 unchanged |
| PA-M10 | still open (V, high) | `src/renderer/cell.zig:118-122` | file unchanged | T3010 unchanged |
| PA-M11 | **fixed** (V, high), as audit-3 | `src/font/WindowsFontIndex.zig:118-141`, `:179`; `src/font/discovery.zig:917-934` | files unchanged | T3011 stays done. `:353` is still a default-stack spawn (T3075) |
| PA-M12 | **changed**: a third path (V, high for the code; I for how often) | `src/apprt/win32/Window.zig:2612-2619` (`deinit`), `:22948-23042` (`onDestroy`), new: `:7675-7729` (`surrenderWindow`) and `:2690-2729` (`releaseWindowBound`) | see below | T3012: add the surrender path |
| PA-M13 | **changed**: one more hidden state (V, high) | `src/renderer/Thread.zig:607-609`, `:624`, `:632-652`; `src/renderer/gl_comp_present.zig:961-966`, `:986-991`, `:695`; `src/renderer/OpenGL.zig:1589-1593`, `:1646-1658`; new: `src/apprt/win32/Window.zig:7645-7653` (`parkPaneHidden`) | see below | T3096: add parked workspaces |
| PA-M14 | still open (V for the code, I for the mechanism) | `src/renderer/gl_comp_present.zig:1134-1160` (`releaseCom`), `:961-981`; `src/renderer/OpenGL.zig:1646-1658` | no `Flush` or `ClearState` in the file. The shared device has two more holders since audit-3 (`processDevice`, `:459-466`: the viewer contents card, and the chrome host when its knob is on), which release D3D objects on it the same way | T3097 unchanged; measure first |
| PA-M15 | still open (V, high) | `src/renderer/opengl/buffer.zig:11`, `:41`, `:85-90`, `:116`, `:146`; `src/renderer/upload_diff.zig:46-55` | files unchanged | T3098 unchanged |
| PA-M16 | still open (V, high) | `src/apprt/win32/ViewerPane.zig:6190-6202` (`releaseSnapshot`, the in-flight return at `:6195`), `:6127-6135`, `:6055-6125`; `src/apprt/win32/Window.zig:8717` | the release still does nothing while a capture is out. T3041 added one line above the return (`:6194`, frees the glass buffer), which does run | T3145 (filed as PA-V27), `todo` |
| PA-M17 | still open (V, high) | `src/apprt/win32/PaneDesk.zig:2356`, `:336-348` | unchanged | T3150, `todo` |

Seven fixed (one new this round), eight still open, two changed, none
incomplete, none wrong.

## Changed items

### PA-M12: surrendering the window is a third teardown twin

- **Still true (V):** `compDragThreadStop()` is called only from `deinit`
  (`Window.zig:2614`) and the divider drag's own end (`:17419`). `onDestroy`
  (`:22948-23042`) calls neither it nor the three dialog `cancel()`s.
- **What moved:** single-window mode (T3191) added `surrenderWindow`
  (`:7675-7729`). It does cancel the three dialogs (`:7679-7681`), then calls
  `releaseWindowBound` (`:7722`, body `:2690-2729`), which tears the chrome
  host down. Neither stops the drag's composition thread, and nothing there
  clears `dragging_split`.
- **Mechanism (I for reachability):** a workspace switch by key or IPC while
  a divider is held leaves the thread running on the parked workspace. It
  holds its own reference on the DComp device (`CompDragThread.zig:141`)
  and on every pane visual it was given (`:167`), so nothing is freed under
  it, but it keeps ticking at frame rate until that workspace's `deinit`.
- **Size:** one thread, one DComp device reference, per occurrence. Rare.
- **What T3012 should now say:** one shared "window is going" routine for
  `deinit`, `onDestroy` and `surrenderWindow`: stop the drag thread, end the
  divider drag, cancel the dialogs.

### PA-M13: a parked workspace is one more state that keeps the swap chain

- **Still true (V):** the trim cannot run while hidden. `drawFrame` returns
  at `src/renderer/Thread.zig:609` before `armStorageTrim` (`:624`), and
  `trimCallback` (`:639-652`) only forces a frame the same check drops. The
  hidden release frees the shared texture (`gl_comp_present.zig:961-966`) and
  keeps the two-buffer swap chain (`:695`; `OpenGL.zig:1650-1654`).
- **What moved:** T3192 hides every pane of a parked workspace
  (`Window.zig:7645-7653`, called from `surrenderWindow` at `:7717` and
  `holdParkedPanes`). Before, only background tabs, zoomed-over and stashed
  panes were hidden. Now every pane of every workspace but the one on show
  is, for as long as it is parked.
- **Cost (computed):** unchanged per pane, 2 x w x h x 4 at the size the pane
  was last shown: ~10 MB at 1400x900, ~66 MB for a full-window pane at 4K.
  The count is what grew: all panes of all parked workspaces.
- **What T3096 should now say:** as audit-3 (shrink or drop the swap chain in
  the hidden release), with parked workspaces as the case that makes it
  worth doing: a parked pane's last frame is not needed for a tab reveal.

## Fix-commit review

| Commit | Task | Verdict |
|---|---|---|
| 073c924a7 | T1590 | Fixes PA-M07 (above). One behavior note outside this area, not traced: a surface-only soft reload (a pane's color scheme flips) no longer reaches any app-level work, by design; whether the chrome still follows a system theme change through another path was not checked |
| 99efd0c58 | T3095 | Clean. `poolOptions` (`src/os/thread_stack.zig:48-50`) passes the 64 KB commit hint to `std.Thread.Pool`; `sheet_workers.zig:47` uses it. The measured test spawns a real worker and reads its stack back |
| 1cde0416f | T3074 | Clean for memory: the chrome host takes a reference on the process device (`chrome_comp.zig:999-1007`) and releases it in `deinit` (`:2386-2387`); `errdefer` covers the init path. It does not change `Host.deinit`'s order, which is **PA-M19**. Thread rule (only the GUI thread binds pipeline state) is area R's to check |
| e15858510 | T3040 | Does what it says for the D3D device. It also makes `viewer_toc_comp.Host.deinit` run after every slide instead of once per viewer, and that teardown has the order T2772 proved leaks: **PA-M18** |
| 663e4a850 | T3041 | Removes the per-paint whole-pane DIB. The buffer it keeps instead is never shrunk and is not released when the pane is hidden: **PA-M20** |
| 674561478 | T3017 | The allocator swap is the cause baseline-4 suspects for the release agent's memory: **PA-M21** (tracked as T3244) |
| 342064c1c | T3235 | Clean. The process-table buffer is allocated and freed inside each call (`src/remote/agent/proc.zig:1353-1354`), sized from the last answer (`:1369`); the parent map is freed on every error path (`:1383-1402`). Note, not a finding: under `smp_allocator` a buffer of 64 KB or more is a `VirtualAlloc`/`VirtualFree` pair per tick (inferred from `SmpAllocator.zig:121`, `:154`); T3243 (done) stops a local agent from sampling at all |
| f6c863aa5 | T3183 | Clean (see PA-M02 row). During a fade every frame rebuilds the desk; that is CPU, area W |
| 64e0ae1a6, c513c69cc | T3191, T3192 | `releaseWindowBound` frees every window-sized buffer of a parked workspace: desk, mirrors, overlay, flat desk, strip labels, fonts (`Window.zig:2698-2728`). Each `deinit` it calls leaves the field reusable for the adopt (`PaneDesk.zig:1235-1253`, `chrome_comp.zig:297-305`, `:352-356`, `:498-502`, `strip_label.zig:91-96`). Two notes folded into PA-M12 and PA-M13 |

## New findings

| Id | Pri | Finding |
|---|---|---|
| PA-M18 | P2 | The viewer contents card's compositor host is now torn down after every slide, in the order T2772 proved leaves DComp objects alive |
| PA-M19 | P3 | The chrome composition host (opt-in) has the same teardown order, and single-window mode now runs it on every workspace switch |
| PA-M20 | P2 | A viewer on glass keeps a pane-sized pixel buffer at its high-water size, also while its tab or workspace is hidden |
| PA-M21 | P2 | Release agents and session holders hold ~5-8 MB more each since they moved to `smp_allocator` (already T3244) |

### PA-M18: the contents card's DComp teardown commits before it releases (P2)

- **Where (V):** `src/apprt/win32/viewer_toc_comp.zig:170-184` (`Host.deinit`:
  `SetRoot(null)` at `:175`, `Commit` at `:176`, then `release` of the
  surface, card visual, root visual and target at `:177-180`, then the DComp
  device at `:181`; no commit after the releases);
  `src/apprt/win32/ViewerTOCPanel.zig:1295-1298` (`releaseComp`), called when
  a slide ends, is cancelled or fails (`:1221`, `:1273`, `:1284`, `:1288`).
- **Mechanism (I, from T2772's measurement):** DirectComposition destroys a
  released object only at its device's next `Commit`. T2772 proved this on
  two sibling paths by `Release()` counts: the device was left at 3
  references with a commit before the releases and at 0 with one after, and
  each pending object kept the device and its surfaces alive for the life of
  the process. `child_comp.Tree.deinit` (`child_comp.zig:280-293`) and
  `Presenter.releaseCom` (`gl_comp_present.zig:1134-1160`) both now release
  first and commit after. This host does not. Until T3040 that happened once
  per viewer, at close. Since T3040 it happens after every slide of the
  card, in and out.
- **Cost (inferred, not measured):** per slide, one DComp device, two
  visuals and one card-sized surface (w x h x 4 of GPU memory, under 1 MB for
  a 280x700 card) that are never destroyed. The D3D11 device is the shared
  one, so no driver threads go with it. T3040's own criterion for this
  ("thread count and GPU memory return to the pre-slide value") is unticked;
  T3219 (`todo`) is the measurement. The second slide's `CreateTargetForHwnd`
  succeeds in T3040's test (`declared=2 failures=0`), so the target itself is
  let go; the visuals and the surface are the open question.
- **Fix in brief:** the order `child_comp.Tree.deinit` uses: detach, release
  surface, visuals and target, `Commit`, then release the device. Verify the
  way T2772 did, by the count `Release()` returns for the device.
- **Risk:** low.
- **Regression of:** T3040 (e15858510) for the frequency; the order is older.

### PA-M19: the chrome host's teardown has the same order (P3)

- **Where (V):** `src/apprt/win32/chrome_comp.zig:2363-2390` (`Host.deinit`:
  commits at `:2367` and `:2370`, then releases the face and pane roots, the
  pane target, the fill, the desk tree through `releaseDesk` (`:2331-2346`:
  shadow root, caption, overlay, glows, hero slide, root visual, desk
  surface and visual), the backstop, the target and the device, with no
  commit after). Callers: `Window.releaseWindowBound`
  (`src/apprt/win32/Window.zig:2698`), which runs at window close and, since
  T3191, at every workspace surrender (`:7722`); and the device-loss rebuild
  (`chrome_comp.zig:2428`).
- **Mechanism (I):** as PA-M18. The objects here are larger: the desk
  surface and the overlay surface are window-sized.
- **Cost (inferred):** per teardown, a DComp device and up to two
  window-sized surfaces (2 x w x h x 4: ~10 MB at 1400x900, ~66 MB at 4K) of
  GPU memory never destroyed. Only with `GHOZTTY_COMP_CHROME=1`
  (`chrome_comp.zig:69`, `:85-88`: off unless set), which is why this is P3.
  In single-window mode with the knob on it would be paid on every workspace
  switch.
- **Fix in brief:** release first, commit once after, then release the
  device. Must land before the knob becomes the default.
- **Risk:** low.
- **Regression of:** none for the order; T3191 (64e0ae1a6) raised how often
  it runs.

### PA-M20: a glass viewer's sheet buffer is grow-only and survives hiding (P2)

- **Where (V):** `src/apprt/win32/ViewerPane.zig:705-709` (`glass_buf`),
  `:7990-7997` (`glassPixels`: grows to `n + n / 4`, never shrinks),
  `:7999-8002` (`releaseGlassBuf`), whose only callers are `deinit` (`:1031`),
  leaving glass (`:5899`) and `releaseSnapshot` (`:6194`);
  `:8021-8033` (`glassSheetRect`: the sheet is the whole dirty rect unless a
  ready, opaque page covers a full edge of it).
- **Mechanism:** T3041 replaced a whole-client DIB made and freed on every
  paint with one kept buffer. A whole-client paint (a new slice, a resize, a
  see-through page, a page not ready yet) sizes it to the client plus a
  quarter. After that it stays at its largest: restoring from maximized does
  not shrink it, and hiding the pane (background tab, parked workspace,
  minimized window) does not free it. `releaseSnapshot` frees it only as a
  side effect of a glide ending, hero mode ending or a drag ending on that
  tab (`Window.zig:13548`, `:8643`, `:9417`, `:6641`), and the next paint
  grows it back.
- **Cost (computed):** w x h x 4 x 1.25 per viewer pane on a glass window:
  ~6.3 MB at 1400x900, ~41 MB after one 4K maximize, held until the pane
  closes. Zero off glass. The same class as PA-M01 and PA-M02, which were
  fixed for terminals and the desk.
- **Fix in brief:** free it when the pane is hidden (where T3035 sheds the
  rest of a background viewer), and fit it when a whole-client paint needs
  less than half of it, outside a resize drag, as `PaneDesk.fitList` does.
- **Risk:** low: the next paint allocates again.
- **Regression of:** T3041 (663e4a850) traded a per-paint allocation for a
  kept one; the trade is right, the two releases are what is missing.

### PA-M21: the release agent's allocator keeps what it took (P2, already T3244)

- **Where (V):** `src/remote/agent/main.zig:170` (`use_debug_allocator`),
  `:179-183` (release builds take `std.heap.smp_allocator`); the holders use
  the same `main`.
- **Mechanism (V in the std source, zig 0.15.2
  `lib/std/heap/SmpAllocator.zig`):** one freelist set per CPU slot (`:41`,
  `:82-85`), 13 size classes, each fed from 64 KB slabs mapped from the OS
  (`:50`, `:154`). A freed small block goes back on its slot's list; the file
  has no path that unmaps a slab. So the process keeps one or more slabs per
  size class per slot it ever touched, and the agent's many short-lived
  threads walk across the slots.
- **Cost (quoted, baseline-4 and T3235's re-run):** release agent base
  private 9.3 -> 17.7 MB; each session holder 12.5 -> 17.8 MB (18.1 on the
  re-run). Debug, which kept `DebugAllocator`, is unchanged at 9.8 / 12.45.
  The ceiling is CPU count x 13 x 64 KB (computed: ~27 MB on 32 logical
  CPUs) per process. One holder runs per session, so ten sessions are about
  50 MB more than at audit-3.
- **Fix in brief:** T3244's plan: measure `smp_allocator` against the C heap
  for the agent and for a holder, with T3017's throughput number beside
  each. A holder serves one session on few threads and likely does not need
  per-CPU lists.
- **Risk:** low; keep T3017's ingest win.
- **Regression of:** T3017 (674561478). T3235 closed with the CPU half only;
  the memory half is T3244, `todo`, P2.

## Checked and found clean

- `PaneDesk.scratch_fade` (T3183): sized to the downscaled gradient, freed
  after the fade and in `deinit`.
- Parked workspaces (T3191): every window-bound buffer is freed at surrender
  and each `deinit` leaves a reusable value, so the adopt does not touch
  freed memory.
- ConPTY read coalescing (T3060, `src/termio/Exec.zig`): one waitable timer
  per pane reader, closed by `defer` when the reader exits.
- Hero tile cards (T3279): the carousel band is a DIB section made and
  deleted per paint, as the compatible bitmap before it was.
- New viewer workers (`ViewerDocumentRead.zig:126`,
  `ViewerResourceServe.zig:297`, `ViewerImageDecode.zig:334`) use the worker
  pool, not a default-stack `std.Thread.spawn(.{})`.

**Not covered:** anything that needs a run; viewer internals beyond the
snapshot and glass buffers (T3035, T3039, T3044, T3241, T3245 are area V's);
the agent beyond its allocator and process snapshot (area I); the Mac half
of the shared-core items.

## Summary

| Fixed (all rounds) | Incomplete | Still open | Changed | Wrong | New |
|---|---|---|---|---|---|
| 7 (M01, M02, M03, M04, M05, M07, M11) | 0 | 8 (M06, M08, M09, M10, M14, M15, M16, M17) | 2 (M12, M13) | 0 | 4 (M18, M19, M20, M21) |

- **Open P0 in area M:** none.
- **Open P1 in area M:** none. T3130 (the unattributed `private_rw`) closed
  with 2dbfbf887: it is the NVIDIA GL driver's own arena.
- **Open P2:** M06 (T3006), M08 (T3008), M09 (T3009), M10 (T3010),
  M12 (T3012), M13 (T3096), M14 (T3097), M15 (T3098), M16 (T3145),
  M17 (T3150), and the new M18, M20, M21 (T3244).
- **Open P3:** the new M19.
- **Fix commits that brought a regression:** e15858510 (T3040) -> PA-M18;
  663e4a850 (T3041) -> PA-M20; 674561478 (T3017) -> PA-M21; 64e0ae1a6
  (T3191) widened PA-M12, PA-M13 and PA-M19.

Suggested filing:

- **T3007** -> close as fixed by T1590 (073c924a7)
- **PA-M18** -> new task, P2, seat win, follow-up of T3040; T3219 is its
  measurement
- **PA-M19** -> new task, P3, seat win, blocks making `GHOZTTY_COMP_CHROME`
  the default
- **PA-M20** -> new task, P2, seat win, follow-up of T3041
- **PA-M21** -> T3244 (exists); add the slab mechanism and the per-CPU
  ceiling
- **T3012** -> add `surrenderWindow` (`Window.zig:7675`)
- **T3096** -> add parked workspaces
- **T3006**, **T3008** -> new line numbers
