# Audit-2, area I: IPC and the agent (T3072)

- **Date:** 2026-11-14
- **Commit audited:** 879fba35a
- **Input:** `../audit-1/I-findings.md` (PA-I01..PA-I17 as of a9eac4671) and
  the I table in `../audit-1.md`

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. Nothing
was built, run or measured this turn: every verdict is from reading the code
at HEAD, and every cost below is carried from audit-1, quoted from a fix
commit's own measurement, or computed from the code. Nothing was re-measured.

## Scope note: what moved since audit-1

`git log a9eac4671..HEAD -- src/remote src/apprt/win32/Ipc* src/os` is two
commits, and both are the stack fix:

- **90e57ab70 (T2985)** added `src/os/thread_stack.zig` and moved the app's
  long-lived spawns, including the agent link's (`connection.zig`,
  `client_mux.zig`, `IpcServer.zig`).
- **fc7f7fdfb (T3015)** moved the agent's and the holder's spawns.

Outside the spawn lines and one import per file, every file in the area is
byte-identical to audit-1 (`git diff --stat a9eac4671 HEAD`: 19 files, 190
insertions, 130 of them the new module). So PA-I02 to PA-I17 cannot have been
fixed by accident, and their lines moved by at most one. `IpcHandlers.zig`,
`LocalAgent.zig`, `tcp_dial.zig`, `pipe_stream.zig`, `ipc_client.zig`,
`foreground.zig` and `PageList.zig` did not move at all.

## Verdicts

