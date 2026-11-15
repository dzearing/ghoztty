# Audit-2, area V: viewer panes (T3072)

- **Date:** 2026-11-14
- **Commit audited:** 879fba35a
- **Input:** `../audit-1/V-findings.md` (PA-V01 to PA-V24, lines as of
  a229abc72) and the V table in `../audit-1.md`.
- **Baseline:** still none for viewers. `scripts/perf-baseline.ps1` gained a
  `-BusyText` knob since audit-1 and no viewer phase, so every cost below is
  still an estimate unless it says otherwise.

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor.

**Method.** Every verdict below comes from reading the cited lines at HEAD,
not from a search hit. Nothing was built, run or launched.

## What changed since audit-1

`git log a229abc72..HEAD` over `src/apprt/win32/Viewer*`, `viewer*` and
`webview2*.zig` is **empty**, and `git diff --stat a229abc72..HEAD -- src/`
touches no viewer file, `Window.zig` or `App.zig`. So:

- every audit-1 line number for a viewer file is still exact at HEAD;
- no V task (T3033 to T3056) closed, and none was fixed as a side effect;
- three fixes in other areas touch V items indirectly (below).

| Fix | What it did | Effect on area V |
|---|---|---|
| T2968 29302f08c | one process-wide D3D11 device for terminal swap chains (`src/renderer/gl_comp_present.zig:393-443`, `DeviceCache`) | PA-V08: the "share R02's device" option now exists, and its per-device cost is measured. The cache is file-private (`var device_cache`, `:443`), so the contents card still makes its own. |
| T2985 90e57ab70 | pooled threads commit 64 KB of stack, not 16 MB (`src/os/thread_stack.zig:33-34`, `src/os/reusable_thread.zig:61`, `:116`) | The viewer worker pool (`worker_pool.zig:25-28`) inherits it: the watcher, diff probe, worktree probe and git deadline threads no longer hold 16 MB each. The feedback sender is not on the pool (PA-V25). |
| T2974 6711c4e45 | terminal render storage is trimmed a second after a resize settles | None. A viewer has no render target. Its twin, PA-V14, is untouched. |

