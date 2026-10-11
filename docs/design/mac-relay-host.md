# A Mac that hosts: role-scoped agent lock + the macOS relay agent

**Status:** implemented on `users/dzearing/mac-relay-host`.

A Mac enrolled to an account appeared in every chooser on that account and
could never come online. Two things were missing, in dependency order: the
agent's single-instance guard could not tell a relay daemon from a
session-persistence daemon, and nothing on macOS ever started a relay daemon.

## What was actually measured (and one correction)

The relay journal shows zero `agent online` events for this Mac, ever, and
zero auth rejections: no agent ever dialed. The credential in
`~/.config/ghoztty/relay.env` is valid (`/v1/agent/whoami` → 200).

Starting `ghoztty-agent --relay=… --headless` by hand failed with *another
instance is already running*. That was first read as the default lock being
shared by every role. It is not the whole story, and the reproduction matters:

- The session-persistence agent does **not** hold the default
  `~/.config/ghoztty/agent.lock`. LocalAgentManager points it at
  `~/.config/ghoztty/local-agent/agent.lock` through `GHOSTTY_AGENT_LOCK`.
  Nothing held the default lock.
- But the LaunchAgent sets `GHOSTTY_AGENT_LOCK` and `GHOSTTY_AGENT_HEARTBEAT`
  in the agent's environment, and the agent handed its whole environment to
  every shell it spawned. **Every pane inherited the session agent's lock
  identity**, so any agent started from a pane contended for the session
  agent's lock.
- Worse, the hand-started stopgap (`GHOSTTY_AGENT_LOCK` overridden, heartbeat
  not) was writing its own pid into the **session agent's heartbeat file**.
  The takeover protocol reads that file to decide which pid to SIGKILL.

So there are three defects, not one: the guard is role-blind by name, the
takeover is role-blind by identity, and the agent leaks its private control
variables into user shells.

## 1. The role-scoped single-instance guard

### Roles

| Role | Mode | POSIX default lock / heartbeat | Windows mutex |
|---|---|---|---|
| `relay` | `--relay` | `agent.lock` / `agent.heartbeat` | `Global\GhozttyAgentDaemon-<SID>` |
| `listen` | `--listen` (TCP, dev) | `agent.listen.lock` / `agent.listen.heartbeat` | `Global\GhozttyAgentDaemon.listen-<SID>` |
| `listen-unix` | `--listen-unix` (session persistence) | `agent.listen-unix.lock` / `agent.listen-unix.heartbeat` | — (POSIX-only mode) |

Same role excludes (the dual-supervisor incident stays fixed, exit code stays
**183**). Different roles coexist — which is what `main.zig`'s header always
claimed for `--relay` ("coexists with — does not replace — `--listen`").

