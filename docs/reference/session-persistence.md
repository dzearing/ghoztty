# Session persistence

Terminal processes owned by `ghoztty-agent` so they outlive the app. Read before
touching `LocalAgentManager`, `termio/Remote.zig`, anything under `src/agent/` /
`src/remote/`, the session-layout manifest, restore/relaunch, or the app↔agent
protocol. Design and measured E2E results: `docs/design/session-persistence.md`.

Terminal processes can be made independent of the GUI app so they survive app
crashes, quits, and binary upgrades (and relaunch across reboots / agent
crashes). It is **on by default** (disable with `session-persistence = false`).

- `session-persistence = true|false` (macOS, default `true`). When `true`, new local
  windows/tabs/splits run their shell under the local `ghoztty-agent` (found or
  spawned on demand) instead of directly under the app process, so the child
  processes outlive the app. On next launch the app re-attaches: layout, split
  ratios, titles, working dirs, and gap-filled scrollback come back with the
  **same PIDs** (no restart) as long as the agent stayed alive.
- `session-relaunch = restore|rerun|prompt` (default `restore`). Only matters
  across an **agent** restart (reboot / agent upgrade), where the child is gone
  but its metadata was materialized from disk as a relaunchable tombstone.
  - `restore` (default): the pane comes back as a **plain login shell in the
    session's recorded working directory**, under a
    `--- previous session was lost; new shell in its working directory ---`
    notice. The recorded command is **not** re-run. This is what makes a reboot
    safe to do: a `/wt` window opened with `--command="cl …"` used to come back
    by starting a brand-new Claude Code session, silently, in every pane.
  - `rerun`: re-execute the recorded command in place with a
    `--- session restarted ---` divider — the old `auto`, kept as an explicit
    opt-in for panes whose command is cheap and idempotent.
  - `prompt`: leave the pane in its exited state for the user to decide; the
    consenting keystroke does a `rerun`.

  The policy lives entirely client-side. `RELAUNCH` carries no argv, but the
  agent's synthesized relaunch OPEN already drops the *recorded* command
  whenever the viewer supplies `Relaunch.argv` — so `restore` just sends a
  `<shell> -li` argv and the agent's own recorded `cwd` does the rest. No wire
  change; an agent too old to honor those fields degrades to `rerun`.

  **The recorded cwd is the shell's LIVE cwd.** `handleOpen` records `OPEN.cwd`
  at spawn, and every agent checkpoint (`SessionStore.checkpoint`: the 30 s
  reaper tick, a viewer disconnecting, the agent's SIGTERM at logout) then
  re-samples each live child's actual cwd from the OS (`refreshCwds`) and
  rewrites `sessions.json` when it moved — so a shell that `cd`'d comes back
  where it was, not where it started. A pane opened with no directory at all
  (a GUI window with no parent pane to inherit from) is handed the app's own
  default — the configured `working-directory`, else the app's cwd — instead of
  inheriting the agent's, which for a launchd-started agent is `/`.
  (`ghoztty +new-window` run from a shell already sends the caller's cwd, and
  splits and tabs inherit their parent pane's.)

  **What a reboot replays is the session's HISTORY, not its raw bytes.** Each
  session's agent-side emulator (`agent/grid_snapshot.zig`) keeps bounded
  scrollback, and every checkpoint writes it next to the raw ring as a `.hist`
  file: content-only VT (text, SGR, hyperlinks, soft wraps left unwrapped so the
  pane re-wraps them), no modes, no cursor addressing, no queries. After an agent
  restart that history is what gets preloaded and replayed — a pane that was on
  the alternate screen comes back as its primary-screen scrollback followed by
  the TUI's last frame, on the PRIMARY screen, with the fresh shell below it. A
  ring written by an agent that predates `.hist` is converted the same way at
  load (`historyFromRaw`). The raw ring was the wrong thing to replay: it starts
  mid-sequence, is mostly a TUI's in-place redraws (2 MB of Claude Code is ~700
  frames of spinner), and carries every query (`CSI c`, `CSI ? 2026 $ p`, …) the
  terminal then answered into the NEW shell's stdin, plus mouse/kitty-keyboard/
  synchronized-output state, plus cursor motion that only lands at the original
  geometry. Snapshot files whose session is gone are swept at agent start.

  **The replay reaches the pane whole.** A viewer's inbound ring is 256 KiB; a
  reboot replay is ONE DATA frame of up to the agent ring's size. Bytes that do
  not fit now go to a per-channel overflow (`inbound_ring.Channel.overflow`)
  instead of being dropped — they used to be, which cut every restored history
  to its first 256 KiB and lost the notice and the new shell's prompt behind it
  (the "unresponsive" restored pane). And `FLOW{resume}` now sends what the
  session printed while paused (`Server.catchUpLocked`); it used to be recorded
  and never delivered.

  **Restoring scrollback can still restore VT modes** — from an older agent's
  raw replay, or from the app's own quit-time snapshot of a pane whose child has
  since been relaunched. `termio/Remote.zig`'s `replay_mode_reset` undoes them:
  mouse tracking above all (a dead TUI's `ESC[?1003h` makes a plain zsh read
  pointer motion as typed input — `zsh: command not found: 30M35`), plus
  bracketed paste, focus reporting, cursor keys/keypad, the kitty keyboard flag
  stack and modifyOtherKeys (Claude Code pushes both; left on, Ctrl-C reaches the
  shell as `CSI 99;5u`), synchronized output, autowrap, cursor visibility, and
  SGR. It is **mode state only** — no `RIS`, and deliberately no alt-screen /
  origin / scroll-region reset, because ghostty applies those unconditionally
  (cursor restore, erase, home) and they would land the fresh prompt on top of
  the restored output; a history replay never leaves any of them set. It is
  **not** applied on the ordinary alive re-attach: there the child still runs and
  still owns those modes.

  **The notice and the reset travel in the stream, not as a local print**
  (`RELAUNCH.notice`, gated on the `relaunch_notice` HELLO capability). The
  agent appends them to the ring before replaying, so they land after the
  scrollback + divider and before the respawned child's first byte — the same
  slot the divider occupies. A client-side inject does not survive: it reaches
  the terminal after the fresh shell owns the screen, and the shell's first
  prompt repaint blanks the line (measured — the agent-baked divider one row up
  survives while the client's line goes blank, which is what pinned the cause).
  Putting the reset there too removes a second hazard: injected locally it could
  land *after* a `rerun` TUI armed its own mouse tracking and switch it back off.
  Against an agent too old to advertise the capability the client falls back to
  printing both itself — visible, just repaintable.

- `claude-code-fullscreen = true|false` (macOS, default `true`). Sets
  `CLAUDE_CODE_NO_FLICKER=1` in local and session-persistence panes so Claude
  Code uses its **fullscreen renderer**, which keeps the conversation itself and
  re-wraps ALL of it on a resize. Its classic renderer writes the conversation
  into the terminal's scrollback pre-laid-out with cursor moves — no soft wraps
  for the terminal to reflow — so after a resize everything above the last
  screen stays at the old width, and nothing on our side can fix that.
  **An explicit choice always wins**: the variable already in the environment,
  a `tui` key in Claude's settings (`$CLAUDE_CONFIG_DIR/settings.json`, else
  `~/.claude/settings.json` — what `/tui default|fullscreen` writes; Claude gives
  the variable precedence over that setting, so injecting it blindly would
  override the user), or `env = CLAUDE_CODE_NO_FLICKER=…` in the config, applied
  last. **Never applied to cross-machine panes** — Claude itself turns the
  renderer off where it renders poorly (Windows over a remote connection).
  Trade-off: the conversation lives inside Claude, not in scrollback, so a
  reboot restores Claude's last screen and `claude --resume` brings back the
  rest. Code: `claudeFullscreenWanted` (`src/Surface.zig`).

Session lifecycle: a process DIES when the user closes its pane/tab/window (or
`+close`s it — the CLOSE lands when the close's undo window expires), when the
shell itself exits, or when the agent dies (children then relaunch as
tombstones per `session-relaunch`). It SURVIVES app quit/crash/upgrade (quit
never prompts for persistent windows — their sessions re-attach on relaunch).
E2E: `scripts/e2e/session-persistence.py` (incl. `--winsize` for re-attach
PTY-geometry integrity, and `--reboot-tui` for a reboot of panes running a
Claude-Code-shaped TUI).

Properties every agent-backed pane relies on, each of which used to fail under
real Claude Code output:

- **A pane is only ever sized to its REAL geometry.** A surface is built at a
  placeholder (800×600 px = 49×17 cells) and its IO thread starts before the
  view is laid out; OPEN/ATTACH used to carry the placeholder, so every app
  restart resized each live program to 49×17 and back (Claude Code re-rendered
  at 49 columns into the scrollback, then again at full width). Bring-up now
  waits, bounded, for the first real size (`Remote.awaitRealSize`, signalled by
  `Termio.size_reported`) and sizes its own grid to it before painting anything.
- **One pane cannot freeze the others' input.** Input is written to each pty by
  that child's own writer thread (`PtyChild.writerLoop`, POSIX). The write used
  to happen on the connection's single data-reader thread, so one program not
  reading its terminal blocked typing in every pane.
- **A re-attach resumes exactly where the viewer left off.** The offset a
  viewer persists for its next re-attach is a count of bytes it applied, and the
  agent's re-attach reply includes synthetic bytes (the visible-screen repaint,
  a scrollback-lost marker) that occupy no stream offsets. Counted anyway, every
  restart pushed the offset one repaint further until it passed the agent's head,
  and the next re-attach discarded the child's real output until the stream
  caught up — an idle pane froze after an app restart (the unmodified 1.37 build
  freezes all three panes of a 3-pane test by the 3rd restart). `ATTACHED` now
  carries `replay_len` (additive) and the viewer anchors its count on it
  (`Remote.anchorAppliedOffset`); against an older agent the discard watermark is
  clamped to the agent's head so a bad offset can never freeze a pane.
- **Restored scrollback stays reflowable.** The app's quit-time snapshot and the
  agent's re-attach repaint serialize soft-wrapped rows as continuations
  (`unwrap = true`), not rows ending in CRLF — otherwise every app restart froze
  the restored lines at the old width, and widening the pane later left them
  broken where the old width broke them. They also carry the rows'
  shell-integration prompt marks (`formatter.Options.semantic_prompts`, OSC 133
  `P`/`I` only — never `A`/`C`/`D`, which move the cursor or signal commands):
  on a resize with the cursor at a prompt the terminal blanks from the current
  prompt's first row down for the shell to redraw, and an unmarked restored
  prompt sent that walk up to an older one, blanking the restored output in
  between. E2E: `--restore-resize`.

  Not ours and not restore-specific: a prompt LONGER than the pane wraps, and
  zsh redraws it on a resize by moving up the row count it had at the old
  width — after widening that overwrites the end of the last output line. Same
  with no restart at all.
- **A burst of output cannot stall the pane.** The remote backend parses output
  on the IO thread that also drains its own 64-slot mailbox, and a parse emits a
  message per query reply and per synchronized-output frame; `drainRing` now
  yields as soon as that mailbox is half full (`Mailbox.underPressure`) instead
  of overflowing it — each overflowing message cost a 50 ms wait and a drop,
  minutes of a frozen pane for one 2 MB replay.
- **A child that exits is always seen to exit.** The agent's only reap check
  used to be the pty reader's EOF nudge, and EOF is no proof of exit: the
  kernel closes the child's slave fds part-way through exit, before `waitpid`
  can collect it, so the nudge usually found it "still running" and was never
  repeated. The session stayed `alive` over a zombie, and the pane showed its
  last output, took no input (`pty input write failed: error.InputOutput` in
  `agent.log`), and never said "process exited". Any shell exit could leave a
  pane like that, e.g. Claude Code's `claude …; exec zsh -li` after the zsh
  ends. The reader now waits (bounded) for the exit to land before nudging,
  and the reaper tick sweeps every alive session (`SessionStore.reapExited`),
  which also catches a child that closed its terminal and exited later.
  Tests: `the EOF nudge finds the exited child reapable`,
  `SessionStore.reapExited`.

The agent owns the PTYs, keeps a per-session output ring (2 MB default;
snapshotted to disk — with the session's history — for reboot scrollback),
persists session metadata to
`sessions.json`, and is packaged as a per-user LaunchAgent so it comes back
after a crash/reboot. The app dials it over a 0600 AF_UNIX socket
(`~/.config/ghoztty/local-agent[-debug]/agent.sock`) with a same-uid peercred
check. Use `+sessions` (above) to enumerate live sessions directly from the
agent, even when the app is not running. Design + measured E2E results:
`docs/design/session-persistence.md`; E2E harness: `scripts/e2e/session-persistence.py`.

Cross-machine session *move* (browse another machine's live sessions from the
Cmd-Shift-N chooser and resume them locally over the relay) is **scoped but not
yet built** — see tasks T16–T18 in `docs/design/session-persistence-tasks.json`.

## The agent's accept loop does not exit on a passing error

`acceptLoop` (`src/remote/agent/main.zig`) ends the process if it returns, and
every session with it. It retries at once on a connection that died in the
backlog, and after 100 ms on running out of file descriptors or kernel memory
(`acceptRetryDelayMs`); only an error that says the socket is no longer a
listening socket ends it. The agent does not raise its own descriptor limit:
child shells would inherit it.

## A restored screen leaves the cursor where the program left it

Both restore paints — the app's own snapshot (`Surface.formatSessionSnapshot`)
and the agent's repaint (`GridEmulator.snapshotAlloc`) — are
`terminal.formatter.TerminalFormatter` output: the screen, the cursor
position, then terminal state. Two pieces of that state move the cursor when
replayed: DECSTBM/DECSLRM home it, and each tabstop is set by moving to its
column. `formatTrailingExtras` puts the cursor back afterwards whenever the
cursor is part of what is restored.

Before this a re-attached pane's cursor sat at the last tabstop (the right
row, column 113 of 116), so whatever the program printed next started there
until it sent a carriage return; the following snapshot recorded that as a
row of spaces soft-wrapped onto the text, and the restore after that
duplicated a line. Caught by the E2E's `--quit=graceful` mode from the second
cycle on. Test: `Terminal vt restores the cursor after tabstops and a
scrolling region` (`formatter.zig`).

## An agent-backed pane cannot stall on its own mailbox

The remote backend parses output on the IO thread (`termio/Remote.zig`
`drainRing`), and that thread also drains the termio mailbox. The parse sends
to it: a reply to every query, a timer for every synchronized-output start.
Local panes are immune — their read thread parses while the IO thread drains.

- `drainRing` works in 1 KiB slices and yields when the mailbox is half full
  (`Mailbox.underPressure`), so a long replay cannot fill it between slices.
- **Within one slice the IO thread can no longer fill it either.** The
  thread that drains a mailbox `claim`s it; what that thread sends to itself
  once the 64-slot queue is full goes on an overflow list (`mailbox.zig`
  `Overflow`) instead of waiting 50 ms for a drain only it can perform and
  then being dropped. `Mailbox.next` hands out the queue, then the overflow,
  so order holds. Before this, a kilobyte of queries (`ESC [ c` is three
  bytes) froze the pane for seconds with its replies lost and its input
  unread.
- Other threads sending to a full mailbox behave as before: bounded waits,
  then a logged drop, never a wait forever.
- Tests: `the consumer sending to its own full mailbox neither waits nor
  drops`, `another thread sending to a full mailbox still gives up rather
  than block forever` (`mailbox.zig`).

## The agent's outbound queue is bounded

Each connection's writer thread drains one queue of frames. Child output is
copied into it as it is printed, so a viewer that stops reading — the app
suspended or at a breakpoint, a slow relay link — used to grow that queue at
the speed its panes print, with no limit, until the agent ran out of memory
and every session died.

- `queued_data_bytes` counts data-stream bytes queued **or being written**;
  past `data_queue_high_water` (4 MiB) `bridgeData` refuses the chunk. It is
  already in the session's ring; `sent_offset` stays where it was.
- **A session that is behind sends nothing live.** `onChildOutput` hands a
  chunk to the bridge only when `sent_offset` is exactly where the chunk
  starts; otherwise it tells the bridge it is behind (a zero-length call).
  Sending live output past a gap would skip what the viewer is missing.
- **The writer catches sessions up as it makes room.** A refusal marks the
  connection `backlogged`; after writing a batch the writer runs
  `catchUpBacklog`, which sends each behind-and-streaming session its gap
  from the ring (`catchUpLocked`), in `catch_up_chunk` (64 KiB) pieces and
  only while the queue has room. `FLOW{resume}` goes through the same code,
  so a resume no longer sends the whole gap as one frame.
- Lock order is store, then write, on every path; the writer holds neither
  while it writes to the socket.
- What is NOT bounded this way: the pty is still read as fast as the child
  writes, so a viewer that stays away longer than the ring holds (2 MiB)
  loses the oldest output, announced by the "bytes of output lost while
  paused" marker, exactly as with a client pause.
- Test: `a full outbound queue holds output in the ring and delivers it in
  order when there is room` (`server.zig`).

## The layout manifest: syncing and writing

`SessionLayoutManifest` (`session-layout.json` in Application Support) holds
one entry per persistent window: frame, tab group, names, the split tree and,
per terminal leaf, its session id and a screen snapshot with its byte offset.
`paneStack` (optional/additive) holds the rows the user collapsed into blades
and the focus history, by leaf position — see
[stacked-panes.md](stacked-panes.md); restore adopts it before the window lays
out and puts the caret in a pane on show.

### What a relaunch restores

Each window comes back with: its frame; the split tree with exact directions
and ratios; stashed panes (`Leaf.stashIndex`); collapsed rows and the focus
history (`paneStack`), the caret in the pane focused last; its target name
(`ipcName`) and titles (`titleOverride`, `windowTitleOverride` +
`windowTitleSetByUser`); per pane its target name, title — pinned when the
user set it (`Leaf.titleSetByUser`) — banner and tint (`Leaf.tint`, `#RRGGBB`
sRGB, for `--color=#hex`, `random` in the flat style and the color picker);
the window's gradient (`deskVariant`) and tab color (`tabColor`); the pane
sidebar's order and identity (`paneSidebarOrder`, `paneSidebarWindowID`; its
expanded/hidden flags are shared by every window and live in the defaults);
and which window was in front (`frontmost`). `titleSetByUser`, `tint` and
`tabColor` are additive: an older manifest restores the pane untinted, its
title unpinned and no tab color, and an older app ignores them. A tint
change (the picker) and a user-set title save the window at once
(`SurfaceView.layoutStateDidChange`), like a banner; a tab color change does
too (`TerminalWindow.tabColor`).

