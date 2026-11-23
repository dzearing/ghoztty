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
  apt-get install -y --no-install-recommends libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev gettext libxml2-utils python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 mesa-utils weston git curl xz-utils
  ```

  Ubuntu 24.04 gives GTK 4.14.5, libadwaita 1.5.0 and WebKitGTK 2.52.6 (`webkitgtk-6.0`, the GTK4 build, for viewer panes).
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
  `+rename`, `+close`, `+rearrange`, `+reload` (a viewer pane, T3413),
  `+set-banner`, `+set-state` (T3339) and the
  `focus` action are real; every other verb answers `+<verb> is not served by
  the Linux app yet (<task>)`, naming the card that brings it (T3369
  `+reload --config`, T3337 stash/restore/remote).
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
  (`Surface.bannerLink`; Ctrl splits a viewer beside the pane). `+set-state` /
  OSC 7777 is stored on the surface and listed as `state`; it is not shown
  yet (T3561). A debug build appends every render to
  `$GHOZTTY_TEST_BANNER_DUMP` (`BANNER <pane-id> shown|cleared`, one line per
  widget, `END`). Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\cli-banner.sh`, ends `CLI BANNER: ALL PASS` (32 checks). Not
  yet: collapse and the Ctrl+R editor (T3559), restore (T3560), the link
  menu (T3561), the pane sidebar (T3557, T3558).
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
  test\linux\cli-windows.sh`, ends `CLI WINDOWS: ALL PASS` (35 checks).
- **`+close` and `focus` (T3367)** follow win32's too: `+close` closes a pane
  (its window when it was the last pane) or a window with no confirmation,
  succeeds on a name nothing holds, refuses an ambiguous one, and refuses
  over an open dialog unless `--force` (which dismisses it). `focus` has no
  CLI verb on any platform - it is the `ghoztty://` launcher's action - and
  never creates. Weston headless has no seat, so no window is ever ACTIVE in
  the harness: a window raise cannot be asserted there, only pane focus. To
  stand a dialog over a window, a debug build opens the window whose
  `+new-window --target` equals `$GHOZTTY_TEST_ASK_TO_CLOSE` with its real
  close confirmation up. Acceptance: `wsl-run.ps1 -CommandFile
  test\linux\cli-close-focus.sh`, ends `CLI CLOSE FOCUS: ALL PASS`.