## Verdicts

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| V01 | still open | `scripts/perf-baseline.ps1` | the only change since audit-1 is `-BusyText ascii/cjk`; phases are still idle, busy, resize, cycle, agent | T3033 unchanged |
| V02 | still open | `webview2.zig:494-503`, `:511-529`, `App.zig:2848` | `Host.deinit` is the only `env.release()` and its only caller is app teardown; `request` never returns state to `.idle` | T3034 unchanged |
| V03 | still open | `ViewerPane.zig:1831-1848` | `setVisible` calls `c.setVisible`, `ShowWindow` and the diff catch-up only; no `TrySuspend` or `MemoryUsageTargetLevel` anywhere in `src/apprt/win32` (case-insensitive search, then the function read) | T3035 unchanged |
| V04 | still open | `Window.zig:3997`, `:4422-4427` | `viewer.start(alloc, &self.app.webview2_host)` is unconditional; the doc comment still says rebuilt background tabs start visible | T3036 unchanged |
| V05 | changed (wider) | `ViewerPane.zig:7461-7463`, `:7548-7553`, `:4439-4454`, `:4527-4566` | the reload timer calls `reloadContent(.file_changed)` with no visibility, size or mtime check; the plan also covers `.html` (a full `Reload()`) and `.image` (re-fetch, and a re-transcode on the WIC route), not only markdown and code | T3037: say all four file modes; the hidden-defer fix covers them in one place |
| V06 | still open | `ViewerPane.zig:237`, `ViewerDiffProbe.zig:540-625`, `:645-683`, `:762-770` | per tick: 1 root query, name-status for staged, unstaged and untracked, numstat for staged and unstaged = 6 spawns; each untracked file read whole to count lines | T3038 unchanged |
| V07 | still open | `ViewerPane.zig:2296-2309`, `:4729-4739`, `viewer_diff.zig:640-658`, `ViewerDiffProbe.zig:47`, `:449` | unsized UTF-8 list, then `utf8ToUtf16LeAllocZ` in `executeScript`; `self.patch = job.out_patch` is kept, cap 8 MB | T3039 unchanged |
| V08 | changed (cost measured, fix path concrete) | `viewer_toc_comp.zig:123-168`, `ViewerTOCPanel.zig:1178-1184`, `:1271`, `:1285`, `:404` | still its own `D3D11CreateDevice` + DComp device per pane, kept until `destroy`; see the section below | T3040: rewrite cost and fix, add dep on T3074 |
| V09 | still open | `ViewerPane.zig:7112-7130` | `Dib32.create(hdc, width, height)` then `defer dib.destroy()` and a whole-client `glassSheetRegion` on every paint | T3041 unchanged |
| V10 | still open (inferred) | `ViewerFindBar.zig:764-768`, select at `:746` | `DeleteObject(card_bmp)` runs before `DeleteDC(card_dc)`, with the bitmap still selected and the original never saved | T3042 unchanged; still needs the GDI-count run to confirm |
| V11 | changed (one more copy) | `ViewerPane.zig:4935-4941`, `:4874`, `:4894-4898`, `:5126-5129` | as audit-1, plus PA-V26: the WIC route also reads the whole encoded file first and never uses it on success | T3043: add PA-V26 |
| V12 | still open | `ViewerPane.zig:4822-4838`, `:4874`, `:5019-5037`, `:5125-5129`, `:4528`, `:2087-2090`, `:5076`, `viewer_range.zig:27` | `readFileAlloc`/`readToEndAlloc` then `stream.writeAll(bytes)` into an HGlobal, all in the resource handler on the GUI thread; `max_chunk` is 8 MB | T3044 unchanged |
| V13 | still open | `ViewerDiffProbe.zig:222-226`, `ViewerWorktreeProbe.zig:195-199`, `ViewerFeedbackSend.zig:155-159`, `ViewerPane.zig:1030-1042`, `git_run.zig:39` | all three `deinit`s `join` with no cancel flag; deadline is 15 s per git | T3045 unchanged (PA-V25 is the same file) |
| V14 | still open | `ViewerPane.zig:5462-5468`, `:5499-5506`, `:909` | `snap_dib` is replaced on the next capture and deleted only in `deinitHeroSnap`, whose only caller is `deinit`. A glide asks for the full pane size (`:5368-5371`), a hero tile for the tile size (`:5338-5352`), so the 5-33 MB figure is the glide case | T3046: note the hero-tile case is tile-sized |
| V15 | changed (count) | `src/viewer/viewer.html:8-22`, `ViewerPane.zig:4822`, `:5133-5139` | the template names **12** files (5 stylesheets, 7 scripts), 13 requests with the page, about 399 KB by `wc -c` (LICENSE files excluded); audit-1 said 14 and 470 KB. `find.js`, `links.js` and `selection.js` are `@embedFile`d (`viewer_bridge.zig:69`, `:86`, `:100`) and never read from disk. Mechanism unchanged | T3047: correct the numbers |
| V16 | still open | `ViewerPane.zig:2319-2320`, `ViewerDiffProbe.zig:604-616` | `probe.snapshot(alloc)` on every completion; the numstat iterator restarts for every name-status entry | T3048 unchanged |
| V17 | still open | `ViewerPane.zig:2146`, `:1291`, `:7526`, `:7541` | both repeating timers stay armed while hidden; the worktree gate is `IsWindowVisible(hwnd)`, the diff gate is `self.visible` | T3049 unchanged |
| V18 | still open | `ViewerPane.zig:5424`, `:5462`, `hero_snap_schedule.zig:58-63` | `capturePreview(.png, ...)` at most once per 1000 ms per viewer, decoded on the GUI thread in the completion | T3050 unchanged |
| V19 | still open | `ViewerFeedbackBar.zig:1862-1870` | `Dib32.create` + `glassBand` + `destroy` per paint | T3051 unchanged |
| V20 | still open | `viewer_feedback_images.zig:55-56`, `:113-130`, `ViewerFeedbackSend.zig:255-258` | the `Store` API is `add`, `find`, `live`, `carousel`, `deinit`: no remove; `fill` dupes every PNG | T3052 unchanged |
| V21 | still open | `ViewerTOCPanel.zig:2274-2290`, `:939-941`, `ViewerPane.zig:3712-3722`, `ViewerFindBar.zig:770-779`, `:561-563`, `:537-551` | drag: `setTOCWidthLive` then `updateTOC` then `measureRows` per move; row hover invalidates the whole card; `updateHover` calls `currentLayout`, which calls `measureCount` (GetDC + GetTextExtentPoint32W) per move | T3053 unchanged |
| V22 | still open | `ViewerPane.zig:1244-1258` | `ViewerFeedbackBar.create` and `ViewerFindBar.create` in pane create | T3054 unchanged |
| V23 | still open | `ViewerPane.zig:2963`, `:2997`, `:5703-5710` | `adoptFrame` is the only caller of `pruneFrames`; `resourcesDir` is walked once per pane (the guard is the pane's own field) | T3055 unchanged |
| V24 | still open | `WhatsNewNotesView.zig:252-268` | `renderer.beginPaint()` then a full `renderer.render` from `-self.scroll` on every paint | T3056 unchanged |

**Totals:** 0 fixed, 0 wrong, 20 still open, 4 changed (V05, V08, V11, V15).
One note-only addition to V14.

## Changed items

### PA-V05: the hidden reload covers every file mode, not only text

Audit-1 described the markdown and code path (read, escape, inject). The
timer handler (`ViewerPane.zig:7548-7553`) calls
`reloadContent(.file_changed)`, and that function (`:4439-4454`) dispatches on
`content.reloadPlan`: `.rerender` goes to `renderFileContent` (text modes read
at `:4528`, image mode calls `startImage` at `:4517-4519`, which makes the
page re-fetch through `serveImage`), and `.reload_in_place` is a full
`web.reload()` of a rendered `.html` page (`:4463-4468`). None of the branches
looks at `self.visible`, the file size or its mtime.

So a hidden image pane on a file that keeps being rewritten re-reads it each
time, and on the WIC route re-transcodes it (PA-V11's roughly 195 MB transient
for a 12 MP photo, computed). A hidden `.html` pane reloads the whole page and
its subresources.

**Task should now say:** the hidden-defer and unchanged-skip belong in the
timer handler or at the top of `reloadContent`, so all four file modes get
them. The cost line should name the image and html cases. Priority unchanged
(P1).

### PA-V08: the contents-card device has a measured price and a place to share

Still true as written: `Host.init` (`viewer_toc_comp.zig:123-168`) creates a
D3D11 device, a DComp device, a target and two visuals;
`declareCompSlide` (`ViewerTOCPanel.zig:1178-1184`) creates it on the first
slide and keeps it; `finishCompSlide` (`:1271`) and `cancelCompSlide`
(`:1285`) only `stop`; release is in `destroy` (`:404`) or after a compositor
failure (`:1219`).

What moved:

- **Cost.** Audit-1 estimated "by analogy with PA-R02". T2968's commit message
  now carries the measurement for the same kind of device: ten panes went from
  611 to 116 threads, 3347 to 1402 handles, 1416 to 1223 MB private, and 349
  to 227 MB of GPU memory. Per device that is about **50 threads, 195 handles,
  19 MB private and 12 MB GPU** (computed from those figures; the terminal
  device also carried a swap chain, so the card's device is somewhat less on
  the GPU side). T2985 does not shrink this: the threads are the driver's, not
  `std.Thread`'s.
- **Fix path.** `DeviceCache` (`src/renderer/gl_comp_present.zig:393-443`) is
  the shared device. It is created with the same flag the card uses
  (`D3D11_CREATE_DEVICE_BGRA_SUPPORT`, `:358`, against
  `viewer_toc_comp.zig:135`) and is `ID3D10Multithread`-protected. It is not
  reachable from `apprt/win32` yet: `device_cache` is a file-private `var`.
  T3074 is the task that exposes it, and its text already says the contents
  card is PA-V08's own.

**Task should now say:** cost = about 50 driver threads and 19 MB private per
viewer that ever slid its card (computed from T2968). Fix, in order of
preference: (a) take the D3D11 device from `DeviceCache.acquire` once T3074
exposes it, and still drop the DComp device, target and surface when the slide
ends; (b) if T3074 has not landed, `deinit` the host in `finishCompSlide` and
`cancelCompSlide`, which needs nothing else. Add `deps: T3074` for (a) only.
Priority unchanged (P1).

### PA-V11: one more whole-file copy than audit-1 counted

See PA-V26. The four or five pixel copies are as described; the encoded file
is also read whole and thrown away.

### PA-V15: the numbers

Mechanism unchanged: each pane load requests every template file, the handler
reads each one from disk (`ViewerPane.zig:4822`) and answers with no cache
header (`.default` caching at `:4837`, header block at `:5133-5139`).

The template (`src/viewer/viewer.html:8-22`) names 5 stylesheets and 7
scripts. With the page itself that is 13 requests and about 399 KB
(`github-markdown.css` 32 KB, two hljs sheets 1.3 KB each, `viewer.css` 8 KB,
`diff.css` 10 KB, `markdown-it` 125 KB, task-lists 3 KB, `highlight` 129 KB,
`dompurify` 23 KB, `diff.js` 37 KB, `image.js` 12 KB, `viewer.js` 17 KB,
`viewer.html` 1 KB). Audit-1's 14 and 470 KB appear to have counted the
vendor LICENSE files, which no page requests.

**Task should now say:** 12 assets and the page, about 400 KB. The lazy-script
half is where the size is: `markdown-it` and `highlight` are 254 KB of the 399
and an image or diff pane needs neither `markdown-it` nor `dompurify`.

## New findings

| PA | Pri | Where | Cost | Fix |
|---|---|---|---|---|
| V25 | P2 | `ViewerFeedbackSend.zig:202` | 16 MB of stack commit while a report is being written (computed, T2985's mechanism), and one new OS thread per report | `worker_pool.spawn` |
| V26 | P2 | `ViewerPane.zig:4874`, `:4894-4898`, `:4935-4936` | one wasted whole-file read and copy (up to the 32 MB cap) on the GUI thread per HEIC/TIFF load (computed) | read only the first 32 bytes on the WIC route |

### PA-V25: the feedback sender is the one viewer worker not on the pool (P2)

`ViewerFeedbackSend.zig:202` is `std.Thread.spawn(.{}, work, .{ self, job })`.
The other viewer workers go through `worker_pool.spawn`: the watcher
(`viewer_watcher.zig:148`), the diff probe (`ViewerDiffProbe.zig:414`), the
worktree probe and the git deadline watchdog (`git_run.zig:61`).

**Mechanism.** A default `SpawnConfig` hands 16 MB to `CreateThread` as the
initial commit (`src/os/thread_stack.zig:3-14`). The pool's threads use
`thread_stack.config` (`src/os/reusable_thread.zig:61`, `:116`) and commit
64 KB. The pool also exists because every thread created while a GL context is
alive costs about 64 KB the NVIDIA driver never returns
(`worker_pool.zig:3-12`); this spawn pays that once per report.

**Cost (computed):** 16 MB of private bytes for the life of one send (a git
revision query, a file read and a report write; up to 15 s if git stalls),
plus about 64 KB per report on NVIDIA that is never returned (measured by
T2644 for the same thread shape, not re-measured here).

**Fix:** `worker_pool.spawn(work, .{ self, job })`; the handle type's `join`
is the same call. **Risk:** none seen; `deinit` already joins.

**Task action:** T3075 lists "about 35 `std.Thread.spawn(.{})` sites" and its
proposed source audit would catch this one. Name the site there, or do it in
T3045, which already edits this file's `deinit`. The three other
`std.Thread.spawn(.{}` hits in `ViewerPane.zig` (`:11429`, `:11539`, `:12306`)
are test servers.

### PA-V26: the WIC image route reads the whole file and does not use it (P2)

`serveImage` reads the viewed file whole before it looks at the route
(`ViewerPane.zig:4874`, cap `content.max_file_bytes`, 32 MB). On the `.wic`
route (`:4894-4898`) the bytes served come from `transcodeImage(alloc, path,
&why)`, which decodes from the **path** (`image_copy.decodeWhy(alloc, path,
why)`, `:4936`). The buffer read at `:4874` is touched only on failure, and
then only its first 32 bytes (`viewer_image.missingCodec(file[0..@min(file.len,
32)])`, `:4907`). It stays allocated across the whole transcode (`defer
alloc.free(file)`, `:4879`).

**Cost (computed):** one synchronous read and one heap copy of the encoded
file per load on the GUI thread: 2-5 MB for a phone HEIC, up to 32 MB for a
TIFF, held while PA-V11's pixel copies peak. Each live-reload repeats it
(PA-V05).

**Fix:** branch on `self.image_route` first; on `.wic`, open the file and read
32 bytes for the codec sniff only if the decode fails. **Risk:** none seen.
One behavior note for the fixer: today a TIFF over 32 MB fails at `:4874` with
"unreadable" before WIC is asked; after the fix WIC would decode it, so decide
whether the cap should still apply (stat the size) rather than let it lapse by
accident.

**Task action:** fold into T3043 (PA-V11), which rewrites this function.

## Regressions from the fix commits

None found in area V. No viewer file changed; T2968's device cache is private
to the renderer and the contents card neither uses nor disturbs it; T2985
lowers the viewer pool's stack commit and the stack still grows on demand to
the same 16 MB reserve (the watcher's 16 KiB on-stack buffer,
`viewer_watcher.zig:180`, and git's path buffers are far inside it); T2974
does not reach a viewer.

## Checked and found clean

- **Viewer worker threads after T2985.** `worker_pool.zig:25-28` owns one
  `reusable_thread.Pool` whose `spawn_config` defaults to
  `thread_stack.config`. A file viewer holds one parked-pool thread for its
  watcher for the pane's life, blocked in `WaitForMultipleObjects`
  (`viewer_watcher.zig:188-202`); at 64 KB commit that is no longer worth a
  task. The pool never shrinks, by design.
- **Resource-request scope.** The `WebResourceRequested` handler is filtered
  to the two virtual hosts (`ViewerPane.zig:3848-3866`), so a website pane's
  own requests do not round-trip through the GUI thread.
- **Contents-card width persistence.** Saved once on mouse-up
  (`commitTOCWidth`, `ViewerPane.zig:3724-3729`), not per drag step. The two
  prefs files are a few bytes each and read once per pane
  (`viewer_prefs.zig:59-79`).
- **Script injection handlers.** `find.js`, `links.js` and `selection.js` are
  compiled in, not read per pane (`viewer_bridge.zig:69-100`).
- **Close-undo.** A parked viewer is hidden through the same `setVisible`
  (`CloseUndo.zig:393-400`) and finalized when the undo deadline passes
  (`:740-749`); it holds its renderer for the configured `undo-timeout` only,
  which is PA-V03's cost for a bounded time, not a separate leak.
- **Hero thumbnails are tile-sized.** `decodeScaled(stream, snap_w, snap_h)`
  (`ViewerPane.zig:5462`) with the tile's size on the hero path
  (`:5338-5352`); only a glide asks for the full pane.
- **Hidden `git-status:` panes run no git.** `diff_poll_gate.tick(self.visible)`
  (`:7541`) and the single catch-up on show (`:1844-1847`), as audit-1 found.
- **The file watcher** is overlapped `ReadDirectoryChangesW` on the document's
  directory only, no subtree (`viewer_watcher.zig:188-197`), and `stop` joins
  before closing its three handles (`:157-168`).

**Not covered** (same gaps as audit-1, none closed by this pass): the
page-side cost of `diff.js`, `image.js` and `viewer.js`; `ViewerFeedbackWeb`
beyond its create/close pair; `viewer_feedback_report/_doc/_acc/_a11y/_layout`;
`screen_capture.zig`; `banner_markdown.zig`; the message handlers in
`ViewerPane.zig` outside the cited ranges; and every runtime number, which
waits on PA-V01 (T3033).

## Task actions, in one place

- **No change:** T3033, T3034, T3035, T3036, T3038, T3039, T3041, T3042,
  T3044, T3045, T3048 to T3056.
- **Edit the text:** T3037 (all four file modes), T3040 (measured cost; share
  through `DeviceCache` behind T3074, or release at slide end), T3043 (add
  PA-V26), T3046 (hero case is tile-sized), T3047 (12 assets, about 400 KB).
- **New, no new task needed:** PA-V25 into T3075 (or T3045), PA-V26 into
  T3043.
