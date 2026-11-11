# Background windows: what stops when no one is looking

Read before adding anything that animates, polls, or redraws on its own
(a Core Animation loop, a repeating timer, a title or status that changes
often), or before touching window visibility (`WindowInUse`,
`WindowCoverage`, `ghostty_surface_set_occlusion`).

## The rule

Work that only matters to the eye runs only where someone can see it.
State never pauses: activity (`idle`/`busy`/`needs_input`, priority
`needs_input` > `busy` > `idle`), `AXWindowActivityState`, notifications and
the dock badge are tracked for every window as always. A window that comes
forward shows its current state at once — one catch-up, not a replay.

| Work | Runs in | Elsewhere | Code |
|---|---|---|---|
| Busy border (the light circling a working pane) | the window in use | holds still at the top | `BusyBorderView.updateSpinning` |
| Sidebar busy sheen | the window in use | glint off the pill, drift and rim still | `PaneSidebarTileSheenLayer.View.animate` |
| Window title / tab label | windows that can be seen | held, landed when the window shows, at most every 5s meanwhile | `BaseTerminalController.applyTitleToWindow` |
| Terminal frames (cell rebuild, link scan, draw) | terminals that can be seen | skipped; one rebuild when shown | `renderer.Thread.renderCallback` |
| `git-status:` pane poll | windows that can be seen | skipped; one refresh when shown | `ViewerView.startWatchingDiff` |
| Animated image (GIF) | windows that can be seen | stops on its frame, goes on when shown | `ViewerImageView.advanceFrame` |

- **The window in use** (`WindowInUse.animates`): the key window, on screen.
  So every window holds still while another app is active.
- **Can be seen** (`WindowInUse.isOnScreen`): AppKit's occlusion state says
  visible (not minimized, hidden, or on another Space) **and** the window is
  not covered (`WindowCoverage`).
- Live web pages in viewer panes need nothing from us: WebKit throttles a
  page's timers and animation frames in an occluded window itself.

## Why AppKit's occlusion is not enough

`NSWindow.occlusionState` calls a window visible while any pixel of it
shows, and a window behind another of **exactly its frame** always shows —
its rounded corners and shadow peek out around the front window's. Terminal
windows that all fill the screen are the usual layout, so behind the front
one AppKit called every window visible, and nothing gated on it (the
renderer's hidden-surface path included) ever stopped.

`WindowCoverage` asks the window list instead (`CGWindowListCopyWindowInfo`,
~2ms a read): a window is covered when ordinary (layer 0), fully opaque
windows in front of it cover all of it but a 24pt square at each corner,
ignoring what lies off every screen. Our own non-opaque windows (background
opacity, blur) do not cover. Front-to-back order across apps changes without
telling us, so it re-reads on our windows' events (key, minimize,
occlusion, app activation, Space change — not moves or resizes, which arrive
every frame of a drag) and on a 1s timer: a window uncovered by a window
moving away catches up within a second. The geometry is pure and tested (`WindowInUseTests`).

A tab group's labels are in its selected window's tab bar, so a window's
title is "seen" when any window of its group is.

## Titles

Setting `NSWindow.title` is a WindowServer transaction plus a titlebar
layout pass (and `TerminalWindow.title`'s didSet walks the titlebar's view
tree). A program that spins a glyph in its title costs that ten times a
second per window. A hidden window's title is held (`pendingWindowTitle`) and
lands the moment it shows, or after `hiddenWindowTitleInterval` (5s) so
Accessibility readers and the Window menu are never far behind. A window's
first title always lands. Readers that bypass the screen get the held title
at once: `+list` and AppleScript read `BaseTerminalController.currentWindowTitle`.

## Terminal frames

A hidden surface skips `updateFrame` as well as the draw: building cells and
scanning the screen for links nobody sees was the bulk of a background
terminal's cost under steady output. It marks the frame stale
(`flags.frame_stale`) and rebuilds once when shown. The IO thread is
unaffected — the terminal's state, scrollback and activity are always
current. A terminal added to a hidden window starts hidden
(`BaseTerminalController.surfaceTreeDidChange` → `updateSeen`), so it never
allocates render targets it would not draw into (see
[memory.md](memory.md#hidden-windows-drop-their-render-targets)).

## Measured

Debug build, 16 background windows behind a full-screen window of another
app: 5 agent-like panes (busy state, a progress report so the border
circles, a spinner redrawn in the terminal 10×/s), 2 titles spinning 10×/s,
2 animated HTML viewers, 1 `git-status:` viewer, 6 idle shells. CPU over
15s, 100% = one core, two alternating rounds each:

| | ghoztty | WindowServer |
|---|---|---|
| before | 19.5–23.1% | 64–105% (mean 92%) |
| after | 4.3–5.1% | 85–91% (mean 88%) |

WindowServer swings with whatever else is on screen, so it is noisy; the
targeted A/B is clearer — a dozen covered windows each with a circling
border: WindowServer +7–8% of a core (A/B within one run), ghoztty ~0; a
dozen covered windows each retitling 10×/s: ghoztty +32–37%, WindowServer
+7–10%. Method: `sample`, per-thread CPU from `ps -M`, and cumulative CPU
time deltas from `ps -o time` (not `top`, which under-reads).

## Tests

`WindowInUseTests` (the border and sheen gate on the window in use;
coverage geometry; a hidden window's title lands as it shows while `+list`
has it at once), `PaneTeardownTests.aHiddenTerminalShowsWhatChangedWhileHiddenAsItComesBack`,
`PaneTeardownTests.occludedTerminalsGiveBackTheirRenderTargets` (fails
without the catch-up rebuild on show),
`ViewerDiffPaneTests.aHiddenWorkingTreeDiffCatchesUpWhenShown`.

The test host is never the active app and its windows open behind other
apps', so they are hidden by these rules. A test about something else that
needs its window drawing, animating or polling declares it in use with
`WindowInUse.setInUseForTesting(window, true)` — never by pulling the
window in front of whatever the person at the machine is doing.