**The relay role keeps the legacy, unsuffixed names.** Every supervisor that
has ever shipped (the Windows MSI launcher, the SMB deploy watcher, Linux
hosts) runs `--relay`, and a running agent is frequently an older build than
the one starting beside it. An old relay agent holding the legacy name still
excludes a new relay agent across that skew; renaming the relay role would
have let the two coexist and re-opened the incident on the first upgrade. The
Windows fallback chain (SID → username, `Global\` → `Local\`) is unchanged and
applies per role (`Local\GhozttyAgentDaemon` / `Local\GhozttyAgentDaemon.listen`).
The `.role-` separator is a `.`, which never follows `GhozttyAgentDaemon` in a
legacy name, so no user id can make one role's name collide with another's.

### `GHOSTTY_AGENT_LOCK` / `GHOSTTY_AGENT_HEARTBEAT` stay one exact path

An explicit override names **one daemon's identity**, verbatim — no role
suffix is added. This was decided deliberately:

- macOS session agents that are running *right now* (older builds; the
  user's is from Sep 1) hold `~/.config/ghoztty/local-agent/agent.lock` through
  this override. A newer `--listen-unix` agent must contend for that exact path,
  or an upgrade could put two session agents on one socket.
- `wp4_e2e.zig` and `relay/agent_enroll_e2e_test.go` already set both to unique
  temp paths per harness agent; exact paths keep them independent.

The cost — one override shared by two roles still excludes — is exactly the
leaked-environment case, which is fixed at its source (below) and, more
importantly, can no longer kill anything.

### Takeover never crosses roles

`--force-replace`, and the stale-heartbeat takeover, now kill a holder only
when its role is **confirmed equal** to the challenger's. The heartbeat file
records the role (`<pid>\nrole=<role>\n`), and the holder's role is resolved
in this order:

1. the heartbeat's `role=` line;
2. the holder process's own argv (`--relay` / `--listen-unix` / `--listen`),
   read with `KERN_PROCARGS2` on macOS and `/proc/<pid>/cmdline` on Linux —
   this is what identifies an *older* holder that writes no role line;
3. the heartbeat came from this role's **default** path (no override), so it
   is this role's file by construction — the only signal on Windows, and the
   one that keeps self-update (`--force-replace` respawn against a pre-role
   holder) working there;
4. otherwise **unknown — never killed**, not even under `--force-replace`.

A different role → `die` (log, exit 183) regardless of `--force-replace` or
staleness. So a relay agent that inherited the session agent's lock and
heartbeat paths, run with `--force-replace`, refuses and says why
(`held by a listen-unix agent (pid N); GHOSTTY_AGENT_LOCK is probably inherited
from that agent's environment`) instead of SIGKILLing the process that owns
the user's live panes. Decision matrix: `takeoverVerdict` (pure, tested);
role resolution: `resolveHolderRole` (pure, tested).

Older challengers reading a new two-line heartbeat fail to parse it and treat
it as "no heartbeat" → yield. That is the safe direction: an old build can no
longer take over a new holder, and never kills it.

### The agent no longer leaks its control variables

`PtySpawner` strips `GHOSTTY_AGENT_LOCK`, `GHOSTTY_AGENT_HEARTBEAT`,
`GHOSTTY_AGENT_NO_SELFUPDATE` and `GHOSTTY_DEVICE_TOKEN` from the environment
it gives children. The first three are this daemon's private identity; the
last is a credential that a remote viewer's shell has no business reading.
Existing shells keep what they inherited until they restart, which is why the
takeover rule above is the real safety net.

### Which modes take the guard

Unchanged: `--listen`, `--listen-unix`, `--relay`. `--stdio` and `--enroll`
take none.

## 2. macOS hosts when it is enrolled

### Interaction model

There is **no new switch**. Enrollment is the opt-in — it is what puts this
Mac in every chooser on the account — so being enrolled and being reachable
now mean the same thing:

| This Mac's state | Relay agent |
|---|---|
| Signed in, `relay.env` holds a live credential owned by the signed-in account | **running** (LaunchAgent, survives quit/relaunch/reboot) |
| Signed out (sign-out revoked the machine) | stopped, LaunchAgent removed |
| Sign-out could not reach the relay (**pending revocation** armed) | **stopped immediately** — the Mac goes dark locally even though the relay still lists it |
| Suspended (signed out), then the same account signs back in | restored credential → started |
| Credential owned by a **different** account | not started (the app is a guest; not its enrollment to serve) |
| Credential dead (device removed from another client) | stopped; the dead `relay.env` is removed, like an already-revoked sign-out |
| No credential (a client-only Mac — the common case) | not started; nothing installed |
| `GhosttyRelayDisable` / `GHOSTTY_RELAY_DISABLE` | never started, nothing installed |
| Relay can't be reached to confirm ownership | **no change** — whatever was installed stays as it was |
| `session-persistence = false` | irrelevant — the relay agent does not use or need the session agent |

The Mac shows up in the other machine's Cmd-Shift-N chooser as online, and
`ghoztty +new-remote-window` / the chooser opens a shell on it, exactly as
for a Windows host.

### Why a second LaunchAgent, not a second mode on the session agent

The relay agent is its own LaunchAgent job (`com.dzearing.ghoztty.relay-agent`,
debug `com.dzearing.ghoztty.debug.relay-agent`), written by the same
`LocalAgentManager` plist/launchctl machinery as the session agent, with its
own state directory (`~/.config/ghoztty/relay-agent[-debug]/`, holding only its
log). Not one process serving both, because:

- **Sessions are a security boundary.** One agent serving `--listen-unix` and
  `--relay` shares one session store. A relay client could then list and
  ATTACH to the user's local panes. Two processes, two stores.
- **Independent lifecycles.** The relay agent starts and stops with
  enrollment, several times in a session (sign-out, pending revocation,
  restore). The session agent must never restart under the user's panes —
  `LocalAgentManager` deliberately refuses to boot it out while it is alive.
  Changing its argv to add `--relay` would be exactly such a restart.
- **`session-persistence = false`** has no session agent at all, and the
  relay agent must not depend on one.

The two never contend: different roles (above), and the relay job sets no
`GHOSTTY_AGENT_LOCK`, so it uses the relay role's default lock — the same one
a hand-started `ghoztty-agent --relay` uses, so a manual relay agent and the
app's are still mutually exclusive (one device token, one control connection).

### The job

```
ghoztty-agent --relay=<RELAY_BASE from relay.env> --headless --exit-on-revoke
```

- `RunAtLoad`, `KeepAlive = { SuccessfulExit = false }`: restarted after a
  crash or a 183 (throttled by launchd, the documented supervisor heartbeat),
  started at login, **not** restarted after a clean exit.
- `--headless`: never pops a browser for enrollment from a background job; a
  missing credential is an error (exit 1, after which launchd retries —
  but the app only installs the job when a credential exists).
- `--exit-on-revoke` (new, opt-in): two consecutive control dials rejected
  with HTTP 401 (what `/v1/agent/control` answers for an unknown token) mean the credential is dead (revoked from another client, or a
  sign-out on a machine the app wasn't running on). The agent exits 0 and
  launchd leaves it down — it does not keep dialing with a dead credential.
  The Windows tray agent does not pass it and keeps its current behavior (its
  tray Sign-in re-enrolls in place). Opt-in because a running agent is often
  an older build than the app; a flag only the app's own freshly-installed job
  passes needs no capability negotiation.
- `GHOSTTY_AGENT_NO_SELFUPDATE=1`: the bundle owns the binary, as for the
  session agent.
- The relay agent keeps watching `relay.env` (`relay_creds.zig`), so a
  restored credential is adopted without a restart.

### The controller: `RelayHostAgent`

`RelayHostAgent.reconcile()` is the one decision point. It consumes
`LocalMachineEnrollment` — it does not re-implement it:

```
disabled (GhosttyRelayDisable)               → stop
pending revocation armed                     → stop
not signed in                                → stop
no credential in relay.env                   → stop
probe credential (whoami):
  alive, owner == signed-in account          → run
  alive, owner != signed-in account          → stop
  dead (401)                                 → stop, delete relay.env
  unknown (offline / 5xx)                    → leave as is
```

The decision is the pure `RelayHostAgent.decide` (unit-tested); the probe is
`LocalMachineEnrollment.hostingVerdict(accountEmail:)`, which reuses the same
`probeCredential` the revocation and the restore already share, inside the
same serialized queue — so a reconcile can never race a revocation against one
credential file.

**When it runs:** at launch (after the Keychain load), on sign-in (after the
enrollment restore), on sign-out (after the revocation — both outcomes), when a
pending revocation is armed, after every pending-revocation retry, and on every
network-came-back transition.

"Stop" is `launchctl bootout` + delete the plist. `bootout` sends SIGTERM and
waits for the process, so when `signOut` returns the agent is gone — before
`/oauth/signout`, before the UI says "signed out". The relay's own
`deenroll` already severed the control connection; stopping the agent is what
keeps a *running* agent from redialing (with a credential that is dead anyway,
or — for a pending revocation — still alive, which is the case that matters).

"Run" is the session agent's idempotent install: write the plist only when it
changed, `bootstrap` if not loaded, `kickstart` otherwise. A changed plist
(relay base or binary path moved) restarts the relay agent — sessions hosted
for *other* machines are lost in that case, which only happens on a genuine
configuration change, never on an ordinary launch.

### What is not in scope

The Windows box (`MaximusHome`) runs no agent at all (7777/7778 closed, no
relay events). That is a missing MSI install on that machine, not a code
defect here.
