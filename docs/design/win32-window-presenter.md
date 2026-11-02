# One presenter per window (T2610 step 2 design note)

Status: design, 2026-11-01. Implementation is T2610 step 3, behind
`GHOZTTY_WINDOW_PRESENTER`.

## Why

`test\zig-repro\t2599-wgl-multichild` proved this at the driver level, with no
Ghoztty code involved. A top-level window that has had two plain WGL children
swap into it leaks about 3 MB (the top-level's size) on every hide/show and
every minimize/restore. Destroying a second child that has swapped strands
another 3 MB. One GL child that composes every pane and swaps once stays flat
through all of it. The spike's `pres-*` rows show it: 0 per rep, and churn
returns its memory exactly. Read the repro README's T2610 section first.

Step 1 settled memory. This note settles the on-screen half: where the
presenter sits among the window's children, how panes keep owning input,
and how the rest of the renderer plugs in.

## The on-screen question

Every terminal pane HWND stays. Input, IME, focus, drag-drop, the cursor and
the IPC pane identity all key on it. But a pane HWND that overlaps the
presenter can hide or clip what the presenter draws, and the window's other
children (viewer panes, banners, the sidebar, the rearrange overlays and the
dividers the parent paints) must keep showing.

### Decision: the presenter sits between the terminal panes and everything else

Z-order inside the top-level, top to bottom:

1. viewer panes, banners, sidebar, PaneDesk and the other chrome children
2. **the presenter** (`GhozttyPresenter` class, `WS_CHILD | WS_CLIPSIBLINGS`;
   **not** `WS_EX_TRANSPARENT`, see below)
3. terminal pane HWNDs (`GhozttyTerminal`, unchanged class, **no pixel format**)

What each piece buys:

- **The presenter is clipped by everything above it, for free.** With
  `WS_CLIPSIBLINGS` its visible region already excludes viewer panes and
  chrome, so its swap never covers them. No region bookkeeping is needed for
  children.
- **Terminal pane HWNDs are fully covered, so they never paint.** They keep
  `WS_CLIPSIBLINGS`, and a window whose visible region is empty gets no
  `WM_PAINT`. They draw nothing, and there is nothing to keep out of the
  presenter's way.
- **Input falls through the presenter.** It answers `WM_NCHITTEST` with
  `HTTRANSPARENT`, which hands the hit to the next window beneath it **on the
  same thread**. So the presenter HWND is created on the UI thread, like the
  panes. Only its GL context lives on the presenter thread. `WindowFromPoint`
  honors `HTTRANSPARENT` the same way (the static-control behavior), so OLE
  drag-drop targets, `WM_SETCURSOR` and mouse activation all reach the pane.
  The presenter never takes focus and has no `WS_TABSTOP`.
- **No `WS_EX_TRANSPARENT`** (changed in step 3b, T2614). The first draft
  added it so `ChildWindowFromPointEx(CWP_SKIPTRANSPARENT)` would skip the
  presenter. But that style also takes a window out of its lower siblings'
  clipping: the panes beneath would keep a visible region and keep painting
  into the presenter's pixels, which breaks the "fully covered, never paints"
  property above. No harness hit-tests that way, so the style was dropped.
  `test\win32\window-presenter.ps1` checks the property directly: the debug
  build logs, for every pane, whether it is covered (`GetClipBox` on a cache
  DC answers `NULLREGION`) and whether a hit at its center reaches it.
- **Gaps belong to the parent.** The dividers, their hover and drag states,
  and the rearrange overlays are GDI paint by the parent, and the parent's
  `WS_CLIPCHILDREN` would clip them out of a presenter that covers the gaps.
  So the presenter's window region (`SetWindowRgn`, `bRedraw = FALSE`) is the
  **union of the terminal pane rectangles**. It is set in the same layout pass
  that moves the pane windows, and that pass then posts the presenter a
  re-compose. The parent keeps painting the gaps exactly as it does today.

### Rejected

- **Presenter at the bottom, without `WS_CLIPSIBLINGS`.** It would paint
  through the pane HWNDs, but also over every viewer pane and chrome child,
  because a swap writes the whole back buffer. Keeping those visible would
  need a region that excludes each of them, rebuilt every time any child
  moves. The chosen order gets that from the window manager.
- **Pane HWNDs as children of the presenter.** The clipping is the same, but
  every pane's coordinates and parent would change, and `GetParent` is load
  bearing across `src/apprt/win32/`.
- **Windowless panes** (one HWND, logical panes). This is the cleanest
  end state, but it rewrites focus, IME, drag-drop, accessibility and the
  IPC identity at once. It is not needed to cure the leak.
- **Layered or alpha pane windows.** Each layered child is its own DWM
  surface, which is the `pane_layer` cost (T2499) this task retires. An
  alpha-0 layered window is also click-through.

## Renderer contexts

- **The presenter context is created first**, when a window's first terminal
  pane is created, on a pixel format chosen the way the pane's is today
  (alpha when the window is or may turn translucent).
- **Pane contexts share its group**: `wglCreateContextAttribsARB(dc,
  presenter_ctx, attribs)`. `wglShareLists` after creation is refused on this
  driver (T2599). **The robustness attributes must match.**
  `WGL_ARB_create_context_robustness` fails creation when the reset
  notification strategy of the share context and the new one differ. So the
  presenter context goes through `gl_robust.createContext` with the same
  `robust_attribs`, and that function grows a `share` argument.
- **The presenter context must be current NOWHERE while a pane context
  joins its group** (found in step 3c, T2615). `wglCreateContextAttribsARB`
  refused every share while the presenter thread held its context current,
  which it does for life. The spike never met this, because its presenter
  context was current only while it presented. So
  `WindowPresenter.createSharedContext` asks the presenter thread to let go of
  its context, makes the pane's, and hands it back (bounded both ways; a
  timeout leaves that pane on its own present). A lost-device rebuild of a
  pane context needs the same pause (T2616).
