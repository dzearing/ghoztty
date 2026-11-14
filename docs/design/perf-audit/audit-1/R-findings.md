# Audit-1, area R: renderer and GPU (T2959)

- **Date:** 2026-11-14
- **Commit audited:** 4c8a7cd4f
- **Baseline:** `../baseline-1.json` (T2958)

**Produced by** two Fable 5.2 auditors (`claude-fable-5-2`, passed explicitly)
working read-only and in parallel:

1. **Renderer core:** `generic.zig`, `OpenGL.zig`, `opengl/*`, `Thread.zig`,
   `cell.zig`, `image.zig`, `link.zig`, and the font atlas as the renderer
   uses it.
2. **Windows present path:** `gl_comp_present.zig`, `gl_window_presenter.zig`,
   `comp_tree.zig`, `comp_overlay.zig`, `WindowPresenter.zig`,
   `FrameClock.zig`, `pane_pool.zig`, `chrome_comp.zig`, `child_comp.zig`,
   and the `Surface.zig` and `Window.zig` code that creates, sizes, hides and
   closes panes.

**Verification.** The T2959 turn checked every surviving claim against the
code before filing it, by reading the cited lines (claim-verification rule).

- Where an auditor's line number was wrong, the corrected one is below:
  `opengl/buffer.zig` upload calls are at 108 and 119, not 191 and 226.
- Two pairs of findings were the same defect seen from each side. They are
  merged: core F2 with present finding 1 (PA-R02 and PA-R03), and core F7
  with present finding 2 (PA-R08).

**What the default Windows path is.** Each pane presents through its own
composition swap chain (`gl_comp_present.zig:82`, `default_on = true`). Its
GL context goes current on a hidden helper window. The window presenter and
the chrome composition host are opt-in, so they explain none of the baseline.

## Findings

Each finding lists:

- **Where:** file and line
- **Cost:** whether it was measured or estimated
- **Fix**
- **Risk**
- **Pri:** priority
- **Task:** the parity task it was filed as

Code marked *shared* is used by the Mac build as well. Its Mac half is
**T2984** (`seat: mac`), which covers R01, R04, R05 and R07.

| Id | Pri | Finding | Task |
|---|---|---|---|
| PA-R01 | P0 | The render-state reset counter is never zeroed, so after 100,000 frames every frame rebuilds everything (*shared*) | T2967 |
| PA-R02 | P0 | One D3D11 device and one DComp device per pane: about 54 threads and tens of MB each | T2968 |
| PA-R03 | P2 | Each pane has its own GL programs and its own GPU copy of the font atlas (no share group) | T2969 |
| PA-R04 | P1 | A focused pane redraws every 600 ms even when its cursor does not blink (*shared*) | T2970 |
| PA-R05 | P1 | The link string and byte map are built every frame when no link can highlight (*shared*) | T2971 |
| PA-R06 | P1 | All cell buffers are re-uploaded, row by row, on every drawn frame (*shared*) | T2972 |
| PA-R07 | P1 | The whole atlas is re-uploaded per new glyph in every pane, and the atlas never shrinks (*shared*) | T2973 |
| PA-R08 | P1 | The target, the interop texture and the swap chain only ever grow | T2974 |
| PA-R09 | P1 | Background-tab panes keep all their surfaces; a hidden window keeps the interop texture | T2975 |
| PA-R10 | P1 | About 50 MB of GPU memory stays behind after closing 10 panes (the cause is not yet identified) | T2976 |
| PA-R11 | P2 | An unchanged frame is re-presented through two full-frame copies | T2977 |
| PA-R12 | P2 | Every grid resize reallocates all row lists (*shared*) | T2978 |
| PA-R13 | P2 | Each glide backdrop slice is copied twice, gets a new texture and forces a full rebuild | T2979 |
| PA-R14 | P2 | `Pipeline.deinit` leaks its FBO and VAO | T2980 |
| PA-R15 | P2 | The pixel format requests depth and stencil buffers that are never used (SwapBuffers fallback only) | T2981 |
| PA-R16 | P2 | The occlusion walk runs on every resize step; the hero heartbeat ignores occlusion | T2982 |
| PA-R17 | P2 | A recycled pane window skips `SetPixelFormat` (a correctness hazard, found in passing) | T2983 |

### PA-R01: the render-state reset counter is never zeroed (P0)

- **Where:** `src/renderer/generic.zig:1365-1370`.
  - The block deinits `terminal_state` once `terminal_state_frame_count >= 100_000`.
  - Nothing else writes the counter. A grep shows only the declaration (`:288`) and `+= 1` (`:1370`).
- **Effect:** from then on every `updateFrame` tears down and rebuilds the RenderState. That forces a full row re-shape under the terminal mutex. It also sets `frame_changed`, which defeats the unchanged-frame skip (T1935).
- **Upstream:** `upstream/main` already has `self.terminal_state_frame_count = 0;` (generic.zig:1390 there). `origin/main` does not (generic.zig:1211-1216).
- **Cost (estimated):**
  - about 15-30 minutes of streaming output at 60-120 fps to reach the threshold
  - hours for a pane with a spinner
  - after that, permanent full work on every wakeup
