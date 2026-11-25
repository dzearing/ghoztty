# Ghoztty for Linux (WSL first)

Started 2026-11-21 at the user's request: "start a port of ghoztty for linux as
well so that it can run in wsl. similar to how we're approaching the windows
port - the mac version is first to get features, we port to windows and linux."

## Stance

- **macOS leads.** Features land on the Mac first. Windows and Linux are both
  followers that translate the Mac feature, never the Mac implementation - the
  same contract the Windows port has run under since July (CLAUDE.md, "Platform
  symmetry is a standing rule").
- **First target is WSL2 + WSLg on this box.** WSLg gives a Linux GUI app a
  Wayland compositor (with XWayland) that draws into ordinary Windows windows.
  Anything that runs there runs on a native Linux desktop too; native desktops
  are not a separate target, only a later validation lane.
- **One tracker.** Linux work is filed in `docs/design/windows-parity-tasks/`
  with `seat: linux`. `parity-tasks.ps1 next` filters by seat, so the Windows
  go-loop never claims a Linux task and its queue is untouched. Same id space,
  same dashboard (a "Linux-seat open" tile sits beside "Mac-seat open").

## Starting point (read from the tree, 2026-11-21)

| Piece | State | Where |
|---|---|---|
| Linux frontend | Upstream Ghostty's GTK4/libadwaita apprt is still in the tree. The fork has only touched it in sweeping renames (`912299319` purged `com.mitchellh.*`); none of the Ghoztty features are in it. Expect it **not to compile**: Ghoztty added apprt actions that the GTK `performAction` has never been taught. Unverified until a Linux build runs. | `src/apprt/gtk/` |
| CLI → app IPC client | Already POSIX. The Mac path is a Unix domain socket, and `apprt.ipc.socketPath()` only special-cases Windows, so a Linux client resolves a socket with no new code. | `src/apprt/ipc.zig`, `src/os/ipc_client.zig` |
| IPC server + verb handlers | The Windows server is Zig: 2793 lines of handlers with only 7 `w32.` calls, plus shared helpers already in `src/apprt/ipc/` (args, list, read_tail, target_lookup, url_scheme...). Most of the verb logic can move into shared code and serve GTK too. The Mac server is Swift and cannot be shared. | `src/apprt/win32/IpcHandlers.zig`, `IpcServer.zig`, `IpcRegistry.zig` |
| `ghoztty-agent` | Already has Linux branches: metrics sampling, foreground-process lookup, pid, `xdg-open`. PTYs are the same POSIX code the Mac uses. Probably the closest to working today. | `src/remote/agent/` |
| Sweep/intake | `parity-sweep.ps1` and the staleness check currently **exclude** `src/apprt/gtk/` as "Linux's, owes Windows nothing". That stays right for the Windows seat. The Linux seat's own intake is `parity-sweep.ps1 -Seat linux` (L13, T3342): Mac commits since the Linux watermark (`windows-parity-linux-intake.json`, baseline `9c0e90622`) that no `seat: linux`/`any` task cites, run every lane-L turn. | `go.md` lane L overrides, `docs/claude/testing.md` |

## Translation table (Mac → Windows → Linux)

Follow the pattern the Windows port set: the native equivalent, not an
emulation of the Mac mechanism.

| Concept | macOS | Windows | Linux |
|---|---|---|---|
| Frontend | Swift/SwiftUI | Zig win32 (`src/apprt/win32/`) | Zig GTK4 + libadwaita (`src/apprt/gtk/`) |
| IPC transport | AF_UNIX at `$TMPDIR/ghostty[-debug]-<uid>.sock` | owner-only-DACL named pipe | AF_UNIX, mode 0600, at the same derivation as the Mac (one function, so it cannot drift); `$XDG_RUNTIME_DIR` preferred when set |
| Agent autostart | LaunchAgent | HKCU Run | `systemd --user` unit; XDG autostart `.desktop` when systemd is off (WSL needs `[boot] systemd=true` in `/etc/wsl.conf`) |
| Secret store | Keychain | DPAPI | libsecret (Secret Service); file at mode 0600 under `$XDG_DATA_HOME` when no keyring daemon runs, which is the WSL default |
| Viewer panes (markdown/HTML/web/diff) | WKWebView | WebView2 | WebKitGTK (`webkitgtk-6.0`, the GTK4 build) |
| `+list` process column | `--tty` | `--pid` | `--tty` (Linux has real ttys) |
| Shell launch | `$SHELL -lic` | per-flavor (`pwsh -NoExit -Command`, `cmd /K`, `wsl --`) | `$SHELL -lic`, like the Mac |
| `ghoztty://` scheme | LaunchServices | registry `HKCU\Software\Classes` | `.desktop` with `MimeType=x-scheme-handler/ghoztty` + `xdg-mime default` |
| Pane/window screenshots | CGWindow | PrintWindow | in-app GTK snapshot (`pane_snapshot.zig`: widget paintable -> GSK render -> PNG); Wayland has no global capture, so it must come from our own render. Tests reach it through the debug-only `capture-pane` seam (`hl_screenshot`, T3359) |
| Focus on CLI open | `--focus` opts in | `--focus` opts in, `SWP_NOACTIVATE` | Wayland refuses focus stealing outright, so `--no-activate` is free and `--focus` needs `xdg-activation` |
| Chrome | native AppKit | custom, `docs/design/win32-design-system.md` | libadwaita widgets; parity is behavior and information, not pixels |
| Delivery | `.app` / dmg | MSI + auto-update | tarball → `.deb`/AppImage later (L14) |
| GUI test isolation | n/a | background desktop (`TestDesktop.ps1`) | a headless nested Wayland compositor (`weston --backend=headless` or `sway` headless) so a test never opens a window on the user's screen |

## WSL specifics

- **Memory: guard on the Windows side, never edit `.wslconfig`.** WSL2 has
  already taken 28 GB on this box. The user's `%USERPROFILE%\.wslconfig` is
  tuned for their other WSL work (`memory=48GB`, `vmIdleTimeout=-1`), so a
  low cap is not ours to set. Instead the L0 wrapper refuses to start a build
  when Windows free memory is under a floor, and caps zig's parallelism.
- **WSL is never started unasked** (standing rule). Every Linux script launches
  through one wrapper that refuses to run when the cap is missing, and nothing
  in the Windows floor or sweeps boots WSL.
- **Renderer.** Ghostty needs OpenGL 3.3+. WSLg's Mesa d3d12 driver provides it
  on the GPU; llvmpipe is the software fallback. Check with `glxinfo -B` in L1.
- **The two Ghoztty apps stay separate.** Inside WSL, Windows `PATH` is appended
  by default, so a bare `ghoztty` can resolve to the Windows `ghoztty.exe`
  through interop and drive the user's Windows terminal. The Linux build must be
  first on `PATH` in every script, and the CLI should be named by full path in
  tests (the Windows CreateProcess lesson, same shape).
- **Debug and release endpoints must differ** - the T243/T350 rule applies
  unchanged: a release-mode dev build would answer on the installed socket name.
- **Fonts.** Windows fonts are not visible to WSL by default; bundle or install
  the default font in the dev setup.

## Phases

| Phase | Goal | Tasks |
|---|---|---|
| 0 Bring-up | A Linux debug build launches in WSLg, the lib/none test lanes and the agent pass, and a script can do all of it from this box | L0-L4 |
| 1 CLI core | Every verb in the CLI at a glance (`+new-window`, `+split`, `+close`, `+list`, `+read`, `+send-keys`, `+rearrange`, `+set-state`, `+set-banner`, `+reload`) works against the GTK app over the Unix socket, with acceptance tests that drive the CLI only | L5-L7 |
| 2 Sessions | `ghoztty-agent` hosts the panes; restore/re-attach works; HELLO handshake contract unchanged | L8 |
| 3 Feature intake | One task per `docs/reference/*.md` topic (viewers, banners, pane sidebar, stacked panes, window modes, settings, ...), ported in the Mac's order | L9-L12 |
| 4 Ship | Intake sweep for the Linux seat; packaging; `ghoztty://` registration | L13-L14 |

Each step is a `seat: linux` task (filed 2026-11-21; `parity-tasks.ps1 next
-Seat linux` hands out the next one):

| Step | Task | Step | Task | Step | Task |
|---|---|---|---|---|---|
| L0 WSL cap + wrapper | T3329 | L5 shared IPC handlers | T3334 | L10 banners + sidebar | T3339 |
| L1 GTK builds, launches | T3330 | L6 GTK IPC server | T3335 | L11 reference intake | T3340 |
| L2 lib/none lanes | T3331 | L7 CLI verbs | T3336 | L12 secrets + relay | T3341 |
| L3 agent on Linux | T3332 | L8 sessions | T3337 | L13 Linux intake sweep | T3342 |
| L4 linux.md + headless harness | T3333 | L9 viewers (WebKitGTK) | T3338 | L14 packaging + scheme | T3343 |

Every `docs/reference/*.md` topic has a Linux owner (L11, 2026-11-23). The
cards L11 filed are numbered in the order the Mac shipped each feature (its
first commit on `main`), so `next` takes them in that order within the P2 band:

| Reference topic | Linux task(s) |
|---|---|
| cli-commands, cli-targeting | L7 T3336 (+ T3367-T3370) |
| session-persistence | L8 T3337 (+ T3397-T3400) |
| viewer-panes, viewer-image-and-diff, viewer-feedback | L9 T3338 (+ its L9a-L9k cards) |
| banners, pane-sidebar | L10 T3339 (+ T3557-T3561, T3606, T3607) |
| url-scheme | in-app `ghoztty://` links: T3415; OS registration and handing the URL to the app: L14 T3343 |
| remote-machines | L11a T3563 (chooser, Close vs Disconnect, pill); verbs T3597 (done: `+new-remote-window` TCP + relay, splits and `--from-focused` stay on the machine; + relay relaunch, new tab, per-host defaults T3668; +stash/+restore T3596 done, + relaunch and spatial ops T3667; handoff-quit T3595 done, the launch's Switch / Open Window / Cancel T3598 done), relay account store L12 T3341 (done: keyring, else a 0600 file), the account row's sign-in L12b T3575 |
| pane-rearrange | L11b T3564 (done: mode, headers, in-window drops; tab bar + tab dwell T3615 done; + cross-window T3616, ghost/preview/hover handle T3617, new window/pop-out T3618) |
| copy-reflow | L11c T3565 (done: every GTK copy path reaches the shared cleanup; + seat for a cross-app paste T3620, rectangle T3621) |
| pane-style | L11d T3566 (done: desk, elevated cards, focus glow, flat, `--color=random` gradient; + glass T3622 done, seed persistence and desk under sidebar/header T3623 done, flat gutter T3624) |
| stacked-panes | L11e T3567 (done: one stage the shared layout places, minimum + strips, focus brings forward, gutter drags, `+list minimized`; + glides T3625 done, gutter bar and double-click T3626 done, persistence/undo T3627, featured side pane T3628, live relabel/strip drag/columns T3629 done; + sidebar as a pane drop target T3756, seat drag T3757) |
| terminal-resize | L11f T3568 (done: divider drag, banner fold; + prompt-redraw hold and window-edge drag T3630 done; explicit bash command integration T3758) |
| settings | L11g T3569 (done: the window, All Settings; + curated pages T3631 done, lists T3632 done, font picker T3765 done (Windows T3766), config file/backups/undo T3633 done, file mode T3634, Sessions & Remote T3635, themes + preview T3636, color wells + folder picker T3759, search across pages T3760) |
| keyboard-shortcuts | L11h T3570 (done: Ctrl+Shift+/, menu, palette, live catalog, search, Run, cheat sheet; + Run on hover T3639, menu/palette check T3640) |
| background-windows | L11i T3571 (done: hidden panes stop building frames and catch up on show, held window title; + viewer polls/animations in a minimized window T3643) |
| memory | L11j T3572 (done: pane/tab/window/viewer teardown measured, nothing leaks; + hidden/idle panes give back their frames T3645, agent per-session growth T3646) |
| window-modes | L11k T3573 (done: the launch latch; + foundation T3648, switching T3649, parked layout T3650, shade fade T3651, closing T3652, CLI T3653, activity T3654, persistence T3655) |

## The Linux lane

The Linux seat is worked by its own go-loop **lane `l`**, in its own worktree
`D:\git\ghoztty-l` (user, 2026-11-21: "we could do that in its own worktree on
its own go loop"). It uses the lane machinery lane `b` already runs on
(`scripts\lib\LoopLane.ps1`): its own lock, watchdog (`GhozttyGoLoopWatchdog-l`),
window marker `[go-loop l]` and window `main-l`. `Get-LoopLaneSeat` maps lane
`l` to seat `linux`, so its `next` hands out only `seat: linux` and `any`
tasks, and the Windows lanes never see them. Like every lane but `a`, it never
publishes or delivers. The turn is go.md, word for word, with the lane `l`
overrides listed there.
