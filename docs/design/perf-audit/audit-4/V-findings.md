# Audit-4, area V: viewer panes (T3151)

- **Date:** 2026-11-21
- **Area:** V, viewer panes (`src/apprt/win32/ViewerPane*.zig`, WebView2
  hosting, viewer feedback, What's New, diff/git-status viewers, page assets,
  and the new viewer workers `ViewerDocumentRead`, `ViewerResourceServe`,
  `ViewerImageDecode`)
- **This is audit-4, a re-audit of `../audit-3/V-findings.md`.**
- **Commit audited:** c9af15802 (audit-3 was d0d874326)
- **Baseline:** there is now a viewer phase. `scripts/perf-baseline.ps1`
  accepts `-Phase viewer` (`:134`, `:1304`) and opens a markdown, a
  `git-status:` and a website viewer (`:1722-1723`), with shown, hidden and
  after-close spans (`:83-87`). Numbers quoted below come from task files that
  ran it; this audit ran nothing. Every other cost is marked computed or
  inferred.

**Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor.

**Method.** Every verdict comes from reading the cited lines at HEAD
(c9af15802). For each task closed since audit-3 the fix commit's source diff
was read (`git show <commit> -- src`), then the same code was re-read at HEAD.
No fix is claimed from a commit message. Nothing was built, run or launched.
Where a file is byte-identical to d0d874326 the audit-3 line numbers are
carried and were spot-read; those rows say "file unchanged". "High" means the
cited lines were read at HEAD and the mechanism traced; "medium" means the
code was read but the verdict leans on a measurement recorded in a task file
that this audit did not repeat.

## What moved since audit-3

`git diff --stat d0d874326 HEAD` over `Viewer*`, `viewer*`, `webview2*`,
`WhatsNew*`, `git_run.zig`, `src/viewer`, `worker_pool.zig`,
`hero_snap_schedule.zig`, `gl_comp_present.zig`, `perf-baseline.ps1`:
23 files, +5332 / -390. `ViewerPane.zig` alone is +1381 and is now 14297
lines. Eight new files: `ViewerDocumentRead.zig`, `ViewerResourceServe.zig`,
`ViewerImageDecode.zig`, `viewer_document.zig`, `viewer_scratch.zig`,
`viewer_slow_path.zig`, `viewer_suspend.zig`, `reload_gate.zig`.

Unchanged since audit-3: `webview2.zig`, `ViewerFeedbackBar.zig`,
`viewer_feedback_images.zig`, `WhatsNewNotesView.zig`,
`hero_snap_schedule.zig`, `viewer_process.zig`, `viewer_watcher.zig`,
`src/viewer/*`.

