# Audit-3, area M: memory and leaks (T3101)

- **Area:** M, memory and leaks (whole app, Windows build)
- **This file:** audit-3, a re-audit of `../audit-2/M-findings.md`
- **Commit audited:** d0d874326 (audit-2 was 879fba35a)
- **Produced by** Fable 5.2 (`claude-fable-5-2`), one read-only auditor. No
  build, no test run, no app launch: every cost below is computed or
  inferred from the code, or quoted from a fix commit's own measurement. None
  was measured this turn.

**Method.** Every cited line was read at HEAD, not grepped. For each of the
six tasks now `done`, the task file and the fix commit's hunks were read, and
then the code at HEAD was traced to see whether the finding is gone and
whether the fix added a cost or a leak.

Confidence markers: **V** = read and traced at HEAD; **I** = inferred from
documented platform behavior on top of code that was read.

## What moved since audit-2

`git diff --stat 879fba35a HEAD` over the files the fifteen PA-M ids cite:

| File | Lines | Commits (task) |
|---|---|---|
| `scripts/perf-baseline.ps1` | +607 | ad3cfa61d (T2989), a7554f932 (T3005) |
| `src/apprt/win32/Window.zig` | +424 / -86 | 40297c800 (T3001) and W-area work |
| `src/renderer/generic.zig` | +287 | 8b0de569b, 6bd6fe7fb (Mac intake, T3102), ad014989d (T3103), ae9b1adb2 (T3104), 19581323a (T2975) |
| `src/terminal/PageList.zig` | +168 | 0f71734a4 (T3003), ede873611 (T3004), e4f27d125 |
| `src/terminal/page_pool.zig` | new, 263 | 0f71734a4 (T3003), ede873611 (T3004) |
| `src/font/WindowsFontIndex.zig` | new, 497 | fb7b961ec (T3011) |
| `src/font/discovery.zig` | +188 / -143 | fb7b961ec (T3011) |
| `src/termio/mailbox.zig` | +175 | 65fce4b64 (Mac intake, T3102) |
| `src/apprt/win32/PaneDesk.zig` | +103 | 5a7fa1191 (T3002) |
| `src/renderer/Thread.zig` | +81 | T3102, T3103 |
| `src/apprt/win32/chrome_comp.zig` | +77 | 5a7fa1191 (T3002), 66a526f79 (T2987) |
| `src/renderer/OpenGL.zig` | +64 | T2975, T3103, T3104 |
| `src/apprt/win32/Surface.zig` | +56 | 40297c800 (T3001), T2975, T3104 |
| `src/apprt/win32/ViewerPane.zig` | +14 (snapshot part) | 40297c800 (T3001) |
| `src/termio/Thread.zig` | +13 | 65fce4b64 (T3102) |
| `src/renderer/gl_comp_present.zig` | +10 | 19581323a (T2975) |

Unchanged since audit-2: `src/apprt/win32/IpcHandlers.zig`,
`DirectoryProbe.zig`, `AgentIntegration.zig`, `src/renderer/cell.zig`,
`src/renderer/opengl/buffer.zig`, `src/renderer/upload_diff.zig`,
`src/datastruct/blocking_queue.zig`.

Six PA-M tasks closed: T3001, T3002, T3003, T3004, T3005, T3011. Three
renderer tasks outside the M task list changed the shape of PA-M13 and
PA-M14: T2975, T3103, T3104.

