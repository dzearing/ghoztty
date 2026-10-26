# Remote machines

Remote windows (`+new-remote-window`, the Cmd-Shift-N chooser), closing them
(Close vs Disconnect), and what relay sign-out does to an enrolled Mac. Read
before touching remote surfaces, close confirmation, `RelayAccount`, machine
enrollment or `RelayHostAgent`. Design history: `docs/design/remote-machines.md`,
`docs/design/remote-transport-relay.md`, `docs/design/mac-relay-host.md`.

## `ghoztty +new-remote-window`

Open a terminal window whose shell runs on a remote machine via a `ghoztty-agent`
reached over TCP. Drives the same flow as the Cmd-Shift-N "New Remote Window" menu
action (dial the agent, build a remote surface, open the window), so the remote
path is scriptable/testable from the shell.

```
ghoztty +new-remote-window --host=<host> --port=<port> --working-directory=<path> --shell=<path> --command=<cmd> --focus
```

- `--host`: Agent host (DNS name or literal IP). Required.
- `--port`: Agent TCP port. Required.
- `--working-directory`: Working directory ON THE REMOTE MACHINE for the new
  session. Overrides the machine's per-host default.
- `--shell`: Shell ON THE REMOTE MACHINE to run (e.g. `wsl.exe`,
  `powershell.exe`, `/bin/zsh`). Overrides the machine's per-host default.
- `--command`: Command to run in the remote session instead of an interactive
  shell. Runs through the resolved shell using its native convention (POSIX
  `-lic`, cmd `/c`, powershell/pwsh `-Command`, wsl `--`).
- `--focus`: Activate Ghoztty and raise the new window; it opens in the
  background otherwise (see Focus above). A failed dial still shows its modal
  alert.

```bash
ghoztty +new-remote-window --host=127.0.0.1 --port=7777
ghoztty +new-remote-window --host=winbox --port=7777 --shell=wsl.exe --working-directory='C:\dev'
```

The remote session uses the remote machine's own default shell and working
directory (the local shell/pwd are NOT forwarded — they would not exist on a
different OS such as a Windows ConPTY agent) unless a **per-host default** or
an explicit flag says otherwise. Per-host defaults (default working directory
+ default shell per machine) are edited in the machine chooser (Cmd-Shift-N →
row `⋯` menu → "Host Settings…") and persist in UserDefaults keyed by relay
device id or `host:port`; explicit `--working-directory`/`--shell` flags
override them per window. New tabs/splits on a remote window use the per-host
default shell too (their cwd inherits from the parent pane).

### Closing a remote window: Close vs Disconnect

Freeing a remote surface DETACHes its agent session by default and only CLOSEs
it — terminating the remote child — when the app marked the surface
CLOSE-on-free, which it does on every user-initiated close. **Disconnect** is
the third button that skips that marking, so you can walk away from a remote
session and resume it later from the Cmd-Shift-N chooser.

- The close confirmation for a window whose terminals run on a **remote**
  machine gets three buttons: `Disconnect` (rightmost, and the **default** —
  Return picks it), `Close`, `Cancel`. The wording names the machine and counts
  the sessions at stake, and is scope-neutral so one sentence serves a pane, a
  tab, a window and a tab group.
- **A remote window is confirmed even when it is IDLE.** Ending a process on
  another machine is not the recoverable thing an idle local shell is, so the
  usual "only prompt while something is running" gate is widened for remote
  panes — at every *interactive* close (Cmd-W, the red X, Close Tab / Other
  Tabs / Tabs on the Right / Window). It is deliberately NOT widened inside
  `closeSurface`, because that is the path IPC `+close`, AppleScript, App
  Intents and viewer panes take: a modal there wedges every later `ghoztty +…`
  command until someone dismisses it.
- **`confirm-close-surface = false` still means no prompt.** A user who turned
  confirmation off does not get one invented for them.
- **Local-agent (session-persistence) windows are excluded on purpose.** Their
  machine is `isLocalMachine`, and "closing a pane ends its session" is that
  feature's documented contract (see `+close`); the way to leave one running is
  to quit the app.
- **A tab group can mix machines.** A group-scoped close offers Disconnect when
  any affected window has something to spare, pins only the panes that actually
  live on a remote machine, and names the machine only when there is exactly
  one (several read as "other machines" rather than naming one and lying about
  the rest).
- A Disconnect is still a deliberate close: the window's `RemoteSessionManifest`
  entry is removed, so the WINDOW does not come back on next launch. The
  SESSION stays alive and is resumed from the chooser.

The user's answer is recorded as a **pin** (`SessionDetachPin`), not as a
one-shot intent write, because a single close marks CLOSE-on-free twice from two
independent places — `surfaceTreeDidChange` (the leaf left the tree) and
`windowWillClose` (the window is going away) — in an order that varies by close
path. The pin refuses later CLOSE markings, and is released when the view is
re-adopted into a live tree (an undone close, a pane moved between windows) so a
LATER close closes normally. Policy + wording live in `SessionDisconnectPolicy`;
tests: `SessionDisconnectPolicyTests`, `SessionDetachPinTests`,
`SessionDetachPinPlanTests`.

