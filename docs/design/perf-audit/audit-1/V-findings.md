# Audit-1, area V: viewer panes (T2963)

- **Date:** 2026-11-14
- **Commit audited:** a229abc72
- **Baseline:** `../baseline-1.json` (T2958). It has **no viewer phase**, so
  every cost below is an estimate, and each one says how it was estimated.
  PA-V01 adds the missing phase, and the other tasks' validation criteria
  quote the metric it will produce.

**Produced by** three Fable 5.2 auditors (`claude-fable-5-2`, passed
explicitly) working read-only and in parallel:

1. **A: WebView2 lifetime.** `webview2*.zig` and the create, close,
   visibility and snapshot paths of `ViewerPane.zig`.
2. **B: the content pipeline.** `viewer_content`, `viewer_bridge`,
   `viewer_diff`, `ViewerDiffProbe`, `ViewerWorktreeProbe`,
   `viewer_worktree`, `viewer_watcher`, `viewer_image`, the resource handler,
   and `WhatsNewNotesView`.
3. **C: viewer chrome.** Nav bar, contents card (`ViewerTOCPanel`,
   `viewer_toc_comp`), find card, feedback composer and its images, glass.

Areas W, R, M and I were read first and are not re-reported. Thread stacks
(16 MB committed per `std.Thread.spawn`) are PA-W01/T2985 and are only noted
here.

**Verification.** This turn read the cited lines for every surviving claim
before filing it. Merged: A4 and B3 are one defect (PA-V05); A7 and B9 are
one cluster (PA-V17); B5 and B10 are one cluster (PA-V12); B8 and C10 are one
cluster (PA-V13); C6, C7 and C8 are one cluster (PA-V21); A8 and A9 are one
cluster (PA-V23).

## What the area looks like

- **The process model is right.** One `ICoreWebView2Environment` and one
  user-data folder serve every viewer (`webview2.zig:453-461`, `:565-578`;
  `webview2_paths.zig:126-134`). So there is one browser, GPU and utility
  tree per app, plus one renderer per viewer controller.
- **The close path is clean.** `ViewerPane.deinit` closes the controller
  before releasing it, then releases every handler, frame, the popup request
  and the environment reference (`ViewerPane.zig:919-981`). The watcher,
  probes, strings and chrome windows are all released (`:901-1080`).
- **What is not right is the time between.** The browser tree is kept after
  the last viewer closes (PA-V02), hidden viewers keep their whole renderer
  (PA-V03), and a background viewer still reloads on every save (PA-V05).
- **The busiest idle cost is `git-status:`.** About six git processes every
  2 s while the pane is visible (PA-V06).

## Findings

