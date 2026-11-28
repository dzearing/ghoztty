# Audit-5, area M: memory and leaks (T3316)

- **Area:** M, memory and leaks (whole app, Windows build)
- **Date:** 2026-11-28
- **This file:** audit-5, a re-audit of `../audit-4/M-findings.md`
- **Commit audited:** 5eaac0760a (audit-4 was c9af15802)
- **Input:** `../audit-4/M-findings.md` (PA-M01..PA-M21), `../audit-4.md`
  (the PA-id to task map), and `../audit-1/M-findings.md` ..
  `../audit-3/M-findings.md` for the original descriptions
- **Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. No
  build, no test run, no app launch: every cost below is computed or
  inferred from the code, or quoted from a fix commit, a task file or an
  earlier baseline. None was measured this turn.

**Method.** Every cited line was read at HEAD, not grepped. `git diff --stat
c9af15802 HEAD` was read over the files the twenty-one PA-M ids cite and
over the rest of `src/` outside `src/apprt/gtk`. The task file of every id
was checked for status and commits. For each commit since audit-4 that
changes what memory is held or how it is freed (T3746, T3739, T2622, T2626,
T1923, T2635, T3361/T3374, T2122, T3645, T3761, T2219/T2221, T2333) the
source hunks were read and the code at HEAD traced. No fix is claimed from a
commit message.

Confidence markers: **V** = read and traced at HEAD; **I** = inferred from
documented platform behavior, or from a mechanism this repo measured on a
sibling path, on top of code that was read.

## What moved since audit-4

1341 commits. Most are the Linux/GTK port (`src/apprt/gtk`, out of scope)
and file splits that move code without changing it. Over the files the PA-M
ids cite, plus the new files that hold memory:

| File | Change | Commits (task) |
|---|---|---|
| `src/apprt/win32/IpcHandlers.zig` | `+read` body moved out | decba35cdc (T3361), T3374: the body is now `src/apprt/ipc/verbs.zig` + `core_terminal.zig`, shared with Linux. PA-M06 moved with it |
| `src/apprt/win32/ViewerTOCPanel.zig` | split | `releaseComp` is now in `viewer_toc_place.zig` (PA-M18 callers moved) |
| `src/apprt/win32/ViewerPane.zig` | +/- 1106 | 02938fe529 (T1923, glass sheet read from the desk), b05ed1d58d (T2635, exact-size opening capture), 5bb0018512 (T3436, split) |
| `src/apprt/win32/Window.zig` | +967 | de91e717ed (T2122, UIA strips provider), T2626, T2618; lines moved for PA-M01, M12, M13 |
| `src/apprt/win32/chrome_comp.zig` | +102 | 3bc0718992 (T2626, busy-lights visual and surface) |
| `src/apprt/win32/PaneDesk.zig` | +410 | 3bc0718992 (T2626, `lights_px`) |
| `src/apprt/win32/PaneSidebar.zig`, `pane_sidebar_rim_cache.zig` | +408, new | T2333 (rim bitmap cache) |
| `src/apprt/win32/AgentIntegration.zig` | +/- 77 | lines moved by one (PA-M08) |
| `src/renderer/gl_comp_present.zig` | +194 | 459de62840 (T3746, the shared D3D11 device is a pool of up to 8), d6732bc4da (T3739) |
| `src/renderer/OpenGL.zig` | +110 | T3739 (stranded-pane retry), 79307bd67b (T2622, slot reclaim), T3645 (GTK frame release) |
| `src/renderer/Thread.zig` | +40 | 7ce6815435 (T3761, pace cap); lines moved for PA-M09, M13 |
| `src/renderer/generic.zig` | +60 | T3645 (GTK: `releaseQueuedFrames`); the win32 path is the same code under a new name (`releaseFramesNow`) |
| `src/termio/Thread.zig`, `Exec.zig` | +20, +74 | T3383, T3328 (exit gate); no memory change |
| `src/remote/agent/main.zig` | +59 | T3646 (Debug heap counter), T2051; the allocator choice is unchanged |
| `src/remote/agent/web_tunnel.zig`, `viewer_grants.zig` | new | T2221, T2219 |

Unchanged since audit-4: `src/terminal/PageList.zig`, `page_pool.zig`,
`src/font/*`, `src/renderer/cell.zig`, `opengl/buffer.zig`,
`upload_diff.zig`, `src/datastruct/blocking_queue.zig`,
`src/termio/mailbox.zig`, `src/apprt/win32/DirectoryProbe.zig`,
`viewer_toc_comp.zig`, `child_comp.zig`, `CompDragThread.zig`,
`src/os/thread_stack.zig`, `scripts/perf-baseline.ps1`.

