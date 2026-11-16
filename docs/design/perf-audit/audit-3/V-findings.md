# Audit-3, area V: viewer panes (T3101)

- **Date:** 2026-11-15
- **Area:** V, viewer panes (`src/apprt/win32/ViewerPane*.zig`, WebView2
  hosting, viewer feedback, What's New, diff/git-status viewers, page assets)
- **This is audit-3, a re-audit of `../audit-2/V-findings.md`.**
- **Commit audited:** d0d874326 (audit-2 was 879fba35a)
- **Baseline:** still none for viewers. `scripts/perf-baseline.ps1` grew by
  about 600 lines (T2989, T3005) and its phases are still idle, busy, cycle
  and agent (`:92`, `:815`); the words "viewer" and "webview" do not occur in
  it. Every cost below is an estimate unless it says otherwise.

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor.

**Method.** Every verdict comes from reading the cited lines at HEAD. Nothing
was built, run or launched. Where a file is byte-identical to 879fba35a
(`git diff` empty) the audit-2 line numbers are carried and were spot-read;
those rows say "file unchanged". "Confidence high" means the cited lines were
read at HEAD and the mechanism traced.

## What moved since audit-2

`git diff --stat 879fba35a HEAD` over `Viewer*`, `viewer*`, `webview2*`,
`WhatsNew*`, `whats_new*`, `git_run.zig`, `ipc_whats_new.zig`, `src/viewer`,
`worker_pool.zig`, `hero_snap_schedule.zig`:

```
src/apprt/win32/ViewerPane.zig     | 248 +++
src/apprt/win32/viewer_process.zig | 131 +++   (new file)
src/apprt/win32/webview2.zig       |  15 +
src/apprt/win32/webview2_iface.zig |  54 +-
```

Two commits did that:

| Commit | Task | What it did in area V |
|---|---|---|
| 40297c800 | T3001 (an R/W-area task) | `ViewerPane.releaseSnapshot` (`ViewerPane.zig:5523-5531`), called through `PaneView.releaseSnapshot` (`PaneView.zig:535-540`) from `Window.releaseIdleSnapshots` (`Window.zig:12891-12900`) and `endRearrangeDrag` (`Window.zig:6325-6326`). **Fixes PA-V14 as a side effect.** |
| 546a81b1c | T3107 (a Mac-parity port, not a perf task) | subscribes to WebView2 `ProcessFailed`; a dead or hung renderer is reloaded at most 3 times a minute, past that the controller is closed and the error card shows. New file `viewer_process.zig`; +122 lines in `ViewerPane.zig` plus a live test. |

Everything else in the area is byte-identical to audit-2: `ViewerDiffProbe`,
`ViewerWorktreeProbe`, `ViewerFeedback*`, `ViewerFindBar`, `ViewerNavBar`,
`ViewerTOCPanel`, `viewer_toc_comp`, `viewer_watcher`, `viewer_feedback_images`,
`WhatsNew*`, `git_run.zig`, `src/viewer/*`. No V task closed: T3033 to T3056,
T3074 and T3075 are all `status: "todo"`.

**Line shifts in `ViewerPane.zig`** (audit-2 line to HEAD line): +7 from 191,
+18 from about 438, +22 from 950, +36 from 5497, +37 from 5832, +115 from
6443, +122 from 7477. `Window.zig` moved by 424 lines; its two cited sites are
re-found below. `webview2.zig` moved +15 after line 95.

## Verdicts

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| V01 | still open (high) | `scripts/perf-baseline.ps1:92`, `:815` | phases are `idle`, `busy`, `cycle`, `agent`; no viewer phase; T2989 and T3005 added thread and leak attribution to the existing phases only | T3033 unchanged |
| V02 | still open (high) | `webview2.zig:510-518`, `:527-548`, `App.zig:2848` | `Host.deinit` holds the only `env.release()`; its only caller is app teardown; `request` never returns to `.idle` | T3034 unchanged |
| V03 | still open (high) | `ViewerPane.zig:1853-1870` | `setVisible` does `c.setVisible`, `ShowWindow`, and the diff catch-up; no `TrySuspend`, no memory-usage target level | T3035 unchanged; see PA-V28 for a new interaction |
| V04 | still open (high) | `Window.zig:4055`, `:4483-4485` | `viewer.start(alloc, &self.app.webview2_host)` is unconditional; the doc comment still says fresh surfaces start visible and a rebuilt background tab must hide them | T3036 unchanged |
| V05 | still open, as audit-2 widened it (high) | `ViewerPane.zig:7576-7579`, `:7668-7676`, `:4461-4476`, `:4539-4541`, `:4550` | the debounce timer calls `reloadContent(.file_changed)`; that dispatches on `content.reloadPlan` with no visibility, size or mtime check; image mode goes to `startImage`, text modes read the whole file | T3037 unchanged |
| V06 | still open (high) | `ViewerPane.zig:244`, `:2183-2187`; `ViewerDiffProbe.zig:540-625`, `:645-683`, `:762-770` (file unchanged) | 2000 ms poll, 6 git spawns per tick, untracked files read whole | T3038 unchanged; PA-V30 adds one case |
| V07 | still open (high) | `ViewerPane.zig:2318-2332`, `:4751-4762`; `viewer_diff.zig:640-658`, `ViewerDiffProbe.zig:47`, `:449` (files unchanged) | UTF-8 call built, then widened whole in `executeScript`; `self.patch = job.out_patch` kept | T3039 unchanged |
| V08 | still open, as audit-2 changed it (high) | `viewer_toc_comp.zig:123-168`, `ViewerTOCPanel.zig:1178-1184`, `:1271`, `:1285`, `:404` (files unchanged); `src/renderer/gl_comp_present.zig:393-443` | own D3D11 + DComp device per pane, kept until `destroy`; `var device_cache` is still file-private (`:443`), T3074 still todo | T3040 unchanged |
| V09 | still open (high) | `ViewerPane.zig:7236-7243` | `Dib32.create` + `defer dib.destroy()` + whole-client `glassSheetRegion` per paint | T3041 unchanged |
| V10 | still open (inferred, as before) | `ViewerFindBar.zig:764-766`, select at `:746` (file unchanged) | `DeleteObject(card_bmp)` before `DeleteDC(card_dc)`, bitmap still selected | T3042 unchanged; still needs the GDI-count run |
| V11 | still open, with V26 (high) | `ViewerPane.zig:4957-4963`, `:4896`, `:4916-4920`, `:5148-5151` | decode to BGRA, DIBV5 copy, BMP copy, then `stream.writeAll` into an HGlobal | T3043 unchanged |
| V12 | still open (high) | `ViewerPane.zig:4844-4860`, `:4896`, `:5041-5061`, `:5148-5151`, `:4550`, `:5006`; `viewer_range.zig:27` | `readFileAlloc` / `readToEndAlloc` then `writeAll`, all in the resource handler on the GUI thread; `max_chunk` 8 MB | T3044 unchanged |
| V13 | still open (high) | `ViewerPane.zig:1052-1064`; `ViewerDiffProbe.zig:222-226`, `ViewerWorktreeProbe.zig:195-199`, `ViewerFeedbackSend.zig:155-159`, `git_run.zig:39` (files unchanged) | pane `deinit` calls three `deinit`s that join with no cancel | T3045 unchanged |
| V14 | **fixed (incomplete)** by 40297c800 (T3001) (high) | `ViewerPane.zig:5523-5531`; `Window.zig:12891-12900`, `:12922`, `:8068`, `:8838`, `:6325-6326` | the DIB is now deleted when a glide lands (every tab), when the hero heartbeat is stopped, and when a drag ends. What remains: a capture still in flight at that moment is skipped (`:5524`) and nothing frees its picture when it lands. That is PA-V27 | **close T3046** against 40297c800; the remainder is PA-V27 |
| V15 | still open, audit-2's numbers (high) | `ViewerPane.zig:4844`, `:4851-4860`, `:5157-5160`; `src/viewer/viewer.html:8-22` (unchanged) | each asset read from disk per request and answered with `.default` caching, which adds no header | T3047 unchanged |
| V16 | still open (high) | `ViewerPane.zig:2341-2342`; `ViewerDiffProbe.zig:604-616` (unchanged) | `probe.snapshot(alloc)` on every completion | T3048 unchanged |
| V17 | still open (high) | `ViewerPane.zig:2168`, `:1313`, `:7648`, `:7663` | both repeating timers stay armed while hidden; only the work is gated | T3049 unchanged |
| V18 | still open (high) | `ViewerPane.zig:5446`, `:5484`; `hero_snap_schedule.zig:58-63` (unchanged) | full-page PNG capture, at most one per 1000 ms per viewer, decoded on the GUI thread in the completion | T3050 unchanged |
| V19 | still open (file unchanged) | `ViewerFeedbackBar.zig:1862-1870` | `Dib32.create` + `glassBand` + `destroy` per paint | T3051 unchanged |
| V20 | still open (file unchanged) | `viewer_feedback_images.zig:55-56`, `:113-130`, `ViewerFeedbackSend.zig:255-258` | the image `Store` has no remove | T3052 unchanged |
| V21 | still open (high for the pane half) | `ViewerPane.zig:3734-3744`; `ViewerTOCPanel.zig:2274-2290`, `:939-941`, `ViewerFindBar.zig:770-779`, `:561-563`, `:537-551` (unchanged) | `setTOCWidthLive` calls `updateTOC` per accepted move | T3053 unchanged |
| V22 | still open (high) | `ViewerPane.zig:1266-1280` | `ViewerFeedbackBar.create` and `ViewerFindBar.create` at pane create | T3054 unchanged |
| V23 | still open (high) | `ViewerPane.zig:2985`, `:3019`, `:5739-5746` | `adoptFrame` is the only caller of `pruneFrames`; `resources_dir` is resolved per pane | T3055 unchanged |
| V24 | still open (file unchanged) | `WhatsNewNotesView.zig:252-268` | full `renderer.render` from `-self.scroll` per paint | T3056 unchanged |
| V25 | still open (high) | `ViewerFeedbackSend.zig:202` (unchanged) | `std.Thread.spawn(.{}, work, .{ self, job })` | T3075 unchanged (still todo) |
| V26 | still open (high) | `ViewerPane.zig:4896`, `:4916-4920`, `:4929`, `:4957-4958` | whole file read before the route switch; `.wic` decodes from the path; the buffer is used only for a 32-byte sniff on failure | T3043 unchanged |

**Totals:** 1 fixed (V14, incomplete), 25 still open, 0 changed, 0 wrong.

## Changed items

None. V05, V08, V11 and V15 keep the shape audit-2 gave them; only their
`ViewerPane.zig` line numbers moved, re-cited above.

## Fix-commit review

### 40297c800 (T3001): snapshot release

Read: `ViewerPane.releaseSnapshot` (`:5523-5531`), `deinitHeroSnap`
(`:5535-5542`), `onCapturePreviewCompleted` (`:5460-5503`),
`Window.releaseIdleSnapshots` (`:12891-12900`), its three callers, and
`heroOnSnapReady` (`Window.zig:8142-8186`).

- **What it does right.** The DIB is deleted and all five fields are cleared,
  so the paint paths that read `snap_dib` (`PaneView.zig:452`) see "no
  picture" and the next request captures afresh. Hero tabs, panes still
  carrying a glide frame and the dragged pane are skipped. No allocation, lock
  or per-frame work was added: the release is one walk over a tab's leaves at
  the end of a glide, a hero exit or a drag.
- **Hole: the in-flight capture.** That is PA-V27 below.
- **No regression seen.** `snap_dirty = false` cannot swallow a wanted
  picture: the function only runs when nothing reads the DIB.

### 546a81b1c (T3107): reload a page whose process failed

Read: `onProcessFailed` (`ViewerPane.zig:6508-6524`), `handleProcessFailed`
(`:6527-6546`), `dropController` (`:6549-6556`), `subscribeProcessFailed`
(`:6491-6506`), `fail` (`:7138-7151`), all of `viewer_process.zig`, and the
`webview2_iface.zig` vtable change (slot 25, covered by the offset test).

- **Steady-state cost: none.** One more COM handler per pane (freed in
  `deinit`, `:968-971`), a 3-entry stamp array, and no work until the event
  fires. The handler itself does a fixed-size decision and one `PostMessage`.
- **Three new costs, all on the failure path:** PA-V28 (a hidden pane's
  renderer is respawned at once), PA-V29 (an unresponsive renderer is treated
  as a dead one), PA-V30 (a pane that gave up keeps its git poll). Details
  below.
- **Not a perf matter, noted for the owner:** after `.browser_gone` the shared
  `Host` still reports `.ready` with the same environment (`webview2.zig:528-531`),
  so "Reopen this pane" relies on the environment starting a new browser
  process. Not checked on a box.

## New findings

| PA | Pri | Where | Cost | Fix |
|---|---|---|---|---|
| V27 | P2 | `ViewerPane.zig:5524`, `:5484-5490`; `Window.zig:8163` | one pane-size DIB (5 MB at 1400x900, 33 MB at 4K, computed) kept until the next glide, hero exit or drag on that tab, or pane close | drop a capture that lands unwanted, without decoding it |
| V28 | P2 | `ViewerPane.zig:6527-6540` | a hidden pane whose renderer was killed gets a new renderer and a full re-render immediately (inferred: tens of MB and the page's load cost, per hidden pane) | defer the reload to `setVisible(true)` |
| V29 | P2 | `viewer_process.zig:61-65`; `ViewerPane.zig:6514-6522` | a slow page is restarted up to 3 times and then closed (inferred from WebView2's documented behaviour; not run) | do not reload on `render_process_unresponsive` |
| V30 | P2 | `ViewerPane.zig:6549-6556`, `:2183-2187`, `:7651-7665` | a visible `git-status:` pane that gave up keeps running 6 git processes every 2 s for a page that no longer exists (computed from PA-V06) | kill the pane's repeating timers in `dropController` / `fail` |

### PA-V27: a snapshot that lands after the release is never given back (P2)

`releaseSnapshot` returns at once when a capture is in flight
(`ViewerPane.zig:5524`, `if (self.snap_in_flight_since_ms != null) return;`).
The comment says the capture "is left to land". When it lands,
`onCapturePreviewCompleted` decodes it at `snap_w` x `snap_h` on the GUI
thread and stores it in `snap_dib` (`:5484-5490`), then posts
`WM_APP_HERO_SNAP`. `Window.heroOnSnapReady` finds no drag waiting, the tab
not in hero mode and `glide_snap == .none`, and returns (`Window.zig:8163`).
Nothing calls `releaseSnapshot` again for that pane until the next glide
lands, hero mode next ends, or a drag next ends on that tab.

Three ways in, all read in the code:

1. **A drag that ends before its ghost picture arrives.** `glideSnapRequest`
   is asked at pane size when the ghost is first shown (`Window.zig:7410`,
   `ghost_waiting = true`). A short drag ends in `endRearrangeDrag`
   (`:6325-6326`) while the browser is still painting and encoding the page.
2. **A fold or unfold whose capture is slower than the glide.** `endStackSlide`
   releases every tab (`:12922`) when the glide lands, whether or not the
   viewer's frame arrived.
3. **Hero exit within the capture window.** A viewer tile is re-captured about
   once a second; leaving hero mode while one is out skips the release. This
   one is tile-sized, so it is small.

A second, rarer shape: a capture that never answers leaves
`snap_in_flight_since_ms` set for good (only a new request clears it,
`:5372`, `:5398`), so every later release of that pane returns early and an
older DIB stays pinned.

**Cost (computed):** `w * h * 4` bytes of GDI DIB per affected viewer: 5 MB at
1400x900, 33 MB for a 4K pane (the same figures 40297c800's message uses,
halved because a viewer has no landing buffer). Plus the wasted PNG decode on
the GUI thread for a picture nobody shows. Bounded: one picture per pane,
freed by the next release event or by closing the pane.

**Fix:** in `releaseSnapshot`, when a capture is in flight, bump `snap_gen`
(the completion already drops a stale generation at `:5462-5467` before it
decodes), release the stream and clear `snap_in_flight_since_ms`, then free
the DIB as now. That removes both shapes and saves the decode. **Risk:** low;
`glideSnapRequest` and `heroSnapRequest` start a new capture when they next
need one.

**Task action:** new task, or reopen T3001 with this as its remainder.

### PA-V28: a hidden pane's dead renderer is respawned at once (P2)

`handleProcessFailed` (`ViewerPane.zig:6527-6540`) calls `web.reload()` for
`.reload` with no look at `self.visible`. A renderer the OS killed for memory
is most likely to belong to a pane nobody is looking at (PA-V03: a hidden
viewer keeps its full renderer). The reload starts a new renderer process and,
through `NavigationCompleted`, re-reads and re-renders the file, so the memory
the system just took back is re-committed for a hidden page.

**Cost (inferred):** one renderer process and one full page load per hidden
viewer whose renderer died, at the moment the box is short of memory. With N
hidden viewers killed together, N reloads on the GUI thread's resource handler
(PA-V12) in a row.

**Fix:** when `!self.visible`, record "reload owed" (and keep
`page_loaded = false`, already set at `:6520`), and do the reload from
`setVisible(true)` next to the diff catch-up (`:1866-1869`). The restart
budget should be spent when the reload runs, not when it is owed. **Risk:**
a hidden pane's hero thumbnail or fold frame would be blank until shown;
reload on a snapshot request as well if that matters.

**Task action:** new task; `deps` none. Fits beside T3035 (PA-V03), which
changes the same function.

### PA-V29: a renderer that is only slow is reloaded, three times, then closed (P2, inferred)

`Budget.decide` (`viewer_process.zig:61-65`) treats
`render_process_unresponsive` exactly like `render_process_exited`: spend a
restart and return `.reload`. `onProcessFailed` (`ViewerPane.zig:6514-6522`)
then clears `page_loaded` and posts the reload.

What the code cannot show, and this finding rests on: WebView2 documents
`RENDER_PROCESS_UNRESPONSIVE` as raised for a long-running script or a busy
system, and raised again every few seconds until the renderer answers. If
that holds on the installed runtime, a page that is merely slow (an 8 MB diff
being highlighted, PA-V07; a 32 MB markdown file; any site with a long task
while the box is loaded) is reloaded mid-work, starts the same work again, and
after three reports inside a minute the controller is closed with "This page
keeps crashing". Mac's counterpart
(`webViewWebContentProcessDidTerminate`) fires only for a process that is
gone, so this half is not a port of Mac behaviour.

**Cost (inferred, not run):** up to 4x the page's load work followed by a
dead pane, for exactly the pages that are already the slowest.

**Fix:** return `.ignore` for `render_process_unresponsive` (the page is
still alive and may finish), or reload only after the report has repeated for
a long, fixed time. **Risk:** a truly hung page stays hung until the user
reloads, which is the pre-T3107 behaviour for that case only.

**Confirm first:** open a viewer on a page with a 30 s busy loop and read the
log for `process failed (kind=2)`. If the event does not fire for a script
that later finishes, close this as wrong.

**Task action:** new task (bug-shaped; perf is the smaller half).

### PA-V30: a pane that gave up on its page keeps polling git (P2)

`dropController` (`ViewerPane.zig:6549-6556`) closes and releases the
controller and calls `fail`, which sets `state = .failed` and repaints
(`:7138-7151`). Neither kills `diff_timer_id` or `worktree_timer_id`. The
diff tick (`:7651-7665`) is gated on `self.visible` only, and `pollDiff`
(`:2183-2187`) checks the probe and the mode, not the state or the controller.
So a visible `git-status:` pane showing the "keeps crashing" card goes on
spawning PA-V06's six git processes every two seconds; each completion's
scripts go to a controller that is null.

The same was already true of a pane whose WebView2 never started (no runtime
installed); T3107 adds two ordinary ways to reach the state.

**Cost (computed from PA-V06):** 6 process spawns per 2 s per such pane, for
as long as it stays open and visible. Bounded by how rare the state is.

**Fix:** `KillTimer` both repeating timers in `fail` (it is the one place
every "no web view" path goes through), and stop the file watcher there too.
**Risk:** none seen; nothing restarts a failed pane in place.

**Task action:** fold into T3049 (PA-V17, the same two timers) or T3038.

## Checked and found clean

- **`viewer_process.zig`** is pure, allocation-free, and bounded: a
  3-element array compacted in place per event.
- **The new handler does not close the controller under its own `Invoke`:**
  it posts `WM_APP_VIEWER_PROCESS_FAILED` and the close happens from the
  message loop (`:7593-7597`).
- **`ProcessFailed` handler lifetime:** created with a borrowed `Pending`
  reference and released on the add-failure path (`:6500-6504`) and in
  `deinit` (`:968-971`); no leak on either path.
- **T3001's release walk** runs once per glide end over every tab
  (`Window.zig:12910-12923`) and once per hero exit or drag end; it is not on
  a per-frame path.
- **Hero tiles while hero mode is on** are kept, by design
  (`releaseIdleSnapshots` returns for a hero tab, `:12892`); they are
  tile-sized (`ViewerPane.zig:5484`).

**Not covered** (same gaps as audit-2): the page-side cost of `diff.js`,
`image.js` and `viewer.js`; `ViewerFeedbackWeb` beyond create/close;
`viewer_feedback_report/_doc/_acc/_a11y/_layout`; `screen_capture.zig`;
`banner_markdown.zig`; message handlers in `ViewerPane.zig` outside the cited
ranges; and every runtime number, which waits on PA-V01 (T3033).

## Summary

- **Fixed:** 1 (V14, by 40297c800 / T3001; incomplete, remainder is PA-V27).
- **Still open:** 25 (V01-V13, V15-V26).
- **Changed:** 0. **Wrong:** 0.
- **New:** 4 (V27-V30), all P2, all from the two commits that touched the
  area.

**Task actions:**

- Close T3046 (PA-V14) against 40297c800.
- New tasks: PA-V27 (late snapshot), PA-V28 (hidden reload), PA-V29
  (unresponsive reload; confirm on a box first).
- Fold PA-V30 into T3049.
- No change: T3033-T3045, T3047-T3056, T3074, T3075.

**Open P0/P1 in area V** (priorities read from each task file's `priority:`;
this pass changed none). No P0. P1, thirteen open:

- PA-V01 (T3033): no viewer phase in the baseline; blocks every measured number
- PA-V02 (T3034): the WebView2 environment is never released
- PA-V03 (T3035): a hidden viewer keeps its full renderer
- PA-V04 (T3036): background-tab viewers start their web view
- PA-V05 (T3037): hidden live-reload, all four file modes
- PA-V06 (T3038): six git spawns per 2 s poll
- PA-V07 (T3039): diff patch copied and widened whole, and kept
- PA-V08 (T3040): a D3D11 + DComp device per contents card
- PA-V09 (T3041): pane-size DIB and glass sheet per paint
- PA-V10 (T3042): find-card bitmap deleted while selected (inferred)
- PA-V11 (T3043, with V26): image transcode copies
- PA-V12 (T3044): whole-file reads in the resource handler on the GUI thread
- PA-V13 (T3045): pane close joins git workers with no cancel

T3046 (PA-V14) is also P1 and is the one this pass says to close. T3047 to
T3056 (V15-V24) are P2.
