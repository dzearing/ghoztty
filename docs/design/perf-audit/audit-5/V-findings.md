# Audit-5, area V: viewer panes (T3316)

- **Date:** 2026-11-28
- **Area:** V, viewer panes (`src/apprt/win32/ViewerPane*.zig`, WebView2
  hosting, viewer feedback, What's New, diff/git-status viewers, page assets,
  the viewer workers `ViewerDocumentRead`, `ViewerResourceServe`,
  `ViewerImageDecode`, and the files split out of the pane since audit-4:
  `viewer_pane_links.zig`, `viewer_toc_paint.zig`, `viewer_toc_place.zig`,
  `viewer_feedback_paint/_carousel/_composer/_focus.zig`, `viewer_image.zig`)
- **This is audit-5, a re-audit of `../audit-4/V-findings.md`.**
- **Commit audited:** 5eaac0760a (audit-4 was c9af15802)
- **Input:** `../audit-4/V-findings.md` (PA-V01 to PA-V36), `../audit-4.md`
  for the PA-to-task map, and the task files under
  `docs/design/windows-parity-tasks/`.
- **Baseline:** nothing was run. `scripts/perf-baseline.ps1` is unchanged since
  audit-4 (`-Phase viewer` at `:134`, `:1304`, `:1722`). Every cost below is
  marked quoted (from a task file), computed or inferred.

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor.

**Method.** Every verdict comes from reading the cited lines at HEAD
(5eaac0760a). No PA task in this area closed since audit-4, so there was no
fix commit to review; instead the source diff of every commit that touched the
area's Windows files since c9af15802 was read (table below), then the code
re-read at HEAD. Nothing was built, run or launched. Where a file is
byte-identical to c9af15802 the audit-4 line numbers are carried and the row
says "file unchanged". "High" means the cited lines were read at HEAD and the
mechanism traced; "medium" means the code was read but the verdict leans on a
measurement recorded in a task file that this audit did not repeat.

## What moved since audit-4

`git diff --stat c9af15802 HEAD` over `Viewer*`, `viewer*`, `webview2*`,
`WhatsNew*`, `git_run.zig`, `image_copy.zig`, `src/viewer`,
`gl_comp_present.zig`: 29 files, +5263 / -3950. Most of it is code moving
between files with no behaviour change: `ViewerPane.zig` is 13953 lines (was
14297) after its link routing moved to `viewer_pane_links.zig`;
`ViewerFeedbackBar.zig` and `ViewerTOCPanel.zig` were each split into
paint/place/composer/carousel/focus files. **Every ViewerPane line number
from audit-4 has moved**; all are re-cited below.

Unchanged since audit-4 (no diff): `ViewerFeedbackSend.zig`,
`ViewerFindBar.zig`, `ViewerDocumentRead.zig`, `ViewerResourceServe.zig`,
`ViewerImageDecode.zig`, `viewer_scratch.zig`, `viewer_feedback_images.zig`,
`viewer_process.zig`, `viewer_toc_comp.zig`, `viewer_watcher.zig`,
`viewer_suspend.zig`, `reload_gate.zig`, `hero_snap_schedule.zig`,
`worker_pool.zig`, `scripts/perf-baseline.ps1`.

| Commit | Task | What it did in area V | Perf effect |
|---|---|---|---|
| b05ed1d58d | T2635 | a viewer opening out of its strip is resized hidden, its page kept rendering under the hidden host (`renderHidden`), and captured at the new size (`exactSnapRequest`, up to 8 tries) | new GUI-thread decodes during the opening glide: PA-V37 |
| 02938fe529 | T1923 | the glass sheet is read out of the window's desk bitmap (`PaneDesk.cached`, borrowed) instead of evaluating the gradient per pixel | improvement to the paint PA-V09 left; no memory held by the pane |
| fd70fa3a90 | T1655 | a loopback poll tick that lands on a worker already answering the same question is dropped, not queued | improvement; lookups no longer chain |
| 7a9c944d95 | T3532 | a saved image keeps zoom and scroll (`image_previous`) | none (a few fields) |
| 93a5c88392 | T3587 | `viewer.js` restores scroll synchronously, plus once on the next frame | none (no timer, one rAF per render) |
| 1fa55ab92c | T3535 | `patch_scroll` carried from the request to the push | none |
| dfe50ede62 | T1909 | Ctrl+C at an image pane also publishes `CF_HDROP` (a path, not the bytes) | none |
| 5bb0018512 | T3436 | link routing and the link menu moved to `viewer_pane_links.zig` | none; PA-V12's link-click sites moved with it |
| 57dead4647, 0ec04d8c31 | T1784, T1781 | TOC card and feedback composer split across files | none; PA-V08 and PA-V19 cites moved |
| 8f50b16141 | (wheel) | owner-painted panels accumulate wheel deltas | none |
| 6bc96e8309, 50d86dcf03, f04aea8865, b8d2b61414, decba35cdc, f80c050bdc | T3417, T3416, T3415, T3410, T3361, T3331 | GTK port: `ViewerDiffProbe`, `git_run`, `viewer_document`, `viewer_content` made to compile on POSIX (`comptime is_windows` branches, a `Notify` callback beside the HWND post) | none on Windows; read, no Windows path changed |
| 17372d93cf, 131c5ee49a, 6a7bdc8aaa, 751f47bbfe | T2155, T1735, T2353, T2351 | test-only (`webview2.zig` pump deadline helpers, clipboard test locking) | none |

