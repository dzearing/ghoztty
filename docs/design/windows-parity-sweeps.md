# Windows parity sweeps

The evidence trail for `scripts\parity-sweep.ps1` (T152). One section per
swept range, written at the time the range was evaluated.

**Why this file exists.** The sweeps before T152 (T88, T117) recorded a
*narrative* of what a merge contained — "this brought the viewer work". A
narrative cannot be checked for holes, and on 2026-07-29 a re-audit found 16
Mac commits that had been merged and never mapped to any Windows work item.
The sweep replaces the narrative with an enumeration, and this file is where
the enumeration lands so the next sweep can diff against it instead of
re-deriving it.

**How a commit stops being unmapped.** The sweep keys coverage on the commit
sha, so a commit is covered once *some* parity doc cites it. Three legitimate
dispositions, all of which count:

1. **Filed** — a new task exists for it.
2. **Covered by an existing task** — the behavior is already in the queue and
   the commit is simply part of that task's content. Cite it against that
   task; do not file a duplicate.
3. **No parity owed** — Mac-only (a Swift crash fix, a macOS test harness, a
   doc scrub). Say *why*, so a later reader does not have to re-derive the
   judgement.

Never resolve an unmapped commit by deleting it from the range.

---

## `cda6e5191..4a41394b2` — 2026-08-08 main intake (swept 2026-08-09)

Swept retroactively: this range was the 2026-08-08 intake, which filed
T598-T606 before the sweep existed. The sweep found **7 of its 54 commits
uncited** — none of them a missing feature, all of them content of a task
that was already filed. That is the exact leak shape T152 was filed for
(compare `538f4fd64` in T152's own table: *"behavior covered, commit was
uncited"*), and it is why citation is now a gate rather than a habit.

- Commits evaluated: 54
- Mapped at the time of the sweep: 47
- Unmapped, now dispositioned: 7

| Commit | Subject | Filed as |
|---|---|---|
| `06d50037a` | macos: harden banner state writes and escape untrusted banner fields | T598 (bundled-hook content) |
| `1b632b812` | macos: drop dead `last` key from banner wipe lists | T598 (bundled-hook content) |
| `4b07859e4` | docs: warn against "fixing" the load-bearing TERM_PROGRAM=ghostty spelling | T598 (bundled-hook content) |
| `15208971a` | docs: correct the agent-integration description to match the code | T598 (bundled-hook content) |
| `4ea557270` | docs: record the HookSpec generalization as a deferred refactor | T598 (bundled-hook content) |
| `4df779938` | macos: drop the AI-attribution line from the bundled process-feedback skill | T598 (bundled-skill content) |
| `bced2217c` | test(macos): give poll's default deadline real headroom (15s -> 60s) | No parity owed - a macOS-only XCTest deadline |

This is also the whole divergence: `git merge-base HEAD origin/main` is
`cda6e5191`, so with this range clean there is nothing on main that this
branch has not been told about.

**What the six T598 rows mean for the Windows work.** They are all changes to
the files main's agent integration *installs* (`ghoztty-banner.sh` and the
bundled `process-feedback` skill), which Windows does not install at all yet.
So they add no new Windows task, but they do change what T598 must ship when
it lands: the hardened banner script (mkdir-mutex around the state
read-modify-write, unique temp file, self-healing on a corrupt state file, and
markdown-escaping of prompt-derived and model-set fields so an untrusted value
cannot forge a clickable link in the trusted banner overlay), the
de-attributed skill template, and the `TERM_PROGRAM=ghostty` spelling that
reads like a typo and is load-bearing. Vendoring the pre-hardening copies
would ship known defects on day one.

---

## `680a07ed3..HEAD` — already-merged history (swept 2026-08-10, T684)

The tail the 2026-07-29 hand audit never reached (it only covered
`--since=2026-07-08`), plus everything the T88 and T117 merges brought in
before that — i.e. every Mac-side commit on this branch since 2026-06-01.

- Commits evaluated: 210
- Mapped before this sweep: 84
- Unmapped, dispositioned below: 126
- Genuine gaps found and filed: **7** (T709–T715)

