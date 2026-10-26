# Image and git-diff viewer panes

The two non-page viewer kinds: native image panes and `git-status:` /
`git-diff:` panes. Shared viewer behavior (nav bar, find, keyboard, links) is in
[viewer-panes.md](viewer-panes.md). Read before touching `ImageViewer*` /
the diff viewer, `ViewerSidePanel`, or the diff rendering JS.

# Image panes

`--view=<path>.png` (and the other image extensions) opens a pane that renders
the picture on a **native `NSScrollView`**, not as an `<img>` in the web view.

```bash
ghoztty +split --target=dev --name=shot --view=temp/feedback/new/x/images/image-1.png
ghoztty +new-window --view=~/Desktop/mock.png
ghoztty +reload --target=shot        # re-decode from disk
```

**Why it is native.** Every other viewer mode is a page, and the whole stack —
find (`src/viewer/find.js`), quoting (`selection.js`), the link menu
(`links.js`), history — is web-side, so an `<img>` would have been the tidier
choice architecturally. It loses the actual requirement. `WKWebView`'s pinch is
WebKit's *page* magnification: it has no notion of the image's natural size (so
no real "fit" and no pixel-exact "100%") and its double-tap smart-zoom targets
DOM elements. `NSScrollView` is what Preview and Xcode's canvas use, and it is
where macOS's own gesture handling lives — pinch anchored at the gesture
centroid, rubber-banding past the zoom limits, elastic edges and momentum on a
two-finger pan, `smartMagnify` for a two-finger double-tap. All of that is free
and none of it is reproducible in a page. Trackpad feel was the requirement, so
it won.

**The web view is still there, underneath.** The pane navigates to the render
template exactly as a markdown pane does; the surface is a sibling mounted over
it. That is what buys an image pane everything structural for free: a real
history entry (Back out of a website lands on the image), Home, an address
field that shows and accepts the path, `+list --json`'s `"url"`, session
restore, and — when the file cannot be decoded — the same in-page **error card**
every other file mode shows, rather than a second one written for images.