- **Fix:** reset the counter inside the `if`.
- **Risk:** none.

### PA-R02: one D3D11 device and one DComp device per pane (P0)

- **Where:**
  - `gl_comp_present.zig:499` calls `D3D11CreateDevice`.
  - `gl_comp_present.zig:590` calls `DCompositionCreateDevice`.
  - Both run in `Presenter.init`, once per pane.
- **The repo's own note:** `comp_overlay.zig:879-880` describes "the pane's whole D3D11 device, ~55 driver threads and its GPU memory".
- **Cost (measured, baseline-1 release):** from 1 pane to 10 panes,
  - threads went from 72 to 611 (about 54 per pane)
  - private memory went from 323 MB to 1418 MB
  - dedicated GPU memory went from 52.6 MB to 348.8 MB

  The attribution to the per-pane device is inferred, both from the repo's own note and from the thread count matching it. T2968's first step is an A/B test to confirm it.
- **Fix:** one process-wide device with multithread protection, shared by every swap chain.
- **Risk:** medium-high:
  - presents serialize on one immediate context
  - a device loss affects the whole process
  - GL interop has to be tested on each GPU vendor

### PA-R03: no GL share group (P2; depends on PA-R02)

- **Where:**
  - `OpenGL.zig:473-477`: each pane has its own context.
  - `opengl/shaders.zig:113-116`: each pane compiles its own programs.
  - `generic.zig:431-442`: each pane has its own atlas textures.
- **Cost (estimated):** at least 1.25 MB of atlas per pane, plus driver state for each context.

### PA-R04: the blink tick redraws a non-blinking cursor (P1)

- **Where:**
  - `Thread.zig:902-903`: the tick flips the blink phase and notifies the renderer.
  - `Thread.zig:475-483`: the timer is armed whenever the pane is focused.
  - `generic.zig:1664`: the raw blink phase is hashed into `frame_changed`.
  - `renderer/cursor.zig:64`: the phase only matters when `cursor.blinking` is set.
- **Cost (estimated):** 1.67 full frames per second per focused pane, for a cursor that is steady or hidden. That covers most TUIs.

### PA-R05: the link map is built when no link can highlight (P1)

- **Where:**
  - `link.zig:76-83`: builds the viewport string and map before the per-link highlight check at `:89-101`.
  - `generic.zig:1591`: calls this every frame.
  - `generic.zig:1557-1563`: already computes the `needed` predicate, but uses it only for seams.

### PA-R06: full cell buffer re-upload on every frame (P1)

- **Where:**
  - `generic.zig:1993-1995`: uploads the cell buffers.
  - `opengl/buffer.zig:96-119`: issues one `setSubData` per row.
  - `buffer.zig:108`: the buffer only ever grows.
- **Cost (estimated):** about 260 KB and about 48 GL calls per frame at 160x45.

### PA-R07: the whole atlas is re-uploaded per new glyph (P1)

- **Where:**
  - `font/Atlas.zig:274`: every `set` bumps `modified`.
  - `generic.zig:2005-2020`, then `:3906`: `replaceRegion(0, 0, atlas.size, atlas.size, ...)` runs in every pane.
  - `Atlas.zig:366`: `clear` does not reclaim memory.
- **Cost (estimated):** at 512², 256 KB per glyph per pane (grayscale) or 1 MB (color).

### PA-R08: GPU surfaces only grow (P1)

- **Where:**
  - `opengl/Target.zig:86`
  - `OpenGL.zig:1334`, where `grow_only` is set on win32
  - `gl_comp_present.zig:198` (`sharedCapacity`)
  - `gl_comp_present.zig:658-668`, where `ResizeBuffers` runs only when the capacity grows
- **Cost (estimated):**
  - about 22-25 MB per pane that was ever 1400x860
  - about 150 MB per pane after one maximize on 4K
  - about 45 MB of baseline-1's 348.8 MB comes from the three tab-root panes

### PA-R09: hidden and background-tab panes keep their surfaces (P1)

- **Where:**
  - `OpenGL.zig:1536-1544`: targets are released only when the whole window is hidden.
  - `generic.zig:1261-1263`: that release shrinks only the GL target.
  - `Window.zig:4785-4790`: switching tabs hides panes without releasing anything.
- **Cost (estimated):**
  - about 22-25 MB per background-tab pane
  - about 16-19 MB per pane after a window hide

### PA-R10: about 50 MB GPU plateau after closing panes (P1, cause unverified)