Confidence is high (cited lines read at HEAD) unless a row says otherwise.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-I01 | fixed | `src/os/thread_stack.zig:33-36`; agent `session.zig:1725`, `handoff.zig:423`, `:699`, `single_instance.zig:1040`, `main.zig:1851`, `:2209`, `:2269`, `:2534`, `:2552`, `:2843`, `:2868`, `:2957`, `:2972`, `:3117`, `:3191`, `server.zig:663/669/675`, `:1929`, `:2526`, `:2637`, `proc_spawn.zig:89`, `adopt.zig:401`; holder `pty_host.zig:267`, `:425`, `pty_child.zig:366`, `:502`, `pty_holder_child.zig:452` | fc7f7fdfb. Every non-test `std.Thread.spawn` in `src/remote/agent` and in the three relay workers the agent imports (`relay_hosting.zig:173`, `relay_revoke_pending.zig:346`, `relay_suspend.zig:600`) passes `thread_stack.config`. No `CreateThread` or thread pool exists in the image. What still passes `.{}` is test code and the two smoke modes (`pty_host_smoke.zig:274`, `:561`, `conpty_smoke.zig`). Commit measured 167.5 -> 11.8 MB base, 19.15 -> 3.2 MB per session, holder 59.8 -> 12.25 MB | T3015 stays closed. See "PA-I01 and the T2985 seam" below |
| PA-I02 | still open | `client_mux.zig:201-221` (re-encode `:211-212`, fifo write `:217`), `connection.zig:4031-4067` (second parse); kept buffers `client_mux.zig:292-295`, `protocol.zig:2315-2318` | Unchanged. The pump parses each frame, re-encodes it into `wire`, copies it into a fifo, and the data reader copies it out and parses it again | T3016 unchanged. Add: the agent's `mux.zig:123-146` is the same shape for inbound input (low volume) |
| PA-I03 | still open | `agent/main.zig:169`; `server.zig:870-882` (`sendDataFramed`: alloc, encode, free), `:810-831` (`enqueue`: dupe) | Unchanged. `GeneralPurposeAllocator(.{})` in every build mode; two allocations and two copies per chunk before the writer's encode | T3017 unchanged; line is now `main.zig:169`. PA-I20 below adds the replay paths to its scope |
| PA-I04 | changed (wider) | `session.zig:492-495` (append), `:506-510` (`copyRetained`), `:567-571` (`slice`) | The append loop is unchanged. Two more loops in the same struct do a modulo per byte and audit-1 did not name them; see PA-I18 | T3018: name all three loops, plus the holder's (PA-I18) |
| PA-I05 | still open | `session.zig:1661-1663` (`onChildOutput` takes `self.mutex`), `server.zig:1425-1426` (`handleAttach` holds it to the end) | Unchanged. One `SessionStore.mutex` covers ring append, VT parse, bridge enqueue and the whole attach | T3019 unchanged |
| PA-I06 | still open | `session.zig:1730` (30 ticks), `:3065` (`historyAlloc` before the unlock at `:3068`), `atomic_write.zig:90`, `ring_snapshot.zig:221` | Unchanged. Precision: the ring itself is appended to a journal (delta only, `:3089`), so the full re-serialise is the `.hist` file; each changed pane costs two fsyncs per timer pass (history, journal). Volume-triggered passes skip the history (`:1813-1817`) | T3020: say "history file" and "two fsyncs", not "ring" |
| PA-I07 | still open | `pty_host.zig:328-342` (200 ms), `:355` (500 ms linger); `pty_holder_child.zig:843`, `:1177`, `:1191` (50 ms), `:606` (200 ms redial) | Unchanged. `exitPoller` is `tryWait` + `sleep(200 ms)` forever | T3021 unchanged; lines +1 |
| PA-I08 | still open | `IpcHandlers.zig:810` (TCP), `:796` (relay), comment `:767-771`; `tcp_dial.zig:180` (`tcpConnectToHost`, no timeout), `:147` (10 s HELLO) | Unchanged, same lines | T3022 unchanged |
| PA-I09 | still open | `foreground.zig:117`, called per live session from `session.zig:2282`, every 10 ticks (`:1796`); `sampleDescendants` `:1773` (1 s, one snapshot, only when a bound peer negotiated `session_busy`), vanish sweep `:1781` (5 s) | Unchanged | T3023 unchanged; lines +1 |
| PA-I10 | still open | `IpcServer.zig:393-411`; `ipc_session_await.zig:34`, `:37` (3000 ms, 15 ms) | Unchanged | T3024 unchanged |
| PA-I11 | still open | `os/ipc_client.zig:147` (sync `ReadFile` on an unowned handle), `:159` (sync `WriteFile`); `IpcServer.zig:49` (`instance_count = 4`), `:424`, `:438` (`readFull` with no bound) | Unchanged | T3025 unchanged. Add: the reply write at `:159` is equally unbounded for a client that stops reading a reply larger than the pipe buffer |
| PA-I12 | still open | `pipe_stream.zig:251-252`, `:278-279`; `os/ipc_client.zig:189-195` | Unchanged, same lines | T3026 unchanged |
| PA-I13 | still open | `LocalAgent.zig:1139-1140` (100 ms steps, 2 s deadline, pumped), `:590` (`Child.run --version`) | Unchanged. The probe is already cached per run (`:555-556`), so the remaining cost is one synchronous process spawn on the GUI thread per app start | T3027: drop "or cache" from the fix; it is cached. Worker only |
| PA-I14 | still open | `server.zig:823` (append, no bound), `connection.zig:1855-1892` | Unchanged | T3028 unchanged. PA-I19 below is the inbound mirror |
| PA-I15 | still open (inferred) | `pty_holder_child.zig:493` (reader stops at EXIT, link stays open); `pty_host.zig:410-411` (holder returns only when the owner closes), `:291-294` | Unchanged. Still not measured. `markExited` (`session.zig:1027-1032`) leaves the child installed, so the link closes only at terminate | T3029 unchanged; lines +1 |
| PA-I16 | still open | `pty_child.zig:779-850` (`terminateFn`); the only `CloseHandle` calls in the file are `:194`, `:244`, `:1948`, `:1977`, none on `self.pid` | Unchanged. Matters only for the in-process ConPTY arm; a holder exits with its handles | T3030 unchanged; lines +1 |
| PA-I17 | still open | `session.zig:944-948` (lazy create), `grid_snapshot.zig:161` (4 MiB scrollback), `terminal/PageList.zig:34` (`page_preheat = 4`) | Unchanged. T3015's measurement (3.2 MB per session with stacks gone) is consistent with audit-1's estimate that this is most of what remains | T3031: baseline is now 3.2 MB per session, of which this is the suspect |

## PA-I01 and the T2985 seam

Asked specifically: does the app-side fix leave a gap against the agent-side
one? No, with one named leftover that already has a task.

