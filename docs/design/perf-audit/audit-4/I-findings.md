# Audit-4, area I: IPC and the agent (T3151)

- **Area:** I, IPC and the agent (`src/remote/agent/`, the win32 IPC server,
  `src/os/ipc_client.zig`, the app's agent link, the pty holder)
- **Date:** 2026-11-21
- **This is audit-4, a re-audit of `../audit-3/I-findings.md`** (PA-I01..PA-I21;
  `../audit-1/I-findings.md` and `../audit-2/I-findings.md` used only for the
  original descriptions)
- **Commit audited:** c9af15802 (audit-3 was d0d874326)
- **Also read:** `../audit-4.md` (baseline-4: agent idle CPU and release memory,
  T3235)

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. Nothing
was built, run or measured. Every verdict is from reading the code at HEAD and
the source diff of each fix commit; every cost is quoted from a fix commit or
task, computed from the code, or inferred, and says which.

## Method

1. `git diff --stat d0d874326 HEAD` and `git log d0d874326..HEAD` over
   `src/remote`, `src/os`, `src/termio`, `src/apprt/win32/Ipc*`, `ipc_*.zig`,
   `LocalAgent.zig`, `SessionRoster.zig`.
2. For each PA id: the task file named in audit-3's "Task action" column
   (status, commit, progress log), then `git show <commit> -- src` for the fix,
   then the cited code at HEAD.
3. New findings only from code that moved since d0d874326, with HEAD cites
   that were read.

## What moved since audit-3

Eleven perf commits landed in the area. Seven close PA tasks; four came from
baseline-4 follow-ups (T3235, T3243, T3236, T3239).

| File | Change | Commit / task |
|---|---|---|
| `src/remote/client_mux.zig`, `connection.zig`, `protocol.zig` | `ClientMux.createConnection`: the pump hands parsed DATA frames to the connection; no re-encode, no data fifo, no data reader thread. Buffers over 256 KiB are freed once drained | 302824c05 (T3016) |
| `src/remote/agent/main.zig`, `server.zig`, `protocol.zig` | Release builds use `std.heap.smp_allocator`; `enqueueOwned`, `allocDataPayload`, `enqueueDataPayload`: one allocation and one copy per chunk, ring sliced straight into the frame | 674561478 (T3017) |
| `src/remote/agent/session.zig`, `pty_host_proto.zig` | `ringWrite` / `ringRead`: two `@memcpy` segments in `append`, `copyRetained`, `slice` and the holder's replay append | d02c90a1e (T3018) |
| `src/remote/agent/session.zig`, `server.zig`, `grid_snapshot.zig` | Per-session `emu_mutex`; the VT parse runs after the store lock is released | 29ba077ff (T3019) |
| `src/remote/agent/session.zig` | History rewritten every 5 min on the timer (`HistoryMode`), always at disconnect and checkpoint | 4a66a406e (T3020) |
| `src/remote/agent/pty_host.zig`, `pty_holder_child.zig` | Exit poller blocks on a duplicate of the shell handle; linger is a timed condition wait; `waitProcessExit` is one kernel wait | 7040bd7e8 (T3021) |
| `src/apprt/win32/IpcHandlers.zig`, `IpcServer.zig`, `ipc_remote_dial.zig` (new) | `+new-remote-window` dials on a detached worker; the listener waits, then posts the window open to the GUI thread | d8a5c59c6 (T3022) |
| `src/remote/agent/proc.zig`, `session.zig` | Parent table from one `NtQuerySystemInformation` call; the 1 s descendants sample and the 5 s vanish sweep share one snapshot | 342064c1c (T3235) |
| `src/remote/connection.zig`, `tcp_dial.zig` | A local-agent dial no longer advertises `session_busy`, so the agent does not take the 1 s snapshot for it | a3c7f7d2b (T3243) |
| `src/remote/agent/pty_child.zig`, `pty_host.zig` | ConPTY reader coalesces a flood for up to ~1 ms / 16 KiB (`termio/read_coalesce.zig`) | 95ce42d0f (T3236) |
| `src/remote/agent/pty_child.zig`, `src/os/power.zig` | `QosWatch`: a completion port on the PTY job opts each new process out of efficiency mode | a05fce2d7 (T3239) |

Not perf, read for side effects only: T1505 (test thread joins), T1506
(`DETACHED{taken}`), T1509, T3251/T3253 (handoff), T3252, T3254, T3185/T3191
(`ipc_workspaces.zig`), T1557 (`+list` machine field).

Unchanged since audit-3 (not in the diff): `agent/mux.zig`, `foreground.zig`,
`LocalAgent.zig`, `ipc_pipe_io.zig`, `ipc_session_await.zig`. `pipe_stream.zig`
gained `cancelAccept` and test guards only; `ipc_client.zig` changed in the
client's error text only.

## Verdicts

Confidence is high (cited lines read at HEAD, fix diff read, mechanism traced)
unless a row says otherwise.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-I01 | fixed (fc7f7fdfb), unchanged | `agent/session.zig:1854`, `agent/main.zig:1863`, `IpcServer.zig:261`, `:432` | Spawns still pass `thread_stack.config`, including the two new ones (the remote-dial worker and `QosWatch`, `pty_child.zig:208-236`) | T3015 stays closed. T3075 (app `.{}` workers) still todo |
| PA-I02 | fixed (302824c05, T3016) | `client_mux.zig:159-176` (`createConnection`), `:188-194` (`deliverToSink`), `:276-278`; `connection.zig:4448-4459` (`deliverDataFrame`), `:1262` (`inline_data`); callers `tcp_dial.zig:396`, `relay_dial.zig:171`, `ssh_transport.zig:652` | A bound connection gets each DATA frame as parsed, on the pump thread: no re-encode, no fifo copy, no second parse, no data reader thread. All three mux dialers use it. Control frames still take the fifo (low volume). Quoted from the commit: 106 threads instead of 107 | T3016 closed correctly |
| PA-I03 | fixed (674561478, T3017) | `agent/main.zig:170`, `:179-183`; `server.zig:865-887` (`enqueueOwned`), `:936-948` (`sendDataFramed`: one alloc, one copy) | Release agent and holders (same `main`) use `smp_allocator`; Debug keeps the leak checker. The dupe per chunk is gone. The fix brought a memory regression: PA-I22 | T3017 closed correctly; see PA-I22 / T3244 |
| PA-I04 | fixed (d02c90a1e, T3018) | `session.zig:466-494` (`append`), `:499-504`, `:549-559`, `:565-581` (`ringWrite`, `ringRead`) | All three loops are two `@memcpy` segments. `endsWith` (`:519-532`) still walks bytes, but only `suffix.len` of them with no modulo | T3018 closed correctly |
| PA-I05 | fixed (incomplete) (29ba077ff, T3019) | `session.zig:1762-1804` (`ingestOutput`: store lock `:1763`, `emu_mutex` `:1775`, bridge `:1791`, unlock `:1800`, parse `:1801`); still under the store lock: `server.zig:1615` + `:1751` (attach snapshot), `:2729-2736` (writer catch-up), `session.zig:3262` (history) | The per-chunk VT parse is off the store lock. Ring append, the bridge's allocation and copy, and the queue lock are still under it. Store-lock holders that touch an emulator (`setGeometry` `:987`, `gridSnapshotAlloc` `:1068`, `historyAlloc` `:1084`) wait for that session's parse in flight while holding the store lock, so one chunk's parse can still stall everyone (computed: at most one batch, 16 KiB). `onChildOutput` now takes the store lock twice per chunk (`:1753`, `:1755`), negligible | T3019 closed; remainder is T3165 (attach), T3166 (history), T3148 (catch-up), all todo P2. Add PA-I23 to T3165 |
| PA-I06 | fixed (incomplete) (4a66a406e, T3020) | `session.zig:1859` (30 ticks), `:1866` (5 min), `:1882-1888` (`historyDue`), `:1975`, `:3262` (`historyAlloc` before the unlock at `:3266`) | Timer passes rewrite the history at most every 5 min per session; the ring journal still lands every 30 s. A volume pass never writes it. Not fixed: the history is still serialised under the store lock, and still a whole-file write with fsync | T3020 closed; remainder is T3166 (todo P2) |
| PA-I07 | fixed (7040bd7e8, T3021) | `pty_host.zig:365-374` (`waitHandleFor`), `:384-428` (`exitPoller`: `:391` infinite wait, `:422` timed linger, `:426` owner wait); `pty_holder_child.zig:845-851`, `:607`, `:1198` | Idle holder blocks in the kernel. Quoted from the commit: 0.03 context switches a second, down from about 5. Left as a sleep-poll on purpose: `dialExisting` (`pty_holder_child.zig:1178-1186`, 50 ms, adoption only, bounded) and the accept retry (`pty_host.zig:296`, error path) | T3021 closed correctly |
| PA-I08 | fixed (incomplete) (d8a5c59c6, T3022) | `IpcHandlers.zig:814` (job left for the listener), `:826-860` (`runRemoteDial`, worker), `IpcServer.zig:430-452`, `:502-505`; `tcp_dial.zig:180` (`tcpConnectToHost`, still no timeout); `IpcHandlers.zig:801` -> `:918-932` | The TCP and relay dial no longer run on the GUI thread; the window open is posted back. Not fixed: the relay session token is still renewed over HTTP on the GUI thread when near expiry (`resolveAccountToken`), and the connect has no timeout of its own, so an unreachable host holds one detached worker and one of the 16 listeners for the OS connect timeout | T3022 closed; remainder is T3167 (todo P2). Add the missing connect timeout to T3167 or a new task |
| PA-I09 | changed (smaller) | `foreground.zig:111-117` (Toolhelp per live session), called from `session.zig:2437-2481` every 10 ticks (`:1895`, `:1948-1955`); shared walk `session.zig:2179-2187`; `proc.zig:1346-1373`; `connection.zig:1402-1414`, `tcp_dial.zig:343-357` | 342064c1c: the 1 s and 5 s walks share one snapshot, and the snapshot is one `NtQuerySystemInformation` call (quoted: 10.7M cycles against 18.7M). a3c7f7d2b: a local app no longer asks for the 1 s walk at all (quoted, Debug: reaper 17.2 -> 5.0 Mcycles/s). Still open: one Toolhelp snapshot per live session every 10 s for the foreground command, and the 1 s walk for any remote viewer or older app | T3023 stays todo: re-title to the per-session foreground walk; drop the 1 s / 5 s part |
| PA-I10 | still open | `IpcServer.zig:395-414` (post `:401`, sleep `:412`); `ipc_session_await.zig:34`, `:37` (3000 ms, 15 ms) | Function unchanged | T3024 unchanged |
| PA-I11 | fixed (e4bfd30f5, T3105), unchanged | `ipc_pipe_io.zig:33`, `:109-111`, `:116-133`; `IpcServer.zig:57`, `:297`, `:469`, `:481`, `:601-602` | Files unchanged apart from the T3022 hunk. A deferred dial holds its listener for the dial; that is 1 of 16 | T3025 stays closed |
| PA-I12 | still open | `pipe_stream.zig:205-208`, `:254`, `:281`, `:420`; `os/ipc_client.zig:189-195`; `ipc_pipe_io.zig:80-86` | Unchanged. T3236 cut the number of I/Os on the agent link in a flood (quoted: 3,726 -> 193 deliveries for 4,000 lines), so the event churn fell with it, but each I/O still creates and closes an event | T3026 unchanged |
| PA-I13 | still open | `LocalAgent.zig:1140` (100 ms steps), `:590` (`Child.run --version`) | File unchanged | T3027 unchanged |
| PA-I14 | fixed (incomplete), unchanged | Agent: `server.zig:226`, `:885`, `:891-896`, `:1001-1008`. Not bounded: `connection.zig:1973-2011` (app queue); `server.zig:1802-1804` (attach replay), `:2596` (relaunch replay), `:925-928` (`sendRepaint`), `:909-911` (control lane) | Same state as audit-3. The replay paths now call `enqueueDataPayload` directly, still with no room check | T3028 stays todo, as re-scoped at audit-3 |
| PA-I15 | still open (inferred) | `pty_host.zig:424-427` (holder waits while an owner is attached); `session.zig:1105-1110` (`markExited` leaves the child installed) | T3021 changed how the holder waits, not when it leaves. Still not measured | T3029 unchanged |
| PA-I16 | still open | `pty_child.zig:944-1015` (`terminateFn`); `tryWaitFn` `:803-823` | No `CloseHandle` on `self.pid` anywhere in the file; `Command.zig` has no `CloseHandle` at all. T3021's exit poller closes only its own duplicate (`pty_host.zig:385`) | T3030 unchanged |
| PA-I17 | still open (as re-scoped at audit-3) | `grid_snapshot.zig:122` (4 MiB cap), `:153-165`; `session.zig:1012-1021` (lazy create); `terminal/PageList.zig:40` | Nothing moved. The per-session number is now confounded by PA-I22 (holder private 12.5 -> 17.8 MB, quoted from baseline-4) | T3031: re-measure after T3244 |
| PA-I18 | fixed (d02c90a1e, T3018) | `pty_host_proto.zig:369-391` | Two `@memcpy` segments under the holder mutex | folded task closed |
| PA-I19 | fixed (incomplete) (302824c05) | Client: `client_mux.zig:285`, `:364`; `protocol.zig:2429`, `:2457`, `:2520`. Agent: `agent/mux.zig:123-146`, `:150-188` (unchanged) | Client side: the data lane bypasses the fifo, and the pump's `wire`, the fifo and the `Reader`'s two buffers give back anything over 256 KiB (the reader no longer reserves the 16 MiB frame cap). The agent's mux still re-encodes every inbound frame into an unbounded fifo that only resets when fully drained; it carries input and control, so the volume is small. Confidence medium on the cost (inferred, as before) | Fold the agent-mux remainder into T3028 |
| PA-I20 | fixed (incomplete) (674561478) | attach `server.zig:1800-1806` (under the lock from `:1615`); relaunch `:2573-2578` (under the lock), enqueue `:2594-2597` (after the unlock at `:2589`) | The scratch buffer and second copy are gone: the ring is sliced into the frame it goes out in. Attach and relaunch still build one frame the size of the gap (up to the 2 MiB ring) with the allocation and copy under the store lock, and skip the queue bound (PA-I14) | Fold the remainder into T3165 |
| PA-I21 | fixed (incomplete) (674561478, d02c90a1e) | `server.zig:2687-2721` (`catchUpLocked`: room check `:2706` before the alloc at `:2712`, `slice` `:2713`), `:2728-2737`; `session.zig:1794-1796` (nudge per chunk while behind) | Per 64 KiB piece: one allocation and one block copy, where audit-3 counted two allocations, three copies and a modulo per byte; the allocation now follows the room check. Still open: one pass moves up to 4 MiB under the store lock, and each chunk of a behind session takes `write_mutex` to set a flag that is already set (`noteBacklog`, `:900-906`). Each 64 KiB + 8 payload is above `smp_allocator`'s largest class (PA-I24) | T3148 stays todo: re-cite, drop the copies from its text |

## Fix-commit review

### 302824c05 (T3016): parsed DATA straight to the pane

- **Checked, no stall:** `deliverDataFrame` runs on the pump thread under
  `sink_mutex`. `routeInboundData` (`connection.zig:4321-4397`) takes
  `panes_mutex` briefly, pushes to the ring without blocking and at most
  enqueues a FLOW frame. Control frames queue behind it exactly as they did
  behind the fifo write.
- **Checked, teardown:** every close unbinds the sink before the idempotence
  gate, so no delivery can run into a destroyed connection.
- **Cost added:** one uncontended lock per DATA frame. Negligible.
- No regression found.

### 674561478 (T3017): `smp_allocator`, owned payloads

- **Regression (quoted):** release agent base memory 9.3 -> 17.7 MB and
  holder 12.5 -> 17.8 MB per session. Recorded as PA-I22; T3244 is open.
- **Checked, ownership:** `enqueueOwned` frees on the closed and error paths;
  `enqueueDataPayload` frees on a failed shrink; the writer frees after emit
  and on a failed `writeFrame` (`server.zig:1173-1183`).
- **Checked, cross-thread free:** payloads are allocated on a reader thread
  and freed on the writer thread. `SmpAllocator` puts a free on the freeing
  thread's slot and an allocating thread that runs dry moves to the next slot
  before mapping a new 64 KiB slab (Zig 0.15.2 `SmpAllocator.zig:55`,
  `:143-154`), so the pair converge on one slot. Bounded growth, not a leak,
  and a likely part of PA-I22 (inferred).
- The commit's own measurement: a 64 MB flood cost the agent the same CPU
  before and after. The allocator was not where the time went; T3236 found it.

### d02c90a1e (T3018): block copies

- Model tests compare against the byte loop at every wrap point. No
  regression found.

### 29ba077ff (T3019): per-session parse lock

- **Checked, order:** `emu_mutex` is taken before the store lock is released
  (`session.zig:1775`, `:1800`), so the emulator is fed in ring order.
- **Checked, no cross-session wait:** only a session's own reader holds its
  `emu_mutex` without the store lock, so a reader never waits on it while
  holding the store lock.
- **Residual:** store-lock holders that need a busy session's emulator wait
  out its parse in flight (see PA-I05). Restore paths still parse under the
  store lock: PA-I23.
- T3168 (pane-ingest-ab red after this commit) was closed as not reproducing;
  the cause turned out to be efficiency mode (T3239).

### 4a66a406e (T3020): history every 5 minutes

- The restore splice (older history plus the ring bytes after it) runs at
  restore only. No hot-path cost. No regression found.

### 7040bd7e8 (T3021): event-driven exit poller

- **Hardening note, not a finding:** `exitPoller` (`pty_host.zig:387-405`)
  has no back-off if the handle is signalled but `tryWait` returns null
  (`GetExitCodeProcess` failing, `pty_child.zig:817-818`). That turn would
  spin. I found no way to reach it in normal operation.
- No regression found.

### d8a5c59c6 (T3022): dial off the GUI thread

- **Checked:** while a dial is in flight the listener wakes every 100 ms to
  notice a quit (`IpcServer.zig:419`, `:441-445`). Ten wakeups a second for
  the length of a dial only.
- **Checked, lifetime:** the job is reference counted (worker + listener); a
  quit mid-dial leaves the worker to free it.
- No regression found; the remainder is in PA-I08.

### 342064c1c (T3235) and a3c7f7d2b (T3243): idle CPU

- T3235 is closed with 342064c1c. Its CPU half is done (quoted: about 45%
  off, then two-thirds more with T3243). Its memory half moved to T3244,
  which is open: see PA-I22.
- **Checked, skew:** an older app still advertises `session_busy`, and a
  remote viewer always does, so those agents still walk once a second, now at
  the cheaper rate.
- **Cost left:** each walk allocates a table buffer of about 0.5 MB and builds
  a new map (PA-I24).

### 95ce42d0f (T3236): flood coalescing at the ConPTY read

- **Checked, echo latency:** `shouldWait` holds a read back only when the
  blocking read returned in under 2 ms (`read_coalesce.zig`), and the wait is
  capped at 1 ms. A keystroke echo after a pause is not delayed.
- **Checked, idle:** two `Instant.now` calls per read; the timer is created
  once per reader (`pty_child.zig:494-502`).
- **Checked, ring safety:** the holder caps a batch at a sixteenth of its
  replay ring (`pty_host.zig:273`).
- Quoted: agent family CPU over a 64 MB flood 3.0 -> 2.1 s (ReleaseFast).
- No regression found.

### a05fce2d7 (T3239): efficiency-mode opt-out

- **Cost added (computed):** one parked thread per process that owns a PTY
  job (each holder), and per process started in a pane one completion packet,
  `OpenProcess`, `SetProcessInformation` and `CloseHandle`
  (`pty_child.zig:239-261`). Four syscalls and a thread wake against a process
  start. Negligible, including for a build that starts thousands.
- Nothing at idle: the thread blocks in `GetQueuedCompletionStatus`.
- No regression found.

## New findings

| Id | Pri | Finding | Suggested task |
|---|---|---|---|
| PA-I22 | P2 | Release agent base memory doubled (9.3 -> 17.7 MB) and each holder grew 12.5 -> 17.8 MB when release builds moved to `smp_allocator` (regression from T3017's fix) | T3244 exists (todo, P2); keep, link to PA-I22 |
| PA-I23 | P3 | Restore paths still run a ring-sized VT parse under the agent-wide store lock: relaunch replay, and the first output or first attach of an adopted session | fold into T3165 |
| PA-I24 | P3 | Allocations over 32 KiB bypass `smp_allocator`'s classes and map/unmap pages every time: the process-table buffer per walk and every 64 KiB catch-up piece | new P3 task, or fold into T3023 / T3148 |

### PA-I22: `smp_allocator` doubled the release agent's memory (P2)

- **Where:** `agent/main.zig:170`, `:183` (the switch); every allocation in
  the agent and in each `--pty-host` holder goes through it.
- **Mechanism:** `SmpAllocator` keeps a freelist and a bump pointer per size
  class per thread slot and maps memory a 64 KiB slab at a time, 13 classes
  up to 32 KiB (Zig 0.15.2 `SmpAllocator.zig:50-55`). It never returns a slab.
  A process with many threads that each touch a few classes holds a slab per
  class per slot it used. The agent's reader allocates and its writer frees
  (PA-I03's fix), which spreads slabs over more slots before the two converge.
  Which of these carries most of the 8 MB is not known (inferred).
- **Cost (quoted, baseline-4, `../audit-4.md:42-43`):** agent base private
  9.3 -> 17.7 MB; per-session holder 12.5 -> 17.8 MB. Release only (Debug
  9.8 MB). With 20 sessions that is about 8 + 20 x 5 = 108 MB more than
  before the fix (computed from the quoted figures).
- **Fix:** T3244's plan: measure the retained caches, then choose per process.
  The holder is a three-thread relay with one large ring; it gained nothing
  measurable from the fast allocator (T3017 measured no CPU change) and is
  the larger total, so it is the first candidate to move back to a plain
  heap or the page allocator plus a small arena.
- **Risk:** low; the allocator is one line per process.

### PA-I23: ring-sized parses under the store lock on restore (P3)

- **Where:**
  - relaunch: `server.zig:2586` (`rs.feedEmulator` over the whole replay),
    unlock at `:2589`;
  - first output of a session with a restored ring: `session.zig:978`
    (`seedEmulatorFromRing` inside `appendOutputLocked`), reached from
    `ingestOutput` between the lock at `:1763` and the unlock at `:1800`;
  - first attach of such a session: `session.zig:1070`
    (`gridSnapshotAlloc`), called at `server.zig:1751` under the lock from
    `:1615`. The seed itself is `session.zig:1044-1052`.
- **Mechanism:** T3019 moved the per-chunk parse off the store lock. These
  three sites parse a whole ring (up to 2 MiB) in one call and still hold the
  store lock for it, so every other session's output waits. They run once
  per session per restore, but a reboot or an agent upgrade restores every
  session in the same few seconds, so the stalls line up end to end.
- **Cost (computed, upper bound):** T3236 quotes 2.1-3.0 s of agent-family
  CPU for a 64 MB flood in ReleaseFast, relay included, so a parse runs at
  20 MB/s or better and a full 2 MiB ring takes up to about 100 ms. Twenty
  restored sessions with full rings is up to about 2 s of the store lock held
  in pieces during a restore. Debug builds are far slower (T3108 quoted
  about 120 KB/s) but are not what ships.
- **Fix:** the shape T3165 already describes for the attach snapshot: do the
  work under `emu_mutex` alone. For the seed, take `emu_mutex` hand over
  hand and release the store lock before feeding, as `ingestOutput` does for
  a chunk; for relaunch, feed after the unlock at `:2589` under `emu_mutex`.
- **Risk:** medium, the same lock-order care as T3019.

### PA-I24: large allocations map and unmap pages every time (P3)

- **Where:** `proc.zig:1333` (512 KiB hint), `:1352-1353` (alloc and free per
  snapshot), `:1378-1403` (a new `ParentMap` per snapshot);
  `server.zig:231` (`catch_up_chunk` 64 KiB), `:2712` (one payload per
  piece); the attach and relaunch replays (`:1802`, `:2575`).
- **Mechanism:** `smp_allocator` serves only sizes up to 32 KiB from its
  classes; anything larger is a `VirtualAlloc` and a `VirtualFree` per call
  (Zig 0.15.2 `SmpAllocator.zig:123`, `:205`). The process-table buffer is
  about 0.5 MB and is allocated, filled by the kernel and freed on every
  walk, so its pages fault in fresh each time. A catch-up payload is
  64 KiB + 8, just over the limit. A live chunk (at most 16 KiB + 8 after
  T3236) fits the 32 KiB class and is not affected.
- **Cost (inferred):** per walk, one map/unmap pair and on the order of 100
  page faults, once every 5 s on a local-only agent and once a second with a
  remote viewer or an older app. Small beside the query itself (quoted
  10.7M cycles). Per backlog refill, 64 map/unmap pairs under the store lock
  (PA-I21). Under DebugAllocator the same sizes also went to the page
  allocator, so this is a remaining cost, not a regression.
- **Fix:** keep the snapshot buffer (and the map, cleared with capacity
  retained) on the `SessionStore` between walks; make `catch_up_chunk`
  32 KiB - 8, or reuse freed payloads on the writer.
- **Risk:** trivial.

## Checked and found clean

- **Agent idle loop:** the reaper wakes once a second (`session.zig:1905-1978`).
  With a local viewer it now takes no process snapshot on four ticks of five.
  `reapExited` is one zero-timeout wait per live session under the store lock.
- **Handoff supervisor:** one tick a minute (`handoff.zig:118`, `:519-524`);
  T3251 added a module-name read per tick. Negligible.
- **IPC listeners idle:** unchanged, overlapped accept with an infinite wait.
- **`ipc_workspaces.zig`, `+list` machine field:** GUI-thread handlers that
  walk the window list once per request. Nothing blocking.
- **`inbound_ring.zig`:** one atomic flag added (T1506).
- **Coalescer and local panes:** the agent reader shares the local reader's
  policy file, so the two cannot drift.

**Not covered:** `termio/Remote.zig` and `Exec.zig` beyond their call into
`read_coalesce` (area T), `page_pool.zig`, `SessionRoster` UI code,
`machine_pool.zig`, the relay transport internals, `link_control.zig`'s
internals, the macOS code paths of the shared agent (T3032), and anything
that needs a measurement to decide.

## Summary

Counts over the 21 existing ids:

- **fixed (all rounds):** 7 (PA-I01, I11 from earlier rounds; PA-I02, I03,
  I04, I07, I18 new this round)
- **fixed (incomplete):** 7 (PA-I05, I06, I08, I19, I20, I21 new this round;
  PA-I14 unchanged)
- **changed:** 1 (PA-I09, smaller)
- **still open:** 6 (PA-I10, I12, I13, I15, I16, I17)
- **wrong:** 0
- **new:** 3 (PA-I22 P2, PA-I23 P3, PA-I24 P3)

Fix commits that brought a regression: one. 674561478 (T3017) doubled the
release agent's and holders' memory (PA-I22, tracked by T3244). No other fix
commit regressed anything I could find by reading.

Baseline-4's two agent rows: the idle-CPU row is answered by 342064c1c and
a3c7f7d2b (T3235 closed, T3243 closed); the memory rows are not answered yet
(T3244 todo).

Tracker corrections this implies:

- T3023 (PA-I09): narrow to the per-session foreground-command walk.
- T3148 (PA-I21): re-cite `server.zig:2687-2737`; the copies are fixed, the
  4 MiB lock hold is not.
- T3165: add the relaunch feed and the two `seedEmulatorFromRing` sites
  (PA-I23), and the attach / relaunch single-frame replay (PA-I20).
- T3167 (PA-I08): add the missing TCP connect timeout.
- T3028 (PA-I14): add the agent mux fifo (PA-I19 remainder).
- T3031 (PA-I17): re-measure after T3244.

Open P0/P1 in the area: none. Every P1 from audit-3 (PA-I02 to PA-I08) is
fixed or fixed with a P2 remainder on file. The highest open items are P2:
PA-I22 (memory, T3244), PA-I05 / I06 / I20 / I21 remainders (T3165, T3166,
T3148), PA-I08 remainder (T3167), PA-I09 (T3023), PA-I10, I12, I13, I14,
I15, I16, I17.