- **A pane context is current on a hidden helper window, not on the pane
  HWND.** That is the measured `pres-helper` shape: 34.00 MB for two
  renderers, against 38.13 MB with each context current on its pane
  (`pres-pane`). It also keeps the pane HWND free of a pixel format, which is
  the property that ends the per-pane surface. Each surface owns one helper:
  a never-shown `WS_POPUP`, created and destroyed with the surface.

## The frame path

The seam already exists. `OpenGL.present` asks `compBegin` whether to blit
into another framebuffer (the composition path, T2466). The presenter path is
a second answer from the same seam:

1. **Renderer, in `present`:** blit the target into the pane's **slot
   texture**, one of two per pane, through an FBO the renderer owns.
   FBOs are not shared, but textures are. A planted lab frame (T2383) clears
   that slot instead, so it still reaches the screen.
2. **Renderer, at the swap site** (`OpenGL.zig`, where `swapBuffers` is
   called today): no swap. `glFenceSync`, `glFlush`, then publish
   `{slot, fence, width, height, frame id}` to the window presenter and
   signal its event. The renderer writes the other slot next. It waits until
   the presenter has released that slot, so it is never more than one frame
   ahead. That wait replaces the vsync throttle the per-pane swap gave it.
3. **Presenter thread:** wake on the event, or on a re-compose posted by a
   layout pass. For each terminal pane, take its newest published slot,
   `glWaitSync` its fence, and blit it into the pane's rectangle. Fill
   whatever the texture does not cover with the pane's background color. This
   is `fillUncoveredStrips` (`Surface.zig`) moved here, and it is the T2592 strip cure: a
   resize re-composes textures the presenter already holds, so a strip is
   never black. Then one `SwapBuffers` at swap interval 1, release the slots
   it consumed, and stamp the frame-lab trace with each pane's frame id.

A resize in the layout pass waits on the presenter's composed frame for the
new geometry, the way it waits on `frame_event` per pane today.

## Interactions

- **Lost device (T1690).** A reset is shared by the whole share group. Any
  context that sees one tells the presenter. The presenter rebuilds its own
  context first and bumps a generation number, and each renderer rebuilds
  against the new share context when it sees the bump.
  `test\win32\gl-device-lost.ps1` must cover both the presenter and a pane.
- **Composition present (T2466/T2606).** It is mutually exclusive with this.
  With `GHOZTTY_COMP_PRESENT=1` the presenter knob is ignored, and the log
  says so. A later step could make the presenter the single producer of one
  composition swap chain per window, but that is not this task.
- **Translucency.** The presenter's pixel format carries alpha when the window
  is translucent. If a window turns translucent after it was created
  opaque, the presenter is recreated, and so is every pane context sharing
  its group, through the same generation bump as a device reset.
- **Hero thumbnails (T59a)** read the offscreen target and are unaffected.
- **Banner band (T2566)** applies to the comp path only. On the presenter
  path a pane's rectangle is its grid band.
- **Pane pool (T2597) and `pane_layer` (T2499/T2502)** are forced off when
  the presenter is on, because pane HWNDs no longer present. Both are
  retired when the presenter becomes the default (step 5).

## Harness

- Scripts that count `GhozttyTerminal` children are unaffected, because the
  presenter is its own class.
- A hit-test with `ChildWindowFromPoint(Ex)` lands on the presenter (the
  presenter is not `WS_EX_TRANSPARENT`, so `CWP_SKIPTRANSPARENT` does not skip
  it either). No script in `test\win32\` uses one (checked 2026-11-01).
  App code that does should use `WindowFromPoint` on the UI thread, which
  honors `HTTRANSPARENT`.
- Pixel probes of terminal glass already ask the app, not the desktop (T275).
  The background test desktop has no composite to read, so **what the screen
  shows can only be checked on the live desktop with the user present**.
  That is T2610's T2592 criterion (0 black frames in three live runs), and
  the loop records it as NOT RUN rather than faking it.

## Open, decided in step 3

- Whether one presenter thread per window is too many on a 10-window box.
  The alternative is one presenter thread for the app, holding one context per
  window. Start per window, the shape the spike measured, and measure thread
  count and wake latency in step 4.
- The exact layout-pass wait (step 3 of the frame path) against the resize
  debounce (T2577).
