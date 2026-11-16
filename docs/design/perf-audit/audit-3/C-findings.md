# Audit-3, area C: shared Zig core hot paths (T3101)

- **Area:** C, shared Zig core (`src/Surface.zig`, `src/termio/`,
  `src/terminal/`, `src/font/`, `src/input/`, plus the shared parts of
  `src/renderer/` that the fix commits touched)
- **Audit:** audit-3, a re-audit of `../audit-2/C-findings.md`
- **Commit audited:** d0d874326 (audit-2 was 879fba35a)
- **Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. No
  build, test or app run; every verdict below comes from reading the code at
  HEAD.

## What moved since audit-2

`git diff --stat 879fba35a HEAD` over the area (16 files, +1786 / -260):

- `src/font/WindowsFontIndex.zig` (new, 497 lines) and
  `src/font/discovery.zig` (-188 / +~40): T3011, fb7b961ec. The Windows
  discovery backend now answers from a process-wide index.
- `src/terminal/page_pool.zig` (new, 263 lines) and
  `src/terminal/PageList.zig` (+168): T3003 (0f71734a4) and T3004
  (ede873611). On Windows, standard pages are one allocation each and a
  destroyed page past a reserve of one goes back to the OS.
- `src/termio/mailbox.zig` (+175) and `src/termio/Thread.zig` (+13): Mac's
  65fce4b64, merged by T3102 (6dc6ecb90). The IO thread's sends to its own
  full mailbox go to an overflow list.
- `src/terminal/formatter.zig` (+173 / -~60): Mac's e4f27d125 via T3102. A
  restored screen puts the cursor back after the tabstop and region setup.
  Not a hot path.
- `src/renderer/generic.zig` (+287), `Thread.zig` (+81), `OpenGL.zig` (+64),
  `gl_comp_present.zig` (+10): the idle and hidden frame releases, Mac's
  8b0de569b and 6bd6fe7fb via T3102, then T3103 (ad014989d), T2975
  (19581323a), T3104 (ae9b1adb2).
- `src/Surface.zig` (+38): 8c6987575 / T3138 (09241982e), the "fresh default
  shell closes without asking" flags. Lines below 260 moved down by 14,
  below 970 by 28, below 1647 by 34, below 3952 by 35, and so on up to 38.
- **No change:** `src/termio/Exec.zig`, `Termio.zig`, `stream_handler.zig`,
  `Remote.zig`, `src/pty.zig`, `src/os/hostname.zig`, `src/font/shaper/`,
  `src/terminal/Screen.zig`, `terminal/render.zig`, `renderer/State.zig`,
  `renderer/link.zig`, `src/input/`. Audit-2's line numbers in those files
  are still exact.
- `scripts/perf-baseline.ps1` grew by about 600 lines (T2976, T2989, T3005,
  and others) and still has no `GHOZTTY_PERF` reference.

So two findings are fixed (C06, C07, one commit), none changed shape, and
fifteen stand. Two new findings come from the fix commits.

## Verdicts

