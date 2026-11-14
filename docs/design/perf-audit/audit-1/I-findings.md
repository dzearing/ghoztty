# Audit-1, area I: IPC and the agent (T2962)

- **Date:** 2026-11-14
- **Commit audited:** a9eac4671
- **Baseline:** `../baseline-1.json` (T2958), the `agent` blocks

**Produced by** three Fable 5.2 auditors (`claude-fable-5-2`, passed
explicitly) working read-only and in parallel:

1. **A: app-side IPC and the agent client.** `IpcServer`, `IpcHandlers`,
   `IpcRegistry`, `src/os/ipc_client.zig`, and the app's links to the agent
   (`LocalAgent`, `MachineConnectionPool`, `SessionRoster`,
   `RemoteReconnect`, `src/remote/client_mux.zig`, `connection.zig`,
   `pipe_stream.zig`, `inbound_ring.zig`).
2. **B: the agent's server and session core.** `server.zig`, `session.zig`,
   `main.zig`, the ring and grid snapshots, and a thread inventory checked
   against the baseline numbers.
3. **C: agent process, ConPTY and handle lifetimes.** The per-session pty
   holder (`pty_host`, `pty_child`, `pty_holder_child`), the process
   probes, the watchers and single-instance.

Areas R, W and M (`R-findings.md`, `W-findings.md`, `M-findings.md`) were
read first and are not re-reported.

**Verification.** This turn read the cited lines for every surviving claim
before filing it. Three pairs were the same defect seen by two auditors and
are merged: B1 = C-F1 (PA-I01), B4 = C-F9 (PA-I03), and A6 = C-F7
(PA-I12). B9, C-F3 and C-F4 are one cluster (PA-I09), and so are A9 and B8
(PA-I14).

## What the area does and does not explain

- **Thread stacks are almost all of the agent's memory.** Every
  `std.Thread.spawn` in the agent passes `.{}`, so each thread commits 16 MB
  (PA-W01's mechanism). Auditor B's model is 5 always-on threads, 1 per
  session, and 4 per app connection. It reproduces all three baseline numbers
  to within 0.1 MB:
  - attach: +64.4 MB measured = 4 x 16
  - per session: 19.15 MB = 16 + ~3
  - 1 session attached: 167.4 MB modelled vs 167.5 MB measured

  Private bytes 167 MB against an 18 MB working set is the same shape.
- **Most of each session's 60-76 MB "descendant" cost is ours.** Each
  session has a pty holder process (a `ghoztty-agent.exe --pty-host`
  re-exec) running 3 threads idle and 4 once typed in. That is 48 or 64 MB
  of stack, against the 59.8 and 76.3 MB measured. conhost and cmd account
  for the remaining ~12 MB (estimated, not measured per process).
- **T2985 (PA-W01) did not name the agent image**, so the agent and holder
  sites are filed separately as PA-I01. The app's own IPC threads (4
  listeners and 5 per agent connection, 144 MB of commit with persistence
  on) are T2985's, and a note there says so.
- **What stacks do not explain:** ~4 MB of agent base and ~3 MB per session.
  Most of the per-session 3 MB is the headless emulator's page preheat
  (PA-I17, estimated).
- **Idle wakeups:** source accounts for ~2.2 of the agent's 5.3/s (reaper
  1 Hz, watchers, the app's 3 s ping). The rest is unattributed and likely
  OS pool threads; PA-W05 (T2989) is the per-thread attribution tool.
  The holders add 5/s each, outside the agent's count (PA-I07).

## Findings

| Id | Pri | Finding | Task |
|---|---|---|---|
| PA-I01 | P0 | Agent and holder threads commit 16 MB stacks: ~160 of 167 MB, and 48-64 MB per session | T3015 |
| PA-I02 | P1 | Each inbound agent frame is parsed twice in the app, on an extra thread, through buffers that keep their peak size (*shared*) | T3016 |
| PA-I03 | P1 | Release agents use DebugAllocator; the output path makes two big allocations and up to four copies per chunk (*shared*) | T3017 |
| PA-I04 | P1 | The session ring appends a byte at a time with a modulo per byte (*shared*) | T3018 |
| PA-I05 | P1 | One agent-wide lock covers every session's ring append, VT parse and attach snapshot (*shared*) | T3019 |
| PA-I06 | P1 | Each changed session's whole history is re-serialised and fsynced every 30 s, under the store lock (*shared*) | T3020 |
| PA-I07 | P1 | Each holder polls for shell exit at 5 Hz forever; exit and dial waits sleep-poll at 50 ms | T3021 |
| PA-I08 | P1 | `+new-remote-window` dials on the GUI thread with no connect timeout | T3022 |
| PA-I09 | P2 | One process snapshot per session every 10 s, plus separate 1 s and 5 s walks | T3023 |
| PA-I10 | P2 | The session-bind wait posts to the GUI thread every 15 ms for up to 3 s | T3024 |
| PA-I11 | P2 | A stalled CLI client parks an IPC listener forever; four of them lock the CLI out | T3025 |
| PA-I12 | P2 | A kernel event is created and closed per pipe read and write | T3026 |
| PA-I13 | P2 | Cold agent start sleeps in 100 ms steps on the GUI thread; `--version` probe is synchronous | T3027 |
| PA-I14 | P2 | Neither side bounds its outbound frame queue (*shared*) | T3028 |
| PA-I15 | P2 | An exited shell's holder and conhost live until the pane closes (inferred) | T3029 |
| PA-I16 | P2 | The in-process ConPTY child never closes the shell's process handle | T3030 |
| PA-I17 | P2 | Each session's headless terminal preheats 4 pages beside the 2 MB ring (*shared*) | T3031 |