**Three dispositions do the bulk of the work here, and each is a claim about
evidence, not a shrug:**

1. **Port baseline.** The range is *already-merged* history, and the Windows
   port of each of these features was written afterwards, in July/August,
   against Mac code that already contained the commit. So the commit is part
   of what the port copied, not a delta the port missed. Cited against the
   port's own task, which is where a reader should go to ask whether the port
   is faithful.
2. **Shared code, already compiled in.** The substance is in `src/` (core,
   `src/remote/`, `src/cli/`), which the Windows build compiles from the same
   tree. Nothing is owed unless a *Mac-frontend* behavior rides on top, and
   where one does it is called out.
3. **Mac-only.** A Swift object-lifetime or AutoLayout fix, an XCTest change,
   or a CI/identity/doc scrub. Named individually below with the reason, so a
   later reader does not have to re-derive the judgement.

### Remote windows, the machine chooser, and the relay — port baseline

WP4 (June) and WP-A1/B2/C2/D1/D2 (July) built the Mac's remote-window stack:
Cmd-Shift-N chooser, the machine pill, TCP and relay transports, Google
sign-in, the reconnect ladder, and remote-window restore. The Windows port of
all of it is T21a/T21b (relay dial + sign-in), T22b/T22c (device directory +
chooser dialog), T93 (brokered OAuth), T68 (new window/tab/split inherits the
remote host), T367 (the caption-band connection pill), and T318–T321/T336
(session roster, cross-machine browse, resume, Restore All).

`333b9565a`, `e91c6e7b7`, `5236bb863`, `75c4b301d`, `f3e5ec070`, `29ee2c71e`,
`5945f7e13`, `d550aa8dd`, `86ada5f9e`, `74ea0674f`, `9186f1f00`, `a8a485f5b`,
`f0482de02`, `dbfcd7c08`, `a12c26765`, `3f6dc90bc`, `8076e707b`, `9716098bb`,
`361aa960e`, `9ce38cdaa`, `68d7baa8a`, `9ca6b1773`, `ef84967d6`, `b2b90939c`,
`d7c570175`, `4a55acef1`, `81792453a`, `f1d38a028`, `d2d47f5b0`, `4c5ae0e1a`,
`ff9760acb`, `881d09a91`, `555ca6607`, `cbc3d5bfe`, `a00550f84`, `f2dbaeb2c`