Confidence is "high" where the cited lines were read at HEAD and the
mechanism traced end to end. Costs are audit-1's estimates unless a task
measured them; nothing was measured this turn.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| C01 | **fixed** (high) | `src/Surface.zig:2355`, `:3851`; `src/input/key_mods.zig:99-101` | dacab7bec, unchanged since audit-2. Both compares use `bindingEqual`. | T3058 stays closed. |
| C02 | **still open** (high) | `scripts/perf-baseline.ps1` (no `GHOZTTY_PERF` reference); counters at `termio/Exec.zig:1548-1633`, `stream_handler.zig:138-166` | The script was extended four times since audit-2 (idle wakers, cycle leftovers, driver fill) and still records none of the busy-phase counters. | T3059 as written, with T3080 folded in. |
| C03 | **still open** (high) | `termio/Exec.zig:1568-1611`, `:1639` | File unchanged. Quit-pipe peek, blocking read, top-up peek, lock, per batch. | T3060 as written. |
| C04 | **still open** (high) | `termio/Termio.zig:1190-1192`, `stream_handler.zig:171-174`, `Remote.zig:2180-2182` | Files unchanged. `queueRender` is still the first statement under the lock. | T3061 as written. |
| C05 | **still open** (high) | `src/pty.zig:417` | `CreatePipe(..., null, 0)` unchanged. | T3062 as written. |
| C06 | **fixed** (high) | `font/discovery.zig:917-945`, `:962-980`; `font/WindowsFontIndex.zig:118-141`, `:152-166`; caller `CodepointResolver.zig:170-181` under `SharedGrid.zig:172-181` | fb7b961ec. `discoverFallback` now asks the index for the faces whose cmap maps the codepoint and opens only those, lazily. A codepoint no font covers opens nothing. T3011 measured 200 distinct uncovered codepoints 15,671 ms -> 12.9 ms at `getIndex`. Residual costs are PA-C19. | T3011 stays closed. |
| C07 | **fixed** (high) | `src/Surface.zig:3488-3499` (`setFontSize`); `SharedGridSet.zig:180`, `:195`; `WindowsFontIndex.zig:133-139` | fb7b961ec. Each per-style family query is a name filter over the index, then one `Face.initFile` of the first candidate. T3011 measured 8.4 ms -> 0.2 ms per family query. Still on the GUI thread, now about 1 ms per zoom step. | T3011 stays closed. |
| C08 | **still open** (high) | `src/Surface.zig:5663-5720` (`linkAtPin`; `selectLine` at `:5671-5679`, `selectionString` at `:5683-5689`); `terminal/Screen.zig:2541` | Unchanged apart from the line shift. Soft-wrap walk uncapped; stringify with a map under the renderer mutex on the GUI thread. | T3064 as written; update lines. |
| C09 | **still open** (high) | `src/Surface.zig:5683-5689` (alloc) before `:5693-5696` (mods check) | Unchanged. | T3064. `renderer/link.zig:63` `canHighlight` is still the ready-made early-out. |
| C10 | **still open** (high) | `src/Surface.zig:5958-5967`; `:2466`; `terminal/render.zig:276-290` | `over_link or ...` still bypasses the same-cell check; each event sets `dirty.hyperlink_hover` (a full redraw) and posts apprt actions. | T3064 as written; update lines. |
| C11 | **still open** (high) | `src/Surface.zig:6009`, `:6042-6048`, `:6155-6168`; `terminal/Screen.zig:2414-2428` | Unchanged. `select` tracks, untracks and sets `dirty.selection` with no equality check. | T3065 as written; update lines. |
| C12 | **still open** (high), as audit-2 restated it | `src/Surface.zig:4343-4346`; also `:3832-3836`, `:4419-4421`, `:3970-3971` | Up to four renderer-mutex cycles per key event on the GUI thread, plus the apprt's read at `apprt/win32/Surface.zig:6763`. | T3066's title still says "giving up the T114 priority handoff". Rewrite it as audit-2 asked: collapse the lock cycles; `lockPriority` buys nothing until T3068. |
| C13 | **still open** (high) | `font/shaper/harfbuzz.zig:134-148`; `renderer/generic.zig:3548-3556`, `:3817-3825` | Unchanged. Exclusive grid lock across `hb_shape` on a cache miss. | T3067 as written; update the generic.zig lines. |
| C14 | **still open** (high) | `font/shaper/run.zig:75`, `:306-310`; `harfbuzz.zig:265-298`; cache check at `generic.zig:3548` after `runIterator` at `:3509` | Unchanged. | T3067 as written. |
| C15 | **still open** (high), P1 as audit-2 restated it | `termio/Remote.zig:2590`, `:2620-2622`, `:2236`, `:2276-2280`, `:2413-2418`; `renderer/State.zig:70-77` | `Remote.zig` and `State.zig` unchanged. `Remote.zig:2278` is still the only call of `yieldToPriorityWaiters` in `src/`, and still unreachable. The five `lockPriority` sites are now `apprt/win32/Surface.zig:6089`, `:6763`, `:6845`, `IpcHandlers.zig:1373`, `renderer/generic.zig:1681`. The Mac mailbox fix (65fce4b64) did not touch the handoff. | T3068 as restated; update the caller lines. |
| C16 | **still open** (high) | `termio/stream_handler.zig:1285-1420`; `os/hostname.zig:104-110` | Files unchanged. | T3069 as written. |
| C17 | **still open** (high) | `src/Surface.zig:2350-2380` (`dirty.clear` at `:2372`); key path `:3851-3873`; `terminal/render.zig:276-282` | Unchanged apart from the line shift. A real modifier change still forces a full rebuild and, on the key path, a link match. | T3099 as written; update lines. |
| C18 | **still open** (high) | `renderer/link.zig:63`, `:83`; `renderer/generic.zig:1823`, `:1854` | `link.zig` unchanged; the generic.zig call sites only moved. No cache of the match set. | T3100 as written; update lines. |

