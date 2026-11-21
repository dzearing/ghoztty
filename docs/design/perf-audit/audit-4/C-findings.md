# Audit-4, area C: shared Zig core hot paths (T3151)

- **Date:** 2026-11-21
- **Area:** C, shared Zig core (`src/Surface.zig`, `src/termio/`,
  `src/terminal/`, `src/font/`, `src/input/`, `src/pty.zig`, plus the shared
  parts of `src/renderer/` that the fix commits touched)
- **Audit:** audit-4, a re-audit of `../audit-3/C-findings.md`
- **Commit audited:** c9af15802 (audit-3 was d0d874326)
- **Input:** `../audit-3/C-findings.md` (PA-C01..PA-C20), `../audit-4.md`
  (baseline-4), `../baseline-4.json`
- **Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. No
  build, test or app run; every verdict below comes from reading the code at
  HEAD and the source diff of each fix commit.

## Method

1. `git diff --stat d0d874326 HEAD` over the area to see which files moved.
2. For every task audit-3 named, the task file's status and commit, then the
   fix commit's source diff read in full (`09c94632b`, `5059acb10`,
   `2b92c79da`, `ccc103ce7`; `74539ebe0` for the script side).
3. The cited code re-read at HEAD for every PA id whose file changed. For a
   file with an empty diff since audit-3 the verdict is carried, and the
   cited lines were spot-read.
4. libxev's IOCP `Async` (`src/watcher/async.zig`, `src/backend/iocp.zig` in
   the pinned package) re-read to check the new wake coalescing cannot lose
   a wakeup.
5. Costs are the tasks' own measurements where quoted; nothing was measured
   this turn.

## What moved since audit-3

`git diff --stat d0d874326 HEAD` over the area (28 files, +2453 / -181,
1026 of them in `scripts/perf-baseline.ps1`):

| File | Change | Task / commit |
|---|---|---|
| `src/termio/Exec.zig` (+108), `src/termio/read_coalesce.zig` (new, 86) | The ConPTY reader checks an atomic quit flag instead of peeking the quit pipe, and holds a streaming batch back for up to 1 ms or 16 KiB on a high-resolution timer. | T3060, 09c94632b |
| `src/pty.zig` (+7) | ConPTY output pipe is 64 KiB instead of the ~4 KiB default. | T3062 folded into T3060, 09c94632b |
| `src/renderer/wake_coalesce.zig` (new, 142), `renderer/Thread.zig` (+11), `termio/Termio.zig` (+39), `termio/stream_handler.zig` (+24), `termio/Options.zig` (+6) | Output-driven render requests go through one atomic flag; the request is posted after the parse and after the unlock. | T3061, 5059acb10 |
| `src/termio/Remote.zig` (+218), `renderer/State.zig` (+19) | The agent drain's priority handoff runs after every slice when a waiter is announced. The rest of the Remote diff is not hot-path: T3252 bring-up notices, T1506 `taken` flag (one atomic load per drain wake). | T3068, 2b92c79da |
| `src/Surface.zig` (+297), `src/terminal/Screen.zig` (+106), `src/input/Link.zig` (+23) | Link hover: modifier early-out, 32-row cap on the line read, same-cell keep. The rest of the Surface diff is T3133/T3155 (`fresh_default_shell`, `user_input_sent`), which runs at init and on input writes. | T3064, ccc103ce7 |
| `scripts/perf-baseline.ps1` (+1026) | The busy phase runs under `GHOZTTY_PERF=1` and parses the app's counter lines into `busy.perf`; per-thread attribution. | T3059, 74539ebe0 |
| `src/terminal/Terminal.zig`, `terminal/search/Thread.zig`, `config/Config.zig`, `os/power.zig`, `os/thread_stack.zig`, `os/windows.zig` | Tests, keybind defaults, the T3239 per-process throttling opt-out, T3095 pool stack options, timer externs. None on a per-frame or per-byte path. | various |
| **No change** | `src/font/` (all of it), `renderer/generic.zig`, `renderer/link.zig`, `renderer/OpenGL.zig`, `terminal/render.zig`, `terminal/PageList.zig`, `terminal/page_pool.zig`, `termio/mailbox.zig`, `termio/Thread.zig`, `os/hostname.zig`, `input/key_mods.zig`. Audit-3's line numbers in those files are still exact. | |

