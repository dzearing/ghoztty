# Audit-3, area I: IPC and the agent (T3101)

- **Area:** I, IPC and the agent (`src/remote/agent/`, the win32 IPC server,
  `src/os/ipc_client.zig`, the app's agent link, the pty holder)
- **This is audit-3, a re-audit of `../audit-2/I-findings.md`** (and through
  it of `../audit-1/I-findings.md`)
- **Commit audited:** d0d874326 (audit-2 was 879fba35a)

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. Nothing
was built, run or measured. Every verdict is from reading the code at HEAD;
every cost is carried from an earlier audit, quoted from a fix commit, or
computed from the code, and says which.

## What moved since audit-2

The brief expected no fixes in this area. The diff says otherwise: three
changes landed, two of them fixes for I findings that were made under other
task ids, so the tracker still shows the PA tasks as `todo`.

`git diff --stat 879fba35a HEAD` over `src/remote`, `src/os`, `src/termio`,
`src/apprt/win32/Ipc*`, `ipc_*.zig`, `LocalAgent.zig`,
`MachineConnectionPool.zig`, `SessionRoster.zig`, `RemoteReconnect.zig` and
`src/terminal/PageList.zig`:

| File | Change | Commit / task |
|---|---|---|
| `src/remote/agent/server.zig` | +372: bounded outbound DATA queue, chunked ring catch-up, two tests | d5f83c3d4 (Mac), merged by 6dc6ecb90 (T3102); named-pipe test 2df535dc0 (T3108) |
| `src/remote/agent/session.zig` | +22: `bridge_data` returns `bool`; live output only to a level viewer | same |
| `src/remote/agent/main.zig` | +53: `acceptRetryDelayMs` for the socket accept loop | same |
| `src/apprt/win32/IpcServer.zig` | 174 lines: overlapped instances, 16 listeners, bounded I/O | e4bfd30f5 (T3105) |
| `src/apprt/win32/ipc_pipe_io.zig` | new, 286 lines | e4bfd30f5 (T3105) |
| `src/os/ipc_client.zig` | 10 lines, comments only | e4bfd30f5 (T3105) |
| `src/terminal/PageList.zig` | 168 lines: `ExactPool`, `page_preheat` 1 on Windows | 0f71734a4 (T3003), ede873611 (T3004); area M's commits, but they change PA-I17 |
| `src/termio/Thread.zig`, `mailbox.zig` | mailbox overflow fix | 65fce4b64 via T3102; the termio thread, not this area. `termio/Remote.zig` did not move |

Every other file in the area is byte-identical to audit-2: `client_mux.zig`,
`connection.zig`, `protocol.zig`, `pipe_stream.zig`, `tcp_dial.zig`,
`inbound_ring.zig`, `agent/mux.zig`, `pty_host.zig`, `pty_host_proto.zig`,
`pty_child.zig`, `pty_holder_child.zig`, `foreground.zig`,
`grid_snapshot.zig`, `IpcHandlers.zig`, `LocalAgent.zig`,
`ipc_session_await.zig`. Their line numbers are audit-2's. In `session.zig`
lines after 787 moved by +7 and lines after 1681 by +16; in `server.zig`
everything after 219 moved (re-cited below).

## Verdicts

Confidence is high (cited lines read at HEAD, mechanism traced) unless a row
says otherwise.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-I01 | fixed (fc7f7fdfb), unchanged since audit-2 | `agent/session.zig:1741`, `agent/main.zig:1851`, `IpcServer.zig:253` | The spawns I re-read still pass `thread_stack.config`. The 12 new IPC listener threads (PA-I11's fix) use it too | T3015 stays closed. The app's short-lived `.{}` workers are still T3075 (todo) |
| PA-I02 | still open | `client_mux.zig:201-222` (re-encode `:211-212`, fifo write `:217`), `connection.zig:4031-4067` (second parse); kept buffers `client_mux.zig:292-295`, `protocol.zig:2315-2318` | Files unchanged. Pump parses, re-encodes into `wire`, copies into a fifo; the data reader copies out and parses again. Agent mirror `agent/mux.zig:131-139` | T3016 unchanged (PA-I19 still folded) |
| PA-I03 | still open | `agent/main.zig:169`; `server.zig:912-924` (`sendDataFramed`: alloc, encode, free), `:838-861` (`enqueue`: dupe at `:845`) | `GeneralPurposeAllocator(.{})` in every build mode. Two allocations and two copies per chunk before the writer's encode. The new code adds a second `write_mutex` round trip per chunk (`dataQueueHasRoom`, `:865-870`), negligible | T3017: re-cite `server.zig:912`, `:845` |
| PA-I04 | still open | `session.zig:491-495` (append), `:505-510` (`copyRetained`), `:566-571` (`slice`) | Unchanged. `slice` gained a hot caller: every 64 KiB catch-up piece (`server.zig:2609`), see PA-I21 | T3018: add `server.zig:2609` to the callers (PA-I18 still folded) |
| PA-I05 | changed (wider) | `session.zig:1668-1670` (`onChildOutput`), `server.zig:1521-1522` (`handleAttach`), `:2543-2544` (`handleFlow`), **new** `:2622-2623` (`catchUpBacklog`, on the writer thread) | Still one `SessionStore.mutex`. Since d5f83c3d4 each connection's writer thread also takes it, to refill its queue from the rings. See "Changed items" | T3019: add the writer thread as a fourth holder |
| PA-I06 | still open | `session.zig:1746` (30 ticks), `:1828-1832`, `:3081` (`historyAlloc` before the unlock at `:3084`), `atomic_write.zig:90` | Unchanged apart from the +16 shift | T3020: re-cite |
| PA-I07 | still open | `pty_host.zig:329-342` (200 ms), `:355` (500 ms linger); `pty_holder_child.zig:843`, `:1177`, `:1191` (50 ms), `:606` (200 ms redial) | File unchanged | T3021 unchanged |
| PA-I08 | still open | `IpcHandlers.zig:810` (TCP dial on the GUI thread), relay arm above it; `tcp_dial.zig:180` (`tcpConnectToHost`, no timeout) | Files unchanged | T3022 unchanged |
| PA-I09 | still open | `foreground.zig:117`, called per live session from `session.zig:2298`, every 10 ticks (`:1753`, `:1805-1812`); `sampleDescendants` `:1789` (1 s); vanish sweep `:1795-1797` (5 s) | Unchanged apart from the shift | T3023: re-cite |
| PA-I10 | still open | `IpcServer.zig:387-405` (post at `:393`, sleep at `:404`); `ipc_session_await.zig:34`, `:37` (3000 ms, 15 ms) | Function untouched by e4bfd30f5 | T3024: re-cite `IpcServer.zig:387-405` |
| PA-I11 | fixed (e4bfd30f5, T3105) | `ipc_pipe_io.zig:33` (5 s bound), `:57` (overlapped instances), `:109-111` (owned, bounded `Conn`), `:116-133` (bounded hang-up wait); `IpcServer.zig:57` (16 instances), `:288-290` (cancel on quit), `:417-432` (bounded reads), `:548-553` (bounded writes) | A silent client now costs 1 of 16 instances for at most 5 s. The reply write audit-2 flagged is bounded as well (`ipc_client.zig:159`, `:99-106`). Residual, not a perf cost: the bound is per read, not per request, so a client that trickles a byte every few seconds can hold an instance longer; only this user can open the pipe | Close T3025 against e4bfd30f5 |
| PA-I12 | changed (wider) | `pipe_stream.zig:251-252`, `:278-279`, `:407-408`; `os/ipc_client.zig:189-195`; **new** `ipc_pipe_io.zig:80-86` | The IPC server used to do synchronous I/O. It now creates and closes an event per accept, per read and per write. See "Changed items" | T3026: add the server side |
| PA-I13 | still open | `LocalAgent.zig:1139-1140` (100 ms steps), `:590` (`Child.run --version`) | File unchanged | T3027 unchanged |
| PA-I14 | fixed (incomplete) | Agent: `server.zig:226` (4 MiB), `:859`, `:865-870`, `:943-950`, `:1129-1133`. App: `connection.zig:1855-1892` (no bound) | d5f83c3d4 (via 6dc6ecb90) bounds the agent's DATA lane and catches viewers up from the ring; 2df535dc0 proves it over a real pipe. Not bounded: the app's outbound queue, the agent's control lane, and the attach, relaunch and repaint frames, which call `sendData`/`sendRepaint` without the room check (`:1709`, `:2494`). See "Changed items" | T3028: re-scope to the app side and the replay bypass |
| PA-I15 | still open (inferred) | `pty_holder_child.zig:493`; `session.zig:1034-1039` (`markExited` leaves the child installed) | Unchanged; still not measured | T3029 unchanged |
| PA-I16 | still open | `pty_child.zig:779` (`terminateFn`); `CloseHandle` only at `:194`, `:244`, `:1948`, `:1977` | File unchanged | T3030 unchanged |
| PA-I17 | changed (smaller on Windows) | `terminal/PageList.zig:40` (`page_preheat = if (exact_page_pool) 1 else 4`), `:47`; `grid_snapshot.zig:154-162`, `:119` (4 MiB cap); `session.zig:949-954` (lazy create) | 0f71734a4 (T3003) did the suggested fix for every `PageList` on Windows, and the agent's headless emulator is one. Confidence medium: I read the constant and the emulator's `Terminal.init`, not the agent's measured footprint | T3031: Windows half is done by T3003; re-measure the 3.2 MB per session before doing more. The Mac half (preheat 4) stays with T3032 |
| PA-I18 | still open | `pty_host_proto.zig:381-385` (called at `pty_host.zig:308` under `state.mutex`); `session.zig:505-510`, `:566-571` | Unchanged | folded in T3018 |
| PA-I19 | still open (inferred) | `client_mux.zig:273-296`, `agent/mux.zig:165-188` | Unchanged | folded in T3016 / T3028 |
| PA-I20 | changed (partly fixed) | attach `server.zig:1704-1709` (under the lock from `:1521`); relaunch `:2469-2476` (under the lock), send at `:2494` (after the unlock at `:2488`); FLOW resume `:2584-2614` | d5f83c3d4 turned the FLOW-resume catch-up into 64 KiB pieces limited by the queue bound. Attach and relaunch are unchanged: one allocation and one frame the size of the gap, up to 2 MB. See "Changed items" | folded in T3017 / T3019: drop FLOW resume from the text, keep attach and relaunch |

## Changed items

### PA-I05: the writer thread now takes the store lock

`catchUpBacklog` (`server.zig:2621-2630`) runs on each connection's writer
thread after a batch, whenever a bound session was refused room. It locks
`store.mutex` and walks every channel bound to the connection. Audit-2 counted
three holders of that lock on the output path (the pty reader in
`onChildOutput`, the control reader in `handleAttach` and `handleFlow`). The
writer is a fourth, and it holds the lock for as long as it takes to copy up
to 4 MiB out of the rings (PA-I21). The lock order is store then write, the
same as the live path, so this is contention, not a deadlock.

### PA-I12: the IPC server joined the per-I/O event sites

Before T3105 the server wrapped a synchronous handle (`owned = false`) and
created no events. `pipe_io.conn` (`ipc_pipe_io.zig:109-111`) now builds an
owned `Conn`, so every server read and write goes through
`Conn.overlappedIo` (`ipc_client.zig:189-195`), and `pipe_io.accept` creates
its own event (`:80-86`). One served request is: 1 accept, 2 reads (length,
body), 2 writes (length, body) and at least 1 hang-up read
(`awaitHangup`, `:123-133`), so 6 create/close pairs where there were none.

Cost (computed): 12 extra syscalls per CLI request, on a listener thread, not
the GUI thread. A few microseconds against a request that costs a process
start on the client side. Still P2; the fix is the same (one cached event per
listener).

### PA-I14: agent DATA lane bounded, the rest is not

What the fix does, read at HEAD:

- `enqueue` counts DATA payload bytes (`server.zig:859`); the writer gives
  them back only after the bytes are written (`:1129-1133`, called after
  `flushWire`).
- `bridgeData` (`:943-950`) refuses a live chunk when the queue holds more
  than `data_queue_limit` (4 MiB, `:226`, `:355`) and marks the connection
  backlogged. `onChildOutput` (`session.zig:1688-1694`) then leaves
  `sent_offset` where it is, and sends nothing live until the viewer is level.
- The writer catches the session up from its ring in 64 KiB pieces
  (`:2584-2614`) once it has written a batch (`:1057-1058`, `:1123`).

So a viewer that stops reading costs the agent at most ~4 MiB of queue per
connection plus the writer's `wire` buffer, instead of everything its panes
print.

What remains of the finding:

- **App side:** `Connection.enqueue` / `enqueueOwnedLocked`
  (`connection.zig:1855-1892`) still append with no bound. That queue carries
  input and control frames, so the volume is small, but a wedged agent still
  lets a large paste pile up.
- **Replay bypass:** attach replay (`server.zig:1709`), relaunch replay
  (`:2494`), the lost-bytes marker (`:2595`) and grid repaints go straight to
  `sendData`/`sendRepaint`, with no room check. They are counted in
  `queued_data_bytes` (`:859` counts by stream), so they can push the queue
  over the limit by up to 2 MB per attached pane. An app that re-attaches N
  panes and then stops reading leaves N x 2 MB queued. Bounded by pane count,
  not by time.
- **Control lane:** unbounded, low volume (roster, metrics).

### PA-I17: the preheat fix arrived through T3003

Audit-1's suggested fix was "preheat 1 (ties to T3003)". T3003 landed after
audit-2 and sets `page_preheat` to 1 on Windows and moves standard pages to
`ExactPool` (`PageList.zig:40-47`). The agent's `GridEmulator` builds an
ordinary `terminal.Terminal` (`grid_snapshot.zig:154`), so it gets both. The
commit measured 1.7-2.0 MB less per app pane; it did not measure the agent.
What is left of PA-I17 on Windows is the 4 MiB scrollback cap beside the 2 MB
ring (`grid_snapshot.zig:119`), which is a limit, not a commit. The 3.2 MB per
session that audit-2 attributed mostly to this should be re-measured before
T3031 does anything else.

### PA-I20: FLOW resume fixed, attach and relaunch not

- **FLOW resume:** `catchUpLocked` allocates one 64 KiB scratch (`:2600`) and
  sends pieces of at most that size while the queue has room. The single 2 MB
  allocation and frame are gone. The per-piece copies are not (PA-I21).
- **Attach:** unchanged. `alloc(want)` for the whole gap, `ring.slice` with a
  modulo per byte, one `sendData`, all under `store.mutex`
  (`:1704-1709`). The fix commit's own comment on `catch_up_chunk` (`:228-231`)
  says a single multi-megabyte frame "overran [the viewer's] inbound ring in
  one go"; attach still sends one.
- **Relaunch:** the allocation and `slice` are under the lock
  (`:2469-2476`); the send is after the unlock (`:2494`). Audit-2 listed it
  with the other two without saying the send is outside the lock.

## Fix-commit review

### d5f83c3d4 / 6dc6ecb90 (T3102) and 2df535dc0 (T3108): bounded agent queue

- **New cost found:** the backlog catch-up path, PA-I21 below.
- **Checked, negligible:** `dataQueueHasRoom` adds one uncontended
  `write_mutex` lock/unlock per live chunk (`:945`, then `enqueue` takes it
  again at `:847`).
- **Checked, no spin:** the writer wakes on `backlogged` with an empty queue
  (`:1049`). `catchUpLocked` re-arms the flag only when the queue is over the
  limit, and the writer is the only thread that releases queue bytes and has
  just released its batch, so an over-limit queue at that point is a non-empty
  queue and the next pass has frames to write. A `slice` that returns null
  ends the pass without re-arming (`:2609`).
- **Checked, no latch:** a session that falls behind returns to the live path
  as soon as one catch-up pass reaches `out_offset` (`session.zig:1688`).
- **Checked, error paths:** a failed `writeFrame` frees the payloads and
  releases their count (`server.zig`, the `catch` block in `writerLoop`), so
  the counter cannot leak upward and close the queue for good. `releaseQueued`
  saturates.
- **`acceptRetryDelayMs` (`main.zig:2173-2190`):** used only by the socket
  accept loop (`:2219-2231`). The Windows pipe accept loop (`:1838-1845`) is
  unchanged and already slept 100 ms on any error. A persistent
  `SystemResources` now retries at 10 Hz with a log line each time instead of
  ending the agent; that is the intended trade and not a hot path.
- **T3108's test** adds `data_queue_limit` as a field (`:355`); production
  value is the constant. No cost.

### e4bfd30f5 (T3105): bounded, concurrent IPC server

- **New cost found:** events per I/O on the server, recorded as the wider
  PA-I12 above, not as a new id.
- **Checked, threads:** 16 listeners instead of 4 (`IpcServer.zig:57`). They
  spawn with `thread_stack.config` (`:253`) and park in an overlapped
  `ConnectNamedPipe` wait (`ipc_pipe_io.zig:97`), so the cost is 12 idle
  threads at the ~76 KB a thread that T2985 measured, about 0.9 MB (computed),
  and no idle wakeups.
- **Checked, hang-up wait:** `finish` waits for the client to close before
  disconnecting (`:116-119`). It replaces `FlushFileBuffers`, which waited for
  the same event without a bound. The CLI closes straight after reading its
  answer (`ipc_client.zig:844`), and the wait ends on the resulting
  `BROKEN_PIPE` (`:219`), so a normal request pays one extra read, not a
  delay.
- **Checked, quit:** the shutdown loop cancels all 16 pipes every 1 ms pass
  (`IpcServer.zig:283-312`). Quit only.
- **Checked, GUI thread:** nothing new runs there. Handlers are still
  serialised through `WM_APP_IPC`.
- No leak found: the accept event is closed on every path (`:86`), and
  `serveOne` frees `body` and `response` by `defer`.

### 0f71734a4 / ede873611 (T3003, T3004): page pool

Area M's commits. Their effect here is PA-I17 above. I did not review
`page_pool.zig`.

## New findings

| Id | Pri | Finding | Suggested task |
|---|---|---|---|
| PA-I21 | P2 | While a viewer is behind, the writer thread refills up to 4 MiB from the rings under the store lock, with a modulo per byte, three copies and two allocations per 64 KiB piece | fold into T3017 / T3018 / T3019 |

### PA-I21: backlog catch-up is dearer than the live path and holds the store lock (P2)

- **Where:** `server.zig:2621-2630` (`catchUpBacklog`), `:2584-2614`
  (`catchUpLocked`: scratch alloc `:2600`, room check `:2605`, `ring.slice`
  `:2609`, `sendData` `:2611`); the refusal that starts it, `:943-950`; the
  per-chunk nudge while behind, `session.zig:1692-1693`.
- **Mechanism:** once the queue passes 4 MiB, every session on the connection
  is refused, and from then on all of their output reaches the viewer through
  catch-up, not the live path. After each batch the writer thread locks
  `store.mutex` and, for each bound session that is behind, loops until the
  session is level or the queue is full again. Per 64 KiB piece that is:
  `ring.slice` into the scratch (a 64-bit modulo per byte, PA-I04),
  `sendDataFramed` allocating a payload and copying into it (`:919-922`), and
  `enqueue` duplicating it (`:845`). The writer has just emptied the queue, so
  one pass can move the full 4 MiB while holding the lock that every session's
  pty reader needs (PA-I05). Two smaller wastes: the 64 KiB scratch is
  allocated before the room check, so a session that finds no room still pays
  an allocation and free under the lock; and each output chunk of a behind
  session takes `write_mutex` and signals the writer (`noteBacklog`,
  `:874-880`) although one flag set is enough.
- **Cost (computed):** per refill pass, up to 4 M modulo operations, 12 MiB of
  copying and about 128 allocations of 64 KiB (each a `VirtualAlloc` /
  `VirtualFree` pair under DebugAllocator, PA-I03), all inside one hold of the
  store lock. That is on the order of 10 ms or more with every session's
  output stalled, repeated once per writer batch for as long as the viewer
  stays behind. It only happens when a viewer reads slower than its panes
  print (suspended app, slow relay link, a flood); a viewer that keeps up
  never enters this path. Before the fix the same situation grew memory
  without bound, so this is the price of a correct fix, not a regression in
  the common case.
- **Fix:** build each piece straight from `ring.segments()` into a
  queue-owned payload (one copy, one allocation; the owning enqueue T3017
  already asks for); check for room before allocating; cap the bytes moved per
  lock hold (for example 256 KiB per session) and re-arm `backlogged` for the
  rest; skip `noteBacklog` when the flag is already set. T3019's per-session
  lock removes the cross-session stall.
- **Risk:** low. Order is still guaranteed by the single writer and by
  `sent_offset`; the two new tests (`server.zig`, "a full outbound queue
  holds output in the ring..." and the T3108 named-pipe test) cover gap-free
  delivery.

## Checked and found clean

- **Windows agent pipe accept:** unchanged; one event per accept, blocking
  wait (`pipe_stream.zig:400-434`).
- **IPC listeners idle:** overlapped accept with an infinite wait; no polling
  (`ipc_pipe_io.zig:79-105`).
- **`ipc_client.zig`:** the three changed hunks are comments. The client's
  overlapped path is as it was.
- **Live path when level:** one extra lock round trip per chunk, nothing else
  (`session.zig:1688-1691`, `server.zig:943-947`).
- **`termio/Remote.zig`:** not touched since audit-2.

**Not covered:** `page_pool.zig`, `termio/mailbox.zig` and `Thread.zig` (other
areas), `SessionRoster` UI code, `machine_pool.zig`, `ipc_handoff.zig`,
`ipc_timeout.zig`, the relay transport internals, `inbound_ring.zig` beyond
its call site, and the `activity_*` dialers.

## Summary

Counts over the 20 existing ids:

- **fixed:** 2 (PA-I01, already fixed at audit-2; PA-I11, new this round by
  e4bfd30f5)
- **fixed (incomplete):** 1 (PA-I14: agent DATA lane only)
- **changed:** 4 (PA-I05 wider, PA-I12 wider, PA-I17 smaller on Windows,
  PA-I20 partly fixed)
- **still open:** 13 (PA-I02, I03, I04, I06, I07, I08, I09, I10, I13, I15,
  I16, I18, I19)
- **wrong:** 0
- **new:** 1 (PA-I21, P2)

Tracker corrections this implies: T3025 (PA-I11) can close against e4bfd30f5;
T3028 (PA-I14) and T3031 (PA-I17) need re-scoping; the brief's "no fixes
landed in this area" is not what the diff shows.

Open P0/P1 in the area (no P0 remains):

- **PA-I02 (P1, T3016):** double parse and extra thread hop per inbound frame
  in the app
- **PA-I03 (P1, T3017):** DebugAllocator in release agents; two allocations
  and two copies per output chunk
- **PA-I04 (P1, T3018):** per-byte modulo in the session ring (three loops),
  plus the holder's per-byte append
- **PA-I05 (P1, T3019):** one agent-wide lock for all sessions' output, now
  also taken by each writer thread
- **PA-I06 (P1, T3020):** history file rewritten and fsynced every 30 s per
  changed session, built under the store lock
- **PA-I07 (P1, T3021):** each holder polls for shell exit at 5 Hz
- **PA-I08 (P1, T3022):** `+new-remote-window` dials on the GUI thread with no
  connect timeout
