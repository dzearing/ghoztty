# Window modes: separate windows, or one window of workspaces

Read before touching `macos-window-mode`, `WorkspaceHost`,
`TerminalController+Workspace.swift`, or any code that goes from a
controller to its `NSWindow` or from a window back to its controller.

`macos-window-mode` (`separate` default | `single`; `Ghostty.Config.macosWindowMode`,
`WindowMode`). `separate` is every terminal window its own `NSWindow`, exactly
as before this option existed. `single` is **one** `NSWindow`; everything that
is a window in `separate` mode is a **workspace** in it, and the pane
sidebar's all-windows list switches between them. Read once at launch
(`WindowMode.current` latches it): a controller is built for one mode or the
other, so a change takes effect at the next launch, where the windows that
were open come back in the new mode. Settings → Panes & Windows → Windows.

## The rule: a parked workspace has no window

A workspace **is** a `TerminalController` — split tree, pane layout, stash,
`windowName`/target, titles, gradient (`deskVariant`), focused pane,
activity, sidebar state, session-layout entry. **Every workspace keeps its own
controller; only the `NSWindow` is shared.**

- The window belongs to the workspace **on show** (`WorkspaceHost.active`):
  `window.windowController` and `window.delegate` are that controller, and
  `window.contentView` is its content (`TerminalViewContainer`).
- Every other workspace is **parked** (`isParked`). Its `window` is **nil**
  (`TerminalController.window` answers nil while parked — and never loads a
  nib). Its content view is out of the window, kept whole by the controller
  (`parkedContainer`), laid out at the window's size with the titlebar's inset
  (`additionalSafeAreaInsets`), so its terminals keep the grid they will have
  on show. `heldWindow` is the raw `NSWindowController` window, for the
  hand-off only.
- So code that goes **controller → window** finds nil for a parked workspace
  and skips its window work (titles, sheets, raising, frames) — that is
  correct. Code that goes **window → controller** or enumerates windows must
  not use `NSApp.windows`, `NSApp.orderedWindows` or
  `view.window?.windowController`, which see only the workspace on show. Use:
  - `BaseTerminalController.everyController` (closed windows left out) /
    `everyControllerFrontToBack` (windows, then parked workspaces most
    recently shown first); `TerminalController.all` is built on it.
  - `BaseTerminalController.owner(of: pane)` / `owner(of: surface)`: the
    controller a pane is in, parked or not. Core actions from a parked
    terminal (a shell exiting closes its pane) go through it.
  - `controller.bringForward()`: what "go to this window" means — a sidebar
    click, `--focus`, `ghoztty://focus`, a notification click. In single mode
    it puts the workspace on show; otherwise `makeKeyAndOrderFront`.
  - `controller.workspaceHost`: non-nil only for a workspace (single mode,
    never the Quick Terminal).

## The hand-off (`WorkspaceHost.show`)

No view is rebuilt, no process touched, no second `NSWindow` created:

1. The parked workspace is laid out at the window's current size
   (`prepareParkedContent`).
2. The workspace on show **surrenders** the window (`surrenderWindow`): its
   focused pane and tab color are remembered, its content view comes out, its
   fullscreen handler is handed over (it belongs to the window), its `window`
   becomes nil. Its terminals are told they are hidden (`updateSeen`).
3. The other **adopts** it (`adoptWindow`): window controller, delegate,
   content view, first-responder observation, fullscreen handler, tab color,
   machine pill, zoom, title (landed at once, never held back),
   `representedURL`, appearance. Then it draws again, takes focus back where it
   was (never into a minimized strip), and its sidebar catches up.
4. The window's shade fades from the old workspace's gradient to the new one's
   (`deskEntrance`, `PaneDeskFade`, 0.35s) — the old desk drawn over the new
   and faded out. Nothing fades in the flat style, which has no desk.

Refused (a beep, `false`) while a sheet is up on the window: it is the
workspace on show's, and has to be answered there. A close that sheet itself
confirmed passes `force`.

**Size.** A window resize brings every parked workspace to the new size once it
settles (`WorkspaceHost.windowDidResize`, 0.3s), so each is ready when shown.
A parked terminal keeps the backing scale of the window it was last in
(`SurfaceView.backingSize`) — out of a window AppKit would use the main
screen's, and on a display of another scale the grid would change while
parked and change back when shown. A tree change in a parked workspace (a
`+split`, a close) lays its content out at once (`layoutParkedContent`): no
window will.

## Parked counts as hidden