- **Agent and holder images:** complete. I listed every `Thread.spawn` under
  `src/remote` and `src/os` and read each non-test site. The agent's
  per-connection threads (`server.zig:663/669/675`), the pipe worker
  (`main.zig:1851`), the per-session holder reader
  (`pty_holder_child.zig:452`) and the holder's three threads
  (`pty_host.zig:267`, `:425`, `pty_child.zig:366`, `:502`) all use the
  shared config. The holder is the agent exe re-run, so it shares the 16 MB
  PE reserve the helper relies on.
- **App side of the link:** `connection.zig:1364`, `:1371`, `:1377`, `:1387`,
  `client_mux.zig:233` and `IpcServer.zig:269` are covered by 90e57ab70.
- **Leftover:** the app's short-lived agent-link workers still pass `.{}`:
  `LocalAgent.zig:245` (retire), `MachineConnectionPool.zig:577` (dial),
  `SessionRoster.zig:420` (fetch), `RemoteReconnect.zig:511` (dial), `:909`
  (retire). Each commits 16 MB for its lifetime, and a dial worker lives up
  to a HELLO timeout. That is T3075's list, not a new finding.
- **Not done from audit-1's fix text:** folding the four low-rate tickers
  into the reaper loop. Thread counts are unchanged by the commit. At ~76 KB
  a thread this no longer matters.
- **Regression check:** the diff of both commits is spawn config and imports
  only. Stack growth past the 64 KB commit is covered by the helper's own
  test (`thread_stack.zig:105-124`). The readers' 64 KB stack buffers
  (`server.zig:1056`, `:1100`, `pty_host.zig:407`) simply grow the commit on
  first use. No regression found.

## Changed items

### PA-I04: three loops, not one

`OutputRing.append` (`session.zig:492-495`) is as audit-1 described. The same
struct has two more per-byte modulo loops:

- `copyRetained` (`:506-510`): runs under the store lock on every ring growth
  (`growFor`, `:445`) and on every full-base snapshot rewrite (`:3053`).
- `slice` (`:567-571`): runs under the store lock for every journal append
  (`:3051`), every attach replay (`server.zig:1612`), every relaunch replay
  (`:2379`) and every FLOW-resume catch-up (`:2499`).

`segments()` (`:517-521`) already returns the two contiguous views, so all
three become two `@memcpy` calls. T3018 should name all three.

### PA-I06 and PA-I13: wording

Both are still true; the task text overstates each slightly. PA-I06 rewrites
the history file, not the ring (the ring is journalled). PA-I13's version
probe is already cached, so only "move it off the GUI thread" is left.

## New findings

| Id | Pri | Finding | Suggested task |
|---|---|---|---|
| PA-I18 | P2 | The holder's replay ring appends a byte at a time, and two more session-ring loops do a modulo per byte | fold into T3018 |
| PA-I19 | P2 | Both mux fifos are unbounded and reclaim space only when fully drained (inferred cost) | fold into T3016 / T3028 |
| PA-I20 | P2 | Attach replay and FLOW-resume catch-up copy up to 2 MB three times, through three large allocations, under the store lock | fold into T3017 / T3019 |

### PA-I18: byte-at-a-time copies beyond PA-I04 (P2)

- **Where:** `pty_host_proto.zig:381-385` (`ReplayBuffer.append`, called from
  the holder's `sinkFn` at `pty_host.zig:308` under `state.mutex`);
  `session.zig:506-510` and `:567-571` (above).
- **Mechanism:** the holder is on every session's output path, ahead of the
  agent. Its append is a per-byte store with a wrap compare (no divide). The
  writer on the other side of the same mutex already copies in two segments
  (`pty_host.zig:502-503`), so only the producer is slow.
- **Cost (computed):** one branch and store per output byte in every holder,
  under the lock its writer needs; up to 2 M divides under the agent's store
  lock per attach replay or base rewrite.
- **Fix:** two `@memcpy` segments in each.
- **Risk:** trivial; `pty_host_proto` has unit tests for the wrap cases.

### PA-I19: inbound mux fifos (P2, inferred)

- **Where:** `client_mux.zig:273-296` (app), `agent/mux.zig:165-188` (agent).
- **Mechanism:** `write` appends with no bound (`:277`). `read` advances
  `head` and resets the buffer only when `head == buf.items.len` (`:292-295`).
  There is no compaction, so while the consumer trails the pump by even one
  byte, every byte already consumed stays allocated. FLOW pause does not help:
  it is issued by the consumer (`connection.zig:3973-3978`), which is
  downstream of this fifo.
- **Cost (inferred):** none while the data reader keeps up, which it normally
  does (its work is a ring push). Under a sustained flood where it does not
  fully drain, the fifo grows with bytes streamed, not with backlog. The peak
  capacity is then kept for the connection's life (audit-1's "~8 MB kept").