No task for a PA-V id changed status since audit-4. T3310 (V32), T3311 (V31),
T3312 (V33), T3313 (V35), T3314 (V36) were filed from audit-4 and are `todo`;
T3250 now names PA-V34. T3047 to T3056, T3075, T3145 to T3147 are still
`todo`.

## Verdicts

Cost kind is the audit that produced it: q = quoted from a task file,
c = computed, i = inferred.

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| V01 | **fixed** by 809ffdede (T3033) (high) | `scripts/perf-baseline.ps1:134`, `:1304`, `:1722` (file unchanged) | the `viewer` phase is still there | none; T3173, T3174, T3198, T3217, T3219 (coverage gaps) unchanged |
| V02 | **wrong** (medium; measurement is T3034's, q) | `webview2.zig:510-519`, `App.zig:3002` | the environment is still released only at app exit; T3034 measured the browser tree exiting by itself ~5 s after the last controller closes. The file's only change is test pump helpers | none; T3034 stays skipped |
| V03 | **fixed** by 336d1ad41 (T3035) (high) | `ViewerPane.zig:2084`, `:2137-2159`, `:2161-2166`, `:2182-2185`, `:2227-2234`, `:8232-8237`; `viewer_suspend.zig` (unchanged) | hide trims and arms the 30 s one-shot; the timer suspends; show restores. T2635's `renderHidden` (`:5746-5752`) calls `applySleep(true)` for an opening card and `setVisible` (`:2072-2084`) puts the pane back to sleep if it ends hidden, so the fix holds through the new path | none. The hole is still PA-V33 |
| V04 | **fixed** by f661522ef (T3036) (high) | `Window.zig:4397`; `ViewerPane.zig:6110-6122`, `:6132-6135`, `:8114-8121`, `:2087` | unchanged mechanism | none |
| V05 | **fixed** by 923dbe45d (T3037) (high) | `ViewerPane.zig:2118-2130`, `:2097-2104`, `:8239-8249`; `reload_gate.zig` (unchanged) | the debounce still ends in `fileSaved`; hidden returns `.owed` with no stat | none; Mac half T3199. The stat is PA-V34 |
| V06 | **fixed** by 1d7b2e7ba (T3038) (high) | `ViewerDiffProbe.zig:184`, `:559`, `:728`, `:897`; `ViewerPane.zig:2740-2746` | `out_unchanged` still ends an idle poll after one `git status`; the file's changes since audit-4 are POSIX branches and `patch_scroll` | none; Mac half T3201 |
| V07 | **fixed** by 4e50b9d80 (T3039) (high) | `ViewerPane.zig:2667-2682`, `:2700-2718`; `ViewerDiffProbe.zig:352` | one presized UTF-16 buffer; `defer probe.releasePatchBytes()` | none |
| V08 | **fixed** by e15858510 (T3040) (high) | `viewer_toc_comp.zig:135` (unchanged); `viewer_toc_place.zig:453`, `:533-544`, `:552-559`, `:566`; `src/renderer/gl_comp_present.zig:502` | the card's host moved to `viewer_toc_place.zig` with the T1784 split; it still takes `processDevice()` and both slide ends call `releaseComp` | none; T3219 unchanged |
| V09 | **fixed** by 663e4a850 (T3041) (high) | `ViewerPane.zig:7666-7703`, `:7740-7752`, `:7782-7813` | kept buffer, dirty rect only, page rect skipped. T1923 (02938fe529) then made the fill a read from the window's desk (`:7687-7693`) | none. What the fix keeps is PA-V32 |
| V10 | **wrong** as a leak; order corrected by b4655e962 (T3042) (medium) | `ViewerFindBar.zig:764-776` (file unchanged) | as audit-4 | none |
| V11 | **fixed** by 128e8e861 (T3043), with V26 (high) | `ViewerPane.zig:5057-5076`; `ViewerImageDecode.zig` (unchanged) | the `.wic` route parks the request and decodes on the worker | none |
| V12 | **fixed (incomplete)** by b44c4609e (T3044) + e41f7b840 (T3224) + 9619578eb (T3245) (high) | done: `ViewerPane.zig:4944-4949`, `:5304-5311`. Left on the GUI thread: `serveImage` browser route open+stat+read `:5081-5090`, icns `readFileAlloc` `:5102`, `stageImage` stat `:4637-4638`, link-click resolution now `viewer_pane_links.zig:251-253`, `:401-402` through `takeIfFile` (`ViewerPane.zig:5313-5325`) | nothing in the remainder moved except its file; cost i: one file-system round trip per event on a slow path; the browser route also reads the picture itself there (under 2 MB when staging is available, up to `max_file_bytes` = 32 MB when it is not) | T3250 (todo) unchanged; it already carries PA-V34 |
| V13 | **fixed** by bde0a487f (T3045) (high) | `ViewerDiffProbe.zig:289-293`; `git_run.zig` `Cancel` | cancel before join is intact; the POSIX branch added to `git_run` does not touch the Windows job path | none |
| V14 | **fixed (incomplete)**, as audit-4 (high) | `ViewerPane.zig:5898-5913`; `Window.zig:13868-13877` | `releaseSnapshot` now also clears `exact_want`; the in-flight early return is `:5906` | T3046 closed; remainder is PA-V27 (T3145) |
| V15 | still open (high; cost i) | `ViewerPane.zig:4944-4949`, `:5008`, `:5449`; `ViewerResourceServe.zig:137-147` (unchanged) | each asset is read from disk per request and answered `.default` (no cache header) | T3047 unchanged |
| V16 | still open (high; cost c) | `ViewerPane.zig:2728-2731`, `:2740`; `ViewerDiffProbe.zig:643-659` | `probe.snapshot(alloc)` (one alloc plus a dupe per path) still runs before `probe.complete()`, so every `.unchanged` 2 s poll pays it and uses none of it | T3048 unchanged; the audit-4 note (snapshot only for `.listing`) still applies |
| V17 | still open (high; cost i) | `ViewerPane.zig:1529`, `:2540`, `:8206-8230` | both repeating timers stay armed while hidden; only the work is gated | T3049 unchanged |
| V18 | still open (high; cost i) | `ViewerPane.zig:5648-5679`, `:5840`; `hero_snap_schedule.zig` (unchanged) | full-page PNG capture, decoded with `gdiplus_decode.decodeScaled` on the GUI thread | T3050 unchanged. T2635 adds a second caller of the same decode: PA-V37 |
| V19 | still open (high; cost c) | `viewer_feedback_paint.zig:88-96` (moved from `ViewerFeedbackBar.zig` by 0ec04d8c31), also `:213-217` | `Dib32.create` + `glassBand` + `destroy` per paint, unchanged by the move | T3051 unchanged; re-point its cite |
| V20 | still open (file unchanged) | `viewer_feedback_images.zig:55-56`, `:113-130` | the image `Store` has `add`, `find`, `deinit` and no remove | T3052 unchanged |
| V21 | still open (high) | `ViewerPane.zig:4129-4138` | `setTOCWidthLive` calls `updateTOC` per accepted move | T3053 unchanged |
| V22 | still open (high) | `ViewerPane.zig:1483`, `:1492`, `:1473-1476` | composer and find card are still built at pane create | T3054 unchanged |
| V23 | still open (high) | `ViewerPane.zig:3379-3380`, `:3414-3423`, `:6167-6172` | `adoptFrame` is still the only caller of `pruneFrames`; `resources_dir` resolved per pane | T3055 unchanged |
| V24 | still open (high) | `WhatsNewNotesView.zig:239-270` | full `renderer.render` per paint (`:264`); the file's only change is wheel accumulation | T3056 unchanged |
| V25 | still open (file unchanged) | `ViewerFeedbackSend.zig:208` | still `std.Thread.spawn`; the other six viewer workers use `worker_pool.spawn` | T3075 unchanged |
| V26 | **fixed** by 128e8e861 (T3043) (high) | `ViewerPane.zig:5057-5065` | the `.wic` branch returns before any file read | none |
| V27 | still open (high); **slightly wider** | `ViewerPane.zig:5906`, `:5860-5866` | `releaseSnapshot` still returns while a capture is in flight and the late answer is decoded and kept. T2635 added a second way in: `releaseSnapshot` clears `exact_want` (`:5904`), so an opening card's capture that lands after the glide passes the `exact_want` test at `:5845` as "no ask" and is kept at card size (c: w x h x 4 bytes until the next release) | T3145 unchanged (todo); add the T2635 path to it |
| V28 | still open (high) | `ViewerPane.zig:6958-6972` | `handleProcessFailed` reloads with no look at `self.visible`, after `wakeForWork` | T3146 unchanged (todo) |
| V29 | still open (inferred, as before) | `viewer_process.zig:61-65` (file unchanged) | `render_process_unresponsive` still spends a restart | T3147 unchanged (todo); still needs the on-box confirmation |
| V30 | still open (high) | `ViewerPane.zig:6981-6988`, `:7570-7583`, `:8206-8230` | `dropController` and `fail` kill no timer; a failed `git-status:` pane still runs 1 git per 2 s while visible | folded into T3049, unchanged |
| V31 | still open (high; cost i) | `ViewerPane.zig:1238-1255`; `ViewerDocumentRead.zig:162-166`, `ViewerResourceServe.zig:375-388`, `ViewerImageDecode.zig:373-376` (all three unchanged) | pane close still joins the three workers on the GUI thread with no cancel | T3311 (todo, P2) |
| V32 | still open (high; cost c) | `ViewerPane.zig:7709-7721`, `:2069-2105`, `:5902`, `:1095`, `:5530` | `glassPixels` still only grows (`n + n/4`); `setVisible(false)` still does not call `releaseGlassBuf`. T1923 changed how the buffer is filled, not how long it is kept | T3310 (todo, P2; = PA-M20) |
| V33 | still open (high; cost i) | `ViewerPane.zig:2138`, `:6287`, `:6270-6342` | `applySleep` returns before touching the gate when there is no controller; `adoptController` sets `c.setVisible(self.visible)` and never calls `applySleep`. The only callers are `:2084` and `:5750` | T3312 (todo, P3) |
| V34 | still open (high; cost i) | `ViewerPane.zig:2110-2114`, `:2121`, `:2099`, `:2511`, `:4401`, `:2459` + `:2473-2476` | `fileStamp` and `isReadableFile` are synchronous `statFile` calls on the GUI thread | T3250 (todo) names it |
| V35 | still open (high; cost c) | `ViewerPane.zig:6307`, `:4701-4706`, `:1258-1261`; `viewer_scratch.zig` (unchanged) | every pane claims a scratch folder at adopt and deletes the tree at close; the first also sweeps, all on the GUI thread | T3313 (todo, P3) |
| V36 | still open (high; cost c) | `ViewerPane.zig:4629-4646`; `ViewerImageDecode.zig:144-149` (unchanged); `viewer_content.zig:742`, `:748` | a 2 MB to 512 MB browser-route picture is `copyFile`d into `%TEMP%` per revision | T3314 (todo, P3) |

**Totals for V01 to V36:** 11 fixed (V01, V03 to V09, V11, V13, V26), 2 fixed
(incomplete) (V12, V14), 21 still open (V15 to V25, V27 to V36), 0 changed,
2 wrong (V02, V10). Nothing closed since audit-4. V27 is marked open, not
changed: its mechanism is the same and one more caller reaches it.

## Fix-commit review

No PA-V task closed since audit-4, so there is no fix commit to review. The
feature commits in the table above were read for regressions instead:

| Commit | Task | What it left or introduced | Finding |
|---|---|---|---|
| b05ed1d58d | T2635 | each capture an opening card rejects as "old layout" is fully decoded and scaled on the GUI thread before its size is looked at; up to 8 in a row | PA-V37 |
| b05ed1d58d | T2635 | `releaseSnapshot` clearing `exact_want` lets a late opening capture be kept | folded into PA-V27 |

Read and found without a regression: 02938fe529 (T1923), fd70fa3a90 (T1655),
7a9c944d95 (T3532), 93a5c88392 (T3587), 1fa55ab92c (T3535), dfe50ede62
(T1909), 5bb0018512 (T3436), and the Windows side of the GTK-port commits.
The two notes audit-4 left on 1d7b2e7ba (T3038, fingerprint over
`listing_cap`) and e15858510 (T3040, a DComp host per slide) still stand
unchanged.

## New findings

| PA | Pri | Where | Cost | Fix |
|---|---|---|---|---|
| V37 | P3 | `ViewerPane.zig:5840-5859`, `:5706`, `:5715-5732`; `gdiplus_decode.zig:177-209`; `Window.zig:13715-13723` | a viewer opening out of its strip can decode and scale up to 8 full-page PNG captures on the GUI thread during the glide, 7 of them thrown away (inferred: one pane-sized PNG decode + scale each, the cost PA-V18 describes, inside an animation) | read the capture's size before decoding it |

### PA-V37: an opening card decodes every capture it is about to reject (P3)

Introduced by b05ed1d58d (T2635). Not a regression of a perf fix; a new
feature that reuses PA-V18's expensive path where frames matter most.

A viewer pane opening out of its strip is now placed at its slot's size while
hidden (`Window.zig:13265-13272`, `PaneView.setOpeningAwake`,
`PaneView.zig:634-643`), its page kept rendering under the hidden host
(`renderHidden`, `ViewerPane.zig:5746-5752`), and asked for a capture of the
page laid out at that size (`askOpeningFrame`, `Window.zig:13715-13723`, to
`exactSnapRequest`, `ViewerPane.zig:5715-5732`).

`CapturePreview` answers with whatever the page last painted, so the first
answers can still be of the old layout. `onCapturePreviewCompleted` handles
that at `:5840-5859`:

1. `gdiplus_decode.decodeScaled(stream, snap_w, snap_h)` (`:5840`) decodes the
   whole PNG (`GdipCreateBitmapFromStream`, then
   `GdipCreateHBITMAPFromBitmap`, `gdiplus_decode.zig:182-198`) and scales it
   into a new DIB at card size (`scaleInto`, `:205`).
2. Only then is the capture's own size compared with the size asked
   (`exactFits(want.w, want.h, thumb.src_w, thumb.src_h)`, `:5845`).
3. A misfit deletes the DIB just built (`:5846`) and, while
   `exact_tries < exact_max_tries` (8, `:5706`), starts the next capture from
   inside the completion (`:5850-5856`) with no pacing.

`decodeScaled` already knows `src_w`/`src_h` at `gdiplus_decode.zig:193-195`,
before the pixel decode at `:198`. So every rejected capture pays a full
decode, an HBITMAP, a scale and a DIB for nothing, on the GUI thread, while
the glide the capture is for is animating. The browser also paints and
PNG-encodes each one.

**Cost (inferred, not run):** per rejected try, one pane-sized PNG decode plus
scale on the GUI thread: the per-capture cost PA-V18 (T3050) names for the
hero tile, which the scheduler there spaces a second apart because it competes
with interaction. Here up to 7 can run back to back inside a glide of a few
hundred milliseconds. Bounded (8 per opening, one opening per user action), so
it cannot grow; it shows up as dropped frames in the opening animation, which
is the thing T2635 set out to smooth. How many tries a real opening needs is
not recorded in T2635's task file; the debug line at `:5847` (`viewer exact
frame misfit ... try=`) would say.

**Fix:** split the size probe from the decode. Give `gdiplus_decode` a
`sizeOf(stream)` (or a `decodeScaledIf(stream, w, h, accept)` taking a
predicate on the source size) that stops after `GdipGetImageWidth/Height`, and
call it before `decodeScaled` when `exact_want` is set. A rejected capture
then costs the PNG header. Optionally wait one frame before re-asking rather
than re-asking from the completion. **Risk:** low; the accepted capture takes
the same path as today.

**Priority:** P3. User-visible only as animation smoothness on one gesture,
and bounded.

**Cross-area overlap:** the GUI-thread decode is PA-V18's; the glide it runs
inside belongs to whichever area audits the pane-strip slide
(`pane_stack_slide`, `Window.armGlideSnaps`). If that area reports "opening
glide stalls on a viewer card" it is this finding.

**Task action:** new task, P3; or add to T3050 (PA-V18), whose fix (decode off
the GUI thread) would cover it.

## Checked and found clean

- **`renderHidden` does not strand an awake page.** `placeGrid` calls either
  `setOpeningAwake` or `setVisible(shown)` for every placed pane on every pass
  (`Window.zig:13272`); `setVisible` clears `render_hidden` first and, for a
  pane that was rendering hidden and ends hidden, still reaches the controller
  and `applySleep(false)` (`ViewerPane.zig:2072-2084`). A second
  `renderHidden` while already rendering returns at `:5747`.
- **`exactSnapRequest` is asked once per size**, not per frame
  (`Window.zig:13719`), and returns before any capture while the page's bounds
  have not followed the window (`ViewerPane.zig:5717-5721`).
- **T1923's desk read borrows.** `glass_desk` is a pointer to the window's
  `PaneDesk` (`ViewerPane.zig:767`), `cached()` returns a view of the bitmap
  the window already holds and renders nothing; a region the desk does not
  cover falls back to the evaluated gradient (`:7687-7693`). No per-pane copy.
- **T1655's drop** keeps `dirty` from an earlier different question, so a
  navigation during a lookup is still re-asked; only the same-question tick is
  dropped.
- **T3587's scroll restore** in `viewer.js` adds no timer or observer: one
  synchronous `scrollTo` and one `requestAnimationFrame` per render, guarded
  by a generation counter.
- **T1909's file copy** puts a `DROPFILES` path list on the clipboard, not the
  file's bytes.
- **The POSIX branches** in `ViewerDiffProbe.zig` and `git_run.zig` are
  `comptime is_windows` splits; the Windows job-object and `PostMessage` paths
  are the audit-4 ones.
- Everything audit-4 listed as clean was re-read where its file changed
  (`wakeForWork` `:2227-2234`, the three hidden gates `:2121`, `:8228`,
  `:8213`, document generation `:2493`) and still holds.

**Not covered** (same gaps as audit-4, plus the splits): the page-side cost of
`diff.js`, `image.js` and `viewer.js` beyond the diffs read; `ViewerFeedbackWeb`
beyond create/close; `viewer_feedback_report/_doc/_acc/_a11y/_layout`; the
moved bodies of `viewer_feedback_composer/_carousel/_focus.zig`,
`viewer_toc_paint/_place.zig` and `viewer_pane_links.zig` outside the cited
sites (they were treated as moves, checked at the PA sites only);
`screen_capture.zig`; `banner_markdown.zig`; `src/apprt/gtk/` (out of scope
for Windows). `baseline-4.json` was not read.

## Summary

- **Fixed (all rounds):** 13 of 36. Eleven complete: V01 (809ffdede, T3033),
  V03 (336d1ad41, T3035), V04 (f661522ef, T3036), V05 (923dbe45d, T3037),
  V06 (1d7b2e7ba, T3038), V07 (4e50b9d80, T3039), V08 (e15858510, T3040),
  V09 (663e4a850, T3041), V11 and V26 (128e8e861, T3043), V13 (bde0a487f,
  T3045). **None of these closed since audit-4**; all were re-verified at HEAD.
- **Incomplete:** 2. V12 (remainder T3250, with PA-V34), V14 (remainder
  PA-V27, T3145).
- **Still open:** 21 (V15 to V25, V27 to V36).
- **Changed:** 0. (V27 gains one caller from T2635; V19's and V12's cites
  moved files.)
- **Wrong:** 2 (V02, V10), as audit-4.
- **New:** 1 (V37, P3, from b05ed1d58d T2635).

**Task actions:**

- New task: PA-V37 (P3), or fold into T3050.
- T3145 (PA-V27): add the T2635 late-capture path (`ViewerPane.zig:5904`,
  `:5845`).
- T3051 (PA-V19): the cite is now `viewer_feedback_paint.zig:88-96`.
- T3250 (PA-V12 remainder): the link-click sites are now
  `viewer_pane_links.zig:251-253`, `:401-402`.
- No change: T3047 to T3050, T3052 to T3056, T3075, T3146, T3147, T3310 to
  T3314.

**Open P0/P1 in area V:** none. Open work is P2 (T3047 to T3056, T3075,
T3145 to T3147, T3250, T3310, T3311) and P3 (T3312, T3313, T3314, PA-V37).
