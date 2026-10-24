# Remote viewer tunnel (T1297)

Design for "a viewer opened on a remote machine renders locally as if it were
yours" (user request, 2026-09-03). This doc is the decision record. The
implementation is split into the tasks listed at the end. It applies to both
platforms: every row has a Windows task and a Mac task.

## Where things stand today (surveyed 2026-10-24)

- A remote pane's shell DOES get `GHOZTTY_PANE_ID` and `GHOZTTY_IPC_SOCKET`.
  The apprt bakes them into `config.env`, and `config.env` is forwarded verbatim
  in `OPEN.env` (`src/Surface.zig:1092-1174`; win32 bake at
  `src/apprt/win32/Surface.zig:957`; Mac at `SurfaceView_AppKit.swift:467`).
- **That socket names a LOCAL endpoint.** It is a `\\.\pipe\ghoztty-<USER>` pipe
  name or a `$TMPDIR/ghostty-<uid>.sock` path. On the remote box it resolves to
  one of two places:
  - **nothing**, so the CLI reports "No running Ghoztty instance found". This is
    the usual case.
  - **the remote box's OWN Ghoztty**, when the username and build flavor happen
    to match. A `+split --view` then opens on the other machine's desktop.
  - It never reaches the app the user is looking at. `docs/claude/cli.md`'s line
    "a remote pane's IPC still belongs to the local app" holds only for the
    same-machine local agent.
- **There is no remote→local request path.**
  - The agent pushes only data, meta, sessions and metrics.
  - `rpc` (0x30) and `tunnel` (0x40) are reserved opcodes and capability strings
    with no handler and no caller.
- **Viewers read their content from local disk in the app process.**
  - Windows: `ViewerPane.zig` reads the file with `readFileAlloc`. Mac:
    `ViewerView.swift`.
  - Rendering is JS in the bundled template; the native side only supplies text.
  - Diffs run `git` locally in the origin directory.
  - Relative assets and `.html` siblings are served from the file's directory by
    the WebView2 virtual host or the WKWebView scheme handler.
- **Nothing in a viewer says which machine it is about.** The address bar shows a
  bare path or URL. The window's connection pill shows only link state.

## Decision 1: tunnel content, not pixels

The remote side ships **content** (file bytes, git output, HTTP responses). The
**local** viewer renders it with the same bundled engine it already uses.

Why, for every viewer kind:

- **Markdown, code, diff:** these are text. Local rendering stays crisp at any
  DPI, and selection, find, quoting and feedback capture keep working unchanged.
  Bandwidth is the size of the file, not a video stream.
- **HTML pages and websites:** these are rendered locally too. Their network
  traffic is tunnelled (decision 3), so a page sees the remote machine's network
  while it is still a real, interactive local page.
- **Pixels: rejected.** A frame pipeline costs latency and bandwidth, loses text
  selection and search, and is not needed for any viewer kind:
  - Its one advantage, sidestepping the content-trust question, is answered by
    decision 4 instead.
  - "Genuinely interactive" pages stay interactive under content tunnelling,
    because they run locally.

## Decision 2: the remote pane's IPC is forwarded to the app the user is looking at

This fixes the general problem, not only viewers. Every `ghoztty +…` verb run
inside a remote pane should reach the local app, as `cli.md` already promises.

- **A per-session proxy endpoint on the remote machine.** For each session it
  hosts, the agent serves an IPC endpoint there:
  - Windows: a named pipe with an owner-only DACL, the same pattern as the
    agent's own pipe.
  - Mac and Unix: an AF_UNIX socket with mode 0600.
  - The agent writes that endpoint's address into the child's
    `GHOZTTY_IPC_SOCKET`. This **replaces** the baked local value, which is
    meaningless over there and is how a request misroutes to the remote box's
    own Ghoztty today.
- **Wire.** The proxy wraps each request in a new capability-gated frame pair,
  `app_request` (A→C) and `app_response` (C→A), tagged with the session id. It
  forwards the pair over the existing connection, mux and relay included.
  - The local app runs the request through its ordinary IPC dispatcher.
  - The caller pane is seeded to the local pane that is bound to that session.