A parked workspace is hidden in every sense
[background-windows.md](background-windows.md) and
[memory.md](memory.md#panes-that-are-not-drawing-give-back-their-frames)
mean: `updateSeen` tells each of its terminals it cannot be seen
(`setRendererVisible(false)`), so they build and draw no frames and give back
their render targets; the IO thread and the terminal state are untouched.
Viewer panes are out of the window, so WebKit hides the page, GIFs stop
(`ViewerImageView` on `window == nil`), and a working-tree diff stops polling
— and catches up and polls again when shown (`ViewerView.viewDidMoveToWindow`).
Its sidebar never redraws live (`PaneSidebarState.isLive` is false while
parked); it catches up when shown.

State never pauses: activity, bells, banners, the manifest. The window's
`AXWindowActivityState` is the most urgent of **all** its workspaces'
(`WorkspaceHost.refreshWindowActivity`) — a parked workspace waiting on a
question is the window waiting on one — and a parked `needs_input` still asks
for attention. The title suffix is the workspace on show's own
(`BaseTerminalController.activityState`). `+list`/AppleScript read a parked
workspace's title from `currentWindowTitle` (kept while it has no window).

## Opening, switching, closing

- **Everything that opens a window opens a workspace**: Cmd-N, the menus and
  palette, the sidebar's + buttons, `+new-window`, a pane dragged out to a new
  window, undo of a close, session restore, AppKit restoration. The first
  controller made while no workspace has the window loads it
  (`WorkspaceHost.startsParked`, decided before `super.init`, since the window
  can load during init); every other one starts parked.
- **Cmd-N is on show in the key's own turn**: a new workspace from a local
  window takes the parent pane's working directory as it is known here (its
  shell's OSC 7, or the core's inherited one) instead of asking the local
  agent on a background queue, is presented at once rather than a turn later
  (`TerminalController.newWindow`), and is laid out once, in the window, as
  it comes on show (`WorkspaceHost.show` lays out off screen only a workspace
  that was already parked). Measured in the debug build: key → drawn 57–88 ms
  before, 40–63 ms after; what is left is creating the terminal and building
  the workspace's view. A pane that never reported a directory still asks the
  agent. Test: `newWindowIsOnShowInTheKeysTurn`.
- **A new tab is a new workspace** (`TerminalController.newTab`): there are no
  native tabs (`tabbingMode = .disallowed`). `goto_tab` (previous/next/last/N)
  and `goto_window` walk the workspaces in the sidebar's order
  (`TerminalController.sidebarOrder`).
- **Focus policy is unchanged**: a manual open (Cmd-N, +) puts the new
  workspace on show; a programmatic one (`+new-window` without `--focus`)
  leaves it parked and the workspace on show keeps the window and the caret.
  `--focus` — or the idempotent `--target=<existing> --focus` — puts it on show.
- **Closing**: closing the workspace on show (Cmd-W, the red button, `+close`,
  the sidebar's ×, its last pane exiting) hands the window to the workspace
  shown before it; the last workspace's close closes the window. A parked
  workspace closes in place (`workspaceWillClose` → `didClose(window: nil)`:
  the same session close intents, manifest removal and held-window release as
  a window close). A close that needs confirming puts a parked workspace on
  show first, so the sheet has a window and the person sees what closes.
  Undo of a close brings the workspace back on show.
- If the window itself closes with workspaces left (not at quit), the next one
  loads a window of its own (`windowDidClose`).

## CLI and scripting

From the CLI nothing changes: each workspace is a window. `+list` lists each
(on show first, `focused`), `--target` names resolve to them (`TargetLookup`),
and `+close` / `+close --force`, `+split`, `+read`, `+send-keys`,
`+set-state`, `+set-banner`, `+stash` / `+restore` address a parked workspace
without putting it on show. A workspace's `+list`/AppleScript `id` is its
controller's, the same on show or parked (`ScriptWindow.stableID`).

## Persistence

- **Session layout manifest**: one entry per workspace, as per window. A
  parked workspace's `frame` is the window's. `Entry.frontmost` (additive)
  marks the window in front — the workspace on show, or in `separate` mode
  the main window (synced as main changes). Restore brings the frontmost entry
  back **last** (`SessionLayoutManifest.frontmostLast`), so it is in front
  again in `separate` mode and on show in `single` — which is what makes a
  manifest written in one mode restore in the other. In single mode tab-group
  siblings come back as workspaces of their own; a single-mode manifest read in
  `separate` mode is windows at one frame, the frontmost on top. The manifest
  blob the agent stores is opaque to it: the app↔agent wire contract is
  unchanged.
- **AppKit restoration** (session persistence off): the window's archive
  carries the workspace on show as `state` and every other restorable
  workspace under `workspaces` (`TerminalRestorableState.workspacesKey`,
  additive — an older build restores the one in `state`). Decoded in single
  mode they come back as workspaces; in `separate` mode, as windows. A
  separate-mode archive read in single mode is a workspace per window. The
  window is restorable while any workspace is
  (`WorkspaceHost.windowStateDidChange`).

## Tests

`SingleWindowModeTests` (real controllers in the test host, mode forced with
`WindowMode.overrideForTesting`): `aSwitchHandsTheOneWindowOver`,
`aSwitchFadesTheShade`, `nextAndPreviousTabWalkTheWorkspaces`,
`parkedTerminalsDoNotDraw`, `aWorkspaceParkedFromBirthStaysQuiet`,
`theCLIAddressesAParkedWorkspace`, `forceClosingAParkedWorkspace`,
`focusPolicy`, `closingTheWorkspaceOnShowShowsTheLastOne`,
`theWindowReportsEveryWorkspacesActivity`,
`appKitRestorationRoundTripsInBothModes`,
`aSeparateModeArchiveRestoresAsAWorkspace`,
`theManifestRemembersTheWorkspaceOnShow`. `WindowModeManifestTests`
(frontmost-last ordering, the field is additive). `ConfigTests.macosWindowMode*`.

To try it without touching the config file the release app also reads:
`zig-out/Ghoztty-Debug.app/Contents/MacOS/ghoztty --macos-window-mode=single`
(CLI args are config when the binary is run directly).