## Verdicts

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| PA-M01 | **fixed** by 40297c800 (V, high) | `src/apprt/win32/Surface.zig:2853` (buffer freed after publish), `:2863-2890` (`releaseSnapshot`); `src/apprt/win32/Window.zig:12891-12900` (`releaseIdleSnapshots`), called at `:12922` (glide end), `:8068` and `:8838` (hero exit), `:6325-6326` (drag end) | the landing buffer goes as soon as its pixels are in the DIB; the DIB goes when the glide lands, hero mode ends or the drag ends; a pending request is cancelled under `snap_mutex`, so the renderer cannot write into a freed buffer (`heroSnapAcquire` `:2720-2730` re-checks size under the same lock) | T3001 stays done. The viewer half has a hole: PA-M16 |
| PA-M02 | **fixed** by 5a7fa1191 (V, high) | `src/apprt/win32/PaneDesk.zig:328-340` (`fitList`), `:2590-2599`, `:2608` (`ensureDesk`), `:118-159` (`Backing.tight`, `keepsTight`), `:2560`, `:2571`; `src/apprt/win32/chrome_comp.zig:382-383`, `:403-418` (`Overlay.fit`) | outside a window-edge drag the desk, gradient, quarter, glow and overlay buffers fit the window again and the two DIB sections are re-mapped once they are twice the bitmap. `ensureDesk` returns early at `:2577-2581` when the desk is cached, so the fit runs once per size change, not per paint | T3002 stays done. One new cost: PA-M17 |
| PA-M03 | **fixed** by 0f71734a4 (V, high) | `src/terminal/PageList.zig:40` (preheat 1 on Windows), `:47`, `:84-87` (`ExactPool`), `:114-117`; `src/terminal/page_pool.zig:140-154` (`allocNew`) | one page-allocator call per standard page, so commit equals live pages; preheat is 1 | T3003 stays done |
| PA-M04 | **fixed** by ede873611 on Windows (V, high) | `src/terminal/PageList.zig:53` (`page_free_retain = 1`), `:3509-3520` (`destroyNodeExt`); `src/terminal/page_pool.zig:99-107` (`release`) | a destroyed standard page beyond one in reserve goes back to the OS without the memset. Scrolling at the limit still reuses the oldest page in place (`:3250-3258`) | T3004 stays done. Mac half T3013 is still open (the arena pool cannot free single pages) |
| PA-M05 | **fixed** by a7554f932 (V, high) | `scripts/perf-baseline.ps1:994-999` (cycles 1-2), `:1005-1048` (warm-up until two quiet cycles, then a least-squares slope over `-SettledCycles`), `:447-530` (region census), `:1052-1058` (closed-and-idle sample), `:86-98` (`-AppEnv`) | every item of the finding and of audit-2's rewrite is present | T3005 stays done. Caveat below (fix-commit review) |
| PA-M06 | still open (V, high) | `src/apprt/win32/IpcHandlers.zig:1373-1381` (priority lock, whole-screen selection, dump), `:1408` (tail) | file unchanged | T3006 unchanged |
| PA-M07 | still open (V, high) | `src/apprt/win32/App.zig:9226-9283` | the handler body still never reads `target` | T3007: new lines |
| PA-M08 | still open (V, high) | `src/apprt/win32/DirectoryProbe.zig:155`, `src/apprt/win32/AgentIntegration.zig:171` | both still `std.Thread.spawn(.{}, ...)`; files unchanged | T3008 unchanged |
| PA-M09 | **changed**: one more site (V, high) | `src/renderer/Thread.zig:267`; `src/datastruct/blocking_queue.zig:102-105`; `src/termio/Thread.zig:358-360`; `src/termio/mailbox.zig:131-139`, new: `:136` | see below | T3009: add the overflow list, new lines |
| PA-M10 | still open (V, high) | `src/renderer/cell.zig:118-122` | file unchanged | T3010 unchanged |
| PA-M11 | **fixed** by fb7b961ec (V, high) | `src/font/WindowsFontIndex.zig:118-141` (`candidates`), `:179` (`build`); `src/font/discovery.zig:917-934`, `:962-980` | a query opens only the faces the index names; the walk over every font file is gone from the query path | T3011 stays done |
| PA-M12 | still open (V, high) | `src/apprt/win32/Window.zig:2498-2505` (`deinit`) against `:22187-22279` (`onDestroy`) | `compDragThreadStop()` is called only at `:2500` and `:16793`; the three `cancel()` calls are only at `:2503-2505`. Both paths do share `releaseOwnedResources` (`:2566`), which holds neither | T3012: new lines |
| PA-M13 | **changed**: smaller (V, high) | `src/renderer/Thread.zig:600-602`, `:617`, `:632-646`, `:842`; `src/renderer/generic.zig:1369`, `:1478-1543`; `src/renderer/OpenGL.zig:1589-1593`, `:1646-1658` | see below | T3096: rewrite the M13 half |
| PA-M14 | **changed**: more sites (V for the code, I for the mechanism) | `src/renderer/gl_comp_present.zig:1111-1136` (`releaseCom`), `:938-943` (`releaseShared`), `:945-958` (`destroyShared`); `src/renderer/OpenGL.zig:1646-1658` | see below | T3097: add the two new release paths to the measurement |
| PA-M15 | still open (V, high) | `src/renderer/opengl/buffer.zig:11`, `:41`, `:85-90`, `:116`, `:146`; `src/renderer/upload_diff.zig:46-55` | both files unchanged. The idle and hidden releases free targets and atlas copies only (`generic.zig:1518-1532`), not `cells` or `cells_bg` | T3098 unchanged |