`src/Surface.zig` line shift since audit-3: +7 below 386, +34 below 977,
about +114 from 2800 to 5650, about +205 past `linkAtPin`.

Baseline-4 (`../audit-4.md`): busy wakeups 34,427/s -> 4,280/s (release),
which is T3060 plus T3061 on the Exec path. The idle rise (0.90% of a core
against 0.47-0.59%) was T3234, closed by 6ab6112e7 with **no code fix**:
the untouched 11-15 binary read 0.686/0.736 on 11-18 against HEAD's
0.716-0.758, so the rise is box drift. That commit changed no source in
this area (evidence and tracker only); T3242 (open, P2) is the method fix.
Nothing in this area's diff adds an idle wakeup: the reader's timer exists
only inside a flood, and the coalescing flag adds no timer.

## Verdicts

Confidence is "high" where the cited lines were read at HEAD and the
mechanism traced end to end.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| C01 | **fixed** (high) | `src/Surface.zig:2388`, `:3962`, `:6125`; `src/input/key_mods.zig:99-101` | dacab7bec, unchanged. All three compares use `bindingEqual`. | T3058 stays closed. |
| C02 | **fixed** (high) | `scripts/perf-baseline.ps1:1115-1183` (parser), `:1397-1401` (the busy app alone runs under `GHOZTTY_PERF`), `:1478` (per-thread attribution) | 74539ebe0. `busy.perf` in `baseline-4.json` carries reads, batches, bytes per batch, queue_render, render notifies, renderer wakeups, fps for both builds. Gap: the baseline run is persistence-off, so `agent_feed` has 0 windows; see PA-C22. The new `coalesce_waits_per_s` field on the pty line is not parsed. | T3059 stays closed. |
| C03 | **fixed** (high) | `termio/Exec.zig:1597` (atomic quit flag), `:1606` (blocking read), `:1627` (top-up), `:1635-1650` (coalescing wait), `:1688-1702` (`topUp`); `termio/read_coalesce.zig:22-49` | 09c94632b. The per-read quit-pipe peek is gone; a read that blocked under 2 ms waits up to 1 ms in 500 us slices for 16 KiB. T3060 measured (release A/B): batches 29.2k -> 647/s, bytes per batch 94 -> 4.6k, app CPU 19.3/20.5 s -> 10.9/11.4 s, wall 28.5 -> 26.0 s. A read that waited 2 ms or more parses at once, so an idle echo is not delayed. Residuals: PA-C21, PA-C23. | T3060 stays closed. |
| C04 | **fixed** (high) | `termio/stream_handler.zig:187-190` (`queueRender` through `wake_coalesce.request`); `termio/Termio.zig:1106-1115`, `:1124-1126`, `:1145`, `:1188` (request after the unlock); `renderer/Thread.zig:744` (`consume` first in `wakeupCallback`); `renderer/wake_coalesce.zig:41-58`; wiring `src/Surface.zig:1366` | 5059acb10. T3061 measured queue_render 31.5k/s -> 119 notifies/s at unchanged fps. Lost-wakeup check: `consume` runs before the mailbox drain and the terminal read; a request that finds the flag set was made after an unlock the renderer has not yet locked past; a notify before the waiter registers is kept by libxev (`async.zig` `self.wakeup = true`) and the thread posts its own first wakeup at `Thread.zig:327`. The agent path gets the same saving through `processOutputTracked`. | T3061 stays closed. |
| C05 | **fixed** (high) | `src/pty.zig:422` | 09c94632b: `CreatePipe(..., null, 64 * 1024)`. T3062's own note: ^C during a flood was not exercised by a run; the bound (about 22 ms of output already in the pipe) is by construction. | T3062 stays closed. |
| C06 | **fixed** (high) | as audit-3 (`src/font/` unchanged) | fb7b961ec. | T3011 stays closed. |
| C07 | **fixed** (high) | `src/Surface.zig:3600` (`setFontSize`); font files as audit-3 | fb7b961ec. | T3011 stays closed. |
| C08 | **fixed** (high) | `src/Surface.zig:5860` (`link_match_max_rows` = 32), `:5886-5897`; `terminal/Screen.zig:2542`, `:2602-2610`, `:2678-2686`, `:2697-2698` | ccc103ce7. The soft-wrap walk stops 32 rows each side of the pointer and a capped edge does not follow hard wraps, so the string is at most 65 rows wide of the logical line plus up to 32 hard-wrap rows on an uncapped edge. Still under the renderer mutex on the GUI thread, now bounded. Unit test `Screen: selectLine max_rows bounds a 1 MB unbroken line`. | T3064 stays closed. |
| C09 | **fixed** (high) | `src/Surface.zig:5875-5884`; `src/input/Link.zig:58-63`; default link `config/Config.zig:4142` (`hover_mods` ctrl/super) | ccc103ce7. `linkAtPin` returns before `selectLine` unless some configured link's modifier rule is met, so a plain move with the default config reads nothing. | T3064 stays closed. |
| C10 | **fixed** (high) | `src/Surface.zig:5796-5805` (`linkHoverRefresh`), `:6172-6197`, `:2430-2433` | ccc103ce7. A move inside the same cell over the same screen pin keeps the link: no match, no apprt action, no `dirty.hyperlink_hover`. Behavior note, not a cost: text that changes under a still pointer without scrolling no longer refreshes the highlight until the pointer leaves the cell. | T3064 stays closed. |
| C11 | **still open** (high) | `src/Surface.zig:6239` (unconditional `queueRender`), `:6273-6279`, `:6385-6398`; `terminal/Screen.zig:2414-2434` | Unchanged apart from the line shift. `select` still untracks, tracks and sets `dirty.selection` with no equality check. | T3065 as written; update lines. |
| C12 | **changed** (high) | `src/Surface.zig:3945-3948`, `:4082-4083`, `:4457-4459`, `:4534-4535`; apprt read at `apprt/win32/Surface.zig:6858` | The four plain lock cycles per key event stand. What changed is the ground under audit-2's restatement: since T3068 (2b92c79da) the priority handoff works on agent-backed panes, the default (`config/Config.zig:1222`), so `lockPriority` now buys something there. The task's original wording (plain locks on the key path lose the race during a flood) is true again for agent panes. | T3066: keep both halves. Collapse the cycles into one, and take that one with `lockPriority`. Title can stay; drop audit-2/3's "rewrite it" hygiene note. |
| C13 | **still open** (high) | `font/shaper/harfbuzz.zig:134-148`; `renderer/generic.zig:3548-3556`, `:3817-3825` | Files unchanged. | T3067 as written. |
| C14 | **still open** (high) | `font/shaper/run.zig:75`, `:306-310`; `harfbuzz.zig:265-298`; `generic.zig:3509`, `:3548` | Files unchanged. | T3067 as written. |
| C15 | **fixed (incomplete)** (high) | `termio/Remote.zig:2320-2326` (`feedSlices` calls `afterSlice` after every slice), `:2351-2382` (handoff gated on `hasPriorityWaiters`); `renderer/State.zig:88-90`; still `:2690` (`slice_bytes = 1024`), `:2722` | 2b92c79da fixes the half that made it P1: the handoff is reachable for a 1 KiB chunk and costs one atomic load when nobody waits. Two unit tests pin reachability. The other half stands: one lock cycle per 1 KiB, 512 per wake. The render post per slice is now an atomic swap (T3061). The five `lockPriority` sites are `apprt/win32/Surface.zig:6181`, `:6858`, `:6946`, `IpcHandlers.zig:1427`, `renderer/generic.zig:1681`. | T3068 stays closed. T3228 (todo, P2) owns the slice size; its text still counts "render posts", which T3061 removed. |
| C16 | **still open** (high) | `termio/stream_handler.zig:1301-1443` (`reportPwd`; `isLocal` at `:1357`, `setPwd` and the surface message at `:1426-1434`); `os/hostname.zig:98-110` | Body unchanged, shifted by 16 lines. No compare against the current pwd before the parse, the syscall or the message. | T3069 as written; update lines. |
| C17 | **still open** (high), smaller | `src/Surface.zig:2383-2413` (`dirty.clear` at `:2405`); key path `:3962-3984` | The full rebuild per real modifier change stands. The link-match half shrank with C09: the key path's `mouseRefreshLinks` now returns before reading the line unless the new modifier set meets a link's rule (Ctrl does, Shift and Alt do not), and the read is bounded by C08. | T3099 as written; update lines; note the smaller second half. |
| C18 | **still open** (high) | `renderer/link.zig:63`, `:83`; `renderer/generic.zig:1823`, `:1854` | Files unchanged. | T3100 as written. |
| C19 | **still open** (high) | `font/WindowsFontIndex.zig:118-126`, `:152-166`, `:351-363`; `font/SharedGridSet.zig:180`, `:195` | `src/font/` unchanged. | T3149 (todo, P2) as written. |
| C20 | **still open** (high on mechanism; cost still unmeasured) | `renderer/generic.zig:1406`, `:1419-1437`, `:1478-1546`, `:2170-2183`, `:2256-2278`; `renderer/OpenGL.zig:1602-1606`, `:1646-1653` | Files unchanged. | T3141 (todo, P2, shared with PA-R20) as written. |

