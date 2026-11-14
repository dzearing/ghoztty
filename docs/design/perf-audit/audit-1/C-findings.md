# Audit-1, area C: shared Zig core hot paths (T2964)

- **Date:** 2026-11-14
- **Commit audited:** e9b6d84ea
- **Baseline:** `../baseline-1.json` (T2958). A pane printing 64 MB via
  `cmd /c type` takes about 30-35 s (about 2 MB/s) at 66-72% of one core of
  app CPU, with about 28,500 context switches/s. The idle figure is about 210/s.
  The baseline does not separate the app's threads, and it does not measure
  mouse movement or typing. So the busy costs below are inferred from that
  number plus the T1464/T1465 reader telemetry, and the input costs are
  estimates. PA-C02 adds the attribution.

**Produced by** three Fable 5.2 auditors (`claude-fable-5-2`, passed
explicitly) working read-only and in parallel:

1. **A: the output path.** ConPTY to the terminal: `src/termio/` (the
   `Exec.zig` reader, `Termio.processOutput`, `Remote.zig` drain,
   `stream_handler`), and the renderer wakeup on IOCP (libxev).
2. **B: parse and state.** `src/terminal/` stream, parser, print, scroll,
   `PageList`, OSC handling, SIMD on Windows, and the fork's edits to those
   files since the merge-base.
3. **C: input and fonts.** `src/Surface.zig` key, mouse, link and selection
   paths, `src/input/`, and `src/font/` as built on Windows (HarfBuzz, the
   `discovery.Windows` scanner, `SharedGrid`).

Areas R, W, M, I and V were read first and are not re-reported.

**Verification.** This turn read the cited lines for every surviving claim
before filing it, including libxev's `iocp.zig:850-861` in the pinned
dependency (hash `86vtc4…`). These were merged:

- A01 and B02 are one defect (PA-C03).
- A03, B04 and A06 are one cluster (PA-C04).
- A05 and B03 are one defect (PA-C05).
- A04 and A07 are one cluster (PA-C15).

## What the area does and does not explain

- **Parsing is not the bottleneck.** B diffed every shared hot file against
  the merge-base. No Ghoztty edit adds per-byte or per-line cost in a release
  build:
  - SIMD is on for Windows (`src/build/Config.zig:251-261`,
    `SharedDeps.zig:832-941`).
  - The slow integrity checks compile out of the app (`SharedDeps.zig:141-145`).
  - Hot-path asserts are `unreachable` in release.

  Debug used 25.5 CPU-s and ReleaseFast 20.3 CPU-s for the same 64 MB. That
  gap bounds ReleaseFast parse and state at about 3% of app CPU.
- **The 2 MB/s ceiling is conhost's.** T1464 measured the reader's consumer
  waiting on the producer: 60-73 bytes per read, parse about 4%, lock wait
  about 3%.
- **What the app adds is per-batch overhead:**
  - one quit-pipe peek, one read and one top-up peek per batch
  - one lock cycle per batch
  - one IOCP post to the renderer per batch, even when one is already
    pending

  At 19-29k batches/s that is the same order as the 28.5k context switches/s
  (PA-C03, PA-C04). The rest of the 66-72% is inferred to be renderer frame
  work (area R) and is not attributed. PA-C02 settles it.
- **The largest input-side cost is a plain bug.** With NumLock on, every
  mouse move over a pane forces a full rebuild (PA-C01).

## Findings