**No PA-M task closed since audit-4.** T3006, T3008, T3009, T3010, T3012,
T3096, T3097, T3098, T3145 (PA-M16, filed as PA-V27), T3150, T3244, T3308,
T3309, T3310 are all `todo` with no commits. T3007 (PA-M07) was closed by
audit-4 against 073c924a7.

## Verdicts

Cost column: **q** quoted, **c** computed, **i** inferred.

| PA | Verdict | HEAD where | Evidence | Cost | Task action |
|---|---|---|---|---|---|
| PA-M01 | **fixed** (V, high), as audit-4 | `src/apprt/win32/Surface.zig:3180-3200` (`releaseSnapshot`); `src/apprt/win32/Window.zig:13868-13877` (`releaseIdleSnapshots`), called at `:13903` (glide end), `:8904` and `:9682` (hero exit); `:6881` (drag end) | snapshot code unchanged, lines moved | - | T3001 stays done |
| PA-M02 | **fixed** (V, high), as audit-4 | `src/apprt/win32/PaneDesk.zig:341-355` (`fitList`), `:2721` (`ensureDesk`), `:2770-2781` (`scratch_fade`), `:1264`; `src/apprt/win32/chrome_comp.zig:403` (`Overlay.fit`) | T2626 added `lights_px` (`PaneDesk.zig:384`), a window-sized layer used only on the opt-in chrome compositor; it is fitted to zero when no light is on (`:2614`, `:2632`) and freed in `deinit` (`:1268`). Clean | - | T3002 stays done |
| PA-M03 | **fixed** (V, high), as audit-4 | `src/terminal/PageList.zig:40`, `:84-87`; `src/terminal/page_pool.zig:140-154` | files unchanged | - | T3003 stays done |
| PA-M04 | **fixed** on Windows (V, high), as audit-4 | `src/terminal/PageList.zig:53`, `:3509-3520`; `src/terminal/page_pool.zig:99-107` | files unchanged | - | T3004 stays done. Mac half T3013 still `todo` |
| PA-M05 | **fixed** (V, high), as audit-4 | `scripts/perf-baseline.ps1` (unchanged since audit-4: `:101-104`, `:751-760`, `:769`) | file unchanged | - | T3005 stays done |
| PA-M06 | still open (V, high); **moved to shared code** | `src/apprt/ipc/core_terminal.zig:33-56` (`dumpScreen`: priority lock at `:39`, whole-screen selection at `:50-53`, dump at `:54`); `src/apprt/ipc/verbs.zig:180` (the call), `:188` (tail taken after the whole dump) | same mechanism: the whole scrollback is serialized under the renderer lock on the GUI thread to return the last N lines. `IpcHandlers.zig:1144-1146` is now a one-line forward. One fix now serves Windows and Linux | c: unchanged (whole scrollback as text, per `+read`) | T3006: new file and lines; note the Linux app shares the body |
| PA-M07 | **fixed** by 073c924a7, T1590 (V, high), as audit-4 | `src/apprt/win32/App.zig:10277-10299`, the gate at `:10295-10298` | unchanged | - | T3007 stays done |
| PA-M08 | still open (V, high) | `src/apprt/win32/DirectoryProbe.zig:155`; `src/apprt/win32/AgentIntegration.zig:156`, `:172` | still `std.Thread.spawn(.{}, ...)` | q: ~64 KB of driver memory per thread start, never returned (audit-1) | T3008: `AgentIntegration` lines moved by one |
| PA-M09 | still open (V, high) | `src/renderer/Thread.zig:281`; `src/termio/Thread.zig:357-361`; `src/termio/mailbox.zig:131-139` | three places a queued payload is dropped; nothing moved but lines. The new `.pace` message (T3761) owns no memory | i: one config or backdrop payload per occurrence, rare | T3009: new renderer line |
| PA-M10 | still open (V, high) | `src/renderer/cell.zig:118-122` | file unchanged | c: 3 x columns of `CellText` per row, per pane | T3010 unchanged |
| PA-M11 | **fixed** (V, high), as audit-4 | `src/font/WindowsFontIndex.zig:118-141`, `:179`; `src/font/discovery.zig:917-934` | files unchanged. `:353` is still a default-stack spawn (T3075) | - | T3011 stays done |
| PA-M12 | still open (V, high for the code; I for how often), in audit-4's shape | `src/apprt/win32/Window.zig:2719-2726` (`deinit`: stops the drag thread, cancels three dialogs); `:23731-23821` (`onDestroy`: neither); `:7916-7972` (`surrenderWindow`: cancels the dialogs at `:7920-7922`, does not stop the drag thread); `:2798-2843` (`releaseWindowBound`: neither) | `compDragThreadStop()` is still called only from `deinit` (`:2721`) and `endDividerDrag` (`:17945`). `surrenderWindow` now also calls `cancelPaneDrag` and `resetPointerTransients` (`:7924-7925`), but the latter (`:8651-8663`) ends only a hero divider drag, not a split divider drag | i: one thread and one DComp device reference per occurrence, rare | T3012: new lines |
| PA-M13 | still open (V, high), in audit-4's shape | `src/renderer/Thread.zig:624-626` (`drawFrame` returns while hidden, before `armStorageTrim` at `:641`), `:649-670`; `src/renderer/OpenGL.zig:1696-1707` (`hiddenTargetsReleased`: "The swap chain stays"); `src/renderer/gl_comp_present.zig:1015-1020` (`releaseShared`), `:757` (`buffer_count = 2`); `src/apprt/win32/Window.zig:7886-7894` (`parkPaneHidden`), `:7958` | nothing moved but lines | c: 2 x w x h x 4 per hidden pane: ~10 MB at 1400x900, ~66 MB full-window at 4K; every pane of every parked workspace | T3096 unchanged |
| PA-M14 | still open (V for the code, I for the mechanism) | `src/renderer/gl_comp_present.zig:1188-1213` (`releaseCom`), `:1015-1034`; `src/renderer/OpenGL.zig:1696-1707` | still no `Flush` or `ClearState` anywhere in the file. T3746 turned the one shared device into a pool (`:421`, `:440`), so deferred destruction can now pend on up to eight devices instead of one; the mechanism is the same | i: not measured | T3097 unchanged; measure first. See PA-M23 for the pool itself |
| PA-M15 | still open (V, high) | `src/renderer/opengl/buffer.zig:11`, `:41`, `:85-90`, `:116`, `:146`; `src/renderer/upload_diff.zig:46-55` | files unchanged | as audit-3 | T3098 unchanged |
| PA-M16 | still open (V, high); **one more asker** | `src/apprt/win32/ViewerPane.zig:5898-5912` (`releaseSnapshot`, the in-flight return at `:5906`); `:5813-5875` (`onCapturePreviewCompleted` commits the DIB at `:5861-5866`) | the release still does nothing while a capture is out. T2635 (b05ed1d58d) added a second full-size asker: a viewer opening out of its strip asks for an exact-size frame and retries it (`:5845-5858`). `releaseSnapshot` clears `exact_want` (`:5904`) before the in-flight return, so a late answer skips the fit check and commits a pane-sized DIB after the glide | c: w x h x 4 per viewer this happens to: ~5 MB at 1400x900, ~33 MB at 4K, until the next glide end, hero exit or drag end on that tab | T3145 (PA-V27), `todo`: add the opening path |
| PA-M17 | still open (V, high) | `src/apprt/win32/PaneDesk.zig:2403` (`fitList(&self.glow_px, 2 * n)`), `:341-355` | unchanged | i: one allocation and free per focus change between panes of unequal size | T3150, `todo` |
| PA-M18 | still open (V for the code, I for the mechanism) | `src/apprt/win32/viewer_toc_comp.zig:170-184` (`Host.deinit`: `SetRoot(null)` `:175`, `Commit` `:176`, releases `:177-183`, no commit after); `src/apprt/win32/viewer_toc_place.zig:566-569` (`releaseComp`), called at `:492`, `:544`, `:555`, `:559` | `viewer_toc_comp.zig` unchanged; the caller moved out of `ViewerTOCPanel.zig` in a file split | i: per slide, one DComp device, two visuals and a card-sized surface (under 1 MB) that may never be destroyed | T3308, `todo`; T3219 (its measurement) `todo` |
| PA-M19 | **changed**: one more window-sized surface (V for the code, I for the mechanism) | `src/apprt/win32/chrome_comp.zig:2461-2488` (`Host.deinit`: commits at `:2465`, `:2468`, then releases, none after), `:2428-2444` (`releaseDesk`, now also `releaseGlow(&self.lights_vis)` at `:2434`); `src/apprt/win32/Window.zig:2806` (in `releaseWindowBound`, run by `surrenderWindow` at `:7961`) | see below | c: up to three window-sized surfaces per teardown (was two): ~15 MB at 1400x900, ~100 MB at 4K. Still only with `GHOZTTY_COMP_CHROME=1` (`chrome_comp.zig:88-91`) | T3309, `todo`: add the lights surface |
| PA-M20 | still open (V, high) | `src/apprt/win32/ViewerPane.zig:773` (`glass_buf`), `:7709-7716` (`glassPixels`: grows to `n + n / 4`, never shrinks), `:7718-7721` (`releaseGlassBuf`), whose only callers are still `deinit` (`:1095`), leaving glass (`:5530`) and `releaseSnapshot` (`:5902`) | T1923 (02938fe529) changed where the pixels come from (`:7685-7693`: read out of the window's desk instead of evaluating the gradient), not the buffer: same size, same lifetime | c: w x h x 4 x 1.25 per glass viewer: ~6.3 MB at 1400x900, ~41 MB after one 4K maximize | T3310, `todo` |
| PA-M21 | still open (V, high) | `src/remote/agent/main.zig:172` (`use_debug_allocator = builtin.mode == .Debug`), `:189` (release takes `std.heap.smp_allocator`) | T2051 changed which endpoint family a ReleaseSafe agent uses, not its allocator (still by `builtin.mode`). T3646 added a live-bytes counter on the Debug allocator only (`:184-188`) | q: release agent 9.3 -> 17.7 MB, each holder 12.5 -> 17.8 MB (baseline-4) | T3244, `todo` |

Seven fixed (none new this round), thirteen still open, one changed, none
incomplete, none wrong.

## Changed items

### PA-M19: the busy-lights layer is a third surface the teardown leaves pending

- **Still true (V):** `Host.deinit` (`chrome_comp.zig:2461-2488`) commits
  before it releases and never after. `releaseDesk` (`:2428-2444`) releases
  the desk tree with no commit of its own.
- **What moved:** T2626 (3bc0718992) draws the busy lights' rings on the
  compositor as their own visual and surface (`lightsUpload`, sized `w` x
  `h` of the desk). `releaseDesk` releases it with the rest (`:2434`), so it
  is a third window-sized DComp surface released under the order T2772
  proved leaves objects alive. It exists only while a pane's busy light is
  on (`lightsHide` drops it otherwise, and that path does commit first).
- **Cost (computed, mechanism inferred):** up to 3 x w x h x 4 of GPU memory
  per teardown: ~15 MB at 1400x900, ~100 MB at 4K. Opt-in knob only. In
  single-window mode with the knob on, paid on every workspace switch.
- **What T3309 should now say:** as filed, with the lights surface added.
  It still blocks making `GHOZTTY_COMP_CHROME` the default.

## Fix-commit review

No PA-M task closed, so there is no fix commit of this area to review. The
commits below changed what memory is held and were read in full.

| Commit | Task | Verdict |
|---|---|---|
| 459de62840 | T3746 | Reference counting is clean: a refused pane releases the device and context it was handed before asking for the next (`gl_comp_present.zig:714-723`), the `errdefer`s are registered only after the loop (`:724-730`), and a pane that never gets an interop handle returns through them. The pool itself only grows: **PA-M23** |
| d6732bc4da | T3739 | Clean. The retry runs only when `self.comp == null` (`OpenGL.zig:1494-1501`), so no presenter is overwritten; five attempts, then it stops |
| 79307bd67b | T2622 | Clean. `SlotPair.reclaim` hands back the pending slot only; the overwritten frame's fence is still returned by the next `publish` for deleting (`gl_window_presenter.zig:119-138`) |
| 3bc0718992 | T2626 | `PaneDesk.lights_px` is fitted to zero when no light is on and freed in `deinit`. The compositor surface it feeds widens **PA-M19** |
| 02938fe529 | T1923 | No new buffer: the glass sheet is copied out of the desk the window already holds. PA-M20 is unchanged by it |
| b05ed1d58d | T2635 | A misfit capture's DIB is deleted (`ViewerPane.zig:5846`) and the retry is bounded. It adds a second way into **PA-M16** |
| decba35cdc | T3361 | `+read` is the same work in a new place; the arena is still freed per request (`verbs.zig:159-160`). PA-M06 moved |
| de91e717ed | T2122 | The UIA provider is detached only on `WM_DESTROY`. A workspace that gave the shared window away never gets one: **PA-M22** |
| 7ce6815435 | T3761 | No memory change. Fewer frames on unused windows; area R's |
| T3645 commits | T3645 | GTK only at run time. The shared `releaseFrameResources` was split into a decide half and `releaseFramesNow`; the win32 path takes the same lock and frees the same things |
| 2ea2f1e0f8, 42083e60bc | T2219, T2221 | Agent side, bounded by constants: 64 grants per connection, 6 requests in flight, 64 MB of held response bodies (`src/remote/protocol.zig:1819`, `:1922`, `:1928`). Request threads use `thread_stack.config` (`web_tunnel.zig:152`) |

## New findings

| Id | Pri | Finding |
|---|---|---|
| PA-M22 | P2 | A workspace that hands the shared window away and then closes leaves its UI Automation provider registered and pointing at the freed `Window` |
| PA-M23 | P3 | The pooled D3D11 devices made for the 16th, 31st, ... pane are kept for the life of the process |

### PA-M22: the strips' UIA provider outlives a workspace closed in place (P2)

- **Where (V):** `src/apprt/win32/Window.zig:24082-24084` (the provider is
  made on the first `WM_GETOBJECT(UiaRootObjectId)` and kept in
  `strip_uia_root`); `:24420-24423` (its only release: `detach` in the
  window procedure's `WM_DESTROY` arm). `strip_uia_root` appears nowhere
  else in `src/`. `:7916-7972` (`surrenderWindow`: clears `GWLP_USERDATA`
  at `:7964` and `hwnd` at `:7965`, leaves `strip_uia_root`); `:23660`,
  `:23678-23685` (`close`: a workspace closed `.in_place` has no HWND, so it
  calls `onDestroy` directly); `:23821` (`onDestroy` frees the `Window`).
  `src/apprt/win32/strip_uia_provider.zig:337-349` (`Root.create`: one
  reference, a raw `*Window`), `:359-364` (`detach`: the only place
  `window` is set to null and the reference dropped), `:393`, `:562`, `:622`
  (every provider call dereferences `window` when it is not null).
- **Mechanism:** in single-window mode, closing the workspace on show while
  another exists goes `closeWorkspace` -> `.hand_to` -> `surrenderWindow`
  (`App.zig:8532-8544`). The HWND lives on under the adopter, so
  `WM_DESTROY` never reaches the closing workspace, and `close` runs
  `onDestroy` by hand. If any UI Automation client had asked that window
  for its provider, the `Root` is never detached: its reference is never
  dropped (a leak of the `Root` and of every `Strip` holding it), UIA is
  never told to disconnect it, and its `window` field still points at the
  freed controller. A client that still holds it and calls in reads freed
  memory. The same holds for a workspace whose last pane exits while parked
  (`closeParkedWorkspaceLater`, `App.zig:8552-8555`) if it was on show, and
  asked, earlier.
- **Cost:** memory is small (one `Root`, a few dozen bytes, plus any live
  `Strip` objects per closed workspace). The reason for P2 is the dangling
  pointer: a use-after-free on the GUI thread, reachable only with a UI
  Automation client attached (a screen reader, or an automation tool that
  walks the window) and single-window mode. Inferred reachability, not
  reproduced.
- **Fix in brief:** move the detach out of the `WM_DESTROY` arm into the
  shared teardown: `surrenderWindow` (the HWND is still valid there, as
  `detach` needs) and `onDestroy`. This is one more item for T3012's
  "window is going" routine (PA-M12).
- **Risk:** low.
- **Regression of:** de91e717ed (T2122) meeting T3184/T3191's in-place
  close. Not a perf cost; listed here as a lifetime defect. Cross-area: the
  crash half belongs to whichever area owns window lifetime.

### PA-M23: the device pool only grows (P3)

- **Where (V):** `src/renderer/gl_comp_present.zig:398-407` (the comment:
  "Each pooled device ... lives for the process"), `:421` (`pool_max = 8`),
  `:440-469` (`acquireAt`: makes the device at `index` on first use and
  keeps the cache's own reference), `:479-483` (`dropEntry`, reached only
  from `deinit`, which only tests call, and when a device is found removed),
  `:495` (the process cache), `:714-723` (a pane refused by device N asks
  for N+1).
- **Mechanism:** a driver caps the GL contexts that may open one D3D11
  device (15 on the NVIDIA box, quoted from T3746). The 16th pane open at
  once makes a second device, the 31st a third. When panes close, the slot
  on device 0 is reused first, which is right, but device 1 and up keep the
  cache's reference after their last pane has gone. Nothing releases an
  empty pooled device.
- **Cost (quoted per device, from T2968's measurement of per-pane devices):**
  about 54 driver threads and tens of MB of private and GPU memory per
  D3D11 device (10 panes with a device each read 611 threads and 348.7 MB
  of dedicated GPU memory; on one shared device, 116 and 226.9 MB). One such device
  stays for the rest of the process after any moment with more than 15
  panes open, two after more than 30. Bounded at seven extra.
- **Fix in brief:** count holders per entry; when the last pane on an entry
  above 0 releases, drop the cache's reference too (a later 16th pane makes
  it again). Or leave it and record the bound: the trade is one device
  creation (tens of ms) on the next crossing against the retained threads.
- **Risk:** low; device 0 must never be dropped this way (the chrome and
  viewer hosts take it through `processDevice`, `:502-509`).
- **Regression of:** 459de62840 (T3746), by design; the fix it makes (the
  16th pane keeps the fast path) is worth far more than this costs.
  Cross-area: area R may list the same pool under its device findings.

## Checked and found clean

- Sidebar rim cache (T2333, `pane_sidebar_rim_cache.zig`): eight tile-sized
  DIBs at most, the evicted one destroyed by the caller
  (`PaneSidebar.zig:4698`), all drained on destroy (`:932`).
- `PaneDesk.lights_px` (T2626): see the PA-M02 row.
- Stranded-pane retry (T3739) and slot reclaim (T2622): see the review table.
- Dropped-file paste (`Surface.zig`, `path_paste`): the per-file UTF-16 and
  UTF-8 buffers are freed by `defer` inside the loop; the result buffer has
  an `errdefer`.
- Agent web tunnel and viewer grants (T2219, T2221): bounded by protocol
  constants.
- ConPTY exit gate (`conpty_exit_gate.zig`): two atomics, no allocation.

**Not covered:** anything that needs a run; `src/apprt/gtk` and the Linux
run-time paths of shared files; viewer internals beyond the snapshot and
glass buffers (area V); the agent beyond its allocator and the two new
bounded stores (area I); the many remaining default-stack
`std.Thread.spawn(.{}, ...)` sites under `src/apprt/win32` (T3075's class,
not re-counted here); the Mac half of the shared-core items.

## Summary

| Fixed (all rounds) | Incomplete | Still open | Changed | Wrong | New |
|---|---|---|---|---|---|
| 7 (M01, M02, M03, M04, M05, M07, M11) | 0 | 13 (M06, M08, M09, M10, M12, M13, M14, M15, M16, M17, M18, M20, M21) | 1 (M19) | 0 | 2 (M22, M23) |

- **Open P0 in area M:** none.
- **Open P1 in area M:** none.
- **Open P2:** M06 (T3006), M08 (T3008), M09 (T3009), M10 (T3010),
  M12 (T3012), M13 (T3096), M14 (T3097), M15 (T3098), M16 (T3145),
  M17 (T3150), M18 (T3308), M20 (T3310), M21 (T3244), and the new M22.
- **Open P3:** M19 (T3309), and the new M23.
- **Fixed since audit-4:** none. No task of this area was worked in the
  1341 commits between the two audits.
- **Fix commits that brought a regression:** none of this area's. From
  other work: de91e717ed (T2122) -> PA-M22; 459de62840 (T3746) -> PA-M23;
  3bc0718992 (T2626) widened PA-M19; b05ed1d58d (T2635) widened PA-M16.

Suggested filing:

- **PA-M22** -> new task, P2, seat win; or fold into T3012 (same shared
  teardown routine)
- **PA-M23** -> new task, P3, seat win, follow-up of T3746
- **T3006** -> new location: `src/apprt/ipc/core_terminal.zig:33-56`,
  `src/apprt/ipc/verbs.zig:180-188`
- **T3145** -> add the opening card's exact-size capture (T2635)
- **T3309** -> add the lights surface (T2626)
- **T3008**, **T3009**, **T3012**, **T3096**, **T3308**, **T3310** -> new
  line numbers only