## Changed items

- **C12.** See the row. The lock count did not move; the value of
  `lockPriority` did, because T3068 made the handoff real on the default
  pane type. Audit-2's "lockPriority buys nothing until T3068" has expired.

## Fix-commit review

### T3060 / T3062, 09c94632b (reader batching, 64 KiB pipe): correct, two residuals

Read the whole `Exec.zig` diff, `read_coalesce.zig`, and the `pty.zig` hunk.

- **Quit path.** `threadExit` sets `read_thread_quit` (`Exec.zig:225`)
  before the `CancelIoEx` retry loop; the reader loads it before every
  blocking read (`:1597`) and inside the wait loop (`:1648`). The flag
  lives in `ThreadData`, which outlives the join. A close during a
  coalescing wait is delayed by at most one 500 us slice.
- **Idle cost: none.** The timer is armed only after a read that returned
  within 2 ms; an idle reader sits in `ReadFile`. Two `Instant.now()` calls
  per batch are new.
- **No timer, no wait.** If `CreateWaitableTimerExW` fails the reader logs
  once and keeps the old top-up.
- **Residual 1: one parse can now cover the whole 64 KiB buffer.** PA-C21.
- **Residual 2: the wait never ends early.** PA-C23.
- **Validation gap** recorded by the task itself: ^C during a flood was not
  run.