- **Measured:** after closing the panes, dedicated GPU memory is 107.4 MB, against 57.6 MB at start. The second cycle adds 0 MB, so this is a bounded plateau rather than a growing leak.
- **Suspects:**
  - `pane_pool.zig:28` (`capacity = 16`), with closed panes parked at `Surface.zig:1554-1555`
  - the per-HWND DComp target
  - driver caching
- **Next step:** T2976 starts with an A/B test of three knobs to find the carrier.

### PA-R11: unchanged frames re-presented (P2)

- **Where:**
  - `generic.zig:1907`: `presentLastTarget` is called for a frame that did not change.
  - `OpenGL.zig:1558-1566`: returns early only on the window-presenter path.
  - `OpenGL.zig:1397`: blit from the target to the interop texture.
  - `gl_comp_present.zig:839/844`: copy to the back buffer.
  - `gl_comp_present.zig:851`: `Present(1,0)`.
- **Cost:** GPU engine use is 1.0-1.6% busy on a 4090 (measured), so this only matters on small GPUs.

### PA-R12: row lists are reallocated on every grid resize (P2)

- **Where:** `cell.zig:118-122`.
- **Cost (estimated):** about 47 allocations and about 0.7 MB per resize step.

### PA-R13: glide backdrop churn (P2)

- **Where:**
  - `generic.zig:2327` and `:2289`: two copies of each slice.
  - `image.zig` (around line 906): a new texture each time.
  - `generic.zig:2337`: `markDirty`, which forces a full cell rebuild.
- **Measured context:** T2820 measured a glide tick at 12.8 ms against an 8.3 ms period.

### PA-R14: Pipeline leaks its FBO and VAO (P2)

- **Where:** `opengl/Pipeline.zig:50-56` creates them; `:72-74` destroys only the program.

### PA-R15: unused depth and stencil buffers (P2)

- **Where:** `Surface.zig:1735` and `:1751-1752`.
- **Cost (estimated):** about 5 MB per pane, on the SwapBuffers fallback path only.

### PA-R16: occlusion and hero heartbeat (P2)

- **Where:**
  - `Window.zig:22388-22389`: the occlusion walk runs on every `SIZE_RESTORED`.
  - `Window.zig:8002`: the hero heartbeat skips only minimized windows, not occluded ones.
- **Cost:** small.

### PA-R17: a recycled pane window skips SetPixelFormat (P2, correctness)

- **Where:** `Surface.zig:1019`.
- **Problem:** a window parked by a pane on the helper path never had a pixel format set. If a later pane's helper creation fails, that pane calls `createContext` on a device context with no pixel format.

## Claims that did not survive verification

| Claim | Why not |
|---|---|
| A 120 Hz draw loop runs at idle | `syncDrawTimer` arms it only for animations (custom shaders), `Thread.zig:341-357`. |
| The frame clock ticks at idle | `FrameClock.zig:370-373` waits `INFINITE` when nothing is live. |
| Hidden or minimized panes keep rendering | They return early at `Thread.zig:565` and `778-781`; occlusion is applied at `SIZE_MINIMIZED`. Only the blink timer keeps firing (PA-R04). |
| Unchanged frames are drawn | `shouldPresent` and `Thread.zig:856-860` skip them, apart from PA-R01, PA-R04 and the re-present in PA-R11. |
| The swap chain or target is reallocated on every WM_SIZE | It uses 256 px buckets and `resizeInPlace`. The opposite problem is real: they never shrink (PA-R08). |
| GL, D3D or DComp objects leak on pane close | Teardown is complete (`Surface.zig:1453/1491`, `gl_comp_present.zig:875-919`), and the second cycle measured 0 MB GPU and 0 threads. The caveats are PA-R10 (bounded plateau) and PA-R14. |
| Triple-buffered frame state | `swap_chain_count = 1` (`OpenGL.zig:40`). |
| The CPU atlas is duplicated per pane | It lives in `SharedGrid`; only the GPU copy is per pane (PA-R03). |
| `yieldToPriorityWaiters` causes 34k context switches/s under output | Its only caller is `termio/Remote.zig`, not the local ConPTY path. The switch rate is unexplained by this area and is left to the IO/core audit (T2964). |
| `DwmFlush` is in the hot path | It runs only after a banner-narrowing pass and in the drag-thread fallback. |
| The flip swap chain could use fewer than 2 buffers | 2 is the flip-model minimum. |

**Considered and not filed:** `gl.finish()` every frame (`opengl/Frame.zig:64`)
and `gl.flush()` every pass (`RenderPass.zig:143`). Both are deliberate: T2788's
A/B test found `glFlush` slower for glides. No cost has been measured, so no
task is filed. A re-audit should look again if the busy-phase CPU stays high
after PA-R05 and PA-R06.

## What this area does not explain

These baseline numbers have no cause in the renderer or GPU path. They belong
to the other area audits:

- 164 idle context switches per second (T2960, win32 apprt)
- about 830 MB of private memory retained after the first open/close cycle (T2961, memory)
- 34k context switches per second under output (T2964, core hot paths)