- **`+rearrange` (T3368)** is win32's `handleRearrange`: the shared
  `validateLayout` / `firstDuplicate` checks and sentences, then the window
  (`--target`, else the caller's window, else the front one), then every leaf
  resolved inside that window's active tab (a pane id anywhere, else a pane
  name of THAT window; a name held only elsewhere is "not in the target
  window"). Panes move with their shells; ratios are percents clamped 10-90;
  focus stays on a surviving focused pane, else goes to the top-left leaf. A
  pane the layout omits closes at once with its shell: the Linux app has no
  close undo or stash yet (T3384), which is win32's `undo-timeout = 0`.
  Acceptance: `wsl-run.ps1 -CommandFile test\linux\cli-rearrange.sh`, ends
  `CLI REARRANGE: ALL PASS` (28 checks).
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
  win32's refusals word for word. `--config` answers that T3369 brings it.
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
  `ghoztty://` popup focuses. Nothing is ADOPTED yet: `create` always returns
  no web view (a script sees `window.open()` return null), a Ctrl-clicked
  same-site popup to http(s) opens a fresh viewer window at its URL (its
  opener is lost), and a bare `window.open()` or a non-web scheme logs
  `not adopted on Linux yet (T3447)`. Adoption with `window.opener` and the
  requested size is T3447.
- **The link menu**: the shared `links.js` is a user script in EVERY frame
  (an iframe's link gets the menu too); it declines a `#fragment`, a click in
  a selection and schemes with no action, and posts `linkMenu` on
  `viewerTOC`. `ghoztty-page:` is in its scheme list for this platform. The
  href is resolved to what the menu acts on first (a relative doc link or a
  page link is the FILE, a broken doc link the file it meant), then a
  `GtkPopoverMenu` pops at the last pointer position over the page, rows,
  order and ids `banner_link`'s with Linux titles (`Open Containing Folder`
  for reveal, the nav bar button's own wording), separators as GMenu
  sections.
- **Opening things**: the browser is `GtkUriLauncher`, a default app
  `GtkFileLauncher`, reveal the bar button's `open_containing_folder` road,
  a split `SplitTree.newSplitAt(.right, ...)` from the pane's `Tab`, a window
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

Ends `VIEWER LINKS: ALL PASS` (36 checks).

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
  Not yet: Ctrl+C copying the picture (T3534). A viewer pane cannot be split
  narrower than its nav bar, about 260 px (T3533).
- **Reading it back**: every decision is a `viewer image ...` log line, and
  the steps seam's `image` step prints `rev= loads= route= zoom= fitting= fit=
  natural=WxH viewport=WxH`. A picture's `wait` is its decode-and-fit (the
  `loaded` answer), not the `setImage` call.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-image.sh
```

Ends `VIEWER IMAGE: ALL PASS` (28 checks).

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
- **Narrow pane**: an overlay over the document. The nav bar's first item
  (`sidebar-show-symbolic`) opens and closes it. Entering the narrow layout
  closes it, a row click dismisses it, and nothing is reserved.
- **The pane width is measured live** by a `GtkDrawingArea` overlay
  (`can-target` off) whose `resize` reports the page area. A split divider
  drag or a window resize switches the layout either way.
- The open state is never saved. Only the width is.
- **Driving it headless**: the steps seam's `toc` prints `mode= open= card=
  button= handle= rows= active= selected= width= cardw= shownw= gutter=
  pane=WxH`, `toc-rows` the `id:depth` list, `toc-row <id>` clicks a row,
  `toc-drag <dx>` drags the edge, `click contents` the button, and
  `resize WxH` resizes the window (`gtk_window_set_default_size`, which
  headless Weston honours). The page's padding is read with a `probe`.

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-toc.sh
```

Ends `VIEWER TOC: ALL PASS` (25 checks).

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
- Not yet: dark style (T3552, the vars are fixed Adwaita light), the draft
  folder + footer link (T3553). Quoting and pictures are the next sections.
- **Steps seam**: `composer` prints `open= view= ready= lines= sending=
  sends= quotes= quoted= filed= status=... text=...` once the page is up and
  no send is out (`quotes` = live blocks, `quoted` = ever registered);
  `composer-type <text>` types through `insertText` (`\n` = newline);
  `composer-key ctrl+Enter|Escape|Enter`; `composer-probe <js>` evaluates in
  the composer page; `click feedback-send`.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-composer.sh
```

Ends `VIEWER COMPOSER: ALL PASS` (23 checks, about 2 minutes).

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
  here. `ssh_transport`'s `ChildStream.close` did exactly that until T3354:
  the reader now blocks in `poll` on its fd plus a private wake pipe that
  `close` writes, and the fd itself is released by `deinit` once the reader
  is joined. Use the same shape for any new "close unblocks the reader" code.
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

- **The file** is `<config root>/ghoztty/session-layout[-debug][-<lineage>].json`,
  beside the agent's state dir under the same root, so the harness's private
  `XDG_CONFIG_HOME` holds a test's manifest too.
- **It records** per window its target name, pinned title, maximized state and
  selected tab; per tab the split tree with exact directions and ratios; per
  terminal pane its session id, pane id, name, pinned title and pwd; per
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
  opens its own. Panes are built through the ordinary window/tab/split paths,
  each handed its restore through `Surface.pending_restore`.
- **Not restored yet:** window size and position (Wayland gives a client no
  position; size is T3549), tab titles, banners and stash (T3339, T3399).

Acceptance:

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\session-restore.sh
```

Ends `SESSION RESTORE: ALL PASS`: after a SIGKILL the relaunch rebuilds every
window, split, ratio, name and pane id on the same pids with their screens;
SIGTERM detaches and snapshots; a session that died while the app was down
comes back as a fresh shell; after an agent restart the panes come back as
relaunched shells under the new agent; a second instance neither restores nor
writes; a closed window stays closed.

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
(one top-level `ghoztty/`: `bin/`, `share/`, plus `install.sh`).
`PKG_OPTIMIZE=ReleaseFast` (default) or `Debug`; `PKG_OUT` moves it.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile scripts\linux\package.sh
```

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
and `gio mime` agree). Not covered: a release package (T3578), .deb/AppImage
(T3578), and a real desktop's browser handing a click to xdg-open - the
harness has no browser, so that last hop is the person at the keyboard's.

## Distro state (2026-11-21)

- Ubuntu 24.04.1 LTS, runs as `root` (`$HOME=/root`), 32 cores, 47 GB visible.
- zig 0.15.2 and blueprint-compiler 0.16.0 are installed by `setup-distro.sh`
  (above). Inside a step `command -v zig` names the wrapper function; ask
  `type -P zig` for the binary.
- git is `/usr/bin/git`. The Windows `ghoztty.exe` is not reachable from a step
  (PATH guard).
- The user runs other work in this distro (`~/*.sh`, a model server): do not
  touch `~` beyond `~/ghoztty-l` and the `~/.local` entries named above.