| Commit | Task | What it did in area V |
|---|---|---|
| 809ffdede | T3033 | `perf-baseline.ps1` gains the viewer phase. Fixes PA-V01. |
| 336d1ad41 | T3035 | new `viewer_suspend.zig`; `applySleep` sets `MemoryUsageTargetLevel = Low` on hide and calls `TrySuspend` after 30 s hidden; `wakeForWork` resumes before any renderer-bound call. Fixes PA-V03. |
| f661522ef | T3036 | `startWhenShown`: the web view starts one message hop later and only if the pane is still visible, else on first `setVisible(true)`. Fixes PA-V04. |
| 923dbe45d | T3037 | new `reload_gate.zig`; a save while hidden is owed and paid once on show; a save that left size and mtime alone renders nothing. Fixes PA-V05. |
| 1d7b2e7ba | T3038 | one `git status --porcelain=v2` fingerprint per poll; an unchanged fingerprint ends the poll there; untracked files with unchanged size and mtime are not re-read. Fixes PA-V06. |
| 4e50b9d80 | T3039 | `setDiffFileCallUtf16` builds the call once, presized; `releasePatchBytes` after the push. Fixes PA-V07. |
| e15858510 | T3040 | the contents-card slide takes the process D3D11 device (`gl_comp_present.processDevice`) and releases its DComp host when the slide ends. Fixes PA-V08. |
| 663e4a850 | T3041 | glass sheet painted from a kept buffer, over the dirty rect only, skipping the area under an opaque page. Fixes PA-V09; leaves PA-V32. |
| b4655e962 | T3042 | find card deletes DC before bitmap; test proves 50 rebuilds leave GDI count flat. Its own comment records that the old order did not leak. PA-V10 was wrong. |
| 128e8e861 | T3043 | new `ViewerImageDecode.zig`: WIC decode on a pooled worker, straight into the response HGLOBAL, request parked on a deferral. Fixes PA-V11 and PA-V26. |
| b44c4609e | T3044 | `fileStream` reads a file straight into the response stream; `max_chunk` 8 MB to 2 MB. First part of PA-V12. |
| bde0a487f | T3045 | `git_run.Cancel` + a kill-on-close job per git; the three probes cancel before they join. Fixes PA-V13. |
| 1cde0416f | T3074 | chrome/child hosts share the device cache (the cache PA-V08's fix now uses). |
| 7c44aa9ec | T3169 | measurement only: closing viewers leaks nothing per open. |
| 9ae21a246 | T3241 | large pictures are staged into a per-pane scratch folder mapped as a virtual host, so their bytes never cross this process. Introduces PA-V35 and PA-V36. |
| e41f7b840 | T3224 | new `ViewerDocumentRead.zig` + `viewer_document.zig`: the markdown/code read, UTF-8 check and escape run on a worker. Second part of PA-V12. |
| 9619578eb | T3245 | new `ViewerResourceServe.zig`: every template and page resource is stat-ed and read on a worker, request parked. Third part of PA-V12. |

T3034 (PA-V02) was closed as `skipped(does not reproduce)` with no product
commit. T3145, T3146, T3147 (PA-V27, V28, V29) were filed and are `todo`.
T3047 to T3056 and T3075 are `todo`. T3250 (PA-V12 remainder) is `todo`.

## Verdicts

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| V01 | **fixed** by 809ffdede (T3033) (high) | `scripts/perf-baseline.ps1:83-87`, `:134`, `:1304`, `:1722-1723` | a `viewer` phase exists and opens three viewer kinds; T3169 quotes its output (app private 202 MB before, 268 MB with three viewers open) | none; gaps in what the phase covers are already filed: T3173, T3174, T3198, T3217, T3219 |
| V02 | **wrong** (medium: code read, measurement is T3034's) | `webview2.zig:510-518` (file unchanged), `App.zig:2909` | the code is as audit-1 said (the environment is released only at app exit), but the cost is not there: T3034 measured all 6 `msedgewebview2` processes exiting about 5 s after the last controller closes with the environment still held, built the idle release, saw no change, and reverted it. Oracle: `test/win32/webview-browser-exit.ps1`. T3169 records the residue as +9 GDI / +15 USER, one time | none; T3034 stays skipped |
| V03 | **fixed** by 336d1ad41 (T3035) (high) | `ViewerPane.zig:2016`, `:2069-2091`, `:2114-2134`, `:2159-2166`, `:8509-8514`; `viewer_suspend.zig:34`, `:76-128` | hide trims and arms a 30 s one-shot; the timer calls `TrySuspend`; show restores the level and resumes; `executeScriptWide`, reload, navigate, capture and process-failed all pass `wakeForWork` first | none. T3174 (the baseline cannot see the saving) stays open. One hole is PA-V33 |
| V04 | **fixed** by f661522ef (T3036) (high) | `Window.zig:4221`; `ViewerPane.zig:6399-6411`, `:6421-6428`, `:2019` | `createViewerPane` calls `startWhenShown`; the posted `WM_APP_VIEWER_START` starts only a pane still visible; a hidden one starts on first show | none; T3173 (baseline span) stays open |
| V05 | **fixed** by 923dbe45d (T3037) (high) | `ViewerPane.zig:2050-2061`, `:2029-2036`, `:8516-8526`; `reload_gate.zig` | the debounce timer calls `fileSaved`, not `reloadContent`; hidden returns `.owed` without a stat; unchanged size+mtime returns `.unchanged`; all four file modes go through it because the gate sits before `reloadContent` | none; Mac half is T3199. The gate's stat is PA-V34 |
| V06 | **fixed** by 1d7b2e7ba (T3038) (high) | `ViewerDiffProbe.zig:412`, `:448`, `:657-700`, `:791-830`, `:863-882`; `viewer_diff.zig` `statusFingerprintArgv`; `ViewerPane.zig:2668-2672` | an idle poll is one `git status` plus a stat per dirty path; `job.out_unchanged` ends it. A poll that finds a change still runs the full listing (the fingerprint plus the old gits), which is the wanted behaviour | none; Mac half is T3201 |
| V07 | **fixed** by 4e50b9d80 (T3039) (high) | `ViewerPane.zig:2599-2650`; `viewer_diff.zig` `setDiffFileCallUtf16`, `diffFileCallEstimate`; `ViewerDiffProbe.zig` `releasePatchBytes` | one presized UTF-16 buffer, passed to `executeScriptWide` with no second widening; `defer probe.releasePatchBytes()` in `applyDiffPatch` | none; T3217 (baseline has no large patch) stays open |
| V08 | **fixed** by e15858510 (T3040) (high) | `viewer_toc_comp.zig:124-135`; `ViewerTOCPanel.zig:1180-1186`, `:1262-1300`; `src/renderer/gl_comp_present.zig:459` | no `D3D11CreateDevice` in the card's host; `finishCompSlide` and `cancelCompSlide` call `releaseComp`, so a viewer at rest holds no DComp device, target or surface | none; T3219 (baseline never slides the card) stays open |
| V09 | **fixed** by 663e4a850 (T3041) (high) | `ViewerPane.zig:7955-7984`, `:7990-7997`, `:8060-8094`, `:8021-8033` | no `Dib32.create` per paint; the sheet is laid over the update rect, minus the page rect when the page is ready and opaque | none. What the fix keeps is PA-V32 |
| V10 | **wrong** as a leak; order corrected by b4655e962 (T3042) (medium: the no-leak result is the fix commit's) | `ViewerFindBar.zig:764-775` | `releaseCardSurface` now deletes the DC first. The commit's own comment and test record that the old order measured flat on Windows 11 (GDI freed the DIB with the DC); only the documented order was wrong | none |
| V11 | **fixed** by 128e8e861 (T3043), with V26 (high) | `ViewerPane.zig:5431-5443`, `:5513-5540`; `ViewerImageDecode.zig` `Job.run`; `image_copy.zig` `Source.copyInto` | WIC decodes on a pooled worker into the HGLOBAL the response stream wraps: BGRA, DIBV5 and BMP copies are gone (one extra buffer only for a rotated picture). T3241 then moved large pictures out of the process entirely | none |
| V12 | **fixed (incomplete)** by b44c4609e (T3044) + e41f7b840 (T3224) + 9619578eb (T3245) (high) | `ViewerPane.zig:4843-4895`, `:5263-5340`, `:5544-5560`; `ViewerDocumentRead.zig:52-57`; `ViewerResourceServe.zig:125-184`; `viewer_range.zig` `max_chunk` | document read and every template/page resource (stat probes and read) run on workers with the request parked; video chunks are 2 MB. Still on the GUI thread: `serveImage` browser route (`:5449-5457`) and icns route (`:5471`), `stageImage`'s stat (`:5013`), link-click resolution (`:4460-4462`, `:4610-4611`) | T3250 (todo) carries the remainder; add PA-V34's sites to it |
| V13 | **fixed** by bde0a487f (T3045) (high) | `ViewerDiffProbe.zig:277-284`; `ViewerWorktreeProbe.zig` and `ViewerFeedbackSend.zig` `deinit`; `git_run.zig` `Cancel`, `Running.kill`, `launch`, `finish` | each probe requests cancel before `join`; cancel terminates the git's whole job and refuses later spawns on that worker | none. The same shape came back in three newer workers: PA-V31 |
| V14 | **fixed (incomplete)**, as audit-3 (high) | `ViewerPane.zig:6190-6202`; `Window.zig:13517-13526`, `:13548`, `:8643`, `:9417`, `:6641` | unchanged since 40297c800 apart from the added `releaseGlassBuf()` call; the in-flight early return is still `:6195` | T3046 is closed; remainder is PA-V27 (T3145) |
| V15 | still open (high) | `ViewerPane.zig:5371-5380`; `ViewerResourceServe.zig:137-147`; `src/viewer/viewer.html` (unchanged) | each asset is still read from disk per request and answered with `.default` caching; T3245 only moved the read to a worker | T3047 unchanged |
| V16 | still open (high) | `ViewerPane.zig:2655-2656`; `ViewerDiffProbe.zig:611-625` | `probe.snapshot(alloc)` runs before `probe.complete()`, so it is now also paid by every `.unchanged` poll (`:2668`), which uses none of it | T3048 unchanged; note the cheap fix is now to snapshot only after `complete()` says `.listing` |
| V17 | still open (high) | `ViewerPane.zig:1465`, `:2472`, `:8483-8508` | both repeating timers stay armed while hidden; only the work is gated (`IsWindowVisible`, `diff_poll_gate.tick`) | T3049 unchanged |
| V18 | still open (high) | `ViewerPane.zig:6032`, `:6151`; `hero_snap_schedule.zig:58-63` (unchanged) | full-page PNG capture, decoded with `gdiplus_decode.decodeScaled` on the GUI thread in the completion | T3050 unchanged |
| V19 | still open (file unchanged) | `ViewerFeedbackBar.zig:1862-1870` | `Dib32.create` + `glassBand` + `destroy` per paint; T3041's kept-buffer fix was not applied here | T3051 unchanged |
| V20 | still open (file unchanged) | `viewer_feedback_images.zig:55-56`, `:113-130` | the image `Store` has no remove | T3052 unchanged |
| V21 | still open (high) | `ViewerPane.zig:4056-4066` | `setTOCWidthLive` calls `updateTOC` per accepted move | T3053 unchanged |
| V22 | still open (high) | `ViewerPane.zig:1419`, `:1428` | `ViewerFeedbackBar.create` and `ViewerFindBar.create` at pane create; `ensureNav` now also builds three worker objects per pane (cheap structs, no thread until used) | T3054 unchanged |
| V23 | still open (high) | `ViewerPane.zig:3306-3307`, `:3341`, `:6456-6461` | `adoptFrame` is the only caller of `pruneFrames`; `resources_dir` is resolved per pane | T3055 unchanged |
| V24 | still open (file unchanged) | `WhatsNewNotesView.zig:252-268` | full `renderer.render` per paint | T3056 unchanged |
| V25 | still open (high) | `ViewerFeedbackSend.zig:208` | still `std.Thread.spawn`; every other viewer worker uses `worker_pool.spawn` (`ViewerDiffProbe.zig:507`, `ViewerWorktreeProbe.zig:323`, `viewer_watcher.zig:148`, and the three new ones) | T3075 unchanged |
| V26 | **fixed** by 128e8e861 (T3043) (high) | `ViewerPane.zig:5431-5443` | the `.wic` branch returns before any file read; the 32-byte sniff is read by the worker only on `no_codec` (`ViewerImageDecode.zig` `readSniff`) | none (was tracked under T3043) |
| V27 | still open (high) | `ViewerPane.zig:6195`, `:6151-6157` | `releaseSnapshot` still returns when a capture is in flight; the late answer is still decoded and kept | T3145 unchanged (todo) |
| V28 | still open (high) | `ViewerPane.zig:7247-7261` | `handleProcessFailed` still reloads with no look at `self.visible`; T3035 added `wakeForWork` before it, so a suspended hidden page is now resumed and reloaded | T3146 unchanged (todo) |
| V29 | still open (inferred, as before) | `viewer_process.zig:61-65` (file unchanged); `ViewerPane.zig:7228-7244` | `render_process_unresponsive` still spends a restart | T3147 unchanged (todo); still needs the on-box confirmation |
| V30 | still open (high); cost is smaller | `ViewerPane.zig:7270-7277`, `:7859-7872`, `:8493-8507` | `dropController` and `fail` still kill no timer. Since T3038 an unchanged tree costs such a pane 1 git per 2 s, not 6 | folded into T3049, unchanged |

**Totals for V01 to V30:** 11 fixed (V01, V03 to V09, V11, V13, V26), 2 fixed
(incomplete) (V12, V14), 15 still open, 0 changed, 2 wrong (V02, V10).

## Fix-commit review

Regressions and holes found in the fix commits. Each is a new finding below.

| Fix commit | Task | What it left or introduced | Finding |
|---|---|---|---|
| 128e8e861, e41f7b840, 9619578eb, 9ae21a246 | T3043, T3224, T3245, T3241 | three new workers that pane close joins on the GUI thread with no cancel: the exact shape T3045 removed from the git probes | PA-V31 |
| 663e4a850 | T3041 | the per-paint DIB became a kept buffer that only grows and is not dropped on hide | PA-V32 |
| 336d1ad41 | T3035 | a pane hidden before its controller arrives is never trimmed or suspended | PA-V33 |
| 923dbe45d | T3037 | the gate's `statFile` runs on the GUI thread, the thing T3224/T3245 removed for every other read | PA-V34 |
| 9ae21a246 | T3241 | every viewer of every kind claims a scratch folder on the GUI thread; the first one sweeps abandoned folders there | PA-V35 |
| 9ae21a246 | T3241 | each picture of 2 MB or more is copied whole to `%TEMP%` on every open and every save | PA-V36 |

Read and found without a regression: f661522ef (T3036), 4e50b9d80 (T3039),
bde0a487f (T3045), b44c4609e (T3044), b4655e962 (T3042). Two small notes that
are not findings:

- **1d7b2e7ba (T3038).** If the porcelain output exceeds `listing_cap`
  (16 MB, `ViewerDiffProbe.zig:43`) or `git status` fails, the fingerprint is
  null and every poll runs the full listing plus the extra `status`: one git
  more than before the fix. Needs a tree with a very large untracked set.
- **e15858510 (T3040).** A DComp device, target and surface are now created
  per slide (`ViewerTOCPanel.zig:1180-1182`, `viewer_toc_comp.zig:124-165`)
  on the GUI thread at the start of a 150 ms slide. User-driven and rare; the
  trade is the one the task chose. T3219 would measure it.

## New findings

| PA | Pri | Where | Cost | Fix |
|---|---|---|---|---|
| V31 | P2 | `ViewerPane.zig:1176-1191`; `ViewerDocumentRead.zig:162-166`; `ViewerResourceServe.zig:375-388`; `ViewerImageDecode.zig:373-376`, `:146-149` | closing a viewer blocks the GUI thread for the rest of an in-flight read, decode or stage copy (inferred: the read time of up to 32 MB on a slow path; a copy of up to 512 MB) | detach the job instead of joining it |
| V32 | P2 | `ViewerPane.zig:7990-7997`, `:8070-8075`, `:2005-2037` | each viewer on glass keeps a whole-client buffer x1.25 (computed: 6.3 MB at 1400x900, 41.5 MB at 4K), also while hidden | release on hide; shrink after an oversized paint |
| V33 | P3 | `ViewerPane.zig:2069-2070`, `:6576` | a pane hidden while its controller is being created keeps a full, awake renderer until the next show/hide (inferred: PA-V03's whole cost for that pane) | call `applySleep(false)` at the end of `adoptController` when hidden |
| V34 | P3 | `ViewerPane.zig:2042-2046`, `:2053`, `:2443`, `:4794`, `:2405-2406` | one synchronous `statFile` on the GUI thread per visible save, per navigation and per chrome reload (inferred: one slow-path round trip each) | take the stamp on the document worker |
| V35 | P3 | `ViewerPane.zig:6596`, `:5076-5082`; `viewer_scratch.zig:45-57`, `:85-118`, `:33-37` | every viewer, image or not: `makePath` + `CreateFileW` + `MapHostToFolder` at adopt and `deleteTree` at close, on the GUI thread; the first viewer after a crash also deletes abandoned folders there (computed: 3 file-system calls per open, 1 tree delete per close) | sweep on a worker; skip the claim for web panes |
| V36 | P3 | `ViewerPane.zig:5004-5021`; `ViewerImageDecode.zig:146-159`; `viewer_content.zig:715`, `:721` | a browser-route picture of 2 MB to 512 MB is copied whole into `%TEMP%` per revision (computed: bytes written = file size, per open and per save) | hard-link when source and scratch share a volume |

### PA-V31: closing a viewer joins its document, resource and image workers with no cancel (P2)

`ViewerPane.deinit` calls `image_decode.deinit()` (`:1176-1179`),
`document_read.deinit()` (`:1182-1185`) and `resource_serve.deinit()`
(`:1188-1191`). Each joins its worker thread on the GUI thread:
`ViewerImageDecode.zig:373-376`, `ViewerDocumentRead.zig:162-166`,
`ViewerResourceServe.zig:386`. None of the three jobs has a cancel flag: the
document job is one `readFileAlloc` of up to `max_file_bytes` (32 MB) plus the
escape (`viewer_document.zig:53-61`); the resource job is `statFile` over up
to three candidates then one `preadAll` (`ViewerResourceServe.zig:129-134`,
`:179`); the image job is a WIC decode or a `copyFile` of up to
`max_staged_bytes` (512 MB, `ViewerImageDecode.zig:146-149`,
`viewer_content.zig:721`).

T3224 and T3245 exist because a document on a slow or network path froze every
terminal in the window while it was read. With the read on a worker the open
no longer freezes, but closing the pane while that read is still out waits for
all of it. `resource_serve.deinit` drops the queued jobs first
(`:376-385`), so only the one in flight is waited for; the other two have no
queue to drop but also wait for the one in flight.

This is PA-V13's shape. bde0a487f (T3045) fixed it for the git probes by
cancelling before the join; these three workers were added after it and did
not take the pattern.

**Cost (inferred, not run):** the remaining time of one read, decode or copy.
Local SSD: tens of milliseconds for a document, a few hundred for a phone
photo's decode (the figure the removed `transcodeImage` comment gave). Slow or
dead network path: as long as the file system takes to answer, which is the
case the workers were built for. A 512 MB staged copy: seconds.

**Fix:** let the job outlive the pane. Each job already owns its path and
output and frees itself in `finish`; give it an atomic `abandoned` flag,
set it in `deinit`, detach instead of join, and have the worker call `finish`
itself and skip the `PostMessage` when the flag is set. The parked deferral
must still be completed and released on the GUI thread, so complete it in
`deinit` before detaching (the controller is already closed at `:1045-1050`).
For the stage copy, the scratch folder's `deleteTree` (`:1194-1197`) must then
wait for or tolerate the worker; simplest is to have the abandoned worker
delete its own spill. **Risk:** medium; the join exists because the worker
writes into pane-owned memory (`self.hwnd`, `self.message`), so the worker
must read those from the job, not from the pane.

**Task action:** new task, P2; `deps` none.

### PA-V32: the glass sheet buffer only grows, and a hidden viewer keeps it (P2)

T3041 replaced the per-paint DIB with `glass_buf`, grown by `glassPixels` to
`n + n/4` pixels when a paint needs more (`ViewerPane.zig:7990-7997`) and never
shrunk. It is freed in three places only: `deinit` (`:1031`), leaving glass
(`:5899`), and `releaseSnapshot` (`:6194`), which runs when a glide lands, hero
mode ends or a drag ends. `setVisible(false)` (`:2005-2037`) does not free it.

Every viewer paints the whole client at least once: before the page is ready
`opaque_page` is null (`:8070`), so the sheet is laid everywhere and the buffer
grows to the full client x1.25. Once the page is ready and opaque, later paints
need only the nav band (`glassSheetRect`, `:8021-8033`), but the full-size
buffer stays. A see-through page (`drawsOnGlass`) needs the full buffer on
every paint, so for those the kept buffer is the point; for the ordinary
opaque page it is dead weight after the first paint.

**Cost (computed):** `w * h * 4 * 1.25` bytes of committed private memory per
viewer on glass: 6.3 MB at 1400x900, 41.5 MB for a 4K pane. Before T3041 this
memory was transient (allocated and freed inside each paint), so resident
memory per glass viewer went up by this much in exchange for the per-paint
allocation. A background tab's viewers keep theirs until some glide, hero exit
or drag happens to release that tab.

**Fix:** (a) call `releaseGlassBuf()` from `setVisible(false)`; (b) after a
paint whose `n` is under a quarter of `glass_buf.len`, free and re-allocate at
`n + n/4`, so an opaque page settles at band size. **Risk:** low; (b) costs one
allocation when the page turns ready, and the resize path still reuses.

**Task action:** new task, P2; or reopen T3041 with this as its remainder.

### PA-V33: a pane hidden before its controller arrives never sleeps (P3)

`applySleep` begins `const c = self.controller orelse return;`
(`ViewerPane.zig:2069-2070`), before it touches `sleep_gate`. A pane whose
`start` was paid while visible and that is hidden before the asynchronous
controller creation completes therefore leaves the gate at `.awake`. When the
controller arrives, `adoptController` passes the visibility to WebView2
(`:6576`, `c.setVisible(self.visible)`) but does not call `applySleep`. The
page then loads hidden with a normal memory target and no suspend timer, and
stays that way until the pane is next shown and hidden again.

The window is the controller's creation time: short for a second viewer, up
to the environment's cold start for the first (audit-1 estimated 0.3 to 1 s).
Opening a document and switching tab at once is enough.

**Cost (inferred):** for that pane, exactly what PA-V03 described: a hidden
renderer at full size with its timers running, for as long as it stays hidden.

**Fix:** at the end of `adoptController`, `if (!self.visible)
self.applySleep(false);`. **Risk:** none seen; the page's first load then runs
with a low memory target, which WebView2 allows.

**Task action:** new task, P3; one line plus a unit test on the gate.

### PA-V34: the reload gate stats the viewed file on the GUI thread (P3)

`fileStamp` (`ViewerPane.zig:2042-2046`) is `std.fs.cwd().statFile(path)`.
It is called from `fileSaved` on every debounced save of a visible pane
(`:2053`), from `syncWatcher` on every navigation (`:2443`), from
`reloadContent` on a chrome reload (`:4794`) and from the show catch-up
(`:2031`). `isReadableFile` (`:2405-2406`) is a second synchronous stat on
navigation. All run on the GUI thread.

T3224 and T3245 moved the document read and every resource stat off this
thread because one stat on a slow path stalls the window. T3250 lists the
remaining GUI-thread disk touches but not these.

**Cost (inferred):** one file-system round trip per visible save and per
navigation. Nothing on a local disk; a stall of the path's latency otherwise.
A writer saving a visible file several times a second pays it at the debounce
rate.

**Fix:** let the document worker take the stamp (it opens the file anyway) and
hand it back with the job; `fileSaved` then always requests a read and the
worker returns `.unchanged` without reading when the stamp matches.
**Risk:** low; one worker hop for the "unchanged" answer.

**Task action:** add to T3250 (same defect, same task family).

### PA-V35: every viewer claims an image scratch folder on the GUI thread (P3)

`adoptController` calls `mapImageScratch` for every pane (`ViewerPane.zig:6596`),
whatever its mode. That calls `viewer_scratch.claim` (`:5080`): `makePath` of
`%TEMP%\ghoztty-viewer-images\<pane id>` and a `CreateFileW` of its `.owner`
file (`viewer_scratch.zig:45-57`, `:60-79`), then `MapHostToFolder`. Pane
close calls `Claim.release`, a `deleteTree` (`viewer_scratch.zig:33-37`,
`ViewerPane.zig:1194-1197`). The first pane of the process also runs `sweep`
(`:5081`), which iterates the parent folder and `deleteTree`s every folder
whose owner is gone (`viewer_scratch.zig:85-118`); after a crash those can
hold staged pictures of tens of megabytes each.

The mapping must precede the first navigation (the comment at `:5068-5070`
records that a later mapping never reaches the page), and a markdown pane can
navigate to an image, so the claim cannot simply be made lazy for file panes.
A `.web` pane never shows a staged image.

**Cost (computed):** per viewer open, two file-system creates and one COM
call; per close, one tree delete; all on the GUI thread. Once per process, a
directory walk and N tree deletes. Each is sub-millisecond on a healthy local
`%TEMP%`; the sweep after a crash is bounded by what the crash left.

**Fix:** run `sweep` on a `worker_pool` thread; skip `mapImageScratch` when
`self.mode == .web`. **Risk:** low.

**Task action:** new task, P3.

### PA-V36: a large picture is copied whole to `%TEMP%` on every open and save (P3)

`stageImage` (`ViewerPane.zig:5004-5021`) stages any browser-route picture
from `stage_min_bytes` (2 MB) up to `max_staged_bytes` (512 MB)
(`viewer_content.zig:715`, `:721`); the worker's `copy` is a full
`copyFile` into the pane's scratch folder (`ViewerImageDecode.zig:146-159`).
`loadImage` runs on open and on every reload, including the watcher's
(`fileSaved` to `reloadContent` to `startImage`), so each save of a visible
picture copies it again; the previous copy is deleted when the new one is
shown (`:5060-5063`).

This is T3241's deliberate trade: T3241's title records about 9.5x the
picture's size in app memory before it, because WebView2 copies every
`WebResourceRequested` body. The copy is off the GUI thread. What it costs now
is disk.

**Cost (computed):** bytes written to `%TEMP%` equal to the file's size per
revision, and the same again in temporary disk space while two revisions
overlap. A 200 MB GIF saved ten times writes 2 GB.

**Fix:** try `CreateHardLinkW` first (same volume: no bytes copied, and the
link survives the source being replaced by an atomic save); fall back to the
copy across volumes. **Risk:** low; an editor that rewrites the file in place
would change the linked bytes under the page, which the next revision's
reload corrects.

**Task action:** new task, P3.

## Checked and found clean

- **`viewer_suspend.Gate`** is pure and allocation-free; `wakeForWork` only
  queries `ICoreWebView2_3` when the gate says resume (`ViewerPane.zig:2159-2166`),
  so a visible pane pays one branch per script.
- **No hidden suspend/resume churn.** The three hidden wake-ups that could
  resume a suspended page are all gated before they reach the renderer: the
  file reload (`reload_gate`, `:2053`), the diff poll (`diff_poll_gate.tick`,
  `:8505`) and the loopback poll (`IsWindowVisible`, `:8490`).
- **`reload_gate`** does not stat while hidden (`:2053`), and `reset` on
  navigation (`:2441`) drops an old document's debt.
- **`git_run.Cancel`** clears the thread-local token after each job on the
  pooled thread (`ViewerDiffProbe.zig:646`), and `track` kills a process
  launched in the window between the pre-spawn check and publication.
- **`ViewerResourceServe`** runs one worker per pane, started on demand and
  exited when the queue drains; the join in `request` (`:295`) is of a thread
  that has already left its loop. Queued jobs are dropped, not run, at close.
- **Superseded document reads** are dropped by generation
  (`ViewerPane.zig:4944-4953`) and a second request replaces the queued one
  (`ViewerDocumentRead.zig:107-110`), so a burst of saves reads at most twice.
- **`fileStream` / `readInto`** hold a served file once (the HGLOBAL the
  stream wraps), not twice.
- **The T3038 untracked cache** is borrowed by the worker
  (`ViewerDiffProbe.zig:448`) and only replaced in `complete`, after that
  worker has finished; `deinit` joins before freeing it (`:277-291`).

**Not covered** (same gaps as audit-3): the page-side cost of `diff.js`,
`image.js` and `viewer.js`; `ViewerFeedbackWeb` beyond create/close;
`viewer_feedback_report/_doc/_acc/_a11y/_layout`; `screen_capture.zig`;
`banner_markdown.zig`; message handlers in `ViewerPane.zig` outside the cited
ranges. `baseline-4.json` was not read for viewer numbers; the quoted figures
are from T3034 and T3169.

## Summary

- **Fixed (all rounds):** 13 of 30. Eleven complete: V01 (809ffdede, T3033),
  V03 (336d1ad41, T3035), V04 (f661522ef, T3036), V05 (923dbe45d, T3037),
  V06 (1d7b2e7ba, T3038), V07 (4e50b9d80, T3039), V08 (e15858510, T3040),
  V09 (663e4a850, T3041), V11 and V26 (128e8e861, T3043), V13 (bde0a487f,
  T3045).
- **Incomplete:** 2. V12 (b44c4609e T3044 + e41f7b840 T3224 + 9619578eb
  T3245; remainder T3250 and PA-V34), V14 (40297c800 T3001; remainder PA-V27,
  T3145).
- **Still open:** 15 (V15 to V25, V27 to V30).
- **Changed:** 0.
- **Wrong:** 2. V02 (measured by T3034: the runtime ends the browser tree by
  itself) and V10 (measured by T3042: the delete order did not leak).
- **New:** 6 (V31 to V36): two P2, four P3, all from fix commits.

**Task actions:**

- New tasks: PA-V31 (P2), PA-V32 (P2), PA-V33 (P3), PA-V35 (P3), PA-V36 (P3).
- Add PA-V34's sites to T3250.
- Note on T3048 (PA-V16): the snapshot is now also taken for `.unchanged`
  polls; taking it only for `.listing` is most of the fix.
- No change: T3047 to T3056, T3075, T3145, T3146, T3147, T3250.

**Open P0/P1 in area V:** none. Every P1 from audit-3 (T3033 to T3046) is done
or, for T3034, skipped on measurement. Open work is P2: T3047 to T3056
(V15 to V24), T3075 (V25), T3145 to T3147 (V27 to V29), T3250 (V12
remainder), plus the two new P2 findings above.