### Signing out revokes THIS machine

An account's **user session** and a machine's **device enrollment** are two
independent relay credentials, and `POST /oauth/signout` revokes only the
session — deliberately, because an account may own headless hosts that no app
is signed in on. That independence was also a hole: signing out in the app
running ON an enrolled machine left the machine listed, online, and bridgeable
from every other client on the account, with live sessions still visible
through "See Activity".

**The rule:** app sign-out is a **hard revocation of the machine the app runs
on**, when — and only when — that machine's enrollment belongs to the account
signing out. `RelayAccount.signOut()` reads the local `relay.env`, asks
`GET /v1/agent/whoami` whose machine it is, and on a match calls `POST
/v1/agent/deenroll` with the *machine's own* credential: the device row is
deleted (its token hash gone, so it can never re-authenticate) and every live
connection — control **and** in-flight bridged data — is severed. Other
clients lose the row on their next `/v1/client/devices` refresh (the chooser
polls every 5s while open). Then the local credential file is deleted so a
restart can't dial with it.

- A machine enrolled to a **different** account is untouched — the app is a
  guest on that host.
- A Mac with **no** local enrollment (the common case) has nothing to revoke
  and sign-out is unchanged.
- An agent whose credential comes from `GHOSTTY_DEVICE_TOKEN` rather than
  `relay.env` is invisible to the app and is NOT revoked. Identifying it by
  hostname was rejected: hostnames collide, and the failure mode would be
  silently deleting somebody's *other* machine during sign-out. The remedy is
  the chooser's existing "Remove from Account" (`DELETE
  /v1/client/devices/{id}`), which is the same hard revocation.

**Failure is never silent.** The revocation is awaited; if the relay can't be
reached, `signOut` **throws and the account stays signed in** (reporting
"signed out" while the machine is still reachable is the bug itself). The user
may sign out anyway, which arms a **pending revocation** — `relay.env` is left
in place as the retry's own record, and the revocation is retried at every
launch and on every network-came-back transition until the relay confirms it.
The retry authenticates as the DEVICE, so it needs no account session.

**Sign-out suspends rather than discards.** The machine's name and relay are
remembered — recorded **before** the de-enroll POST, because the relay is about
to delete the only record of that name and a lost response would otherwise lose
the machine for good — and signing back in with the **same** account re-enrolls
it (`POST /v1/client/devices`) and writes the fresh credential to `relay.env`,
which a running agent adopts within one watcher tick and reconnects with
(`relay_creds.zig`). A different account signing in never inherits it, and
restore is refused across relays (a session on relay A can't mint a device on
relay B). This mirrors what sign-out/sign-in already do to the account's remote
*windows*, and is what makes signing out safe rather than a one-way door. The
restore is retried at **every launch while signed in**, not just at sign-in: a
re-enroll can fail transiently (relay 5xx, device quota), and nobody would think
to fix a missing machine by signing out and back in.

**The two failure paths that look alike are kept apart.** A revocation whose
POST landed but whose response was lost is indistinguishable from one that
failed, so neither side guesses: the retry treats a later 401 as "already
revoked" *without* discarding the suspension the first attempt recorded, and a
sign-in that would cancel a pending revocation first re-checks the credential —
cancelling only when it is confirmed alive, dropping it and re-enrolling when it
is confirmed dead, and staying armed when the relay can't say. An unparseable
`RELAY_BASE` is likewise not treated as "already revoked": the agent dials the
base it was *started* with and only ever compares that field, so the machine can
be perfectly reachable with a broken line in the file — the app falls back to its
own relay rather than deleting the one credential that could revoke it.

**An enrolled Mac hosts.** Enrollment is the only opt-in: while `relay.env`
holds a credential the relay confirms belongs to the signed-in account, the
app keeps a relay agent running as its own LaunchAgent
(`com.dzearing.ghoztty[.debug].relay-agent`: `ghoztty-agent --relay=<base>
--headless --exit-on-revoke`), so the Mac is online in every chooser it is
listed in. It is separate from the session-persistence agent (a relay client
must never see local panes; the session agent must never restart under live
panes), and their single-instance guards are per role so they coexist.
Sign-out stops it (awaited, before "signed out"), including when the
revocation is only pending; a dead credential stops it and the agent exits by
itself after two 401s; an unreachable relay changes nothing; a
relay-disabled app (`GhosttyRelayDisable`) touches nothing. `RelayHostAgent`
(`macos/Sources/Features/Remote/RelayHostAgent.swift`), policy
`MachineHostingVerdict.decide`; design: `docs/design/mac-relay-host.md`.

Client: `macos/Sources/Features/Remote/MachineEnrollment.swift`. Tests:
`MachineEnrollmentTests`, `RelayHostAgentTests`, `RelayAccountSignOutTests`, and
`relay/signout_revoke_test.go` (which pins both halves: `/oauth/signout` alone
leaves the machine reachable, and de-enroll kills the live bridge).