- **Compatibility** follows the HELLO handshake:
  - The capability is `app_ipc`.
  - Against an older app, the agent hosts no proxy and leaves the env as it is
    today.
  - Against an older agent, the app keeps baking the local value as today.
  - Neither side can wedge the other: an unanswered request times out at the
    proxy with a clear error, the same as the CLI's existing timeout policy.
- **Remote verbs create remote things.** A forwarded `+split` or `+new-window`
  without `--view` opens a pane **on the same remote machine**, using that
  machine's per-host default shell. A remote process can never spawn a local
  shell.

## Decision 3: where a tunnelled page's network requests come from

**Assumed default: every request a tunnelled viewer makes goes out from the
remote machine.** That is what the user described ("network requests from
within the remote web window … sent to remote"). It is also the only rule that
makes the main use case work: previewing a dev server on `localhost:3000` *of
that box*.

- Mechanics:
  - The viewer's fetches are intercepted, by WebView2 `WebResourceRequested` on
    Windows and a `WKURLSchemeHandler` plus a proxy on Mac.
  - They are forwarded over the reserved `tunnel` opcode as HTTP requests the
    agent makes on the remote machine.
- The pane states it (decision 5).
- This is filed as a user decision because the alternative would look and
  behave differently:
  - The alternative is "only loopback and private-network addresses go via the
    remote machine; public URLs load from here".
  - The work proceeds on the default meanwhile.

## Decision 4: the trust boundary

**A remote machine is trusted to show you things, not to reach into your
machine.**

- **Forwarded verbs are scoped to the remote window's own panes.**
  - `+send-keys`, `+read`, `+close`, `+set-banner` and `+set-state` from a remote
    session may target only panes whose sessions live on **that** machine.
  - `+list` returns only those panes.
  - A remote box can never type into, or read, a local shell. This is enforced
    in the app's dispatcher on the request's origin, not by the CLI.
- **Content reads are scoped to roots the app granted.**
  - Opening a viewer grants that file's directory, for relative images and
    linked `.md` files.
  - The agent refuses a fetch outside the granted roots. It also refuses one
    above a size cap: the same cap the local viewer applies.
- **A tunnelled page cannot touch local disk.**
  - Its virtual host serves only agent-fetched bytes.
  - It is a separate host from the local `ghoztty-page` origin, so storage and
    cookies do not mix with local pages.
- **The `ghoztty://` scheme is unchanged.** It stays `focus`-only, for the reason
  its header gives. Its links resolve against the local app, which is correct:
  a remote page can ask to focus a pane, the same as any document can.

## Decision 5: the pane says where it came from

A tunnelled viewer shows an **origin chip** in its navigation chrome, before the
address: the machine's display name (`Hello.hostname`, or the per-host label).

- The tab and pane title carry the same suffix, for example
  `README.md — on winbox`.
- A viewer that looks local but is not is the failure the user named, so the
  chip is not optional and cannot be hidden by the page.

## Navigation, live reload, persistence

- **Navigation.** In-page links to `.md` files, back/forward and reload work as
  they do locally, against the remote root.
- **Live reload.** The agent watches the file and pushes `viewer_changed`. The
  viewer re-fetches and keeps its scroll position.
- **Feedback and quoting.**
  - Both run locally against rendered text, so they work.
  - A feedback report is written **on the remote machine**, through the proxy,
    because that is where the agent that has to read it runs.
- **Persistence.** A tunnelled viewer persists as `{machine key, remote
  location}`, never as a bare local path.
  - On restore it re-fetches through the machine pool.
  - If that machine is offline, it shows "This page lives on <machine> —
    reconnect" instead of a broken local path.

## Tasks

The split of T1297 is below. Shared Zig work (agent and protocol) sits with the
Windows task that needs it first. Every Mac task is `seat: mac`.

| Area | Windows / shared | Mac |
|---|---|---|
| IPC proxy + `app_ipc` frames + env rewrite + scope policy | T2217 | T2218 |
| Remote file content: fetch, granted roots, live reload, relative assets, remote git diff | T2219 | T2220 |
| HTTP tunnel for pages and websites (decision 3) | T2221 | T2222 |
| Origin chip, title suffix, persistence/restore of tunnelled viewers | T2223 | T2224 |
| End-to-end acceptance over a loopback "remote" agent | T2225 | (docs in T2218) |

Decision 3 is filed for the user as D103 (linked to T2221).
