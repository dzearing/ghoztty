# Audit-2, area C: shared Zig core hot paths (T3072)

- **Area:** C, shared Zig core (`src/Surface.zig`, `src/termio/`,
  `src/terminal/`, `src/font/`, `src/input/`, plus the shared parts of
  `src/renderer/` that the fix commits touched)
- **Audit:** audit-2, a re-audit of `../audit-1/C-findings.md`
- **Commit audited:** 879fba35a (audit-1 was e9b6d84ea)
- **Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. No
  build, test or app run; every verdict below comes from reading the code at
  HEAD.

## What moved since audit-1

`git diff --stat e9b6d84ea HEAD` over the area:

- `src/termio/`, `src/terminal/`, `src/pty.zig`, `src/os/hostname.zig`,
  `src/apprt/win32/Surface.zig`: **no change**. Every audit-1 line number in
  those files is still exact.
- `src/Surface.zig`: 7 lines (T3058). Everything below line 2318 moved down
  by 3.
- `src/input/key_mods.zig`: `bindingEqual` added (T3058).
- `src/font/Atlas.zig`: a dirty-row log (T2973). No other font file changed.
- `src/renderer/`: T2967, T2970, T2971, T2973, T2974 (`generic.zig`,
  `Thread.zig`, `cursor.zig`, `link.zig`, plus OpenGL-only files).

So one finding is fixed, two change shape, and thirteen stand as written.

## Verdicts

