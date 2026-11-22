# Linux (WSL) bring-up: running anything Linux from this box

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load it for any
> `seat: linux` task, anything under `src/apprt/gtk/`, `scripts/linux/` or
> `test/linux/`. The plan and phases are `docs/design/linux-port.md`; this file
> is how to actually run things, test things inside the headless harness, and
> read a crash.

## The one entry point: `scripts\linux\wsl-run.ps1` (T3329)

Every Linux build, test or launch goes through it. Nothing else calls
`wsl.exe`, and nothing in the Windows floor, sweeps or Windows lanes calls it.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -- uname -a
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'zig build -Doptimize=Debug' -Step 'zig build test'
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile my-step.sh     # anything with double quotes
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Plan -- zig build         # print what it would run; starts nothing
```

What it guarantees:

| Guard | Behavior |
|---|---|
| Memory | Exit **2** `WSL-RUN REFUSED Windows has X GB free, under the Y GB floor` when free physical memory is under 16 GB (`-MinFreeGB`, `$env:GHOZTTY_WSL_MIN_FREE_GB`). Checked before any `wsl.exe` call that could boot the VM, and again before every `-Step`. |
| Parallelism | `zig build` inside a step gets `-j<n>`, n = (free - floor) / 3 GB, at least 1, at most the core count, recomputed per step. An explicit `-j` wins. `$GHOZTTY_WSL_JOBS` carries n. |
| Lane | Refused from Windows lanes (a, b, ...). Lane l runs; a person by hand passes `-AllowAnyLane`. |
| Distro | `-d Ubuntu` always (`-Distro` to change it); `docker-desktop` is refused. |
| PATH | `zig-out/bin` first, every `/mnt/*` entry (the Windows PATH WSL appends) dropped, so a bare `ghoztty` cannot reach the user's Windows terminal through interop. |
| Cleanup | If no distro was running before the call, the distro is terminated and the VM shut down afterwards (the user's `vmIdleTimeout=-1` would otherwise hold the memory forever). `-KeepRunning` skips it. A VM someone else started is left alone. |

Exit codes: the step's own; 2 refused; 3 the distro is not installed.

**Never edit `%USERPROFILE%\.wslconfig`.** It is the user's (`memory=48GB`,
`swap=16GB`, `vmIdleTimeout=-1`) and tuned for their other WSL work.

Acceptance: `test\linux\wsl-run-guard.ps1` (refusals, argv, job arithmetic,
plan contents) - it never boots WSL, and asserts so.

## Where the repo lives in WSL: the in-distro clone, by a mile

`-Repo clone` (default) runs in `~/ghoztty-l` inside the distro's ext4
filesystem, synced to this worktree's **HEAD commit** on every call (fetched
from the main repo's common `.git`, then a detached checkout). Uncommitted
edits are NOT there: commit first, or use `-Repo mnt`.

`-Repo mnt` runs in `/mnt/d/git/ghoztty-l` - the live tree - with
`GIT_DIR` pointed at the worktree's git dir in `/mnt` form (the worktree's
`.git` file names a Windows path, `D:/git/ghoztty/.git/worktrees/ghoztty-l`,
which Linux git reports as "not a git repository") and
`GIT_OPTIONAL_LOCKS=0`, so a Linux `git status` never rewrites the index the
Windows lane's git owns.

Measured 2026-11-21 on this box (Ubuntu 24.04, WSL kernel 5.15.167, same commit
a8e7bd2d1, 1764 files under `src/` + `pkg/`):

| Operation | `/mnt/d/...` | `~/ghoztty-l` |
|---|---|---|
| `git status --porcelain` (first) | 85.76 s | 0.16 s |
| `git status --porcelain` (warm) | 41.83 s | 0.01 s |
| `find src pkg -type f` | 0.31 s | 0.00 s |
| `grep -r` over `src/*.zig` | 1.21 s | 0.01 s |
| `tar -cf /dev/null src pkg` (read every file) | 1.12 s | 0.00 s |
| `cp -r src /tmp` | 5.12 s | 0.05 s |
| create 2000 small files | 2.80 s | 0.02 s |
| `rm -rf` those 2000 | 1.02 s | 0.01 s |

Zig's cache is thousands of small files written and stat'ed, which is exactly
the 100x+ row.

**`zig build` does not work on `/mnt` at all** (measured in T3330, 2026-11-21).
On the live tree it fails after about 20 s with `failed to rename compilation
results ('.zig-cache/tmp/...') into local cache ('.zig-cache/o/...'):
AccessDenied`. Zig's atomic cache rename does not survive the Windows drive
mount. So **build in the clone**: commit first, then `-Repo clone` (the
default). In the clone the GTK debug build took 24 s when the global cache was
already warm, and `test/linux/gtk-smoke.sh` takes about 1 minute end to end.
Keep `-Repo mnt` for steps that do not build, such as `setup-distro.sh`.

## Distro setup (one time, idempotent): `scripts/linux/setup-distro.sh` (T3330)

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Repo mnt -CommandFile scripts\linux\setup-distro.sh
```

It ends `SETUP OK` and prints each tool's version. Re-running it is a no-op
when everything is present. What it puts where:

- **apt** (the exact line it runs for whatever is missing):

  ```
  apt-get install -y --no-install-recommends libgtk-4-dev libadwaita-1-dev gettext libxml2-utils python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 mesa-utils weston git curl xz-utils
  ```

  Ubuntu 24.04 gives GTK 4.14.5 and libadwaita 1.5.0.
- **zig 0.15.2** (`build.zig.zon` `minimum_zig_version`) in `~/.local/zig-0.15.2`.
- **blueprint-compiler 0.16.0** in `~/.local/blueprint-compiler-0.16.0`, a
  checkout of the tag. `src/apprt/gtk/build/blueprint.zig` requires 0.16 and
  Ubuntu 24.04 ships 0.12. Two traps it handles: GNOME's gitlab answers an
  automated clone with HTTP 406, so it clones GNOME's GitHub mirror; and a
  source checkout answers `--version` with `uninstalled`, which the build's
  version check rejects, so the wrapper answers with the tag's number.
- `~/.local/ghoztty-tools/bin` links both, and `wsl-run.ps1` puts that dir on
  PATH right after `zig-out/bin`. Nothing else in `~` is touched.

A `-Repo mnt` step has `GIT_DIR`/`GIT_WORK_TREE` exported at this worktree, so
any other `git clone` or `git init` inside it needs `env -u GIT_DIR -u
GIT_WORK_TREE` (or it fails with `working tree ... already exists`).

## Build and smoke test (T3330)

```
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell
```

`-fno-sys=gtk4-layer-shell` builds that library from source: Ubuntu 24.04 does
not package it, and the default links the system one. The output is
`zig-out/bin/ghoztty`. `-Doptimize=Debug` is required for the same reason as on
Windows: the debug app id is `com.dzearing.ghoztty-debug` and the debug socket
is `ghostty-debug-<uid>.sock`, so a release-mode dev build would answer on the
installed app's names.

The acceptance script builds and launches it:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\gtk-smoke.sh
```

It opens the window in a **private headless Weston** (the shared harness
below: its own `XDG_RUNTIME_DIR` and socket), never in WSLg, so no window ever lands on the
user's desktop or takes focus. It checks the build, the debug app id, that the
window's shell ran on a pty, that the app stays up, and that OpenGL loaded.
It ends `GTK SMOKE: ALL PASS` or `GTK SMOKE: <n> FAILURE(S)`.

**The GPU is reachable, but Mesa does not pick it by default.** Measured
2026-11-21: `glxinfo -B` and the app both report `llvmpipe` (software) unless
`GALLIUM_DRIVER=d3d12` is set. With it, both report `D3D12 (NVIDIA GeForce RTX
4090)` and the app loads OpenGL 4.6. `/dev/dxg` and `/usr/lib/wsl/lib` are
present. The smoke script sets the variable when `/dev/dxg` exists. The app
does not set it on its own yet; that is T3350.

## GUI tests: the headless harness, `test/linux/lib/headless.sh` (T3333)

**Never launch the Linux app into WSLg.** WSLg draws every Linux window into an
ordinary Windows window on the user's desktop and gives it focus - exactly what
go.md's first rule forbids. A wsl-run step inherits WSLg's environment
(`DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0`, `XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir`),
so a bare `./zig-out/bin/ghoztty` in a step WOULD pop a window. Every Linux GUI
test runs inside the harness instead; it is the analog of
`test/win32/lib/TestDesktop.ps1`.

```bash
. "$PWD/test/linux/lib/headless.sh"   # a -CommandFile step's cwd is the repo root
hl_check_init
hl_start                               # private `weston --backend=headless`
app=$(hl_ghoztty)                      # absolute path, refuses a non-ELF
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'tty > "$XDG_RUNTIME_DIR/m"; sleep 60'
hl_wait_for 20 test -s "$XDG_RUNTIME_DIR/m"
hl_check "my check" $?                 # PASS/FAIL line, counted
grep -q 'loaded OpenGL' "$APP_LOG"     # each launch logs to $HL_RUNTIME/<var>.log
hl_finish "MY SCRIPT"                  # stops everything, '<LABEL>: ALL PASS', exit 0/1
```

| Piece | What it guarantees |
|---|---|
| `hl_start [w] [h]` | `XDG_RUNTIME_DIR` = a fresh `mktemp` dir under `/tmp` (0700); socket `wayland-hl-<pid>`, so concurrent harnesses never share one; `DISPLAY`/`WAYLAND_SOCKET` unset; `GDK_BACKEND=wayland` so GTK cannot fall back to X11; `GALLIUM_DRIVER=d3d12` when `/dev/dxg` exists. EXIT/TERM/INT traps run `hl_stop`. |
| `hl_launch <var> <cmd...>` | Re-checks isolation first and **refuses with exit 4** (`HEADLESS REFUSED: <why> - nothing was launched`) if anything points back at WSLg. Records the pid in `<var>`, the log in `<var>_LOG`. |
| `hl_isolation_problem` | Prints the first reason the environment is not isolated, or nothing. Pure. |
| `hl_ghoztty [root]` | `<root>/zig-out/bin/ghoztty` by absolute path; refuses a missing or non-ELF file (the interop PATH trap below). |
| `hl_weston_sockets`, `hl_env_is_private <pid>` | Evidence that an app connected to the private Weston: its socket-fd count rises, and the app's own `/proc/<pid>/environ` names only it. |
| `hl_stop` | Kills every launched process and its children, then Weston, then removes the runtime dir. Idempotent. |

Acceptance (it builds the GTK app, then proves the refusals and the isolation,
and that a SIGTERMed harness leaves no Weston, app or dir behind):

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\headless-harness.sh
```

Ends `HEADLESS HARNESS: ALL PASS` (15 checks, about a minute warm).

**What the harness cannot give you yet.** There is no screenshot or input path:
Weston headless has no capture a client can ask for, and Wayland has no global
input injection. Pixels come from the app's own render (the translation table's
GTK snapshot row) and input from the CLI (`+send-keys`) once L6/L7 land; until
then a GUI test asserts on the app's log, its pty and its process tree.

**Running the app by hand** is a harness run too: there is no "just open it"
path on this box, because the only display is the user's. To look at it, the
person at the keyboard runs it into WSLg themselves.

## The interop PATH trap

Inside WSL the Windows `PATH` is appended by default, so a bare `ghoztty` can
resolve to the Windows `ghoztty.exe` through interop and drive the user's
installed Windows terminal. `wsl-run.ps1` drops every `/mnt/*` PATH entry and
puts `zig-out/bin` first, and tests still name the Linux binary by full path
(`hl_ghoztty`). The same rule as Windows' CreateProcess lesson: never let a
lookup decide which binary a test drives.

## Crash diagnostics

Measured 2026-11-21 in the distro: no `gdb`, no `coredumpctl`, `ulimit -c` is
0, and `core_pattern` is `|/wsl-capture-crash %t %E %p %s` (WSL's own crash
collector). So a crashing Linux build leaves no core by default, and:

- **The Zig panic trace is the first evidence.** A debug build prints the panic
  message and a symbolized stack to stderr - inside the harness that is
  `$<var>_LOG`. Grep it for `panic`/`reached unreachable` before it is removed
  (`hl_finish` deletes the runtime dir), or copy it out first.
- **GTK/GLib warnings** land in the same log; `G_DEBUG=fatal-criticals` turns
  a critical into a trap with a stack when one is the suspect.
- **For a native crash with no Zig trace** (a segfault in GTK, Mesa, a C
  dependency), install gdb (`apt-get install -y gdb`, a one-time distro change,
  so say so in the task) and run the app under
  `gdb -batch -ex run -ex 'thread apply all bt' --args "$app" ...` inside the
  harness. A core file needs `ulimit -c unlimited` in the step plus a
  `core_pattern` the distro owns, and that file is system-wide: leave it to the
  user.

## The Linux floor: `scripts/linux/floor.sh` (T3331)

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile scripts\linux\floor.sh
```

The same two shared-core lanes `floor-lane.ps1` runs as `lib` and `none` on
Windows, built natively in the clone: `zig build -Dapp-runtime=none` and
`zig build test -Dapp-runtime=none`. One `LANE <name> PASS|FAIL|STALL` line
each, then `LINUX FLOOR: ALL PASS` or `LINUX FLOOR: <n> FAILURE(S)`; full logs
are `/tmp/linux-floor-<lane>.log` in the distro. `FLOOR_LANES=none` picks
lanes, and `FLOOR_LANE_TIMEOUT` (1800 s) bounds each one. It tests the
committed HEAD, so commit first.

**What breaks here that Windows and macOS never see.** The none lane compiles
the `src/apprt/win32/` and `src/renderer/` pure-logic tests too, and Linux is
the first host where they meet both an LP64 C ABI and a POSIX `std.fs.path`:

- `std.os.windows.HRESULT` is `c_long`, which is 64 bits on Linux (32 on
  Windows), so `@bitCast(@as(u32, 0x8...))` into it does not compile. Spell a
  Win32 `LONG`/`HRESULT` as `i32`.
- `std.fs.path.dirname`/`basename` are the POSIX ones on Linux and find no
  `\`, so a test (or helper) handling a Windows path panics on `.?`. Use
  `dirnameWindows`/`basenameWindows` for a value that IS a Windows path, and
  `std.fs.path.sep_str` when a test builds a path on the real disk.
- `close(2)` on Linux never wakes a `read` blocked on the same fd in another
  thread (macOS does), so code that "unblocks a reader by closing" hangs
  here. `ssh_transport`'s `ChildStream.close` does exactly that: T3354, and
  its test is skipped on Linux until that lands.
- A panic stops that test process and the runner restarts after it, so one
  crash can hide the next: re-run until the lane is green, not until the first
  named failure is gone.

## The agent on Linux (T3332)

`floor.sh` carries two agent lanes, `agentx` (`zig build agent`) and `agent`
(`zig build test-agent`), both with `-Dapp-runtime=none`: under the default gtk
runtime the build's configure step wants a system `gtk4-layer-shell`, even for
the GUI-free agent (T3358). Measured 2026-11-21: test-agent 2839 passed / 40
skipped (the skips are Windows-only tests) in about a minute.

- **glibc has no `getpeereid`.** The Mac binds it as an `extern "c"`; on Linux
  the link fails with `undefined symbol: getpeereid`. `peerUid` in
  `src/remote/agent/main.zig` reads `SO_PEERCRED` (a local `struct ucred`, which
  zig 0.15's std does not declare) instead, and the real-socket test
  `listen-unix: peerUid on a real accepted connection` covers it.
- The rest already had Linux branches: `/proc/<pid>/cmdline` and `/exe` in
  `single_instance.zig`, `/proc` sampling in `proc.zig` and `metrics.zig`,
  `/proc/<pid>/cwd` in `pty_child.zig`, `xdg-open` in `enroll.zig`.

Acceptance that a pane outlives its client (the GUI half is L8, T3337):

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\agent-survive.sh
```

It starts the agent by hand on an ephemeral loopback port with a private
`HOME`/`XDG_RUNTIME_DIR`, opens a session with `remote-test-client
--open-command=... --hold=1` whose command writes a heartbeat file, checks the
heartbeat still advances after the client exits, then CLOSEs the session by id
and checks it stops. Ends `AGENT SURVIVE: ALL PASS`.

## Distro state (2026-11-21)

- Ubuntu 24.04.1 LTS, runs as `root` (`$HOME=/root`), 32 cores, 47 GB visible.
- zig 0.15.2 and blueprint-compiler 0.16.0 are installed by `setup-distro.sh`
  (above). Inside a step `command -v zig` names the wrapper function; ask
  `type -P zig` for the binary.
- git is `/usr/bin/git`. The Windows `ghoztty.exe` is not reachable from a step
  (PATH guard).
- The user runs other work in this distro (`~/*.sh`, a model server): do not
  touch `~` beyond `~/ghoztty-l` and the `~/.local` entries named above.
