# Linux (WSL) bring-up: running anything Linux from this box

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load it for any
> `seat: linux` task, anything under `src/apprt/gtk/`, `scripts/linux/` or
> `test/linux/`. The plan and phases are `docs/design/linux-port.md`; this file
> is how to actually run things, test things inside the headless harness, and
> read a crash.

> **The quality bar is the Mac, on a real screen** (user, 2026-11-25; T3793).
> Functional parity in the headless Weston is not "done": the first look at
> the Linux build on the real WSLg display found a see-through window (T3783),
> a too-bold title (T3791) and a resize that felt slow (T3792), all green in
> the harness. A visible change is judged side by side against the Mac
> (`docs/reference/` for its values) on the real WSLg screen via
> `scripts\linux\open.ps1`. That puts a window on the user's display, so it
> runs only when the user has asked for it, never from a lane, sweep or floor
> step. Until then, record that half as NOT RUN and park the task on the
> user; the automated stand-in is `open.ps1 -Check`'s on-screen pixel
> assertion.

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
| Lease (T3721) | A `-KeepRunning` call that found the VM idle writes a lease (`temp\wsl-run\lease.json`: distro, the VM's `boot_id`, lane, time). **`wsl-run.ps1 -Release` gives it back**: terminates the distro and shuts the VM down when nothing else runs. It refuses (exit 2) with no lease, and while any WSL session is attached from Windows (a `wsl.exe` process - the user's shells live in the same Ubuntu); a lease whose VM has restarted since is `RELEASE STALE`, cleared, and nothing is stopped. `-LeaseStatus` reports it without calling `wsl.exe`. `-NoLease` (what `open.ps1` passes) keeps a person's VM up and records nothing, so no lane can release it. Step 0's claim and `parity-tasks.ps1 validate` print `WSL LEASE HELD` while one is held. |

Exit codes: the step's own; 2 refused; 3 the distro is not installed.

**Never edit `%USERPROFILE%\.wslconfig`.** It is the user's (`memory=48GB`,
`swap=16GB`, `vmIdleTimeout=-1`) and tuned for their other WSL work.

Acceptance: `test\linux\wsl-run-guard.ps1` (refusals, argv, job arithmetic,
plan contents, and section L for the lease and `-Release`, all with WSL state
faked) - it never boots WSL, and asserts so.

**A turn that used `-KeepRunning` ends with `-Release`** once its last Linux
step is done; that is the only sanctioned way to give the memory back.

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
  apt-get install -y --no-install-recommends libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev gettext libxml2-utils python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 mesa-utils weston git curl xz-utils desktop-file-utils xdg-utils patchelf dpkg-dev
  ```

  Ubuntu 24.04 gives GTK 4.14.5, libadwaita 1.5.0 and WebKitGTK 2.52.6 (`webkitgtk-6.0`, the GTK4 build, for viewer panes).
- **zig 0.15.2** (`build.zig.zon` `minimum_zig_version`) in `~/.local/zig-0.15.2`.
- **blueprint-compiler 0.16.0** in `~/.local/blueprint-compiler-0.16.0`, a
  checkout of the tag. `src/apprt/gtk/build/blueprint.zig` requires 0.16 and
  Ubuntu 24.04 ships 0.12. Two traps it handles: GNOME's gitlab answers an
  automated clone with HTTP 406, so it clones GNOME's GitHub mirror; and a
  source checkout answers `--version` with `uninstalled`, which the build's
  version check rejects, so the wrapper answers with the tag's number.
- **go 1.26.0** (`relay/go.mod` says `go 1.26`) in `~/.local/go-1.26.0`, the
  official linux-amd64 tarball (T3670). Section Y of
  `test/linux/cli-remote-window.sh` builds the local rendezvous relay from
  `relay/` with it and dials a real relay end to end; without it that section
  fails Y0 rather than skipping.
- `~/.local/ghoztty-tools/bin` links all three, and `wsl-run.ps1` puts that dir on
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
present. **The app picks it itself** (T3350, `src/apprt/gtk/wslg_gpu.zig`):
before GTK initializes, when `/dev/dxg` exists and none of `GALLIUM_DRIVER`,
`MESA_LOADER_DRIVER_OVERRIDE` or a true `LIBGL_ALWAYS_SOFTWARE` is set, it
sets `GALLIUM_DRIVER=d3d12`, brings GDK's GL up, and removes the variable
again, so shells (and the agent that hosts them) and WebKit's web processes
never inherit it. A driver the user exported wins and reaches their shell
untouched. Log lines: `wslg: setting GALLIUM_DRIVER=d3d12 ...` and
`wslg: GPU driver left to the environment ...`. Nothing in `test/linux`
exports the variable to the app any more (only Weston gets it), so every GUI
test exercises this default; `gtk-smoke.sh` S9-S13 prove both paths.

**Root has no Wayland socket under WSLg, so the app finds WSLg's** (T3783,
`src/apprt/gtk/wslg_display.zig`). WSLg's socket is
`/mnt/wslg/runtime-dir/wayland-0`, linked into the DEFAULT user's
`/run/user/<uid>` only; root (how this box drives the distro) inherits
`WAYLAND_DISPLAY=wayland-0` with nothing at `/run/user/0/wayland-0`. GDK then
fell back to X11 (XWayland), where d3d12 cannot present (`MESA: error: Failed
to attach to x11 shm`, every frame dropped): a see-through window while the
app's own render was fine (user report 2026-11-25). Now, before GTK opens its
display, when the socket libwayland would try is missing and WSLg's exists
(and neither `WAYLAND_SOCKET` nor a `GDK_BACKEND` without wayland says
otherwise), the app sets `WAYLAND_DISPLAY` to WSLg's socket by absolute path,
then puts the original value back once the display is open, so shells see
what WSLg gave them. Not `XDG_RUNTIME_DIR`: the CLI socket lives there and
every `+verb` client resolves it from its own environment. Log: `wslg: no
Wayland socket at the runtime dir's wayland-0; connecting to WSLg's ...`. If
it still lands on X11 under WSLg, the app drops its own d3d12 choice before GL
comes up (software GL draws) and logs one `wslg: the display is X11 ...`
warning with the remedy; a user's own `GALLIUM_DRIVER=d3d12` there is kept and
warned about. A debug build reads "WSLg's socket" from
`GHOZTTY_DEBUG_WSLG_SOCKET`: `hl_start` points it at a non-socket inside the
harness dir (and `hl_isolation_problem` refuses anything outside it), so no
test can reach the real WSLg through this fallback; `test/linux/wslg-display.sh`
points it at the private Weston and proves the path (W1-W2 are the control).
The on-screen pixel check is a person's command (T3785).

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
| `hl_start [w] [h]` | `XDG_RUNTIME_DIR` = a fresh `mktemp` dir under `/tmp` (0700); socket `wayland-hl-<pid>`, so concurrent harnesses never share one; `DISPLAY`/`WAYLAND_SOCKET` unset; `GDK_BACKEND=wayland` so GTK cannot fall back to X11; Weston (not the app) renders with `GALLIUM_DRIVER=d3d12` when `/dev/dxg` exists - the app picks its own GPU (T3350). EXIT/TERM/INT traps run `hl_stop`. |
| `hl_launch <var> <cmd...>` | Re-checks isolation first and **refuses with exit 4** (`HEADLESS REFUSED: <why> - nothing was launched`) if anything points back at WSLg. Records the pid in `<var>`, the log in `<var>_LOG`. |
| `hl_isolation_problem` | Prints the first reason the environment is not isolated, or nothing. Pure. |
| `hl_ghoztty [root]` | `<root>/zig-out/bin/ghoztty` by absolute path; refuses a missing or non-ELF file (the interop PATH trap below). |
| `hl_weston_sockets`, `hl_env_is_private <pid>` | Evidence that an app connected to the private Weston: its socket-fd count rises, and the app's own `/proc/<pid>/environ` names only it. |
| `hl_stop` | Kills every launched process and its children, then the compositor, then removes the runtime dir. Idempotent. |
| `hl_start_seat [w] [h]` | `hl_start` with a headless **sway** instead of Weston (T3620), for a test that needs a `wl_seat` - Weston headless has none. Same runtime dir, isolation, refusals and cleanup; the socket is whatever sway picks inside the private dir (`HL_SOCKET` is read back), `SWAYSOCK` is exported, `HL_WESTON_PID` holds sway's pid. No input devices, no Xwayland, pixman renderer. See "A seat, for cross-client paste" below. |
| `hl_key_serial` | Under `hl_start_seat` only (refuses otherwise): one `Shift_L` key event to the focused window through a short-lived virtual keyboard (`wtype`). Without it no copy ever leaves the app. |
| `hl_seat_keyboard`, `hl_seat_has_keyboard`, `hl_seat_keyboard_stop` | Under `hl_start_seat` only (T3713): a keyboard that STAYS on the seat - a background `wtype` parked in a one-hour sleep between two `Shift_L` taps, killed by `hl_stop`. Without it the seat's capabilities are 0, no window ever gets `wl_keyboard.enter`, and GTK (whose is-active follows keyboard focus, not sway's own focus) never calls a window active. See "The seat checks" below. |

Acceptance (it builds the GTK app, then proves the refusals and the isolation,
and that a SIGTERMed harness leaves no Weston, app or dir behind):

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\headless-harness.sh
```

Ends `HEADLESS HARNESS: ALL PASS` (25 checks, about a minute warm; H16-H21 are
the screenshots below, H22-H25 the seat compositor: `hl_key_serial` refuses
under Weston, a GTK client sees no seat under Weston and one under
`hl_start_seat`, and a SIGTERMed seat harness leaves no sway behind).

**A seat, for cross-client paste: `hl_start_seat` (T3620).** A Wayland
selection is offered to other clients only through a `wl_seat`, and Weston's
headless backend creates none (a GTK 4 client there reports
`get_default_seat() == None`, H23). Weston's VNC and RDP backends do create a
seat, but they insist on TLS keys and open a TCP listener, so they were
rejected. sway 1.9 with `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1`
has a seat with no devices, and it speaks wlr-data-control, so `wl-paste`
reads the selection without needing focus of its own. What it does not do on
its own: **wlroots refuses a `set_selection` whose serial the client was never
given** (sway's debug log: `Rejecting set_selection request, serial 0 was
never given to client`). GTK claims a selection with its last key-press or
button serial, and with no input devices that serial stays 0, so every copy
stays inside the app. `hl_key_serial` fixes that with one real key event. A
modifier-only tap (`wtype -M shift -m shift`) is not enough, because it sends
`wl_keyboard.modifiers`, not `.key` (measured with `WAYLAND_DEBUG=1`). The
press-key and pane-mouse seams do not help either: they inject inside the app,
so Wayland never issues a serial for them. Packages: `sway wtype wl-clipboard`
(in `setup-distro.sh`). The GTK app renders fine on the pixman sway, since
the copy-reflow run captures panes under it as usual.

**The seat checks (T3713): what the seat answers that Weston cannot.**
Measured on sway 1.9 with no input devices: the seat reports capabilities 0,
and sway focuses every newly mapped window itself, but with no keyboard no
window ever gets `wl_keyboard.enter`, so GTK never calls one active and every
`--focus` logs a decline. With `hl_seat_keyboard` holding a keyboard: a
`+new-window --focus` is activated, a `--focus` on an existing, older window
raises it (`hl_start_seat` writes `focus_on_window_activation focus`; sway's
default `urgent` only marks the window), and text typed with `wtype` runs in
the focused pane through the real `wl_keyboard` path. A popover (the
sidebar's window menu) stays open - sway grants the `xdg_popup` grab even at
serial 0, where Weston closes it at once. What it still cannot do: a pointer.
`swaymsg seat seat0 cursor set|press|release` reaches no client while the seat
has no pointer device, `wtype` makes only keyboards and `wlrctl`'s virtual
pointer lives for one call, so a drag cannot be held - T3847 builds a held
virtual pointer. Two sway facts a check must allow for: a raise sent while
sway is still focusing a window it just mapped is lost (wait ~2s), and sway
tiles windows side by side, so `workspace_layout tabbed` keeps each one wide
enough for the sidebar to stay expanded.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-seat.sh
```

Ends `CLI SEAT: ALL PASS` (12 checks: S4-S5 the no-keyboard control, S6-S7
activation, S8 real keys, S9-S10 the popover); `NEGATIVE=1` never takes the
keyboard and must fail S6, S7 and S8.

**Screenshots: `hl_screenshot` (T3359).** Weston headless has no capture a
client can ask for and Wayland has no global one, so the picture comes from
the app's OWN render: the debug-only `capture-pane` IPC seam - win32's wire
shape (T275), no CLI verb on either platform, a release build answers
`unknown action`. The GTK half renders the widget through
`src/apprt/gtk/pane_snapshot.zig` (`render`); the pure half is
`src/apprt/gtk/capture_seam.zig` (none lane).

```bash
pane=$(hl_first_pane "$app")                       # first pane id from +list
hl_screenshot "$pane" "$HL_RUNTIME/p.png"          # one pane (terminal or viewer)
hl_screenshot "$pane" "$HL_RUNTIME/w.png" --window # its whole window
hl_screenshot "$pane" "$HL_RUNTIME/s.png" --width=200 --height=100
hl_png_stats "$HL_RUNTIME/p.png" 255 0 0           # w=800 h=512 colors=2 match=0.972
hl_ipc capture-pane --target=x --path=/tmp/y.png   # any raw request; prints the reply
```

| Helper | What it does |
|---|---|
| `hl_socket` | The harness app's socket, `$XDG_RUNTIME_DIR/ghostty-debug-<uid>.sock`. |
| `hl_ipc <action> [arg...]` | One raw request (4-byte big-endian length + JSON each way); prints the reply, exit 1 when nothing answered. For seams with no CLI verb. |
| `hl_screenshot <target> <png> [--window] [--width=N] [--height=N]` | Prints the reply; 0 only when it says success AND the file is a PNG. |
| `hl_png_stats <png> [r g b]` | Pure-python decode: `w= h= colors=<distinct> match=<fraction within 8 of r,g,b>`. |
| `hl_first_pane <app>` | The first pane id `+list --json` names. |

Reply: `path width height bytes x y client_width client_height scope`.
Differences from win32, both because a GTK window is one widget tree: `--window`
captures the whole window in one render (win32 composes one from pane
captures and a `PrintWindow`, T778), and `x`/`y` are the pane's origin INSIDE
its window in device pixels, since Wayland gives a client no screen
coordinates. A viewer pane is captured too (WebKit content included). The first
capture logs one harmless GTK warning, `Trying to snapshot GtkRevealer ...
without a current allocation` (a collapsed revealer in the pane). Acceptance:
H16-H21 of `test/linux/headless-harness.sh` (a pane paints itself 24-bit red
and the shot must be over half red, at its own size, inside its window's shot,
and scaled).

Input still comes from the CLI (`+send-keys`): Wayland has no global input
injection.

**Running the app by hand**: there is no "just open it" path for a loop,
because the only display is the user's. For the person at the keyboard there
is one command (2026-11-24, after three days in which nobody had seen the port
on a real screen):

```powershell
powershell -NoProfile -File scripts\linux\open.ps1          # lane l's latest build, on screen via WSLg
powershell -NoProfile -File scripts\linux\open.ps1 -Build   # rebuild lane l's tree first
powershell -NoProfile -File scripts\linux\open.ps1 -Stop    # close it (the agent keeps its sessions)
```

It goes through `wsl-run.ps1 -AllowAnyLane -KeepRunning`, runs
`~/ghoztty-l/zig-out/bin/ghoztty` with `LD_LIBRARY_PATH=zig-out/lib` (the
from-source gtk4-layer-shell; without it the binary dies with
`libgtk4-layer-shell.so: cannot open shared object file`), and logs to
`/tmp/ghoztty-open.log`. No lane calls it: it puts windows on the user's
display, which is the user's to ask for.

## The CLI socket (T3335)

The GTK app serves the same Unix socket the CLI dials, derived in ONE place
for server and clients: `ipc_client.endpointPath` (`src/os/ipc_client.zig`) -
`<dir>/ghostty[-debug]-<uid>.sock`, where `<dir>` is `$XDG_RUNTIME_DIR` on
Linux when set, else `$TMPDIR`, else `/tmp` (the Mac keeps `$TMPDIR`, which
its Swift server binds). Inside the headless harness that is the harness's
private runtime dir, so a test app can never meet the user's.

- `IpcServer.zig` is the transport: chmod 0600 before `listen`, one accept
  thread, each request run on the GTK main thread through `glib.idleAdd`.
  A live socket at the path is left alone (the app logs `another instance
  already serves`); a stale one of ours is replaced; anything else is refused.
- `IpcHandlers.zig` plugs into the shared `apprt/ipc/server.zig` dispatcher,
  and serves `+read`/`+send-keys` through the shared verb bodies in
  `apprt/ipc/verbs.zig` (T3361): GTK supplies only the model (`Terminal`
  over the core Surface via `apprt/ipc/core_terminal.zig`, `lookupTerminal`,
  `input_line_ends = .pty`), so its argument handling, failure sentences and
  replies are win32's by construction. `+close`/`focus` (T3374) and
  `+new-window`/`+split`/`+rename` plus `+list`'s split-tree walk (T3375)
  are shared the same way: this file only opens the window or pane
  (`openWindow`, `createSplit`) and builds a `+list` leaf. A new verb body
  goes into `verbs.zig` first, not into this file.
  `+list`, `+version`, `+send-keys`, `+read`, `+new-window`, `+split`,
  `+rename`, `+close`, `+rearrange`, `+reload` (a viewer pane, T3413;
  `--config`, T3369), `+set-banner`, `+set-state` (T3339) and the
  `focus` and `handoff-quit` actions are real; every other verb answers
  `+<verb> is not served by the Linux app yet (<task>)`, naming the card that
  brings it (T3597 remote). `+stash` / `+restore` are real since T3596
  (below).
- **`+stash` / `+restore` (T3596)** are win32's T1827 bodies
  (`gtk/ipc_stash.zig`, Mac `handleStash`'s refusal sentences byte for byte)
  over the GTK split tree. A stashed pane stays a LEAF of its tab's tree -
  shell running, every verb still reaching it, `+list` saying
  `stashed: true` - and only the layout skips it: the mark is
  `Surface.stash_seq` (on the instance, so win32's pure `pane_stash.zig` reads
  it off any leaf), `pane_stack_grid.buildWith(.visible)` collapses a split
  with a stashed side into the other, and `SplitTree.onRebuild` gives the
  pane no card (its old card goes with the old stage; a restore builds a new
  one, the path a close undo takes). `SplitTree.setTree` runs
  `pane_stash.normalize` after every tree change, so a tab always shows a
  pane: a close that leaves only stashed panes brings the top one back,
  focused. Stashing the focused pane hands focus to the neighbor a close
  would pick, ON SCREEN (`gotoVisible` over `pane_stash.visibleClone`, which
  keyboard navigation uses too); a background pane's stash leaves focus
  alone. `+restore` puts the pane back in the slot it left and moves focus
  only with `--focus`. The last pane on screen and a Quick Terminal pane are
  refused; both verbs are idempotent. The sidebar keeps a dimmed row for a
  stashed pane (`pane-sidebar-stashed`, the seam's `stashed`), and a click on
  it restores and focuses it. Keys: `stash_pane` is **Ctrl+Shift+M** on
  Linux (Windows' chord), `restore_stashed_pane` (top of the stash, focused)
  has no default, as on the Mac. **The spatial verbs act on what is on show
  (T3667, win32 T1827):** a keyboard resize runs `SplitTree.resize` on
  `pane_stash.visibleClone` and lifts the ratios back (`liftRatios`), so the
  divider that moves is one the user can see and a collapsed split keeps its
  ratio; `equalize_splits` does the same with `equalize`; `swap_split` picks
  its partner with `gotoVisible`, so a stashed pane is never swapped in; the
  pane-drop resolver's hidden predicate (`pane_drop_apply.stashed`) is
  `pane_stash.isStashed`, so "would this drop change anything" and a gap's
  sides are judged over the panes on show. **Alt-click** on a stashed row of
  the tab on show (`SplitTree.exchangeStashed`, `pane_stash.exchange`, win32
  T1845) swaps it with the focused pane: it takes that slot, focused, and
  the focused pane takes its place in the stash. GTK4's button `clicked`
  carries no event state, so the row reads Alt off the seat's keyboard
  (`altHeld`); the seam is `pane-sidebar --click=alt:<row id>`. Anywhere
  else an Alt-click is a click. The sidebar lists stashed panes in a tray
  after the others, and a row dragged into or out of it stashes or
  restores (T3698, below under the pane sidebar).
  Acceptance: `wsl-run.ps1 -CommandFile test\linux\cli-stash.sh`, ends `CLI
  STASH: ALL PASS` (37 checks; V0-V5 and A1-A2 are T3667's);
  `wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/cli-stash.sh'`
  (a Windows `$env:NEGATIVE` never reaches WSL) presses Ctrl+Shift+N and must
  fail K1 (and X1, which builds on it).
- **`handoff-quit` (T3595)** is win32's T1070 server half: the request a
  launch of ANOTHER build sends when the user answers "Switch". No CLI verb -
  only a launch carries the `handoff` identity. Refused (shared
  `ipc_handoff.refuseHandoffQuit`) without one, and for the same build (same
  commit, whatever the exe path). Otherwise the reply goes out first and
  150 ms later the app runs the ordinary `quitNow`: layout saved, every
  agent-hosted pane detached, so the build taking over re-attaches the same
  shells. `+version` carries `handoff_quit: true` and `session_persistence`
  (a quit with persistence off ends the shells - what the launch tells the
  user before they choose). Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\cli-handoff-quit.sh`, ends `CLI HANDOFF QUIT: ALL PASS` (17
  checks).
- **The launch half: Switch / Open Window / Cancel (T3598)** is win32's
  T1023/T1070 `handoffChoice` + `takeOverEndpoint`. `Application.run` calls
  `launch_handoff.decide` BEFORE GApplication registration (a Switch must
  still be able to become the primary instance): it asks whoever serves the
  socket for `+version` and, only when that is a DIFFERENT build (shared
  `ipc_handoff.mismatchPrompt`; same commit = same build, whatever the path),
  shows a parentless `GtkAlertDialog` - [Switch] [Open Window] [Cancel], Enter
  on Open Window, Escape = Cancel, no Switch against a build that does not
  advertise `handoff_quit`. Switch sends `handoff-quit`, waits up to 20 s for
  the pid and 5 s for the socket to stop answering, then registers and starts
  as usual, so its own launch restore re-attaches the panes the old build
  detached. Open Window forwards `+new-window --focus` (plus the launch's
  `-e`/`--command` and cwd, `launch_handoff_rules.forwardArgs`) with the
  launch's identity, and exits 0. Cancel exits 0. Every failure joins, and a
  join nobody answers starts the launch as before. The same build is never
  asked (a single-instance launch still joins over D-Bus; with
  `--gtk-single-instance=false` it runs beside). Seams: `GHOZTTY_HANDOFF_PROMPT
  =join|switch` (win32's), debug-only `GHOZTTY_HANDOFF_VERSION` /
  `GHOZTTY_HANDOFF_COMMIT` (be another build) and
  `GHOZTTY_TEST_HANDOFF_DIALOG=<file>` (records `shown <title>|<buttons>|
  <text>`, then cancels the dialog). Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\launch-handoff.sh`, ends `LAUNCH HANDOFF: ALL PASS` (20 checks);
  `wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/launch-handoff.sh'` must
  fail H6. The switched-out debug build can still abort in core `App.deinit`
  on its way out (a surface outlives the quit): T3689, which H14 names.
- **Pane banners and activity state (T3339)**: `+set-banner` / OSC 7778 put
  a card above the terminal (`PaneBanner.zig`): the shared parser
  (`win32/banner_markdown.zig`, with `PathContext.posix` so `./` and `~/`
  links join with `/`) turned into stock widgets - a markup `GtkLabel` per
  line or heading (`banner_markup.zig` is the pure markdown-to-Pango half,
  none-lane tested), a grid per list (a pointer-blind `GtkCheckButton` for
  `[x]`) and per table (bold header, `:` alignment, cells wrapped to 3 lines),
  a separator per rule. The card is prepended to the pane's content box,
  which turns vertical, so the terminal is laid out and resized BELOW it.
  Link clicks take `banner_link.clickAction` with the modifiers of the press
  (`Surface.bannerLink`; Ctrl splits a viewer beside the pane). A
  right-click on a link (T3561) pops the viewer's link menu - same rows,
  order and ids (`banner_link.build` through `viewer_links.menu`), popped by
  the shared `Viewer.popLinkMenu` at the press: a capture-phase secondary
  `GtkGestureClick` on each label reads `gtk_label_get_current_uri` and
  claims the press, so GtkLabel's own Copy Link menu never opens (a
  right-click off a link still gets it). A file link is named by its path,
  which Copy Path copies. `+set-state` / OSC 7777 is stored on the surface,
  listed as `state`, and shown (T3561): the window title gains the most
  urgent pane's human label, ` (busy)` / ` (question)` (`needs_input` >
  `busy` > `idle` over every pane of every tab, pinned title included -
  `window_activity.zig`, none-lane tested; the title is composed by
  `Window.syncTitle`, which replaced the tab-title property binding), and
  each tab's entry shows a spinner (`AdwTabPage:loading`) while busy and
  asks for attention (`needs-attention`) on a move into `needs_input`
  (cleared on leaving it, or by selecting the tab as for a bell). The Mac's
  Dock bounce / win32's taskbar flash for a background window is the
  window's urgency (`winproto.setUrgent`, as the bell's `attention` feature
  sets it), requested on a move into `needs_input` since T3654 (under Window
  modes). A debug build appends every render to
  `$GHOZTTY_TEST_BANNER_DUMP` (`BANNER <pane-id> shown|cleared`, one line per
  widget, `END`). Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\cli-banner.sh`, ends `CLI BANNER: ALL PASS` (46 checks; S1t-S5t
  the title, S1m/S2m the tab marks, M1-M7 the link menu through the debug
  seam `hl_ipc pane-banner --target=<pane> --link-menu=<target>` /
  `--menu-pick=<row>`, recorded under `GHOZTTY_TEST_VIEWER_LINKS` like the
  viewer's). A banner survives a relaunch and an agent
  recovery (T3560, under Session persistence). A banner's title names its
  pane's sidebar row (below).
- **Banner collapse and the editor (T3559)**: the card is a horizontal box -
  the blocks, then a flat chevron (`pan-up`/`pan-down-symbolic`) shown only
  while the banner has a line under its first (`pane_banner_rules.collapsible`,
  win32's rule). A click on the card or the chevron folds it to its title row
  (`collapsedBlocks`: the first block, a list's first item, a table's header)
  and back; GTK lays the pane out once per click, so the terminal is resized
  once. The card's release is queued to an idle so a link's `activate-link`
  or the chevron's `clicked`, both later, can take the click instead. A new
  text keeps the fold, a clear resets it. The editor (`BannerEditor.zig`) is
  an `AdwAlertDialog` with a monospace `GtkTextView`, filled with the banner
  and all selected: Return is the view's newline, Ctrl+Return saves, Escape
  cancels (`editorKey`), blank clears; one at a time. Opened by
  `prompt_surface_banner`, bound to **Ctrl+Shift+B** on Linux (Windows'
  chord; plain Ctrl+R is the shell's history search). Libadwaita 1.5 here has
  no `adw_dialog_set_focus_widget`, so the text box takes focus by hand after
  `present`. The dump gains a `state fixed|expanded|collapsed` line. Debug
  seam: `hl_ipc pane-banner --target=<pane> [--click=card|chevron]
  [--editor-text=<text>] [--editor-key=return|ctrl+return|escape]` replies
  with the card (`shown`, `collapsible`, `collapsed`, `text`), the editor
  (`open`, `pane`, `text`) and `key_effect` (`save|cancel|pass`). Acceptance:
  `wsl-run.ps1 -CommandFile test\linux\cli-banner-edit.sh`, ends
  `CLI BANNER EDIT: ALL PASS` (32 checks); `NEGATIVE=1` presses Ctrl+R and
  must fail E1-E4.
- **The pane sidebar (T3557)**: `PaneSidebar.zig`, a card in a horizontal
  row (`sidebar_row` in `window.blp`) before the tab view, listing the
  active tab's panes in reading order (a split's left/top side first, as
  `+list` walks; the node array is in no spatial order). A row's text is
  win32's pure rules (`gtk/pane_sidebar_rows.zig` over
  `win32/pane_sidebar.zig`): the user's pane title, else the banner's
  title, else the title, else the directory's name; under it the banner's
  first line when it has no title, else the directory with home as `~` -
  dropped when the title IS that directory (the core titles a pane by its
  directory until a program sets one). Click focuses
  (`SplitTree.focusSurface`). ONE button switches the rail (icons, the name
  in a tooltip) and the panel; under 720 px the rail is held and the button
  is off; a quick terminal has none. `toggle_pane_sidebar` is **Ctrl+Shift+S** on Linux (Windows'
  chord). The flags are shared by every window (a change redraws all of
  them at once - no deferral to next-key, which only paid on the Mac's
  per-frame SwiftUI cost) and persist in `<config root>/ghoztty/pane-sidebar[-debug]`
  in win32's format; `macos-pane-sidebar` forces the start without writing
  over the user's own flags (`pane_sidebar_prefs.StartState`). Redraws are
  queued (one idle) from the window's tree, tab, active-surface, title,
  pwd, title-override, size and banner changes. Debug seam: `hl_ipc
  pane-sidebar --target=<pane|window> [--search=<text>]
  [--search-key=enter|escape] [--click=toggle|scope|<row id>|fold:<row id>]`
  replies with the drawn state (`mode`, `expanded`, `hidden`, `can_expand`,
  `visible`, `width`, `window_width`, `all_windows`, `search`,
  `search_field`, `window_count`, `title`, `rows[]` - a row's `pane` is a
  pane id, or a header's `window:<key>` / `project:<name>` / `ungrouped`).
  Acceptance: `wsl-run.ps1 -CommandFile test\linux\cli-sidebar.sh`, ends
  `CLI SIDEBAR: ALL PASS` (29 checks; it switches to the per-window scope
  first); `NEGATIVE=1` presses the wrong chord and must fail S12.
  **All windows (T3558)**: the panel's scope button (trailing edge of the
  header) lists every window - each TAB of each GTK window, as on win32 -
  as an outline (`pane_sidebar_all.zig`, over win32's pure
  `pane_sidebar_outline` / `pane_sidebar_shared`): lone windows first, then
  `<project>: <worktree>` windows under a project header labeled by
  worktree in Finder order, with an "Ungrouped" header over the lone ones
  whenever there is a group; namesakes in the order they opened. A first
  launch opens in it (the persisted 4th field of the flags file); every
  window starts folded to its row (name + pane count; a chevron unfolds,
  the name raises it), and the folds, the scope and the search are ONE
  state for every window, so every list redraws when any window's panes
  change while it is on. The search (`GtkSearchEntry`, panel only) keeps
  the panes every term matches - window name, label, own title, banner
  line, directory and `~` form, ignoring case - and the windows holding
  one, unfolded; Return focuses the first hit, Escape clears (on an empty
  field the caret goes back to the terminal). A pane row of another window
  focuses it there through the surface's present request. Collapsed, the
  rail is one tile per window. Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\cli-sidebar-all.sh`, ends `CLI SIDEBAR ALL: ALL PASS` (30
  checks); `NEGATIVE=1` searches for nothing and must fail A12.
  **Drag to reorder (T3607)**: a pane row on screen drags (its own mime
  type, `application/x-ghoztty-sidebar-row`, so a split tree never takes
  it) and, let go over a list, lands among its own window's rows level with
  the pointer (`pane_sidebar_rows.dropIndex`). The order is the sidebar's,
  one per window (`rows.Orders`, through win32's `pane_sidebar_order`
  `moving`/`arranged`): the grid never moves, a split lands after its
  parent, a closed pane drops out, and both scopes show the same order. The
  seam's ordinary read redraws, and new rows have no place until GTK's next
  frame, so `--layout` reads the rows as laid out (each row's `top`,
  `height`, `draggable`) and `--drag=<row id>:<y>` lets one go at a y of the
  list through the live drop's code; both skip the redraw. Acceptance:
  `wsl-run.ps1 -CommandFile test\linux\cli-sidebar-drag.sh`, ends `CLI
  SIDEBAR DRAG: ALL PASS` (48 checks; T1-T11 are the tray's); `NEGATIVE=1`
  must fail D2, D2b, D4b.
  **Another window's rows (T3699)**: in the all-windows list a pane row let
  go inside ANOTHER window's group - its header down to its last row, the
  gaps included, a folded window's header alone (`rows.joinTab` over the
  rows as laid out) - joins that window (Mac `sidebarHit` over
  `windowGroups` -> `.joinWindow`, win32 `commitJoinDrop`): the same pane
  moves onto that grid's right edge at the top level
  (`SplitTree.joinArriving`, the cross-window `dropArriving` a drop on its
  right edge band makes), that tab is selected, the pane is focused there,
  and a stashed one arrives on screen. Logged `pane sidebar join pane=
  window= outcome=`. Over its own window's rows, between groups or below
  them all it is the T3607/T3698 drop; the tray does not light over another
  window's rows. D10-D10e of `cli-sidebar-drag.sh`.
  **The stash tray (T3698)**: stashed panes are listed after the panes on
  screen, the top of the stash first (`rows.trayed`), in both scopes. This
  window's list draws the tray's head, a row of kind `tray` (id `tray`):
  over the stash a hairline and "Stashed" with the count, or with nothing
  stashed the empty tray's dashed well ("Drag a pane here to stash it"),
  lit in the accent (`pane-sidebar-tray-lit`) while a drag over the list
  would land in it. The all-windows outline draws no head: a window's tray
  begins between its last row on screen and its first stashed row, or right
  under its last row (`rows.trayTopBetween`, win32 `trayTop`), so a row let
  go below its window's rows there stashes. `dropRowAt` splits at that
  line: in the tray the pane is stashed at that place
  (`SplitTree.stashSurfaceAt`, `pane_stash.markAt`; a stashed row moves
  within the stash, the last pane on screen is refused), in the list a
  stashed pane is restored, focused, then placed. Stashed rows drag.
  A real pointer drag is NOT RUN (no pointer, even on the seat compositor:
  T3847). Not yet: a pane drag (a header
  or a strip, so another window's pane) dropped on the sidebar (T3756), the
  order across a restore (T3700), the rows sliding to make room (parity is
  behavior here, not the glide).
  **Windows and groups drag too (T3697)**, in the expanded all-windows list
  only: a project header among the top level (never above the lone
  windows), a window row anywhere - into a group (retitled `<group>:
  <name>`, pinned), out of one, or within its own (win32's pure
  `pane_sidebar_window_order` / `pane_sidebar_cross_drop`, fed by
  `pane_sidebar_all.dropItem`). The order is `scope.window_order`, keys =
  the rows' ids (`project:<name>`, `window:<tab address, hex>`), stored in
  `<config root>/ghoztty/pane-sidebar-order[-debug]`; at launch only its
  project keys are kept, since a tab address does not survive a relaunch
  (T3700). The drop reads the rows where they are drawn (no glide, so no
  closed-up pitch). Picking one up folds every group (or window) to its row
  and letting go restores them; the seam's `--lift=<row id>` is the drag's
  begin, `--drag=<row id>:<y>` its release. Move to Group / Remove from
  Group keep the list's place (`window_order.renamingWindow`). Acceptance:
  `wsl-run.ps1 -CommandFile test\linux\cli-sidebar-drag-items.sh`, ends `CLI
  SIDEBAR DRAG ITEMS: ALL PASS` (32 checks); `NEGATIVE=1` must fail I3, I3c.
  **Group editing (T3608)**: a window row's right-click menu (a
  `GtkPopoverMenu` parented to the card, actions `sbmenu.*`) offers Create
  Group..., Move to Group (the other groups as listed, only when there is
  one) and Remove from Group (grouped windows), and the Ungrouped header's
  buttons start with a pencil (`rows.Tool.rename`). Create Group... and the
  pencil open an in-place `GtkEntry` (placeholder "Group name") where the
  name was; it is kept across redraws (text and caret), Return or clicking
  away commits, Escape or nothing typed changes nothing. Each pins
  `<group>: <name>` on the tab, or on the window when it carries a
  window-wide pin; the rules are win32's pure `pane_sidebar_menu` /
  `pane_sidebar_rename`. Seam: `--menu=<window row id>` (reply `menu`:
  `row`, `items`, `groups`, `popped`), `--menu-pick=create|remove|
  move:<group>`, `--edit=<text>`, `--edit-key=enter|escape` (reply
  `editing`: `row`, `purpose`, `placeholder`, `text`, `shown`, `focused`).
  The headless Weston has no seat, so the popover closes at once for want of
  a grab; the menu's state lasts until a pick or the next open, which is
  what `--menu-pick` acts on. On the seat compositor it stays open (S9-S10
  of `cli-seat.sh`, T3713). Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\cli-sidebar-groups.sh`, ends `CLI SIDEBAR GROUPS: ALL PASS`
  (32 checks); `NEGATIVE=1` never presses Return and must fail G9/G9b. Not
  yet: the list keeping its place across a regroup (needs T3697's window
  order).
  **A title the sidebar pinned is the user's (T3702; win32 T2404, Mac
  `windowTitleIsUsers`)**: `Window.setTitleOverrideBy(title, .user|.script)`
  records who set the window-wide pin (`title_set_by_user`; plain
  `setTitleOverride` is a script's), and the sidebar's group moves write it
  as the user's. A script's `+rename` is refused, with Mac's sentence
  (`verbs.rename_refusal_fmt`), while the window carries a user's window pin
  or ANY of its tabs carries a pin - only the user pins a tab here, and a
  window pin would hide it (`pane_sidebar_all.renameKept`, none lane; logs
  `IPC rename kept the user's title=`). A script's own window pin may still
  be replaced. `+list --json` reports `title_set_by_user` (window pin only),
  and `session-layout.json` keeps the bit. G17-G20 of the script above.
  Gap: Change Window Title edits the tab, so the user cannot clear a
  window-wide pin yet (T3837).
  **This window's header and the rail's + (T3695)**: a window always holds
  its panes - the expanded per-window list starts with the window's own
  header row (`window:<key>`: chevron, name, pane count, + and x on hover)
  with its panes one level in (`depth` 1), and a `<project>: <name>` window
  has its group's header above it (labeled by worktree, counting - and its x
  closing - the whole group; folded, the group's header alone). Built by
  `pane_sidebar_all.buildOwn` with the outline's own rules; the header's
  fold is this list's (`Shared.folded_this`, so `toggleFold` follows the
  scope), and it is drawn selected only folded. The panel caption reads
  `Panes` / `All Windows` (seam `title`). The rail's first tile is a +
  (kind `rail_add`, id `rail-add`, win32 `railAdd`): in Panes a new pane in
  this window (the window header's +, split the last manual direction,
  logged `from=rail`), in all windows a new window. Acceptance:
  `wsl-run.ps1 -CommandFile test\linux\cli-sidebar-header.sh`, ends `CLI
  SIDEBAR HEADER: ALL PASS` (23 checks); `NEGATIVE=1` never folds and must
  fail H4. The other sidebar suites read pane rows by kind, so the header
  does not shift them. Not yet: the pencil (T3828), the hover tint (T3823),
  the busy sheen (T3824), the width grip (T3825), hero suppression (T3826),
  a + from a remote window opening on its machine (T3827).
  `--view` on `+new-window`/`+split` opens a viewer pane (T3411, below).
- **Names (T3370)** follow win32's rules exactly (`apprt/ipc/target_lookup.zig`,
  T2250): a window name is global (`+new-window --target`, else a minted
  `window-N`, shown as `target` in `+list`); a pane name (`--name`) belongs
  to its window, and a lookup starts in the caller's window (the CLI forwards
  `$GHOZTTY_PANE_ID`), so the same name in two windows is ambiguous from
  outside both and the command fails naming them. The names live on the GTK
  objects (`Window.ipcName`, `Surface.ipcName`) and every lookup walks the
  live windows, so there is no registry to forget a closed pane from. A pane
  id always works as a target. `--command` runs as the Mac's
  `<shell> -lic '<cmd>; exec <shell> -li'` (a pane that stays drivable),
  `-e` execs its argv. `+rename` pins the window title over the tabs' until
  `--title=` clears it. Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\cli-windows.sh`, ends `CLI WINDOWS: ALL PASS` (40 checks).
- **`--focus` (T1797 on GTK, T3381)**: a `+new-window` without it is SHOWN,
  not presented - no activation request, and on X11 a `_NET_WM_USER_TIME` of
  0 (`winproto.Window.suppressFocusOnMap`) - so it opens behind whatever the
  user is typing into; the app logs `window shown in the background (no
  activation request)`. A `+split` without it leaves the window's focused
  pane alone. With `--focus` the window is presented, which on Wayland IS an
  xdg-activation request that the compositor may decline: when no window of
  this app is active at request time (a command run from another app's
  terminal), the `+new-window` reply carries the note `--focus: Ghoztty is
  not the active app, so the compositor may keep the window behind ...`, and
  a second after any `--focus` raise the app logs `focus: the compositor
  activated|declined to activate the window`. Weston headless has no seat, so
  the harness always sees the decline (W20-W21 of `cli-windows.sh`); the
  activation itself, and a raise of an older window, are S6-S7 of
  `cli-seat.sh` on the seat compositor with a held keyboard (T3713). Not
  done: forwarding a launcher's `$XDG_ACTIVATION_TOKEN` through the CLI,
  which would only help a command run from a freshly launched app.
- **`+close` and `focus` (T3367)** follow win32's too: `+close` closes a pane
  (its window when it was the last pane) or a window with no confirmation,
  succeeds on a name nothing holds, refuses an ambiguous one, and refuses
  over an open dialog unless `--force` (which dismisses it). `focus` has no
  CLI verb on any platform - it is the `ghoztty://` launcher's action - and
  never creates. Weston headless has no seat, so no window is ever ACTIVE in
  the harness: a window raise cannot be asserted there, only pane focus
  (`cli-seat.sh` asserts one on the seat compositor, T3713). To
  stand a dialog over a window, a debug build opens the window whose
  `+new-window --target` equals `$GHOZTTY_TEST_ASK_TO_CLOSE` with its real
  close confirmation up. Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\cli-close-focus.sh`, ends `CLI CLOSE FOCUS: ALL PASS`.
- **Pane tints (T3382)**: `+new-window --color`, `--split-color` and `+split
  --color` (`#rgb`, `#rrggbb`, `random`) go through
  `Surface.applyBackgroundTint`, win32's steps over win32's pure
  `color_math.zig`: background, black/white contrast foreground, WCAG-adjusted
  base 16, regenerated 16-255, the renderer's contrast floor. A new pane's GL
  area realizes after the handler returns, so the tint is stored and applied in
  `initSurface` once the core surface exists. A split inherits its parent's
  tint in `SplitTree.newSplitAt` (keyboard splits too). `+list` reports
  `background_tint`. Not yet: the window gradient (T3566), restore (T3589). A
  test that reads a split's colour must set `unfocused-split-opacity = 1`: a
  split opened without `--focus` is dimmed. Acceptance: `wsl-run.ps1
  -CommandFile test\linux\cli-color.sh`, ends `CLI COLOR: ALL PASS` (26 checks).