Each finding's full Where/Cost/Fix/Risk text is in its task's Summary. The
essentials:

### PA-I01: agent and holder stacks (P0)

- **Where:** agent `session.zig:1724`, `handoff.zig:422`, `main.zig:2971`,
  `:2956`, `single_instance.zig:1039` (always on);
  `pty_holder_child.zig:451` (per session); `main.zig:1850`,
  `server.zig:662/668/674` (per connection), `:1928` (roster pump).
  Holder `pty_host.zig:266`, `:424`, `pty_child.zig:365`, `:501`.
- **Cost (measured totals, modelled split):** ~160 of the agent's 167.5 MB;
  16 of each session's 19.15 MB in the agent; 48-64 of its 59.8-76.3 MB in
  the holder.
- **Fix:** explicit `stack_size` at each site, or T2985's helper with the
  reservation flag. Readers hold 64 KB stack buffers, and the agent's holder
  reader runs the VT parse, so size those at 512 KB-1 MB. Also fold the four
  low-rate tickers into the reaper loop.
- **Risk:** low. No wire change; running holders keep old stacks until their
  session ends.

### PA-I02: double parse on the client mux (P1, shared)

- **Where:** `client_mux.zig:209-216` re-encodes each parsed frame into a
  fifo; `connection.zig:4030-4062` parses it again. Buffers keep their peak
  size (`client_mux.zig:291-293`, `protocol.zig:2315-2317`).
- **Cost (estimated):** 3 copies, 1 parse and 1 thread hop per chunk, 1
  extra thread per connection, and ~8 MB (up to ~64 MB) held after a replay.
- **Fix:** route data-lane frames from the pump directly; shrink past a
  threshold.
- **Risk:** medium; `Connection` is shared with the Mac app.

### PA-I03: release allocator and output copies (P1, shared)

- **Where:** `agent/main.zig:168` (`GeneralPurposeAllocator`, which is
  DebugAllocator in every mode), `server.zig:870-874` and `:814`.
- **Cost (by reading):** a mutex per allocation; chunks over 16 KB become
  VirtualAlloc/VirtualFree pairs; two allocations and up to four copies per
  chunk.
- **Fix:** `smp_allocator` outside Debug; an owning enqueue.
- **Risk:** low.

### PA-I04: byte-at-a-time ring append (P1, shared)

- **Where:** `session.zig:493-496`.
- **Cost (estimated):** a 64-bit divide per output byte, under the store
  lock.
- **Fix:** two `@memcpy` segments.
- **Risk:** trivial.

### PA-I05: one lock for all sessions' output (P1, shared)

- **Where:** `session.zig:1660-1662` (`onChildOutput`), and the attach
  snapshot under the same lock.
- **Fix:** per-session lock for ring and emulator.
- **Risk:** medium (lock ordering).

### PA-I06: 30 s full-history rewrite with fsync (P1, shared)

- **Where:** `session.zig:1729` (`snapshot_every_ticks = 30`), `historyAlloc`
  in `snapshotRingsWith` before the unlock, `atomic_write.zig:90`
  (`file.sync()`).
- **Cost (estimated):** 1-3 MB plus an fsync per changed pane every 30 s.
  Five clock-showing panes is on the order of 20 GB/day of writes.
- **Fix:** rewrite on detach, stop or checkpoint, or on a long timer;
  serialise outside the lock.
- **Risk:** medium; widens the history recovery window.

### PA-I07: holder exit poll (P1)

- **Where:** `pty_host.zig:328-341` (200 ms), `:354` (500 ms linger);
  `pty_holder_child.zig:839-845`, `:1176`, `:1190` (50 ms).
- **Cost (arithmetic):** 5 wakeups/s per session; 20 panes = 100/s.
- **Fix:** wait on the process handle; `WaitNamedPipeW` for dials.
- **Risk:** low.

### PA-I08: remote dial on the GUI thread (P1)

- **Where:** `IpcHandlers.zig:810`, `:796` (comment at `:767-770` admits
  it); `tcp_dial.zig:180` (unbounded connect), `:147` (10 s HELLO).
- **Cost (estimated):** every window frozen for up to ~30 s on a black-holed
  host.
- **Fix:** dial on a worker, as `MachineConnectionPool.startDial` does.
- **Risk:** medium (reply order and error text).

### PA-I09 to PA-I17 (P2)

