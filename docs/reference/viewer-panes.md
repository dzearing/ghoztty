# Viewer panes

Panes that render content instead of a terminal. Read before touching
`ViewerView`, the viewer web assets (`src/viewer/`), viewer keyboard handling,
links, find, or the nav bar. Image and diff panes:
[viewer-image-and-diff.md](viewer-image-and-diff.md); feedback capture:
[viewer-feedback.md](viewer-feedback.md); link-click table:
[banners.md](banners.md). Design history: `docs/design/viewer-panes.md`.

A pane (or a whole window) can render **content** instead of a terminal: a
markdown file, an HTML file (as a live page), a plain text/code file, an
**image**, a website, or a **git diff**. Viewers live in the normal split tree
— they resize, focus, zoom, close, and persist like any pane. View-only, no
editing.

```bash
ghoztty +new-window --view=README.md                 # viewer window
ghoztty +split --target=dev --name=doc --view=docs/design.md
ghoztty +split --target=dev --name=mock --view=mock/index.html   # a live page
ghoztty +split --target=dev --name=shot --view=temp/screenshot.png  # an image
ghoztty +split --pane=doc --direction=down --view=https://example.com
ghoztty +split --target=dev --name=diff --view=git-status:   # a git diff
ghoztty +close --target=doc
```