Confidence is "high" where the cited lines were read at HEAD and the
mechanism traced end to end. Costs are still audit-1's estimates; nothing was
measured this turn.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| C01 | **fixed** (high) | `src/Surface.zig:2321`, `:3817`; `src/input/key_mods.zig:99-101` | dacab7bec. Both raw compares now use `bindingEqual`. All three `modsChanged` callers (`:3819` key, `:5048` button, `:5869` move) go through `:2321`. The link-hover compares (`Surface.zig:5608`, `:5659`, `renderer/link.zig:70-72`, `:117-123`, `generic.zig:1587`) read the stored `binding()` mods against config mods, never raw event mods. | T3058 stays closed. The live NumLock-on fps run is still owed (T3076, parked). Residual cost on a real mod change is PA-C17. |
| C02 | **still open** (high) | `scripts/perf-baseline.ps1` (no `GHOZTTY_PERF` reference); counters at `termio/Exec.zig:1548-1633`, `stream_handler.zig:138-166` | The script was last touched by T2973 and still records none of the counters. | T3059 as written. Fold in T3080 (same binary read 27.9 s then 13.7 s app CPU): the busy figure audit-1 costed C03/C04 from is good to about 2x only. |
| C03 | **still open** (high) | `termio/Exec.zig:1568-1611`, `:1639` | File unchanged. Quit-pipe peek, blocking read, top-up peek, lock, per batch. | T3060 as written. |
| C04 | **still open** (high) | `termio/Termio.zig:1190-1192`, `stream_handler.zig:171-174`, `Remote.zig:2180-2182` | File unchanged. `queueRender` is still the first statement under the lock, before the parse. | T3061 as written. |
| C05 | **still open** (high) | `src/pty.zig:417` | `CreatePipe(..., null, 0)` unchanged. | T3062 as written. |
| C06 | **still open** (high) | `font/discovery.zig:929-937`; `CodepointResolver.zig:170-213`; `SharedGrid.zig:172-181` | Unchanged. `discoverFallback` drops the collection and rescans, inside the grid's exclusive lock. | T3011 as written. |
| C07 | **still open** (high) | `src/Surface.zig:3454-3465` (`setFontSize`); `SharedGridSet.zig:122-134`, `:191-197` | Unchanged apart from the 3-line shift. | T3011 as written; update the Surface line. |
| C08 | **still open** (high) | `src/Surface.zig:5626-5683` (`linkAtPin`); `terminal/Screen.zig:2541-2650` | Soft-wrap walk still uncapped; `selectionString` with a map still runs under the renderer mutex on the GUI thread. T2971 fixed the renderer's copy of this work, not this one. | T3064 as written; update lines. Also now reached from the key path on every modifier press (PA-C17). |
| C09 | **still open** (high) | `src/Surface.zig:5646-5652` (alloc) before `:5656-5660` (mods check) | Unchanged. | T3064. The fix can reuse `renderer/link.zig:61-73` `Set.canHighlight` (T2971) as its early-out predicate. |
| C10 | **still open** (high) | `src/Surface.zig:5921-5930`; `:2430`; `terminal/render.zig:284-290` | `over_link or ...` still bypasses the same-cell check; each event sets `dirty.hyperlink_hover`, which `render.zig` turns into a full redraw, and posts two apprt actions. | T3064 as written; update lines. |
| C11 | **still open** (high) | `src/Surface.zig:5972`, `:6005-6011`, `:6118-6131`; `terminal/Screen.zig:2414-2428` | Unchanged. `select` tracks, untracks and sets `dirty.selection` with no equality check. | T3065 as written; update lines. |
| C12 | **changed** (high) | `src/Surface.zig:4307-4310`; also `:3798-3802`, `:4385-4386`, `:3937-3938` | The plain lock is still there, but "gives up the T114 priority" overstates it: nothing honors a priority waiter at HEAD (see below). The real cost is the count of lock cycles per key event. | Rewrite T3066: remove the extra lock cycles (pass the mode in, read once). Do not "use lockPriority" as the fix; it buys nothing until T3068. |
| C13 | **still open** (high) | `font/shaper/harfbuzz.zig:134-148`; `renderer/generic.zig:3311-3319` | Unchanged. Exclusive grid lock across `hb_shape` on a cache miss. | T3067 as written. |
| C14 | **still open** (high) | `font/shaper/run.zig:75`, `:306-310`; `harfbuzz.zig:265-298`; cache check at `generic.zig:3311` | Unchanged. The HarfBuzz buffer is filled per codepoint by the run iterator; the cache is consulted only after `next()` returns. | T3067 as written. |
| C15 | **changed** (high) | `termio/Remote.zig:2590`, `:2620-2622`, `:2236`, `:2276-2280` | Still true, and larger than filed: the unreachable yield is the ONLY consumer of `priority_waiters` in the tree, so all 5 live `lockPriority` sites are plain locks today. | Raise T3068 to P1 and restate it (below). |
| C16 | **still open** (high) | `termio/stream_handler.zig:1285-1420`; `os/hostname.zig:104-110` | File unchanged. No repeat check; `GetComputerNameA` and a GUI post per OSC 7. | T3069 as written. |

## Changed items

### PA-C12: the key path's plain locks (changed)

- **Still true:** `encodeKey` (`src/Surface.zig:4307-4310`) takes the
  renderer mutex with a plain `lock()` to read `win32_input`, after
  `apprt/win32/Surface.zig:6719` read the same bit under `lockPriority`.
- **What audit-1 got wrong:** the cost is not "priority given up".
  `lockPriority` (`renderer/State.zig:70-77`) only bumps a counter. The one
  place that reads the counter to hand the mutex over is
  `Remote.zig:2278`, which PA-C15 shows is unreachable. The Exec reader
  never calls `yieldToPriorityWaiters` at all (grep over `src/` finds the one
  call site). So a priority lock and a plain lock behave identically at HEAD,
  on both backends.
- **What the cost is:** one key event takes the mutex up to four separate
  times on the GUI thread, each a chance to queue behind the IO thread in a
  flood:
  - `:3798-3802` KAM check (when `vt_kam_allowed`)
  - `:4307-4310` `win32_input` (Windows)
  - `:4385-4386` `encodeKeyOpts` (when 9001 is off, e.g. a non-ConPTY stream)
  - `:3937-3938` selection clear and scroll-to-bottom after an encode
  - plus the apprt's own read at `apprt/win32/Surface.zig:6719`