- **`+rearrange` (T3368)** is win32's `handleRearrange`: the shared
  `validateLayout` / `firstDuplicate` checks and sentences, then the window
  (`--target`, else the caller's window, else the front one), then every leaf
  resolved inside that window's active tab (a pane id anywhere, else a pane
  name of THAT window; a name held only elsewhere is "not in the target
  window"). Panes move with their shells; ratios are percents clamped 10-90;
  focus stays on a surviving focused pane, else goes to the top-left leaf. A
  pane the layout omits is parked for `undo-timeout` and then closes with its
  shell (close undo, T3384, below); a stashed pane (T3596) keeps its mark
  wherever the layout puts it.
  Acceptance: `wsl-run.ps1 -CommandFile test\linux\cli-rearrange.sh`, ends
  `CLI REARRANGE: ALL PASS` (28 checks).
- **Close undo (T3384)** is Mac's ExpiringUndoManager and win32's T1825/T2234,
  in `src/apprt/gtk/CloseUndo.zig`: a closed pane (keyboard, its own close,
  `+close`) or a pane a `+rearrange` left out is PARKED - out of the split
  tree, so out of `+list` and every name lookup, but one GObject reference
  keeps the Surface, its pty and its shell alive - for `undo-timeout` (5 s;
  `0` turns undo off). **Ctrl+Shift+Z** puts it back (a pane at win32's
  `close_undo.Anchor`, a layout from win32's `layout_undo.Shape` by pane id),
  by name and with the same shell; **Ctrl+Shift+Y** redoes. Windows' chords,
  added to Linux's defaults in `Config.zig`, not performable (an idle chord
  must not reach the shell as ^Z). One stack, entries owned by their window:
  an undo in one window never reaches another, and a window that closes ends
  its entries. Expiry, a window close and a quit end a parked pane as a CLOSE
  (its agent session ends, never detaches). `+close --force` is never parked.
  **A closed tab parks too (T3590)**: `Window.finishTabClose` takes one
  reference on the Tab before the tab view detaches it, so its tree and every
  shell wait; undo re-inserts it at its old position through
  `Window.attachTabPage` (the same wiring a new tab gets). A tab's only pane
  closing (`+close`, its close key) closes the TAB, tree intact
  (`CloseUndo.closeTabInstead`), so it parks whole. Close Other Tabs and
  Close Tabs to the Right are ONE undo and one redo (win32's group ids,
  begun in `Tab.actionClose`). A tab whose shells have all exited is not
  parked. **A closed window parks too (T3665, win32 T1874)** - its close
  button, `win.close`, `+close` (not `--force`), or its last tab or last
  pane going (`Window.finishTabClose` declines the last page's close and
  `CloseUndo.parkWindow` takes the window whole). `Window.parkForUndo` hides
  it and REMOVES it from the GtkApplication, so every `getWindows` walk
  (`+list`, targeting, sidebars, session layout, the quit check) sees it
  gone with no per-walker filter; undo `addWindow`s and presents it. The
  entry is owned by a shared key, so ANY window's Ctrl+Shift+Z reaches it in
  recency order with that window's own closes (`popForEither`). Never
  parked: the last window (nowhere to press undo), the quick terminal, a
  window with no running shell, and a single-window-mode workspace (T3790).
  A parked window closed again (its last shell exited) drops its undo
  (`forgetWindow`) and closes for real.
  **Pressing keys headless**: Wayland has no input injection and the default
  harness has no seat (on `hl_start_seat`, `wtype` types for real: S8 of
  `cli-seat.sh`), so a debug build serves the `press-key` IPC seam - `hl_ipc
  press-key --target=<pane> --key=ctrl+shift+z` - which feeds one press and
  release through the pane's core `keyCallback`, so the configured binding
  table decides what it does; the reply's `effect` is `consumed`, `ignored`
  or `closed`. Acceptance: `wsl-run.ps1 -CommandFile test\linux\cli-undo.sh`,
  ends `CLI UNDO: ALL PASS` (60 checks, T1-T16 the tabs, W0-W12 the windows; P2 tolerates only
  T3802's known teardown CRITICAL); `NEGATIVE=1` runs it with undo off
  and must fail.
- **Pane rearrange mode and pane drops (T3564)**: `toggle_rearrange_mode`
  (**Ctrl+Shift+.**, the shared default; the command palette's "Toggle
  Rearrange Mode") is per window (`Window.setRearrangeMode`). On, every pane
  of every tab shows a 24 px header (`PaneDrag.Header`: a grip icon and the
  pane's title, an open-hand cursor) at the top of the pane's own vertical
  box, above any banner, so it takes layout space and every terminal is
  resized once each way; a pane that arrives while it is on (a split, a
  drop) grows one on the tree's rebuild. The tab bar is forced visible
  (`getTabsVisible` true, `getTabsAutohide` false). **Escape** leaves it,
  through a capture-phase key controller on the window that takes Escape
  only while the mode is on (`Window.rearrangeKey`). The header is a
  `GtkDragSource` offering one private mime type,
  `application/x-ghoztty-pane`, so no terminal's file/text drop target can
  take it; each split tree's `tree_bin` holds a `GtkDropTargetAsync` for
  it. The dragged pane is module state set at `drag-begin` (GTK runs one
  drag at a time), and the drop is win32's pure resolver
  (`win32/pane_drop.zig`, with `pane_gap.zig`'s dividers) over the split
  area's own coordinates, made by `gtk/pane_drop_apply.zig` (none-lane
  tested): split, swap, top-level edge band, divider gap; a drop that would
  leave the pane in place (`pane_layout.wouldLeaveInPlace`) does nothing.
  Every move keeps the same `Surface` (same shell, pid and pane id) and
  focuses the moved pane. Log category `gtk_pane_drag` (`drag began`,
  `drop pane=... target=... outcome=...`).
  **The tab bar (T3615)**: the window's `AdwTabBar` holds a second
  `GtkDropTargetAsync` for the same mime type. It is a target only while it
  is on screen (mapped and non-empty: with the mode off and one tab it is
  hidden and takes nothing). Its candidate is the bar plus each tab's button
  - libadwaita's internal `AdwTab` widgets, found by type name and ordered
  left to right (`Window.tabBarCandidate`) - and the same resolver answers
  `new_tab` with the button index under the pointer (Mac and win32: over a
  button means before it; with expanded tabs there is no strip background,
  so a drop cannot append past the last tab, as on the Mac).
  `Window.dropOnTabBar` then applies `pane_drop_apply.tabDrop`: a pane of a
  tab with others moves into a new tab of its own at that index, selected
  and focused (`SplitTree.releaseSurface` + `Tab.newAdopting`, the same
  `Surface`); a pane that is its tab's only one moves its tab there instead
  (win32 `pane_relocate.tabReorderIndex`), and the two seams either side of
  it are in place - so a window's only pane never leaves it. **The dwell**:
  every drag-motion over the bar calls `Window.tabDwellAt`, which arms a
  500 ms clock on the button under the pointer (`pane_drop.hoveredTab`),
  re-armed only when that button changes, never on the tab already on show;
  leaving the bar or dropping cancels it, and when it fires that tab is
  selected. A drop in the new tab's split area then finds the pane in
  another tree of the window and goes through
  `pane_drop_apply.applyArriving` (`SplitTree.moveTo`/`swapWith`): split,
  swap, top-level and gap drops across tabs, the tab it left closing when it
  empties. **Another window (T3616)**: every window's split trees and tab
  bar hold the same targets and the compositor delivers a drop to the window
  under the pointer, so a drop finds its source app-wide
  (`Window.paneHome`: this window first, then every other) and the same two
  paths take it - `SplitTree.dropArriving` (split, swap, top-level, gap) and
  `Window.dropOnTabBar` (a new tab there, `adoptFromWindow` +
  `SplitTree.takeSurface`). The Mac's rule (`PaneMoveCoordinator.allows`,
  fd7385c42): joining an EXISTING window is always allowed, a window's last
  pane included - its tab closes, and with no other tab its window closes,
  without a confirmation (nothing runs in it any more). The source's tree
  and window are held by a reference through the move, since that close is
  synchronous. `Window.finishArrival` is Mac `finishRelocation`: the moved
  panes (both, for a swap) drop a Disconnect's detach pin, a drag made in
  rearrange mode turns the mode on in the window it lands in, and that
  window is presented. A rebuild now syncs every header to its window's mode
  both ways, so a pane a swap sends into a window out of the mode loses its
  header. The agent session needs no extra step: the same `Surface` moves,
  so nothing is freed and nothing marks CLOSE (Mac needs one because its
  close-intent policy reads a leaf leaving a tree). A tree now
  PUSHES its is-split to its panes on every rebuild (`Surface.setIsSplit`)
  instead of binding the property: a binding from the tree that made a pane
  went on driving it after it moved. Logs: `tab bar drop pane=... index=...
  outcome=...`, `pane drag dwell opened tab <n>`, `pane <id> arrived from
  another tab`, `pane <id> arrived from another window`, `tab bar drop ...
  (from another window)`. **The ghost card** (T3617, `PaneDragGhost.zig`,
  sizes in `pane_ghost_rules.zig`): drag-begin sets the drag icon to a card
  of the pane - its background (or tint), a title strip with the header's
  label, the pane's own content scaled into the body, a rim and a shadow, at
  most 220x150 in the pane's shape plus a 10px shadow margin, held by the
  middle of the title strip - drawn with GtkSnapshot and rendered ONCE to a
  texture by the window's GSK renderer (a still, like the Mac's NSImage).
  Log: `drag began pane=... ghost=<w>x<h> hot=<x>,<y>`. **A new window**
  (T3618): a drag let go over nothing - GTK's `drag-cancel` with
  `GDK_DRAG_CANCEL_NO_TARGET`, and none of our drop targets saw the release
  (`PaneDrag.drop_seen`, so a quiet drop such as an in-place one never pops
  out; Escape is `USER_CANCELLED` and does nothing) - moves the pane into a
  new window holding only it, and so does the header's right-hand button
  (`window-new-symbolic`, flat). Both call `Window.popOutPane`: a new EMPTY
  window (`Application.newWindowForPopOut`, at the source window's size, or
  its restored size when that one is maximized or fullscreen) adopts the
  same `Surface` through `adoptFromWindow`, so shell, pid, pane id and agent
  session go with it, the mode follows and the new window is presented. The
  release-over-nothing move runs on an idle, after the drag has ended.
  **A window's last pane may not** (`pane_drop_apply.popOutAllowed`, win32
  `pane_relocate.popOutAllowed`, Mac `canPopOut`): its button is disabled
  (`Window.syncPopOut`, re-run on every tree rebuild and every tab attach or
  detach, since a second tab makes a lone pane movable) and a release over
  nothing is refused, so a drag never closes a window. Wayland gives a client
  no pointer or window position, so where the new window opens is the
  compositor's call (Mac and win32 open it at the drop point). Logs: `pop out
  pane=... into a new window size=<w>x<h>`, `pop out pane=... refused`,
  `drag released over nothing pane=...`, `pop-out button pane=...
  outcome=...`. **Undo (T3706, Mac "Move Pane")**: every drop that moves a
  pane - in its tab, into another tab, a new tab off the tab bar, another
  window, a pop-out - is ONE undo on Ctrl+Shift+Z and one redo on
  Ctrl+Shift+Y, through `CloseUndo.beginMove`/`endMove` around the commit.
  Each tree it touched is recorded by pane id, and while the move runs a tab
  or window it EMPTIES is kept (`parkTab`/`parkWindow` hand it to the open
  move: out of its tab view, or hidden and out of the app's window list)
  instead of destroyed, so the undo puts the pane back AND reopens what it
  emptied (`move_undo_rules.rebuildAcross` rebuilds every tree together; a
  pane opened since joins its tree on the right, one closed since is
  pruned). The redo is recorded the same way as the undo applies, so the
  drop's new tab or the pop-out's window comes back too. A move within one
  window is that window's entry; one between two windows is shared, so
  either window's undo reaches it. Not yet: a lone pane's tab moved along
  the bar (a tab reorder, not a tree change) is not recorded (T3840); in
  single-window mode a workspace a move empties or creates is not kept (the
  same exclusion as a workspace close, T3790), so that undo or redo finds
  the tree gone and does nothing (code-read, not run). Logs: `pane move
  recorded for undo (<n> tree(s), <n> emptied)`, `pane move emptied the tab
  at <n>: kept for undo`, `pane move emptied a window: kept for undo`.
  Acceptance: `wsl-run.ps1 -CommandFile test\linux\pane-drag-undo.sh`, ends
  `PANE DRAG UNDO: ALL PASS` (28 checks); `NEGATIVE=1` turns undo off and
  must fail 12 (listed in its header). **The drop preview (T3708, Mac
  `PaneDropFeedbackView`, win32 `drop_highlight.zig`)**: every drag motion
  over a split area calls `SplitTree.hoverAt`, which resolves the point
  through the SAME `resolveDropAt` a release uses and draws win32's
  `drop_highlight.forTarget` rect as an overlay child of the area
  (`drop_preview` in `split-tree.blp`, `can-target: false`, so the drop
  target keeps every event): a split fills the half of the pane it takes
  and a top-level insert half the area, each with a 2px seam where the new
  divider runs; a divider insert fills its landing area, seamed both sides
  of that axis; a swap is the pane's centre box, rounded and outlined, with
  a ⇄ glyph (accent at 30%, the Mac's values; classes and placement in the
  pure `pane_drop_preview.zig`). A spot that would leave the pane where it
  is shows nothing (`pane_drop_apply.wouldMove`, the rule `apply` answers
  `in_place` by, unit-tested to agree). Leaving the area or releasing takes
  it down. **The dwelling tab is lit**: while the 500ms clock runs, its
  `AdwTab` button wears `pane-drag-dwell` (an accent wash), dropped when
  the clock is cancelled or fires (`Window.lightDwell`, referenced so a tab
  closed mid-dwell cannot dangle). Not yet: the new-tab caret on the tab
  bar and a strip's slot caret (T3841). Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\pane-drop-preview.sh`, ends `PANE DROP PREVIEW: ALL PASS` (19
  checks; V13 compares a window capture's pixel with and without it); `NEGATIVE=1` hovers over the dragged pane itself and must fail
  V4-V7, V10 and V13 (6). **The hover grab handle (T3709, Mac
  `PaneGrabHandle`, win32 `pane_grab_handle.zig`)**: with the mode OFF,
  every pane - terminal or viewer - carries `PaneGrabHandle.Handle`, a
  `GtkPicture` overlaid on the surface's `terminal_page` overlay, centred at
  the top edge. A CAPTURE-phase motion controller on that overlay sees the
  pointer over the terminal and over a WebKit page alike: in the pane's top
  band (the top fifth, never under 24 px) the grip is `hinted`, on its 80x24
  hit box `engaged`, and it is hidden otherwise - and always hidden in
  rearrange mode (the header drags), in a fullscreen window holding one
  pane, while the pointer is hidden for typing, and while another drag is in
  flight. Every rule and pixel is win32's pure `pane_grab_handle.zig`
  (`band`, `layout`, `state`, `render`), shared, not copied: the capsule is
  rendered into a premultiplied BGRA buffer at the widget's device scale and
  shown as a memory texture, so the Linux grip is the Windows one. Hidden,
  the picture is not visible and takes no press from the terminal under it.
  Dragging it is the header's drag exactly: both are a `PaneDrag.Source`
  (same mime type, ghost card, drop targets and preview, release-over-nothing
  pop-out), with `hooks` keeping the grip engaged while it is the thing being
  dragged. Log category `gtk_pane_grab` (debug: `grab handle pane=...
  hidden -> hinted`). Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\pane-grab-handle.sh`, ends `PANE GRAB HANDLE: ALL PASS` (18
  checks; G8 compares a window capture's pixel engaged and hidden);
  `NEGATIVE=1` puts the band pointer below the band and must fail G5-G8
  (4). A real pointer drag is NOT RUN (no seat). Debug seam:
  `hl_ipc pane-drag --target=<pane> [--key=escape] [--drop-on=<pane>
  --fx=<0..1> --fy=<0..1> | --drop-at=<x>,<y> | --drop-tab=<n>]
  [--hover-tab=<n> | --hover-leave] [--bar-of=<pane>]
  [--grab-at=<x>,<y> | --grab-leave] [--grab-begin | --grab-end]
  [--release-nowhere --via-grab]
  [--hover-on=<pane> --hx=<0..1> --hy=<0..1> | --hover-at=<x>,<y> |
  --hover-end]
  [--release-nowhere | --pop-out] [--ghost | --ghost-png=<path>]`
  (`--release-nowhere` is the no-target cancel's call, `--pop-out` the
  button's own `clicked` - not `gtk_widget_activate`, which GTK4 animates and
  clicks only after a timeout - and gives a disabled button no click; both
  report as a drop with `target` `new_window` and `outcome`
  `moved|refused|not_here|none`, and every header reports `pop_out`, its
  button enabled. Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\pane-pop-out.sh`, ends `PANE POP OUT: ALL PASS` (16 checks);
  `NEGATIVE=1` aims both moves at a lone window's last pane and must fail
  P6, P7, P9, P11 and P12) (`--ghost` adds a `ghost` object: the
  card's planned geometry, the texture size and scale, and pixels sampled
  from the very texture a drag-begin would set; `--ghost-png` also saves it.
  Acceptance: `wsl-run.ps1 -CommandFile test\linux\pane-drag-ghost.sh`, ends
  `PANE DRAG GHOST: ALL PASS` (15 checks); `NEGATIVE=1` must fail G12 only)
  (`--bar-of` aims the
  tab-bar flags at that pane's window) replies with `mode`, `tabs_visible`,
  `tabs_autohide`, `key_effect`, every pane's header (`shown`, `height`,
  `title`, `content_height`, `is_split`, `rect`, the pane as drawn in
  its split area, and `grab`, its grab handle: `state`, `shown`, `dragging`,
  the `planned` hit box and `band` in the pane's own coordinates, and
  `widget` as laid out), the drop (`target`, `side`,
  `pane`, `index`, `outcome`), `tab_count`, `selected_tab`, `dwell_tab`,
  `dwell_lit` (the button wearing the dwell's light, read off the widgets)
  and `tab_buttons` of the window the target is in after the drop,
  `window_count`, and `preview` (T3708: `shown`, the split `area`, `kind`,
  `seam`, `glyph`, the planned `rect`, the `widget` as laid out on the last
  frame - so read it again after a hover - and its `classes`) of the area
  the hover named, else the tab on show. `--hover-on`/`--hover-at` is the
  split area's drag-motion call (`SplitTree.hoverAt`) for the TARGET pane,
  `--hover-end` its drag-leave; a `--drop-on`/`--drop-at` takes the preview
  down first, as a release does. It drops the TARGET pane through the same
  `SplitTree.dropPaneAt` (in the `--drop-on` pane's tab, else the tab on
  show) or `Window.dropOnTabBar` (`--drop-tab`, the middle of that tab's
  button) a release calls, and `--hover-tab` is the motion handler's
  `tabDwellAt` call. The harness has no seat, so a pointer drag cannot START
  headless; the seam is the drop half. Acceptance:
  `wsl-run.ps1 -CommandFile test\linux\cli-pane-drag.sh`, ends
  `CLI PANE DRAG: ALL PASS` (53 checks; X1-X12 the second window);
  `NEGATIVE=1` presses Ctrl+Shift+, and must fail 32: D2-D5b, D14, D15, the
  tab-bar half D19-D28b, D31 and D32 (with the mode off and one tab the bar
  is hidden, so it is no target), and X2-X10 and X12 (the mode never follows
  a pane, the other window's bar stays hidden, and the moves cascade from a
  different start).
- `+send-keys` and `+read` take a pane id, a pane name or a window name (its
  active pane). `+send-keys` is the Mac's:
  text runs framed as a bracketed paste when the program asked for one, key
  runs bare, no LF rewriting (a POSIX pty takes LF as a line end).
  Acceptance: `wsl-run.ps1 -CommandFile test\linux\cli-send-read.sh`, ends
  `CLI SEND READ: ALL PASS` (15 checks, including a byte-exact raw-tty probe
  of the paste framing).
- Every pane is baked with `$GHOZTTY_IPC_SOCKET` (this app's) and a UUID
  `$GHOZTTY_PANE_ID`; an inherited `$GHOZTTY_IPC_SOCKET` is unset at startup.

Acceptance: `wsl-run.ps1 -CommandFile test\linux\ipc-server.sh`, ends
`IPC SERVER: ALL PASS`.

## Viewers on WebKitGTK: the foundation (T3410)

The viewer-pane work (L9, T3410-T3420) runs on WebKitGTK 6.0. What L9a put
in place, and what every later slice builds on:

- **The binding is hand-written**: `src/apprt/gtk/webkit.zig`. zig-gobject has
  no WebKit module, so these are C externs over opaque types; `addGtkNg`
  links `webkitgtk-6.0`. Add a function when a slice needs one.
- **`src/apprt/gtk/Viewer.zig`** wraps one web view. Template modes (markdown,
  code) load `ghoztty-viewer://page/viewer.html` - the Mac's own custom scheme
  and URL - and push the file in through `window.__viewer.setMarkdown` /
  `setCode` once the page has loaded, built by win32's pure
  `viewer_document.readUtf8`. A `.html` file loads from
  `ghoztty-page://page/<rel>`, whose grant is the file's own directory (win32's
  T601 split). A website is navigated to directly. Images (T3416) draw in the
  template through `ViewerImage.zig`. Diffs (T3417) are the template's
  `diff.js` driven by `ViewerDiff.zig`, which reuses win32's diff stack
  whole - `viewer_diff.zig`, `viewer_file_tree.zig`, and the git worker
  `ViewerDiffProbe.zig` over `git_run.zig`, both POSIX-capable (a process
  group stands in for the job object; a `Notify` callback + `g_idle_add`
  for the window message). The changed-files panel is native GTK.
  Acceptance: `test/linux/viewer-diff.sh`.
- **The schemes are pure** in `src/apprt/gtk/viewer_scheme.zig` (none lane):
  template tiers are bundled assets, then the file's directory, then absolute
  (the Mac's order, `..` refused by the first two); the page origin is its
  directory only. Both are registered local + secure on WebKit's default
  context, once per process; a request finds its viewer through the web view
  (`g_object_get_data`).
- **The WSLg GPU trap.** WebKit runs its web processes in a bubblewrap
  sandbox with no `/dev/dxg`, so a web process that inherits
  `GALLIUM_DRIVER=d3d12` aborts with `Could not create surfaceless EGL
  display: EGL_NOT_INITIALIZED` and no page ever loads (the app log shows it;
  the viewer just never renders). The viewer brings GDK's GL up first and then
  unsets the d3d12 override before the first web process spawns, so the
  terminal stays on the GPU and the sandbox stays on. Since T3350 the app's
  own default never reaches that point (it is removed at startup); this
  strips only an override the user exported. Measured 2026-11-22:
  unset override renders, `WEBKIT_DISABLE_DMABUF_RENDERER=1` and
  `LIBGL_ALWAYS_SOFTWARE=1` alone do not, disabling the sandbox does (never
  do that).
- **Reading a viewer back.** In a debug build, with `GHOZTTY_TEST_VIEWER_DUMP`
  set, every viewer - a pane's too - writes the result of
  `GHOZTTY_TEST_VIEWER_PROBE` (a JS expression) there once it has rendered,
  as `OK <value>` / `FAIL <why>`; `GHOZTTY_TEST_VIEWER=<location>` also opens
  one in a plain window at startup, with no split tree in the way. A probe is
  how a headless test sees a viewer: there are no pixels in the harness.

### Viewer panes (T3411)

A viewer pane is a **`Surface` in viewer mode**, not a new leaf type: the
split tree, tabs, zoom, focus and close code all speak `Surface`, and a
Surface whose core never started is a state every surface already passes
through before its first resize. So `Surface.new(.{ .view = location })`
puts the `Viewer`'s web view where the GL area was and hides the GL area,
which is then never realized - no core surface, no pty, no agent session.
(Win32 retyped its leaf to `PaneView`, T90a; the observable behavior is the
same, and this shape kept the GTK tree, tab and window code untouched.)

- `+split --view` / `+new-window --view` open one. The CLI resolves a relative
  path against `--working-directory` (else its cwd); the server resolves one
  a raw client sent the same way (`viewer_scheme.resolveLocation`). `git-*:`
  specs, URLs and `about:blank` (a blank browser pane) are never touched.
  `+new-window --split=` still splits a TERMINAL beside the viewer, as on win32.
- `+list` reports the leaf as `type: viewer` with `url` = the page a website
  is on now, else the file (`Viewer.currentLocation`); the title is the file
  name, host or diff subject. The text form prints `view: <title>  <url>`.
- `+read` / `+send-keys` fail with `<name> is a viewer pane, not a terminal`
  (`lookupTerminal` answers `.viewer`); `+set-state` / `+set-banner` will
  answer the same once T3339 serves them through the shared bodies.
- `+close` and a pane's own close never prompt: nothing is running in it.
- A `--name` held by a viewer is reused for the same view and refused for
  another (the shared `split_name_collision` rule, fed the viewer's location).
- Keys are the web view's (the Surface's key handler steps aside), after the
  viewer's own pane chords (T3412, below); restore with the session is
  T3420 (under Session persistence, below).

### The nav bar and pane keys (T3412)

`Viewer.widget()` is a vertical box: the nav bar (back, forward, reload,
home, reveal, address) and then the web view, so the bar reserves its height
from the first frame. Focusing the pane focuses the PAGE
(`Viewer.focusContent`), never the box, which would hand focus to Back.

- **History is WebKit's own.** A template mode's URL carries its file:
  `ghoztty-viewer://page/viewer.html?file=<escaped path>`
  (`viewer_chrome.templateUrlFor`), so each back/forward entry names the file
  it showed, and every committed URI is read back (`syncCommitted`) to say
  where the pane is - mode, `+list` url, title, address, reveal button.
- **The address** goes through win32's `viewer_nav.resolveInput` (paths,
  `about:`, diff specs pass; a host is omnibox-completed) plus `~` expansion.
- **Pane keys**: a CAPTURE-phase key controller on the box asks
  `viewer_chrome.classify`, which maps the GDK keysym onto win32's pure tables
  (`viewer_accel.paneChord`/`zoomAction`, `viewer_find.fieldKeyAction`) - the
  same chords as Windows, Ctrl as the modifier. Ctrl+R reloads in place,
  Ctrl+L / Alt+D select the address, Ctrl +/-/0 zoom, Escape reverts the
  address. Ctrl+F/G and F3 are find's (T3414, below); the app-keybinding
  fallback for every chord the pane declines is T3430.
- **Reveal** is `gtk_file_launcher_open_containing_folder` (the desktop's
  FileManager1), or the nearest existing folder for a deleted file. Headless
  Weston has neither, so the test reads the `viewer: reveal ...` log line.
- **Driving it headless**: a debug build with
  `GHOZTTY_TEST_VIEWER_STEPS=<file>` runs that file's steps (`key <accel>`,
  `type`, `activate`, `click <button>`, `wait`, `state`, `probe <js>`,
  `mark`, `sleep`) on the first viewer to write its dump, and appends one
  result line per step to `GHOZTTY_TEST_VIEWER_STEPS_OUT`. `key` calls the
  controller's own handler; `click` emits `clicked` (a GtkButton's
  `activate` delays it by 250 ms); `activate` emits the entry's `activate`,
  which is what Return does.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-nav.sh