### T3061, 5059acb10 (wake coalescing): correct, one note

Read `wake_coalesce.zig`, the `Termio.zig`, `stream_handler.zig`,
`Thread.zig` and `Options.zig` hunks, and libxev's IOCP async.

- **No lost wakeup** found; reasoning is in the C04 row.
- **Order.** The request now follows the unlock in all three entry points
  (`Termio.zig:1114`, `:1145`, `:1188`), so a woken renderer no longer
  blocks on the mutex the parser holds.
- **Note (correctness, unlikely):** `wakeupCallback` returns `.rearm` on a
  wait error before `consume` (`Thread.zig:735-738`). If that path ever ran
  with the flag set, output-driven requests would be swallowed until some
  other producer (resize, focus, mailbox) woke the thread. Move `consume`
  above the error check.
- **Not covered:** the termio thread's own wakeup. `mailbox.zig:248`
  (`sendOverflow`) still notifies once per overflowed message; audit-3
  asked for that to be folded into T3061 and it was not. See Task hygiene.

### T3068, 2b92c79da (priority handoff): correct, the throughput half moved

Read the `Remote.zig` and `State.zig` hunks.

- Uncontended cost per slice: one atomic load (`State.zig:88-90`). The bare
  `SwitchToThread` branch of `yieldToPriorityWaiters` is not reached from
  here.
- Contended: the drain yields for at most 2 ms (`State.zig:65`) per slice.
  When the mutex is held by a third thread while a priority waiter queues
  behind it, the drain spins `SwitchToThread` for up to that budget rather
  than blocking; bounded, once per slice.
- The 1 KiB slice and 512 lock cycles per wake are unchanged (T3228).
- The comment at `Remote.zig:2283-2285` admits the 4 KiB `max_parse_slice`
  was not re-tuned after Exec moved to 16 KiB batches. Since `drainRing`
  pops 1 KiB, `max_parse_slice` is still dead for the live path.

### T3064, ccc103ce7 (link hover): correct and complete

Read the `Surface.zig`, `Screen.zig` and `Link.zig` hunks and
`cursorPosCallback` at HEAD.

- New per-move cost: one `pages.pin(.viewport)` (`Surface.zig:6175-6177`),
  taken under the renderer mutex the function already holds (`:6138`).
- `link_pin` is compared by value and never dereferenced, so a stale pin is
  safe.