- **Fix:** T3016's direct routing removes the data-lane fifo. If the fifo
  stays, compact past a threshold as `protocol.Reader.compact` does
  (`protocol.zig:2320-2330`) and cap it.
- **Risk:** low.

### PA-I20: replay copies under the store lock (P2)

- **Where:** `server.zig:1610-1613` (attach), `:2497-2500` (FLOW resume),
  `:2379` and `:2398` (relaunch); each feeds `sendDataFramed` (`:870-882`) and
  `enqueue` (`:816`).
- **Mechanism:** the replay allocates `tmp` of the whole range and fills it
  with `slice` (per-byte modulo), `sendDataFramed` allocates a second buffer
  and copies into it, `enqueue` dupes a third, and the writer encodes a
  fourth time into `wire`. Attach and FLOW resume do all but the last while
  holding `store.mutex` (`:1425-1426`, `:2447-2448`), which every other
  session's output needs (PA-I05). The range is up to the 2 MB ring and goes
  out as one frame.
- **Cost (computed):** up to ~6 MB of copying and three 2 MB allocations
  (each a `VirtualAlloc`/`VirtualFree` pair under DebugAllocator, PA-I03) per
  reattach, with all sessions' output stalled meanwhile. An app start that
  re-attaches N panes does N of these in series on one control reader. A
  flooding pane repeats it on every pause/resume cycle.
- **Fix:** frame straight from `ring.segments()` into a queue-owned buffer
  (the owning enqueue T3017 already asks for), in bounded chunks.
- **Risk:** low; ordering is already guaranteed by the single writer.

## Regressions from fix commits

None found. Both commits change only spawn configuration.

## Checked and found clean

- **Stack helper:** `thread_stack.config` is `.{}` off Windows
  (`thread_stack.zig:33-36`), so the shared agent code is unchanged on macOS.
- **Holder input path:** `PtyChild.writeFn` queues to a per-child writer and
  caps the backlog at 4 MiB (`pty_child.zig:279`, `:512-518`), so one stuck
  pane cannot block the connection's shared data reader. The queue frees
  itself after a large paste (`:572`).
- **Per-chunk reap check:** `onChildOutput` calls `tryWait` per chunk, but
  for a holder child that is two field reads under a private mutex
  (`pty_holder_child.zig:698-721`), not a syscall.
- **ACKs to the holder:** batched by size and time (`:572-591`), never per
  frame.
- **Agent writer:** swaps the whole queue out under the lock, coalesces only
  under backlog, one `writeAll` per lane run (`server.zig:974-1037`).
- **`protocol.Reader`:** lazy compaction at 64 KB; no per-frame memmove
  (`protocol.zig:2313-2331`).
- **`relay_perf` meters:** on the per-chunk path in four places, inert unless
  `GHOZTTY_PERF` is set (`relay_perf.zig:46-52`).
- **Metrics and session-CPU pumps:** exist only while a client is subscribed,
  timed condition waits, throttled under load (`server.zig:2553-2581`,
  `:2697-2731`). App subscribers are the activity monitor and the chooser.
- **Agent accept loop, adoption (30 s) and handoff (60 s) tickers:** blocking
  accept; long sleeps (`main.zig:1838-1859`, `adopt.zig:95`,
  `handoff.zig:118`).
- **`sampleDescendants`:** returns before taking a process snapshot unless a
  bound peer asked for it (`session.zig:1988-2004`).
- **`+version`:** no agent call on the GUI thread (`IpcHandlers.zig:2170`).

**Not covered:** `SessionRoster` UI code, `machine_pool.zig` beyond its
ledger, `ipc_handoff.zig`, `ipc_timeout.zig`, the relay transport internals
(`ws_client`, `relay_dial`), `inbound_ring.zig` beyond its call site, and the
`activity_*` dialers.