```

Ends `VIEWER NAV: ALL PASS` (26 checks).

### Reloads: live reload, `+reload`, a dead web process (T3413)

Every decision is win32's, mapped onto GTK by the pure
`src/apprt/gtk/viewer_reload.zig` (none lane):

- **Live reload.** A file pane watches the file it shows NOW
  (`viewer_watch.zig`: a `GFileMonitor` on the file, which GIO's inotify
  backend runs on the directory by name, so an atomic save needs no re-arm).
  A link, Back or a typed address moves the watch; a website watches nothing.
  A burst of events is collapsed for 100 ms (win32's `reload_debounce_ms`),
  then win32's T3037 gate (`reload_gate.zig`) skips a save that left size and
  mtime unchanged, and holds one that lands while the pane is unmapped until
  it maps. What the reload does is `viewer_content.reloadPlan`: markdown/code
  re-render into the live template (the template restores the scroll on the
  next animation frame); a `.html` page reloads in place (WebKit restores the
  scroll); a deleted file shows the `Cannot read file` card, and re-creating
  it brings the document back. Only the viewed file is watched, so an edited
  sibling stylesheet needs `+reload`. A file on `/mnt/<drive>` (WSL's 9p
  mount) gets no inotify events for edits made from the Windows side.
- **`+reload`** is the shared body `verbs.reload` (win32 routes through it
  too): a viewer pane, or a window's focused one, reloads bypassing caches;
  win32's refusals word for word. `--config` (T3369) runs the GTK
  `reload_config` action hard and app-wide - the files are read again and
  every open pane takes the new values - and answers success like the Mac;
  a bad config line is a diagnostic, not a failure (`test/linux/cli-reload.sh`).
  Ctrl+R in the pane is the same reload; the bar's button is a plain one.
- **A dead web process** (`web-process-terminated`, Mac
  `webViewWebContentProcessDidTerminate`): reload the page the pane is on, at
  most 3 times in 60 s (win32's `viewer_process.Budget`); the 4th death shows
  win32's "This page keeps crashing" card (a self-contained page via
  `load_alternate_html`, since the template is a page too), and Ctrl+R or
  `+reload` behind it loads the pane's location again. Every termination
  reason counts, WebKit's own API termination included - that is what the
  debug steps seam's `terminate` step uses.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-reload.sh
```

Ends `VIEWER RELOAD: ALL PASS` (30 checks).

### Find in page (T3414)

The search is the shared `src/viewer/find.js` (index, matching, Custom
Highlight painting, live re-scan, the 5000 cap, the "frames not searched"
note), so this side is only the card, the chords and the bridge:

- **The script reaches every document.** It is a `WebKitUserScript` on the
  view's own content manager - top frame, document end, the Mac's
  `WKUserScript` - added before the first navigation, so a website gets it as
  well as the template. Its counts come back through
  `webkit_user_content_manager_register_script_message_handler("viewerTOC")`
  (`script-message-received::viewerTOC`, a `JSCValue` turned to JSON and read
  by win32's pure `viewer_bridge.parse`). The template's `viewer.js` posts on
  the same handler; only `find` is acted on.
- **The card floats**: the web view sits in a `GtkOverlay` under the nav bar
  and the card is an overlay at its top-trailing corner, so opening it never
  reflows the page. Field, live count (`viewer_find.Result.label`: `3/17`,
  `12/5000+`, `No results`, nothing for an empty field), previous / next /
  close, and the honesty note as a second line only while there is one.
- **Keys** are win32's tables through `viewer_chrome.classify`: Ctrl+F opens
  (query selected), Enter / Shift+Enter in the field, Ctrl+G / Ctrl+Shift+G
  and F3 / Shift+F3 step (re-opening a closed card), Escape closes from the
  field or the page and keeps the query; an address edit's Escape wins. A
  picture (`viewer_chrome.canFind`) declines every find chord, and navigating
  to one closes an open card. Ctrl+G with no query yet is declined too.
- After every load an open search is pushed again, ahead of the template's
  render; the page's own observer then counts the rendered document, so a
  navigation, Back, or a live reload keeps the count live.
- Find's page calls evaluate with no callback (`runQuiet`): they must not
  count as renders for the test seam's `wait`.
- **Driving it headless**: the steps seam's `find <text>` sets the field (its
  `changed` runs the search), `click find-previous|find-next|find-close`, and
  `state` reports `find= findq= findsel= count= note=`. The highlights are
  read from `CSS.highlights` with a `probe`; `find.js` keeps the current
  match in its own highlight, so three matches read `2/1`.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-find.sh
```

Ends `VIEWER FIND: ALL PASS` (27 checks).

### Links, popups and the link menu (T3415)

Every decision is the shared one - win32's pure `viewer_content.classifyLink`
/ `livePageLinkAction`, `viewer_popup`, `banner_link` - reached through the
GTK-only `src/apprt/gtk/viewer_links.zig` (none lane), which does two
translations and nothing else:

- **Origins.** `canonical` rewrites `ghoztty-viewer://page/...` and
  `ghoztty-page://page/...` into win32's `https://ghoztty-viewer/...` /
  `https://ghoztty-page/...` before a URI meets the shared rules, so a
  relative doc link is `.relative` and a rendered page has a site to leave.
