# Ghoztty

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds
CLI-driven window management for AI agents and automation (`ghoztty +…` IPC
commands), viewer panes, stacked/glass pane layouts, and session persistence
via a long-lived `ghoztty-agent`.

Upstream's agent guide still applies for build/test/format commands and
directory layout: [AGENTS.md](AGENTS.md) (and `macos/AGENTS.md`). This file
adds the fork's hard rules and an index of topic docs.

## Hard rules

- **NEVER modify, replace, copy over, or touch `/Applications/Ghoztty.app` in
  any way.** It is the user's primary terminal. Test with the debug build at
  `zig-out/Ghoztty-Debug.app`, which uses its own socket
  (`ghostty-debug-<uid>.sock`), bundle id, and URL scheme (`ghoztty-debug://`)
  so it runs alongside the release app.
- **Fork identifiers are `com.dzearing.ghoztty.*`**, never `com.mitchellh.*`.
- **The app↔agent wire contract is a compatibility boundary** (see below).
- **`ghoztty://` is focus-only by design.** Any web page can fire a registered
  scheme, so a verb that spawns, types, or opens content would be remote code
  execution behind an `<a href>`. Wanting a second verb is a signal to stop and
  ask, not to add one. Details: [url-scheme.md](docs/reference/url-scheme.md).
- **No `ghoztty +…` command takes focus without `--focus`.** Programmatic
  surfaces open in the background; manual ones (Cmd-N, menus, palette) focus as
  always. Details: [cli-targeting.md](docs/reference/cli-targeting.md).
- **Machine tokens are a public API.** `idle`/`busy`/`needs_input`
  (`+set-state`, OSC 7777, `AXWindowActivityState`) never change; the UI shows
  human labels (`needs_input` → "question").

### Agent contract & upgrade compatibility

The `ghoztty-agent` outlives the app on purpose (per-user LaunchAgent), so **a
running agent is frequently a DIFFERENT build than the app talking to it.**

- Old agent + new app and new agent + old app MUST both keep working. A skew
  degrades to reduced function — never garbled output, a wedged socket, or a
  crash.
- Evolve additively: new messages/fields only; never change the meaning, type
  or framing of an existing one, never remove one a peer still uses. Readers
  ignore unknown fields and tolerate absent ones.
- Detect capability at runtime via the HELLO handshake, never at compile time;
  gate every new behavior on it and document each protocol version in the agent
  protocol source (`src/remote/protocol.zig`).
- A breaking change is allowed only as a conscious decision: bump the protocol
  version, never replay across an incompatible skew, and go through the
  mandatory agent-update process (lazy non-destructive upgrade first; otherwise
  an explicit "Upgrading will reset all windows. Continue?" confirmation).

Full text: [session-persistence.md → Agent contract](docs/reference/session-persistence.md#agent-contract--upgrade-compatibility).

## Build & Test

```bash
zig build -Doptimize=Debug
```

Produces `zig-out/Ghoztty-Debug.app`. Other build/test/format commands:
[AGENTS.md](AGENTS.md).

## Architecture

- **Zig core** (`src/`): terminal emulation, input handling, CLI commands, IPC client
- **Swift macOS app** (`macos/`): SwiftUI frontend, IPC server, split tree layout
- Split panes use a binary tree (`SplitTree`) with a ratio (0.0–1.0) per split node
- IPC uses JSON messages over a Unix domain socket at
  `$TMPDIR/ghostty[-debug]-<uid>.sock`, overridden per pane by
  `$GHOZTTY_IPC_SOCKET`
- `ghoztty-agent` owns session-persistence PTYs; the app dials it over a 0600
  unix socket (`~/.config/ghoztty/local-agent[-debug]/agent.sock`)

## Topic reference (read when working in that area)

Reference docs in `docs/reference/` describe how things behave **now** — rules,
invariants, code pointers, test names. `docs/design/` holds plans and history.
When you change behavior, update the matching reference doc (and the bundled
skill in `macos/Resources/Ghoztty/skills/ghoztty/` if a user-facing flag
changed).

| Doc | Read before… |
|---|---|
| [cli-targeting.md](docs/reference/cli-targeting.md) | changing how any `+command` picks its instance, window/pane, or focus: `--focus`/`IPCFocusPolicy`, name lookup (`TargetLookup`), pane ids, caller anchoring, `$GHOZTTY_IPC_SOCKET` |
| [cli-commands.md](docs/reference/cli-commands.md) | touching an IPC command handler or the CLI: `+new-window`, `+split` (name collisions, honest reply), `+close`, `+read`, `+list`, `+sessions`, `+send-keys` (bracketed-paste framing), `+set-state` + activity hooks, `+reload`, `+stash`/`+restore` |
| [banners.md](docs/reference/banners.md) | touching pane banners (`+set-banner`, OSC 7778): markdown subset, autolinking, the link-click table (`BannerLinkOpener`, shared with viewers), collapse/expand |
| [url-scheme.md](docs/reference/url-scheme.md) | touching `ghoztty://` handling (`GhozttyURLScheme`) or links that focus panes |
| [remote-machines.md](docs/reference/remote-machines.md) | touching remote windows, the close-vs-Disconnect prompt, relay sign-out/enrollment, or `RelayHostAgent` |
| [viewer-panes.md](docs/reference/viewer-panes.md) | touching viewer panes: `ViewerView`, `src/viewer/` JS, nav bar, find, links, viewer keyboard handling |
| [viewer-image-and-diff.md](docs/reference/viewer-image-and-diff.md) | touching image panes or `git-status:`/`git-diff:` panes |
| [viewer-feedback.md](docs/reference/viewer-feedback.md) | touching the feedback composer, quoting, or the `temp/feedback/` report format |
| [copy-reflow.md](docs/reference/copy-reflow.md) | touching copy/selection formatting or link detection across TUI-wrapped rows (`hard_wrap.zig`) |
| [terminal-resize.md](docs/reference/terminal-resize.md) | touching resize coalescing/pacing or the prompt-redraw hold |
| [pane-style.md](docs/reference/pane-style.md) | touching pane looks: elevated/flat, gradients and `--color`, glass tints, focus glow, unfocused dimming |
| [stacked-panes.md](docs/reference/stacked-panes.md) | touching pane layout (`PaneLayout`), stacking/strips, gutters and divider/grip drags, glides, focus handoff |
| [pane-sidebar.md](docs/reference/pane-sidebar.md) | touching the pane sidebar or stashing |
| [pane-rearrange.md](docs/reference/pane-rearrange.md) | touching pane drag-and-drop, rearrange mode, or moving panes between windows/tabs |
| [session-persistence.md](docs/reference/session-persistence.md) | touching the agent, restore/relaunch, scrollback replay, `claude-code-fullscreen`, or the app↔agent protocol |
| [memory.md](docs/reference/memory.md) | touching pane/window teardown, closures stored on window-owned state, renderer swap-chain targets or occlusion; where memory goes and how to measure it |