## Changed items

None this round. C12 and C15 keep the shape audit-2 gave them; T3068 was
raised to P1 as asked, T3066's text was not rewritten.

## Fix-commit review

### T3011, fb7b961ec (font index): fixes C06/C07, three residual costs

Read in full: `WindowsFontIndex.zig`, the `Windows` backend in
`discovery.zig:903-1030`, and both callers.

- **Correct and complete for the finding.** The index is consulted under
  its own mutex; `candidates` copies paths out, so no snapshot pointer
  escapes the lock. Discovery re-opens each candidate and re-checks family
  and `glyphIndex` (`discovery.zig:983-991`), so a stale index can only
  cost time, not change an answer. Candidates are opened lazily, one per
  `next()`.
- **Residual 1: the prewarm does not help the first query.** See PA-C19.
- **Residual 2: a stale stamp rebuilds on the querying thread.** See PA-C19.
- **Residual 3: two directory opens per query.** `readStamp`
  (`WindowsFontIndex.zig:168-177`) opens and stats each Fonts folder on
  every `candidates` call, inside the index mutex and, for a fallback
  lookup, inside the grid's exclusive lock. The task's 0.2-0.4 ms per query
  is mostly this. Bounded by the grid's cache (once per distinct codepoint,
  style and presentation), so it is a note, not a finding: 5,000 distinct
  uncovered codepoints of binary noise cost about 1-2 s of exclusive lock
  spread over the burst (computed from the task's per-query figure), where
  the old code cost minutes.
- **Memory:** the snapshot keeps every face's cmap ranges for the life of
  the process. Size was not measured; it belongs to area M.
- **Error path:** if `Library.init` fails for a reason other than OOM
  (`:194-200`) the empty snapshot is cached with the current stamp, so
  fallback finds nothing until a font is installed. Correctness, not
  performance; unlikely.

### T3003 / T3004, 0f71734a4 / ede873611 (exact page pool): clean

Read `page_pool.zig` in full and every `PageList.zig` hunk.

- `create` and `destroy` are a pop and a push on a side array; no syscall
  while the free list has an item.
- `release` (`page_pool.zig:99-107`) is a linear scan of every page the
  pool owns. With the default scrollback that is tens of entries. A pane
  with a 1 GB limit erasing its history does about 3 million pointer
  compares once (computed). Not a finding.
- A destroyed page past the reserve of one (`PageList.zig:53`,
  `:3509-3521`) is now a `VirtualFree`, and the page that later replaces it
  a `VirtualAlloc` plus about 100 demand-zero faults, where the old pool
  did one 0.4 MB `memset`. That is the trade T3004 chose. The steady paths
  do not hit it: scroll at the limit reuses the oldest page in place
  (unchanged), and a destroy-then-create pair is served by the reserve.
  A program that clears scrollback on every repaint would pay it per clear;
  not traced to any real program, so not filed.
- `reset` skips the old arena-zeroing block at comptime and the pool zeroes
  what it keeps (`page_pool.zig:117-137`). No double work.

### 65fce4b64 via T3102 (mailbox overflow): clean, one note

Read `mailbox.zig` in full and the `Thread.zig` hunks.

- Fixes a real stall: the IO thread sending to its own full queue used to
  wait 50 ms per message and then drop it.
- Cost on `send`: one atomic load and one `GetCurrentThreadId`. `next` is a
  queue pop, then an index compare.
- The overflow list keeps its peak capacity (`clearRetainingCapacity`,
  `:66`). The peak is what one 1 KiB drain slice can produce, a few hundred
  messages, because `drainRing` stops when `underPressure` is true
  (`mailbox.zig:263-268`, `Remote.zig:2615-2624`). Kilobytes.
- **Note:** `sendOverflow` (`:241-252`) calls `wakeup.notify()` once per
  overflowed message. On IOCP each notify is an unconditional post
  (PA-C04's mechanism), so a slice full of queries posts a few hundred
  stale packets to the thread's own loop. Bounded per slice; fold into
  T3061 if that task adds a pending flag.

### e4f27d125 via T3102 (formatter): clean

`formatTrailingExtras` adds one `CSI H` to a session restore. Runs once per
restore or snapshot, not per frame.

### 8b0de569b, 6bd6fe7fb, T3103, T2975, T3104 (idle and hidden frame release)

Read the `generic.zig` and `Thread.zig` hunks in full and the `OpenGL.zig`
hunks. Area R owns the OpenGL side; this is the shared half.

- **Steady cost while drawing:** one `Instant.now()` per rendered frame
  (`generic.zig:2196`), and the idle timer fires once per 3 s to find the
  pane still drawing and re-arm (`Thread.zig:1015-1039`). No per-frame
  allocation, no new lock (the frame already holds `draw_mutex`).
- **Idle cost:** none. After a release `releaseIdleFrames` returns null and
  the timer stays disarmed until the next rendered frame.
- **New cost on the first frame back:** PA-C20.
- `frameMemory` (`generic.zig:1387-1399`) takes `draw_mutex`, so a readout
  can wait behind a frame. It is a diagnostic call, not a hot path.

### 8c6987575 / T3138 (`Surface.zig`): clean

Two bools, written on input paths (`:3955`, `:4445`, `:4491`, `:7520`) and
read once in `needsConfirmQuit` (`:1653-1654`).

## New findings

### PA-C19: the font index is built or rebuilt on whichever thread asks first (P2, Windows)

- **Where:** `src/font/WindowsFontIndex.zig:118-126` (`candidates` takes the
  mutex, then `currentLocked`), `:152-166` (build when missing or the stamp
  moved), `:351-363` (`prewarm`); `src/font/SharedGridSet.zig:180` then
  `:195`; `src/font/discovery.zig:906-911`.
- **Mechanism, startup:** the prewarm thread is started by `Windows.init`,
  which `SharedGridSet.collection` triggers at `:180`. With `font-family`
  set, the very next statement that matters (`:195`) is the first family
  query, on the GUI thread inside `Surface.init`
  (`src/Surface.zig:852`). It takes the index mutex and either builds the
  whole index itself or waits for the prewarm thread to. Either way the GUI
  thread waits for a full build before the first window can finish
  creating. The old code stopped at the first matching file. With the
  default config (no `font-family`) there is no startup query, but the first
  frame's first uncovered codepoint does the same wait on the renderer
  thread while holding the grid's exclusive lock.
- **Mechanism, font install:** when either Fonts folder's last-write time
  moves, the next query rebuilds the index synchronously under the mutex.
  For a fallback lookup that is the renderer thread inside the grid's
  exclusive lock, so every pane on that grid stalls for one build.
- **Cost:** one build is 60-75 ms with a warm file cache (measured by
  T3011). Against the old first family query of 8.4 ms (T3011, `Consolas`),
  a first window with `font-family` set starts about 50-65 ms later
  (computed from those two figures). With a cold file cache (first launch
  after boot) the build reads the cmap of every installed font; that was
  not measured and is likely several times larger (inferred).
- **Fix:** start the prewarm earlier than the first query (at app init,
  before the first surface), and for a family query made while no snapshot
  exists fall back to the old short walk rather than waiting. On a stamp
  change keep answering from the old snapshot and rebuild on the
  `font-index` thread, swapping the pointer under the mutex. Discovery
  already re-checks every candidate, so a briefly stale snapshot is safe.
- **Shared with Mac:** no (Windows discovery backend).
- **Confidence:** high on the mechanism; cost computed from T3011's
  measurements, cold-cache cost inferred.

### PA-C20: the first frame after 3 s of stillness re-creates the target and re-uploads the atlases, and its cost on Windows was never measured (P2)

- **Where:** `src/renderer/generic.zig:1406` (`idle_release_ns` = 3 s),
  `:1419-1437` (`releaseIdleFrames`), `:1478-1546`
  (`releaseFrameResources`), `:2170-2183` (`redraw_after_release` forces a
  draw), `:2256-2278` (target re-created), `:580-601` (`releaseAtlases`
  zeroes the modified counters so the next sync is a full upload);
  `src/renderer/OpenGL.zig:1602-1606` (`releaseIdleTargetsNow`),
  `:1646-1653` (`hiddenTargetsReleased` also frees the composition staging
  texture, for the idle reason too).
- **Mechanism:** a pane that renders nothing for 3 s gives back its render
  target, both font-atlas textures and, on the composition path, the
  GL-to-D3D staging texture. The next rendered frame must allocate a
  window-sized target, upload both atlases in full (T3103's readout:
  1,280 KB of atlas for one pane), re-create and re-register the staging
  texture, and draw in full. That frame is whatever ends the stillness: the
  first keystroke's echo after a pause, the first line of output from a
  long-running command, a focus switch into a still pane. Cells are not
  rebuilt; the cost is GPU allocation and upload.
- **Cost:** not measured on Windows. T3103's summary carries Mac's "~1 ms"
  figure; its Windows validation checks that the frame redraws in full
  (I2), not how long it takes. The OpenGL path adds the staging-texture
  re-registration, which Mac does not have. Inferred: a few ms on the first
  frame, once per stillness, per pane. A pane whose cursor blinks draws on
  each blink and so should never go idle while focused; that was not
  re-traced this turn. T3103 already records one bounded side effect (a
  pane with title-only output cycles release and full redraw every ~3.5 s).
- **Fix:** measure it first: time from wakeup to present for the first
  frame after an idle release against a normal frame (the `traceStage`
  hooks at `generic.zig:2280` are already there), in a small and a
  maximized pane. If it exceeds one frame, keep the atlas textures and the
  staging texture across an idle release (they are shared-size, not
  window-size, and are the upload cost) and release only the target; or
  release only panes that are not focused.
- **Shared with Mac:** the mechanism is Mac's; the unmeasured part is the
  Win32 OpenGL path. Area R owns `OpenGL.zig`; de-duplicate at roll-up if
  R reports the same thing.
- **Confidence:** high on the mechanism; cost inferred, unmeasured.

## Checked and found clean

- **`ExactPool`** on the scroll path: no syscall and no write into a free
  page; growth before the limit is one `VirtualAlloc` per page of rows.
- **`Mailbox.send`** for a non-consumer thread (the Exec reader, the GUI
  thread): the fast path is unchanged apart from one atomic load.
- **`Thread.drainMailbox`** (`termio/Thread.zig:350-390`): same loop, now
  through `next()`.
- **`needsConfirmQuit`** (`Surface.zig:1647-1654`): the new check returns
  before the lock it used to take.
- **Renderer idle timer:** disarmed while a pane is still; one wakeup per
  3 s while it draws.
- **Files unchanged since audit-2** (`Exec.zig`, `Termio.zig`,
  `stream_handler.zig`, `Remote.zig`, `Screen.zig`, `render.zig`,
  `src/input/`, `font/shaper/`): audit-1's and audit-2's "clean" list
  stands.

## Not re-done

- No measurement. PA-C02 (T3059) is still what would turn the output-path
  estimates into numbers, and PA-C20 asks for one more.
- `src/terminal/` outside `PageList.zig`, `page_pool.zig` and
  `formatter.zig` was not re-swept line by line; it did not change.
- The OpenGL-only files were read only where the shared renderer calls into
  them.

## Summary

- **Fixed:** 3 (C01 from audit-2; C06 and C07 this round, fb7b961ec).
- **Still open:** 15 (C02-C05, C08-C18).
- **Changed:** 0. **Wrong:** 0. **Fixed (incomplete):** 0; C06/C07's
  residual costs are filed as PA-C19.
- **New:** 2 (PA-C19 P2, PA-C20 P2).
- **Open P0:** none.
- **Open P1:** C02 (T3059), C03 (T3060), C04 (T3061), C08 (T3064, with
  C09/C10), C15 (T3068).
- **Task hygiene:** T3066's title and summary still describe C12 as a lost
  priority handoff; audit-2's restatement was not applied.