| Id | Pri | Finding | Task |
|---|---|---|---|
| PA-C01 | P0 | NumLock or CapsLock makes every mouse move and keystroke a full rebuild (*shared*) | T3058 |
| PA-C02 | P1 | The busy phase records none of the existing `GHOZTTY_PERF` counters (tooling) | T3059 |
| PA-C03 | P1 | The reader does 3 syscalls, a lock and a post per ~60-110 bytes of a flood | T3060 |
| PA-C04 | P1 | A redundant IOCP renderer post per batch, from inside the lock, before the parse | T3061 |
| PA-C05 | P2 | The ConPTY output pipe is the 4 KB default | T3062 |
| PA-C06 | P1 | Each uncovered codepoint rescans every font file under the exclusive grid lock | T3063 |
| PA-C07 | P1 | Each new font size rescans the font directory on the GUI thread | T3063 |
| PA-C08 | P1 | Link hover stringifies an unbounded soft-wrapped line under the renderer mutex (*shared*) | T3064 |
| PA-C09 | P2 | `linkAtPin` allocates before checking whether any link can match (*shared*) | T3064 |
| PA-C10 | P2 | Over a link, every pixel of movement re-matches and forces a full rebuild (*shared*) | T3064 |
| PA-C11 | P2 | A drag selection re-tracks pins and forces a full rebuild on every event (*shared*) | T3065 |
| PA-C12 | P2 | `encodeKey` takes a plain lock, giving up the T114 priority | T3066 |
| PA-C13 | P2 | A shaping miss holds the grid's exclusive lock across HarfBuzz | T3067 |
| PA-C14 | P2 | The run iterator fills the HarfBuzz buffer before the cache is checked | T3067 |
| PA-C15 | P2 | The agent drain parses 1 KiB per lock and post, and its priority yield is unreachable | T3068 |
| PA-C16 | P2 | OSC 7 does full work and posts a GUI message for an unchanged directory (*shared*) | T3069 |

The Mac half of the shared fixes (PA-C01, C08-C11, C15, C16) is T3071. A
correctness defect found in passing is T3070: the Windows font discovery
ignores bold and italic.

### PA-C01: NumLock/CapsLock full rebuild per event (P0)

- **Where:**
  - `src/Surface.zig:2316-2321`: `modsChanged` tests
    `!self.mouse.mods.equal(mods)`, then stores `mods.binding()`.
  - `src/input/key_mods.zig:106-113`: `binding()` keeps only shift, ctrl,
    alt and super.
  - `src/apprt/win32/Surface.zig:7165-7170`: sets `caps_lock` and
    `num_lock` from `GetKeyState`.
  - Callers: `cursorPosCallback` (`src/Surface.zig:5866`) and the key path
    (`:3814`). The key path also runs `getCursorPos` and `mouseRefreshLinks`
    under the renderer mutex.
- **Mechanism:** with a lock key toggled on, the stored mods and the raw
  mods never compare equal. Each event therefore sets
  `terminal.flags.dirty.clear = true` and queues a render. The code comment
  says "its really only one frame", which assumes a real change.
- **Cost (estimated):** 60-125 full-viewport rebuilds/s while the pointer
  moves, plus two per keystroke. At 2-5 ms per rebuild (inferred from the
  resize figure), that is roughly 10-50% of a core. NumLock is on by
  default on most desktop keyboards.
- **Fix:** compare against `mods.binding()` at both sites.
- **Risk:** trivial.

### PA-C02: the busy phase cannot attribute its CPU (P1, tooling)

- **Where:** `scripts/perf-baseline.ps1` has no `GHOZTTY_PERF` reference.
  The counters it would read already exist:
  - `src/termio/Exec.zig:1548-1633`
  - `src/termio/stream_handler.zig:138-166`
  - `src/renderer/Thread.zig:629-656`
- **Fix:** run the busy phase with `GHOZTTY_PERF=1` and record a
  `busy.perf` block: reads/s, batches/s, bytes per batch, queued renders/s,
  renderer wakeups/s and fps. Add per-thread CPU and context switches by
  thread role (this extends PA-W05).
- **Risk:** trivial.

### PA-C03: per-batch reader overhead (P1)

- **Where:** `src/termio/Exec.zig:1568-1611` and `:1639`.
- **Mechanism:** each iteration does `PeekNamedPipe(quit)`, a blocking
  `ReadFile`, a top-up `PeekNamedPipe`, then `processOutput`. The top-up
  (T62) only coalesces bytes that are already waiting, so in a steady flood
  one batch is about one conhost write. T1464/T1465 measured 60-73 bytes per
  read.
- **Cost (estimated):** 5-8 µs per iteration at 19-29k iterations/s. That is
  10-16% of a core, plus most of the context switches.