Six fixed, six still open, three changed, none wrong.

## Changed items

### PA-M09: the termio overflow list is a third place a payload is dropped

- **Still true (V):** `src/renderer/Thread.zig:267` destroys the renderer
  mailbox undrained, and `src/termio/Thread.zig:358-360` (drain mode) pops
  and drops every message without freeing a `write_alloc` payload
  (`src/termio/message.zig:101`).
- **What moved:** 65fce4b64 (Mac intake, T3102) gave the termio mailbox an
  `Overflow` list (`src/termio/mailbox.zig:32-71`) for messages the IO
  thread sends itself when the queue is full. `Mailbox.deinit`
  (`:131-139`) frees the queue and then `overflow.list.deinit` (`:136`)
  without walking either for owned payloads. The drain-mode loop now goes
  through `mailbox.next()`, so it empties the overflow list too, and drops
  those the same way.
- **Size:** unchanged in kind (rare, one payload per pane close at most),
  but the overflow list is exactly where large reply bursts sit, so the
  window is wider than the 64-slot queue alone.
- **What T3009 should now say:** free payloads in three places: the
  renderer mailbox before `destroy`, the termio drain-mode loop, and
  `Mailbox.deinit` over both the queue and `overflow.list`.

### PA-M13: a tab-hidden pane now gives back most of it; the swap chain is what stays

- **What moved:** T2975 (19581323a) and T3104 (ae9b1adb2) made a pane whose
  tab went behind another, or that is zoomed over or stashed, count as
  hidden for the release (`OpenGL.releaseHiddenTargetsNow`,
  `src/renderer/OpenGL.zig:1589-1593`). On `.visible = false` the renderer
  shrinks the three frame targets to 1x1 and drops the atlas copies
  (`src/renderer/generic.zig:1369`, `:1518-1532`), and
  `hiddenTargetsReleased` frees the presenter's shared texture
  (`OpenGL.zig:1646-1658`, `gl_comp_present.zig:938-943`). `releaseShared`
  zeroes `tex_w`/`tex_h`, so the texture is rebuilt at the current size.
- **Still true (V):** the trim itself still cannot run while hidden.
  `drawFrame` returns at `src/renderer/Thread.zig:600-602` before
  `armStorageTrim` (`:617`), and `trimCallback` (`:632-646`) only forces a
  frame that the same check drops.
- **What is left at the high-water size:** the composition swap chain. It is
  kept on purpose (`OpenGL.zig:1650-1654`: it holds the picture a reveal
  shows), it has two buffers (`gl_comp_present.zig:672`), and its
  `swap_w`/`swap_h` only come down in a trim frame (`:964-968`, `:984`).
  The window-presenter slot textures (`OpenGL.zig:1727-1740`) were not
  traced through the hidden path.
- **Cost (computed):** about 2 x w x h x 4 for a pane last shown at a larger
  size: ~66 MB per full-window pane after a 4K maximize, ~10 MB at
  1400x900, until the tab is shown again. Audit-2 had ~150 MB at 4K.
- **What T3096 should now say:** the M13 half is the swap chain only. Fix:
  when the hidden release runs with the swap chain oversized for the
  current client size, `ResizeBuffers` it down in the same pass (one frame
  of old picture stretched on reveal), or accept it and close the half.

### PA-M14: two more places release D3D objects on the shared device with no flush