Two of those carry a live Windows follow-up rather than a gap of their own:
`cbc3d5bfe`/`a00550f84` (a device rename reaches every open window's pill)
land on **T610**, since the win32 pill does not name the machine at all yet;
`23d3938e8` (live per-machine CPU/mem in the picker) is **T619**, already
filed and open.

`23d3938e8`

### Activity Monitor — port baseline (T226 → T284/T285/T286/T295/T296/T298)

The Mac built the panel over three days at the end of June — charts, machine
carousel, process filter, multi-select kill, sparklines. The win32 port
(T226 and its four splits) was written against that finished panel.

`9e8ff621b`, `04c03f9e6`, `ea6b4ef70`, `afda9fcf8`, `f24d7f472`,
`ac4b8c401`, `b359f5a12`, `e69bb02a6`, `c6a72a8ee`, `438b853bb`, `f55488c13`

### Hero mode — port baseline (T19a/T58/T59a/T59b, divider T250)

`fe5335968` reflowed terminal content and smoothed the divider drag in Mac's
hero mode. The win32 hero mode was designed (T58) and ported (T59a/T59b)
afterwards, on a snapshot pipeline rather than live panes, and its divider was
brought onto the design system in T250.

`fe5335968`

### Session persistence — port baseline (T89a → T89b–T89i)

Mac's T03–T19 series (LocalAgentManager, the session-layout manifest,
launch-time restore, the per-user LaunchAgent, `sessions.json`, on-by-default)
is the design the Windows port translates: named pipe for the UDS, HKCU Run
for the LaunchAgent, `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\` for the
state directory.

`09f277f47`, `3730b5f26`, `3e3f355a0`, `6c6e32b64`, `0490b16fc`, `a0dce4b48`,
`cda38f18f`, `2654015c7`, `03a781207`, `062d797f7`, `5ed3c26a9`

### Viewer panes — port baseline (T90a → T90b–T90h)

Mac's T01–T15 viewer series in one day on 2026-07-17, plus its follow-ups.
The Windows port is T90a's design and the T90b–T90h splits, whose own
follow-ups (T380, T383, T390, T394–T397, T399, T400) are where the individual
behaviors below are tracked on this side.

`6a10f3a53`, `df7a46903`, `ccf71bf4d`, `b612d6540`, `ebd25654c`, `2ba2744ba`,
`ad7d547c2`, `27a6fa42e`, `f88e9a5fd`, `2b9018a9a`, `52100e1cc`, `fda06f156`,
`81fc07da2`, `0a22f6a1c`, `dd9811582`

`dd9811582` (File→Open / dock drop for markdown) is the one with no Windows
equivalent filed. It is not a gap in the pane itself: the win32 build has no
file-association or drop-target story at all, which is a larger question than
this sweep, and `+new-window --view=` already covers the scriptable path.

### Pane banner markdown — port baseline (T35, T131, T149, T165, T377)

Headings, tables, lists, checkboxes, separators, autolinking and the wrapping
rules all shipped on Mac between 2026-07-17 and 2026-07-30 and are documented
as present on Windows in CLAUDE.md, each with its own win32 task and geometry
assertions.

`47e15036f`, `6eeebcc15`, `701d700bf`, `bc016b257`, `4dd56db35`, `6da6dad9f`,
`c77c98f54`, `c35dabe73`, `c7c9da939`

### Chooser and Activity Monitor build-out (August) — mixed

This is the youngest slice and the one that produced most of the real gaps,
which is what you would expect: the Windows ports were written before it.

| Commit | Disposition |
|---|---|
| `7d9ef0dff` | Per-session CPU meter fed by the agent's pushed stream — **T462** (win32 never subscribes to `session_cpu`) |
| `f0d5e3308` | Stop the session-CPU stream when the picker closes — content of **T462** |
| `9c79a6374`, `8133f7bfe` | CPU-value layout polish in the row — content of **T462** |
| `9e06ca67a` | Live session roster while the dialog is open — **T710** (filed) |
| `bf318f55b` | Push the roster instead of polling it; show window renames — **T710** (filed) |
| `74fade009` | Right-aligned "See Activity", now including This Mac — **T177** (the win32 detail action row, done) |
| `2a5da6a27`, `d706f2d28` | Never offer to resume a session we have no pane for; hide just-closed panes — **T520** (open) |
| `f0a4ad6d0` | Stop `sessions.json` growing forever with dead Resume rows — shared `src/remote/`, already compiled into the Windows agent |
| `78a21daa8` | Modeless New Window picker — **T712** (filed) |
| `ab79f37c4`, `2964c8859` | Per-core %CPU and which pane owns each process — **T709** (filed) |
| `9018aee04` | What's New reshaped into a real release-notes window — **T624** (open: no bundled release notes on Windows) |
| `38d02efe9` | Link the version at the fork's release — **T714** (filed) |
| `3de92c55d` | New-surface link clicks go to the default browser — already shipped on win32 as **T163** (popup adoption + Ctrl to keep) |
| `2742c2013`, `c90f110be` | macOS XCTest timing fixes — no parity owed |

### Filed as new Windows tasks

The seven genuine gaps this sweep found. Each names the Mac commit in its own
Summary, which is what maps the commit from here on.

| Task | Gap | From |
|---|---|---|
| **T709** | Activity Monitor has no per-core %CPU and no owning-pane column | `ab79f37c4`, `2964c8859` |
| **T710** | The chooser polls the roster instead of being pushed it, and never shows a window rename | `bf318f55b`, `9e06ca67a` |
| **T711** | The chooser opens with an empty, unseeded device list and never refreshes while open | `66012e2ee`, `b0028112a`, `55dd70978`, `27e639ae6` |
| **T712** | The chooser is modal and freezes the terminal behind it | `78a21daa8` |
| **T713** | Relay sign-out leaves account remote windows running and new dials allowed | `ed8482d25` |
| **T714** | The About box has no links — no fork release for the version, no Help | `6ea66423f`, `38d02efe9` |
| **T715** | No assistive-tech attribute for a remote window's link state | `97530c9ac` |

### Mac-only — no parity owed

| Commit | Why nothing is owed |
|---|---|
| `716ade71a` | Swift object-lifetime fix: use-after-free tearing down a remote pane's `SurfaceView`. win32 owns its surfaces explicitly; no analog. |
| `f7459ffee`, `fe592d126`, `042f9c6f7` | AppKit AutoLayout thrash around the machine pill (intrinsic content size feedback loop, and its revert). The win32 pill is laid out by hand in `remote_pill.zig`. |
| `b421cfac3` | "Never swap a failed surface over a healthy grid" — a SwiftUI view-swap ordering bug. win32 rebuilds the pane's transport in place. |
| `c1b42e16f` | Stop the reconnect ladder on a poisoned session — the win32 ladder already carries the poisoned-session breaker (T367, documented in CLAUDE.md). |
| `38ff0c0e3`, `03ca52586` | Frozen-agent thaw. The fix is in `src/remote/` and the agent, which Windows compiles and runs; the Mac half is Swift plumbing. |
| `bff7c6c40` | GUI-thread/IO-thread join deadlock — the fix is in `src/Surface.zig`, `src/termio/` and `src/datastruct/`, i.e. already in the Windows build. |
| `c1570b5eb`, `372a8c606` | IPC single-instance with sentinel-file recovery. Windows has no sentinel file *by design*: binding the named pipe **is** the single-instance lock (`IpcServer.zig`), so there is no stale-socket state to recover from. |
| `3a2df53e1`, `912299319` | Bundle-identity renames (`com.mitchellh.*` → `com.dzearing.ghoztty`) across Info.plist, xcodeproj, flatpak, po/, CI. The Windows endpoints already derive from the `ghoztty` name. |
| `ed34fbab7` | Automatic CLI setup + Claude Code integration on first launch — win32 has its own `ClaudeIntegration.zig` doing the same job the Windows way. |
| `d7fbe2cd6` | `+split --target=<window>` no-op when a viewer pane is focused. A SwiftUI focus-resolution bug: win32 splits the tab's active pane *node* (`Window.newSplitAt`), which is pane-kind agnostic, and T395 exercises that path from a viewer. |
| `97530c9ac` | *(the AX attribute half is filed as T715; the macOS test half is Mac-only)* |
| `366f557b4` | Chooser polish — hide own machine, dedupe header, footer divider, profile-photo avatar. The win32 chooser is owner-drawn with its own layout (T172, T175–T177); T602 tracks the remaining identity-band difference. |
| `bc96dad4d` | XCTest: wait for conditions instead of fixed durations. |
| `6ea66423f` | *(the Help/About link half is filed as T714)* |

### What this sweep does not cover

The sweep that produced the table above watched only `macos/` and
`src/viewer/`, so a change main made to the shared `src/` core was ungated —
that is how the `src/cli/send_keys.zig` divergence behind T604 went unflagged.
**T685 widened it**, and the section below is the same range re-swept under the
wider paths, with the 81 commits that widening exposed dispositioned one by one.

---

## `680a07ed3..origin/main` — the same range, swept WIDE (2026-09-14, T716)

T685 widened `parity-sweep.ps1` from `macos/` + `src/viewer/` to `macos/` +
`src/` (minus the two frontends that owe Windows nothing). Re-running the
already-merged-history range above under the wider paths turns 349 commits into
368 and finds **81 that no Windows work item had ever cited** — 39 in June, 40
in July, 2 in August.

**This supersedes the claim at the head of the section above.** T684 said every
Mac change merged since June was accounted for, and that was true of the
definition it swept under: `macos/`. Under the widened definition it was not,
and these 81 are the difference. The claim now reads: every Mac change *and*
every shared-core change merged since June is accounted for, by that section
plus this one.

**The fact that decides most of these.** All 81 are already ancestors of
`users/dzearing/windows-amd64` — checked commit by commit at the time of
writing — so none of them is code the Windows build is missing. The parity
question here is therefore not "does Windows have this" (it does; it compiles
and ships in `zig-out\bin\ghoztty.exe` and `ghoztty-agent.exe`) but "does the
Windows seat owe follow-up work for it". That is why the dispositions below are
citations rather than tasks: an unported Mac feature would have produced a task,
and none of the 81 is one.

### Shared remote/agent core — WP1 through WP4 (27 commits)

The protocol library, the transport, the connection, the channel and session
lifecycle, the agent's session server, the `termio.Remote` backend and the C API
that hangs off it. **Windows runs this exact source**: `ghoztty-agent.exe` is
`src/remote/agent/` compiled for `x86_64-windows`, and the client half is the
same `src/remote/` the win32 frontend links. There is no Mac implementation here
to port — one codebase, two targets, which is the arrangement CLAUDE.md's
architecture section describes. No parity owed.

| Commit | Subject |
|---|---|
| `81275a9d4` | feat(remote): WP1 — pure wire protocol lib (HELLO, frames, transfer codecs) |
| `7210e230e` | feat(remote): WP3 spike — per-channel inbound ring + ChannelTable (§3.4) |
| `26af4f78a` | feat(remote): WP2 agent session-server core (increment 1, §4.1–4.2/§7.1) |
| `ca02e266b` | feat(remote): add RemoteConnection transport core (WP3 increment 1) |
| `07ca686d8` | feat(remote): add health & link-state tracking to RemoteConnection (increment 2) |
| `176d85ad4` | feat(remote): channel/session lifecycle, resync, steal, FLOW-pause (WP3 incr 3) |
| `d6b463753` | feat(remote): termio.Remote backend + backend.zig union arm (WP3 incr 4a) |
| `de230b6de` | feat(remote): wire .remote surface construction + ghostty_remote_* C API (WP3 inc 4b) |
| `1766a783a` | feat(remote): ssh Transport — connection.Stream over ssh subprocess (§4.1) |
| `8a9f7bc14` | feat(remote): agent real PTY child + zig build agent exe target |
| `213025a5e` | feat(remote): client-side lane mux — two logical streams over one transport (§4.3) |
| `85faeb456` | feat(remote): TCP transport + loop-accept daemon agent + Mac test client |
| `695bfc06a` | fix(remote): test client sends CR (not LF) as Enter + hard exit cap |
| `44220cd0c` | fix(remote): daemon never wedges + sessions survive disconnect (§4.1/§5/§7.3) |
| `dd6d4b46c` | feat(remote): remote-test-client --catchup-demo proves close-laptop catch-up (§5/§7.3) |
| `8eb4b1437` | test(remote): catchup-demo counter cmd overridable via GHOZTTY_CATCHUP_CMD |
| `bd87b8a45` | feat(remote): reconcile client channel rendezvous + ghostty_remote_connection_new_tcp (WP4 foundation) |
| `fd198da81` | fix(remote): forward live RESIZE to agent — remote surface now renders output (WP4) |
| `eb292348b` | feat(remote): metrics/proc protocol frames + agent host-metrics sampling (inc 1) |
| `e72817c77` | feat(remote): client metrics subscription + C API (inc 2a) |
| `871c94915` | feat(remote): remote process snapshot — agent enum + client + C API (inc 3a) |
| `6d6bb8bbf` | feat(remote): proc kill + spawn (agent/client/C API) + local in-process provider (inc 4+5 backend) |
| `d466320c0` | fix(remote): agent no longer wedges all sessions on a stalled child write |
| `19bad3fd5` | fix(remote): remote shell exit closes the pane (wire EXIT frame -> child_exited) |
| `ffc124b96` | tune(remote): idle-TTL 10min->5min to reduce abandoned-session pile-up |
| `e761c99e9` | fix(remote): never wedge the GUI thread joining a remote surface's IO thread |
| `4bbd2571c` | fix(remote): tray failure must not kill the agent daemon |

### The Windows arms of that build-out, written from the Mac seat (13 commits)

These are not Mac work at all — they are the Windows halves, landed on main by
the seat that happened to be building the feature: the ConPTY arm of the agent's
pty child and its cross-compiled smoke exe, Windows detached spawn and real-pid
recovery, the PEB cwd read, the kill-on-close job object, the Windows agent's
system-tray UI, the agent MSI and its console-free custom-action DLL, and the
owner-only DACL on `relay.env`. Citing them closes the loop on work this seat
already owns and tests (`test\win32\` carries acceptance for the job object,
the tray and the MSI). No parity owed.

| Commit | Subject |
|---|---|
| `e2e72045d` | feat(remote): Windows ConPTY arm for agent pty_child (§13) |
| `35c84eedf` | feat(remote): ConPTY runtime smoke exe (cross-compiled, §13) |
| `1efa4971c` | fix(remote): ConPTY smoke teardown deadlock — close pty before joining reader |
| `7be14ad81` | fix(remote): Windows detached spawn survives + returns real pid (GetProcessId, breakaway-from-job) |
| `59e0c87c1` | feat(remote): proc full-path (cmd) per-OS + Windows detached spawn via CREATE_NEW_CONSOLE + diagnostics |
| `377d8ecff` | test(remote): +--query-cwd probe — verified Windows agent reads real cmd.exe cwd via PEB |
| `23729859a` | feat(remote): Windows agent system-tray UI (GUI subsystem, no console) |
| `9969c06c2` | fix(remote): agent PTY shells die with the agent (kill-on-close job object) — no orphans |
| `7168891fb` | feat(remote): WP2 spike — Windows agent risks (cross-compiles from Mac) |
| `26988ef5a` | feat(relay): agent MSI overhaul — semver artifacts, legacy-install cleanup, launch after install |
| `dc028bd7c` | fix(relay): no console windows during MSI install — in-process custom-action DLL |
| `dfaaaec2c` | feat(agent): tray sign in/out + account email, icon, menu restructure |
| `e5f91faa8` | harden(agent): owner-only DACL on Windows relay.env + drop dead dev token |

### Relay enrollment, link management and agent lifecycle (16 commits)

Browser and device-code enrollment, the native Zig WS client, SSH-over-relay,
keepalive and reconnect, the single-instance mutex, the takeover protocol,
self-update, and the shell/TERM defaults a relayed session gets. All of it is
`src/remote/` plus the Go relay, both of which Windows shares. Two are worth
naming individually because they *look* POSIX-shaped and are not:

- `4441084d6` ("fall back to the user's login shell, not `/bin/sh`") landed the
  Windows arm in the same commit: `resolveShellPath` resolves
  `open_shell` → `%COMSPEC%` → `C:\Windows\System32\cmd.exe` on Windows,
  beside the POSIX `$SHELL` → `getpwuid` → `/bin/sh` chain.
- `71db69417` / `1b6b873e0` ("agent enforces single instance", "close both
  dup-daemon holes") are the named-mutex-on-Windows / `flock`-on-POSIX pair —
  the Windows side *is* the mutex half.

No parity owed.

| Commit | Subject |
|---|---|
| `63d0d0198` | feat(relay): agent device-code enroll flow + installer story (WP-B3 agent) |
| `d538167e6` | feat(relay): Tailscale-style browser enrollment — relay web callback + agent opens browser; device-code becomes fallback |
| `a4e8e57c1` | fix(relay): agent control-channel keepalive — detect dead link after sleep + hostname header |
| `292a07368` | feat(relay): native Zig WS client — single-binary agent + subprocess-free client |
| `628321b9a` | feat(relay): SSH-over-relay transport — connectors + ssh ProxyCommand (WP-T2/T3) |
| `71db69417` | fix(relay): agent enforces single instance — named mutex (win) / flock (posix) for daemon modes |
| `ae77fbc1d` | feat(relay): agent tray Disconnect/Reconnect — user-controlled relay link with live status |
| `14515562c` | fix(agent): hot-reload relay.env on re-enroll — atomic write + daemon watcher |
| `64eacaf71` | feat(agent): first-run auto-enroll in interactive relay mode |
| `f271416ad` | feat(agent): real Check-for-updates + close unauthenticated listen exposure |
| `05ccc9051` | feat(agent): takeover protocol — heartbeat liveness check + --force-replace ("there should be only one") |
| `1b6b873e0` | fix(agent): close both dup-daemon holes — Global\ per-SID mutex + fast-drop reconnect backoff |
| `6bf6d7f2a` | feat(agent): self-update — manifest-driven, sha-verified, idle-gated swap+respawn |
| `37cca720a` | fix(relay): advertise xterm-256color to remote sessions + set COLORTERM |
| `4441084d6` | fix(agent): fall back to the user's login shell, not /bin/sh |
| `e8dfadcd7` | feat(agent): --port-file publishes ephemeral --listen port atomically |

### Session persistence, T04–T17 (15 commits)

The agent's UDS listener and same-uid peercred gate, `LIST_SESSIONS` and the
`+sessions` CLI, session pinning and ring caps, load-at-start materialization,
the relaunch affordance and `session-relaunch` config, reboot scrollback via
disk ring snapshots, and the re-attach repaint. The Windows seat's whole
session-persistence track (`docs/claude/sessions.md`, and the `holder-*`,
`session-*`, `chooser-*` and `restore-*` acceptance guards) is built on this
code — the named pipe stands in for the UDS and the peercred gate becomes an
owner-only DACL, and both of those translations are already documented and
tested here. No new parity owed.

| Commit | Subject |
|---|---|
| `264e1ccc3` | feat(session-persistence): agent --listen-unix transport + same-uid peercred gate (T09) |
| `d323a9a72` | feat(session-persistence): client UDS dial + ghostty_remote_connection_new_unix ABI (T09b) |
| `29ffb1fc6` | feat(session-persistence): LIST_SESSIONS agent RPC + `+sessions` CLI (T10) |
| `0f5ed678e` | feat(session-persistence): pin local sessions, cap 256, --ring-bytes (T11) |
| `4f2fd3ec9` | feat(session-persistence): load-at-start materialization + RELAUNCH (T12b) |
| `1c5ac9643` | feat(session-persistence): viewer auto-relaunch UX + session-relaunch config (T12c) |
| `329303c00` | feat(session-persistence): interactive relaunch affordance for session-relaunch=prompt (T12c2) |
| `1568e76c9` | feat(session-persistence): reboot scrollback — agent ring disk snapshots + replay-on-relaunch (T13) |
| `36be37685` | feat(session-persistence): snapshot dirty rings on graceful agent SIGTERM (T13b) |
| `d57604496` | test(session-persistence): fix use-after-free at teardown in reboot-snapshot test (T17a) |
| `33225d153` | feat(session-persistence): plumb agent pid/tty through Remote.getProcessInfo (wp3) |
| `e8f1cf742` | fix(session-persistence): re-attach repaint (SIGWINCH) + width-aware scrollback replay |
| `4337a9c23` | fix(session-persistence): buffer raced-in ATTACH replay so scrollback restores reliably (T06c) |
| `30b6cc6c6` | feat(session-persistence): forward env overrides to local-agent panes (T04a) |
| `9f3964157` | feat(session-persistence): forward bash/nushell shell-integration argv to local-agent panes (T04c) |

### Activity monitor and host/session metrics (2 commits)

The pushed per-session CPU stream and the macOS-side unit correction. The
protocol and agent halves (`src/remote/agent/proc.zig`, `protocol.zig`,
`connection.zig`) are shared; the Mac half is `embedded.zig` presentation, and
the Windows presentation is its own frontend — `ActivityMonitor.zig`,
`activity_sample.zig`, `SessionCpuProbe.zig` and `chooser_cpu.zig` already
consume that stream, with the `activity-monitor`, `activity-monitor-dialed` and
`activity-pane-column` guards over it. `d9f2ca93e`'s unit fix is explicitly a
macOS units bug; Windows samples its own counters. No parity owed.

| Commit | Subject |
|---|---|
| `7d3e8b496` | feat(agent): pushed per-session CPU stream, throttled by the agent |
| `d9f2ca93e` | fix(activity-monitor): correct macOS per-process CPU units; add tty for pane attribution |

### macOS code signing (2 commits)

Stable self-signed identities for debug bundles, so a Keychain "Always Allow"
survives a rebuild. There is no Windows counterpart: our debug build is an
unsigned `zig-out\bin\ghoztty.exe`, and release signing is a separate track.
No parity owed.

| Commit | Subject |
|---|---|
| `426a4dd4b` | build(macos): sign debug builds with a stable self-signed identity |
| `327640abc` | build(macos): sign the debug bundle with a stable identity when available — Keychain Always Allow survives rebuilds |

### Shared build fixes already in the Windows build (2 commits)

`d04ecc2bb` stamps the bundled agent by its last agent-source commit rather than
HEAD, and `11f7f35bd` keeps the agent's unwind tables at `.sync` because `.none`
crashes zig on release builds. Both live in `src/build/GhosttyAgent.zig`, which
is the step `zig build agent` runs on this box too. Carried, not owed.

| Commit | Subject |
|---|---|
| `d04ecc2bb` | fix(agent): stamp bundled agent by last agent-source commit, not HEAD |
| `11f7f35bd` | fix(build): keep agent unwind tables at .sync — .none crashes zig on release builds |

### Shared behavior verified as already carried on Windows (4 commits)

These four are the class T716 was filed to look hardest at — shared
non-`src/remote/` changes with a user-visible surface — so each was checked
against the code on this branch rather than reasoned about:

- `219d6554d` (default rename shortcut) put the binding in the *shared* keybind
  block via `ctrlOrSuper`, so Windows gets `ctrl+shift+r`. Present at
  `src/config/Config.zig:7343`, bound to `prompt_window_title`, with the win32
  action wired through the menu bar, the command palette and the context menu.
- `a5119273d` (`+list --tty`, `+send-keys --when-idle`) is carried with the
  documented `--tty` → `--pid` translation (`src/cli/list.zig`) and
  `--when-idle` verbatim (`src/cli/send_keys.zig:76`), with
  `test\win32\ipc-when-idle.ps1` over it.
- `2b71512a5` (Cmd-Shift-D panicking in a remote window) was a Mac-only shape:
  the crash came from lowering a *remote* pane's pwd into the **local**
  `working_directory`, where a non-absolute path hits `openDirAbsolute`'s
  `unreachable`. The win32 remote path keeps the remote cwd inside
  `Surface.Overrides.remote` and never seeds the local one
  (`src/apprt/win32/App.zig:5766`), so the mirror-image case — a Mac host's
  `/home/…` cwd inherited into a Windows split — cannot arise the same way.
- `ed98b22fe` is the `CommandCore` extraction, a pure refactor of
  `src/Command.zig` that the Windows build compiles as-is.

No parity owed.

| Commit | Subject |
|---|---|
| `219d6554d` | feat: default cmd+shift+r keybinding for window rename |
| `a5119273d` | feat(cli): +list --tty pane lookup and +send-keys --when-idle |
| `2b71512a5` | fix(remote): Cmd-Shift-D in a remote window no longer panics |
| `ed98b22fe` | refactor(remote): extract CommandCore from Command.zig (DI of rlimits/pre_exec/post_fork) — §17 |

### What the widened sweep still does not cover

Nothing in `src/` or `macos/`, as of this range: the widened paths are the whole
shared core minus `src/apprt/win32/` (ours) and `src/apprt/gtk/` (Linux's). What
remains ungated is everything *outside* those two trees — `dist/`, `relay/`,
`scripts/`, `build.zig` — which a commit reaches only in company with a `src/`
or `macos/` change today. Widening again is a call for a sweep that finds a hole
there, not a speculative one.