| Id | Pri | Finding | Task |
|---|---|---|---|
| PA-V01 | P1 | `perf-baseline.ps1` has no viewer phase, so nothing in this file is measured | T3033 |
| PA-V02 | P1 | The WebView2 browser tree stays up after the last viewer closes | T3034 |
| PA-V03 | P1 | Hidden viewers are paused but never suspended or memory-trimmed | T3035 |
| PA-V04 | P1 | A viewer born hidden still starts a renderer and loads its page | T3036 |
| PA-V05 | P1 | Every save re-reads, re-sends and re-renders the whole document, even hidden or unchanged (*page side shared*) | T3037 |
| PA-V06 | P1 | A `git-status:` pane runs about six git processes every 2 s | T3038 |
| PA-V07 | P1 | A diff patch is copied about four times on the GUI thread, and 8 MB is kept per pane | T3039 |
| PA-V08 | P1 | A contents-card slide creates a D3D11 + DirectComposition device that is kept for the pane's life | T3040 |
| PA-V09 | P1 | On glass, every viewer paint allocates and renders a full-client DIB, even under an opaque page | T3041 |
| PA-V10 | P1 | The find card deletes its bitmap while it is selected, which likely leaks one DIB per card resize (inferred) | T3042 |
| PA-V11 | P1 | HEIC/TIFF transcode holds four or five full pixel copies on the GUI thread | T3043 |
| PA-V12 | P1 | Served resources and documents are read whole, synchronously, on the GUI thread | T3044 |
| PA-V13 | P1 | Closing a pane joins its git or feedback worker on the GUI thread with no cancellation | T3045 |
| PA-V14 | P1 | A viewer's snapshot bitmap lives until the pane dies | T3046 |
| PA-V15 | P2 | Every pane re-reads all 14 template assets and loads every script whatever its mode (*shared*) | T3047 |
| PA-V16 | P2 | Each diff completion deep-copies the file list; the numstat join is O(n²) | T3048 |
| PA-V17 | P2 | Poll timers tick while hidden; the worktree gate uses `IsWindowVisible` | T3049 |
| PA-V18 | P2 | Hero thumbnails are a full-page PNG encode and decode once a second | T3050 |
| PA-V19 | P2 | The feedback composer re-renders its glass band into a fresh DIB on every paint | T3051 |
| PA-V20 | P2 | Feedback images stay after their chip is deleted, and Send copies every PNG | T3052 |
| PA-V21 | P2 | Contents-card and find-card work per mouse move | T3053 |
| PA-V22 | P2 | Every viewer creates its composer and find windows up front | T3054 |
| PA-V23 | P2 | Iframe proxies kept until the next iframe; assets directory re-resolved per pane | T3055 |
| PA-V24 | P2 | What's New re-lays-out every note on every paint and scroll | T3056 |