- **Still true (V):** `releaseCom` (`src/renderer/gl_comp_present.zig:1111-1136`)
  releases the visual, target, swap chain, context and device. The file has
  no `Flush` or `ClearState` call.
- **What moved:** the shared texture is now also released while the app is
  quiet, by two new paths that both end in `hiddenTargetsReleased`
  (`src/renderer/OpenGL.zig:1646-1658`):
  - the hidden release for a tab, zoom or stash (T2975, T3104);
  - the idle release, 3 s after a pane's last draw (T3103,
    `src/renderer/generic.zig:1419-1436`).
  `hiddenTargetsReleased` ends with `gl.finish()` (`:1657`), which submits
  the GL deletes. It does not flush the D3D11 immediate context that owns
  the shared texture.
- **Mechanism (I):** D3D11 destroys a released object when the immediate
  context is next flushed. With one process device (T2968), that flush is
  some pane's next `Present`. The idle release fires exactly when panes have
  stopped presenting, so in a fully idle app the shared textures it released
  may stay allocated until any pane next draws.
- **Cost (inferred):** one shared texture per idle pane, w x h x 4 at its
  grow bucket: ~5 MB at 1400x900, ~33 MB at 4K, on top of audit-2's
  closed-pane case. Bounded; ends at the next present anywhere.
- **What T3097 should now say:** measure three states, not one: pane closed
  with the rest idle, tab hidden with the rest idle, and every pane idle for
  more than 3 s. If any shows the memory held, one
  `ID3D11DeviceContext::Flush` after `releaseShared` and at the end of
  `releaseCom` covers all three.

## Fix-commit review

| Commit | Task | Verdict |
|---|---|---|
| 40297c800 | T3001 | Terminal half clean. Lock order and lifetime traced: `snapRequest` sizes the buffer under `snap_mutex` and only then sets `snap_requested` (`Surface.zig:2663-2679`); `heroSnapPublish` frees only when no request is pending (`:2853`); `releaseSnapshot` clears the request and sets `snap_dib_seq = snap_seq` so a queued `WM_APP_HERO_SNAP` publishes nothing (`:2872-2878`). `Surface.deinit` still frees both (`:1390-1398`). Two notes, neither a finding: in hero mode the landing buffer is now allocated and freed once per thumbnail capture (thumbnail-sized, so small); the Debug-only `captureContent` seam (`:2777-2817`) leaves its buffer until the next publish or release. **One finding: PA-M16** (viewer half) |
| 5a7fa1191 | T3002 | Buffers and sections traced. `fitList` allocates fresh and frees the old region, so a shrink does return commit (the commit explains why `shrinkAndFree` does not; T3124 tracks the other callers). `scratch` and `scratch_desk` are freed on a desk rebuild (`PaneDesk.zig:2597-2598`) and re-grown by the next partial compose to the dirty area only; a full compose does not use them (`:1389`). `Backing.ensure` with `tight` re-creates a section only on a halving. `glowLayer`'s slice is consumed by `glowUpload` before the next `glowLayer` call (`Window.zig:9625-9626`), so the new free-on-shrink cannot leave a dangling slice. `PaneDesk.deinit` (`:1216-1232`) unchanged and complete. **One finding: PA-M17** (`glow_px`) |
| 0f71734a4 | T3003 | Clean. `ExactPool` keeps `free.capacity >= all.len`, so `destroy` cannot fail (`page_pool.zig:141-145`). The zeroing rule holds: a fresh page is a fresh `VirtualAlloc` (zeroed), a pooled page is zeroed by `destroyNodeExt` (`PageList.zig:3523`) or by `reset` (`page_pool.zig:131-134`). `reset` then `initPages` cannot fail for want of pages. `deinit` frees every item. New cost: one `VirtualAlloc` per new 0.4 MB page while scrollback grows; negligible |
| ede873611 | T3004 | Clean. `release` is a linear scan of the pool's page list per released page (`page_pool.zig:99-107`): about 45 pointers at the 10 MB default, and still under a millisecond in total for a 1 GB scrollback cleared at once (computed). A reflow (`PageList.zig:1176-1183`) destroys old pages and creates new ones interleaved; the reserve of one covers the 1:1 case, and a mismatch costs a `VirtualFree` plus a `VirtualAlloc` and its page faults instead of a memset. Bounded, and only on a column change |
| a7554f932 | T3005 | Clean as tooling. One caveat for whoever reads the numbers: the census calls a region `heap` only when it carries the NT heap signature (`perf-baseline.ps1:490-502`). Zig `page_allocator` memory (terminal pages, desk buffers, cell shadows, the whole Debug allocator) lands in `private_rw`, so "heap +3-6 MB" is not "our memory +3-6 MB". T3130 already says this and owns the split |
| fb7b961ec | T3011 | Clean. The index lives for the process in one arena per snapshot; the old snapshot is destroyed on rebuild (`WindowsFontIndex.zig:158-162`); each face is opened and closed inside `build` (`:228-231`); `candidates` frees its partial list on error (`:129-132`); the iterator frees every path (`discovery.zig:956-960`). Size (computed): 8 bytes per cmap range, a few hundred ranges a face, so about 1-2 MB for 500 faces. Per query it now stats both Fonts folders under the index mutex (`:152-156`, `:168-177`); the commit measured 0.3 ms per uncovered codepoint. Two notes, neither a finding: `entries.append(arena, ...)` (`:243`) leaves superseded copies of the entry array in the arena (tens of KB); `prewarm` spawns with `std.Thread.spawn(.{}, ...)` (`:353`), one more default-stack site of the T3075 class, alive for the 60-75 ms build, once per process, and outside T3075's `src/apprt/win32` list |

