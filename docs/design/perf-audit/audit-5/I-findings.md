# Audit-5, area I: IPC and the agent (T3316)

- **Area:** I, IPC and the agent (`src/remote/agent/`, the win32 IPC server,
  `src/os/ipc_client.zig`, the app's agent link, the pty holder)
- **Date:** 2026-11-28
- **This is audit-5, a re-audit of `../audit-4/I-findings.md`** (PA-I01..PA-I24;
  `../audit-1..3/I-findings.md` used only for the original descriptions)
- **Commit audited:** 5eaac0760a (audit-4 was c9af15802)
- **Input:** `../audit-4/I-findings.md`, `../audit-4.md` (the PA-id to task
  map), the task files under `docs/design/windows-parity-tasks/`

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. Nothing
was built, run or measured. Every verdict is from reading the code at HEAD and
the source diff since audit-4; every cost is quoted from a commit or task,
computed from the code, or inferred, and says which.

## Method

1. `git diff --stat c9af15802 HEAD` and `git log c9af15802..HEAD` over
   `src/remote`, `src/os`, `src/termio`, `src/apprt/ipc`,
   `src/apprt/win32/Ipc*`, `ipc_*.zig`, `LocalAgent.zig`, `SessionRoster.zig`.
2. For each PA id: its task file (status, commits), then the cited code at
   HEAD. No PA-I task closed since audit-4, so there was no fix diff to read;
   every commit that touched the area's files was read instead.
3. New findings only from lines read at HEAD.

## What moved since audit-4

**No PA-I task closed.** All 13 open area-I tasks (T3023, T3024, T3026-T3031,
T3148, T3158, T3165-T3167, T3244, T3315) are still `todo` with no commits.
The 1341 commits since audit-4 are mostly the Linux/GTK port; what reached
this area's Windows code is feature and diagnostics work:

| File | Change | Commit / task |
|---|---|---|
| `src/remote/agent/agent_log.zig` (new), `src/agent_main.zig`, `src/os/log_rotate.zig` | The agent and holders append each `info`/`warn`/`err` line to `agent.log`; the release log level is raised from `err` to `info` | 5886a92495 (T1721) |
| `src/remote/agent/viewer_grants.zig` (new), `server.zig`, `protocol.zig` | `VIEWER_OPEN` / `VIEWER_FETCH` / `VIEWER_CLOSE`: a remote viewer reads files under a granted directory, 1 MiB pieces, base64 in JSON | 2ea2f1e0f8 (T2219), e56480ccab (T2217) |
| `src/remote/agent/web_tunnel.zig` (new), `server.zig`, `protocol.zig` | `WEB_REQUEST` / `WEB_READ` / `WEB_CLOSE`: a remote page's HTTP requests are made by the agent, one worker thread per request | 42083e60bc (T2221) |
| `src/remote/agent/heap_stats.zig` (new), `main.zig`, `session.zig` | Debug agent logs live heap bytes at session create and free | 749cc744df (T3646, WIP) |
| `src/remote/connection.zig`, `src/termio/Remote.zig` | `beginRoute` / `finishRoute`: a pane's stream position is adopted only when no routed frame is in flight | 97f4cbe484 (T1999) |
| `src/remote/connection.zig` | `clearControlHandler`: the control handler slot is read under `write_mutex` and drained | 428d66dadc (T1638) |
| `src/apprt/win32/LocalAgent.zig` | `restartForUpgrade(.end)` ends live sessions over RPC before the restart | 889f8d6695, 3a7973989a (T3294, T3295) |
| `src/apprt/win32/IpcHandlers.zig` -> `ipc_list.zig`, `ipc_remote_window.zig`, `ipc_rearrange.zig`, ... ; `src/apprt/ipc/verbs.zig`, `server.zig` | Handlers split one file per verb family; verb bodies shared with the GTK app | 4094486cd1 (T1782), dd74926acc (T3334), T3361, T3374, T3375 |
| `src/remote/agent/main.zig` | ReleaseSafe agent derives the debug endpoints (T2051); Linux `SO_PEERCRED` | 7bf99408e5, 294db17edf |
| `src/remote/tcp_dial.zig` | `dialUnixTimeoutReport`; the `holder_lost` test seam | 5d9f970d1b, 4cc4c84cca |
| `src/termio/Exec.zig`, `conpty_exit_gate.zig` (new) | Child-exit notice waits for conhost's first paint | 44bd4ee636 (T3383) |

Unchanged since audit-4 (not in the diff, so audit-4's line numbers hold):
`client_mux.zig`, `pipe_stream.zig`, `relay_dial.zig`, `agent/mux.zig`,
`foreground.zig`, `proc.zig`, `pty_host.zig`, `pty_child.zig`,
`pty_holder_child.zig`, `pty_host_proto.zig`, `grid_snapshot.zig`,
`handoff.zig`, `IpcServer.zig`, `ipc_pipe_io.zig`, `ipc_remote_dial.zig`,
`terminal/PageList.zig`. `ipc_session_await.zig` changed in one import path.

Line shifts in the files that did change: `agent/session.zig` +1 to +6;
`agent/server.zig` +30 from the frame dispatch down to the proc handlers;
`agent/main.zig` +6 near the allocator, +25 lower down; `connection.zig` and
`protocol.zig` by about +100 and +400.

## Verdicts

Confidence is high (cited lines read at HEAD, mechanism traced) unless a row
says otherwise. "Unchanged" means the mechanism and the code are as audit-4
left them; only the cites moved.

| PA | Verdict | HEAD where | Evidence | Cost | Task action |
|---|---|---|---|---|---|
| PA-I01 | fixed (fc7f7fdfb, T3015), unchanged | `agent/session.zig:1860`, `agent/main.zig:1888`, `IpcServer.zig:261`, `:432`; new spawn `agent/web_tunnel.zig:152` | Every spawn still passes `thread_stack.config`, including the new web-tunnel worker | n/a | T3015 stays closed. T3075 (app `.{}` workers) still todo |
| PA-I02 | fixed (302824c05, T3016), unchanged | `client_mux.zig:159-176`, `:188-194`, `:276-278`; `connection.zig:4545` (`deliverDataFrame`), `:1327`, `:1560` (`inline_data`); callers `tcp_dial.zig:455`, `relay_dial.zig:171`, `ssh_transport.zig:718` | Still one parse per DATA frame on the pump. T1999 added three atomic operations per frame (`connection.zig:4458`, `:4517`, `Pane.beginRoute` / `finishRoute`) and a wake only when the consumer raced a publish. Negligible (computed) | n/a | T3016 stays closed |
| PA-I03 | fixed (674561478, T3017), unchanged | `agent/main.zig:172`, `:181-189`; `server.zig:889-911` (`enqueueOwned`), `:960-972` (`sendDataFramed`) | Release still on `smp_allocator`; one allocation and one copy per chunk. T3646 added `enable_memory_limit` to the Debug allocator only | n/a | closed; regression stays PA-I22 |
| PA-I04 | fixed (d02c90a1e, T3018), unchanged | `session.zig:467-495` (`append`), `:500-505`, `:550-560`, `:566-582` (`ringWrite`, `ringRead`) | Block copies | n/a | closed |
| PA-I05 | fixed (incomplete), unchanged | `session.zig:1768-1810` (`ingestOutput`: store lock `:1769`, `emu_mutex` `:1781`, bridge `:1797`, unlock `:1806`, parse `:1807`); still under the store lock: `server.zig:1645` + `:1781` (attach snapshot), `:2758-2767` (writer catch-up), `session.zig:3268` (history) | Same residue as audit-4. The attach path gained a file write under the lock: PA-I25 | computed: one 16 KiB batch parse at most per waiter | T3165, T3166, T3148 all still todo P2 |
| PA-I06 | fixed (incomplete), unchanged | `session.zig:1865` (30 ticks), `:1872` (5 min), `:1888` (`historyDue`), `:1977-1982`, `:3268` (`historyAlloc` before the unlock at `:3272`) | History still serialised under the store lock and written whole with fsync | inferred | T3166 still todo P2 |
| PA-I07 | fixed (7040bd7e8, T3021), unchanged | `pty_host.zig:365-374`, `:384-428`; `pty_holder_child.zig:845-851` | Files not in the diff | quoted (audit-4): 0.03 context switches/s | closed |
| PA-I08 | fixed (incomplete), unchanged; code moved | `ipc_remote_window.zig:111-112` (job left for the listener), `:124-158` (`runRemoteDial`, worker), `:99` -> `:206-220` (`resolveAccountToken`, still on the GUI thread); `IpcServer.zig:430-452`, `:502-505`; `tcp_dial.zig:180` (`tcpConnectToHost`, no timeout) | T1782 moved the handler out of `IpcHandlers.zig` (re-exported at `IpcHandlers.zig:80-83`) with no change in behaviour. Token renewal is still HTTP on the GUI thread near expiry; the connect still has no timeout | inferred: one renewal round trip of GUI freeze near token expiry; OS connect timeout (about 21 s) of one worker and one of 16 listeners | T3167 still todo P2. Audit-4's request to add the missing connect timeout to T3167 was not applied (no mention in the task) |
| PA-I09 | still open (as narrowed at audit-4) | `foreground.zig:111-117` (Toolhelp per live session), from `session.zig:2443` (`refreshForegroundCommands`) every 10 ticks (`:1901`, `:1954-1961`); shared walk `session.zig:2185`; `proc.zig:1346-1373`; `connection.zig:1467-1479`, `tcp_dial.zig:366-381` | Nothing moved. One Toolhelp snapshot per live session every 10 s, and the 1 s walk for a remote viewer or an older app | quoted (audit-4): 10.7M cycles per shared walk | T3023 still todo P2; its title still names the 1 s / 5 s walks that 342064c1c merged. Re-title |
| PA-I10 | still open | `IpcServer.zig:395-414` (post `:401`, sleep `:412`); `ipc_session_await.zig:34`, `:37` (3000 ms, 15 ms) | Unchanged | computed: up to 200 GUI posts per `+new-window` / `+split` | T3024 unchanged |
| PA-I11 | fixed (e4bfd30f5, T3105), unchanged | `ipc_pipe_io.zig:33`, `:109-111`, `:116-133`; `IpcServer.zig:57`, `:297`, `:469`, `:481`, `:601-602` | Files not in the diff | n/a | closed |
| PA-I12 | still open | `pipe_stream.zig:205-208`, `:254-255`, `:281-282`, `:420-421`; `os/ipc_client.zig:189-195`; `ipc_pipe_io.zig:80-86` | Unchanged: one event created and closed per pipe I/O | computed: 2 syscalls per I/O | T3026 unchanged |
| PA-I13 | still open | `LocalAgent.zig:77` (100 ms), `:1292-1293` (spawn wait loop), `:591` (`Child.run --version`) | File changed (T3294/T3295) but not these paths | computed: up to 100 ms of avoidable wait per cold start; one process spawn per upgrade check | T3027 unchanged |
| PA-I14 | fixed (incomplete), unchanged | Agent bound: `server.zig:228`, `:910-916`, `:1025-1032`. Not bounded: `connection.zig:2054-2084` (app queue); `server.zig:1830-1836` (attach replay), `:2624-2627` (relaunch replay), `:949-952` (`sendRepaint`), `:933-935` (control lane) | Same state. The control lane now also carries frames of up to about 1.4 MiB each (PA-I26), still with no bound | inferred | T3028 stays todo P2 |
| PA-I15 | still open (inferred) | `pty_host.zig:424-427`; `session.zig:1106-1111` (`markExited`) | Unchanged, still not measured | inferred: 50-65 MB per exited session until its pane closes | T3029 unchanged |
| PA-I16 | still open | `pty_child.zig:944-1015` (`terminateFn`), `:803-823` | File not in the diff; still no `CloseHandle` on `self.pid` | computed: one handle per session | T3030 unchanged |
| PA-I17 | still open (as re-scoped at audit-3) | `grid_snapshot.zig:122`, `:153-165`; `session.zig:1013-1022` (lazy create); `terminal/PageList.zig:40` | Nothing moved | quoted (baseline-4): holder 17.8 MB, confounded by PA-I22 | T3031: re-measure after T3244 (the task does not say so yet) |
| PA-I18 | fixed (d02c90a1e, T3018), unchanged | `pty_host_proto.zig:369-391` | File not in the diff | n/a | closed |
| PA-I19 | fixed (incomplete), unchanged | Client: `client_mux.zig:285`, `:364`; `protocol.zig:2825`, `:2853`, `:2916` (`retain_capacity`). Agent: `agent/mux.zig:123-146`, `:150-188` | Agent mux still re-encodes inbound frames into a fifo that resets only when drained. Confidence medium on the cost | inferred | T3158 (todo P2) is the task for the agent half |
| PA-I20 | fixed (incomplete), unchanged | attach `server.zig:1830-1836` (under the lock from `:1645`); relaunch `:2603-2608` (under the lock), enqueue `:2624-2627` (after the unlock at `:2619`) | One frame the size of the gap (up to the 2 MiB ring), allocated and copied under the store lock, no queue bound | computed: one allocation and copy of up to 2 MiB under the lock | T3165. The task text still does not name the single-frame replay |
| PA-I21 | fixed (incomplete), unchanged | `server.zig:2717-2751` (`catchUpLocked`: room check `:2736`, alloc `:2742`, slice `:2743`), `:2758-2767`; `session.zig:1800-1804` (nudge per chunk while behind); `server.zig:924-930` (`noteBacklog`) | One pass still moves up to 4 MiB under the store lock | computed: 64 allocations and block copies per pass | T3148 still todo P2; its text still cites audit-3's lines and copies |
| PA-I22 | still open | `agent/main.zig:172`, `:189` | Release agent and holders still on `smp_allocator`; T3244 not started | quoted (baseline-4): agent 9.3 -> 17.7 MB, holder 12.5 -> 17.8 MB | T3244 todo P2 |
| PA-I23 | still open | relaunch `server.zig:2616` (unlock `:2619`); first output `session.zig:979` inside `ingestOutput`'s lock (`:1769`-`:1806`); first attach `session.zig:1071` from `server.zig:1781` under `:1645`; the seed `session.zig:1045-1053` | Unchanged | computed (audit-4): up to about 100 ms per full ring | folded into T3165 (noted there 2026-11-21) |
| PA-I24 | still open | `proc.zig:1333`, `:1352-1353`, `:1378-1403`; `server.zig:233`, `:2742`; replays `:1832`, `:2605` | Unchanged. The new viewer and web paths add more allocations of this class (PA-I26) | inferred | T3315 todo P3 |

## Review of the commits that touched the area

No fix commit for a PA task landed, so this section covers the feature
commits instead.

### 5886a92495 (T1721): `agent.log`

- **Cost added:** PA-I25. Every non-debug log line on Windows opens the
  state directory and the file, appends, checks the size and closes both.
- **Checked, steady state:** no `info` or `warn` line is on the per-chunk
  output path or the 1 s reaper tick. `relay_perf`'s once-a-second line is
  opt-in (`relay_perf.zig:172`). The handoff supervisor logs once a minute
  only while a newer agent waits on legacy sessions (`handoff.zig:546`).
- **Checked, flood:** the holder's replay-gap warning is rate-limited
  (`pty_host.zig:342`).

### 2ea2f1e0f8 (T2219) and 42083e60bc (T2221): tunnelled viewers

- Agent half only. No Zig client sends these frames yet
  (`viewer_fetch` / `web_request` appear in `agent/server.zig`,
  `agent/web_tunnel.zig` and `protocol.zig` and nowhere else under `src/`),
  so on Windows today the code runs only when a Mac app views a Windows
  agent. The findings below (PA-I26, PA-I27) are therefore P3 until the
  Windows app's half lands, which the platform-symmetry rule requires.
- **Checked, bounds:** 6 requests in flight, 64 MiB of held bodies, 32 MiB
  per response, 30 s idle timeout (`protocol.zig:1908-1932`).
- **Checked, lifetime:** workers hold a reference-counted `Shared`, never the
  `Server`; `Tunnel.deinit` waits at most 1 s (`server.zig:855`).
- **Checked, idle:** `Tunnel.init` is one small allocation per connection
  (`web_tunnel.zig:93-97`); nothing runs until a request arrives.

### 749cc744df (T3646, WIP): heap counter

- **Hardening note, not a perf finding:** `freeUnlinked`
  (`session.zig:1504-1511`) calls `self.liveCount()` and `self.deadCount()`
  with no lock held. The comment calls it "a racy read of two map sizes",
  but `liveCount` (`:1288-1295`) iterates `by_id` and dereferences every
  `*Session`. A session created or freed on another thread at that moment
  can rehash the map or free a session under the iterator. The arguments are
  evaluated at the call site in every build mode; `logEvent` only returns
  early afterwards (`heap_stats.zig:36-39`). Low probability, but it is a
  use-after-free read in the shipped agent. Worth a correctness task outside
  the PA list.
- Cost: three table walks per session create or free. Negligible.

### 97f4cbe484 (T1999) and 428d66dadc (T1638): connection

- T1999: `drainRing` retries at once when the publish has already happened
  (`termio/Remote.zig:2766-2775`); each retry pops, so it cannot spin.
- T1638: two `write_mutex` round trips per control frame with a handler.
  `write_mutex` guards the queue, not the socket write. Negligible.
- No regression found.

### 889f8d6695 / 3a7973989a (T3294, T3295): restart ends sessions

- `endLiveSessions` runs sequential RPCs with a 3 s timeout each on the GUI
  thread (`LocalAgent.zig`, `end_sessions_rpc_ns`), reached only from the
  user's "Restart Ghoztty and Background Sessions" (`App.zig:13180`), which
  restarts the app straight after. The agent answers `CLOSE_SESSION` before it
  terminates the child (`server.zig:2069`). Not a finding.

### 4094486cd1 (T1782) and the shared verb bodies

- A move. `+list` still walks the window list once per request on the GUI
  thread (`ipc_list.zig:36-190`). `IpcServer.zig` is unchanged.

## New findings

| Id | Pri | Finding | Introduced by | Suggested task |
|---|---|---|---|---|
| PA-I25 | P3 | Each agent log line reopens the state directory and `agent.log`; the ATTACH line does so under the agent-wide store lock | 5886a92495 (T1721) | new P3 task |
| PA-I26 | P3 | Tunnelled viewer and web bodies go out as 1 MiB base64-in-JSON frames on the control lane of the one writer, copied four times, ahead of terminal output | 2ea2f1e0f8 (T2219), 42083e60bc (T2221) | new P3 task; raise to P2 when the Windows client half is built |
| PA-I27 | P3 | Every tunnelled web request builds a new HTTP client and thread; an https request rescans the system certificate store each time | 42083e60bc (T2221) | fold into the PA-I26 task |
| PA-I28 | P3 | The agent writer's `wire` buffer keeps the capacity of its largest batch for the life of the connection | none (old code; the client side was fixed by T3016) | new P3 task, or fold into T3244 |

### PA-I25: a file open per log line, one of them under the store lock (P3)

- **Where:** `agent/agent_log.zig:83-94` (`logFn`), `:97-142` (`writeFile`:
  `getenvW` `:104`, `makeOpenPath` `:121`, `OpenFile` `:127`, `write` `:139`,
  size check `:141`); `src/agent_main.zig:19-25` (release level `info`);
  `agent/server.zig:1858` (the ATTACH line, inside the store lock taken at
  `:1645`); also under that lock: `server.zig:1072`, `:1075`, `:1899`.
- **Mechanism:** before T1721 a ReleaseFast agent compiled out everything
  below `err`. Now `info` and above are live in release, and each line walks
  the environment block, creates or opens every component of the state path,
  opens `agent.log`, writes, queries the size and closes two handles. Every
  ATTACH logs one such line while holding the lock that all session output
  takes (PA-I05), right after building the grid snapshot under it.
- **Cost (inferred):** about ten syscalls and two file opens per line; on a
  box with a file-system filter (Defender) each open is commonly 0.1 to 1 ms.
  One line per attach, so an app start that re-attaches 20 sessions holds the
  store lock for an extra 2 to 20 ms in total. Nothing at steady state.
  Confidence medium on the per-line time.
- **Fix:** resolve the path once and keep the append handle open (the append
  access mask already makes each write atomic); reopen only after a rotation.
  Move the ATTACH line after the unlock, or build the text under the lock and
  log it after.
- **Risk:** low. Rotation by another process needs the handle reopened; a
  size check every N lines covers it.
- **Overlap:** none known.

### PA-I26: megabyte JSON frames on the shared writer (P3)

- **Where:** `agent/server.zig:3116-3160` (`handleViewerFetch`: file read,
  base64 `:3139-3147`, `sendJson` `:3148`); `agent/web_tunnel.zig:163-198`
  (`read`), `:435-484` (`workerMain`), `:77-86` (`send` -> `encodeJson`);
  `server.zig:3180-3183` (`deliverWeb` -> control lane); the writer
  `server.zig:1132-1216` (one thread, whole frames, lanes in queue order);
  `protocol.zig:1813` (`max_viewer_chunk_bytes` 1 MiB).
- **Mechanism:** each piece of a file or web body is read into a buffer (up
  to 1 MiB), base64-encoded into a second (1.37 MiB), JSON-stringified into a
  third (`protocol.zig:2564-2568`), then encoded into the writer's `wire`
  buffer as a fourth, and written with one `writeAll`. All of them are over
  `smp_allocator`'s 32 KiB class limit, so each is a map and unmap (PA-I24).
  The single writer sends that frame whole before the next terminal DATA
  frame, and the control lane has no bound (PA-I14). `handleViewerFetch`
  also does its file I/O on the control reader thread, so RESIZE, ATTACH and
  the rest wait behind a slow disk.
- **Cost (computed):** about 5 MiB of transient allocation and four passes
  over the data per 1 MiB piece. Terminal output on the same connection
  waits for 1.4 MiB to cross the link: about 1.4 s at 1 MB/s of uplink, per
  piece. A 32 MiB file is 32 such pieces. Not reached by a Windows-to-Windows
  link today (no Zig client half).
- **Fix:** send bodies as binary frames on the data lane with a small JSON
  header (the DATA framing already has an offset field), in pieces of 64 KiB
  or less so the writer can interleave pane output, and subject them to the
  data queue's bound. Read files on a worker, as the web tunnel already does.
- **Risk:** medium: a wire change, so it needs a new capability; do it before
  the client half ships on Windows and Linux.
- **Overlap:** area V owns viewer panes; the client half, when built, is
  theirs. PA-I14 and PA-I24 cover the queue bound and the allocation class.

### PA-I27: a new HTTP client per tunnelled request (P3)

- **Where:** `agent/web_tunnel.zig:152` (thread per request), `:490-492`
  (`var client: http.Client` per request), `:495` (`keep_alive = false`);
  Zig 0.15.2 `std/http/Client.zig:37`, `:1684-1691` (a fresh client rescans
  the certificate bundle on its first https connection).
- **Mechanism:** a page load is many requests. Each one spawns a thread,
  builds a client, connects, and for https loads and parses the whole system
  root store before the TLS handshake, then throws all of it away.
- **Cost (inferred):** per https request, one enumeration and parse of the
  Windows root store (a few hundred certificates, on the order of 10 ms and
  about 1 MB of transient allocation) plus a full TCP and TLS handshake. For
  plain `http://localhost` dev servers, the common case, only the thread and
  the connect. Up to 6 in flight.
- **Fix:** one `http.Client` per `Tunnel` (it is thread-safe and pools
  connections), with keep-alive on; a small fixed worker pool instead of a
  thread per request.
- **Risk:** low.

### PA-I28: the agent writer keeps its largest batch's buffer (P3)

- **Where:** `agent/server.zig:1133` (`wire`), `:1171`
  (`clearRetainingCapacity`), `:1197` (`writeFrame` appends), no shrink
  anywhere in `writerLoop` (`:1132-1216`). Feeding it: the attach replay and
  repaint (`:1830-1836`, `:1865-1866`), neither room-checked.
- **Mechanism:** the writer encodes every frame of a batch on one lane into
  `wire` before one `writeAll`, and only resets its length. One ATTACH of a
  session with a full ring and scrollback queues a replay of up to 2 MiB and
  a snapshot of up to 4 MiB (`grid_snapshot.zig:122`) in one batch; a restore
  that attaches many sessions back to back can put several in one batch. The
  capacity then stays committed until the app disconnects, which for the
  local agent is the app's whole run. T3016 gave the client's buffers a
  256 KiB retain limit (`protocol.zig:2825`); the agent's writer has none.
- **Cost (computed, upper bound):** 6 MiB or more of private memory per
  connection after one large attach; at least 4 MiB after any flood that
  fills the data queue. Typical size not measured. Confidence medium.
- **Fix:** after a flush, free `wire` when its capacity is over the same
  256 KiB limit. Better, with T3165: write large frames straight from their
  payload instead of copying them into `wire` first.
- **Risk:** trivial.
- **Overlap:** area M may count the same bytes in the agent's after-restore
  private memory; it is separate from PA-I22 (which is the allocator's own
  slabs at idle).

## Checked and found clean

- **Agent idle loop:** unchanged (`session.zig:1911-1984`): one wake a
  second, a process snapshot on one tick in five for a local-only agent.
- **IPC listeners idle:** `IpcServer.zig` and `ipc_pipe_io.zig` unchanged.
- **`ipc_client.zig`:** only the POSIX endpoint path changed.
- **`tcp_dial.zig`:** `Peer.capabilities` reads one environment variable per
  dial (`:366-367`, a test seam). Negligible.
- **`conpty_exit_gate.zig` / `Exec.zig`:** `isPaint` runs on a read only until
  the first paint is seen. The 50 ms exit poll is as before and bounded.
- **`agent/keepalive.zig`:** test timing only.
- **Viewer grants:** each fetch re-resolves the real path and reopens the
  file. That is the security rule, and at 1 MiB per fetch it is not the cost.

**Not covered:** `termio/Remote.zig` and `Exec.zig` beyond the hunks above
(area T), `src/apprt/gtk/` and the Linux-only paths (`secret_service.zig`,
`user_env.zig`, `xdg.zig`), `relay_account.zig`'s new code beyond confirming
`resolveAccountToken`'s call site, `ipc_frame_pacing.zig` (area R),
`SessionRoster` UI code, the macOS code paths of the shared agent (T3032),
and anything that needs a measurement to decide.

## Summary

Counts over the 24 existing ids:

- **fixed since audit-4:** 0
- **fixed (all rounds):** 7 (PA-I01, I02, I03, I04, I07, I11, I18)
- **fixed (incomplete):** 7 (PA-I05, I06, I08, I14, I19, I20, I21), all
  unchanged
- **still open:** 10 (PA-I09, I10, I12, I13, I15, I16, I17, I22, I23, I24)
- **changed:** 0 (PA-I09 was "changed" at audit-4; nothing moved since)
- **wrong:** 0
- **new:** 4 (PA-I25, I26, I27, I28, all P3)

Regressions from a fix commit: none new. PA-I22 (from T3017) is still open.
PA-I25 is a cost added by a non-perf commit (T1721).

Tracker corrections this implies (the first three repeat audit-4, which were
not applied):

- T3167 (PA-I08): add the missing TCP connect timeout (`tcp_dial.zig:180`);
  re-cite to `ipc_remote_window.zig`.
- T3023 (PA-I09): narrow the title to the per-session foreground walk.
- T3031 (PA-I17): re-measure after T3244.
- T3148 (PA-I21): re-cite `server.zig:2717-2767`; the copies are fixed.
- T3165: name the attach / relaunch single-frame replay (PA-I20).
- File the `freeUnlinked` unlocked table walk (T3646) as a correctness task.

Open P0/P1 in the area: none. The highest open items are P2: PA-I22
(T3244), the PA-I05 / I06 / I20 / I21 remainders (T3165, T3166, T3148),
PA-I08 remainder (T3167), PA-I09 (T3023), PA-I10 (T3024), PA-I12 (T3026),
PA-I13 (T3027), PA-I14 (T3028), PA-I15 (T3029), PA-I16 (T3030), PA-I17
(T3031), PA-I19 remainder (T3158).