Mac half: T3057 (PA-V05's page side and PA-V15, in `src/viewer/`).

### PA-V01: no viewer phase in the baseline (P1)

`scripts\perf-baseline.ps1` has five phases (`idle`, `busy`, `resize`,
`cycle`, `agent`); none opens a viewer. **Fix:** a `viewer` phase that opens
a markdown, a `git-status:` and a website viewer, records the
`msedgewebview2.exe` process count and private bytes (children of the
environment's browser process), app private bytes and GDI/USER objects, then
hides the tab for 60 s (renderer CPU and private bytes), then closes every
viewer and waits 90 s (residual tree). **Risk:** WebView2 process discovery
on the test desktop. Every other V task's criteria quote this phase.

### PA-V02: browser tree kept after the last viewer (P1)

`Host.deinit` (`webview2.zig:494-503`) is the only environment release and
runs only at app exit (`App.zig:2848`); `Host.state` never returns to
`.idle` (`:511-529`). **Cost (estimated** from typical idle WebView2 trees):
150-300 MB over about four processes for the rest of the session after any
viewer has opened. **Fix:** count live controllers (panes and composer); at
zero, start a 60 s grace timer, then release the environment and reset to
`.idle`. **Risk:** the next viewer pays a cold start (0.3-1 s, estimated).

### PA-V03: hidden viewers not suspended (P1)

`ViewerPane.setVisible` (`ViewerPane.zig:1834-1849`) only calls
`put_IsVisible` and `ShowWindow`. No `ICoreWebView2_3` (`TrySuspend`,
`Resume`) or `ICoreWebView2_19` (`MemoryUsageTargetLevel`) exists in
`src/apprt/win32` (grep, case-insensitive). **Cost (estimated):** 50-150 MB
of renderer heap per hidden viewer, plus page timers on live pages.
**Fix:** on hide set `MemoryUsageTargetLevel = Low`, then `TrySuspend` after
about 30 s; restore `Normal` on show. **Risk:** IPC verbs and captures
against a suspended page must `Resume` first; needs a runtime-version
fallback.

### PA-V04: born-hidden viewers start (P1)

`Window.zig:3997` calls `viewer.start` unconditionally, and
`setTabSurfacesVisible` (`Window.zig:4425-4427`) says rebuilt background tabs
start visible and are hidden afterwards. Session restore taking this path is
inferred. **Cost (estimated):** a renderer and a full page load per
never-shown viewer. **Fix:** defer `start` to the first `setVisible(true)`.
**Risk:** `+read` and screenshots of a never-shown viewer need start on
demand.

### PA-V05: whole-document reload on every save, even hidden (P1)

`WM_APP_VIEWER_RELOAD` arms the 100 ms debounce (`ViewerPane.zig:7461-7463`)
and the timer calls `reloadContent(.file_changed)` (`:7545-7553`) with no
visibility check, unlike the diff poll (`:7541`). The read and escape run on
the GUI thread (`:4527-4566`; 32 MB cap `viewer_content.zig:1341`) and the
page re-renders everything (`src/viewer/viewer.js:54-63`, shared). **Cost
(estimated** from the copies): about 3x the file size transient per save,
plus a full parse in the renderer, unbounded while a writer keeps saving.
**Fix:** skip when size and mtime are unchanged; while hidden, record the
reload as owed and pay it once on show (the `diff_poll_gate` pattern,
`:1844`). **Risk:** a hidden pane read over IPC shows stale content until
shown.

### PA-V06: `git-status:` spawns about six processes every 2 s (P1)

`diff_poll_ms = 2000` (`ViewerPane.zig:237`). Each listing
(`ViewerDiffProbe.zig:540-623`) resolves the repository root with git
(`repositoryRoot`, `:762-770`), runs name-status and numstat per origin
(`:577-598`, staged and unstaged) and lists untracked files, and reads each
untracked file up to 2 MB to count lines (`:645-683`). **Cost (estimated**
at the ~30 ms per `CreateProcess` the worktree probe's header cites): about
3 spawns/s, roughly 9% of a core while visible. **Fix:** cache the repo root
per pane; one `git status --porcelain=v2 -z` fingerprint per tick and the full
listing only when it moves; cache untracked counts by size and mtime.
**Risk:** a fingerprint that misses a content-only edit; include mtimes.

### PA-V07: diff patch copies (P1)

`setDiffFileCall` (`ViewerPane.zig:2296-2309`, `viewer_diff.zig:640-658`)
builds an unsized UTF-8 list and `executeScript` widens it; `probe.patch`
(cap 8 MB) is kept until the next patch or close. **Cost (estimated** from
the cap): about 32-40 MB transient at the cap and 8 MB retained. **Fix:**
build UTF-16 directly with a presize, as `callUtf16` does
(`viewer_content.zig:785-797`); free the patch after the push.

### PA-V08: contents-card compositor device kept (P1)

`viewer_toc_comp.zig:123-168` creates a D3D11 device, a DirectComposition
device, a target and two visuals on the first compositor slide
(`ViewerTOCPanel.zig:1180`). `finishCompSlide` and `cancelCompSlide` only
call `host.stop` (`:1271`, `:1285`); the device is released in `destroy`.
**Cost (estimated** by analogy with PA-R02's per-device driver threads and
GPU memory): one D3D11 device per viewer that ever slid its card. **Fix:**
deinit the host when the slide ends, or share PA-R02's device. **Risk:** low;
the next slide recreates it.

### PA-V09: glass paint allocates a full-client DIB (P1)

`paintGlass` (`ViewerPane.zig:7112-7130`) creates and destroys a full-client
32bpp DIB and renders the whole sheet on every `WM_PAINT`, also under an
opaque website page. **Cost (computed):** 5 MB per paint at 1400x900, 33 MB
at 4K, on every resize step and backdrop change. **Fix:** a grow-only DIB
(as `ViewerNavBar.ensureBack`), clip to the update rect, skip the controller
rect under an opaque page. **Risk:** stale pixels while the page arrives
(T1885).

### PA-V10: find-card bitmap deleted while selected (P1, inferred)

`releaseCardSurface` (`ViewerFindBar.zig:764-768`) calls `DeleteObject` on
`card_bmp` while it is still selected into `card_dc` (selected at `:745`, the
original never saved), then deletes the DC. Deleting a selected bitmap fails,
so each card resize, scale or theme change likely leaks one DIB. **Cost:**
one card-sized bitmap per resize (inferred, not observed). **Fix:** delete
the DC first, as `ViewerTOCPanel.zig:1552-1553` does. **Validation:** GDI
object count across 50 find-card resizes.

### PA-V11: HEIC/TIFF transcode copies (P1, rare format)

`transcodeImage` (`ViewerPane.zig:4935-4941`) holds the decoded BGRA, the
DIBv5 and the BMP file at once, then the response copies the BMP into an
HGlobal stream (`:5126-5129`); the comment at `:4932-4934` puts the decode on
the UI thread at "a few hundred milliseconds". **Cost (computed):** a 12 MP
photo is 48 MB per copy, about 195 MB transient. **Fix:** write the BMP
header and rows straight into the stream; decode on a worker under a
deferral. **Risk:** deferral lifetime against pane close.

### PA-V12: GUI-thread whole-file reads (P1)

Resources are read whole and copied into an HGlobal stream
(`ViewerPane.zig:4822-4838`, `:5019-5037`, `:5120-5129`); media ranges come in
8 MB chunks (`viewer_range.zig:27`); document stats and reads are
synchronous too (`:4528`, `:2087-2090`, `:5076`). **Cost (estimated):** 2x
the resource size per request, and a stall of every terminal in the process
on a slow or network path. **Fix:** a file-backed stream
(`SHCreateStreamOnFileEx`), 1-2 MB range chunks, document reads on a
`worker_pool` job. **Risk:** share modes while an editor saves.

### PA-V13: close joins workers on the GUI thread (P1)

`ViewerDiffProbe.deinit` joins its worker (`ViewerDiffProbe.zig:222-226`,
from `ViewerPane.zig:1040-1042`); a listing is up to six sequential git
commands with a 15 s deadline each (`git_run.zig:39`). The worktree probe
(`ViewerPane.zig:1030`) and the feedback sender (`ViewerFeedbackSend.zig:157-160`)
join the same way. **Cost:** a whole-app freeze of up to tens of seconds
(rare). **Fix:** a cancel flag checked between commands, and terminate the
running child on deinit.

### PA-V14: snapshot bitmap kept until close (P1)

The hero or glide snapshot DIB (`ViewerPane.zig:5464-5468`) is freed only in
`deinitHeroSnap` from `deinit`. **Cost (computed):** about 5 MB at 1400x900
and 33 MB at 4K per viewer that ever glided. This is the viewer twin of
PA-M01. **Fix:** free it when the glide or hero mode ends.

### PA-V15 to PA-V24 (P2)

- **PA-V15** (*shared*): `viewer.html:8-22` loads 14 assets (about 470 KB,
  by `wc -c`) for every pane, image and diff panes included, served with no
  cache header (`ViewerPane.zig:5133-5139`) and re-read from disk per load.
  Fix: a process-wide asset cache and per-mode lazy scripts.
- **PA-V16:** `completeDiff` snapshots the file list on every completion
  (`ViewerPane.zig:2319-2320`); the numstat join is O(n²)
  (`ViewerDiffProbe.zig:600-617`). Fix: compare inside `complete`, hash the
  join.
- **PA-V17:** the diff (`ViewerPane.zig:2146`) and worktree (`:1291`) timers
  keep ticking while hidden and drop the tick in the handler; the worktree
  gate is `IsWindowVisible` (`:7526`), which reads true for a minimized
  window. Fix: KillTimer on hide, re-arm on show, use `self.visible`.
- **PA-V18:** hero mode captures a full-page PNG each second
  (`ViewerPane.zig:5424`, `hero_snap_schedule.zig:61`) and decodes it on the
  GUI thread (`:5462`). Fix: skip when the page has not changed; a scaled
  capture.
- **PA-V19:** the composer re-renders its glass band into a fresh DIB on
  every paint (`ViewerFeedbackBar.zig:1862-1870`). Fix: reuse
  `GlassHeadCache`, as the nav bar does.
- **PA-V20:** the image store has no remove (`viewer_feedback_images.zig:113-130`,
  caps 32/64 MB at `:55-56`); a deleted chip's PNG stays until send or close,
  and Send copies every PNG (`ViewerFeedbackSend.zig:259-267`). Fix: prune
  unreferenced entries on composer close; lend the bytes to the worker.
- **PA-V21:** dragging the contents-card width re-measures every row
  (`ViewerTOCPanel.zig:2283-2287`, `:939-941`, `:812-878`) and re-renders the
  card DIB (`:1509-1549`) per mouse move; row hover repaints the whole card
  unbuffered (`:2289-2293`); the find card measures its count text per mouse
  move (`ViewerFindBar.zig:770-779`, `:537-551`). Fix: cache widths,
  invalidate only changed rows.
- **PA-V22:** each viewer creates its composer, find card and their EDITs up
  front (`ViewerPane.zig:1244-1259`). Fix: create on first open (key-routing
  risk, per the comments there).
- **PA-V23:** `pruneFrames` runs only from `adoptFrame`
  (`ViewerPane.zig:2963`, `:2997`), so a navigation away keeps dead iframe
  proxies; the assets directory is walked per `start` (`:5703-5710`). Fix:
  prune on navigation completed; resolve once.
- **PA-V24:** `WhatsNewNotesView` lays every note out on every paint and
  scroll (`WhatsNewNotesView.zig:250-272`). Fix: cache lines per width.

## Claims that did not survive verification

- **"One browser process tree per viewer."** False: one shared environment
  and user-data folder (`webview2.zig:565-578`).
- **"Viewer close leaks the controller or its handlers."** False: `Close()`
  then `Release()`, and a late controller arriving after close is closed
  (`ViewerPane.zig:5777-5784`). No `remove_*` calls are needed after
  `Close()`.
- **"The file watcher polls."** False: overlapped `ReadDirectoryChangesW`,
  all handles freed on every path (`viewer_watcher.zig:119-169`, `:208-210`).
- **"Images are sent to the page as base64."** False: by URL through the
  virtual host (`ViewerPane.zig:4512-4519`).
- **"Hidden `git-status:` panes run git every 2 s."** False: the tick is
  dropped while hidden and caught up once on show (`:7541`, `:1844`); only the
  timer wake remains (PA-V17).
- **"The feedback composer's WebView leaks."** False: created on open, closed
  on close (`ViewerFeedbackWeb.zig:178-204`).

## Checked and found clean

- Nav bar: grow-only back buffer, cached glass, one-shot timers, everything
  freed in `destroy` (`ViewerNavBar.zig:365-383`, `:1397-1427`).
- Contents card teardown, its window region, and off-screen row culling
  (`ViewerTOCPanel.zig:401-417`, `:1001-1007`, `:1722-1724`).
- Feedback bar teardown, cached thumbnails, a 32-step undo journal.
- Region selector DIBs exist only while the overlay is up.
- Bridge messages are debounced and change-only; the parse arena is freed per
  message (`viewer_bridge.zig:132-191`, `ViewerPane.zig:2853-2854`).
- Worktree cache is bounded at 8 entries; no per-file or per-commit cache.
- No idle timer in a plain file or web viewer; reload and feedback timers are
  one-shot. No environment pre-warm outside tests.

**Not covered:** the bridge and message handlers in `ViewerPane.zig` beyond
the cited ranges, `viewer_file_tree.zig` and `banner_markdown.zig`
internals, `viewer_feedback_report/_doc/_acc/_a11y/_layout`,
`screen_capture.zig`, the page-side cost of `diff.js` and `image.js`, how
long close-undo keeps a parked viewer (`CloseUndo.zig:394`), and every
runtime number (PA-V01).

## Filed as

- **PA-V01 to PA-V24** -> T3033 to T3056, in order (table above)
- **Mac seat:** T3057 validates PA-V05's page side and PA-V15 (the shared
  `src/viewer/` template) on macOS. Everything else is Windows-only code.