- Not a regression: the click path (`mouse_mods == null`) is capped the
  same way, so a double-click on a link longer than about 65 wrapped rows
  selects its visible part only. Documented at `:5857-5860`.

### T3059, 74539ebe0 (baseline counters): does what C02 asked, one gap

The busy phase measures the Exec path only. PA-C22.

### T3234, 6ab6112e7: no source change

Evidence only. No regression introduced or removed in this area.

## New findings

### PA-C21: the Exec reader can now parse 64 KiB in one lock hold, and the Exec path has no priority handoff (P3, Windows)

- **Where:** `src/termio/Exec.zig:1587` (64 KiB buffer), `:1627` and
  `:1647` (`topUp` fills to `buf.len`), `:1688-1702`, `:1681`
  (`processOutput` of the whole fill); `src/pty.zig:422` (64 KiB pipe);
  `src/termio/read_coalesce.zig:22` (`target_bytes` = 16 KiB, used only to
  stop the wait); `src/termio/Termio.zig:1106-1115` (plain lock);
  `src/termio/Remote.zig:2377-2380` (the only caller of
  `yieldToPriorityWaiters` in `src/`).
- **Mechanism:** before T3062 the pipe held about 4 KiB, which in practice
  bounded one batch. Now whatever accumulated while the reader was blocked
  (a renderer frame holding the mutex, a `+read`) is taken in one `topUp`,
  up to 64 KiB, and parsed under one hold. `target_bytes` caps the wait,
  not the batch. And when 16 KiB or more is pending the reader does not
  wait at all, so it re-locks with only a read and a peek in between: the
  lost-race shape `renderer/State.zig` exists to stop, on a path that never
  yields to a priority waiter. `Remote.zig:2275-2290` documents the same
  hazard for the agent path, which slices at 1-4 KiB for this reason.
- **Cost:** computed from T1464's 0.06-0.07 us/byte (quoted in T3068): a
  64 KiB parse holds the mutex 3.9-4.6 ms in ReleaseFast, against about
  0.3 ms for the measured mean batch of 4.6 KiB (quoted, baseline-4). Rare
  in the measured flood (2.9 MB/s fills 16 KiB in 5.5 ms, so it needs a
  stall that long first). Exec is the persistence-off path, not the
  default. Debug builds pay far more per byte.
- **Fix:** cap one parse at `target_bytes` (pass `buf[0..@min(...)]`-sized
  fills to `topUp`, leave the rest in the pipe), and call
  `hasPriorityWaiters` / `yieldToPriorityWaiters` between batches as
  `Remote.zig:2377` does.
- **Shared with Mac:** no (`threadMainWindows`).
- **Confidence:** high on the mechanism; cost computed.

### PA-C22: the baseline's busy phase measures only the persistence-off path, so the default pane type has no busy row and no before/after for T3060/T3061/T3068 (P2)

- **Where:** `scripts/perf-baseline.ps1:116` (`-BusyPersistence` is an
  opt-in switch), `:1396-1401`, `:1465`; `docs/design/perf-audit/baseline-4.json`
  (`busy.persistence` false, `busy.perf.windows.agent_feed` 0 on both
  builds); `src/config/Config.zig:1222` (`session-persistence` defaults to
  true); the agent path's counters at `src/termio/Remote.zig:2303-2306`
  (`feed_telemetry`).