- **Task should now say:** collapse these into one lock cycle per key event
  (read `disable_keyboard`, `win32_input` and the encode options together,
  or pass the apprt's already-read mode in). Priority stays P2. Windows-only
  for the `win32_input` read; the KAM, options and post-encode locks are
  shared with Mac.

### PA-C15: the priority handoff is dead code (changed, suggest P1)

- **Still true:** `drainRing` pops at most `slice_bytes = 1024`
  (`Remote.zig:2590`, `:2620`) and hands that to `feedSliced`
  (`:2687`, `:2692`). `SliceIter.next` (`:2413-2418`) cuts at
  `max_parse_slice = 4096` (`:2236`), so after the first slice
  `it.rest.len` is always 0 and `:2276-2280` never runs.
- **What is bigger than filed:** that call is the only reader of
  `State.priority_waiters` outside `State.zig`. The five live `lockPriority`
  sites therefore get no handoff:
  - `apprt/win32/Surface.zig:6045`, `:6719`, `:6801` (typing, input mode)
  - `apprt/win32/IpcHandlers.zig:1373` (`+read`/`+list`)
  - `renderer/generic.zig:1464` (every frame)
- Between two `drainRing` iterations there is no syscall (`closing.load`,
  `underPressure`, `streamPos`, a ring `pop`), so the T111b/T114 failure the
  mechanism was built for (a GUI or renderer waiter losing race after race
  against the drain) is back in principle on agent-backed panes, which are
  the shipped default. Not measured this turn.
- **Task should now say:** make the handoff reachable. Either call
  `yieldToPriorityWaiters` once per `drainRing` iteration when
  `priority_waiters != 0` (one atomic load when idle; skip the unconditional
  `Thread.yield` at `State.zig:98-103` on that path), or pop 4 KiB and let
  `feedSliced` slice. Add a unit test that fails when the yield is
  unreachable. Re-run the T114/T115 storm harness. Shared with Mac (the
  agent drain is one codebase).

## New findings

### PA-C17: every real modifier press and release is a full rebuild plus a link match (P2, shared)

- **Where:** `src/Surface.zig:2321-2344` (`modsChanged`) and `:3817-3839`
  (key path); `terminal/render.zig:276-282` (any `t.flags.dirty` bit means a
  full redraw).
- **Mechanism:** T3058 stopped the false mod changes. A real one (Shift,
  Ctrl, Alt or Win going down or up) still:
  1. sets `terminal.flags.dirty.clear = true` unconditionally (`:2338`),
     which rebuilds and re-shapes every row, even when no configured link's
     highlight depends on the changed modifier (Shift never does by
     default);
  2. on the key path, takes the renderer mutex with a plain lock and runs
     `mouseRefreshLinks` -> `linkAtPos` -> `linkAtPin` (`:3829-3835`), which
     is PA-C08's uncapped `selectLine` + `selectionString`. On Windows the
     position comes from `apprt/win32/Surface.zig:1805-1818`, which reads
     the global pointer, so this runs whenever the pointer's client
     coordinates are non-negative, not only when it is over the pane
     (how an out-of-range point maps to a cell was not traced).
- **Cost (estimated):** two full-viewport rebuilds and two line
  stringifications per shifted character or Ctrl chord. At audit-1's 2-5 ms
  per rebuild that is 4-10 ms of renderer work per capital letter, plus
  PA-C08's exposure (megabytes per Shift tap with a 1 MB wrapped line under
  the pointer) on the GUI thread.