- **Zoom.** Trackpad **pinch** is AppKit's, anchored at the gesture centroid.
  **Two-finger pan** scrolls with the standard elastic edges and momentum.
  **Double-click** (and two-finger **double-tap**) toggles **best-fit ⇄ 100%**,
  anchored where you clicked. **Cmd+plus/minus** step by 1.25× (coarser than
  the web viewer's 1.1 — an image's useful range spans two orders of magnitude
  where a page's spans one) and **Cmd+0** is 100%. Limits are 5%–3200%, with
  the floor yielding to whatever best-fit needs for a very large image.
- **"100%" means one image pixel per DEVICE pixel.** Two reasons, in order: it
  is the only definition under which 100% is actually pixel-exact — every image
  pixel lands on one screen pixel, nothing is resampled, and a 1px hairline is
  a 1px hairline, which is the whole reason anyone asks for 100% — and most of
  what these panes get pointed at is screen capture (the feedback composer's
  own screenshots, an agent's UI render), which is captured at device
  resolution, so 100% shows it at exactly the size it was on screen. One image
  pixel per *point* would show a 2x screenshot at twice the size of the screen
  it came from. The natural size comes from the image's REPRESENTATIONS, not
  from `NSImage.size`, which is DPI-derived and would silently halve 100% for
  anything tagged 144dpi. **Vector art (SVG) has no pixel grid to be 1:1 with**,
  so its 100% is its intrinsic size in points.
- **Best-fit never upscales.** A pane opens at best-fit, capped at 100%: a 32px
  icon in a 900pt pane stays 32 device pixels, crisp and centered, rather than
  being blown up into a blurry lie about the asset. The consequence is that fit
  and 100% coincide for a small image, which would make the double-click toggle
  visibly do nothing — so in that one case the first double-click goes to
  **200%** instead and the next comes back to fit. The toggle always toggles.
- **Resizing the pane re-fits — unless you chose a zoom.** Dragging a split
  divider re-fits a fitted image; once you have pinched or stepped to a
  magnification of your own, a resize preserves it. (The magnification is still
  re-derived on a resize, because moving the pane between a Retina and a
  non-Retina display changes what 100% means and it has to stay 100%.)
- **Rendering.** Interpolation is high-quality at or below native resolution
  and switches to **hard pixels from 2x up** — the only reason to magnify a
  screenshot that far is to look at individual pixels, and a bilinear smear of
  them answers no question anyone had. An image smaller than the pane is
  **centered** (a custom `NSClipView`; AppKit pins it to a corner otherwise).
  Animated GIFs animate. The matte is `windowBackgroundColor`, a dynamic color,
  so light/dark follows the window the way every other viewer mode's background
  does.
- **Cmd+C copies the picture** (the image itself plus its file URL), as
  Preview does with nothing selected — the only thing a copy can mean in a
  pane with no text.
- **What an image pane does NOT have**, and why that is stated rather than
  faked: **find** (declined — see Find in page), **text selection**, and
  **quoting**. There is no text. **Feedback capture still works** — the
  worktree is the image file's own directory, the composer takes a written
  report and pasted screenshots as usual, and the report's `source.kind` is
  `image` (rather than `file`) so a downstream agent knows there will be no
  `selection` and no `quotes`.
- **No pop-out or lightbox.** "Make this pane big" is Hero mode
  (`toggle_hero_mode`), which already exists and already works on viewer panes.
  A second expansion affordance would be two answers to one question.

# Git diff panes

`--view=git-status:` / `--view=git-diff:<revspec>` opens a pane that renders a
git diff: a native file tree on the left, traditional red/green
syntax-highlighted hunks on the right, and next/previous-change +
unified⇄side-by-side controls in the nav bar.

```bash
# changes in this branch against main (three-dot: the merge base, which is
# what "changes in this branch" means to a person)
ghoztty +split --target=dev --name=diff --view=git-diff:main...HEAD

# the working tree — staged, unstaged, and untracked, kept apart
ghoztty +new-window --target=review --working-directory=~/git/repo --view=git-status:

# one commit's own changes, and an arbitrary range
ghoztty +split --view=git-diff:a1b2c3d
ghoztty +split --view=git-diff:v1.2.0..v1.3.0

# this branch against main/master/origin HEAD, whichever the repo has
ghoztty +split --view=git-diff:

ghoztty +reload --target=diff        # re-run the diff
```

**The location IS the diff spec**, which is what buys every existing viewer
affordance for free — the address bar shows and accepts it, `+list --json`
reports it as the pane's `url`, `+reload`/Cmd+R re-runs it, back/forward cross
into and out of it, and the session manifest restores the pane by re-running
it. Four forms:

| `--view=` | Means |
|---|---|
| `git-status:` | Working tree: staged, unstaged, and untracked |
| `git-diff:<a>...<b>` | Three-dot range — `<b>` against the merge base |
| `git-diff:<a>..<b>` | Two-dot range, handed to git verbatim |
| `git-diff:<sha>` | That ONE commit's changes (`git show`, first-parent for merges) |
| `git-diff:` | This branch against `origin/HEAD`, else `main`/`master` |

A bare revision means *that commit*, not "diff against it" — `git-diff:abc123`
answers "what changed in abc123". Use `a..b` when you mean a comparison.

- **Which repository**: the one containing `--working-directory` (else the
  caller's cwd, which `+split`/`+new-window` insert for you), resolved with
  `git rev-parse --show-toplevel`. A directory in no repo renders an
  explanatory card, not a blank pane.
- **The file tree is the table-of-contents card**, not a lookalike: same glass
  card, same pinned header, same row metrics and macOS selection pill, same
  gutter⇄overlay switch at 720pt, same drag-to-resize handle and shared width
  preference (`ViewerSidePanel` owns all of it). What it adds is a **filter
  field pinned under the header** — terms are ANDed against the whole path, a
  non-empty filter flattens the tree to a hit list, Return opens the top hit,
  Escape clears it — plus folder/file hierarchy with git's own status letter
  (A/M/D/R…) and each file's `+N −M`. Chains of single-child directories
  collapse into one row (`macos/Sources/Features/Viewer`), and clicking a
  folder folds it.
- **Working-tree sections**: staged, unstaged, and untracked are three lists,
  in that order, because which changes are staged is the thing `git status`
  exists to tell you. A file modified both staged and unstaged appears in both
  (they are different diffs), and clicking each shows that side.
- **Scale**: the file list is eager (one `--numstat`/`--name-status` pass —
  cheap for thousands of files) and each file's PATCH is fetched only when its
  row is clicked. Rows are appended to the page in chunks across frames, with
  a 20 000-row cap and a "Show the rest" button past it. Binary files and
  unreadable ones render a stub, never a hang. All git work runs off the main
  thread.
- **Rendering** is hand-rolled over parsed unified hunks (no new vendored
  dependency, zero added bundle weight) on the already-bundled highlight.js.
  Each hunk is highlighted as two contiguous texts — the old side and the new
  side — rather than line by line, so a block comment or template literal is
  not restarted on every row, and the result is split back into lines with the
  open tags carried across the break. Paired removed/added lines get an
  **intra-line word highlight** so a one-character change reads as one
  character. Deliberately NOT Monaco: this pane is read-only, and a
  multi-megabyte editor would blow up an offline bundle to lose on scroll
  performance.
- **Unified vs side-by-side**: unified is one column with sticky line-number
  gutters and horizontal scroll (code keeps its shape); side-by-side is a
  four-column CSS grid, so a pair stays aligned even when a long line wraps.
  The choice is a preference in defaults, shared by every diff pane.
- **Next/previous change** steps *change blocks* (a `@@` hunk can hold
  several), and rolls over into the adjacent FILE when the open one runs out —
  entering it at its first or last change so walking a diff reads continuously.
  It steps from a remembered index, not from the scroll position, so a fast
  double-press advances twice instead of re-picking the change the smooth
  scroll has not reached yet; your own next scroll hands it back.
- **Three things that are not each other.** A diff pane has a
  next/previous-**change** stepper (nav bar), a **file filter** (side panel),
  and **find in page** (Cmd+F). They step hunks, narrow the file list, and
  search text respectively, and each owns Enter/Escape only while ITS field
  has the caret (see Viewer Panes → Keyboard for the precedence). Find
  searches the **open file's patch and nothing else** — the rest of the diff
  is in the file tree, not in the DOM — so the find bar names the file
  (`in app.swift`), and says `rows past the cap are not searched` while the
  20 000-row cap is in force. Without that line a "No results" would read as
  "not in this diff", which would be a lie.
- **Live**: a `git-status:` pane re-checks the working tree every 2s and
  updates only when the file list actually moved, so an edit or a `git add` in
  another pane shows up without a reload and without a flicker. A commit or a
  range is a fixed pair of trees and is not polled.
- The nav bar carries a diff pane's change and layout controls, and shows its
  revspec. It is pinned open, but so is every other viewer pane's (see
  Navigation chrome) — a diff pane was once one of the modes that had to
  carve out an exception, and no longer needs to.