- **Mechanism:** the "about 8x fewer wakeups" in `audit-4.md` is the Exec
  reader. A default pane takes output through `Remote.drainRing`: 1 KiB
  per lock cycle, 512 per wake (C15's open half, T3228), and the agent and
  holder processes in front of it. T3061's coalescing reaches that path;
  T3060's batching does not (the agent got its own in T3236). None of it
  shows in a baseline, so a regression there would not trip `-Compare`,
  and T3228 has no recorded number to beat.
- **Cost:** a measurement gap, not CPU. Inferred: the largest share of
  real-world busy time is on the unmeasured path.
- **Fix:** run the busy phase twice in a baseline (persistence off and on)
  and store both under distinct keys; add `agent_feed.slices_per_s` and
  `lock_ms_per_s` to the compared metrics. Parse `coalesce_waits_per_s`
  while there.
- **Shared with Mac:** the script is Windows-only; the gap applies to the
  Mac agent path too (T3071).
- **Confidence:** high (read the script and the JSON).

### PA-C23: the reader's coalescing wait always runs to its 1 ms deadline, so the second batch of any short burst is held a full millisecond (P3, Windows)

- **Where:** `src/termio/Exec.zig:1635-1650`;
  `src/termio/read_coalesce.zig:38-49`.
- **Mechanism:** the first read after a pause parses at once. Any further
  read that returns within 2 ms (`stream_gap_ns`) enters the wait loop,
  which leaves only at 16 KiB or when `nextWait` returns null. A slice
  that brought no new bytes does not end it. So when a keystroke echo or a
  TUI repaint arrives as two or more conhost writes, everything after the
  first write lands 1 ms late, with two timer waits and two extra peeks.
  The file's own comment accepts this ("the tail of a burst lands this
  late").
- **Cost:** computed from the constants: up to 1 ms added to the tail of an
  interactive burst, and it can split one repaint across two frames at
  120 Hz. Whether conhost splits a typical echo into more than one write
  was not measured (inferred).
- **Fix:** end the wait when a slice adds nothing (the producer went
  quiet), which halves the tail to one 500 us slice; or shorten the first
  slice.
- **Shared with Mac:** no.
- **Confidence:** high on the mechanism; user-visible cost inferred.

## Checked and found clean

- **`wake_coalesce`** against libxev IOCP: no path strands a set flag
  while the waiter is registered.
- **`Remote.drainRing`'s new `isTaken` check** (`Remote.zig:2858`): one
  atomic load per wake (`remote/inbound_ring.zig:504-506`).
- **`recordTransportFailure`** (`Remote.zig:787-822`): bring-up failure
  path only.
- **`freshDefaultShell` / `bareShellCommand`** in `Surface.init`: once per
  surface.
- **`user_input_sent` writes**: a bool store on input paths.
- **`os/power.zig` `disableThrottlingFor`**: called per process the agent's
  PTY job gains, not per byte (agent area).
- **Unchanged files**: audit-3's clean list stands for `mailbox.zig`,
  `termio/Thread.zig`, `page_pool.zig`, `PageList.zig`, `generic.zig`.

## Not re-done

- No measurement. PA-C20's first-frame cost is still unmeasured.
- `src/remote/` (agent, holder, connection) changed heavily (T3016-T3021,
  T3235, T3236, T3243) and belongs to another area; only the calls made
  from `termio/Remote.zig` were followed.
- `src/apprt/win32/` callers were read only for the `lockPriority` sites.

## Task hygiene

- **T3066 (C12):** restore the priority half; see the row.
- **T3228:** its title counts render posts that T3061 already removed;
  the lock-cycle count is what is left.
- **Orphaned note:** audit-3 asked for `sendOverflow`'s per-message notify
  (`termio/mailbox.zig:248`) to be folded into T3061. T3061 closed without
  it. It is bounded per slice and small; fold it into T3228, which touches
  the same drain loop.
- **`Thread.zig:735-738`:** `consume` after the error return (see the
  T3061 review). One line; any task that next touches the renderer thread.

## Summary

- **Fixed (all rounds):** 10. C01 (audit-2); C06, C07 (audit-3); this
  round C02 (74539ebe0, T3059), C03 (09c94632b, T3060), C04 (5059acb10,
  T3061), C05 (09c94632b, T3062), C08, C09, C10 (ccc103ce7, T3064).
- **Fixed (incomplete):** 1. C15 (2b92c79da, T3068): the handoff is fixed,
  the 1 KiB slice is T3228.
- **Still open:** 8. C11 (T3065), C13, C14 (T3067), C16 (T3069), C17
  (T3099), C18 (T3100), C19 (T3149), C20 (T3141).
- **Changed:** 1. C12 (T3066).
- **Wrong:** 0.
- **New:** 3. PA-C21 (P3), PA-C22 (P2), PA-C23 (P3).
- **Fix-commit regressions:** none that change an answer or lose a frame.
  T3060 lengthened the Exec path's worst-case lock hold (PA-C21) and adds
  a fixed 1 ms to a burst's tail (PA-C23).
- **Open P0:** none. **Open P1:** none in this area; every audit-3 P1
  (C02, C03, C04, C08, C15) is closed, C15 with its P2 remainder.
- **T3234:** closed as box drift, no code change, nothing in this area
  implicated.