The same restore code runs for a launch and for the tests:
`presentRestoredSessionWindow` builds the panes over the agent connection
(`makeSessionLayoutRoot`) and hands them to `presentRestoredWindow`; the
single-window hand-off to the front workspace is `showRestoredFront`. An
in-place recovery (`rebuildSessionLayoutController`) keeps the window's
collapses by leaf position and focuses the pane focused last, never a blade.
A machine reboot takes the same path: the app restores from the manifest and
the agent relaunches each session's tombstone. AppKit restoration (session
persistence off) carries the same list in the window's archive — the
window's target name (`InternalState.windowName`), each pane's name
(`PaneView` key `name`, registered once the window exists), banner and tint
(`SurfaceView` keys `banner`, `tint`) — all optional keys.

Tests (`SessionLayoutRelaunchTests`, both window modes):
`aRestoredRowOfTerminalsKeepsItsBlades`, `aRelaunchRestoresEveryAttribute`
(restored, then saved again the same), `appKitRestorationKeepsEveryAttribute`,
`theNewFieldsAreAdditive`.

- **`frontmost`** (additive) marks the window that was in front — the main
  window, or in single-window mode the workspace on show — and restore brings
  it back last (`SessionLayoutManifest.frontmostLast`), so it is in front (on
  show) again. That, and a parked workspace's frame being the window's, is
  what lets a manifest written in either `macos-window-mode` restore in the
  other ([window-modes.md](window-modes.md#persistence)). The blob mirrored to
  the agent is opaque to it; the wire contract is unchanged.

- A change in a window (tree, frame, sidebar, a pane banner, tint or user-set
  title, a collapsed row, the tab color) schedules a sync
  of its entry, debounced 250 ms (`scheduleSync`); at quit every window is
  synced afresh (`syncAllTrackedNow`), which is what keeps the snapshots
  current when only output changed.
- **The file is written off the main thread.** A save encodes every window's
  entry, snapshots included, and rewrites the file atomically; the app's
  shared manifest hands that to a background queue where the latest state
  wins (`writesInBackground`, `pendingWrite`), so a burst of changes is one
  write. `flushWrites()` waits for it and is called when a quit begins and in
  `applicationWillTerminate`. Anything that must read the file right after a
  change (a test, a script) must allow for that or flush. Measured in a debug
  build with 22 panes: 3.6 ms → 0.6 ms on the main thread per banner change.
- **One session-id retry loop per entry.** A leaf's session id arrives after
  its OPEN completes, so a sync that finds one missing looks again every
  0.5 s for up to 30 s (`syncAndCaptureSessionIDs`,
  `capturingSessionIDs`). A sync triggered while a loop is running does not
  start another.

## Agent contract & upgrade compatibility

(The short form is a hard rule in the root `CLAUDE.md`; this is the full text.)

The `ghoztty-agent` outlives the app on purpose (per-user LaunchAgent; survives
quit/crash/upgrade). The direct consequence: **a running agent is frequently a
DIFFERENT build than the app talking to it** — an app upgrade replaces the app
binary while the old agent process keeps running with every PTY attached. The
app↔agent wire contract is therefore a **compatibility boundary.** Forward
compatibility across it is the **default and strongly preferred** path; a
breaking change is allowed but only as a *conscious* decision routed through the
mandatory agent-update process (below), never as an accident. What is never
acceptable is an *unhandled* skew — garbled output, a wedged socket, or a crash.
Treat this boundary with the same care as an on-disk format or a public API.

Rules for any change to the agent↔app protocol (messages, fields, framing, the
ring/snapshot/gap-fill replay, HELLO handshake):

- **Old agent + new app MUST keep working, and new agent + old app MUST keep
  working.** Neither side may assume the peer is its own build. A skew must
  degrade to reduced function, never to garbled output, a wedged socket, or a
  crash. (The 1.14.0 re-attach corruption — new app replaying an old agent's
  scrollback into smeared, non-interactive panes — is exactly the failure this
  rule exists to prevent.)
- **Evolve additively.** New messages and new fields only. Never change the
  meaning, type, or framing of an existing message or field, and never remove
  one that an older peer still sends or expects. Readers ignore unknown fields
  and tolerate absent ones (fall back, don't fail). A field that goes missing
  because the peer is older must degrade gracefully — the way agent-side
  pid/tty already reports null to an app that doesn't understand it.
- **Detect capability at runtime — never at compile time.** Attach begins with
  a **HELLO handshake** that exchanges a protocol/capability version so each
  side negotiates behavior from what the peer *actually* advertises, not from
  what this build happens to ship. Gate every new behavior on the negotiated
  capability, and document each protocol version and what it added in the agent
  protocol source so the compatibility matrix is checkable at runtime and in
  review.
- **Breaking changes are allowed — deliberately, never accidentally.** Forward
  compatibility is the default because it's the cheapest path (no disruption),
  but a break is a legitimate tool when additive evolution would be worse. What
  makes a break acceptable is that it is *conscious* and *backed by the
  mandatory agent-update process* — not that it's forbidden. When you break the
  contract: bump the protocol version, and on an incompatible skew the app must
  NOT replay across it. Instead the mandatory-update mechanism takes over:
  - **Prefer a lazy, non-destructive agent upgrade.** Carry sessions across by
    upgrading the agent when it is safe — on idle, or as each session naturally
    closes — draining/snapshotting and resuming so no work is lost, then proceed
    with the app upgrade transparently. This is what makes most breaks painless.
  - **When a session cannot be carried across**, show a **mandatory, explicit
    confirmation before resetting**: *"Upgrading will reset all windows.
    Continue?"* Never silently reset live sessions, and never silently replay
    across a version the handshake flagged as incompatible.

  The mandatory-update process is the safety net that makes breaking changes
  survivable; the HELLO handshake is what lets us detect when we need it. Build
  and keep both robust, and a breaking change becomes a conscious, bounded cost
  rather than a corrupted-session incident.

Design + status: `docs/design/session-persistence.md`.
