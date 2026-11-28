# Audit-5, area C: shared Zig core hot paths (T3316)

- **Date:** 2026-11-28
- **Area:** C, shared Zig core (`src/Surface.zig`, `src/termio/`,
  `src/terminal/`, `src/font/`, `src/input/`, `src/pty.zig`, plus the shared
  parts of `src/renderer/` that the area's findings cite)
- **Audit:** audit-5, a re-audit of `../audit-4/C-findings.md`
- **Commit audited:** 5eaac0760a (audit-4 was c9af15802)
- **Input:** `../audit-4/C-findings.md` (PA-C01..PA-C23), `../audit-4.md`
  (PA id to task map), the task files under `../../windows-parity-tasks/`
- **Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. No
  build, test or app run; every verdict below comes from reading the code at
  HEAD and the source diff since audit-4.

## Method

1. `git diff --stat c9af15802 HEAD` over the area to see which files moved.
2. Every PA-C task file's `status:` and `commits:` read. **No PA-C task
   closed since audit-4**, so there was no fix commit to review; the whole
   area diff was read instead (`Surface.zig`, `termio/Exec.zig`,
   `termio/Remote.zig`, `termio/Thread.zig`, `termio/conpty_exit_gate.zig`,
   `renderer/Thread.zig`, `renderer/generic.zig`, `renderer/pace.zig`,
   `renderer/message.zig`, and the `renderer/OpenGL.zig` hunks).
3. The cited code re-read at HEAD for every PA id whose file changed, and the
   line numbers re-pinned. For a file with an empty diff since audit-4 the
   verdict is carried and the cited lines were spot-read.
4. Callees outside the area followed only as far as the new code calls them
   (`remote/connection.zig` `streamSnapshot`, `os/agent_exec_argv.zig`).
5. Costs are the tasks' own measurements where quoted; nothing was measured
   this turn.

## What moved since audit-4

`git diff --stat c9af15802 HEAD` over `src/Surface.zig`, `src/termio`,
`src/terminal`, `src/font`, `src/input`, `src/pty.zig`, `src/renderer`,
`scripts/perf-baseline.ps1`: 15 files, +929 / -116. Most of the 1341 commits
since audit-4 are GTK/Linux and never reach these files.

| File | Change | Task / commit |
|---|---|---|
| `src/renderer/pace.zig` (new, 127), `renderer/Thread.zig` (+40), `renderer/message.zig` (+5), `src/Surface.zig` (`paceCallback`, `:4728-4736`) | A pane in a window nobody is using holds its output-driven frames to 20 fps (`background`) or 4 fps (`glimpse`). The cursor-blink reset no longer forces a frame. | T3761, 7ce6815435 |
| `src/termio/Exec.zig` (+74), `termio/conpty_exit_gate.zig` (new, 94) | The child-exit gate also waits for conhost's first paint. One atomic load per batch on the reader once painted (`Exec.zig:1674`). The rest is `execCommand` argv splitting, at spawn. | T3383 (44bd4ee636), T3750 |
| `src/termio/Remote.zig` (+36) | `drainRing` reads `streamSnapshot()` instead of `streamPos()` and refuses to adopt an unsettled position; a `child_is_shell` message on an in-place respawn. | T1999 (97f4cbe484), T3328 |
| `src/termio/Thread.zig` (+20) | `updateLoopNow` wrapper for the Linux dynamic xev loop. On Windows it compiles to the same `loop.update_now()`. | T3330 |
| `src/Surface.zig` (+92) | Besides `paceCallback`: `child_is_shell`, `waitsAfterExit`, and the `-e` / WSL argv seam in `init` (`:1252-1269`). Init and exit paths only. | T3328, T3396, T3402, T3750 |
| `src/renderer/generic.zig` (+60) | `releaseFrameResources` split into `releaseFrameResources` / `releaseQueuedFrames` / `releaseFramesNow` for GTK's main-thread release. On win32 `queueAppThreadRelease` is comptime false, so the path is the old one. | T3645 |
| `src/renderer/OpenGL.zig` (+110), `gl_comp_present.zig`, `gl_window_presenter.zig`, `comp_overlay.zig`, `gl_loader.zig` | Area R's: composition retry for a stranded pane (T3739), D3D11 device pool (T3746), presenter slot reclaim (T2622), in-pane dim (T2618). Read only where C20 cites them. | area R |
| **No change** | `src/font/` (all), `src/terminal/` (all), `src/input/` (all), `src/pty.zig`, `termio/Termio.zig`, `termio/stream_handler.zig`, `termio/mailbox.zig`, `termio/read_coalesce.zig`, `renderer/link.zig`, `renderer/State.zig`, `renderer/wake_coalesce.zig`, `os/hostname.zig`, `scripts/perf-baseline.ps1`. Audit-4's line numbers in those files are still exact. | |

Line shifts since audit-4: `src/Surface.zig` +6 below 260, +22 below 1160,
+49 below 1880, +50 to +71 from 1920 to 4700, +84 past `paceCallback`
(`:4728`). `src/renderer/generic.zig` +13 below 830, +54 past
`releaseFrameResources`. `src/termio/Exec.zig` -6 from 380 to 1680.
`src/termio/Remote.zig` +11 from 2060 to 2640, +13 to +24 after.
`src/renderer/Thread.zig` +7 below 450, +17 to +26 after.

## Verdicts

Confidence is "high" where the cited lines were read at HEAD and the
mechanism traced end to end. Cost column: quoted (a task's own measurement),
computed (from constants in the code), or inferred.

| PA | Verdict | HEAD where | Evidence | Cost | Task action |
|---|---|---|---|---|---|
| C01 | **fixed** (high) | `src/Surface.zig:2438`, `:4034`, `:6209`; `src/input/key_mods.zig:99-101` | dacab7bec, unchanged. All three compares use `bindingEqual`. | n/a | T3058 stays closed. |
| C02 | **fixed** (high) | `scripts/perf-baseline.ps1` as audit-4 (file unchanged) | 74539ebe0. Gap stands as PA-C22. | n/a | T3059 stays closed. |
| C03 | **fixed** (high) | `termio/Exec.zig:1591` (atomic quit flag), `:1621` (top-up), `:1629-1644` (coalescing wait), `:1684` (`topUp`); `termio/read_coalesce.zig:22-49` | 09c94632b. Only the line shift and the new `painted` check at `:1674` (one relaxed atomic load per batch after the first paint; a scan of at most the batch before it, once). Residuals PA-C21, PA-C23 stand. | quoted (T3060: batches 29.2k -> 647/s) | T3060 stays closed. |
| C04 | **fixed** (high) | `termio/stream_handler.zig:187-190`; `termio/Termio.zig:1106-1115`, `:1124-1126`, `:1145`, `:1188`; `renderer/Thread.zig:761` (`consume`); `renderer/wake_coalesce.zig:41-58` | 5059acb10. The coalescing itself is intact. T3761 changed what a wake does on a capped pane, which weakens the saving there: PA-C24. | quoted (T3061: 31.5k/s -> 119 notifies/s) | T3061 stays closed. |
| C05 | **fixed** (high) | `src/pty.zig:422` | 09c94632b, file unchanged. | n/a | T3062 stays closed. |
| C06 | **fixed** (high) | as audit-3 (`src/font/` unchanged) | fb7b961ec. | n/a | T3011 stays closed. |
| C07 | **fixed** (high) | `src/Surface.zig:3671` (`setFontSize`); font files as audit-3 | fb7b961ec. | n/a | T3011 stays closed. |
| C08 | **fixed** (high) | `src/Surface.zig:5944` (`link_match_max_rows` = `terminal.hard_wrap.max_extend` = 32, `terminal/hard_wrap.zig:268`), `:5952-5982`; `terminal/Screen.zig` as audit-4 | ccc103ce7, unchanged. | n/a | T3064 stays closed. |
| C09 | **fixed** (high) | `src/Surface.zig:5952` (`linkAtPin` early-out); `src/input/Link.zig:58-63` | ccc103ce7, unchanged. | n/a | T3064 stays closed. |
| C10 | **fixed** (high) | `src/Surface.zig:5880` (`linkHoverRefresh`), `:6259-6282` | ccc103ce7, unchanged. | n/a | T3064 stays closed. |
| C11 | **still open** (high) | `src/Surface.zig:6323` (unconditional `queueRender`), `:6358-6360` (drag dispatch), `:6424-6434`, `:6466`, `:6475` (`select` with no compare); `terminal/Screen.zig:2414-2428` | Unchanged apart from the line shift. `select` still untracks, tracks and sets `dirty.selection` with no equality check. The same-cell early return at `:6399` and `:6448` (`samePin`) covers only the clicked cell of a double/triple drag. | inferred: one full rebuild per mouse event during a drag | T3065 (todo, P2) as written; update lines. |
| C12 | **still open** (high) | `src/Surface.zig:4016-4019` (KAM, config-gated), `:4047-4048` (on a modifier change), `:4153-4154`, `:4528-4530`, `:4605-4606`; apprt read at `apprt/win32/Surface.zig:6859` | Nothing moved since audit-4, which marked it "changed" because T3068 made `lockPriority` meaningful on agent panes. That restatement now simply stands: three to four plain lock cycles per key event, none taken with priority. | inferred: a keystroke can queue behind the drain's 1 KiB lock cycles during a flood | T3066 (todo, P2): collapse the cycles into one and take it with `lockPriority`. |
| C13 | **still open** (high) | `font/shaper/harfbuzz.zig:134-148`; `renderer/generic.zig:3602-3610`, `:3871-3879` | Font files unchanged; generic shifted +54. | inferred | T3067 (todo, P2) as written; update generic lines. |
| C14 | **still open** (high) | `font/shaper/run.zig:75`, `:306-310`; `harfbuzz.zig:265-298`; `generic.zig:3563`, `:3602` | As C13. | inferred | T3067 as written. |
| C15 | **fixed (incomplete)** (high) | `termio/Remote.zig:2331` (`feedSlices`), `:2362-2391` (`afterSlice`, handoff gated on `hasPriorityWaiters` at `:2388`); `renderer/State.zig:88-90`; still `:2703` (`slice_bytes = 1024`), `:2735` (512 chunks per wake) | 2b92c79da, unchanged. The open half stands: one lock cycle per 1 KiB. T1999 added one `seq_cst` load per pop (`:2766`, `remote/connection.zig:680-686`), which is noise. `lockPriority` sites at HEAD: `apprt/ipc/core_terminal.zig:39`, `apprt/win32/Surface.zig:6859`, `:7583`, `:7671`, `renderer/generic.zig:1735`. | computed: 512 lock cycles per 512 KiB wake | T3068 stays closed. T3228 (todo, P2) owns the slice size. |
| C16 | **still open** (high) | `termio/stream_handler.zig:1301-1443` (`reportPwd`; `isLocal` at `:1357`, `setPwd` and the surface message at `:1426-1434`); `os/hostname.zig:98-110` | Files unchanged. | inferred | T3069 (todo, P2) as written. |
| C17 | **still open** (high) | `src/Surface.zig:2433-2463` (`dirty.clear` at `:2455`); key path `:4034-4056` | Unchanged apart from the line shift. | inferred: one full rebuild per real modifier press and release | T3099 (todo, P2) as written; update lines. |
| C18 | **still open** (high) | `renderer/link.zig:63`, `:83`; `renderer/generic.zig:1876-1879` (seams), `:1908` (`renderCellMap`) | link.zig unchanged; generic shifted +54. | inferred | T3100 (todo, P2) as written; update generic lines. |
| C19 | **still open** (high) | `font/WindowsFontIndex.zig:118-126`, `:152-166`, `:351-363`; `font/SharedGridSet.zig:180`, `:195` | `src/font/` unchanged. | inferred | T3149 (todo, P2) as written. |
| C20 | **still open** (high on mechanism; cost still unmeasured) | `renderer/generic.zig:1419` (`idle_release_ns` = 3 s), `:1491-1511` (`releaseFrameResources`), `:1540-1598` (`releaseFramesNow`: `frame.resize(1, 1)` and atlas release), `:2249-2256` (re-arm on the first frame back), `:2325-2332` (target re-created); `renderer/OpenGL.zig:1641-1645`, `:1696` | The body moved into `releaseFramesNow` (T3645) with no change to what win32 does. T3761 does not touch it: the longest pace cap is 250 ms, well under 3 s. T3746's device pool changes which D3D11 device the shared texture is made on, not whether it is re-made. | unmeasured | T3141 (todo, P2, shared with PA-R20) as written; update lines. |
| C21 | **still open** (high) | `termio/Exec.zig:1581` (64 KiB buffer), `:1621`, `:1641` (`topUp` fills to `buf.len`), `:1676` (`processOutput` of the whole fill), `:1684`; `src/pty.zig:422`; `termio/read_coalesce.zig:22`; `termio/Termio.zig:1106-1115`; `termio/Remote.zig:2390` (still the only caller of `yieldToPriorityWaiters` outside `State.zig`) | Unchanged apart from the line shift. | computed: 3.9-4.6 ms hold for a 64 KiB parse | T3301 (todo, P3) as written; update lines. |
| C22 | **still open** (high) | `scripts/perf-baseline.ps1:116`, `:1396-1401` (unchanged); `config/Config.zig:1222` | Script unchanged; `coalesce_waits_per_s` still unparsed. T3761's pace adds a second unmeasured default: the baseline's busy window is the one in use, so no baseline row exercises a capped pane (see PA-C24). | measurement gap | T3302 (todo, P2) as written. |
| C23 | **still open** (high) | `termio/Exec.zig:1629-1644`; `termio/read_coalesce.zig:38-49` | Unchanged apart from the line shift. | computed: up to 1 ms on a burst's tail | T3303 (todo, P3) as written; update lines. |

## Changed items

None this round. C12 was "changed" at audit-4; nothing under it has moved
since, so it is carried as still open with audit-4's restated wording.

## Diff review (no PA fix commit this round)

### T3761, 7ce6815435 (window pace): correct, one residual

Read `pace.zig`, the `Thread.zig` and `message.zig` hunks and
`Surface.paceCallback`.

- **Default-path cost: none.** `paceDelayMs` (`Thread.zig:920-929`) returns
  at `capMs` with no clock read when low power is off and the pace is
  `full`, which is what it did before for low power alone.
- **No lost frame.** A deferred wake arms `render_c` once
  (`Thread.zig:779-781`); `renderCallback` then builds with everything
  parsed in between. A pace change is a mailbox message, so it forces the
  catch-up frame (`:456`, `:548`).
- **`reset_cursor_blink` no longer forces** (`:456`). On a full-pace pane
  this removes up to two forced presents a second while output flows; the
  frame still presents when it changed pixels.
- **Residual:** a capped pane's wake is now so cheap that the coalescing
  flag stops limiting the wake rate. PA-C24.
- **Old note still open:** `wakeupCallback` returns `.rearm` on a wait error
  at `Thread.zig:752-755`, before `consume` at `:761` (audit-4's T3061
  review). Still one line, still unowned.

### T1999, 97f4cbe484 (settled stream position): clean

`drainRing` (`Remote.zig:2766-2775`) reads two atomics instead of one per
pop. An unsettled empty pop either retries at once (bounded by the chunk
counter) or breaks and is woken by `finishRoute`
(`remote/connection.zig:707-716`): at most one extra IO-thread wake per
raced frame, in exchange for the `+16/-16` correction pairs and their log
lines.

### T3383, 44bd4ee636 (exit gate): clean

`shouldFire` (`conpty_exit_gate.zig:27-30`) can hold the exit notice for up
to 20 ticks of 50 ms when conhost never paints; the timer exists only while
an exit is pending. The reader's cost is the one atomic load in the C03 row.

### T3645 (generic.zig release split): no win32 change

`queueAppThreadRelease` returns comptime false off GTK
(`OpenGL.zig:1652-1656`), so `releaseFrameResources` falls through to
`releaseFramesNow` on the render thread as before.

## New findings

### PA-C24: a capped pane's renderer thread wakes once per output batch, because the coalescing flag is cleared before the pace check (P3)

- **Where:** `src/renderer/Thread.zig:761` (`wake_coalesce.consume`),
  `:778-783` (pace check, timer armed, return), `:920-929` (`paceDelayMs`);
  `src/renderer/wake_coalesce.zig:41-58`; request sites
  `src/termio/stream_handler.zig:187-190`, `src/termio/Termio.zig:1114`,
  `:1145`, `:1188`; caps `src/renderer/pace.zig:34`, `:37`.
- **Mechanism:** T3061 limits renderer wakeups by leaving the flag set until
  the renderer wakes. That worked because a wake used to cost a frame
  (milliseconds), during which every further request found the flag set.
  On a capped pane the wake now clears the flag, finds the cap not yet due,
  and returns in microseconds. The next parsed batch finds the flag clear
  and posts another IOCP wakeup. So during the 50 ms or 250 ms hold the
  renderer thread is woken once per batch for nothing: per 1 KiB slice on
  the agent path (`Remote.zig:2703`), per coalesced read on Exec. The same
  shape existed for low-power mode (T1951); T3761 extends it to every pane
  outside the window in use, by default.
- **Cost:** computed from the constants: a flooding background agent pane
  at T3060's 2.9 MB/s can post up to about 2,900 wakeups a second against
  the 20 frames it draws; each is an IOCP post, a thread wake, an empty
  mailbox drain and a clock read. T3761's measured case (50 windows at
  about 50 chunks a second each, 11 cores down to 1.4) leaves about 2,500
  such wakes a second in total. Share of the remaining 1.4 cores: inferred,
  not measured.
- **Fix:** when `paceDelayMs` defers, leave the flag set (or set it again)
  and clear it in `renderCallback` just before `updateFrame`. Mailbox
  producers notify the async directly, so forced frames are not held.
- **Introduced by:** 7ce6815435 (T3761), as an extension of T1951's shape.
- **Shared with Mac:** the code is shared; macOS never sends `.pace`, so
  only its low-power path has it.
- **Cross-area:** may overlap whatever area R files against T3761.
- **Confidence:** high on the mechanism; cost computed and inferred.

### PA-C25: opening a pane with `-e` words that need quoting walks PATH x PATHEXT with a file stat per candidate on the GUI thread (P3, Windows)

- **Where:** `src/Surface.zig:1252-1269` (in `init`, gated at `:1159-1160`
  on an explicit command for the local agent);
  `src/os/agent_exec_argv.zig:114-127` (`agentExecArgv`), `:51-77`
  (`resolveProgram`), `:79-104` (`tryCandidates`), `:106-109` (`isFile`,
  `statFile`), `:179-186` (`agentWslArgv` reads PATH and PATHEXT before it
  checks the line is WSL at `:209`).
- **Mechanism:** a bare program name with no extension is tried as
  `dir\name<ext>` for every PATH directory times every PATHEXT entry until
  one exists. A cmd builtin or a mistyped name is never found, so the walk
  is the full product: about 60 directories times 11 extensions is 660
  failed opens, each on the thread that is creating the window. A PATH
  entry on a slow or disconnected share is paid in full. The WSL branch
  copies PATH and PATHEXT for every configured `.shell` command that
  reaches it, WSL or not.
- **Cost:** inferred: tens of microseconds per failed local stat, so
  roughly 10-30 ms once per such pane open on a long local PATH, unbounded
  with a dead network directory. Only `-e` commands where a word holds a
  space or quote (`needsQuoting`, `:33`) pay the walk. Not per frame.
- **Fix:** check `isWslProgram` before the environment reads; resolve with
  `SearchPathW` per extension or stop at the first directory that holds any
  candidate; or resolve on the IO thread, where `Remote.init` already runs.
- **Introduced by:** a652b8b42e (T3402); the WSL branch by 33081a9db0
  (T3750).
- **Shared with Mac:** no (comptime Windows).
- **Confidence:** high on the mechanism; cost inferred.

## Checked and found clean

- **`Surface.paceCallback`** (`Surface.zig:4728-4736`): one mailbox push
  and one `queueRender` per pace change; the apprt sends changes only
  (`apprt/win32/Window.zig:5165-5168`).
- **`child_is_shell` / `waitsAfterExit`**: exit path only.
- **`Exec.execCommand`'s quoted-program split** (`Exec.zig:1878-1893`, T3750):
  spawn only.
- **`termio/Thread.zig` `updateLoopNow`**: identical code on Windows.
- **`OpenGL.presAcquire` reclaim loop** (`OpenGL.zig:1743-1775`, area R,
  opt-in window presenter): the `continue` cannot spin; a failed `reclaim`
  means the pending slot was just taken, so the next `acquire` succeeds.
- **`compBegin` retry** (`OpenGL.zig:1493-1501`): a clock read per frame
  only while a stranded pane has a retry scheduled.
- **Unchanged files**: audit-4's clean list stands for `mailbox.zig`,
  `page_pool.zig`, `PageList.zig`, `wake_coalesce.zig`, `read_coalesce.zig`.

## Not re-done

- No measurement. PA-C20's first-frame cost and PA-C24's wake rate are
  unmeasured.
- `src/remote/` belongs to another area; only `Pane.streamSnapshot`,
  `requestAdoptWake` and `finishRoute` were read.
- `src/apprt/win32/` was read only for the `lockPriority` sites and the
  `paceCallback` caller. `src/apprt/gtk/` was not read.
- `src/os/user_env.zig`, `os/ipc_client.zig`, `os/cli_launch.zig`,
  `config/` and `crash/` changed but are startup, CLI or crash paths
  outside this area's list.

## Task hygiene

- **Line numbers:** every open task in this area (T3065, T3066, T3099,
  T3100, T3141, T3301, T3303, and T3067's generic.zig cites) carries
  pre-shift lines; the table above has the HEAD ones.
- **T3228:** still counts "render posts" that T3061 removed (carried from
  audit-4).
- **Orphaned notes (carried):** `sendOverflow`'s per-message notify at
  `termio/mailbox.zig:248`; `consume` after the error return at
  `renderer/Thread.zig:752-761`. PA-C24's fix touches the second spot and
  can take it.

## Summary

- **Fixed (all rounds):** 10. C01-C10. None newly fixed this round: no PA-C
  task closed between c9af15802 and 5eaac0760a.
- **Fixed (incomplete):** 1. C15 (2b92c79da, T3068); the 1 KiB slice is
  T3228.
- **Still open:** 12. C11 (T3065), C12 (T3066), C13, C14 (T3067), C16
  (T3069), C17 (T3099), C18 (T3100), C19 (T3149), C20 (T3141), C21
  (T3301), C22 (T3302), C23 (T3303).
- **Changed:** 0. **Wrong:** 0.
- **New:** 2. PA-C24 (P3, from T3761), PA-C25 (P3, from T3402/T3750).
- **Regressions from fixes:** none from a PA fix. PA-C24 is a side effect
  of T3761, which is itself a large net saving.
- **Open P0:** none. **Open P1:** none in this area; every open item is P2
  or P3.