- **Which navigation is a click.** WebKit reports the Mac's own
  `navigationType`, so only `LINK_CLICKED` without a redirect is routed;
  Back/Forward, reloads, form posts, script navigations and the pane's own
  loads (`OTHER`) are followed in place. No "my own navigation" counter is
  needed (win32's `self_nav_pending`).

What the user gets: in a markdown/code pane http(s) goes to the default
browser, a relative `.md`/`.html`/image/diff link opens a viewer split to the
right, any other file opens in its default app, a link to nothing or a
`mailto:` does nothing (the missing file is logged), and a `ghoztty://` link
focuses its target in THIS app (`IpcHandlers.focusLink` -> the shared
`verbs.focus`, looked up from the clicking pane's window). A live page (a
website, a rendered `.html`) follows its own site in place - host + port as
written; a rendered page's site is its folder - and a click off it takes the
banner's scheme: plain -> browser, Ctrl -> side pane, Ctrl+Shift -> a viewer
window (a `file://` link: reveal / side pane / its app).

- **`decide-policy`** (navigation actions only) runs `links.decide`, ignores
  anything not `allow`, and routes it.
- **`file://` links are refused by WebKit before the policy runs** ("Not
  allowed to load local resource": a non-`file:` page may not navigate to
  `file:`, and our pages are custom-scheme pages, unlike the Mac's). A small
  GTK-only user script (`file_link_js` in `Viewer.zig`, top frame) takes a
  TRUSTED left click on a `file:` link instead and posts it with its
  modifiers on the `ghozttyFileLink` handler; the same `links.decide` routes
  it. Untrusted (script-made) clicks are ignored so a page cannot fake a
  Ctrl+Shift into launching a local file's app; a debug test run allows them.
- **Popups**: `create` runs `links.decidePopup` - the browser, unless
  Ctrl-clicked; a Ctrl-click off-site is a link click (the scheme above); a
  `ghoztty://` popup focuses. A popup that stays in Ghoztty (Ctrl-clicked, a
  bare `window.open()`, a non-web scheme such as a rendered page's own
  `ghoztty-page:` folder) is ADOPTED (T3447): `create` returns a web view
  built with `g_object_new(..., "related-view", opener, "user-content-manager",
  <its own>)` - related, so `window.opener` and `window.close()` work; its own
  content manager, because a related view otherwise SHARES the opener's and
  the popup's page messages would reach the opener's handlers. It inherits
  the opener's read grant. On `ready-to-show` the pane hands it to
  `Surface.pending_popup` and opens a one-pane viewer window
  (`Application.newViewerWindowSized`) at the window-properties geometry,
  clamped by win32's `viewer_popup.requestedSize` at scale 1
  (`viewer_links.popupSize`). WebKitGTK has no "a size was given" flag and
  its bar flags stay visible whatever the page passed: with no size it
  reports its own fallback rect (800x600 for a scripted open, 100x100 for a
  `_blank` link, measured), so those exact rects at 0,0 mean "no size".
  `about:blank` is its location when it named
  none. WebKit's `close` (the page's `window.close()`) closes the pane from
  an idle. A popup closed before it was shown is destroyed unhosted. Custom-
  scheme pages are cross-origin to one another, so a test talks to an
  adopted `ghoztty-page:` popup by `postMessage` (which only arrives through
  a real `window.opener`), not by reaching into its document.
- **The link menu**: the shared `links.js` is a user script in EVERY frame
  (an iframe's link gets the menu too); it declines a `#fragment`, a click in
  a selection and schemes with no action, and posts `linkMenu` on
  `viewerTOC` - the one message an iframe's post is acted on for (T3554,
  below). `ghoztty-page:` is in its scheme list for this platform. The
  href is resolved to what the menu acts on first (a relative doc link or a
  page link is the FILE, a broken doc link the file it meant), then a
  `GtkPopoverMenu` pops at the last pointer position over the page, rows,
  order and ids `banner_link`'s with Linux titles (`Open Containing Folder`
  for reveal, the nav bar button's own wording), separators as GMenu
  sections.
- **Opening things**: the browser is `GtkUriLauncher`, a default app
  `GtkFileLauncher`, reveal the bar button's `open_containing_folder` road,
  a split `SplitTree.newSplitAt(.right, ..., .focus = false)` from the pane's
  `Tab` - a SIDE PANE, like the Mac's `newViewerSplit` (T3748): the clicking
  pane keeps the caret and the new pane is featured, so it is on show; a window
  `Application.newWindowForIpc` with the location as `view`.
- **Nothing a test does may leave the app**: inside WSL `xdg-open` can
  reach the Windows browser. A debug build with `GHOZTTY_TEST_VIEWER_LINKS=<file>`
  appends every hand-off there (`browser|app|split|window|focus|copy|reveal|menu
  <target>`) and runs the browser/app ones NOT AT ALL; a debug test run
  (`GHOZTTY_TEST_VIEWER_DUMP` set) without the sink refuses them and logs
  `refused to hand`. The menu is not popped under the sink (a seatless
  Weston cannot grant a popup grab); it records `menu <kind> <target>
  rows=a|b,c|d`, and the steps' `menu-pick <row>` runs a row. WebKit drops
  the modifiers of a script-made click, so `mods ctrl|ctrl+shift|none` stands
  in for the keyboard; reading a REAL click's modifiers off WebKit, and the
  popover on screen, are the parts only a person at a desktop sees.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-links.sh
```

Ends `VIEWER LINKS: ALL PASS` (46 checks; K10a-K10c are T3748's caret and
featuring of a link's side pane).

### Which frame posted: the private-world relay (T3554)

WebKitGTK's `script-message-received` carries the value and no frame, and a
handler registered in the page's own world is visible to EVERY iframe. So the
page bridge is split the way win32's `ViewerPane.onFrameMessage` splits it -
a subframe may post the link menu and nothing else - with the shared page
scripts untouched (`src/apprt/gtk/viewer_frames.zig`, none lane):

- The native handlers, `ghozttyTop` and `ghozttySubframe`, are registered in
  the private script world `ghoztty`. No page script, in any frame, can see
  them.
- `shim_js` (page world, every frame, document start - before any page
  script) defines `window.webkit.messageHandlers` with the two names our
  scripts post on, `viewerTOC` and `ghozttyFileLink`. `postMessage`
  serialises the value and fires `__ghozttyBridge` on the frame's OWN
  document as `"<name>\n<json>"`.
- `relay_js` (private world, every frame, document start) hears that event
  in its frame and forwards the string on `ghozttyTop` when
  `window.top === window`, else on `ghozttySubframe`. A cross-origin iframe
  cannot fire an event on the top document, so its only road ends at
  `ghozttySubframe`, which takes `linkMenu` (`links.js` runs in every frame)
  and logs `viewer: dropped a subframe's <kind> post` for the rest - a quote,
  headings, active, find, or a file link.
- Anything new that posts from a page goes through the shim's names; a new
  handler name means a new entry in `shim_js` and `split`, never a page-world
  registration. Code the app evaluates (`evaluate_javascript`, test probes)
  still runs in the page world, so `window.webkit.messageHandlers.viewerTOC`
  there is the shim.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-subframe.sh
```

Ends `VIEWER SUBFRAME: ALL PASS` (16 checks): a cross-origin iframe's quote
(and one forged by firing the relay's event itself), headings, active, find
and Ctrl+Shift file link are all dropped and its link still gets the menu,
while the same quote and file link from the top page are acted on.

### Image panes (T3416)

`--view=<picture>` (the shared extension table, `win32/viewer_image.zig`) is
win32's shape, not the Mac's native scroll view: the template's `image.js`
draws the picture, and every zoom rule is win32's pure `Geometry` - 100% is
one image pixel per device pixel (an SVG's is its intrinsic size), best-fit
never upscales, double-click toggles fit <-> 100% (fit <-> 200% for a picture
smaller than the pane), Ctrl +/- step 1.25x, Ctrl+0 is 100%, a resize re-fits
a fitted picture and keeps a chosen zoom. The GTK half is
`src/apprt/gtk/ViewerImage.zig`; its pure rules `viewer_image.zig` (none
lane).

- **Bytes**: the page loads `ghoztty-viewer://page/__image?v=<revision>`,
  answered from the viewed file - streamed (`g_file_read`) when WebKit can
  draw it. TIFF/HEIF (WebKit cannot) and any raster WebKit fails on are
  decoded on a worker thread by `gdk_texture_new_from_filename` and served as
  PNG (`route=wic` in the log, win32's name for the host route); an `.icns`
  serves its largest embedded PNG. Nothing decodes it: the template's
  `Cannot display this image` card, or - for a real HEIF/AVIF container -
  `Linux needs a HEIF image loader (heif-gdk-pixbuf) ...`.
- **Reloads re-decode** (a save, `+reload`, Ctrl+R) as a new revision, and keep
  the zoom AND the scroll when the pixel size is unchanged (the Mac's
  `reloadFromDisk`; `image.js` takes a 4th `keep` argument for the scroll).
  A different size re-fits. win32 does not keep them yet (T3532).
- The chords zoom the PICTURE, never the page; find declines (no text).
  A viewer pane cannot be split narrower than its nav bar, about 260 px
  (T3533).
- **Ctrl+C (or Ctrl+Insert) copies the picture and its file** (T3534; Mac's
  `ViewerImageSurface.copy`, win32's T1872/T1909), claimed ahead of the page,
  whose bare `<img>` has no selection. `ViewerImage.copy` decodes the FILE
  (`gdk_texture_new_from_filename`, an `.icns` its largest PNG) and sets one
  union provider on the clipboard: the `GdkTexture` (GDK offers it as
  image/png, tiff, jpeg, bmp, ico), then `text/uri-list` and
  `x-special/gnome-copied-files` (`copy`, never `cut`), so a paste into
  Nautilus copies the file. Ctrl+Shift+C is not it (as on win32), and the
  address/find fields keep their own Ctrl+C. Log line: `viewer image copy
  ok= size=WxH file= route= offered=<formats> path=`. Headless, the clipboard
  is local (the provider answers in-process) - the steps seam's `clipboard`
  step reads the formats and the texture back through GDK. Open: a JPEG's
  EXIF orientation may not be applied to the copy (T3603).
- **Reading it back**: every decision is a `viewer image ...` log line, and
  the steps seam's `image` step prints `rev= loads= route= zoom= fitting= fit=
  natural=WxH viewport=WxH`. A picture's `wait` is its decode-and-fit (the
  `loaded` answer), not the `setImage` call.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-image.sh
```

Ends `VIEWER IMAGE: ALL PASS` (34 checks).

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-viewer-panes.sh
```

Ends `CLI VIEWER PANES: ALL PASS` (21 checks).

### Table of contents (T3418)

A markdown pane with two or more headings gets a CONTENTS card
(`src/apprt/gtk/ViewerTOC.zig`); every layout decision is the pure
`src/apprt/gtk/viewer_toc.zig` (none lane) over win32's
`viewer_toc_layout.zig` numbers (720 px threshold, 240 px default width,
170-460 range, 12 px margin, three indent steps, two lines a row).

- **The page reads; the card follows.** `viewer.js` indexes the headings
  and posts `headings` and `active` (the scroll spy) on `viewerTOC`. A row
  click runs `scrollToAnchor`, which pins the spy through the smooth scroll;
  the reader's next wheel/key/mouse gesture releases it. This side never
  sets the selection itself, so it cannot fight the pin. A website posting
  the same messages gets no card (markdown only).
- **Wide pane (>= 720 px)**: the card floats over the page's top-left and
  the page reserves `margin + card` as its own padding
  (`window.__viewer.setGutter`), so the strip behind the card is the
  document's background. The 7 px band right of the card drags the width
  (`GtkGestureDrag`); the saved width is the `viewer_prefs` one the diff
  panel shares.
- **The edge lights the gutter bar** (T3732; Mac
  `SidePanelResizeHandle.gutterBar`, win32 T2265): the band is a vertical
  box holding a non-targetable 4px `.gutter-bar` (the stage's class, so the
  same accent and glow), centred, the band's whole height. Its opacity is
  `gutter_bar_rules.single(hovered, dragged)`: 0.5 while the motion
  controller says the pointer is on it, 1 from `drag-begin` until
  `drag-end` or the gesture's `cancel` (so the pointer running off the band
  mid-drag keeps it lit), else 0. The bar is laid out inside the band, so
  it moves with the edge and stops where the width clamps.
- **Narrow pane**: an overlay over the document. The nav bar's first item
  (`sidebar-show-symbolic`) opens and closes it. Entering the narrow layout
  closes it, a row click dismisses it, and nothing is reserved.
- **The pane width is measured live** by a `GtkDrawingArea` overlay
  (`can-target` off) whose `resize` reports the page area. A split divider
  drag or a window resize switches the layout either way.
- The open state is never saved. Only the width is.
- **Driving it headless**: the steps seam's `toc` prints `bar=none|hover|drag
  baropacity= barrect=x,y,w,h edgerect=x,y,w,h` (window px) then `mode= open=
  card= button= handle= rows= active= selected= width= cardw= shownw= gutter=
  pane=WxH`, `toc-rows` the `id:depth` list, `toc-row <id>` clicks a row,
  `toc-drag <dx>` drags the edge, `toc-hover on|off` is the band's
  enter/leave, `toc-press <dx>` takes hold and moves it (held until
  `toc-release <dx>`), `click contents` the button, and
  `resize WxH` resizes the window (`gtk_window_set_default_size`, which
  headless Weston honours). The page's padding is read with a `probe`.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-toc.sh
```

Ends `VIEWER TOC: ALL PASS` (34 checks; C26-C34 are the bar, read from the
seam and from a `capture-pane --window` picture at each strength - a
capture taken just after the held edge re-lays out the page can find no
frame yet, so the script retries it).

### The feedback button and worktree provenance (T3419)

The first slice of `docs/reference/viewer-feedback.md` (the composer is
T3544, quoting T3545, screenshots T3546). `src/apprt/gtk/ViewerFeedback.zig`
puts an icon-only button (`chat-message-new-symbolic`) at the trailing end of
the nav bar, shown only while the pane's content belongs to a git working
tree, tooltip `Send feedback to <root>`. Which tree is the shared strategy D
(win32's `viewer_worktree.zig` `Plan`/`Cache`), with the POSIX parts in the
pure `src/apprt/gtk/viewer_worktree.zig` (none lane):

- **Leg 1**: a file pane's own folder (POSIX paths; a missing folder falls to
  the origin). **Leg 2**: an `http(s)://localhost|127.0.0.1|::1|0.0.0.0:<port>`
  page is the LISTENING process's cwd - Linux's lsof is `/proc/net/tcp{,6}`
  (the LISTEN row's socket inode) -> the `/proc/<pid>/fd` link that is
  `socket:[<inode>]` -> `/proc/<pid>/cwd`. Another user's process has an
  unreadable fd table and reads as no listener. **Leg 3**: the pane's
  `--working-directory`. Then `git rev-parse --show-toplevel`.
- It runs on a detached worker (win32's `git_run.capture`), lands through
  `g_idle_add` and a ref-counted `Link`, and is tagged with a generation, so
  an answer for a location the pane already left is cached but not shown.
  Answers (negative ones too) are cached per (location, origin) for 15 s; a
  refresh for the question already in flight launches nothing.
- Asked when the pane is told its origin (before the first load commits) and
  on every committed navigation (`syncCommitted`).
- **Driving it headless**: the steps seam's `feedback` waits for a resolution
  in flight and prints `feedback button= worktree= tip= pending= resolves=
  clicks=`; `click feedback` clicks it. Log lines: `viewer feedback:
  worktree=<root> name=<name>` / `worktree=none`, `port <n> is served from
  <cwd>`, `composer open ...`.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-feedback.sh
```

Ends `VIEWER FEEDBACK: ALL PASS` (16 checks).

### The feedback composer and the report it files (T3544)

The button toggles a band under the nav bar (`ViewerFeedback.zig`, second
half): a pill holding the SHARED `src/viewer/composer.js` page in a second
`WebKitWebView` (win32's D43 shape), a round send button, and a footer line.

- **No fork of the page.** `composer.js` talks to `window.chrome.webview`
  (WebView2). `src/apprt/gtk/viewer_feedback_host.zig` (none lane) injects a
  document-start shim that defines that object over WebKit's
  `ghozttyComposer` script-message handler (up) and a
  `__ghozttyComposerDeliver(json)` hook that `evaluate_javascript` calls
  (down). Change the protocol in `composer.js` + `viewer_feedback_page.zig`
  and both platforms follow.
- **Chords live in the shim**: Ctrl+Enter posts `{t:"send"}`, Escape
  `{t:"close"}` (keydown, capture phase); plain Enter is the engine's newline.
  `hostVerb` takes those two before the shared parser, which drops unknown
  `t`s by design.
- **The view exists only while open**; the text lives on the pane
  (`feedback.text`) and every `ready` re-seeds the page from it, so
  close/reopen keeps it. A snapshot whose `gen` is older than the last seed is
  dropped.
- **Send** reads the page's selection (async `evaluate_javascript` on the
  page view), then a worker asks git for branch + commit at SEND time and calls
  win32's pure `viewer_feedback_report.write` (staging + one rename into
  `<worktree>/temp/feedback/new/<stem>/report.json`). Success clears the text,
  shows `Filed temp/feedback/new/<stem>`, and closes after 1.5 s. A file pane's
  `pageTitle` is the file name (the template's own title is ours).
- **Colours follow the style (T3552).** `pushVars` reads
  `AdwStyleManager:dark` and the theme's `@card_bg_color` (composited onto
  `@window_bg_color`) and `@accent_bg_color`, and `composer_palette.zig`
  (pure, none lane) derives fg/bg/placeholder/selection/quote/chip with
  win32's `chrome_theme` (the same contrast floors). A card read that
  disagrees with the dark flag is a stale stylesheet and falls back to
  Adwaita's own (#ffffff / #363636). `notify::dark` re-pushes while a
  composer page exists. Note the app's default `window-theme = auto` picks
  dark from the default background, so the composer is dark out of the box.
- **The draft folder and the footer link (T3553; Mac `feedbackDraftStem` +
  `stagingLink`, win32 T645).** Opening the composer mints a draft stem
  (`ViewerFeedback.stem_buf`); the footer shows
  `<worktree name>/temp/feedback/.staging/<stem>` as a flat link (folder icon,
  middle-ellipsized) whenever there is no status line, and the status takes its
  place after a send or a failure; the key hints sit at the trailing edge.
  Nothing is written until the link is clicked: `revealDraft` stages the
  draft (`report.stage`, from the same `draftParts` the send uses, minus
  branch/commit/selection) and opens the folder with `Viewer.openWithAppFrom`,
  which a test run refuses and logs (`a test run refused to hand <folder> to
  the desktop (app)`). The send passes the stem to `report.write`, so files the
  user dropped in ride along into `temp/feedback/new/<stem>/`; a filed report
  retires the stem, and the next open mints a new one. Staging also sweeps any
  other draft folder untouched for a day (`pruneStaleStaging`).
  Quoting and pictures are the next sections.
- **Steps seam**: `composer` prints `open= view= ready= lines= sending=
  sends= quotes= quoted= style= bg= vars= stem= link= reveals= staged= filed=
  status=... text=...` (`link` = the footer link's label while it shows, `-`
  otherwise; `click feedback-folder` clicks it)
  (`vars` = palette pushes) once the page is up and
  no send is out (`quotes` = live blocks, `quoted` = ever registered);
  `composer-type <text>` types through `insertText` (`\n` = newline);
  `composer-key ctrl+Enter|Escape|Enter`; `composer-probe <js>` evaluates in
  the composer page; `click feedback-send`; `style dark|light|default` sets
  the app's libadwaita colour scheme.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-composer.sh
```

Ends `VIEWER COMPOSER: ALL PASS` (27 checks, about 2 minutes; C24-C27 are
the style). The draft folder has its own script, `test\linux\viewer-composer-draft.sh`:
ends `VIEWER COMPOSER DRAFT: ALL PASS` (17 checks, about 2 minutes; it drops a
`crash.log` into the staged folder between the click and the send, and seeds
a two-day-old and an hour-old draft folder for the sweep).

### Quoting a page selection (T3545)

Selecting text in any viewer page (the template or a website) shows the
SHARED `src/viewer/selection.js` Quote/Copy toolbar (shadow root, so page CSS
cannot touch it), injected by `Viewer.installFindScript` beside `find.js`:
top frame only, document end - win32's rule, since the bar positions itself in
viewport coordinates a subframe does not share. It posts on `viewerTOC`.

- **Quote** -> `bridge.parse` `.quote` -> `ViewerFeedback.acceptQuote`:
  register it (win32's `viewer_feedback_doc.Registry`), splice the passage in
  at the composer's caret as its own block (`viewer_feedback_doc.insertion`),
  and open the composer; an already-open page gets an `undo: true` seed so
  Ctrl+Z takes it back out. A pane in no worktree drops it (logged).
- **The page's nodes are the truth** (T935): every seed carries the spans
  down as `{id,start,end}` in UTF-16 units, every snapshot brings them back,
  so deleting a block drops its metadata and rewording keeps it. All the
  arithmetic (caret units <-> bytes, ids <-> registry indices) is the pure
  `src/apprt/gtk/viewer_quote.zig` (none lane).
- **Send**: `body` renders each live block as a markdown `> ` quote
  (`report.renderBody`); `quotes` carries text, headingId/Text,
  blockSelector/Text, offsetInBlock, documentOffset, editedText, and for a
  file pane `sourceLine`, found by searching the file on the send worker.
- **Copy**: GTK sets `window.__ghozttyHostCopy`, so the shared script posts
  `{type:"copy",text}` instead of using the page's async clipboard, and the
  app writes the GDK clipboard (`Viewer.copyText`, which also feeds the
  `GHOZTTY_TEST_VIEWER_LINKS` sink as `copy <text>`). Mac and Windows never
  set the flag.
- **Driving it headless**: there is no pointer, so the test selects with a
  `Range` in a `probe`, dispatches the `mouseup` that places the bar, then a
  `mousedown` on `[data-ghoztty-ui]`'s shadow-root `button[title=Quote]`.
  Log line: `viewer quote id= bytes= heading= block= offset= live=`.
- The shared composer page folds one newline under a quote block into the
  block's boundary when you type below it (`fox\n\n` + typing reads back
  `fox\nnote`); the report body is still right.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-quote.sh
```

Ends `VIEWER QUOTE: ALL PASS` (26 checks, about 2 minutes).

### Pictures in the composer: screenshots, pastes, the strip (T3546)

The pill has the Mac's two circular buttons: **`+`** takes a screenshot of the
pane, **`↑`** sends. **Ctrl+Shift+S** in the composer is the `+` (the shim
posts `{t:"shot"}`, `viewer_feedback_host.HostVerb.shot`).

- **The picture is the app's own render.** Wayland has no global capture and
  the headless Weston has nothing a client can ask for, so
  `src/apprt/gtk/pane_snapshot.zig` snapshots the widget's paintable into a
  render node, renders it with the window's own GSK renderer to a texture,
  and saves PNG. The widget is the pane's page (`Viewer.view`), so the shot is
  the page at the viewport's size in device pixels; WebKit's composited layer
  is part of that node. T3359 (the harness screenshot) reuses the same
  function.
- **A paste or a drop** is the shared page's own path: `composer.js` decodes
  it to PNG and posts `{t:"image",png}`; one it cannot take arrives as
  `{t:"image",err}` and the footer says why. `image_max_bytes` is the store's
  32 MB cap, so an oversized paste is refused at the page.
- **Chips, numbers, report**: win32's pure `viewer_feedback_images.Store`
  allocates the stable number; `src/apprt/gtk/viewer_shot.zig` (none lane)
  splices `[Image #N]` at the page's caret (UTF-16 units), moves the quote
  spans past it, seeds the live chips down as atomic nodes, and builds the
  report's `images` + body links (`![Image #N](images/image-N.png)`, after the
  quote rendering - win32's order). What is attached is derived from the
  text: delete a chip and its picture leaves the strip and the report, and
  the numbers left keep their gaps. A filed report clears the store.
- **The strip** under the pill is a horizontal `GtkScrolledWindow` of flat
  buttons (picture fitted into 56 px over `#N`), one per live chip, rebuilt
  only when the live list changes, hidden when empty. The tile whose chip holds
  the caret (or the one last clicked) carries `suggested-action`; a click
  posts `{t:"pick",n}` so the page selects that chip whole.
- **Steps seam**: `click feedback-shot`, `composer-key ctrl+shift+S`,
  `thumb <n>`; the `composer` line adds `images=1,3 tiles=1,3 sel= shots=
  shot=WxH`. Log lines: `viewer feedback: image=#N via=screenshot|paste
  bytes= size=WxH live=`, `carousel tiles= images=`, `thumb #N picked`.
- Headless the paste is a `ClipboardEvent` carrying a canvas-made `File`
  (falling back to a `drop`), dispatched in a `composer-probe`.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-screenshot.sh
```

Ends `VIEWER SCREENSHOT: ALL PASS` (21 checks). S19 decodes both PNGs with
python's zlib: the shot is the viewport's width and not blank, the paste is
30x20, and `bytes`/`pixelWidth`/`pixelHeight` match the files.

### The viewer foundation's own test (T3410)

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-webkit.sh
```

Ends `VIEWER WEBKIT: ALL PASS` (11 checks: the link, markdown with a file read
from beside it, highlighted code, a local page with its own CSS/JS and its
grant enforced both ways, a loopback website, the missing-file card, and the
terminal still on D3D12).

## Copy out of a TUI, and links across its wraps (T3565)

`docs/reference/copy-reflow.md` is shared core (`src/terminal/hard_wrap.zig`,
the formatter's `reflow`), and every GTK copy path already reaches it: Ctrl+
Shift+C / Ctrl+Insert and the menu's Copy are the `copy_to_clipboard` binding,
copy-on-select (a drag's release, select-all) goes through the core's
`setSelection`, and both end in `copySelectionToClipboards` with `.reflow =
true` before `Surface.setClipboard` hands the text to GDK. Nothing in
`src/apprt/gtk/` builds clipboard text of its own from the grid (the one other
`setClipboard` caller copies a tab title). Link hover, click and Copy URL are
core too (`linkAtPin` with `.hard_wraps`).

What GTK had to change: a terminal link click lands in
`Application.openUrl`, which hands it to the portal or `xdg-open` - and inside
WSL that can reach the Windows browser. It now takes the viewer's rule
(`Viewer.leavesApp`): in a debug build it is recorded as `open <url>` under
`GHOZTTY_TEST_VIEWER_LINKS`, or refused under `GHOZTTY_TEST_VIEWER_DUMP`.

Two debug-only seams, compiled out of a release:

| Seam | What it does |
|---|---|
| `pane-mouse --target=<pane> [--cell=<col>,<row>] [--mods=ctrl\|shift\|none] [--button=press\|release\|click]` | The pointer: a motion to the CENTRE of a viewport cell (converted through the pane's own cell size and padding), stored where `getCursorPos` reads it, then the left button. Reply `over_link`, `x`, `y`. A drag is a press at one cell and a release at another; a drag includes a cell only once the pointer is past its midpoint, so end one cell PAST the last character. |
| `read-clipboard --target=<pane> --out=<abs file> [--primary]` | Reads the pane's GdkClipboard (or PRIMARY) - the object the copy filled - asynchronously; the text lands in `<out>`, or the reason in `<out>.err` (renamed into place, never half-written). |

**And from outside the app: wl-paste (T3620).** The run uses
`hl_start_seat` (headless sway, which has the seat the default Weston lacks),
so another Wayland client can be offered the copy. P1 is the control: right
after select-all, before the app has any key serial, `wl-paste --primary`
gets nothing ("Nothing is copied"). That proves the outside checks can fail.
P2 runs `hl_key_serial`. P3-P5 then require `wl-paste` to return **the same
bytes** `read-clipboard` returned: the clean prose from Ctrl+Shift+C, the
dragged paragraph from PRIMARY (`--primary`, the middle-click paste), and the
whole URL from Copy URL.

Acceptance (27 checks, R1-R22 and P1-P5: the fixture `test/linux/lib/copy_reflow_fixture.py` is
a fake TUI that word-wraps a paragraph behind a `⏺ ` gutter and a too-long URL
to the pane's real width, the way Ink/wrap-ansi do; `+read` is the negative
control that the same check fails on the screen as laid out):

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\copy-reflow.sh
```

Ends `COPY REFLOW: ALL PASS`. Not covered here: a rectangle selection (left
exactly as selected), which needs the seam to grow the rectangle modifier (T3621).

## The pane style: gradient desk, elevated cards, focus glow (T3566)

`docs/reference/pane-style.md` on GTK. Three pieces:

- **The desk** is drawn by the window (T3623; it was the split tree's until
  then): `Window` overrides the widget `snapshot` vfunc (`snapshotDesk`) and
  appends a small texture of its gradient, stretched over the toolbar view's
  bounds - header bar, tab bar and the sidebar row - before any child. So the
  gradient runs up under the header bar (Mac's transparent titlebar) and
  under the pane sidebar, and the split tree draws nothing of its own. The
  window's classes `pane-desk-window` (+ `-light`, `-glass`;
  `Window.syncDeskClasses`, run from `syncPaneStyle`) make the header bar,
  the toolbar's top/bottom bars and the tab bar transparent in `style.css`.
  On glass the sidebar card is an unfocused pane's card (Mac
  `PaneSidebarCard` -> `PaneCard`): 11px corners, the card's rim and shadow
  in CSS, and its 40% sheet (`pane_style.sidebarSheet`) painted by the
  window inside those corners. Off glass it keeps its own light wash, which
  the desk reads through. Tab-overview thumbnails show the cards without the
  desk (the overview renders the tab alone). The colours
  are win32's `desk_palette.zig` (Mac's `PaneDeskPalette`/`PaneDeskVariant`,
  draw for draw through the same SplitMix64), rendered at win32's downscale and
  cached per size/seed/theme (`pane_style.DeskKey`). Light vs dark follows the
  configured terminal background's luminance, as on win32.
- **The cards** are CSS (`style.css`, `.pane-elevated`): every pane's
  `SurfaceScrolledWindow` gets `pane-card` (11px radius, hairline rim, two-layer
  shadow) and `gtk_widget_set_overflow(HIDDEN)` so the terminal is clipped to
  the corners; the tree's 5px padding plus each card's 5px margin is the one
  10px gutter. The focused card of several gets `pane-focused` (outset glow +
  34% rim). `SplitTree.syncPaneStyle` sets the classes after every rebuild and
  focus move, and `Window.syncAppearance` re-runs it on a config reload, so
  `macos-pane-style` applies to every window at once.
- **The window's gradient** lives on `Window` (`deskVariant`): a hand-opened
  window follows `macos-window-gradient` (random by default); `+new-window`
  sets it from `--color` (`random` in the elevated style = its own gradient and
  NO terminal tint; `#hex` or none = the ocean, and `#hex` tints as before).

**Trap: `style-dark.css` beats `style.css`.** libadwaita loads them as two
providers, and between providers order wins, not specificity - a rule in
`style.css` that the dark sheet also sets (the paned separator) must be
repeated there, or it silently loses in a dark theme.

**Glass panes (T3622, `macos-pane-glass`, default on, elevated only).** The
Mac's layering, not win32's backdrop: the renderer draws no terminal
background (`generic.zig` `pane_glass_sheet_in_apprt` covers GTK), and the
pane's `Surface` paints the sheet in its own `snapshot` vfunc before its
children - the pane's background (`--color` tint, else the configured one) at
40%, and 25% over the banner card's frame (`pane_style.sheetBands`), all inside
the card's `overflow: hidden` clip. The tree's `pane-glass` class makes the
banner a rim-and-shadow card with no wash. A viewer's template pages get a
transparent web view plus `html.pane-glass` (`Viewer.applyGlass`, re-run on
every commit and load; the rules are win32's pure `viewer_glass.zig`). The
unfocused wash closure in `surface.blp` binds `template.config`, or a reload
that turns glass on would leave the wash up until the next focus change.

**Measuring glass: difference, not absolute.** The desk under a card cannot be
read (the gutter beside it is inside the card's drop shadow), so pane-style.sh
reads each probe under two dark backgrounds and checks the pixel moved by
40% (25%) of the change; G7 is the negative control (solid moves by 100%).

**The window's gradient survives a relaunch (T3623).** The session layout
records the window's seed as `desk_variant` (win32's field, Mac
`deskVariant: {seed}`; `session_layout_rules.deskSeedToRecord`), and the
restore gives it back (`deskSeedToRestore`): the recorded seed, else the
ocean - never the fresh random gradient a hand-opened window would draw.
In-place agent recovery keeps the window object, so its gradient never
moves. Acceptance: RD1-RD3 of `test/linux/session-restore.sh`.

Not yet: the 1px line down the flat style's gutter (T3624; the 6px gutter itself came with T3567's stage).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\pane-style.sh
```

Ends `PANE STYLE: ALL PASS` (28 checks; geometry and pixels from the window's
own render via `capture-pane --window`, probed with `hl_png_pixel`; D1-D4 are
the desk under the header bar and the sidebar, D4 the flat control).

## Stacked panes: one stage the shared layout places (T3567)

`docs/reference/stacked-panes.md` on GTK. A split tab is no longer nested
`GtkPaned`s: `SplitTree.onRebuild` puts every card on ONE stage (a `GtkBox`
with a `GtkCustomLayout`, `SplitTree.newStage`), and its allocate callback
(`placeStage`) lays the tab out with win32's pure engine, imported in place
like `pane_layout.zig` already was: `pane_stack_grid` (tree -> frames),
`pane_stack_state` (focus history, collapses; one per `SplitTree`) and
`stack_drag` (every gutter drag). So GTK and win32 compute the same layout
from the same tree. A lone or zoomed pane still sits in the tree's `AdwBin`.

- **Minimum and stacking.** `macos-pane-min-width/-height` (read every
  layout, so a reload restacks). A row that cannot fit keeps a run on show and
  minimizes the rest. A minimized card is hidden with `child_visible` (never
  re-allocated, so its terminal keeps its last size) and its **strip face** -
  a `.pane-strip` label named by the sidebar row's rule
  (`pane_sidebar_rows.text`) - is allocated over its tab, turned 90 degrees in
  a row (`gsk_transform_rotate`; `pane_stage_rules.labelPlacement`). Faces are
  blades (T3729, below): each is drawn at its whole tab and overlaps the
  strip in front by its tuck.
- **Focus brings a pane forward.** `placeStage` notes the last-focused pane
  (`noteFocus`); `propSurfaceFocused` and `focusSurface` (CLI `--focus`, the
  sidebar) queue a relayout. A strip click is a press + release on the stage's
  `GtkGestureDrag` (`stagePress`/`stageRelease`).
- **Gutters.** Every divider and grip is a `RowDrag` (`stagePress` hit-tests
  `Grid.dividerAt`/`stackHandleAt`; `stageDrag` applies the step's ratios with
  `resizeInPlace`), with a `col-resize`/`row-resize` cursor over it.
- **Gutter widths.** Elevated: the engine's 10px gap, the grid inset by the
  card's 5px CSS margin, and each card allocated that margin larger
  (`cardAllocation`), so the look is T3566's exactly. Flat: Mac's 6px
  `flatGap` (pane-style.sh S12); the 1px line in it is T3624.
- `+list` reports `minimized` (`SplitTree.isMinimized`).

**The `pane-stack` seam** (debug only): `pane-stack --target=<pane>
[--press=x,y] [--drag=dx,dy]... [--release=dx,dy]` replies the stage as laid
out (each pane's frame, `minimized`, `focused`, strip rect; every gutter by
kind `divider|grip|edge`) after running the press/drag/release through the
same functions the real gesture calls - the headless harness has no seat.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\stacked-panes.sh
```

Ends `STACKED PANES: ALL PASS` (44 checks since T3629).

### Glides and paint order (T3625)

A change in what is on show (a strip click, focus onto a minimized pane, a
fold under a drag, a split or a close) is a **glide**, driven by win32's pure
follower `pane_stack_slide.Slide` (Mac `PaneStageView.glide`, 45ms time
constant), imported in place like the rest of the engine:

- **`SplitTree.planGlide`**, run by every placement, compares the layout with
  the last one (`Private.placed`, which outlives a rebuild so a split or close
  glides across the new stage): `runsChanged` plans a glide (`plan`, with
  `resize` under a drag); under a drag `retarget` follows the hand; a new grid
  rect (window resize) lays out at once. A minimized pane is held at its last
  size on show (`Private.held`, `pane_stack_slide.hold`).
- **The clock** is a tick callback on the `SplitTree` (`glideTick`):
  `Slide.step` with the frame clock's step (`pane_stage_rules.frameStep`), then
  `queue_allocate` the stage. A glide that catches up under a held drag stops
  its clock and rests (the next move's `retarget` wakes it); let go, it goes
  on for the 50ms tail (`pane_stage_rules.gesturing`) and lands. It dies with
  the tree (`endGlide(true)` on dispose and whenever the tab stops showing a
  stage).
- **A card holds its content.** Every card (`SurfaceScrolledWindow`) gets a
  custom layout (`installCardLayout`): a bin's, unless `Private.holds` has the
  card this frame, when its child keeps the held size, offset where the glide
  pins it (`pane_stage_rules.heldContent`), and the card (overflow hidden, its
  rim and rounded corners its own) cuts it. So a card narrows into its strip
  around a terminal that is never resized, and each terminal takes its new
  size once, when its card lands.
- **Fades.** A card going into or out of its strip fades its content by
  `1 - collapse` and shows its strip face over the card at `collapse`
  (`pane_stage_rules.fadeAt`, over the last 120px, `strip_face.fadeOf`).
- **Paint order** is `pane_stack_layout.paintOrder` (`Leaf.elevation`), each
  face just above its card (`paintByElevation`, a no-op when already in
  order), so a card tucking away passes under the run.
- `GHOZTTY_STACK_SLIDE_MS` stretches the glide (win32's knob; 0 is none), and
  `adw_get_enable_animations` off means no glide.
- The `pane-stack` seam reports, per pane, `drawn` (the card as drawn this
  frame), `gliding`, `fade`, `content_w` (the content's real allocated width)
  and `resizes` (the terminal's size changes, `Surface.sizeChanges`), plus the
  stage's `gliding`.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\stack-glide.sh
```

Ends `STACK GLIDE: ALL PASS`: one sampler process polls the seam every ~40ms
through a stretched glide (strip click, then a close) and checks the motion,
the held content, the fades and the resize counts.

### Strips are blades (T3729)

docs/reference/stacked-panes.md "Gutters": a strip with another between it
and the run reaches 12px (`Metrics.blade_tuck`) under that one.

- **Whole faces, painted in order.** The tucked branch of `placeStage` places
  each face at its whole tab (no `stripFace` trim); `paintByElevation`
  already stacks the strip nearer the run above the one behind it, so the
  front strip covers the tucked part, and `stripAt` hit-tests the same way.
- **The title is centred on what shows**: `pane_stage_rules.labelTuck` names
  the tucked side in the label's own (turned) coordinates and the face takes
  `.pane-strip-tuck-top` / `-bottom`, 12px of padding there
  (`strip_tuck_css_px`, unit-tested against the engine's tuck).
- **The shadow** is win32's pure `blade_shadow.paint` (Mac `PaneCardView`:
  30% dark / 14% light, leaning away from the run, cast from a shape pulled
  in by the corner radius so it fades inside the rounded ends). Rendered
  into a CLEAR buffer it is exactly a premultiplied black shadow, so
  `pane_stage_rules.renderShadow` fills a `GdkMemoryTexture` shown by a
  non-targetable `GtkPicture` per strip (`Blade`), placed just under its own
  face; `shadowImage` grows the tab by the shadow's reach at the device
  scale. The texture is redrawn only when `ShadowKey` changes (size, scale,
  side, collapse in 1/256ths, light desk), so a strip that only moves keeps
  it. The face's own CSS box-shadow is gone: this replaces it.
- **It follows collapse**: a card gliding into or out of its strip
  (`Slide.stripFace`) casts it from the card as drawn at the same collapse
  the content fades by, so it comes on as the card narrows.
- The `pane-stack` seam reports per pane `face` (as drawn), `tuck`
  (`none|top|bottom`), `shadow` (the caster) and `shadow_collapse`.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\stack-blades.sh
```

Ends `STACK BLADES: ALL PASS` (B1-B12): a six-pane row stacks, every face is
its whole tab, side-by-side strips overlap by exactly 12px with the tucked
ones (only) giving way, every strip casts at collapse 1 and no card on show
does, the window's own render is darker just past the front strip's edge on
the blade behind than deep inside it, and a sampled glide shows the shadow
at intermediate collapses. `NEGATIVE=1` reads two interior pixels and must
fail B9. The real-screen look beside the Mac (`open.ps1`) is the user's to
run.

### The gutter bar and double-click (T3626)

Every divider and grip shows a 4px accent bar with a soft glow down the
middle of its gutter (Mac `GutterBar`): half strength under the pointer, full
while dragged, one at a time.

- **One widget, above every card.** `newStage` appends a non-targetable
  `.gutter-bar` box (CSS: `@accent_bg_color`, `box-shadow: 0 0 5px` at 0.9)
  as the stage's last child; `placeBar` allocates it over the lit gutter's
  core and keeps it last after `paintByElevation` reorders the cards.
  Opacity is the strength (0.5 / 1).
- **Which gutter** is `gutter_bar_rules.zig` (pure, none lane; sizes and
  strengths from win32's `gutter_bar.zig`): `litBar` runs on every layout,
  so the bar is drawn where the layout leaves the gutter and stops where the
  edge stops. A drag's bar stays on its divider while that divider is laid
  out; once a fold replaces it (or for a grip, whose index is not stable) it
  moves to the gutter running the same way, across the same span, nearest
  where the bar was (`place`). Mid-glide it follows the gutter as drawn
  (`Slide.shownGutter`). The hover bar is re-asked of every layout from the
  last pointer position (`Private.pointer`, the motion controller's `motion`
  and `leave`), so a gutter that moved out from under a still pointer goes
  out, and every gutter re-checks when a drag ends.
- **Double-click** is the second press on a gutter inside the desktop's
  `gtk-double-click-time`/`-distance` (`isDoublePress`; the stage's drag
  gesture sees every press, so there is no second gesture to group). A
  divider evens out the panes across it in its direction only
  (`equalizeOnly` of the visible tree, lifted back with
  `pane_stash.liftRatios`, as win32's `equalizeSplitsOnly`); a grip between
  two cards evens the run on show (`stack_drag.evenRun`); the grip where a
  run meets its strips has none, so its second press is a drag. Either way
  the press answers `even` and begins no drag.
- The `pane-stack` seam takes `--hover=x,y` and `--leave` (the motion
  controller's calls), reports the stage's `bar` (`kind`, `direction`,
  `strength`, `gutter`, `core`) and `origin` (the stage in its window, to
  read a `capture-pane --window` picture), and runs its arguments in order,
  so `--press=P --release=0,0 --press=P` is a double-click.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\gutter-bar.sh
```

Ends `GUTTER BAR: ALL PASS`: hover/leave/drag strengths, the bar 4px down its
gutter, the accent in the window's own render while a drag is held (and not
at rest), the bar moving to the edge grip when a drag tucks the far pane, and
the divider (both directions) and grip double-clicks.

### Collapses that last (T3627)

docs/reference/stacked-panes.md "Saved with the window". GTK keeps ONE
`PaneStackState` per tab (`SplitTree.priv.stacks`; win32 keeps one per
window), so the win32 `Window.zig` glue is ported onto the split tree:

- **Session layout.** `SessionLayout.captureWindow` writes each tab's
  `pane_stack` from `SplitTree.stackPersisted` (collapsed rows + focus
  history, by leaf position, stash included). `restoreWindow` hands it to
  `adoptStackPersisted` once the tab's tree is whole. The once-a-second
  change-checked capture is the re-save, so there is no `collapseStamp` hook.
- **Restore focus.** `adoptStackPersisted` ends in `focusRestoredPane`:
  `last_focused` goes to the first pane of the saved history that is not
  stashed, and then through `paneOnShow`, so it can never be a strip. It only
  records the pane, and the tree's rebuild moves the keyboard there.
- **Undo.** `CloseUndo.parkClosedPane` keeps `SplitTree.stackSaved()` with
  the entry. `restorePane` calls `restoreStackRows` (note the rows, then
  `restoreScoped`) and focuses the pane only when `isStackMinimized` says it
  is not a strip. A parked TAB needs nothing: its SplitTree, and the stack
  state in it, is parked whole.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\stack-persist.sh
```

Ends `STACK PERSIST: ALL PASS`. Its collapse is the user's own (a divider
dragged past the leading pane's minimum, in a row that fits), so every check
fails on a build without it: the undone close leaves the strip a strip, the
manifest records `leaves [0,1] start 1 count 1`, and a SIGKILL relaunch lays
the row out the same way with the caret in the pane on show.

### Live strip labels, strip drags, columns (T3629)

- **Live labels.** `SplitTree.relabelStrip` renames a showing strip face at
  once (`labelFace`, the sidebar row's rule) and re-lays the stage out. It
  runs on the surface's `title` / `title-override` / `pwd` notify and from
  `Surface.setPaneBanner` (`+set-banner` and OSC 7778), so a banner, a cleared
  banner or an OSC 2 retitle reaches a minimized pane's strip without waiting
  for the next layout. The `pane-stack` seam reports each pane's `label`
  (null when no face is on show).
- **Dragging a strip.** Every face carries a `PaneDrag.StripSource`
  (`GtkDragSource`, keyed by the stage's pane key). `stageDragBegin` leaves a
  strip press unclaimed: the drag source claims it past GTK's drag threshold
  (and the stage gesture is cancelled), and a shorter release is still the
  stage's click that focuses the pane. A strip let go over nothing settles
  back - no new window, unlike a header drag.
- **A strip's targets.** `dropPaneAt(.., blade)` resolves a strip drag with
  `pane_drop.resolveBlade` over `bladeGeometry` (the row's slots from the
  grid's placements): a slot in its row (`reorder`, applied by
  `pane_drop_apply.apply`), a window's edge band (`top_level`), nothing over a
  card. A pane that lands among the cards on show is focused, one among the
  strips stays one (the new tree is laid out to decide, as win32 does).
  **No screen-edge tile**: Wayland gives a client neither the monitors' layout
  around its window nor its position, so GTK passes no screens. A minimized
  pane is a target for an ORDINARY pane drag by its strip's rect (its card is
  out of sight at its last size).
- The seam: `pane-drag --target=<strip's pane> --blade --drop-at=x,y` is the
  drop half of a strip drag (`target` `reorder|top_level|none`, `side`, and
  `pane` = the slot item's first pane). A real pointer drag needs a seat: T3757.
- `stacked-panes.sh` sections 8-10 (S32-S44): live labels, strip drops, and
  a five-pane column (`macos-pane-min-height`) with horizontal strips.

Not yet: strips as blades with their shadows (T3729), a close beside a strip
focusing it (T3744), the pane sidebar as a pane drop target (T3756), and the
bar on a side panel's edge (the pane sidebar's, a viewer's contents).

## Resize pacing (T3568)

Port of `docs/reference/terminal-resize.md`. Nothing GTK-specific paces a
resize: every GTK source - a gutter drag, a window resize, a banner fold -
reaches the core as `glareaResize` -> `Surface.sizeCallback`, which mails the
IO thread, and the shared `termio.Thread` `Coalesce` (100ms settle, 350ms cap)
and `Termio.resizePace` decide what the program is told. So the GTK rule is
the negative one: **never resize the PTY from the apprt directly**, and never
add a per-frame `flushResize` (Mac flushes only for a resize made out of
sight; GTK has no such resize yet).

Measured by `test/linux/resize-pacing.sh` with a SIGWINCH-counting program: a
30-frame divider drag over ~850ms reaches it as 3 SIGWINCH (the stage laid
the pane out on every frame), a banner fold / unfold as exactly one each, and
a 30-step window-edge drag (R10-R12, T3630) as 3. `NEGATIVE=1` drags both in
steps 250ms apart and must fail R6 and R12 alone (one SIGWINCH per step).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\resize-pacing.sh
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\prompt-redraw.sh
```

The window edge is moved through the debug-only **`window-size
--target=<pane|window> [--size=WxH]`** seam (`gtk_window_set_default_size`,
which GTK keeps as the size of an unmaximized window); the reply is the width
laid out so far, so poll it. The headless output is 1280 px wide and a
150-column window already fills it, so a test narrows the window - it cannot
grow past the output.

**What a drag costs per frame (T3792, `resize-frame-cost.sh`).** Every
terminal pane counts its draws, the core's resize work per configure, and
the gap between frames while resizes arrive (`src/apprt/gtk/draw_stats.zig`).
The debug `pane-seen` seam reports them as `draw` (`--reset-draw` zeroes
them). The script drags the edge 40 steps at a prompt and holds each draw
under a 16ms frame (F4; `NEGATIVE=1` sleeps 40ms in every draw through
`GHOZTTY_TEST_DRAW_DELAY_MS` and fails F4 alone). `OPT=ReleaseSafe` measures
an optimized build in its own prefix. ReleaseFast compiles the seams out.
Measured 2026-11-26: about 1.5ms a draw and 15us of resize work, in both
builds. On the real screen the person runs `open.ps1 -DrawStats -Reset`,
drags, then `open.ps1 -DrawStats` (`scripts/linux/draw-stats.sh`, F5).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\resize-frame-cost.sh
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'OPT=ReleaseSafe bash test/linux/resize-frame-cost.sh'
```

**At a prompt (T3630, `prompt-redraw.sh`).** No GTK code is needed for the
prompt-redraw hold either: a GLArea resize re-renders through `glareaRender`
-> `drawFrame` with the cells `updateFrame` held back, so a prompt the resize
cleared stays on screen until bash redraws it. Measured with a green-background
PS1 and `capture-pane` frames across a 16-step window storm: every resize
`pace=now`, every frame shows the prompt, every hold released `by=redraw`.
Its control SIGSTOPs bash, so the 250ms cap draws the cleared prompt and the
frame has no green: the oracle can see a blank prompt. Three traps it found:

- **An `-e bash --rcfile X` pane gets no shell integration** (T3758): the
  explicit command rides `OPEN.command` under the default shell, which is the
  one integrated. A test that needs OSC 133 marks runs bash as `$SHELL` with a
  private `$HOME/.bashrc` instead.
- **`capture-pane` straight after a resize fails** ("produced no frame") until
  GTK re-allocates the pane on its next frame; poll it.
- **Never put `$(...)` in a check's label before `$?`.** Words expand left to
  right, so the label's command substitution resets `$?` to 0 and the check
  passes whatever the condition said (T3568's R5 and background-windows B1
  were vacuous that way). Take `rc=$?` on the condition's line and pass `$rc`.

## The Settings window (T3569)

`open_config` (Ctrl+, / the menu) opens `src/apprt/gtk/SettingsWindow.zig`
instead of the raw file; Advanced's "Open in Editor" is the old behavior. The
write path is NOT GTK code: it is win32's pure model
(`ConfigFileText`/`ConfigFileStore`/`SettingsModel`/`SettingsSources`/
`SettingsCatalog` under `src/apprt/win32/`), imported directly, so the
Mac rules in `docs/reference/settings.md` hold by construction. Fix a rule
there, once, for both seats.

- **Which file**: a debug build writes `$XDG_CONFIG_HOME/ghostty/config-debug.ghostty`
  (layered over the shared `config.ghostty`, which it only reads) -
  `file_load.uses_dev_xdg_path` is true for every non-macOS dev build since
  T3569. A test that wants the app to see a value can still write
  `config.ghostty`; a test of Settings reads `config-debug.ghostty`.
- **Backups**: `$XDG_STATE_HOME/ghoztty/config-backups`; a debug build takes
  `GHOZTTY_SETTINGS_BACKUP_DIR` instead (the test's seam).
- **Seam**: debug-only `hl_ipc settings --op=action|state|search|set|reset|close
  [--key=] [--value=]`, win32's op names. The curated pages add
  `--op=toggle|choose|step|slide|flag|text|curated-reset|reveal` and
  `--page=`/`--filter=` on any op; each moves the row's real widget and lets
  its own signal write, then `flush()`es the idle redraw so the reply reads
  the widgets back (`key.curated.display` beside the model's `expected`).
  List keys add `--op=add|remove` (All Settings' row; `--op=search` for it
  first) and `--op=list-add|list-remove` (a curated list row), with
  `--index=<i>` naming the chip.

### The curated pages (T3631)

The pages are win32's `settings_pages.zig` table, not a GTK one; Linux
words are comptime `linux` branches there (copy-on-select's "To the
selection clipboard", `-lic` in the scripted-shell hint, no `auto-update` on
Updates). Rows: `AdwSwitchRow` (bool), `AdwComboRow` (enum, plus any schema
value nobody curated; a shell row ends with Other...), `AdwSpinRow`
(stepper, MB), `GtkScale` on an `AdwActionRow` (written 250 ms after the
drag settles), `AdwExpanderRow` of switches (flags), else a text field.
Every row has the changed dot and a reset button, and is refreshed IN PLACE
after a write (`refreshCurated`) - rebuilding would lose the page's scroll.
The shell check is `settings_controls.shellProblemPosix` (`:` PATH, X_OK).

Traps found here:

- **Group titles and descriptions are markup** in libadwaita 1.5: "Copy &
  paste" must be escaped (`markup()`); row titles are set with
  `use-markup` off instead. P4 reads the drawn GtkLabel to prove it.
- **`gtk_widget_activate` is not a click or a Return**: on a GtkButton it
  clicks only after a ~250 ms pressed-look timeout, and on a GtkEntry it
  never reached the `activate` handler. A seam gesture emits `clicked` /
  `activate` with `g_signal_emit_by_name`.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\settings-window.sh
```

Ends `SETTINGS WINDOW: ALL PASS` (76 checks: W1-W20 for the window and
All Settings, P1-P23 for the pages, L1-L10 less L5 for list keys, F1-F8 for
the Font picker, C1-C14 with C4b and C11b for Config file and the toast).
Left off the pages for their own cards: color wells and the
folder picker T3759, search across the pages T3760 (the preview and themes
are T3636's, below). Also
still to port: the file-mode and local-time fix T3634 (until it lands, a
backup's date in Restore... reads in UTC: `ConfigFileStore.localNow` is
Windows-only).

### The theme picker and the live preview (T3636)

`src/apprt/gtk/SettingsTheme.zig`, Mac's `ThemeSection` and
`SettingsPreview`, on win32's pure `theme_catalog.zig` (bundled plus
`$XDG_CONFIG_HOME/ghostty/themes`, the user's winning a name clash; light vs
dark by background luminance; `light:A,dark:B`; family seeding; the
mismatch), `settings_theme_grid.zig` (a tab lists only its kind, 11 tiles then
"All N <kind> themes...", the pick first) and `settings_preview.zig` (inputs
and caption). Nothing about which theme goes where is decided in GTK code.

- **Use** is an `AdwActionRow` with two linked `GtkToggleButton`s (GNOME's
  segmented control); the tabs are two more, labelled with the picked names
  in light & dark mode. The filter is a `GtkSearchEntry` (delay 0). Tiles are
  buttons in a `GtkFlowBox` (homogeneous, 118 px minimum, 10 px apart).
- **Colors are CSS.** One provider on the window's display holds a
  `.gz-tile-<catalog index>` rule per theme plus the fixed shapes; a second
  holds `.gz-preview-term`'s rgba and is reloaded only when it changes, so a
  translucent terminal shows the backdrop through exactly as on Mac. Both are
  removed when the window closes. Tile and preview text is Pango markup
  (`foreground`, `font_family`, `size` in 1024ths of a point, `alpha`).
- **The cursor**: block = the cell's `background`; bar / underline = U+258F /
  U+2581 in the cursor color; hollow = U+25AF. It blinks at 530 ms only while
  the card is mapped (the timer stops itself off screen; `map` restarts it).
- The grid is redrawn on idle after a tab, filter or All click, never under
  the clicked widget's own signal; `flush()` runs it for the seam.

Seam (win32's names): `--op=theme-mode --value=true|false`,
`theme-tab --value=light|dark`, `theme-filter --value=`, `theme-all`,
`theme-tile --value=<name>` (clicks the DRAWN tile; refused when the tab does
not draw it), `theme-pick --key=light|dark --value=<name>` (the model call).
State adds `theme` (model, the catalog's names/kinds/backgrounds, and `drawn`)
and `preview` (inputs, caption, and `drawn`: caption, the terminal rule, the
lines' markup, elevated, mapped, blinking).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\settings-theme.sh
```

Ends `SETTINGS THEME: ALL PASS` (32 checks: K catalog, G grid, P one theme,
M light & dark, X mismatch, V preview, O a later file owns `theme`, R
reopen). `NEGATIVE=1` expects the light slot seeded with a dark theme and
must fail M1. The headless Weston reports the system as dark (adwaita's
default there), so K3 and M5 read `system_dark` rather than assume it.

### List keys (T3632)

A repeatable key is Mac's `ListControl`: Font features on its page (the
Font row is the picker below), and every list key under All Settings, show the
user's FILE's values as chips (each with an x) and an "add a value" field.
Both write through `SettingsModel.setList` (the kept run of lines and its
comments stay put), so `keybind`, `palette` and `env` take an entry exactly
like a plain list - Mac's UI never calls `setKeyed`; that waits for the
Keyboard page's binding editor. An add re-reads the file first, so a line an
editor saved a moment ago is kept. A value Ghostty refuses is not written,
the row shows why, and the typed text stays in the field (`draft_key`/
`draft_text`, re-applied when All Settings rebuilds). All Settings adds Mac's
`In effect:` line (first four effective values, then the count). A key a
later file owns gets inert chips and field.

### The Font row (T3765)

Mac's `FontControl`: an `AdwComboRow` whose items are Default (JetBrains
Mono), then the monospaced families fontconfig knows
(`src/apprt/gtk/font_families.zig`: `FcFontList` over family + spacing; a
face counts at `FC_SPACING` mono or charcell, the spacing Ghostty's own
discovery asks for; only its first family name, the rest are localized
aliases). The rules are win32's `settings_controls.zig` (`fontFamilies`,
`fontChoices`, `fontPick`, `fontFallbackLabel`, `fontNotInstalledText`),
shared so Windows (T3766) draws the same row. A pick replaces the FIRST value
of the user's file and keeps the fallbacks; Default removes the key,
fallbacks included. "+N fallback" sits beside the picker with the rest as its
tooltip, and a "Fallback fonts" row below holds them as chips (seam index 0 =
the file's second value) once the file names a font - with none, an add
would become the font. A primary no installed family matches is listed
"X (not installed)" with Mac's "X isn't installed - Ghoztty uses the next
font." as the subtitle; an installed but proportional font is listed by its
plain name with no warning. The items are rebuilt only when that extra entry
changes (`font_arena`). F1 holds the items to `fc-list :spacing=mono` (plus
charcell) exactly; the distro had three such families on 2026-11-25, DejaVu
Sans Mono and Ubuntu Mono among them, and F4 needs at least two.

### Config file, backups and the change toast (T3633)

`src/apprt/gtk/SettingsConfigFile.zig`, on win32's pure
`settings_advanced.zig` (the words, the backup labels, the toast's fade
curve). Advanced now scrolls as one page: the Config file group (the file -
the link target's name when it is a link - with a "loaded" pill, its path
with `~`, Open in Editor and Show in Folder; Mac's link sentence; the red
file problem; every other loaded file with its "included"/"also loaded"
pill, sentence and Open), a group with Backups (Restore... is a
`GtkMenuButton` popover of dates, then Show Backups in Folder; a pick asks
with an `AdwAlertDialog`) and Current file (an `AdwExpanderRow`, the whole
file, monospaced and selectable, capped at 220 px), then All Settings.
"Show in Finder" is "Show in Folder" here (`GtkFileLauncher`, desktop
agnostic).

The toast is a `GtkRevealer` over the stack in a `GtkOverlay`, raised on the
idle redraw after every write. Untouched for `toast_ms` (6 s) and not
expanded, it slides down (the revealer, 350 ms) while a frame callback fades
it on `toastLeave`'s curve; Undo and the x take it away at once; animations
off (`adw_get_enable_animations`) takes it at once too.

Traps found here:

- **A frame callback on the card stops short.** The revealer unmaps its
  child the moment the slide ends, so the fade's last frames never ran. The
  callback sits on the revealer, which stays mapped at zero height.
- **`AdwDialog`'s `closed` arrives after the close animation.** A seam that
  answers the confirmation and reads state at once saw it still open, and a
  late `closed` could forget the NEXT dialog. The window forgets the dialog
  when it closes it, cuts its handlers first, and `closed` only clears the
  dialog still on record.

Seam ops (win32's names, each clicking the drawn button): `open_editor`,
`reveal_file`, `open_source --index`, `backups_folder`, `current_file`,
`restore-ask --index` / `restore-answer --value=restore|cancel`, `restore
--index` (the confirmed half), `undo`, `show_change`, `dismiss`, `toast_ms`.
With `GHOZTTY_SETTINGS_SHELL_DRY` set, a launch is recorded in
`advanced.last_shell` (`editor|open|reveal|folder <path>`) instead of run.

### Sessions & Agent status and Remote Machines (T3635)

`src/apprt/gtk/SettingsLive.zig`, Mac's `AgentStatusSection` and
`RemoteMachinesSection`; the words are win32's pure `settings_live.zig`.
Both are re-read each time their page is SHOWN (`setPage`), as Mac's
`.onAppear` / `.task`; the seam's `--page=session|remote` is that showing.

- **Agent**: Status ("Running · pid N" with a green dot, else "Not running -
  it starts with the first terminal", grey), Running build (the shared
  connection's HELLO stamp, with the stale suffix), This app's agent (only
  once the launch's upgrade check probed it), Socket (the info file's, else
  where it will be; `~` for home). Read by `LocalAgent.liveStatus` from
  `port.json` and a liveness check: showing the page **never dials, never
  spawns and never runs `ghoztty-agent --version`** (N3 proves it with
  `session-persistence = false`).
- **Remote Machines**: the account from local state only (a stored sign-in
  or `GHOSTTY_RELAY_TOKEN`; unconfigured when no OAuth client id resolves),
  rows seeded from the remembered directory as "checking…" (amber), then one
  fetch on a worker thread (`ipc_remote_window.resolveToken` - which may renew
  over the network - and `relay_directory.listDevices`) lands through
  `g_idle_add`, tagged with the showing's generation so a late reply for an
  older showing or a closed window is dropped. A 401 empties the rows and
  deletes the cache. Mac's "New Remote Window..." sits on the account row and
  opens the machine chooser over the front terminal window (T3674, below).
- **Host Settings...** is `src/apprt/gtk/HostSettingsDialog.zig`, an
  `AdwAlertDialog` with Mac's title, body, two fields ("Remote default"
  placeholders) and the shell presets behind a drop-down; Save writes
  `host_defaults` keyed by the device id. The chooser (T3674) reuses it.
- **Where the stores live on Linux** (shared files, a non-Windows branch):
  host defaults `$XDG_CONFIG_HOME/ghoztty/host_defaults[-debug].json`
  (`GHOSTTY_HOST_DEFAULTS` overrides), the machine cache
  `$XDG_CACHE_HOME/ghoztty/machines[-debug].json`.

Seam: `--op=host_settings --value=<device id>` (the row's button),
`--op=new_remote_window` (the account row's New Remote Window..., T3674),
`host-settings-fill --key=working_directory|shell --value=`,
`host-settings-preset --index=`, `host-settings-answer --value=save|cancel`
(in a separate request from the one that opened it); state adds `live`.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\settings-live.sh
```

Ends `SETTINGS LIVE: ALL PASS` (24 checks, against a python relay on
loopback). `NEGATIVE=1` has the relay call every machine offline and must
fail R3.

## The command palette's "… with Shell" rows (T3737)

"New Tab with Shell…", "New Window with Shell…", "Split Right with Shell…"
and "Split Down with Shell…" (win32 T3751). Choosing one keeps the palette
open, clears its search, sets its cue to "New tab with which shell?" and the
like, and swaps the list for the installed shells. Escape goes back to the
commands, and a second Escape closes the palette. Picking a shell emits the
palette's `shell-picked` signal, and `Window.openWithShell` opens the target
with command `[<path>]`, the same command `+new-window --shell=<path>` with no
`--command` builds. The pane inherits the folder any new pane from the active
one gets. In single-window mode a new tab is a new workspace (T3649). The rows
are hidden while the window's active pane rides a remote link
(`Window.isRemoteWindow`).

The list is the **Settings > Shell list**, not `/etc/shells`:
`shell_pick.catalog` resolves `settings_controls.posix_shells` (zsh, bash,
fish, nu) on PATH, and Settings' own Shell menu reads the same catalog
(`SettingsWindow.installedShells`). The pure half lives in
`src/apprt/gtk/shell_pick.zig` and is tested in the none lane.

The seam: `command-palette --op=escape` presses Escape in the search field,
and the reply's `shell_step` names the step on show (`new_tab_with_shell`,
...; null on the command list).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\palette-shell-pick.sh
```

Ends `PALETTE SHELL PICK: ALL PASS`. Pass B runs with session persistence
off (New Tab only) and pass A with it on (all four targets, agent-hosted).
Each pass checks the pane's `/proc/<pid>/exe` (bash, under a `/bin/sh`
default) and `/proc/<pid>/cwd`, and that the pane landed where its row says.
`NEGATIVE=1` backs out instead of picking, so every `.8`-`.11` goes red.

## The keyboard shortcut guide (T3570)

`show_keyboard_shortcuts` - **Ctrl+Shift+/** on Linux (GTK's Ctrl+?; plain
Ctrl+/ is the shell's ^_), the main menu's "Keyboard Shortcuts"
(`app.show-keyboard-shortcuts`) or the command palette - opens
`src/apprt/gtk/ShortcutGuideWindow.zig`. Its rows are NOT GTK code: they are
win32's pure `src/apprt/win32/shortcut_catalog.zig` built from the live
config against a fresh default one (`docs/reference/keyboard-shortcuts.md`).
Where Linux words differ (Super, "Quit Ghoztty", the GTK inspector, no
updater) it is a comptime `linux` branch in that file, so a curation fix is
made once for both seats.

- The window routes Up/Down/Return/Escape/Ctrl+F itself (a capture-phase key
  controller), rebuilds on `config_change` (app target), and Runs a row in the
  most recently focused terminal window (`gtk_application_get_windows` order;
  the guide is not one of the application's windows).
- GtkSearchEntry reports `search-changed` after the fact, even for text the
  guide set: the handler ignores an unchanged query, or a selection made under
  a query is reset (G15b).
- Run shows on the selected row AND the row under the pointer (T3639, Mac's
  hover-or-selection): a `GtkEventControllerMotion` per runnable row calls
  `setHover`; only the hovered row's own leave clears it (the next row's enter
  can come first), and a list rebuild forgets the hover.
- The unbound toggle persists in `$XDG_STATE_HOME/ghoztty/shortcut-guide-unbound[-debug]`;
  the cheat sheet is written to `$XDG_RUNTIME_DIR`.
- **Seam**: debug-only `hl_ipc shortcut-guide --op=action|open|state|select|run|hover|escape|cheat-sheet|shot|close
  [--query=] [--category=] [--unbound=0|1] [--down=n] [--row=<id|none>] [--path=]`, win32's op
  names and reply shape (`data.rows[]`, plus `hovered` and `run_shown` - the
  rows whose Run button widget is visible). `hover` is the motion
  controller's enter/leave call; the harness has no seat, so a real pointer
  hover is NOT RUN. `shot` renders the whole window from
  its own render; a content-box shot comes out transparent behind white text.
- **The other two ways in** (T3640) have seams of their own, both general:
  `hl_ipc main-menu --target=<pane> [--activate=<label>]` lists the window's
  main menu (`items[]`: label, action, section - window.blp's `main_menu`,
  bound as a template child) and activates an item's action from the window
  (`gtk_widget_activate_action`, the muxer path the open popover takes; the
  popover itself needs a seat, NOT RUN). `hl_ipc command-palette
  --target=<pane> [--op=state|open|close|run] [--query=] [--title=]` toggles
  the palette through `win.toggle-command-palette`, types into its search and
  clicks the shown row with that title through the palette's own `activated`.
  The palette's filter is **incremental**: a reply with `pending: true` is not
  the final list, so poll until it is false.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\shortcut-guide.sh
```

Ends `SHORTCUT GUIDE: ALL PASS` (38 checks; G27-G32 are the menu item and the
palette entry); `NEGATIVE=1` presses Ctrl+/ and must go red; `SHOT_OUT=<dir>`
keeps two PNGs.

## Background windows: what stops when no one is looking (T3571)

`docs/reference/background-windows.md`, GTK-translated. The pure rules are
`src/apprt/gtk/window_seen.zig`; `class/window.zig` and `class/surface.zig`
are the GTK half.

- **A window is seen** while it is mapped and its `GdkToplevel` state is
  neither MINIMIZED nor SUSPENDED (`notify::state` on its `GdkSurface`).
  SUSPENDED is the compositor's "covered / other workspace" - the Mac's
  `WindowCoverage` - and Wayland gives a client no window list to compute
  coverage itself. **Weston (headless, and so WSLg) reports neither**, so a
  covered window there keeps drawing: errs toward visible, like win32's
  `occlusion.zig`.
- **A pane is seen** while its widget is mapped (a background tab, a pane
  behind a stacked row's strip and a put-away quick terminal are not) and its
  window is seen. `Surface.syncSeen` tells the core on a change only
  (`occlusionCallback`): the renderer skips building frames and catches up
  once on show; the terminal, `+set-state`, notifications and `+list` never
  pause.
- **A viewer pane (T3643)** has no core to tell; `Surface.syncSeen` pushes
  the window half into it instead (`Viewer.setWindowSeen`), because its box
  stays MAPPED in a minimized or suspended window. `Viewer.isOnShow` (box
  mapped and window seen) gates the `git-status:` poll (`ViewerDiff.onPollTick`
  skips the tick) and the file watcher's render (owed until shown). Hidden,
  the web view is unmapped with `gtk_widget_set_child_visible` (no relayout):
  WebKit then reads the page as hidden and holds a GIF on its frame, whatever
  the compositor told it about the toplevel. On show, one catch-up: an owed
  save renders and a working-tree diff asks git at once (`ViewerDiff.catchUp`,
  also run when a background tab's viewer maps). Logs: `viewer: pane=<id>
  window seen=<bool>`, `viewer diff: pane=<id> shown again; catching up`.
- **Titles**: a hidden window holds a new title (`Window.syncTitle`) and
  lands it on show, or 5 s after the last landing; its first title always
  lands. `+list` and the sidebar read `Window.currentTitle()`, held or not.
- **Seam**: debug-only `hl_ipc pane-seen --target=<pane|window>
  [--toplevel=minimized|suspended|shown|real]` - the window's `seen`,
  `reported` toplevel bits, `title`/`held_title`, and each pane's
  `seen`/`mapped` - plus, for a viewer pane, `viewer`: `on_show`,
  `page_mapped` (the web view), `polling`, `skipped_polls`, `catch_ups`,
  `git` (processes run). `--toplevel` stands in for the compositor (headless Weston
  never minimizes).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\background-windows.sh
```

Ends `BACKGROUND WINDOWS: ALL PASS` (24 checks; V1-V8 a `git-status:` viewer
in a minimized and a suspended window: no git runs while hidden, one
catch-up on show). Measured: a pane redrawing a
full screen every 10 ms cost 9-10 CPU ticks over 4 s in a background tab
against 209-242 on screen. `NEGATIVE=1` keeps that pane on screen for the
"hidden" sample and must fail B4 alone.

## Teardown memory: what a closed pane gives back (T3572)

`docs/reference/memory.md`'s teardown invariants, measured on GTK. On this
frontend the core surface (renderer and IO threads, pty, GL targets) is freed
in the `Surface` GObject's **finalize**, so anything still holding a
reference to a closed pane - a closure, a signal handler, a weak ref that is
really strong - keeps all of it. Thread count is the sharpest oracle: each
open terminal pane is 2 threads and 9 fds in the app.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\pane-close-memory.sh
```

One window stays open; each scenario (`split`, `rapid` - closed while it
starts, `tab`, `window`, `viewer`) runs 8 warm-up and 12 measured
open/close cycles, each close waited past `undo-timeout` (1 s), and asserts
per cycle: app private memory (`smaps_rollup` Private_*) <= 1 MB, threads
<= 0.5, fds <= 0.5, descendant processes <= 0.2 and their memory <= 1 MB,
and the session agent's live heap <= 1 KB (M6, below).
Descendants are the app's (WebKit web processes) AND the session agent's
(pane shells live under `ghoztty-agent`, not the app). The app runs with
`LIBGL_ALWAYS_SOFTWARE=1`, so its GL textures are its own memory and a
leaked render target would show (P0d checks no d3d12 driver is mapped).
Ends `PANE CLOSE MEMORY: ALL PASS` (40 checks), about 6 minutes.
`NEGATIVE=1` leaves the panes open and must fail every budget check (today
the app dies after ~20 open splits, so only the split scenario's checks are
meaningful there - T3779; its M6 reads ~10 KB per kept session). At
`CYCLES=50` the app's own M1 goes red, ~1 MB a cycle (T3778).
The wrapper does not pass environment variables into WSL: for `SCENARIOS`,
`CYCLES`, `WARMUP`, `REPORT=1` (every sample) or `NEGATIVE=1`, write a
scratch command file that exports them and then holds the script's text.

Measured 2026-11-24: nothing in the app leaks per close. The app's memory
climbs ~15 MB over the first ten cycles and then holds (allocator and GTK
caches), hence the warm-up.

**The agent's private memory climbs ~27-45 KB per closed session and that is
not a leak** (T3646). A Debug agent runs on Zig 0.15's `DebugAllocator`,
which never reuses a freed slot and returns a page only once every slot on it
is freed, so any long-lived small allocation pins a page per session's worth
of churn. Its own count of bytes handed out says what is really kept: a Debug
agent built with `enable_memory_limit` writes `heap: session created|freed:
live_bytes=N sessions_live=N sessions_dead=N` (scope `heap`, debug level) to
its `agent.log` on every session create and free
(`src/remote/agent/heap_stats.zig`). Over 30 split cycles that stayed at
29,110 -> 29,830 bytes (~24 B a cycle, in hash-map-growth steps) while private
memory rose 800 KB; one open session holds ~10 KB. M6 asserts it, and reports
`-1` (a FAIL) if the line ever stops being written. A release agent runs on
`smp_allocator`, which reuses its freelists and keeps no such count.

## Panes that are not drawing give back their frames (T3645)

`docs/reference/memory.md`'s release, GTK half. A terminal pane that has drawn
nothing for 3 s (idle) or that `Surface.syncSeen` says nobody can see (hidden)
shrinks its swap-chain targets to 1x1 and drops its font atlas copies
(`generic.Renderer.releaseFrameResources`). The render thread decides, but it
has no GL context on GTK, so it hands the release to the main loop
(`OpenGL.queueAppThreadRelease` -> `Surface.queueFrameRelease`, one idle at a
time), which makes the pane's GtkGLArea current and runs
`Renderer.releaseQueuedFrames` - deciding again, since the pane may have drawn
or been shown in between. No picture goes with it: GTK shows the GLArea's own
texture, and every GTK render is a full draw. Logs: `released idle|hidden
render targets (WxH) targets=<KB> atlases=<KB>`, `redrawing after a(n)
idle|hidden release`. `GHOZTTY_IDLE_FRAME_RELEASE=0` turns the idle half off.
The `pane-seen` seam reports each terminal pane's `frames`: `target_bytes`,
`atlas_bytes`, `released`.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\frame-release.sh
```

Ends `FRAME RELEASE: ALL PASS` (10 checks, about a minute). `NEGATIVE=1`
turns the idle release off and must fail R1 and R2 alone. **Open (T3775):** on
Mesa llvmpipe the app's private memory does not drop after a release (the
target-sized mappings stay, with `MALLOC_MMAP_THRESHOLD_` pinned too), while a
closed pane's do go; something in Mesa's context state still references them.

## Window modes: the launch latch (T3573)

`docs/reference/window-modes.md`, GTK-translated. `macos-window-mode`
(`separate` default, `single`) is read **once**, in `Application.init`,
through win32's pure `src/apprt/win32/window_mode.zig` (`latch`), so the rule
is one function on both frontends. A reload never moves it: when the file now
says the other mode the app logs `window mode: <in force> in force; the config
now says <other>, which takes effect at the next launch`. With
`quit-after-last-window-closed = false` the app stays resident with no
window, which looks quit to the person, so the first terminal window opened
while none is open re-reads it (`relatchIdle`, win32 T3212; logged as
`window mode: A -> B (re-read with no window open)`). The quick terminal
never counts.

### The foundation: one toplevel, workspaces hand it over (T3648)

`src/apprt/gtk/Workspaces.zig`; decisions are win32's pure
`workspace_host.zig` `Host(*Window)`. In `single` mode:

- **One toplevel.** The first window (`Application.initAndShowWindow` ->
  `Workspaces.present`) loads it as an ordinary window. Every later one is a
  workspace that keeps its own `Window` GObject but never maps its own
  GtkWindow: its content root (the template's `Adw.TabOverview`,
  `Window.contentRoot`) is held out of every window by its own reference
  (parked, `Window.holdContent`), or is the toplevel's content (on show).
  `+new-window` without `--focus` opens parked; `--focus` opens on show.
- **The hand-off** (`Workspaces.show`): the workspace on show's content
  comes out of the toplevel, held; the other's goes in. No widget is rebuilt
  and no process touched; the toplevel's title becomes the new one's.
- **Owner-of.** The content root carries qdata naming its `Window`
  (`Window.workspace_qdata_key`); `ext.getAncestor` reads it before the
  widget tree for any type that declares the key. So every existing
  `getAncestor(Window, ...)` answers the workspace a widget is IN - on show in
  another workspace's toplevel, or parked - and separate mode answers as
  before. The workspace's `win` actions are inserted on its content root.
- **Parked counts as hidden**: `Window.syncSeen` reads the toplevel's map and
  toplevel bits for the workspace on show and `false` for a parked one.
- **Leaving.** The content root's `win` group references its Window, a cycle
  that keeps a destroyed workspace from disposing, and GTK clears a destroyed
  window's `application` with no notify. So a workspace leaves the host on the
  application's `window-removed` (`Window.leaveWorkspace`). The close
  experience is the next section (T3652).
- **Known gap, filed on its card**: a workspace parked from birth has no
  running terminal until first shown (the core surface starts on the GLArea's
  first resize, which needs a mapped allocation - T3786). A test that needs a
  busy parked workspace starts it on show and parks it after.
- **Seam**: debug-only `hl_ipc workspaces [--show=<pane|window>]` - `mode`,
  `toplevel`, `active`, `content` (whose content root IS the toplevel's
  content: the hand-off's oracle), `toplevel_title`, `focus_window` (the
  workspace whose pane has the toplevel's keyboard focus), `list` (the
  all-windows list's order, what the goto walks step through), and per
  workspace `parked`, `held`, `seen`, `mapped` (its own GtkWindow), `panes`,
  `tabs`, `owner_ok`.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspaces.sh
```

Ends `WINDOW WORKSPACES: ALL PASS` (43 checks, about two minutes). K9 is the negative control: the key
unset makes no workspaces.

### Closing (T3652)

- **The one on show** hands the window to the workspace shown before it
  (`Host.close` -> `hand_to`, then `Workspaces.adopt`: content, title, the
  T3651 shade fade, focus, sidebar). **A parked one** closes in place. **The
  last one** closes the window.
- **The toplevel's own workspace closing never makes a second window.** GTK
  cannot hand a GtkWindow from one `Window` to another, so `Workspaces.retire`
  closes the WORKSPACE and `Window.becomeFrame` ends what made it one (tabs,
  undo entries, sidebar, relay record, IPC name); its GtkWindow stays mapped
  as the FRAME the others show in (`isFrame`; the seam's `toplevel` reads null
  and `toplevel_frame` true). Every window walk skips a frame. The last
  workspace's close destroys it on the next idle (log `workspace: the last
  workspace closed; the shared window closes`).
- **Every close-for-good goes through `Window.closeNow`** (retire, else
  destroy) and **every close that may ask through `Window.requestClose`**. The
  toplevel's own close-request (headerbar x, compositor close) is routed to
  the workspace on show (`closeRequestTarget`); `win.close`, a last pane
  going and the seam ask for the workspace's OWN close, never routed.
- **A close that asks** puts a parked workspace on show first and presents
  the Close Window? dialog inside the toplevel (`dialogParent`);
  `openDialog` looks in `dialogHost` (the toplevel for the workspace on show,
  nothing for a parked one or a frame).
- Undo of a workspace close is T3790 (window-close undo, T3665, refuses a
  workspace).
- Seam: `workspaces` has `toplevel_frame`, `gtk_windows` and
  `mapped_windows` (the "one window" oracle); `close-dialog --target=<w>
  --op=frame` presses the toplevel's close button, `--op=window` the
  target's own close.

### Switching and every open path (T3649)

- **"Go to this window" is `Window.bringForward`** (Mac `bringForward`): in
  single mode it puts the workspace on show (`Workspaces.show`); a window
  built outside `initAndShowWindow` (a tab dragged out, a pane popped out) is
  admitted as a new workspace first; separate mode presents the window as
  before. Every raise goes through it: a pane's present request (bells,
  notification clicks, the palette), `--focus` (`IpcHandlers.focusTarget`,
  which also puts a parked workspace on show when the pane was made in the
  same request and its window had not connected the present request yet),
  a pane drop's arrival, the sidebar.
- **The sidebar's all-windows list switches.** A click on a workspace's row
  (or tile), or on one of its panes' rows, puts it on show **on the next idle
  turn** (`PaneSidebar.raiseLater`, win32 `showWorkspaceLater`): the hand-off
  takes the clicked sidebar's own content out of the window in the middle of
  the click. Latest request wins; what it names is looked up again when it
  runs. Logged `workspace switch from the sidebar key=|pane=`.
- **The hand-off focuses** the workspace's own active pane (`grabFocus`), so
  keys land in the workspace now on show.
- **goto_tab and goto_window walk the list** (`Workspaces.gotoTab` /
  `gotoWindow` over `PaneSidebar.listOrder`, which is `all.railOrder` over the
  same gather the sidebar draws): previous/next wrap, last is the last, N is
  the Nth (clamped), through win32's pure `pane_sidebar_window_order.gotoTab`
  and `stepped`. Nowhere to go returns false (the key goes on). Separate mode
  is unchanged (tabs within the window; goto_window over GTK's toplevels).
- **A new tab is a new workspace** (`Workspaces.newTabIsWindow`, from both the
  core action and the viewer-pane path): opened as Ctrl+Shift+N opens one from
  that pane, on show. So every workspace has one tab.
- **Focus policy**: a manual open (keys, menus, palette, sidebar +) goes on
  show; `+new-window` without `--focus` stays parked; `--focus`, or
  `--target=<existing> --focus`, or a `+split --focus` into a parked workspace,
  puts it on show.
- **Window-level key controllers act for the workspace on show**
  (`Workspaces.keyTarget`): the rearrange-mode Escape controller lives on the
  GtkWindow, which in single mode is the toplevel.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspace-switch.sh
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/window-workspace-switch.sh'
```

Ends `WINDOW WORKSPACE SWITCH: ALL PASS` (27 checks, about a minute).
`NEGATIVE=1` runs it in `separate` mode and must fail from S1 on (20
failures). Still to come: the CLI (T3653), persistence (T3655), undo of a
workspace close (T3790).

### Activity: state never pauses (T3654)

- **The window's activity is the most urgent of every workspace's**, parked
  ones included (`Workspaces.refreshActivity` over win32's pure
  `Host.rolledUpActivity`; Mac `refreshWindowActivity`). Recomputed from
  `Window.syncActivity` on every activity change of a workspace (a parked
  pane's `+set-state` reaches its own workspace through the content root's
  owner qdata), and when a workspace is admitted (`present`), closes for good
  (`forget`) or is retired into a frame (`retire`). Logged on a move:
  `window activity rolled up state=<s> workspaces=<n>`.
- **The title suffix stays the workspace on show's own**: `Window.syncTitle`
  composes from the workspace's own aggregate, and only the workspace on show
  titles the toplevel (`landTitle`).
- **A move INTO `needs_input` asks for attention** (`Window.noteActivityAttention`,
  win32's pure `activity_attention.Tracker`, T2907): once per move, only when
  the window the person sees is not active, through `winproto.setUrgent(true)`
  (X11 urgency hint; Wayland an xdg-activation token) - the same urgency the
  bell's `attention` feature sets, cleared by `propIsActive` when that window
  is activated. A parked workspace asks on the shared toplevel
  (`Workspaces.attentionWindow`); separate mode asks on the window itself.
  Logged on every move into or out of it: `activity attention
  needs_input=<b> active=<b> urgent=<b> parked=<b> target=<name>`.
- **Seam**: `workspaces` has `activity` (the roll-up) and per workspace
  `activity` (its own panes').

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspace-activity.sh
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/window-workspace-activity.sh'
```

Ends `WINDOW WORKSPACE ACTIVITY: ALL PASS` (18 checks, under a minute). The
headless Weston has no seat, so the toplevel is never active and A7 sees
`urgent=true`. `NEGATIVE=1` runs it in `separate` mode and must fail from A1
on (11 failures).

### Persistence: the one on show comes back on show (T3655)

- **Capture** (`SessionLayout.capture`): in single mode the manifest lists
  the workspaces in `Workspaces.order()` - on show first, then most recently
  shown - and only then any window that is no workspace, in GTK focus order.
  GTK's own order cannot tell workspaces apart: only the shared toplevel is
  ever focused. Every workspace records the toplevel's size and maximized
  state (`Workspaces.physical()`, which is the frame once the toplevel's own
  workspace closed, T3652), and the one on show is marked `frontmost`.
- **Restore** (`SessionLayout.restore`): builds back to front with the
  `frontmost` entry last wherever it is listed
  (`session_layout_rules.restoreOrder`). Every restored window is presented
  with activate, so the last one built is on show in single mode and
  presented last in separate mode, and the workspace order round-trips. Each
  build logs `session layout: building window=<name> frontmost=<b>`.
- **Across modes**: a single-mode manifest read in separate mode is windows
  at the one size they shared; a separate-mode manifest read in single mode
  is workspaces, the `frontmost` one on show.
- **Gap**: a restored PARKED workspace re-attaches its session on first
  show, not at launch (T3786, the born-parked start). Its process is alive in
  the agent the whole time; `+list` shows pid 0 for it until shown.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspace-persist.sh
```

Ends `WORKSPACE PERSIST: ALL PASS` (25 checks, about two minutes: four
launches). Against the pre-T3655 capture it was red on P2, P6 and P8b, with
three on show instead of two.

### Parked layout (T3650)

A parked workspace's content is out of every window, so no window lays it
out. `Workspaces.layoutParked` measures and allocates its content root by hand
at the size of the content on show, then hands every STARTED terminal in it
its new size (`Surface.layoutParked`, the same `sizeCallback` a GL resize
makes) at the shared window's pixel scale - the active pane's GL pixels over
its allocation (`Surface.pixelScale`, Mac `SurfaceView.backingSize`). It runs:

- when a workspace opens parked (`why=birth`);
- `workspace_host.resize_settle_ms` (0.3s) after the toplevel's GdkSurface
  stops changing size (`Workspaces.toplevelResized`, from
  `Window.propGdkSurfaceDims`; `why=resize`);
- on a tree change in a parked workspace (`Workspaces.treeChanged`, from
  `Window.tabSplitTreeChanged`), on a LOW-priority idle so it follows the split
  tree's own widget rebuild, which runs on a default idle (`why=tree`).

Log: `workspace: parked window=<w> laid out at <W>x<H> scale=<s> why=<...>
panes=<n> resized=<m>`. When shown, the GL area's own resize then carries the
same pixel size, so the grid does not move. **Gap**: a terminal MADE while
parked (born parked, or a `+split` into a parked workspace) has no GL context
and starts on first show (T3786). The `workspaces` seam's per-workspace
`grids` (`[{pane, grid: "<cols>x<rows>" | null}]`) is the oracle.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspace-layout.sh
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/window-workspace-layout.sh'
```

Ends `WINDOW WORKSPACE LAYOUT: ALL PASS` (15 checks, about a minute);
`NEGATIVE=1` (separate mode) fails 7.

The launch latch's own test:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-mode.sh
```

Ends `WINDOW MODE: ALL PASS` (13 checks). W6 is the negative control: the
same app with the key unset latches `separate`. A resident app does not quit
on SIGTERM (T3656), so the script KILLs the first app after a TERM that did
not work.

## Chrome title weights: semibold, like the Mac (T3791)

Adwaita draws the header bar's title and every `.heading` bold (700); the
Mac's titlebar, sidebar headers and Settings section titles are semibold and
nothing in its chrome is bold. `style.css`'s last block sets
`windowtitle .title`, `headerbar .title` and `.heading` to 600, and the pane
strip, the shortcut guide's badges and the picked theme tile carry 600 too
(the per-label table is in T3791). A new chrome label takes the Mac's weight,
not Adwaita's default.

The debug-only `label-weights --target=<pane> [--of=window|settings|guide]`
seam lists every label of that window with the weight CSS computed for it
(the Pango font description of its context: 400 regular, 600 semibold, 700
bold), whether it is mapped, its classes and its parent's node name and
classes. `test/linux/label-weights.sh` (B1-B11) asserts the title, the
Settings headings and the guide's badges at 600 and no mapped label in a
window at 700 or more; its control is a gtk-custom-css asking for 800, which
must move the read and move it back. AdwWindowTitle's `.title` label sits in
a box inside `windowtitle`, so find it by its text, not its parent.

## The interop PATH trap

Inside WSL the Windows `PATH` is appended by default, so a bare `ghoztty` can
resolve to the Windows `ghoztty.exe` through interop and drive the user's
installed Windows terminal. `wsl-run.ps1` drops every `/mnt/*` PATH entry and
puts `zig-out/bin` first, and tests still name the Linux binary by full path
(`hl_ghoztty`). The same rule as Windows' CreateProcess lesson: never let a
lookup decide which binary a test drives.

## Crash diagnostics

**gdb is installed since 2026-11-26** (T3656, `apt-get install gdb`): attach to
a hung app with `DEBUGINFOD_URLS= gdb -p <pid> -batch -ex 'thread apply all
bt 40'` from inside the step (the step runs as root, so ptrace is allowed).
That is how T3656's quit hang was traced into Mesa's d3d12 driver.

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

**The `gtk` lane** (T3605) is `zig build test -Dapp-runtime=gtk
-fno-sys=gtk4-layer-shell`: the GTK frontend's own test blocks (upstream's
`src/apprt/gtk.zig` test root - key, portal, ext, gsettings, gtk_version,
class/* - and anything else only a gtk build compiles). It is the only lane on
any platform that runs them; the none lane gets just the std-only
`src/apprt/gtk/*.zig` halves `src/apprt/unit_tests.zig` references, which is
why new GTK logic keeps its pure half there. `-fno-sys=gtk4-layer-shell` is
required because Ubuntu 24.04 packages no gtk4-layer-shell. Measured
2026-11-24 warm: 7963 passed / 100 skipped in about 2 minutes.

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
  here. `ssh_transport`'s `ChildStream.close` did exactly that until T3354:
  the reader now blocks in `poll` on its fd plus a private wake pipe that
  `close` writes, and the fd itself is released by `deinit` once the reader
  is joined. Use the same shape for any new "close unblocks the reader" code.
- A panic stops that test process and the runner restarts after it, so one
  crash can hide the next: re-run until the lane is green, not until the first
  named failure is gone.

## The agent on Linux (T3332)

`floor.sh` carries two agent lanes, `agentx` (`zig build agent`) and `agent`
(`zig build test-agent`), both under the DEFAULT runtime (gtk). The agent is
GUI-free, so on a gtk build `SharedDeps.guiFree` hands it and its test the
runtime-`none` deps: before T3358 they took the app's GTK deps and the build
failed for want of the system `gtk4-layer-shell` Ubuntu 24.04 does not package.
Never add `-Dapp-runtime=none` to those lanes; it would hide that regression. Measured 2026-11-21: test-agent 2839 passed / 40
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

## Session persistence: agent-hosted panes (T3337)

With `session-persistence = true` (the default, as on the Mac and Windows) the
GTK app runs every new pane under the local `ghoztty-agent`, so the pane's
shell outlives the app.

- **Find or spawn** is `src/apprt/gtk/LocalAgent.zig`, the Mac's
  `LocalAgentManager` translated: read `port.json`, check its pid, dial its
  0600 AF_UNIX `agent.sock` (the HELLO is the health check); otherwise
  double-fork + `setsid` the `ghoztty-agent` that sits beside `ghoztty` (the
  GTK build installs it there; `GHOSTTY_LOCAL_AGENT_BIN` overrides) and poll
  the info file, 3 s at most. A missing or broken agent gives the pane a plain
  exec pty, and new panes skip the agent for 15 s after a failure.
- **The state dir** is `remote/local_agent_paths.zig`, shared with `+sessions`:
  `$XDG_CONFIG_HOME/ghoztty/local-agent[-debug][-<instance>]/` when
  `XDG_CONFIG_HOME` is absolute, else `~/.config/...` (macOS is always
  `~/.config`, byte for byte the Swift derivation). It holds `agent.sock`,
  `port.json`, `sessions.json`, `agent.lock`, `agent.heartbeat`, `agent.log`.
- **Close vs quit.** A pane freed while the app is not quitting was closed by
  the user (pane, tab, window, `+close`), so its session ends (CLOSE). Panes
  freed by `quitNow` detach, and a killed app detaches by dropping the socket:
  the sessions survive and the next launch re-attaches them (below, T3397).
  **SIGTERM is a quit**, not a crash: it goes through `quitNow`, so a logout
  or `kill -TERM` saves the layout and detaches every pane.
- **`+list`** reads an agent-hosted pane's pid and tty from what the agent
  reported, so `--tty=$(tty)` still finds it.
- **The harness** exports a private `XDG_CONFIG_HOME` under its runtime dir,
  so the agent a test app spawns lives there, and `hl_stop` reaps it and every
  pane it hosts (`hl_agent_pid`, `hl_stop_agent`). Every GTK suite now runs
  with agent-hosted panes.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\session-agent.sh
```

Ends `SESSION AGENT: ALL PASS`: the agent is spawned under the harness dir with
a 0600 socket, the pane descends from it and not from the app, `+sessions`
lists it, it keeps running after the app is SIGKILLed, a second app finds the
same agent, `+close` ends a session, and `session-persistence=false` keeps the
exec pty.

### Relaunch restores the layout (T3397)

`src/apprt/gtk/SessionLayout.zig` keeps a session-layout manifest and rebuilds
from it at launch, the Mac's `SessionLayoutManifest` in win32's on-disk schema
(`apprt/win32/session_layout.zig`, std-only, shared rather than copied).
Its pure half - the file's path, a tree's first leaf, the recorded window size,
a viewer leaf's restore - is `gtk/session_layout_rules.zig` (T3551), std-only
and referenced from `apprt/unit_tests.zig`, so every lane runs its tests:
`SessionLayout.zig` imports GTK classes, and nothing ever compiled the tests
it used to carry (a `-Dtest-filter=firstLeaf` run matched no tests).

- **The file** is `<config root>/ghoztty/session-layout[-debug][-<lineage>].json`,
  beside the agent's state dir under the same root, so the harness's private
  `XDG_CONFIG_HOME` holds a test's manifest too.
- **It records** per window its target name, pinned title, size (`frame` w/h:
  GTK's default size, which tracks the user's resizes and stays the normal
  size while maximized; x/y are 0, T3549), maximized state, selected tab and gradient seed (`desk_variant`, T3623);
  per tab its pinned title (T3549) and the split tree with exact directions
  and ratios; per
  terminal pane its session id, pane id, name, pinned title, pwd,
  banner (its markdown source, T3560) and tint (`#rrggbb`, T3589); per
  viewer pane its pane id, name, location, Home and origin directory (T3420,
  below). The quit's
  write adds each pane's screen snapshot (base64, the WP-D3 pair).
- **When:** a change-checked capture every second, writing only when the bytes
  changed (GTK has no single change hook for tree, title, name and pwd; the Mac
  debounces each change by 250 ms), and a final one with snapshots at the start
  of `quitNow`, before any window is torn down. Nothing writes after that, so
  the teardown can never record an empty app. A window the user closes drops
  out of the next capture; an app the user empties removes the file.
- **Who:** only the instance that serves the IPC socket, with
  `session-persistence` on. A second instance (`--gtk-single-instance=false`)
  neither restores nor writes.
- **Restore** (in `Application.run`, before `activate`): ask the agent for its
  roster; each terminal leaf ATTACHes its session when it is alive and unheld
  or a relaunchable tombstone (one pane per session), else opens a fresh shell
  in its recorded pwd - under its recorded pane id either way. A restored
  launch shows only the restored windows unless it was given `-e`, which still
  opens its own, in front, and runs its command there (T3594): a restored pane
  nulls `initial-command` in its own config (core would otherwise hand `-e` to
  whichever pane realizes first), and the `-e` window carries the command as an
  explicit `Action.newWindow` override. Acceptance: section 5c (RE1-RE6) of
  `test/linux/session-restore.sh`. Panes are built through the ordinary window/tab/split paths,
  each handed its restore through `Surface.pending_restore`. A window opens at
  its recorded size (`Application.newWindowForRestore`, set before it is
  presented; a size under 100 or over 16384 px is ignored) and each tab
  re-pins its recorded title.
- **Not restored:** window position - Wayland gives a client none, so where a
  window lands is the compositor's call.
- **The stash (T3667)** comes back too: each leaf records its place in its
  tab's stash (`stash_index`, 0 = top; win32 T1838's field, absent for a pane
  on show) and the relaunch stashes the panes again in that order
  (`pane_stash.applyRecorded`, which still leaves one pane on show for a
  manifest that would hide them all). Not at once: a GTK terminal starts
  when its GL area is first realized and a stashed pane has no card, so a
  pane stashed before it was ever on screen would never start its shell or
  re-attach its session. `SplitTree.adoptRecordedStash` waits (50 ms ticks,
  10 s cap) until every recorded pane has started, then applies the stash in
  one go and moves the caret off a pane that left the layout. A stashed pane
  in a tab that is not on show at launch never realizes, so it times out
  unstarted (T3805). Acceptance: RS1-RS5 of `session-restore.sh` (recorded;
  stashed again and off the stage after a SIGKILL relaunch, on a fresh shell,
  and after an agent restart).
- **Banners (T3560)** come back with their pane whether it re-attaches or
  opens a fresh shell (`session_layout_rules.bannerToRecord` /
  `bannerToRestore`, none-lane tested; win32's T422). The restored pane tells
  its backend (`pane_banner_restored`), so the session-interrupted notice
  stays in the scrollback instead of taking the pane's own banner; a
  bannerless pane's slot still shows it. In-place agent recovery carries the
  banner across the same way. Once a pane has a banner its GL area keeps a
  1 px minimum height: a terminal starts on its first resize, and a restored
  banner too tall for a small pane used to leave it at zero height, so the
  shell never started. As on the Mac, a tall banner squeezes the terminal; it
  never stops it.
- **Tints (T3589)** come back the same way: a `--color` / `--split-color` /
  `+split --color` or inherited tint is recorded as the leaf's `tint`
  (`session_layout_rules.tintToRecord` / `tintToRestore`, none-lane tested;
  win32's T3176, Mac `Leaf.tint`), handed over on `Surface.Restore.tint` and
  applied the way an early `--color` is - held until the core surface exists.
  A viewer leaf never takes one, and an unreadable value leaves the theme
  background. In-place agent recovery carries the tint across too.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\session-restore.sh
```

Ends `SESSION RESTORE: ALL PASS`: after a SIGKILL the relaunch rebuilds every
window, split, ratio, name and pane id on the same pids with their screens; a
window comes back at its recorded size (measured from the window's own render)
with its tab's pinned title, and the running app records both again;
SIGTERM detaches and snapshots; a session that died while the app was down
comes back as a fresh shell; after an agent restart the panes come back as
relaunched shells under the new agent; banners are recorded and come back on
every one of those paths, and the session-interrupted notice takes only a
bannerless pane's slot (RB1-RB5, T3560); tints are recorded, listed as
`background_tint` and rendered after a crash relaunch, kept by a fresh shell
and by an agent restart (RT1-RT5, T3589; the test turns off
`unfocused-split-opacity` so an unfocused split's pixels are the raw tint); a
second instance neither restores nor
writes; a closed window stays closed.

### The agent dies under a running app: panes recover in place (T3400)

`src/apprt/gtk/AgentRecovery.zig`, the Mac's link observer (T12e) and win32's
settle watch + `recoverLocalAgentInPlace` (T145/T399/T723/T1473). Every
decision is win32's pure `apprt/win32/agent_recovery.zig`, shared.

- **The watch**: a 250 ms GLib timeout reads the shared link's state and the
  agent pid. A down link settles for 5 s (it may heal); a confirmed-dead agent
  pid waives the wait. Then `agent_recovery.evaluate` says `agent_restarted`
  or `transport_down`, and both rebuild.
- **The rebuild**: `LocalAgent.reconnectForRecovery` finds or spawns an agent
  and only then retires the old connection (shut down on its own thread, never
  freed - panes borrow it). Every terminal pane whose core rides a RETIRED
  connection is swapped in its slot (`SplitTree.replaceSurface` over
  `replaceLeaf`): same pane id, name, pinned title, tint and focus, re-ATTACHing
  its session when the new agent lists it alive or relaunchable (a restarted
  agent relaunches it in its directory with the `Session interrupted` notice),
  else a fresh shell in the pane's directory. Viewers are never touched. The
  replaced pane is `spareSession`d, so its teardown DETACHes instead of ending
  the session its replacement just attached; a user close still ends one.
- **A failed re-dial** retries on `retry_delays_ms` (2-30 s, six tries), then
  logs `gave up`.
- **A new pane first**: `sharedConnection` takes win32's `newSurfaceVerdict` -
  a wedged link gives an exec pane, a dead agent re-dials, and the stranded
  panes are rebuilt on the next idle.
- Log lines: `agent recovery: link down ...`, `... recovering windows in
  place`, `rebuilt <n> pane(s) ... (<a> re-attached, <f> fresh)`, `link
  recovered on its own`, `retry`, `gave up`.
- A STALE agent (an older build) and a protocol skew: next section (T3600).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\agent-recover.sh
```

Ends `AGENT RECOVER: ALL PASS` (19 checks): kill the agent tree under a running
app with two terminal panes and a viewer; the panes come back on a new agent
with the same tree, ids, names and directory and are drivable, a pane's banner
rides across while a bannerless pane shows the notice (T3560), a tinted pane
keeps its tint (A10d, T3589), the viewer is
untouched, a new pane rides the new agent, a second death raced against a new
pane recovers everything onto a third agent, and a user close still ends a
shell.

### An older agent is refreshed; a skewed one is asked about (T3600)

`src/apprt/gtk/AgentUpgrade.zig` over win32's pure `agent_upgrade.zig`
(`evaluate`, `evaluateSkew`), mapped by `agent_upgrade_rules.planFor`.

- **When**: once the first resolve settles (`LocalAgent.on_resolved`, on
  idle, never inside a pane build) and 500 ms after the last surface closes
  (the quit-timer start). Quitting is never a check moment.
- **Stale build** (HELLO stamp vs `ghoztty-agent --version`, probed once per
  run): nothing live => `restartForUpgrade` + `AgentRecovery.recover`, which
  rebuilds any tombstoned panes on the fresh agent; anything live => left
  alone (T1056). The live count is the larger of the agent's roster and this
  app's own panes on the connection, so a pane whose OPEN is in flight still
  counts.
- **Protocol skew** (`tcp_dial.dialUnixTimeoutReport` carries the peer's
  version out of the failed dial): `LocalAgent` records it and never spawns a
  second agent over the live one. Agent older => the mandatory-update
  `GtkAlertDialog` (Later, Restart Now; Later is default and cancel; Later
  holds for the run). App older => a desktop notification, never a restart.
- **The stop** reads the pid from `port.json` and refuses unless
  `/proc/<pid>/exe` is the agent (a ` (deleted)` suffix - the binary was
  replaced on disk - still matches); SIGTERM, 2 s, SIGKILL.
- Test hooks (debug only): `GHOZTTY_AGENT_BUNDLED_VERSION` (the app's bundled
  stamp), `GHOZTTY_AGENT_PROTO_VERSION` (the agent's advertised protocol),
  `GHOZTTY_TEST_AGENT_SKEW_DIALOG` (records the dialog) +
  `GHOZTTY_TEST_AGENT_SKEW_ANSWER=restart` (answers it).
- **The waiting update is visible** (T3691, win32's T1068): a settling check
  (`agent_upgrade.settlesPending`) sets `pending` from `pendingFor`, which
  enables `app.install-agent-update`. That one flag drives the main menu's
  "Background Update Ready…" row (`hidden-when: action-disabled` in
  window.blp) and the palette's "Install Background Process Update…" (an
  `app_action` palette row; the palette rebuilds each time it opens). Choosing
  either re-runs the check, then asks (Later default) with
  `installNowTextInPlace`. Restart Now is the skew path's restart +
  `AgentRecovery.recover`: the windows stay and the panes are rebuilt, with no
  app relaunch (Windows relaunches the app, T1804). Logged: `agent update
  affordance: shown (<kind>)|cleared` and `agent update offer: ...`. The
  `main-menu` seam reports each item's `enabled`. Hooks:
  `GHOZTTY_TEST_AGENT_UPDATE_DIALOG` + `_ANSWER`.
- The app-older notice has a Linux body (`app_older_body_linux`). It does not
  promise a click-to-update, because Linux has no updater behind one.
- Not yet: the dialog's What's New notes (T3692).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\agent-upgrade.sh
```

Ends `AGENT UPGRADE: ALL PASS` (48 checks). It covers six behaviors. Stale +
live is deferred, the waiting row shows, and Later keeps it. The last window
closing refreshes the idle agent and clears the row. A current agent is left
alone and the row stays hidden. The palette entry's Restart Now rebuilds the
pane on a new agent. A protocol-0 agent gets the dialog: Later leaves it, and
Restart replaces it and brings persistence back. A protocol-9999 agent gets the
app-older notice and is never stopped.

### Viewer panes restore too (T3420)

A viewer has no session to re-attach: re-opening it IS its restore (win32's
`restoreViewerOpen`, the Mac's viewer leaf). The leaf records
`viewer_location` (where the pane IS - `Viewer.currentLocation`),
`viewer_home_location` (where it was opened - `homeLocation`, Home's target)
and `viewer_origin_directory` (the `--working-directory` it was opened with -
`originDirectory`). On restore `SessionLayout.viewerRestore` hands the next
`Surface.new` the pane id, the Home (`Viewer.setHomeLocation`, which does not
navigate) and the origin directory as the pane's working directory, and the
pane is built on its recorded location. Everything else falls out of
re-opening: a picture comes back at best fit, a diff spec re-runs in the origin
directory, and a file deleted while the app was down shows the in-page
`Cannot read file` card.

Test seam: `GHOZTTY_TEST_VIEWER_DUMP_ALL=<file>` (debug builds, alongside
`GHOZTTY_TEST_VIEWER_DUMP`) appends every viewer's first render as
`<current location>\t<OK value | FAIL why>`, for a test that opens several
viewers at once.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\session-restore-viewers.sh
```

Ends `SESSION RESTORE VIEWERS: ALL PASS` (18 checks).

### The agent starts at login (T3398)

The LaunchAgent / HKCU Run counterpart. Once persistence engages (an agent
dialed), the app writes, once per run (`LocalAgent.ensureAutostart`; formats
and gates in the pure `src/apprt/gtk/agent_autostart.zig`, none lane):

- **A `systemd --user` unit** when the user's systemd answers, i.e.
  `$XDG_RUNTIME_DIR/systemd/private` exists (else `/run/user/<uid>/...`):
  `<config>/systemd/user/ghoztty-agent[-debug][-<lineage>].service`, enabled
  by a `default.target.wants/` symlink - the file `systemctl --user enable`
  makes. `Restart=on-failure`, `RestartPreventExitStatus=183` (a lost
  single-instance lock is not a crash), output appended to `agent.log`.
- **Else an XDG autostart entry**, `<config>/autostart/<same name>.desktop`,
  `Exec=/usr/bin/env "VAR=..." "<agent>" ...` (a desktop Exec cannot set the
  environment). WSL without `[boot] systemd=true` in `/etc/wsl.conf` lands
  here; that file is the user's and is never edited.
- Writing one removes the other, so only one ever starts at login. Both run
  the argv and environment `spawnDetached` uses (one helper, `spawnArgs`).
- The app **never runs `systemctl`** - nothing here starts, stops or reloads
  the user's systemd.
- **Gates** (win32's): `GHOZTTY_AGENT_AUTOSTART=off` writes nothing; a debug
  build writes only under `force` or `gate`; an agent binary inside a source
  checkout writes only under `force`. So a harness run of a `zig-out` build
  writes nothing unless the test asks.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\agent-autostart.sh
```

Ends `AGENT AUTOSTART: ALL PASS` (32 checks): the gates, each backend's file
(validated by `desktop-file-validate` / `systemd-analyze verify`), each
entry's command run the way a login would and the next app reusing that
agent, the switch back when systemd goes away, and nothing under the real
`~/.config`. The "user systemd is reachable" state is the marker file made
under the harness's private runtime dir.

## Remote-machine windows: `+new-remote-window` (T3597)

`+new-remote-window --host=<h> --port=<p>` (direct TCP) or `--relay=<base>
--device=<id> [--token=]` opens a window whose panes a REMOTE `ghoztty-agent`
hosts. Validation, refusal sentences and the relay token tiers are win32's
(`apprt/win32/ipc_remote_window.zig`, which byte-match the Mac): every
refusal is made before any dial, and the relay wins when both are given.

- **The dial runs off the GTK thread.** `src/apprt/gtk/ipc_remote_window.zig`
  validates on the GTK thread and leaves win32's std-only dial job
  (`win32/ipc_remote_dial.zig`, T3022); `IpcServer` takes it through its
  `TakeDeferred` hook, dials on a worker, then runs the open on the GTK
  thread and only then replies, so `+list` right after the verb sees the
  window. Other IPC verbs queue behind a slow dial (one accept thread), but
  the windows keep drawing.
- **The panes hold the link, not the window** (`src/apprt/gtk/RemoteLink.zig`).
  A GTK pane can leave its window, so each pane riding a machine holds a
  reference; the last one finalized (after its core surface sent its CLOSE or
  DETACH) shuts the connection down off-thread. The memory is kept until exit
  because core surfaces borrow `*Connection` (the `LocalAgent.retired` rule).
- **What a remote pane sends**: only REMOTE-native values -
  `local_shell_integration = false`, no local cwd, shell, `-e` or
  `initial-command`; an explicit `--command` is forwarded in the OPEN with
  `wait-after-command` (win32's marker). The agent runs its own shell's
  convention, so a command that exits leaves a waiting pane.
- **Same machine**: a split of a remote pane (`SplitTree.newSplitAt`) rides
  the parent's link in its REMOTE cwd (a 1.5 s `queryCwdTimeout`), and
  `+split --command` there is that machine's to run (`remote_command`).
  `+new-window --from-focused` on a remote front window re-dials its machine
  on the GTK thread, inheriting the active pane's command and remote cwd
  (win32 `openRemoteWindowFrom`).
- **A new tab** (keybind, menu, tab-bar button) in a remote window opens on
  the same link (T3668, win32 `addTab`'s T68 inheritance):
  `Window.newTabPage` hands the pressed (else active) pane's link, its remote
  cwd (the same 1.5 s query) and its command to the tab's first pane through
  `RemoteLink.pending_open`. A tab in a local window stays local.
- **Per-host defaults** (T3669, win32 `openDialedWindow` / `buildRemoteInherit`'s
  T174, Mac `Machine.applyOpenDefaults`): the store Host Settings... writes
  (`host_defaults`, keyed by relay device id, else `host:port` -
  `RemoteLink.Machine.hostDefaultsKey`). A NEW remote window takes the
  machine's default shell AND cwd, seeded in the one open tail
  (`ipc_remote_window.openWith`), so `--from-focused` gets them too; an
  explicit `--shell` / `--working-directory` (or the inherited cwd) wins, and
  an ATTACH (a relay window brought back) skips the lookup. A tab or split on
  the machine takes the default SHELL only (`Machine.hostDefaultShell`) and
  keeps its parent's remote cwd.
- **`+list`** gives a remote window `machine` (the host, or the relay name /
  device) and `connection.state`; a local window has neither field.
- **Not in the layout file**: `SessionLayout` skips remote windows, and a
  remote pane moved into a local window records no session id. Relay windows
  coming back at relaunch are T3671; Close vs
  Disconnect is T3563 (below); the chooser is T3674 (below), the pill and
  reconnect ladder T3675 (below).

Acceptance, against a loopback agent started with `--listen 127.0.0.1:<port>
--headless` (the Linux half of `test/win32/ipc-remote.ps1`) and, in section Y
(T3670), a REAL relay dial - the local rendezvous relay built from `relay/`
with `DEV_AUTH`, a device enrolled with the dev bearer, and an agent in
`--relay` mode holding that device's token (the Linux half of
`test/win32/ipc-relay.ps1`; needs the distro's `go`):

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-remote-window.sh
```

Ends `CLI REMOTE WINDOW: ALL PASS` (H1-H7 plus 48 checks: the four refusals, the panes
descend from the TCP agent and not the app, keys and `--command` round-trip,
splits, a new tab (in the pressed pane's cwd; a local window's new tab stays
local) and `--from-focused` stay on the machine, `+close` ends the remote
shells and closes the link; then Y0-Y15 over the relay: the relayed panes
descend from the `--relay` agent, `+list` names the machine by `--name` or
else by device id, a split and a new tab stay on it, `+close` ends all three
sessions). Section H (T3669) writes a host-defaults row for the TCP machine
naming a marker shell: the window opens in that shell and cwd, explicit flags
win, and a split and a new tab take the shell but their parent's cwd.
`NEGATIVE=1` dials a dead port for the main window and must fail
R1; `NEGATIVE=hostdefaults` keys the row on a port nobody dials and must fail
H2; `NEGATIVE=relay` dials a device nobody enrolled and must fail Y5 with
`failed to reach <device> via relay <url>: ...`.

## Closing a remote pane, tab or window: Close vs Disconnect (T3563)

The Mac's `SessionDisconnectPolicy` (docs/reference/remote-machines.md), over
win32's pure policy in `src/apprt/win32/session_disconnect.zig` through
`src/apprt/gtk/disconnect_offer.zig` (none lane): which panes a Disconnect
spares, the one machine to name, the widened gate and the detach pin.

- **An interactive close of anything on a remote machine asks, even idle** -
  the pane keybind (`SplitTree.surfaceCloseRequest`), a tab's x
  (`Window.tabViewClosePage`) and the window's x (`windowCloseRequest`). The
  dialog gets a third button, **Disconnect**, rightmost and the default
  (Return), and its body is the shared scope-neutral sentence naming the
  machine and counting the sessions ("the remote machine" when they span
  several). A local window, a local-agent pane, an exited shell, a viewer and
  `confirm-close-surface = false` are untouched.
- **Never widened on the scripted paths**: `+close` (`closeSurfaceNow`,
  `gtk.Window.destroy`) and a pane close that closes its tab
  (`CloseUndo.confirmed_tab`) do not ask - a modal there would wedge every
  later `ghoztty +...`.
- **Disconnect is a pin, not an intent write** (`Surface.pinDetach`). Every
  GTK CLOSE marking goes through `Surface.markSessionClose`, which the pin
  refuses: `finalize`, and `CloseUndo`'s end of a parked pane or tab when the
  undo window expires. So the pane leaves this app, its link is let go, and
  the far session keeps running. Only panes on a remote link are pinned. An
  undo that puts the pane or tab back clears the pin, so a later close ends
  the session again.
- A disconnected session is resumed from the machine chooser (T3674,
  below).

Acceptance, against a loopback TCP agent, driven through the DEBUG-ONLY
`close-dialog --target= [--op=pane|tab|window] [--answer=disconnect|close|cancel]`
seam (it starts the same close a keybind or an x does, reads the dialog and
presses a button - Wayland gives the harness no pointer). Start the close and
answer it in TWO requests (the seam refuses both at once): a dialog answered
in the same main-loop turn that presented it never leaves the window's dialog
stack, and libadwaita then spends the window's next close request dismissing
it - a harness trap, since no person can click before the dialog is up.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-remote-disconnect.sh
```

Ends `CLI REMOTE DISCONNECT: ALL PASS`; the oracle is the remote shell's pid
(alive after Disconnect, past the 1 s undo window; gone after Close).
`NEGATIVE=1` answers Close where it means Disconnect and must fail D4.

## The connection pill and reconnect (T3675)

Mac's `MachinePillView` and WP-D1 ladder; win32's `remote_pill.zig`
(words) and `remote_reconnect.zig` (decisions), both shared, over
`src/apprt/gtk/RemoteReconnect.zig` (the driver) and `RemotePill.zig` (the
widgets).

- **The ladder lives on the link** (`RemoteLink.Link.reconnect`), not on a
  window: GTK panes hold the link and can span windows, so one dial has one
  ladder and every window showing a pane on it paints the same pill. A
  link-state observer (installed on a pane's adoption, again after every swap)
  queues one `g_idle_add`; a 250 ms GLib timer runs only while a link is
  retrying, waiting on the slow re-dial, or a dial is out.
- **Schedule**: a drop of a link with a session to re-attach dials at 1/2/4/8/15
  s ("Reconnecting... n/5"), then every 45 s in the background (red
  "Reconnect", `self_healable: true`). A link that comes back on its own at any
  point recovers with no swap. Session gone (the agent restarted), signed out,
  evicted, or three swaps that die inside 10 s: terminal (`self_healable:
  false`). A protocol skew: "Version mismatch", terminal.
- **The swap**: a worker dials (TCP, or the relay with the account's bearer,
  else the one the window was dialed with) and asks for the roster; on the GTK
  thread the link takes the new transport FIRST, every pane riding it is
  replaced in its slot (`SplitTree.replaceSurface`: same pane id, name, title,
  banner, tint, focus) re-ATTACHing its session by id, the old pane is
  `spareSession`d (it DETACHes), and only then is the old transport shut down -
  kept, never freed (`Link.replaceTransport`).
- **The pill**: a button at the start of the header bar's end box AND of the tab
  bar's (`titlebar-style = tabs` hides the header bar): a dot (libadwaita
  `success` / `warning`) or the refresh glyph, the machine's name, the status
  appended (D93). Broken: `destructive-action`. Tooltip is win32's sentence. A
  click on a broken pill reconnects now, from any disconnected tier, with no
  backoff; when the far sessions are gone a click keeps the layout and opens a
  fresh shell in every pane (T611). A click on a working pill opens the Remote
  Activity Monitor on Mac and Windows; GTK has none yet (T3818), so it logs.
- **`+list`**: `connection` is the ladder's state (`attempt` while
  reconnecting, `self_healable`, `reason: "incompatible"`), not the raw socket.
- Log lines: `remote reconnect: <machine> dropped; attempt n/5 in <ms>[
  (manual)]`, `dialing`, `is back on a fresh transport (<a> pane(s)
  re-attached, <f> opened fresh)`, `link recovered on its own`, `exhausted its
  fast ladder`, `is terminal after attempt <n> (<outcome>)`.
- Not yet: the pill does not follow a remote pane dragged INTO a local window
  until that window's tree next changes (every tree change repaints it).

Seam (DEBUG-ONLY, `src/apprt/gtk/ipc_remote_pill.zig`): `remote-pill
--target=<window|pane> [--op=state|click]`; the reply is the header-bar pill as
drawn (`visible`, `name`, `status`, `mark` dot|refresh, `dot_class`,
`action`, `tooltip`), `last_click`, and the `+list` `connection` object.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\remote-reconnect.sh
```

Ends `REMOTE RECONNECT: ALL PASS` (20 checks, about 2 minutes warm). The app
dials the agent through a python TCP relay the script owns, so killing the
relay cuts the link while the shells live on: P1 the pill names the machine (a
local window has none), P2 amber and counting, P3 the relay back and the SAME
shell pids re-attached and drivable, P4 past the fast ladder the red Reconnect
and a click that dials at once, P5 an agent restarted without its sessions goes
terminal and a click brings the two-pane layout back with fresh shells.
`NEGATIVE=1` never restarts the relay in P3 and must fail P3.

## The machine chooser: browse, resume, end (T3674)

`src/apprt/gtk/MachineChooser.zig` - Mac's `MachineChooserView`, win32's
`MachineChooser.zig` - as an `AdwDialog` (840x540): the account line, Local
then the account's relay devices on the left, the selected machine's detail
and roster on the right. The words and rules are win32's pure modules
(`chooser_rows`, `chooser_sessions`, `chooser_session_sort`, `chooser_help`,
`chooser_refresh`), glued in `machine_chooser_rules.zig` (none lane), so the
three seats say the same thing. Local's detail title is "This Computer"
(Mac "This Mac", Windows "This PC").

- **Opened by** Ctrl+Shift+N - the window's capture-phase key controller asks
  `Window.chooserChord`, which is win32's `window_chord.classify`, so the
  chord shadows `ctrl+shift+n -> new_window` whatever holds the keyboard and
  Ctrl+N stays a local window - the window menu's "New Remote Window…"
  (`win.new-remote-window`) and Settings > Remote Machines' button. One at a
  time; a second open re-presents it.
- **Never waits on the network to open**: devices come from `machine_cache`
  (shared with Settings) as "Checking status", then one `listDevices` on a
  worker, re-run every `chooser_refresh.poll_ms` (5 s) while open; a failure
  keeps the list that is true (`chooser_refresh.Misses`), a 401 empties it.
- **The roster**: selecting a machine fetches `LIST_SESSIONS` on a worker -
  Local on the shared local-agent connection (nothing when
  `session-persistence = false`; showing it never starts an agent then), a
  relay machine dialed per fetch - and refreshes it in place on the same 5 s
  beat, so a session a Disconnect just left appears. Rows are
  `isActionable` only (running, and not held by someone else's viewer),
  labelled by `chooser_sessions.label` and sorted by name then id.
- **Resume / Show / End**: a session one of our panes holds
  (`IpcHandlers.paneHoldingSession`, keyed by device for a relay) is **Show**,
  which focuses that pane; any other is **Resume**, which opens a window
  ATTACHed to it - relay through the one open tail
  (`ipc_remote_window.openWith` with the session id, so it is recorded for
  relaunch), Local through `Surface.pending_restore`. Either closes the
  chooser. **End** sends `CLOSE_SESSION` then refetches; the chooser stays.
- **New Window** opens on the selected machine (a relay one gets its per-host
  defaults through `openWith`); **Host Settings...** (relay rows) is the
  T3635 editor. Every control carries Mac's `.help` sentence.
- Not yet: the warm connection pool and pushed roster (T3811), CPU meters and
  sort headers (T3812), Restore All (T3813), Rename / Remove / See Activity
  (T3814), keyboard navigation and the filter (T3815), the forced "Sign Out
  Anyway" after a revocation that failed (T3676).
- **The account row signs in and out** (T3575; win32 `RelayAccountRow`, Mac
  `accountRow`). Words: win32's `relay_account_text.zig` (shared since this
  card), composed in `machine_chooser_rules.accountView`: signed in it is
  "Signed in as <email>" over **Sign Out**; signed out it is the **Sign in
  with Google…** button alone; an unconfigured build has no button and says
  "Google sign-in isn't set up in this build" (the hover carries the
  remedy). Sign In runs `relay_signin.signIn` on a worker (it waits on the
  browser for minutes) and lands through `g_idle_add`; while it runs the
  row reads "Finish signing in in your browser…" and the button is
  "Signing in…", insensitive, app-wide (a reopened chooser shows it too).
  Sign Out is `relay_signin.signOut(.revoke)`, its outcome sentence under
  the row. A sign-in refetches the machines and replays the relay-window
  record (`RelayWindows.start`, skipping the windows already open), so
  windows a signed-out launch kept come back. **Linux-only line**: when the
  stored account is in the 0600 file (`relay_account.location() == .file`,
  no keyring daemon - the WSL default), the row says "No keyring is
  running, so your sign-in is kept in a private file only you can read
  (<path>)", `~` for home; under a keyring it says nothing.

Seam (DEBUG-ONLY, `src/apprt/gtk/ipc_machine_chooser.zig`): `machine-chooser
--op=open|chord --key=<ctrl+shift+n|ctrl+n|ctrl+alt+shift+n>|state|select
--value=<id>|new-window|resume --value=<session>|end --value=<session>|
host-settings|sort --value=name|cpu|account|close`; every button op emits that
button's `clicked`, every reply is the chooser as drawn (machines, detail,
tooltips, roster state, rows) plus `last`, what it last did (kept after it
closes).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\machine-chooser.sh
```

Ends `MACHINE CHOOSER: ALL PASS` (35 checks, a real relay built from
`relay/` as in `cli-remote-window.sh` section Y, about 1 minute warm): the
chord, the window menu and Settings openers, the list and detail, New Window
on the relayed agent, Disconnect then
Resume of the SAME far shell, Show without a second attach, End, and a local
session a SIGKILLed app left behind resumed. A local session's roster `pid` is
the top of its process tree, so the test matches a local shell by ancestry.
`NEGATIVE=1` presses New Window where Resume is meant and must fail R4.

The account row (state adds `account_visible`, `account_button` - null when
hidden - `account_button_sensitive`, `account_busy`, `account_store_note`,
`account_message`):

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\chooser-account.sh
```

Ends `CHOOSER ACCOUNT: ALL PASS` (23 checks, about 2 minutes warm). A python
relay on loopback answers `/oauth/exchange` and `/oauth/signout`; the app
runs with `GHOZTTY_ENROLL_NO_OPEN=1`, and the harness plays the browser by
GETting the redirect URL the app logged. U: an unconfigured build. A: a
private session bus with no keyring - signed out, Sign In, busy, the
redirect, the email, a 0600 file and its sentence, the machines listed,
a reopen, Sign Out (revoked at the relay, file gone), a refused exchange.
K: an unlocked gnome-keyring (extracted, secret-store.sh's recipe) - no file,
no sentence, Sign Out clears it. `NEGATIVE=1` runs a keyring in phase A too
and must fail A5/A6.

- **Signing out revokes THIS machine** (T3676; win32 T1421/T1424-T1426, Mac
  `RelayAccount.signOut`). The revocation, its retry and the re-enroll are
  all shared core - `relay_signin.signOut` (whoami, then
  `POST /v1/agent/deenroll` with relay.env's own credential, the machine's
  relay name recorded in `suspended-enrollment.json` BEFORE the POST),
  `relay_revoke_pending` (the armed retry, 0/5/15/60 s... backoff, and the
  agent's `revoke_watch`), `relay_suspend` (the sign-in restore) - so the
  GTK half is three affordances: a `.not_revoked` outcome (the user stays
  SIGNED IN) raises an `AdwAlertDialog` in win32's words
  (`relay_account_text.not_revoked_title/body`) with **Stay Signed In**
  (the default and Escape) and destructive **Sign Out Anyway**, which runs
  `signOut(.force)`; the signed-out row reads `pendingRevocationText`
  ("This machine is still connected to <owner> — still removing it.")
  while `pending-revoke.json` is usable, re-read on open, after every
  operation and on the 5 s poll; and the app's startup calls
  `relay_suspend.launchAsync` (signed out: finish an armed revocation;
  signed in: give the machine back), as win32's `App` does. Seam: state
  `account_confirm` ({heading, body} or null) and `account_confirm_answer`,
  op `account-confirm --value=anyway|stay` (works with the chooser closed).
  Closing the relay windows on sign-out is T3817.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\chooser-signout-revoke.sh
```

Ends `CHOOSER SIGNOUT REVOKE: ALL PASS` (23 checks, about 1 minute warm). A
python relay answers whoami/deenroll/devices as well; its `nodeenroll` mode
503s the de-enroll. R1-R6 the failed sign-out and its question, R7-R9 Sign
Out Anyway, R10-R11 the relay back (the retry lands, the row's sentence
goes), R12-R13 the same account's sign-in re-enrolls under the old name,
R14-R16 a revocation a quit run left armed is finished by the next launch.
`NEGATIVE=1` lets the relay de-enroll in `nodeenroll` too: 13 failures.

## The relay account store: keyring, else a private file (T3341)

The Linux row of Keychain -> DPAPI: `src/remote/relay_account.zig` keeps the
signed-in relay session in the **Secret Service** when a keyring daemon
answers, and in a **mode-0600 file** at
`$XDG_DATA_HOME/ghoztty/account[-debug].dat` (default
`~/.local/share/ghoztty/`) when none does - which is the WSL default, since
WSL runs no keyring daemon. `relay_account.location(path)` answers
`.keyring`, `.file` or `.none`, for the account row to say where the sign-in
is kept.

- **libsecret is loaded, not linked** (`src/remote/secret_service.zig`,
  `dlopen("libsecret-1.so.0")` on first use). A missing library and a missing
  daemon are the same answer: use the file. Nothing gains a link dependency.
- **One item, keyed by the store path** (schema
  `com.dzearing.ghoztty.relay-account`, the Mac's Keychain service name;
  attribute `store` = the path). A debug build's item is not the release one
  (T1859), and a `GHOSTTY_ACCOUNT_STORE` override names its own item.
- **A save that reaches the keyring deletes the file**, so a keyring that
  starts later absorbs the credential at the next renewal.
- `GHOSTTY_ACCOUNT_KEYRING=off` forces the file.
- **Unit tests never touch a real keyring.** `systemKeyring()` is null in a
  test binary unless `GHOZTTY_TEST_SECRET_SERVICE` is `1` or `absent`; the
  routing tests use a fake keyring.

Acceptance, the real libsecret against a real daemon:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\secret-store.sh
```

Each phase runs on a **private session bus** (its own `dbus-daemon`), never
the person's. Phase A has no daemon on it (the account lands in a 0600 file);
phase B starts `gnome-keyring-daemon --unlock --components=secrets` and checks
the account goes to the keyring with no file written, reads back and clears.
The daemon is **extracted** from its `.deb` into
`/var/tmp/ghoztty-secret-store-tools` (`apt-get download` + `dpkg-deb -x`),
never installed: an installed gnome-keyring registers
`org.freedesktop.secrets` on the distro's own session bus and changes how every
app there stores secrets. Each opt-in test appends a line to a marker file when
it ran, so a skipped test cannot read as a pass. Ends `SECRET STORE: ALL PASS`.

## Packaging and the `ghoztty://` scheme (T3343)

**The tarball.** `scripts/linux/package.sh` builds the GTK app into a private
prefix and tars it as `zig-out/dist/ghoztty-linux-<arch>-<release|debug>-<sha>.tar.gz`
(one top-level `ghoztty/`: `bin/`, `lib/ghoztty/`, `share/`, plus
`install.sh` and `.package-info`, the version/commit/mode record the .deb
builder reads). `PKG_OPTIMIZE=ReleaseFast` (default) or `Debug`; `PKG_OUT`
moves it.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile scripts\linux\package.sh
```

**The one private library, and the RUNPATH trap** (T3578). Ubuntu does not
package `libgtk4-layer-shell`, so the build makes it from source and the app
links it dynamically. Zig's link step leaves `bin/ghoztty` a RUNPATH of
`.zig-cache/o/<hash>` - a path relative to the *current directory* - so a
packaged copy found the library only when started from the repo root, and
`package-install.sh` passed because it ran from there. `package.sh` now moves
the library to `lib/ghoztty/` and sets the RUNPATH to `$ORIGIN/../lib/ghoztty`
with patchelf (installed by `setup-distro.sh`), which holds for the tarball,
`~/.local/opt` and the .deb's `/usr`. It also drops the build's developer
artifacts (`include/`, `libghostty-vt`, pkg-config files). Every packaging
test runs its binary from `/` so the trap cannot pass again.

**The .deb** (T3578). `scripts/linux/package-deb.sh [TARBALL]` (default: a
fresh release `package.sh` build) lays the same tree out under `/usr`
(`/usr/bin/ghoztty`, `/usr/lib/ghoztty/`, `/usr/share/...`), points the Exec
lines at `/usr/bin/ghoztty`, takes `Depends` from `dpkg-shlibdeps`, and writes
`zig-out/dist/ghoztty_<ver>+<commit count>.g<sha>_<arch>.deb`. A Debug tarball
is refused (exit 3). It has no maintainer scripts: the desktop database, icon
and MIME caches are refreshed by the dpkg file triggers desktop-file-utils,
hicolor-icon-theme and shared-mime-info declare, and the entry's `MimeType` is
what makes it the system-wide `ghoztty://` handler.

**The AppImage** (T3658). `scripts/linux/package-appimage.sh [TARBALL]`
(default: a fresh release `package.sh` build; a Debug tarball only with
`APPIMAGE_DEV=1`, exit 3 otherwise) writes
`zig-out/dist/Ghoztty-<ver>+<count>.g<sha>-<mode>-<arch>.AppImage`: the pinned
AppImage type2 runtime (`setup-distro.sh` fetches release `20251108` and checks
its sha256) followed by a zstd squashfs of the AppDir - what appimagetool
writes, minus update info and signing. No linuxdeploy: the bundler is the
script itself.

- **What it bundles.** The tarball's tree under `usr/`, plus every library
  `ldd` resolves for the app, WebKit's helpers and the bundled modules, minus
  `scripts/linux/appimage/excludelist` (glibc, libstdc++/libgcc_s, the
  GL/EGL/DRM stack, X11/xcb, Wayland, fontconfig/freetype/harfbuzz, alsa,
  udev, dbus: the host's own). That is about 137 libraries, 102 MB release.
  Modules: glib-networking's TLS module (https in a website pane), the
  gdk-pixbuf SVG loader, a GStreamer plugin subset plus its scanner, and the
  GTK 4 GSettings schemas. Every bundled ELF gets an `$ORIGIN` RUNPATH. The
  floor it needs: glibc 2.39 (the build distro's), a host libstdc++ at least
  as new, and `bwrap` for WebKit's sandbox.
- **WebKit's helpers.** `libwebkitgtk-6.0` spawns `WebKitWebProcess` and
  `WebKitNetworkProcess`, and loads its injected bundle, from
  `/usr/lib/<triple>/webkitgtk-6.0`, compiled in. A distro build reads no
  variable to move it (`WEBKIT_EXEC_PATH` is developer-mode only and absent
  from Ubuntu's). The bundled copy has the string rewritten, same length, to
  `/tmp/.ghoztty-appimage-webkit` padded with `/`, and `AppRun` points that
  symlink at the mount. Measured: an absolute path works under WebKit's
  bubblewrap sandbox. The cwd-relative `././/lib/...` trick other AppImages use
  fails with `bwrap: execvp ... No such file or directory`, because the sandbox
  does not keep the cwd. `AppRun` uses the link only if it is this user's
  symlink. A directory there, or a link someone else owns, stops the launch
  (exit 1), so WebKit never runs another user's binary. A CLI verb (`+...`)
  never repoints it.
- **`LD_LIBRARY_PATH` is needed after all.** Bubblewrap shows the web process
  only the host's system directories plus those in `LD_LIBRARY_PATH`. Without
  it the sandboxed web process silently loaded the HOST's libwebkitgtk (seen
  with the host's copy present), and died where there was none.
- **What the shell gets.** `AppRun` records every variable it changes:
  `GHOZTTY_APPIMAGE_ORIG_<NAME>` holds a replaced value and
  `GHOZTTY_APPIMAGE_UNSET` lists the names that were unset; the second is also
  the marker. `src/apprt/gtk/appimage_env.zig` (none lane) undoes exactly
  that, and drops the runtime's `APPDIR`/`APPIMAGE`/`ARGV0`/`OWD`, for a
  pane's shell (`surface.defaultTermioEnv`) and for the agent it spawns
  (`LocalAgent.spawnDetached`). The app keeps them for itself, because WebKit's
  network process reads `GIO_MODULE_DIR` each time it spawns.
- **The top-level entry** is the tarball's with `Exec=ghoztty ...`. It drops
  `TryExec` and `DBusActivatable`, since there is no D-Bus service file to
  activate. The icon and `.DirIcon` sit beside it.

Not done yet (filed): URL opening still hands `AppRun`'s variables to the
host's browser; the agent runs from the FUSE mount, which goes away when the
app exits; the link should be re-checked before each viewer; the GStreamer
subset has never played media.

**Installing it** (`ghoztty/install.sh`, from the unpacked tree; never sudo,
nothing outside `$HOME`): the tree goes to `~/.local/opt/ghoztty`, a symlink to
`~/.local/bin/ghoztty`, and the desktop entry, D-Bus service, systemd user unit
and icons to `$XDG_DATA_HOME`, each with its `Exec`/`TryExec`/`ExecStart`
rewritten to the installed binary (the build bakes in its staging prefix).
Then the entry becomes the default `x-scheme-handler/<scheme>` - `xdg-mime
default`, or a `[Default Applications]` line written by hand when xdg-mime is
absent (`GHOZTTY_INSTALL_NO_XDG_MIME=1` forces that path). Every file outside
`opt/` is listed in `opt/ghoztty/.install-manifest`; `--uninstall` removes
those, the tree, and the handler line only if it is ours. **A Debug package
is refused without `--dev`** (exit 3): it answers on the debug app id, socket
and `ghoztty-debug://` scheme, the same names as a `zig-out` dev build.

**The templates.** `dist/linux/app.desktop.in` carries
`MimeType=x-scheme-handler/@URL_SCHEME@;` (`ghoztty`, or `ghoztty-debug` for
Debug/ReleaseSafe - the app-id split) and `Exec=... %u`. Upstream's
`bin/ghostty` in the entry, D-Bus service and systemd unit is now
`bin/ghoztty`, the file the build actually makes; Name is `Ghoztty`.

**How a link reaches the app** (`src/apprt/gtk/url_scheme.zig`; pure half
`url_activation.zig`, none lane). Focus-only, as on every platform; nothing is
ever created.

- **D-Bus `Open`.** The entry is `DBusActivatable`, so GIO launchers call
  `org.freedesktop.Application.Open` on the running app. The app now sets
  `G_APPLICATION_HANDLES_OPEN` and implements `open`, which runs the shared
  `verbs.focus` in process. Only a single-instance app owns its bus name; the
  test runs one on a private `dbus-daemon`.
- **The `Exec` line.** Anything else runs `ghoztty <url>`: `main_ghostty`'s
  `runUrlSchemeActivation` hook (win32's) makes that an activation process -
  it sends `focus` over the IPC socket and exits 0 focused, 1 nothing has that
  name (a cold click too: it never launches a terminal), 2 unsupported. The
  scan stops at `-e`/`--`.
- **A miss** shows the shared `Failure` wording in a `GtkAlertDialog`, one per
  burst: a flag in process, an `flock` on
  `$XDG_RUNTIME_DIR/ghoztty[-debug]-url-warning.lock` across activation
  processes. Not an `AdwAlertDialog`: under libadwaita 1.5 a parentless one
  closed with `adw_dialog_close` never emitted `closed`, so the process never
  exited; `GtkAlertDialog.choose` completes however the dialog ends.
  `GHOZTTY_URL_SCHEME_QUIET=1` logs instead; a debug build's
  `GHOZTTY_TEST_URL_SCHEME_DIALOG=<file>` records `shown <title>|<body>` and
  ends the dialog through its cancellable 500 ms later.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\url-scheme.sh
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\package-install.sh
```

`URL SCHEME: ALL PASS` (both paths, by name and pane id, both spellings, every
miss, burst coalescing in and out of process) and `PACKAGE INSTALL: ALL PASS`
(a Debug package into a throwaway `HOME`; `desktop-file-validate`, xdg-mime
and `gio mime` agree; the installed binary runs from `/`).

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\package-release.sh
```

`PACKAGE RELEASE: ALL PASS` (T3578, about 6 minutes: a release and a debug
build). R: the ReleaseFast tarball carries the release app id and scheme, its
RUNPATH is `$ORIGIN`, it runs from `/`. I: `install.sh` installs it without
`--dev`. S: the installed release app and a `zig-out` dev build side by side in
one headless Weston and one private bus - `ghoztty://focus/<name>` through the
release binary reaches only the release app, is a miss for a name only the dev
build holds, and leaves the dev build's layout and focus exactly as they were;
each owns only its own bus name and socket. D: the .deb's control, `/usr`-only
contents, Exec lines, root ownership, no file clashing with an installed
package, `apt-get install --simulate` resolving its Depends, a `dpkg --root`
install into a throwaway root (never this distro's `/usr`) that runs, the
MIME cache once the trigger's command runs, `dpkg -r` removing every file, and
a Debug tarball refused.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\package-appimage.sh
```

`PACKAGE APPIMAGE: ALL PASS` (T3658, about 8 minutes). B: AppDir layout, the
relocated WebKit string, nothing excluded bundled, `$ORIGIN` RUNPATHs, each
ELF's own deps bundled or excluded. H: in a private mount namespace where the
host's GTK 4, libadwaita, WebKitGTK and JavaScriptCore are bind-mounted over
with `/dev/null` and WebKit's helper dir is emptied (the unpacked tarball
cannot start there, as a control), the FUSE-mounted debug AppImage renders
markdown and a loopback website. The app maps the mount's libwebkitgtk, its
web and network processes are the AppImage's, and bubblewrap is running. E:
the app's own env has `AppRun`'s variables, the pane's shell has none of them,
and an overridden one comes back with its original value. L: link
ownership refusals, and a CLI verb leaves the link alone. X:
`APPIMAGE_EXTRACT_AND_RUN=1`. R: a release AppImage (ReleaseFast, release app
id) opens a viewer pane asked for by `+split --view` run through the same
image.

Not covered: the AppImage on a distro other than Ubuntu 24.04, a real `apt install` on a clean machine,
and a real desktop's browser handing a click to xdg-open - the harness has no
browser, so that last hop is the person at the keyboard's.

## Distro state (2026-11-21)

- Ubuntu 24.04.1 LTS, runs as `root` (`$HOME=/root`), 32 cores, 47 GB visible.
- zig 0.15.2 and blueprint-compiler 0.16.0 are installed by `setup-distro.sh`
  (above). Inside a step `command -v zig` names the wrapper function; ask
  `type -P zig` for the binary.
- git is `/usr/bin/git`. The Windows `ghoztty.exe` is not reachable from a step
  (PATH guard).
- The user runs other work in this distro (`~/*.sh`, a model server): do not
  touch `~` beyond `~/ghoztty-l` and the `~/.local` entries named above.