- **Fix:**
  - Replace the quit-pipe peek with an atomic flag set by `threadExit`. The
    20 ms retry at `:244-254` already covers the race.
  - Coalesce adaptively: after a non-trivial read whose top-up peeks 0, wait
    up to ~1 ms (high-resolution, not a 15.6 ms `Sleep`) or until 16 KB is
    pending.
  - An isolated echo still parses at once.
  - This needs PA-C05 first.
- **Risk:**
  - Trivial for the flag.
  - Medium for the coalescing (echo latency, and the T62 starvation
    history).
  - T1465 reverted an unconditional 1 ms holder wait because throughput did
    not move. CPU and context switches were never measured then, and they
    are the target here.

### PA-C04: redundant renderer posts (P1)

- **Where:**
  - libxev `src/backend/iocp.zig:850-861`: `async_notify` calls
    `PostQueuedCompletionStatus` unconditionally, after
    `src/watcher/async.zig:597-606` takes a guard mutex.
  - The loop discards the stale packets (`iocp.zig:343-346`).
  - Callers: `stream_handler.zig:171-174`, called from
    `Termio.zig:1190-1192` inside the mutex and before the parse ("We can
    call this first because we have the lock"), and `Remote.zig:2180-2182`.
- **Cost (computed from the batch rate):** 19-29k redundant syscalls/s, and
  as many packets for the renderer to dequeue. An idle renderer woken before
  the parse blocks on the mutex the reader still holds.
- **Fix:** an app-side atomic `render_pending` flag. `queueRender` skips the
  post while the flag is set; the renderer's wakeup callback clears it
  before draining. Notify after the parse and unlock. Do not fork libxev.
- **Risk:** medium. A lost wakeup is a frozen pane (T40).

### PA-C05: 4 KB ConPTY output pipe (P2)

- **Where:** `src/pty.zig:417`:
  `CreatePipe(&pty.out_pipe, &pty.out_pipe_pty, null, 0)`.
- **Mechanism:** the reader's buffer is 64 KB, but the pipe holds about 2 ms
  of output at 2 MB/s. Any reader stall blocks conhost's write.
- **Fix:** `nSize` of 64 KB-1 MB. Re-check the "~4 KiB pieces" note at
  `Remote.zig:2219`.
- **Risk:** low.

### PA-C06 and PA-C07: no font index on Windows (P1)

- **Where:**
  - `src/font/discovery.zig:929-937`: `discoverFallback` drops the
    collection and calls `discover`.
  - `discover` walks the system and user font folders, calling
    `Face.initFile` per face (`:959-1008`, `:1050-1085`).
  - On a codepoint miss, `src/font/CodepointResolver.zig:167-213` runs it
    while `src/font/SharedGrid.zig:172-181` holds the exclusive lock.
  - `src/Surface.zig:3451-3462` → `SharedGridSet.zig:122-134` and `:191-197`
    run it per style per family on each new size.
- **Cost (estimated from the file's own note at `:896-899`):**
  - 50-300 ms per distinct missing codepoint, stalling every pane on the
    grid.
  - 40-200 ms of GUI thread per zoom step when `font-family` is set.
- **Fix:** a lazy, off-GUI-thread index of path, face, family, style and
  cmap coverage, invalidated on `WM_FONTCHANGE`. DirectWrite
  `MapCharacters` is the alternative.
- **Risk:** medium.

### PA-C08 to PA-C10: link hover (P1)

- **Where:** `src/Surface.zig:5623-5660` (`linkAtPin`).
  - `Screen.selectLine` (`src/terminal/Screen.zig:2556-2650`) follows soft
    wraps with no cap. Only hard wraps are capped, at 32.
  - Then `selectionString` with a pin-per-byte map, then the regexes.
  - All of it runs on the GUI thread, holding the renderer mutex.
- **The three findings:**
  - **PA-C08:** a 1 MB unbroken line costs megabytes per cell crossed.
  - **PA-C09:** the mods check (`:5650-5654`) runs after the allocation,
    and the default link is ctrl-hover (`Config.zig:4104-4106`).
  - **PA-C10:** while over a link, `:5918-5926` skips the same-cell check,
    so every event re-matches and forces a full rebuild.
- **Fix:**
  - Return early when no link's highlight matches the mods.
  - Cap the soft-wrap walk.
  - Skip the re-match while the cell is unchanged.
- **Risk:** low.

### PA-C11 to PA-C16 (P2)

- **PA-C11:** `src/Surface.zig:5969`, `:6115-6128` and
  `Screen.zig:2414-2428`. Each drag event tracks new pins and sets
  `dirty.selection`, even when the selection is unchanged.
- **PA-C12:** `src/Surface.zig:4304-4307`. A plain `lock()` to read
  `win32_input`, after the apprt already took the priority lock
  (`apprt/win32/Surface.zig:6716-6722`).
- **PA-C13 and PA-C14:**
  - `shaper/harfbuzz.zig:134-148` and `shaper/Cache.zig:67-78` hold the
    grid write lock across `hb_shape`.
  - `run.zig:75`, `:306-310` and `harfbuzz.zig:265-298` fill the buffer per
    cell before the cache is checked.
  - This is the HarfBuzz path only, so no Mac half is owed.
- **PA-C15:** `src/termio/Remote.zig:2590` (`slice_bytes = 1024`). The
  1 KiB pop means `feedSliced`'s `it.rest.len > 0` (`:2276-2279`) is never
  true, so `yieldToPriorityWaiters` never runs. A 2 MB replay costs 2,048
  lock cycles and posts.
- **PA-C16:** `stream_handler.zig:1283-1420`. `reportPwd` has no repeat
  check. It calls `GetComputerNameA` (`src/os/hostname.zig:104-110`),
  allocates, and posts `.pwd_change` per OSC 7.

## Claims that did not survive verification, or were not filed

- **B-01, the renderer builds a frame per wakeup with no cap under flood
  (P1 as claimed):** not filed.
  - T1462 measured exactly this. It was closed `skipped(not reproducible:
    presents stay at or below the display refresh up to 27k writes/s)`, and
    a timer cap halved fps.
  - `src/renderer/Thread.zig:692-693` still renders immediately, so the
    claim about the code is true. Its cost is unmeasured.
  - PA-C02's fps and wakeup counters are the evidence that would re-open
    it. PA-C04 removes the redundant posts either way.
- **B-06, two surface messages per command (OSC 133 C/D):** not filed. The
  auditor itself proposed no fix. It is a tail risk only when the app
  mailbox is full.
- **B-07, the ReleaseFast staging build targets baseline x86_64:** not
  filed. Parse is at most about 3% of app CPU, and the C++ SIMD dispatches
  at runtime (`src/simd/vt.cpp:292-298`).
- **C's correctness aside, `matches` ignores bold and italic:** confirmed,
  and filed as a correctness task (T3070), not as a performance finding.

## Checked and found clean

- **Reader buffer:** 64 KB on the stack, with no copy before the parser
  (`Exec.zig:1560`).
- **ASCII print path:** no allocation or table lookup (`stream.zig:536-545`
  → `Terminal.zig:327`, `:574`, `:706`).
- **Scroll at the scrollback limit:** reuses the oldest page in place, with
  no pool allocation per line (`PageList.zig:3132-3246`).
- **Fork edits to the hot files:** `stream`, `Terminal`, `PageList`, `page`,
  `Screen`, `osc` and `stream_handler`. None touches print, index or grow in
  a release build.
- **Per-chunk checks:** `title_pace`, `conpty_sync_hold` and the
  `processOutputLocked` extras are a branch each, with no allocation.
- **Termio thread at idle:** no idle timer. The 4 ms redraw poll runs only
  while a resize waits for a prompt redraw.
- **Keybinding lookup, key encoding, mouse reports and scroll:** no
  per-event allocation.
- **Fallback misses:** cached, including negative results (the gap is
  PA-C06).
- **Glyph and codepoint caches:** take a read lock on the fast path.
- **Link regexes:** compiled once, with a retry budget.

## Filed as

- **Windows:** T3058-T3070, with deps on T2964. T3060 and T3061 also depend
  on T3059 (measurement first).
- **Roll-up (T2965):** T3063 (PA-C06/C07) was the same defect as area M's
  T3011 (PA-M11). It is folded into T3011 and closed as a duplicate; see
  `../audit-1.md`.
- **Mac half:** T3071 (`seat: mac`), depending on T3058, T3064, T3065, T3068
  and T3069.