- **Markdown** (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mdwn`): GitHub-style
  rendering via bundled markdown-it + highlight.js (offline, zero network) —
  headings, GFM tables, nested/task lists, fenced code with syntax
  highlighting, blockquotes, images (relative paths resolve against the
  file's directory), links. Light/dark follows the window appearance. Body
  text is set in the **system font** (SF Pro via `-apple-system`) and code in
  SF Mono, so a viewer reads as macOS content rather than a web page.
- **Table of contents** (markdown only, and only with two or more headings) —
  one of the two contents of the pane's shared **side panel** (the other is a
  diff's file tree; see Git diff panes). Everything in this bullet is the
  *panel*, and therefore true of both: only the rows differ.
  A native card listing the document's headings, nested by level, with the
  section you are reading highlighted as you scroll. The card reads as a
  macOS sidebar: the selected row is a rounded pill in the system's own
  selection colors — accent-filled with white text while the window is key,
  the neutral unemphasized gray otherwise — and hover is a separate faint
  wash. **Clicking a row pins the selection to it**: the smooth scroll on the
  way there fires a scroll event per frame, and the highlight must not walk
  off the row you asked for. Your next scroll gesture hands the selection
  back to the scroll spy. A pinned "CONTENTS" header sits on Liquid Glass
  (`glassBackdrop()`, macOS 26; an `NSVisualEffectView` before that) with the
  rows scrolling *under* it, and the scroller's track stops below it —
  both from one `safeAreaInset`, not a ZStack.
  In a **wide pane** the card sits in a left gutter and the document column
  reflows beside it; **drag the card's right edge** to resize it (the gutter
  and the document's text column follow in the same layout pass). The width
  is a preference in defaults, shared by every viewer pane.
  In a **narrow pane** (< 720pt) the gutter would crowd the text, so the card
  becomes an overlay: the navigation bar (always open — see Navigation
  chrome) gains a contents button as its first item, which slides the card in
  and out. The
  switch follows the *pane* width live, so dragging a split divider reflows
  it. The card is the same glass card as the pane banner overlay (shared
  `GlassCardBackground`), opaque so document text never shows through it.
  Panel open/closed state is ephemeral — it does not survive a session
  restore, since restoring an overlay would hide the content it covers.
- **Margins are one number.** `GlassCard.outerMargin` (12pt) is the gap every
  glass card leaves around itself, on all four sides, and the document leaves
  the same 12px on all four of its own — so a TOC card and a banner in the
  pane next door line up at their corners, and the text starts exactly one
  margin right of the card. Per-component fudges are what break that; there
  are none. Enforced by `documentAlignsToTheCard` in `ViewerTOCTests`.
- **HTML files** (`.html`, `.htm`): loaded into the web view as a **live
  page**, never as highlighted source. Its own CSS, JS, images, and fonts run,
  so a scaffolded mock or prototype is viewable straight from disk —
  `--view=mock/index.html` instead of standing up a `python3 -m http.server`
  first. The web view is granted read access to the file's **own directory**
  (recursively), which is what makes relative assets resolve; a page reaching
  UP out of its folder (`../shared/app.css`) is the deliberate cost of keeping
  that grant narrow — put shared assets under the page's directory, or serve
  the project over http. Rendering is unconditional: there is no source-view
  toggle. Because the page is the document, an HTML pane is navigable like a
  website — its links follow **in the pane** for anything inside that same
  grant, exactly as they would if the folder were hosted (Links, below, is the
  one exception) — and Back/Forward cross into and out of it. A file
  that cannot be opened shows the usual in-page error card.
- **Images** (`.png`, `.jpg`/`.jpeg`, `.gif`, `.webp`, `.heic`/`.heif`,
  `.avif`, `.tiff`, `.bmp`, `.ico`/`.icns`, `.svg`, plus a few spellings of
  the same): see Image panes.
- **Text/code files** (anything else): syntax-highlighted by extension.
- **Websites** (`http://`/`https://`): the pane navigates there directly.
- **Git diffs** (`git-status:` / `git-diff:<revspec>`): see Git diff panes.
- **Links.** Every viewer kind now hands a link that leads *out* of what the
  pane is showing to the same place a banner link goes (see Banners → Link
  clicks: plain click to the system, Cmd to a side pane, Cmd-Shift to a surface
  of its own), and **right-clicking any link gives the same menu** —
  `BannerLinkOpener`, adopted whole, not a viewer copy of it.
  - In **markdown/code** viewers (unchanged): http(s) opens the default browser;
    a relative `.md` or `.html` link opens another viewer split (both are things
    a viewer renders); other local files open in their default app.
  - In **live-page** viewers (a website, a local HTML file) a link is followed
    in the pane unless it is **cross-origin**, in which case a plain click
    leaves for the browser. This is what makes an authenticated site work: the
    `WKWebView`'s cookie store is Ghoztty's own, so a hop out to `github.com`
    renders logged-out here.
  - **"Origin" here is deliberately not the web platform's.** That one decides
    what a *script* may read; this one decides where a *person* wants a page to
    open (`ViewerView.isExternalLivePageLink`):
    **http(s)** is same-origin on the same **host** + the same **port as
    written** — the scheme is excluded so an `http`→`https` upgrade stays in the
    pane, and the port is included because `localhost:3000` → `localhost:5173`
    is a different dev server. A subdomain is a different host, so external.
    **`file://`** is same-origin inside the page's own directory, recursively —
    exactly the read grant the HTML bullet describes, so a mock clicks through
    its own pages and a link reaching UP out of the folder (which this pane
    could never load) stops being a dead click. Existence is not checked: a
    broken sibling link is the page's own 404, not Finder's problem.
    **Across the two** (a local mock linking to a website, a dev server linking
    to a `file://` path) there is no shared origin, so: external.
    **Every other scheme** — `javascript:`, `data:`, `blob:`, `about:`,
    `mailto:` — is untouched and followed in the pane. `javascript:` is ordinary
    page machinery, and handing an arbitrary scheme to `NSWorkspace` would
    resolve it to whatever handler is registered.
  - Only a **user's click on a main-frame link** (`.linkActivated`) is ever
    routed. A page's own redirects, form posts, script navigations, iframe
    loads, and subresource fetches are the page's business and pass through.
  - **The right-click menu** is Ghoztty's, on every page including ones we do
    not control. `src/viewer/links.js` is a `WKUserScript` — for the same reason
    `selection.js` is one: `viewer.js` is a `<script src>` in `viewer.html` and
    only ever runs on the bundled template, which would have left a website's
    links with WebKit's menu and the template's with ours. The script does
    nothing but decide whether the click landed on a link Ghoztty has actions
    for, `preventDefault()` if so, and report the href; the menu itself is
    native and pops up at the **pointer** (the click's page coordinates are CSS
    pixels inside a view that may be zoomed and pinch-magnified). It runs in
    **all frames**, unlike `selection.js`, precisely because it needs no page
    coordinates. It **declines** — leaving WebKit's own menu exactly as it is
    today — for a same-document `#fragment`, for a click inside the user's
    current selection (Copy / Look Up must survive), for `mailto:`/`javascript:`
    and other schemes with no Ghoztty action, and whenever the native bridge is
    missing. A relative template link (`ghoztty-viewer://…`) is resolved back to
    the file it names, so the menu offers file actions; a template link to a
    missing file gets no menu, matching a left-click on it doing nothing.
- **Links that open a new surface** in a website viewer — `target="_blank"` or
  `window.open()` — go to the **system default browser**, not a new Ghoztty
  window, for the same cookie-store reason banner URLs do. Same-pane
  navigation is untouched: a website viewer follows ordinary links in place.
  **Cmd-click** keeps the popup in Ghoztty as its own viewer window (honoring
  the size the opener asked for), and so does a popup the browser can't be
  handed — a bare `window.open()` with no URL, or a non-web scheme. The
  tradeoff: a popup that lands in the browser can't `window.close()` itself
  back to the Ghoztty page that opened it, so an OAuth flow finishes in the
  browser. That flow wasn't authenticating in Ghoztty anyway.
  **Cmd here means a new window, not a side pane** — deliberately out of step
  with the Link clicks table above, and left that way. `window.open()` is a
  request for a *window*; the code honors the `width=`/`height=` the opener
  asked for, and a sign-in popup crammed into a split is not what the page or
  the user meant. Cmd on an ordinary link (which asks for no such thing) still
  means a side pane.
- **Live reload**: file viewers watch the file (including atomic saves) and
  re-render preserving scroll position — an HTML pane re-fetches the page from
  disk, and WebKit restores the scroll offset across it, so a save does not
  throw you back to the top; an image pane re-decodes, keeping the zoom and
  scroll position when the pixel dimensions are unchanged and re-fitting when
  they are not (the old magnification describes a picture that no longer
  exists). Only the viewed file is watched: editing a
  sibling `style.css` does not trigger a reload, and a saved HTML file may
  still serve that stylesheet from WebKit's memory cache. `+reload`/Cmd+R
  bypasses the cache (`reloadFromOrigin`) and is the way to pick up a changed
  subresource.
- **Find in page** (**Cmd+F**): a browser find bar, the same one in every
  viewer mode — markdown, code, a local HTML page, a website, and a diff.
  Typing highlights every match as you go (yellow, with the current one
  orange), the bar shows a live `3/17`, and Enter / Shift-Enter — or the
  bar's own chevrons, or **Cmd+G** / **Cmd+Shift+G** — step through them,
  wrapping at each end. Escape closes the bar and clears the highlights; the
  QUERY survives, so Cmd-G resumes the search and Cmd-F comes back to it
  pre-selected. Matching is case-insensitive substring, and a match may not
  straddle a block boundary (no browser matches "foo bar" across two
  paragraphs).
  - **A floating glass card at the pane's top-trailing corner**, not a strip
    under the nav bar and not part of the nav bar. The nav bar reserves its
    space and a markdown/code pane hides it until you reach for it, so a find
    strip would mean Cmd-F both pins the bar open AND adds a row beneath it —
    reflowing a reading surface by ~80pt and scrolling the very text you are
    searching. The card costs no layout and appears identically in every mode.
    It hangs off the web view's top edge, so it moves down with the content
    when the nav bar slides in, and it squeezes with a narrowing pane.
    Matches are scrolled to the MIDDLE of the pane, which is what keeps the
    card from ever covering the match it just found.
  - **The search is ours, in JavaScript** (`src/viewer/find.js`), because
    WKWebView's own `find(_:configuration:)` reports only `matchFound` — no
    count, no ordinal — so `3/17` is unreachable through it. Like
    `selection.js` and `links.js` it is a **`WKUserScript`**, not something in
    `viewer.js`, or it would never reach a website. It paints with the **CSS
    Custom Highlight API**, so it never mutates the page (a find on your own
    dev server cannot corrupt its rendering, and our painting cannot
    re-trigger the observer that keeps the count live). On WebKit older than
    Safari 17.2 the API is missing and the current match is shown as an
    ordinary selection instead — count and stepping still work, only the
    all-matches paint degrades.
  - **The count is live**: the page re-scans when it changes underneath an
    open search, which is what makes find work on a diff still appending rows
    a chunk per frame, or a file viewer that just live-reloaded.
  - **An image pane DECLINES Cmd+F** rather than opening a bar over it.
    There is no text, so the only thing a bar there could ever say is
    "no results" — which reads as a broken search rather than an
    inapplicable one. Declining lets the chord fall through to its global
    binding; Cmd+G is declined the same way.
  - **It is honest about what it is NOT searching**, on a second line under
    the field: text in the tree but not laid out is excluded (counting a
    match nobody can be scrolled to is a promise you can't keep); a page with
    a visible frame says `frames not searched` (the search is main-frame
    only, since one count cannot span two documents); a diff pane says which
    file (see Git diff panes); and past 5 000 matches the count reads
    `12/5000+` rather than a precise-looking number nobody counted.
- **Navigation chrome**: **every mode** gets the same bar — back / forward /
  reload / **home** and an **editable address field** — and it is **pinned
  open in every mode**, from the pane's first layout. There is nothing
  mode-dependent left about it.
  (It used to hover-peek in markdown/code panes; a control you go hunting
  for with the mouse before every use is not a control — don't bring it back.)
  The bar **reserves** its space rather than floating over the content (the
  content view is inset below it, never covered), and because the reservation
  happens in `init`, the content is laid out below the bar from the **first
  frame** in every mode — it paints once, at its final size. Typing an
  `http(s)` address (or a bare `example.com`, completed omnibox-style)
  navigates the pane to the web; typing an absolute or `~` path points it back
  at a file. Back and
  forward reflect real history (disabled when there is none) and work across
  the file↔web boundary — going Back from a website re-renders the file.
  **Home** returns to the location the pane was originally opened with, which
  is remembered separately from where the user has navigated to (and both
  survive a session restore).
  Beside Home, a **folder button** reveals the file the pane is showing in
  Finder — its folder opens with the file **selected** — and is present only
  while the pane IS showing a local file (markdown, code, an HTML page, an
  image). A website or a diff has no single file to reveal, so it gets no
  button rather than one that cannot do anything. It follows the pane's
  *current* location (`ViewerView.fileURL`, derived from the live mode), so it
  comes and goes as the address bar, links, and Back/Forward move the pane. It
  is the same action, symbol, and wording as **Reveal in Finder** on a file
  link's right-click menu, through the same `BannerLinkOpener.revealInFinder`
  — including its answer for a file deleted under the pane: the nearest
  folder that still exists opens instead of a dead click. Clicking into the address field selects the whole
  address; clicking again inside it just moves the caret.
- **Keyboard** (pane-scoped: live only while keyboard focus is inside a
  viewer pane — its page, its nav bar, its find bar, or its feedback composer
  — in any viewer mode):
  - **Cmd+R** reloads the pane in place, exactly like `+reload` (web
    re-fetches from origin, files re-render with scroll preserved, images
    re-decode keeping their zoom).
  - **Cmd+L** puts the caret in the address field with the whole address
    selected — the keyboard version of clicking into it, and every browser's
    chord for it. (It used to be Cmd+D, which is split right: a window holding
    nothing but a viewer then had no keyboard way to split.)
  - **Cmd+F** opens the find bar and puts the caret in it (see Find in page).
    **Cmd+G** / **Cmd+Shift+G** step to the next / previous match, re-opening
    the bar if it was closed. With no query yet there is nothing to step, so
    they are declined rather than swallowed — as is every one of the three in
    an image pane, which has no text to search.
  - **Cmd+plus / Cmd+minus / Cmd+0** zoom. In a page they are page zoom; in an
    **image pane** they drive the image's own zoom, where **Cmd+0 is 100%**
    (Preview's "Actual Size"), not best-fit — fit is one double-click away.
  - The standard editing chords (Cmd+C/V/X/A) reach whichever field inside the
    pane holds focus — the address bar, a diff panel's filter, or the find
    field — which they otherwise would not, because Cmd+C/V are terminal
    keybindings.
  - **Escape and Return belong to whichever field has the caret**, in that
    order of precedence (`ViewerView.fieldKeyAction`, which is pure so the
    ordering is testable): Escape reverts a half-typed **address**, else
    clears a **diff filter**, else closes **find** — including from the page,
    which is where the highlights are. Return steps a match only from the find
    field; in the filter it opens the top file and in the address bar it
    navigates, each via its own field.
  - **A plain key the page ignores does not beep** (`ViewerView.keyDown`).
    WKWebView offers every keyDown to the page and re-sends one the page left
    alone (Return on a page body, a letter, an arrow with nothing to scroll)
    up the responder chain, where nothing handles a plain key — every Ghoztty
    key handler above a pane is an event monitor that already ran — so it
    reached the controller's `noResponder(for:)`, i.e. `NSBeep()`. The pane now
    ends that walk for keys its content handed back. The page still gets every
    key first. **Command chords** still climb (they already went through
    `performKeyEquivalent` and `ViewerKeyFallback`; an unbound one beeps as in
    any Mac app), and so do **Tab / Shift-Tab**, which the window's key-view
    loop needs to move the caret out of a page. Text fields in the pane are
    untouched (the policy only applies while the content view has focus).
    Tests: `ViewerUnhandledKeyBeepTests`.
  - These **override their global binding only while the viewer holds focus**
    (Cmd+R = "Set Pane Banner…"). Focus a terminal pane and they do their
    global thing again; Cmd+D / Cmd+Shift+D (split), Cmd+Shift+R ("Change
    Window Title"), and Ctrl+Cmd+F (Toggle Full Screen) are never affected.
  - **The command palette (Cmd+Shift+P) opens over a viewer too**, a window
    of nothing but viewers included. It anchors on the pane it was opened
    from (`commandPaletteAnchor`, taken at open, either kind) — it used to be
    mounted only over a terminal, so in a viewer-only window the chord toggled
    a flag nothing drew. Over a viewer, config commands follow the same rule a
    key from it does (`ViewerKeyFallback.paletteRoute`): a menu item first,
    else the core (`ghostty_app_binding_action`, an action named by string,
    classified by `ghostty_binding_action_requires`); terminal-only commands
    are not offered. The Viewer: Open… commands open beside the viewer.
  - **Every other chord falls back to Ghoztty's keybindings**
    (`ViewerKeyFallback`): a chord neither the pane's own handling above nor
    anything inside the pane claims is dispatched as a focused terminal would
    dispatch it — Cmd+Shift+. (rearrange), Cmd+1…9, Cmd+Shift+[ / ], and any
    custom binding. It used to die, because config keybindings are dispatched
    by the focused *terminal* (`SurfaceView.performKeyEquivalent`), so from a
    viewer only the chords that happened to also be a menu key equivalent
    worked (and rearrange's is not one: its trigger is the physical `period`
    key, which a menu key equivalent cannot express).
    - **The pane keeps first claim.** The fallback runs at the end of
      `ViewerView.performKeyEquivalent`, after the chords above and after
      `super` — so a **web page** gets the chord first (WebKit takes every
      Command chord to offer it to the page and re-sends only the ones the page
      leaves alone; a site's own Cmd-K stays the site's), and so do the
      feedback composer and the text fields.
    - **Typing stays typing.** While a text field has the caret (address bar,
      diff filter, find field, composer), only Command chords are forwarded,
      and never the text system's own: Cmd-arrows, Cmd-Home/End/PageUp/Down,
      Cmd-Backspace/Delete. Cmd-Z/Shift-Z go through the Undo/Redo menu items
      to the field's own undo stack, as before.
    - **Terminal-only bindings are never forwarded.** The core classifies
      every action, exhaustively (`Binding.Action.requires`): `app`, `window`
      (the surface only names the window — tabs, fullscreen, rearrange,
      palette), `pane` (acts on the focused pane — split, close, zoom, hero,
      goto_split), or `terminal` (`text:`/`csi:`/`esc:`, copy/paste, font
      size, scrolling, search, key tables). A `terminal` action would have to
      be performed through some other terminal in the window — typing into a
      shell the user is not looking at — so it is not. (`global:`/`all:`
      bindings act on every surface wherever focus is, and are forwarded.)
    - **How it is dispatched**, mirroring a terminal's own order: the
      binding's **menu item** first (the menu flashes, and the menu's handlers
      are the ones that already know a viewer can be the focused pane), found
      by ACTION rather than key equivalent, so rearrange's key-equivalent-less
      item is still found; else through libghostty with **no key sent to any
      terminal** (`ghostty_app_key_binding_perform`): app actions directly,
      window actions through a terminal in the same window. A `pane` action
      with no menu item is not forwarded — a terminal standing in would act on
      ITS pane, not the viewer. A window of nothing but viewers has no terminal
      to name it, so from there only app actions and menu-backed bindings reach
      Ghoztty. A `performable:` binding that could not perform acts as if
      unbound, as in a terminal; `unconsumed:` (which in a terminal ALSO sends
      the key to the program running there) has no program to pass it to, so
      it behaves like a plain binding rather than letting the key fall on to
      the menu and perform twice.
- `--view=about:blank` opens a **blank browser pane**. The command palette's
  "Viewer: Open Browser Pane" does the same interactively and puts the caret
  straight in the address field — the equivalent of `+split --view=<url>` for
  when the URL is not known up front.
- Because any viewer can browse, `+list --json`'s `"url"` (and the session
  manifest) report where a pane currently IS, not where it was opened.
- Relative `--view` paths resolve against `--working-directory` if given,
  else the caller's cwd. A `git-*:` spec is NOT a path — its text is a revspec,
  so it is never path-resolved; the same `--working-directory` decides which
  *repository* it applies to.
- `+list` marks viewer panes with a `view:` prefix (JSON: `"type": "viewer"`
  plus `"url"`); they auto-register names like terminal panes.
- `+read`/`+send-keys`/`+set-state`/`+set-banner` against a viewer fail with
  `... is a viewer pane, not a terminal` (exit 1). `+close` works normally
  and never prompts for viewers.
- **Hero mode** shows every viewer kind, and gives it back to the grid on
  exit. A viewer sits in the grid inside a `ViewerLeafHost` — SwiftUI never
  hosts the `ViewerView` directly, as a terminal's `SurfaceScrollView` wraps
  its surface — and while a hero slot holds it (`ViewerView.holdForHero`) no
  grid leaf may take it. SwiftUI re-adds whatever view it was handed on every
  update, and the grid hero mode replaces still runs one last update: it used
  to take the pane back out of the hero about one entry in two, and the hero
  was blank (`viewer.window == nil`). Tests: `HeroViewerRenderWindowTests`
  (captured pixels per viewer kind), `ViewerLeafHostTests`.
- Session persistence: viewer panes restore by re-opening their file/URL —
  an image pane comes back at best-fit, since a zoom is a transient reading
  posture rather than something the pane IS — and a diff pane by RE-RUNNING
  its spec against the origin directory the manifest persisted, so a restored
  `git-status:` pane shows today's working tree, not a snapshot of the one it
  was closed on. (Terminals in the same window re-attach as usual.) A missing
  file restores as an in-page error card.
- File → Open (or dragging onto the dock icon, or `open -a Ghoztty file.md`)
  opens `.md`-family files **and images** as a viewer window. Deliberately
  just those two: a `.swift` or `.sh` dropped on the dock has always opened a
  terminal, and changing that would break a workflow to buy a nicety.
  Ghoztty does **not** declare `public.image` in `CFBundleDocumentTypes` — it
  would put Ghoztty in the Open With menu for every screenshot on the machine,
  which is a system-wide claim about what this app IS rather than a
  consequence of being able to display one.