- **PA-I09:** `foreground.zig:117` takes a full Toolhelp snapshot per live
  session every 10 s (`session.zig:2281`, `:1737`). That is beside the 1 s
  `sampleDescendants` and 5 s vanish sweep. Fix: share one snapshot per tick.
- **PA-I10:** `IpcServer.zig:396-409` posts and sleeps 15 ms for up to 3 s,
  ~67 GUI wakeups/s. Fix: wait on a bind event.
- **PA-I11:** `ipc_client.zig:147` synchronous `ReadFile` on server
  instances, with 4 listeners (`IpcServer.zig:48`). Fix: overlapped with a
  bound.
- **PA-I12:** `pipe_stream.zig:251-252`, `:278-279` and
  `ipc_client.zig:189-195`: create and close an event per I/O. Fix: cache
  one per direction.
- **PA-I13:** `LocalAgent.zig:1140` (100 ms sleep loop) and `:590`
  (synchronous `--version`). Fix: `WaitNamedPipeW`; worker or cache.
- **PA-I14:** `server.zig:822` and `connection.zig:1863-1885`: no queue
  bound. Fix: a byte cap with gap-fill resync.
- **PA-I15 (inferred):** `pty_holder_child.zig:493` stops reading at EXIT
  but keeps the link open, so the holder (`pty_host.zig:281-293`) and
  conhost live on. Measure first, then close the stream after the final ACK.
- **PA-I16:** `pty_child.zig:778-849` `terminateFn` never closes
  `self.pid` (the process HANDLE on Windows, `:287`). Fix: `CloseHandle`
  after the reap.
- **PA-I17:** `session.zig:931-932` feeds a headless terminal with 4 MiB
  scrollback and `page_preheat = 4` (`PageList.zig:34`). Fix: preheat 1
  (ties to T3003).

## Claims that did not survive verification

- **"The holder costs a full agent image per session."** Image pages are
  shared; the private cost is stacks.
- **"One reader thread per session should become IOCP."** With PA-I01 fixed
  a blocked thread costs under 1 MB and no CPU. The agent reader also runs
  the VT parse, so IOCP adds complexity for little gain.
- **"Batch or coalesce the holder output path."** Already measured and
  rejected in-tree (T1464 and T1465, comments at `pty_host.zig:181` and
  `pty_child.zig:399`).
- **"A 2 MB ring is preallocated per session."** False since T470; it
  starts at 4 KB (`session.zig:416`) and is bounded at 2 MB.
- **"Each attached session adds threads."** The +4 threads are per
  connection; one mux connection carries all sessions.
- **"`bound_channels` leaks."** Cleared at disconnect (`server.zig:770`),
  16-byte entries, deduplicated.
- **"The debug build explains the footprint."** Release measures the same,
  with the same allocator and stacks.
- **"The 16 MiB protocol decode scratch is per reader."** Real, but only for
  cobs/base64. Every win32 dial uses `.raw`.
- **"Named-pipe instances reserve 4 x 128 KiB."** Pipe buffer sizes are
  quota hints, not committed memory.
- **"The CLI retries with a 300 ms sleep."** That is the POSIX branch;
  Windows returns earlier (`ipc_client.zig:468`).

## Checked and found clean

- IPC listeners block in `ConnectNamedPipe` with zero idle wakeups; the 4
  instances are created once. Request and response are freed on every path.
- `IpcRegistry` has `forget` and `prune`. `RemoteReconnect`'s 250 ms timer
  runs only while a dial is active. Heartbeats are one 3 s timed wait per
  connection.
- `MachineConnectionPool` drops the connection on last lease.
  `inbound_ring` is 256 KiB per pane, with overflow capped at 32 MiB and
  freed after draining.
- In the agent, `sessions.json` is change-driven, tombstones are capped at
  256, `relay_perf` is inert without `GHOZTTY_PERF`, and the writer
  coalesces only under backlog.
- Holder spawn and `terminateFn` close every handle and kill the holder if
  it ignores SHUTDOWN; the kill-on-close job takes conhost and the shell.
  `proc_spawn`, `proc_control`, `foreground` and `single_instance` close
  their handles.
- Agent timers are event-timed waits doing trivial work: heartbeat 10 s,
  watchers 5 s, keepalive 20 s (relay only). The roster pump is a pure
  condition wait.
- Attach/detach: 0 handle and 0 thread growth over three cycles, which
  agrees with the code.

**Not covered:** `SessionRoster` UI code beyond fetch and worker,
`SessionCpuProbe`, `machine_pool.zig`, `ipc_handoff.zig`,
`ipc_timeout.zig`, `runtime_agent.zig`, `remote_session.zig`, and the relay
transport internals.

## Filed as

- **PA-I01 to PA-I17** -> T3015 to T3031, in order (table above)
- **Mac seat:** T3032 validates the shared agent and client-mux fixes (PA-I02
  to I06, I14, I17) on macOS. PA-I01, I07, I12 and I16 are Windows-only code
  and owe no Mac half.
