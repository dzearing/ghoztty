# The `ghoztty://` URL scheme

`ghoztty://focus/<target>` and why it is focus-only. Read before touching
`GhozttyURLScheme`, link handling in viewers/banners, or before adding any verb
(don't, without asking).


A **link** can raise a Ghoztty window or pane. This is the piece that makes a
generated document (a worktree dashboard, a status report) able to say "jump to
that terminal" — from a browser, from a doc rendered in a viewer pane, or from
a pane banner.

```
ghoztty://focus/<target>
```

One verb, one shape. `<target>` is percent-decoded and passed to
`IPCServer.lookup` — the same resolver `--target` uses, so there is one
naming system, not two: a registered window name, an auto `window-N`, a
registered pane name, or a pane id (`$GHOZTTY_PANE_ID`, case-insensitive).
A link has no caller pane, so a pane name is looked up across every window
(see Naming): once two windows each hold a pane of that name the link is
**ambiguous** and reports so (`Failure.ambiguousTarget`, "Can't focus …")
instead of raising one of them at random. A pane id never is.
Everything after the verb is ONE target, so a name containing `/` survives
encoded (`focus/feat%2Flogin`) or not (`focus/feat/login`). The path form is
canonical over `ghoztty://<target>` (nowhere to put a verb) and over
`ghoztty://focus?target=…` (a second escaping context for no gain). Parsing
(`GhozttyURLScheme.parse`) is strict: unknown verb, empty target, and bare
`ghoztty://<name>` all yield nothing rather than a lenient guess.

**Focus is the only capability, and that is the design, not a first
increment.** A registered URL scheme is reachable by any web page the user
visits — no prompt, no gesture beyond a click, no same-origin check, no way to
know who asked. Everything the IPC socket exposes is safe there only because a
0600 unix socket is reachable only by code already running as the user; none of
that holds for a link. A scheme that could spawn a shell (`--command`), type
into a pane (`+send-keys`), or open a viewer would be remote code execution
behind an `<a href>`. Raising an already-existing window is the one verb whose
worst case is a nuisance. The parser reads a verb rather than hardcoding one
shape so a future verb *could* be added — but wanting a second verb to make
something work is a signal to stop and ask, not to add one.

Consequences, all deliberate:

- **The debug build registers `ghoztty-debug://`**, the release builds
  `ghoztty://` (`CFBundleURLTypes` ← the `GHOZTTY_URL_SCHEME` build setting,
  per Xcode configuration) — the same split as the bundle id and the IPC
  socket. Otherwise LaunchServices picks between them nondeterministically and
  the user's links start landing in a debug build. Verified with
  `NSWorkspace.urlForApplication(toOpen:)`.
- **Both spellings parse in both builds.** Links clicked *inside* Ghoztty are
  short-circuited in process and never reach LaunchServices, so a document that
  hardcodes `ghoztty://` still focuses the right pane when a debug build is
  rendering it.
- **A link that resolves to nothing says so** (`GhozttyURLScheme.Failure`): a
  warning naming the target for `targetNotFound`, or naming the URL plus the
  one supported form for `unsupportedLink`. A click that appears to do nothing
  is indistinguishable from a broken app, and both failures are ordinary (the
  window was closed; the document predates this build). What failure never does
  is *act*: no window is created and no "closest" window is focused as a
  consolation. Presentation is **coalesced** behind `isPresentingFailure` so a
  burst — any page can fire a scheme, and `application(_:open:)` takes an
  array — is one dialog, not one per link. A URL that isn't ours at all is
  ignored silently; nobody clicked a Ghoztty link. The wording lives on
  `Failure` rather than in the presenter so it is testable.
- **App not running:** macOS launches the app for a registered scheme (we can't
  decline), and the registry is empty, so the focus resolves to nothing and
  reports that. The normal `initial-window` behavior still applies — that
  belongs to *launching Ghoztty*, exactly as `open -a Ghoztty` does, not to the
  focus verb, which creates nothing. Suppressing it would leave a windowless
  app that reads as broken in the one case where the link could never have
  worked.
- **Viewer panes** intercept `ghoztty://` at the top of `decidePolicyFor`,
  ahead of the live-page passthrough AND of the cross-origin external-link
  check (WebKit cannot load the scheme, so an allowed navigation is a dead
  click, and a focus link is not "content on another site" to hand to a
  browser). A `target="_blank"` focus link resolves
  to `PopupDestination.ghozttyCommand` instead of falling through to
  "non-web scheme ⇒ open a Ghoztty window", which is how it used to create a
  viewer window pointed at the command string.
- **Rendered markdown** needs `viewer.js` to widen DOMPurify's
  `ALLOWED_URI_REGEXP` by exactly these two schemes. markdown-it keeps a
  `ghoztty://` href, and the sanitizer then stripped it — the link rendered as
  dead text. Keep the regex in sync when the vendored DOMPurify is bumped.
- **Banner links** ignore the Cmd / Cmd-Shift modifier scheme
  (`BannerLinkOpener.Action.runGhozttyCommand`): the link names a window, not
  content, so there is nothing to open in a side pane or a new window. The
  right-click menu is **Focus in Ghoztty** + **Copy Link**. A focus link
  right-clicked in a **viewer page** gets that same two-item menu, since the
  viewer builds its menu from the same `BannerLinkOpener`.

Entry points: `application(_:open:)` (`AppDelegate.swift`) for LaunchServices,
`ViewerView` for viewer link clicks, popups, and the viewer link menu,
`BannerLinkOpener` for banner clicks. All of them funnel into
`GhozttyURLScheme.handle` → `IPCServer.focusTarget`. Tests:
`GhozttyURLSchemeTests`, plus the `ghoztty`-scheme cases in
`BannerLinkOpenerTests` and `ViewerPopupTests`.