- **Fix:** in `modsChanged`, set the dirty flag and queue a render only when
  the link predicate flips: compare
  `links.canHighlight(point, old)` / the OSC 8 `ctrlOrSuper` equality for
  the old and new mods (T2971's `Set.canHighlight` is the predicate). Skip
  the key path's `mouseRefreshLinks` on the same condition.
- **Shared with Mac:** yes (upstream code path).
- **Confidence:** high on the mechanism, estimated on the cost.

### PA-C18: a held-Ctrl hover re-scans the whole viewport every frame (P2, shared)

- **Where:** `renderer/link.zig:61-73` (`canHighlight`), `:83-110`
  (`renderCellMap`); `renderer/generic.zig:1603-1614`, `:1637-1644`.
- **Mechanism:** T2971 skips the viewport string, the byte map, the seam
  pass and the regexes when no link can highlight. When one can (Ctrl held
  with the pointer over a link, or any `always` / `hover` link in the
  config), the work is unchanged from audit-1: every frame the renderer
  draws builds the full viewport string with a per-byte map and runs every
  link regex over it, with no cache keyed on "rows unchanged". Under output
  that is once per presented frame.
- **Cost (inferred):** cols x rows bytes of allocation plus N regex passes
  per frame, only while the condition holds. A config with one `always`
  link pays it on every frame forever; the default config pays it only
  during a Ctrl-hover.
- **Fix:** cache the match set and rebuild it only when the render state is
  dirty or the mouse cell or mods changed. P2 because the default config
  bounds it to a held gesture.
- **Shared with Mac:** yes.
- **Confidence:** high on the mechanism; cost inferred.

## Regressions from the fix commits

None found. Checked specifically:

- **T3058 (dacab7bec):** `bindingEqual` is two masks and a compare. No site
  still compares raw event mods against `mouse.mods`.
- **T2967 (8d2be0f7b):** `terminalStateRecycleDue`
  (`generic.zig:76-81`) resets the counter at the teardown; the teardown is
  once per 100,000 frames.
- **T2970 (2cdc77abe):** `renderCallback` calls `startCursorBlink` per frame
  only when blink is wanted, and it returns at once when the timer is active
  (`Thread.zig:948-950`). `reset_cursor_blink` (`:502-515`) does not restart
  a stopped timer, so a steady cursor under output costs no timer churn. A
  focus gain arms the timer once; it fires once and disarms without a
  wakeup.
- **T2971 (5672c7165):** one predicate, used by both the seam pass and
  `renderCellMap`. No new allocation.
- **T2973 (396aac1db, `font/Atlas.zig`):** `markModified` is one array
  write; `dirtyRowsSince` scans at most 32 entries per atlas sync. `modified`
  has no other writer (`Atlas.zig:349` is the only `fetchAdd`). A burst of
  more than 32 glyph writes between syncs (first paint, a new font size, a
  CJK page) falls back to the old full upload, which is the pre-fix cost and
  not a regression.
- **T2974 (6711c4e45):** the trim timer is bounded by
  `storage_trim.max_attempts = 3` per size change, so it cannot become a
  steady idle wakeup.

## Checked and found clean

- **`processOutputLocked`** (`Termio.zig:1189-1247`): per batch it is one
  notify (PA-C04), one or two `Instant.now()`, the parse, and three branches.
  No allocation.
- **`scrollCallback`** (`Surface.zig:4621-4797`): arithmetic, one lock cycle,
  one render. `clearSelection` (`Screen.zig:2431-2437`) only dirties when a
  selection existed.
- **Mouse move with no link and no button** (`Surface.zig:5823-5950`): one
  lock cycle; the link match is skipped while the cell is unchanged.
- **`Screen.Dirty` consumers** (`terminal/render.zig:276-290`, `:647-649`):
  flags are cleared each update, so a set flag costs one frame, not a
  latched state.
- **The key-binding path, key encoding, reader buffer, ASCII print path and
  scroll-at-limit** were found clean in audit-1 and their files are
  unchanged.

## Not re-done

- No measurement. Every cost above is audit-1's estimate or an inference.
  PA-C02 (T3059, with T3080) is still what would turn them into numbers.
- `src/terminal/` and `src/termio/` were not re-swept line by line for new
  findings, because neither directory changed since audit-1's sweep.