## New findings

| Id | Pri | Finding |
|---|---|---|
| PA-M16 | P2 | A viewer pane keeps its pane-sized snapshot after a fold when the browser's capture answers after the glide has ended |
| PA-M17 | P2 | The focus-glow buffer is now freed and re-allocated on each focus change between panes of unequal size |

### PA-M16: a late viewer capture outlives the release (P2)

- **Where (V):** `src/apprt/win32/ViewerPane.zig:5523-5531`
  (`releaseSnapshot` returns at `:5524` while a capture is in flight),
  `:5460-5503` (`onCapturePreviewCompleted` decodes at `snap_w` x `snap_h`
  into `snap_dib`, `:5484-5490`), `:5390-5401` (`glideSnapRequest` sets
  those to the pane's full size); `src/apprt/win32/Window.zig:12891-12900`,
  `:12922`, `:8163` (`heroOnSnapReady` returns when `glide_snap == .none`).
- **Mechanism:** a fold asks a viewer for a full-size `CapturePreview`. The
  glide's time constant is 45 ms (`pane_stack_slide.zig:60`), so it ends in
  a few hundred ms. `endStackSlide` then calls `releaseSnapshot`, which
  does nothing because the capture is still out: it frees neither the old
  DIB nor cancels the new one. When the capture lands it decodes a
  pane-sized DIB. The `WM_APP_HERO_SNAP` it posts finds no glide and
  returns. Nothing frees that DIB until the next glide end, hero exit or
  drag end on that tab, or the pane closes. The terminal path does not have
  this hole: its release cancels the pending request.
- **Cost (computed):** w x h x 4 per viewer pane this happens to: ~5 MB for
  a 1400x900 pane, ~33 MB at 4K. Whether a given fold hits it depends on
  how long the browser takes to paint and encode the page (inferred: a
  full-page PNG is often slower than the glide).
- **Fix in brief:** make the release sticky. Bump `snap_gen` in
  `releaseSnapshot` when a capture is in flight (the completion handler
  already drops an answer whose `gen` is stale, `:5462-5467`), release the
  stream, clear `snap_in_flight_since_ms`, and free the current DIB.
- **Risk:** low. A fold that starts again asks again.
- **Regression of:** none; a gap in T3001's coverage.

### PA-M17: `glow_px` is fitted on every glow build (P2)

- **Where (V):** `src/apprt/win32/PaneDesk.zig:2336`
  (`fitList(&self.glow_px, 2 * n)`), `:328-340` (`fitList`: after the
  resize, when capacity is over twice the length and the slack is at least
  64 K pixels, allocate fresh, copy, free the old region), `:321`
  (`light_alloc` is `std.heap.page_allocator`);
  `src/apprt/win32/Window.zig:9616-9632` (`syncGlowLayers` builds a layer
  for the pane the glow moves to and, during the 250 ms fade, the one it
  leaves, whenever the desk was recomposed).
- **Mechanism:** `n` is the area of one card's glow rectangle, so it follows
  the pane's size. Before T3002 the buffer grew to the largest pane and
  stayed. Now, when two panes differ in area by more than 2x, building the
  small pane's layer frees the large buffer and building the large pane's
  layer allocates it again. Each allocation is a `VirtualAlloc` of fresh
  zero pages that `composeIn` then writes in full, and the shrink also
  copies `2 * n` pixels that the next line overwrites. A focus change
  between such panes builds both layers, so it pays this at least once.
  Unlike `ensureDesk`'s fit, this call is not gated on `self.live == null`,
  so it also runs under a window-edge drag.
- **Cost (inferred):** one allocation of `2 * n * 4` bytes with a page fault
  per 4 KB, on the GUI thread, per focus change: ~6.7 MB (about 1,600
  faults, in the order of 1-2 ms) for a 980x860 pane, ~18 MB (about 4,300
  faults, several ms) for a 1700x1300 pane. Zero when the panes are within
  2x of each other, and only when the compositor glow layers are in use.
- **Fix in brief:** keep `glow_px` at the larger of the layers wanted
  (plain `resize`, as before), and fit it once where the other buffers are
  fitted, in `ensureDesk`'s `fit` branch (`:2593-2599`), or free it when no
  glow is showing. Drop the copy: the contents are scratch.
- **Risk:** low.
- **Regression of:** T3002 (5a7fa1191).

## Checked and found clean

- `Window.releaseIdleSnapshots` skips a hero tab, a pane whose glide still
  carries its frame, and the dragged pane; every `glide_snap = .none` site
  (`Window.zig:12284`, `:12722`, `:12725`, `:12917`) is inside a slide that
  ends in `endStackSlide`, the only place `stack_slide` becomes null
  (`:12906`).
- `chrome_comp.Mirror` (T2987's kept caption and strip buffers,
  `chrome_comp.zig:244-309`): exact size, rebuilt on a size change, freed in
  `releaseOwnedResources` (`Window.zig:2577-2578`). Band-sized, not
  window-sized.
- `ExactPool` on error paths: `allocNew` reserves bookkeeping before it
  allocates the page (`page_pool.zig:141-153`), so a failed page allocation
  leaves the pool consistent.
- `WindowsFontIndex.build` error paths: `errdefer` on the snapshot and its
  arena (`:183-189`); the private FreeType library is deinited (`:201`).

**Not covered:** anything that needs a run; the renderer changes of T2975,
T3103 and T3104 beyond what PA-M13 and PA-M14 touch (area R owns them);
viewer internals beyond the snapshot path; the Mac half of the shared-core
items.

## Summary

| Fixed | Still open | Changed | Wrong | New |
|---|---|---|---|---|
| 6 (M01, M02, M03, M04, M05, M11) | 6 (M06, M07, M08, M10, M12, M15) | 3 (M09, M13, M14) | 0 | 2 (M16, M17) |

- **Open P0 in area M:** none.
- **Open P1 in area M:** none. All five audit-1 P1 items (M01-M05) are
  fixed. Related P1 outside the PA list: T3130 (the ~290 MB of `private_rw`
  the first pane cycle leaves is unattributed), filed by T3005.
- **Open P2:** M06 (T3006), M07 (T3007), M08 (T3008), M09 (T3009),
  M10 (T3010), M12 (T3012), M13 (T3096), M14 (T3097), M15 (T3098), and the
  new M16 and M17.

Suggested filing:

- **PA-M16** -> new task, P2, seat win, follow-up of T3001
- **PA-M17** -> new task, P2, seat win, follow-up of T3002
- **T3009** -> add `src/termio/mailbox.zig:131-139` (the overflow list)
- **T3096** -> the M13 half is now the swap chain only
- **T3097** -> measure the tab-hidden and all-idle states as well
- **T3075** -> add `src/font/WindowsFontIndex.zig:353`
- **T3007**, **T3012** -> new line numbers
