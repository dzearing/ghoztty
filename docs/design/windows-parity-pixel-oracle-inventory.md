# Pixel-assertion inventory (T1281, 2026-10-24)

Every pixel assertion in `test/win32/` as of 2026-10-24, with the region it
scores and whether that region holds anything other than its subject. Read by
three parallel sweeps of the 92 scripts and libraries that read pixels; each
line was classified from the code around the assertion, not from a grep hit.

Format: `file:line | claim | region scored | statistic | MIXED/SOUND | reason`

**Dispositions of the MIXED lines** (the full reasoning is in
`docs/design/windows-parity-tasks/T1281.md`):

- **Live false-pass risks, filed as their own tasks** - a region that mixes
  the subject with something that can pass the check alone, on a claim the
  script reports as PASS: `test-desktop-spike.ps1` CAP-1, `title-font.ps1`
  lit-pixel count, `hero-mode.ps1` carousel hash, `viewer-toc-emphasis.ps1`
  exact-wash match. Task ids are in T1281's progress log.
- **Lenient "real frame" gates - sound as gates.** About twenty whole-window
  `Get-TestDistinctColors` / `Get-TestCaptureContent` floors ("the capture is
  not black mid-paint") that chrome or child controls can satisfy alone. A gate
  that is too easy can only let the script go on to its REGIONAL assertions,
  which then measure the unpainted surface and fail; it cannot turn a broken
  subject into a PASS. Left as they are.
- **Whole-capture helpers** (`Get-TestBrightness`, `Get-TestDistinctColors`,
  `Get-TestCaptureContent` in `lib/TestDesktop.ps1`; `Changed` in
  `lib/HoverCapture.ps1`) default to the whole capture. Every current caller
  is either a gate (above) or passes a window that is itself the subject; the
  static audit `test/win32/pixel-oracle-audit.ps1` holds new walks to a stated
  region, and the helper defaults are a follow-up task.


## Partition 1

```
T1281 pixel-assertion inventory, partition 1 (test/win32). Format: file:line | claim | region scored | statistic | MIXED/SOUND | reason
Files with NO pixel assertion (verified by reading): banner-resize-repaint.ps1, bell-border.ps1, click-coord-audit.ps1 (line 138 is a string fixture for the analyzer), foreground-audit.ps1 (GetPixel/CopyFromScreen only appear inside analyzer fixture strings), fullscreen-exit.ps1, ipc-send-keys-fidelity.ps1 (Invoke-Capture is a keystroke-capture helper), key-state-pill.ps1 (structural oracles only).
Note: [weak guard] = a whole-window distinct-colour gate (usually "capture is a real frame, not mid-paint") that child controls/chrome can satisfy alone; each such script also has regional asserts that do the real scoring.

activity-monitor.ps1:652-653 | panel painted a real surface, not a flat fill | whole panel capture (inset 8, step 3) | distinct colours >= 8 | MIXED | [weak guard, backstopped by regional asserts below] the filter EDIT, the buttons and their ClearType text are children of the same capture and alone give >= 8 colours even if the owner-drawn chart/table surface were one flat fill
activity-monitor.ps1:664-665 | CPU / Memory trend chart painted in its tint | gauge band (client top .. filter-edit top), left half / right half | exact-colour presence | SOUND | exact GDI constant searched only in the band that holds that chart
activity-monitor.ps1:669-670,673 | (control) tint confined to its own half / not in table | other gauge half; table area | exact-colour absence | SOUND | negative controls over the regions that must not hold the colour
activity-monitor.ps1:1097 | error banner painted at panel bottom | bottom 60px strip of client | exact-colour presence (banner = warn mixed over panel bg) | SOUND | exact derived colour; table remainder in the strip never paints it
activity-monitor.ps1:1099 | (control) banner tint confined to bottom band | client top .. filter-edit bottom | exact-colour absence | SOUND | negative control
activity-monitor.ps1:1103-1113 (Find-BandTop 321-333, Get-ExactPixelCentroid 339-352) | banner has measurable top edge and a dismiss glyph | rows scanned up from bottom (160px), right 60px of band | exact-colour presence / centroid | SOUND | locators on exact colours, glyph search starts below the measured band top
activity-monitor.ps1:366-372 (Test-BannerUp, wait condition) | banner still up / gone | bottom 60 rows, coarse grid | exact-colour presence | SOUND | exact banner colour over the whole subject band
activity-monitor.ps1:442-449,841-847 | table header band located by its own paint | 1px-wide column at client.Right-20 | exact-colour per pixel | SOUND | locator on exact header fill
activity-monitor.ps1:536-545 (Get-TestRowPitch) | row pitch measured | 24px-wide strip per scanline | count of non-bg pixels == width | SOUND | row fill is the subject
activity-monitor.ps1:1264-1269,1346-1353,1401-1403,1420-1421,1458-1459,1471-1476,1489-1490,1504-1505 | caret row focus ring painted / absent (L, L3, L6, L7) | 6x7px box at caret row left rim; control box 6x7 further down | count of pixels != panel bg | SOUND | tiny box on the rim, before/after on same box, positive and negative controls
activity-monitor.ps1:1555-1561 | header cursor ring painted (N2) and caret-row rim yields | 5x7px box in PID header cell; 6x7 box at row rim | count of pixels != header/panel bg | SOUND | small boxes on the subject, with control

activity-selection.ps1:257-258 | capture is a real frame, not black mid-paint | whole panel capture | distinct colours > 3 | MIXED | [weak guard] the filter EDIT, buttons and header rule are in the same capture and give > 3 colours even if the table surface under test were blank
activity-selection.ps1:164-197 (Get-FirstRowY) | header band / first row located by paint | 1px column at client.Right-20 | exact channel distance == 0 | SOUND | locator
activity-selection.ps1:286-288 | panel background sampled | region below the rows (client minus margins) | mode of grid (step 3) | SOUND | mode of an area that is bare panel by construction
activity-selection.ps1:301-327 (Measure-Row: fill is wash of panel, no added chroma) | selected row fill is neutral wash | 400px-wide strip, one scanline at a time | per-line mode, then mode of line modes | SOUND | modal per line on the row itself, background sampled separately
activity-selection.ps1:334-366 | indicator bar contrast/colour/shape, fill either side | single pixels and 1px column inside the row | single-pixel | SOUND | points placed on the subject
activity-selection.ps1:376-392 | no outline / neutral outline | per-line modal colour of the row strip | per-line mode vs fill | SOUND | every line of the row itself
activity-selection.ps1:448-459 | caret rim colour/contrast | 1px column 20 DIP inside right edge, first 8 DIP of row | single-pixel walk | SOUND | on the subject

background-blur.ps1:226,236 | background see-through (blur off / on) | lower band of pane (60%-90% height, 20px side margins) grabbed over checker backdrop then blue backdrop | mean per-channel abs diff between the two grabs | SOUND | only what is behind the window can change between grabs; region is pane background below the text
background-blur.ps1:227,239,241,258 | checker behind is sharp / blurred | same lower band | mean abs dG of horizontal neighbours | SOUND | region is bare translucent background; see-through assertion alongside guards against an opaque-flat pass
background-blur.ps1:249-250 | glyph pixels render at exact fg colour, unchanged across backdrops | top 40% of pane | count of exact 00ff00 pixels; count unchanged between backdrops | SOUND | exact colour only text produces

caption-bar.ps1:231-233 | setup guard: not a mid-paint frame (throws) | whole window capture | distinct colours < 3 => throw | MIXED | [weak setup guard] caption chrome alone (the subject) satisfies it; cannot tell chrome-only from a full capture
caption-bar.ps1:244-256 | caption band is exactly 32 DIP tall (first non-chrome row) | 1px column down the window at mid-width | single-pixel walk, delta > 24 | SOUND | column through the band
caption-bar.ps1:264-272 | window top row is client chrome (derived wash) | 1 px at (mid, top+2) | single-pixel | SOUND | on subject
caption-bar.ps1:296-305 | each caption button paints a glyph | 17x9 px window centred on each button | count of pixels brighter than chrome+80 | SOUND | small window on the button; chrome is the reference
caption-bar.ps1:311-322 | min/max seam and group gap are bare chrome | 1 px each | single-pixel | SOUND | on subject
caption-bar.ps1:394,430-446 (FillShadeIn 382-387) | hover fill lights minimize, is not the firmer pressed shade, dark when drag band hovered | 1 px inside minimize slab above glyph | single-pixel, hover capture vs rest; app Changed flag (435-440) | SOUND | single pixel on the slab; Changed is a same-stack before/after frame diff with dead-space control
caption-bar.ps1:452-464 | press lights fill, release off-button un-lights | same 1 px | single-pixel | SOUND | on subject
caption-bar.ps1:556-568 | maximized: caption band fully on screen | 1px column from client top | single-pixel walk | SOUND | column through the band

chooser-kill-hover.ps1:128-143,150-176,181-187,245-246,262-266,276-281,285-299 | Kill box lights on hover, clears on leave, repeats | 28 DIP box around the Kill x; card-fill reference from neighbouring same-size patch to its left | count of pixels differing from card-fill mode by > 24, compared across states; Changed flag at 261 | SOUND | box is the subject, reference taken outside it, before/after comparisons against rest baseline

chooser-link-hover.ps1:128-162,166-170,218-252 | link underline appears on hover, clears on leave | the link control own rect | count of pixels differing from rect mode by > 24, compared across states | SOUND | rect is the link; hover can only add ink

chooser-resume.ps1:288-289 | capture is a real frame | whole chooser capture | distinct colours > 3 | MIXED | [weak guard] filter EDIT / buttons / header give > 3 colours even if the roster card surface is blank
chooser-resume.ps1:290,300-308 | cursored card picks up accent wash | 1 px on first card, before vs after | single-pixel B-channel delta > 8 | SOUND | before/after on a point inside the subject card

chooser-roster-refetch.ps1:156-158,209,225-230 | cursored last card scrolled into view | 1 px inside last card | single-pixel B delta > 8 | SOUND | on subject, before/after
chooser-roster-refetch.ps1:207-208 | capture is a real frame | whole chooser capture | distinct colours > 3 | MIXED | [weak guard] controls and chrome give > 3 colours even if the roster surface is blank

chooser-selection.ps1:303-304 | capture is a real frame | whole chooser capture | distinct colours > 3 | MIXED | [weak guard] filter EDIT / buttons / column wash give > 3 colours even if the list rows are not painted
chooser-selection.ps1:196-216 | row bg modal; pill fill is wash of bg; no added chroma | row-bg band at list bottom (mode); 1 px on pill top edge | mode; single-pixel | SOUND | mode of bare list area, single pixel on pill
chooser-selection.ps1:223-230,233-265,270-296 | row is full height; indicator bar colour/contrast/shape; fill either side; no outline | single pixels / 1px column / perimeter points on the pill | single-pixel | SOUND | all placed on the pill
chooser-selection.ps1:333,363-376 | focus rim neutral and contrasting | 1px column down the pill top 8 DIP | single-pixel walk | SOUND | on subject

chooser-session-cpu.ps1:175-189,333-335 | tinted meter bar spans the CPU column | meter column band (card top..bottom, step 2 rows) | longest unbroken run of warm-tinted pixels (R-B at least 40, R-G at least 20) | SOUND | run-length (not count) in the meter band, with negative control run at 471-475
chooser-session-cpu.ps1:331-332 | capture is a real frame | whole chooser capture | distinct colours > 3 | MIXED | [weak guard] chrome and controls give > 3 colours even if the roster meter surface were blank
chooser-session-cpu.ps1:469-470 | control capture is a real frame (negative-control run) | whole chooser capture | distinct colours > 3 | MIXED | [weak guard] same as 331-332
chooser-session-cpu.ps1:471-475 | no bar painted without capability | meter band | longest warm run < 6 | SOUND | same band as the positive run

chooser-session-sort.ps1:250-251 | capture is a real frame | whole chooser capture | distinct colours > 3 | MIXED | [weak guard] chrome/controls give > 3 colours even if cards are blank
chooser-session-sort.ps1:252-257 | first card fill sits at new position | 1 px on card vs 1 px of list-bottom bg | single-pixel R compare | SOUND | on subject vs background
chooser-session-sort.ps1:143-162,259-260,316-318 | Name header drawn (ink > 0) / not drawn on empty roster | one scanline across the Name header zone (-8..+60 px) vs bg pixel at far right of the line | count of pixels differing from bg by > 24 | SOUND | single-line zone is the header; negative-control run

chooser-sessions.ps1:206-207 | capture is a real frame | whole chooser capture | distinct colours > 3 | MIXED | [weak guard] chrome/controls give > 3 colours even if cards are blank
chooser-sessions.ps1:210-215,427-430 | first card fill lighter than pane; absent with no agent | 1 px on card, 1 px on bg; run 2 1 px | single-pixel R compare | SOUND | on subject vs control
chooser-sessions.ps1:220-226,432-437 | live card shows green liveness dot; none without cards | one scanline across card title line (Left..Right, step 2) | count of green-dominant pixels | SOUND | scan along the title line of the first card; positive and negative runs
chooser-sessions.ps1:234-242 | no green open chip after label | one scanline across name band | count of green-dominant pixels == 0 | SOUND | band lies on the card row; absence claim

chrome-merged-row.ps1:345-346 | gate: capture is real before band ink is read (Get-BandInk retries until true) | whole window capture | distinct colours >= 8 | MIXED | [weak guard] tab strip/caption chrome gives >= 8 colours; result is -1 only if never satisfied
chrome-merged-row.ps1:347-358,373,383,396 | pinned title paints in drag band, bare when unpinned/cleared | 7 scanlines x band between plus and seam, bg sampled from the group gap | count of pixels differing from bg by > 24 (at most 2 bare, at least 10 painted) | SOUND | band is the subject; before/after

chrome-theme.ps1:544-553,561-570,575-586 (A) | caption band fill == wash of base by bar_wash; debug-tint; band darker/lighter than bg | caption band (client x, 36 DIP rows) | mode (Measure-Box) and lum of the mode | SOUND | mode of the band only, derived exact colour
chrome-theme.ps1:589-593 | caption text clears 4.5:1; band holds real content | caption band | darkest/lightest pixel vs band mode; distinct >= 3 | SOUND | extreme away from the band mode within the band itself
chrome-theme.ps1:623-648 (H) | explicit window-theme decides band side | caption band | mode; IsLight(mode); extreme; distinct | SOUND | as A
chrome-theme.ps1:718 | panel capture holds real content | whole Activity Monitor capture | distinct colours >= 8 | MIXED | [weak guard] EDIT/buttons/ClearType text alone give >= 8 colours
chrome-theme.ps1:719-720,734-735,750-751,774-775 (B1-B4, Test-ShotHasColor 253-261) | panel paints system accent; cached; moves on notification; old accent gone | whole panel capture | exact-colour presence/absence (pure red / green) | SOUND | exact probe colours nothing else paints; presence plus absence pairs
chrome-theme.ps1:874-882 (D) | panel surface IS chromeBase (6 dialogs x 2 themes) | body: below 30 percent (72 percent for banner) of capture, inset 8 | mode (Measure-Box step 3) == bg; distinct >= 8 | SOUND | mode of the panel body; the claim is the surface fill
chrome-theme.ps1:898-903 | panel paints derived primary text colour | whole dialog capture | exact-colour presence | SOUND | exact derived constant (script notes luminance extremes were rejected as fakeable)
chrome-theme.ps1:1001-1009,1022-1027 (F1/F2) | viewer contents-card selected-row bar has accent hue and moves | whole contents-card (child window) capture | distinct >= 8; tallest saturated solid vertical run (Find-SaturatedBar) hue | SOUND | the card is the subject; run-length plus hue not satisfied by antialias fringes

close-glyph-white.ps1:118-119 | setup guard: not mid-paint | whole window capture | distinct < 3 => throw | MIXED | [weak setup guard] caption chrome/pane give >= 3 colours even if the close slab is not painted
close-glyph-white.ps1:120-135 | resting close slab is bare chrome | 1 px in slab vs 1 px mid band | single-pixel delta <= 8 | SOUND | on subject vs band reference
close-glyph-white.ps1:143-146 | lit close slab fills red | 1 px at slab left edge | single-pixel | SOUND | on subject
close-glyph-white.ps1:151-164 | glyph lighter than red fill, none darker | 19x13 px patch centred on close button | counts of pixels lighter/darker than fill by lum | SOUND | patch is the slab plus glyph

color-contrast.ps1:154-166 (Read-Step) and 215,222,226,233,252-254 | foreground/palette/truecolor contrast vs bg | 24x24 px patch at pane centre, pane own pixels via capture-pane IPC | pixel with maximum WCAG ratio vs bg in the patch | SOUND | pane-only capture, no chrome; fixture draws solid blocks/text at the centre (max over patch is the documented intent)

config-errors.ps1:85-98,165 | config-errors dialog capture holds real content | whole dialog capture | distinct colours >= 8 | MIXED | [weak guard] child buttons can supply >= 8 colours over an unpainted black dialog surface, the exact mid-paint case it is meant to exclude
config-errors.ps1:94,166 | config-errors dialog renders dark | dialog client rect (inset 8) | mean luminance < 90 | SOUND | the dialog is the subject; wide threshold
confirm-dialogs.ps1:81-99 (Assert-Dark at 176,229,260) | close / window-close / About dialog capture holds real content | whole dialog capture | distinct colours >= 8 | MIXED | [weak guard] same as config-errors: child buttons can supply >= 8 colours over an unpainted black dialog
confirm-dialogs.ps1:90,100 (176,229,260) | dialogs render dark | dialog client rect (inset 8) | mean luminance < 90 | SOUND | dialog is the subject
dark-menus.ps1:86-109,141-142,154-155 | surface and tab-bar context menus dark/light by theme | popup menu window (inset 8), torn capture | mean luminance (under 90 dark, over 160 light) gated by distinct >= 8 | SOUND | the menu window is the whole subject; wide thresholds; both themes plus -NegativeControl

desk-variant.ps1:194 | desk probe gate | whole window capture | distinct < 4 => return null (SKIP) | MIXED | [weak guard, only produces a SKIP] chrome gives >= 4 colours even if the desk margins are unpainted
desk-variant.ps1:199-200,292-303,346-348,384-387 | desk gradient same/different between windows | two 1 px samples (right margin, bottom margin) | single-pixel channel distance | SOUND | points on the desk, compared across windows

hero-mode.ps1:263-279,509-517 | carousel thumbnails visibly update while a busy TUI runs in a HIDDEN pane | top-window capture from client x = hero.Right+10 to right edge, y 40..H-10, step 7 | hash of sampled pixels changes between captures | MIXED | the column holds every tile, including the hero pane own tile and the band; the script itself (comment 827-832) says live tile snapshots with a blinking cursor refresh on their own schedule, so a different hash can come from another tile or a cursor blink while the hidden pane thumbnail never refreshes
hero-mode.ps1:510 | carousel capture holds real content | same carousel column region | distinct sampled colours >= 4 | MIXED | band backdrop, tile borders and placeholder fill give >= 4 colours without any thumbnail content
hero-mode.ps1:335 (gates 911,964,982) | divider strip capture is real | whole window capture | distinct below 8 => null | MIXED | [weak guard] caption/strip chrome gives >= 8 colours independent of the divider
hero-mode.ps1:577-578,1100-1102,1104 | phase-1 carousel shot / T59b window shot is a picture of a window | whole top-level window, 48x48 sample grid inset 8 | distinct >= 8 and top-colour share at most 0.90 | MIXED | whole window mixes chrome, carousel and the terminal glass; script comment (384-390) records the window scores 23 distinct / 0.60 top share with the terminal glass flat-filled, so chrome and carousel alone pass the floor
hero-mode.ps1:585,590 | hero pane / HIDDEN pane renders content | pane own capture (capture-pane IPC), inset 2, step 4 | distinct colours >= 8 | SOUND | pane-only pixels, no chrome
hero-mode.ps1:910-917 | divider mark painted in split-divider-color, markPx wide | one scanline across the divider band (grab+8px) | longest run of pixels within tol 12 of c86400 | SOUND | exact-colour run length on the band row
hero-mode.ps1:956-971,978-989 | divider changes colour on hover / on grab | same scanline, rest-run range only | no pixel in the rest run matches rest colour | SOUND | same row as rest reading, hover frame from Get-TestHoverCapture
hero-mode.ps1:856-862,959-962 | tile / divider hover paints a different frame, dead-space paints nothing | whole window before/after taken by the app on one GUI stack (Changed flag) | app-computed frame diff | SOUND | only hover can change in the gap; dead-space control present

hero-viewer-tile.ps1:154-184,314,318-326 | each carousel tile painted (border stroke found); exactly one neighbour slot is the viewer | ring of 3px either side of predicted tile left/right edges, every 9px | max R over ring >= 60 | SOUND | predicted tile rect; backdrop and placeholder are below 60 so only a painted tile passes; xor control
hero-viewer-tile.ps1:331-332 | tile carries content / viewer tile carries the page not a placeholder | tile interior (inset 3, step 5) | distinct colours >= 4 | SOUND | region is the tile only; placeholder is one flat colour

hover-capture.ps1:171-173 | probe gate | whole window capture | distinct below 8 => null | MIXED | [weak guard] caption/strip chrome gives >= 8 colours independent of the hover fill
hover-capture.ps1:190-191 | the capture has real chrome in it | whole window hover capture | distinct colours >= 8 | MIXED | claim names chrome but any content in the window can satisfy >= 8; does not discriminate chrome from non-chrome
hover-capture.ps1:174-176,238-254,285-292,303-304 | hovering lights its own fill (rounded), not the other control; stable over 12 captures; gone next frame | 2 px per control (top edge, corner) | single-pixel R compared to rest | SOUND | points on the control, with other-control and rest controls
hover-capture.ps1:207,228,287 | capture is a frame the move changed | whole window before/after taken by the app | app-computed Changed flag | SOUND | same-stack before/after

ipc-machine-chooser.ps1:166-176,447 | chooser capture holds real content | whole chooser capture | distinct colours >= 8 | MIXED | [weak guard] filter, buttons and column wash give >= 8 colours even if list rows are unpainted
ipc-machine-chooser.ps1:480-494,529-535,548-551,564-565 | selection pill inset, neutral unfocused, fill steps up and accent on mark when focused, reverts | single pixels (gutter/pill/unselected); mark band and pill band boxes of the selected row | single-pixel; max of B minus R in band | SOUND | bands are inside the selected row, positive/negative states compared
ipc-machine-chooser.ps1:533,545,547 | Tab onto list repaints the focused row | pill band of selected row | position-weighted pixel checksum differs | SOUND | only the row can change between captures
ipc-machine-chooser.ps1:562,589-591 | text column starts at composed text_x | row 0 band, left 110 DIP | first column with a pixel >= 200 in all channels | SOUND | text colour 230 vs glyph ramp about 160, band inside the row
ipc-machine-chooser.ps1:598-600 | filter shows cue banner while empty | edit interior inset 4 | count of pixels differing from grey 30 by more than 12, at least 40 | SOUND | region is the edit interior
ipc-machine-chooser.ps1:636-647 | machine column is a wash, rule divides columns | 1 px each in column, pane, and 3 candidate rule columns | single-pixel / max of 3 | SOUND | points on the subject
ipc-machine-chooser.ps1:917-918 | signed-in capture holds real content | whole chooser capture | distinct colours >= 8 | MIXED | [weak guard] chrome/controls give >= 8 colours even if the account band is blank
ipc-machine-chooser.ps1:921-935 | monogram disc filled with pinned accent and carries a letter | 1 px inside disc; disc interior inset 6 | single-pixel colour match; count of non-fill pixels >= 10 | SOUND | on the disc
```

## Partition 2

```
# T1281 pixel-assertion inventory, partition 2 (test/win32). Read-only audit.
# Format: file:line | claim | region scored | statistic | MIXED or SOUND | reason
# Scripts with NO pixel assertion: notification-click-real.ps1 (CopyFromScreen only in a comment), printclient-audit.ps1 (static source audit), readonly-badge.ps1 (structural only), resize-flicker.ps1 (schedule oracles only), split-zoom-nav.ps1, tab-tooltip.ps1. pane-sidebar-drag.ps1:236 saves a PNG as evidence only.

menu-bar.ps1:712-713 | A: window capture holds real content | whole window | distinct colours >=8 | SOUND | precondition guard only; the claims it protects are scored by region below with a blank-square control
menu-bar.ps1:785-786 | A: caption menu button paints a glyph (or NONE under NegativeControl) | one 34x26 box on the button | count of pixels >24/channel from the box mode | SOUND | box is on the subject; mode of the box is the band fill
menu-bar.ps1:790 | A: blank strip control has no ink | box at DeadX between plus hit box and next item | ink count vs box mode | SOUND | control box, blank by construction
menu-bar.ps1:791 | A(T260): strip right end paints no menu glyph | one BtnPaint square at strip right end | ink count vs box mode | SOUND | region is the subject square; sibling controls prove the probe sees ink
palette-order.ps1:588-607 | O10d: install row has accent outline | 1 px at row left inset vs bg pixel at bottom-right | single-pixel compare | SOUND | pixel on the subject row, row 3 is the control
palette-order.ps1:590-607 | O10d: install row carries a solid version pill | trailing 110 DIP of one row, rows +3..-3 | longest non-bg identical-colour horizontal run | SOUND | band is the row pill region; row 3 in same capture is the control
palette-order.ps1:715-724 | O11a/b/c: row title band paints ink (>=40 px; empty row <40) | one row title band | total pixels minus mode count | SOUND | band is the subject row title; positive and negative controls
pane-busy-light.ps1:134 | gate: window capture not empty before probes (else SKIP) | whole window | distinct colours >=4 | SOUND | gate only (converts to SKIP); verdicts are single-pixel rim probes diffed against a baseline
pane-busy-light.ps1:138-217 | busy-light ring/bar lights the card rim, red on error, dark when off/expired | 5 single pixels on card rim / desk / top edge | single-pixel RGB-sum lift vs same pixel baseline | SOUND | diff of the same pixels before/after, placed on the subject
pane-sidebar-activity.ps1:78-99,156-225 | rail/panel animates while busy (>=3 distinct frames), still when idle/question/bell (==1), bell dot changes picture | sidebar child window only | MD5 of sidebar capture; distinct hash count / before!=after | SOUND | the captured window is the sidebar itself
pane-sidebar-all-windows.ps1:263-268 | outline paints content | sidebar window only | distinct colours >=3 | SOUND | capture is of the sidebar hwnd (subject)
pane-sidebar.ps1:217-218,242-243 | rail / panel paints content, not one flat fill | sidebar window only | distinct colours >=3 | SOUND | capture is of the sidebar hwnd (subject)
pane-banner.ps1:430,580,1156-1170 (+921,1247,1278,1376 as probe guards) | overlay capture holds real content / card painted on every render | banner OVERLAY window only | distinct colours >=8 | SOUND | the overlay is its own window containing only the card, no terminal
pane-banner.ps1:435-447 | composited card is white@6% wash ~30,30,34 (inverted under NegativeControl) | 1 px at (0.9w, 0.72 oneLineH) in overlay | single pixel +-3 | SOUND | single pixel on the card where sheen/shadow ramps are out
pane-banner.ps1:455-456 | band corner is exactly pane background 16,16,20 | 1 px at (2, half one-line height) | single pixel exact | SOUND | single pixel in the card outer margin
pane-banner.ps1:471-480 | elevation shadow darkens band under the card | column x=w/2, 13 rows above overlay bottom | darkest pixel channel-sum <52 | SOUND | small strip on the shadow area
pane-banner.ps1:488-505 | T1900 card corner tight (3px-in sum >67) and still rounded (tip < in-10) | 2 single pixels near bottom-left card corner | single-pixel channel sums | SOUND | single pixels on the subject, mutually compared
pane-banner.ps1:584-585 | checked task-list box paints native green (>=3 green px) | 75x75 box at overlay origin | count of G-R>60 and G-B>60 pixels | SOUND | only the check stroke is green on a grey card; box is within the overlay card
pane-banner.ps1:921-1000 | hovering chevron lights a fill, rounded, follows pointer, same value across 12 hovered captures | 2 single pixels per capture (top edge, top-left corner of chevron square) | single-pixel R vs rest capture, plus Changed flag | SOUND | single pixels on the subject with rest and cold controls
pane-banner.ps1:1081-1170 (T745) | value column uses >=85% of content width on every render | content columns of overlay, all rows | rightmost pixel >200 channel-sum from region mode | SOUND | region excludes the chevron column; threshold exceeds shadow/fade gradients; text is the subject
pane-banner.ps1:221-250,1248-1308 (T377) | wrapped line fills content column; nothing paints in chevron reserved gap | first content row band of overlay, ink vs same-row reference pixel | rightmost ink x; ink count in gap (R delta >12) | SOUND | two sub-regions of the subject row; rightmost-ink claim guards the zero-ink claim
pane-banner.ps1:1361-1440 (T165) | link underline present, dotted at rest, solid on hover | whole overlay (single-link banner) | bottom-most row with B-R>40: span and ink count | SOUND | overlay holds only the card; link blue distinct from grey wash; rest vs hover compared
pane-capture.ps1:150-151,210-211 | pane renders content | whole capture-pane image | distinct colours >=8 | SOUND | capture-pane is the pane own renderer output (no chrome); pane-glass=false so no gradient supplies colours
pane-capture.ps1:165-188,208-209 | pane A/B carry their own tint; downscaled/hidden capture still that pane | whole capture-pane image | mode colour within tolerance 6; A != B | SOUND | mode of the pane own glass is its background; B is a control for A
pane-elevation.ps1:242,273,508,613,766,1013 | gate: window capture not empty (else SKIP) | whole window | distinct colours >=4 | SOUND | skip-gate only; verdicts are single-pixel probes on margin/desk
pane-elevation.ps1:248-250,276-277,336-337,390-404,472-476,549,619,637-642,719-732,846-848,880-892 | desk shows in margins/gaps/chrome/banner margin (Test-DeskPixel: blue>red+12, sum 45..420) | 1 px at margin, gap, 8 chrome samples, dim-overlay centre | single-pixel predicate | SOUND | each pixel placed on the margin/gap/band it names; predicate excludes terminal black and neutral grey; dim-overlay centre is the overlay own fill
pane-elevation.ps1:167-188,328,435 | glass pane blank area is desk through glass; ends differ; solid/translucent keep terminal black | capture-pane image, 3 single pixels (10%/90% at 90% height, right edge) | single-pixel RGB tests, distance | SOUND | pixels in blank pane area of the pane own capture
pane-elevation.ps1:389-393,404-410,757-758,842-860 | glass sheet = 40% black over desk; carousel band 30% shade; glow lift; dim tints | pairs of single pixels (pane edge vs desk beside it) | single-pixel distance to computed value | SOUND | single pixels on the subject edges compared to the adjacent desk
pane-elevation.ps1:520-562 | glass chrome: caption band/strip are desk; ends differ; bottom row meets desk; title reads 4.5:1 | 8 single pixels in caption/strip + 2 end + 2 edge pixels; title ink = brightest pixel in caption rows (Top+4 .. +26 scale) x (left+8 .. 40% width) | single pixels; brightest-pixel extremum for title contrast | SOUND | pixel probes sit on the band. BORDERLINE: the 4.5:1 ratio uses the single brightest pixel in the left 40% of the caption band, so any bright non-title glyph there (app icon, menu dots) would count as title ink; not confirmed what else is painted in that band
pane-elevation.ps1:1016-1028 | header band corner is desk, just inside curve is band colour | 4 single pixels at band corners | single-pixel | SOUND | single pixels on the subject
pane-elevation.ps1:1067-1072,1109-1116 | viewer card rim is the page colour, not the terminal or white | 1 px at card bottom rim | single-pixel distance | SOUND | single pixel on the rim row
pane-sidebar-elevated.ps1:118,191,230,363,413 | gate/assert: window capture has content | whole window | distinct colours >=4 | SOUND | precondition only; verdicts are single-pixel probes
pane-sidebar-elevated.ps1:195-217,234-251,372-378,416-418 | desk runs under rail/column/panel; card is 30% glass / 38% wash; no seam/rule; solid card is not desk | 2-4 single pixels per case | single-pixel Test-DeskPixel / colour distance | SOUND | each pixel placed on the named element, compared to an adjacent desk pixel
pane-stack-strip.ps1:211-226,420-440 (D1) | tucked pane strip colour exact (opaque or glass), >=8 DIP wide, rounded/square corners | 1 px per probe + walk along ONE scanline while colour matches | single-pixel Test-Near; run length of matching pixels | SOUND | pixels and scanline inside the strip rect
pane-stack-strip.ps1:228,473-487 (D7) | hovering a strip lightens its scrim; elsewhere leaves it at rest | 1 px mid-strip, 3 px in from trailing edge, rest vs hovered vs elsewhere | single-pixel Test-Near + sum compare | SOUND | single pixel on the strip with Changed flag and cold control
pane-stack-strip.ps1:234-249,501-510 (D2) | banner title ink runs further down the strip for a long title | strip own column band x pane rows | count of rows with any pixel >90 from strip colour | SOUND | band is the strip only; short-vs-long compared on same band
printclient-audit.ps1 (no pixel assertion) | static audit of Get-TestWindowPixels call sites | n/a | n/a | SOUND | not a pixel assertion
profile-latency.ps1:409-418 | viewport moved on scroll_to_top | terminal surface hwnd (PrintWindow) | MD5 hash differs before/after | SOUND | diff of the surface only; chrome is not in the region
rdp-session.ps1:284-310,547-560 (S1,S2,S3) | self-test: sampler returns 0..255; drift verdict passes steady/fails fading synthetic series | 256x256 screen block at 0,0; synthetic series | mean luminance / arithmetic | SOUND | checks the sampler returns a number in range and the drift arithmetic; no product claim
rdp-session.ps1:587-621 (G3,G4) | viewer pane composite shows content (head>8) and does not keep darkening | viewer pane rect inset 8 px, downscaled 16x16 | mean luminance per sample; head-quarter vs tail-quarter mean of the SAME region | SOUND | region is the pane (viewer + dim overlay composite, the subject); drift is a same-region before/after
rearrange-drag.ps1:149-157,290,329,349 | carried pane header is marked (colour differs), staying pane keeps resting colour, mark clears on drop | 1 px per pane, 2 rows below header band top | single-pixel colour string compare | SOUND | single pixels on each header band, press/rest/after as controls
remote-pill.ps1:197-199,260-264,361,432 | connected pill paints green dot; red when relay drops; green again | 1 px at dot / capsule trailing fill | single-pixel IsGreenish / IsReddish | SOUND | single pixel on the pill; negative control forbids green
remote-pill.ps1:447-458 | local window paints no pill: band left of the menu button is plain chrome | 30 single pixels along the pill row vs one reference pixel | per-pixel RGB-sum delta <=24 | SOUND | sampled strip is exactly where a pill would be; blank captures are refused by the uniform guard and the remote window in the same script is the positive control
split-dim-viewer.ps1:151-155 | overlay own fill colour (exact) | 1 px at centre of the DimOverlay window (AllowUniform) | single pixel exact match | SOUND | single pixel on the overlay; exact colour a dead capture cannot produce
split-dim.ps1:162-166 | overlay fill colour follows config / default background | 1 px at centre of the DimOverlay window (AllowUniform) | single pixel exact match | SOUND | same as above
tab-color.ps1:90-100 (baseline/red/persist/clear asserts) | tab 0 shows red accent stripe after Red, none on untagged tab, persists, cleared by None | 1 px-wide column x stripeH rows at the tab centre x | any pixel within tol 40 of 255,69,58 | SOUND | column inside the stripe band at that tab; tab 1 and baseline are controls; whole-window distinct>=8 only gates the retry loop
title-font.ps1:112-148 and assert ~line 164 (litA>20 "default font: tab bar draws text") | tab bar draws title text | rect x: ClientLeft+8 .. +tabW+plusW-2, y: ClientTop+4 .. +BarH-5, every 2nd column | total count of lit pixels (R+G+B>300) | MIXED | the rect spans the title text AND the plus button glyph (plusW is included deliberately); the plus mark alone is a 28 DIP-square glyph with ~14 px arms, a few dozen lit pixels in the sampled columns, so lit>20 can pass with no title text drawn at all
title-font.ps1:112-200 (diff A-vs-B>=25, B-vs-C<=15, C-vs-D>=25, A-vs-D<=15) | font family changes / reproduces the tab-bar raster, live reload re-fonts | same rect (title + plus) | sum of absolute column-count differences between launches | SOUND | differences of the same rect across launches; the plus cancels, only title text can move the diff; A-vs-B>=25 fails if no title text exists
title-jitter.ps1:119-136,223-265 (1a control, inked count, 1b identical, 1c ascii differs) | spinner glyph frames render differently in the cell; title text past the cell identical across frames; ASCII lead shifts it | cell box and text box (textL..textL+320) in caption band rows | per-column ink bit-string vs a band-background pixel; count of distinct strings | SOUND | boxes are the title cell / text only, background sampled in the drag region; frame-vs-frame compare of the same box, with sensitivity controls
title-jitter.ps1:137 | gate: window capture holds content | whole window | distinct colours >=8 | SOUND | gate only (retry loop)
split-divider.ps1:229-244,254-264,394-402,439,513-515 | divider gap has configured colour (red/cyan/derived 90,89,89); old gray gone; reload recolours | 3 columns across the gap (30/50/70% along) from A.Bottom-2 to B.Top+2 (2 px into each pane) | any pixel within tol of a colour | SOUND | strip crosses the divider band; positive controls (red present, cyan after reload) in the same script. Note: absence asserts (not HasColor) pass on a null capture
split-divider.ps1:300-308,649-665 | gutter is 6 DIP, visible line is band px wide and >=2 px | 3 columns across the exact gap rows | count of pixels matching rest gray | SOUND | region is exactly the gap
split-divider.ps1:660-760 | rest/hover/drag/unhover gray (90 vs 115) | exact gap strip (+ hovered capture) | any gap pixel within tol 6 | SOUND | strip is the divider band; hot vs rest asserted both ways
split-divider.ps1:800-845 | T251 divider clears 3:1 contrast on black at rest and hover; not raw 0a0a0a | exact gap strip | max WCAG contrast over strip pixels vs black | SOUND | max over the gap strip only (line + black gutter)
split-divider.ps1:949-1160 | T155/T734 after drags/resizes: one divider run of exact width, centred, clean gutter, one run across a composited scanline (raw un-composited scan >1 as counter control) | gap strips at 20/50/80%; one full scanline across both panes + gap on a composite | count/length of runs of pure green 0,255,0; stray non-black count | SOUND | exact colour match with a built-in positive control (raw count >1)
tab-strip.ps1:278,1006,1137 | gate: capture has real content | whole window | distinct colours >=8 | SOUND | gate only; verdicts are strip-scanline or small-box measurements
tab-strip.ps1:293-322,441-447 (sections 1,3,4,5,7 extents) | selected chiclet extent, never spans client, bounds, follows adds | 1 scanline 2 px above strip bottom across client width | longest run of pixels with R,G,B<10 | SOUND | scanline is in the strip; longest dark run is the chiclet
tab-strip.ps1:326-333 | selection: no full-width blue accent rule | bottom 3 rows of the strip, every 2nd px | any pixel within 24 of 3D,8E,F8 | SOUND | strip is the subject; capture content guarded; sibling asserts prove the strip scans
tab-strip.ps1:481-488 | dead space right of tab is bar background | 2 single pixels | max channel delta <=8 | SOUND | single pixels on the strip
tab-strip.ps1:504-516 | seam row has no rim | row at strip bottom vs row 5 px up, across tab width every 4 px | max channel-sum seam <= interior+6 | SOUND | rows inside the selected chiclet
tab-strip.ps1:527-586 | plus glyph margins, bottom gap, symmetry; close x centred; plus and x share a centre | box scanning the plus slot / the close-x square | lit-pixel bounding box (lit = bar + 90) | SOUND | slot-limited boxes with positive controls (mLeft>=0, xL>=0); lit relative to the bar own pixel
tab-strip.ps1:733-815 | inactive tab is a surface (delta>=6 vs strip, differs from selected); inter-tab gap = strip background | single pixels at tab centres and gap middle | single-pixel R delta | SOUND | single pixels on tab fills and gap
tab-strip.ps1:826-840 | rim brighter than fill and strip; rim fades down the tab; selected tab flares | 3 short horizontal scans at tab top / right edge rows | max luminance of a scan; rightmost differing px | SOUND | short scans on the tab own edge rows
tab-strip.ps1:882-912 | top-left arc antialiased (>=5 distinct, >=1 not strip/fill) | arcPad x arcPad box at the selected tab top-left corner | distinct R values in a small corner box | SOUND | box holds only strip + tab pixels by construction; distinct count is the claim
tab-strip.ps1:1006-1060 | hover on plus / close x lights a rounded fill, only the hovered one | 2 single pixels per button per capture | single-pixel R vs rest +8 / corner < edge-5 | SOUND | single pixels on the subject with a positive control (plus) and Changed flag
tab-strip.ps1:1339-1363 | long-title tab capped at 50% of run; short tab selected and measurable | scanline extent | longest dark run | SOUND | same as extents above
test-desktop-harness.ps1:145-151,715,853-870 | harness: light chrome reads bright (>150), dark reads dark (<100), separation >=100 | caption rect (Left+6..Right-6, Top+6..Top+34), every 2nd px | mean luminance | SOUND | rect is the caption band (GDI chrome), terminal surface outside it; dark and light together prove the separation
test-desktop-harness.ps1:370-460 (section C) | content floor fires on flat / near-uniform bitmap, passes busy bitmap and committed hero screenshot; uniform guard passes band-only maximised capture | synthetic bitmaps and a committed PNG | Get-TestCaptureContent distinct/top-share, Test-TestCaptureUniform | SOUND | self-test of the helpers on constructed images, which are the controls. Note the committed hero PNG has flat terminal glass by design, so chrome alone satisfies that floor; that is the floor documented purpose (capture not dead), not a surface claim
test-desktop-harness.ps1:659-661 | uniform guard does not refuse a real chrome window | whole top-level window | distinct colours >=8 | SOUND | claim is exactly that the guard accepts chrome-bearing captures
test-desktop-harness.ps1:667-690 | terminal surface child captures as a flat fill and does not move when it renders more text | GhozttyTerminal child window only | distinct <=2; mean lum within 1 | SOUND | region is the pane surface (subject of the documented limit); route-0 comparison is the positive control
test-desktop-harness.ps1:697-703 | route 0 (capture-pane) sees real content in the same pane | whole capture-pane image | distinct colours >=8 | SOUND | the pane own renderer capture; foreground set so text exists
test-desktop-spike.ps1:441-453 (CONFIRMED T1115 fix) | PrintWindow samples are taken per region: terminal child rect, chrome band (0,0,W,sy), everything below chrome | three SampleRect regions out of one bitmap | mean lum + distinct per region | SOUND | comment ~line 645 and header 52-70 confirm the whole-window mean was replaced; CAP-3 chrome band is the positive control for CAP-4
test-desktop-spike.ps1:662-666 (CAP-3) | PrintWindow returns the window CHROME | chrome band above the terminal child | distinct >4 | SOUND | region is the chrome subject
test-desktop-spike.ps1:667-671 (CAP-4) | terminal surface comes back flat | everything below the chrome band, full width | distinct <=2 | SOUND | region is surface plus thin frame; chrome-band positive control (CAP-3) in the same bitmap
test-desktop-spike.ps1:672-676 (CAP-5) | chrome and surface differ by an order of magnitude | the two regions above | distinct ratio | SOUND | both regions scored separately
test-desktop-spike.ps1:651-654 (CAP-1) | CopyFromScreen/BitBlt is dead on a background desktop | WHOLE WINDOW BitBlt bitmap (0,0,WinW,WinH) | real = mean lum >60 AND distinct >4; asserts NOT real | MIXED | whole-window mean luminance is dominated by the dark terminal surface; header line 78 records a WORKING whole-window BitBlt on the interactive desktop reading mean 55 / 406 distinct, which is <60, so a live capture would score not-real and the BitBlt-is-dead assertion would pass; a failed BitBlt (-1) is indistinguishable from a working capture of a dark window. The T1115 region fix covers CAP-2..6 but not CAP-1
test-desktop-spike.ps1:677-679 (CAP-6) | PrintWindow(flags=0) succeeds | n/a (API return) | boolean | SOUND | not a pixel assertion in effect
```

## Partition 3

```
T1281 pixel-assertion inventory, partition 3  (paths relative to D:/git/ghoztty-b/test/win32)
Format: file:line | claim | region scored | statistic | MIXED/SOUND | reason

== Files with NO pixel assertion (grep hits were comments, prompt text, log tallies or fixture bitmaps) ==
update-progress.ps1, upgrade-no-fork.ps1, viewer-composer.ps1, viewer-feedback-capture.ps1 (Get-CaptureTally = stderr log),
viewer-feedback-carousel.ps1, viewer-feedback-images.ps1, viewer-feedback-utf16.ps1 (New-TestBitmap = fixture PNG pasted in, nothing read back),
viewer-feedback.ps1, viewer-html.ps1, viewer-image.ps1 (Bitmap fixtures only), viewer-worktree.ps1,
lib/ClickCoordAudit.ps1 (static audit), lib/ForegroundAudit.ps1 (static regex audit), lib/WebViewCdp.ps1 (comment only),
lib/DesktopCapability.ps1 (hard-coded capability facts), lib/ComposerSurface.ps1 (stderr-log matcher).

== Scripts ==
translucent-window.ps1:221-229 | A: glyphs opaque (>=20 pure 00ff00 px, 98 pct unchanged over checker vs blue backdrop) | top 40 pct of pane client | count of exact-colour px + same-in-both ratio | SOUND | counts only exact foreground-green px (backdrop is white/red/blue so chrome/background cannot supply any), same px compared across two backdrops
translucent-window.ps1:233-234 | B: terminal bg shows backdrop through | bgRect lower 60-90 pct of pane client (empty bg) | mean per-channel abs diff checker vs blue >=30 | SOUND | empty pane background only; before/after backdrop swap where only a translucent subject can change
translucent-window.ps1:237-238,257-258 | C/D: caption band opaque (also after split) | caption band 18 DIP rows, 45-65 pct of client width | mean diff <=2 | SOUND | region is wholly caption band (title text identical in both captures)
translucent-window.ps1:245-246,250-251 | F: F9 toggle opaque (<=2) then translucent (>=30) | bgRect as B | mean diff | SOUND | same bgRect as B, only subject changes
translucent-window.ps1:272-274 | E: viewer nav bar opaque | whole GhozttyViewerNav window rect | mean diff <=2 | SOUND | region is exactly the nav bar window (a small translucent sub-area would be diluted by the mean but is all subject)

viewer-error-card.ps1:328-329 (A/B) | pane paints configured bg in clearance band | band x=2..Margin-2, +-8px about card mid row | MODE | SOUND | band is subject-only by construction
viewer-error-card.ps1:314,333 (A/B) | a card is painted | single row through card vertical middle, whole pane width | first/last x != bg | SOUND | row is in the gap between text lines so only card fill/rim can be on it; run ends then pinned to exact layout
viewer-error-card.ps1:340 (+206-223) | both card vertical edges are a colour transition | 4 single px at Left-1/Left, Right-1/Right on mid row | single-pixel compare | SOUND | single-pixel samples on the subject
viewer-error-card.ps1:346-353 | card edges at exact layout x, centred, clears margins | run First/Last on mid row | equality of first/last non-bg x | SOUND | extra non-bg content breaks equality, cannot satisfy it
viewer-error-card.ps1:355-359 | card top/bottom at exact layout y | column through card centre, +-Margin | first/last non-bg y equality | SOUND | column bounded to card neighbourhood (nav bar excluded)
viewer-error-card.ps1:365-371 | card fill differs from pane bg | card interior inset 2px | MODE | SOUND | mode of card interior
viewer-error-card.ps1:373-395 | message/hint text contrast >=4.5 vs measured fill | each text-line rect inside card padding | Darkest/Lightest extreme away from fill, WCAG ratio | SOUND | rect is the text line inside the card; absent text gives ratio 1 and fails
viewer-error-card.ps1:399-407 | card rim contrast >=3 | 1px at run.First,midY | single-pixel | SOUND | single pixel on rim
viewer-error-card.ps1:454-456 (C control) | no card when runtime found | same 4 edge px | single-pixel compare count==0 | SOUND | same oracle as A/B asserted inverted
viewer-error-card.ps1:466-467 (C control) | live web view covers host paint | clearance band as A/B | MODE != bg | SOUND | same band/statistic as A/B, inverted

viewer-feedback-alpha.ps1:399-404 | transparent half of pasted PNG shows tile fill | 1px at quarter-width of image vs 1px in inset ring | single-pixel colour-near (6) | SOUND | two single pixels on subject tile
viewer-feedback-alpha.ps1:411-415 | tile fill / transparent half not black | same 2 px | single-pixel distance from black >24 | SOUND | single pixels on subject
viewer-feedback-alpha.ps1:418-420 | opaque half still carries picture colour | 1px at three-quarter width | single-pixel near red (24) | SOUND | single pixel on subject

viewer-find.ps1:353-359 | find card paints real chrome, not flat fill | whole GhozttyFindCard window (inset 8, step 3) | distinct colours >=3 | SOUND | capture window IS the card, no non-card content in region

viewer-toc-emphasis.ps1:254-257,302-304 | card capture holds real content (positive control) | whole GhozttyViewerTOC window | distinct colours >=8 | SOUND | window is the card itself; capture-alive control only
viewer-toc-emphasis.ps1:261-266 | measures card fill (feeds derivations; asserts non-null only) | whole card, step 2 | MODE | SOUND | mode of card window is its fill
viewer-toc-emphasis.ps1:272-278,306-308,343-344 (lib/SelectionBar.ps1:20) | A/C accent indicator bar present+narrow; B accent absent | whole card window | tallest solid saturated vertical run >=10px of one colour + hue test | SOUND | shape-based (glyph fringes cannot form a solid 10px run); no concrete non-bar content identified that forms one
viewer-toc-emphasis.ps1:280-283,313-315 (Test-CardHasColor l.161-169) | A: row fill is neutral focused wash; B: selected row still marked in unemphasized wash | WHOLE card window | exists any px exactly equal to derived wash RGB | MIXED | region is the whole card, not the selected row: label-text antialiasing ramps (fill to ink) and any other row/header/rim wash pass through intermediate colours, so an exact-RGB match for a 10-16 pct wash step can come from non-selected-row pixels when the selection fill is missing (the paint-nothing build in B is the case it claims to exclude)

viewer-narrow-pane.ps1:480-490,560-561,599,601 | E: leading nav slot carries a control; narrow overflow has fewer ink rows than wide first button | leading slot box of GhozttyViewerNav capture, left of address EDIT | count of rows with any px differing >40 (L1) from bg px at top-right | SOUND | box is the slot subject; field area deliberately excluded (T1400)
viewer-narrow-pane.ps1:468-489,578,592 | E: narrowing never adds ink slots; narrowest band more compact | per-slot boxes along button strip, stop at EDIT left | count of slots with any ink row | SOUND | each slot box is subject; bg is a single reference px
viewer-narrow-pane.ps1:745-789 | F: wheel scrolls list under header | 6 rows at y0=margin*6, x<200 of TOC capture, before vs after wheel | diff px count >0 | SOUND | before/after strip where only list content can change
viewer-narrow-pane.ps1:748-798 | F: rows read THROUGH pinned translucent header | header band (margin+2 .. margin+header-2), x<200 | diff px count >0 before vs after scroll | SOUND | band is header only (rim/seam rows dropped); only see-through header changes under scroll; list-row diff is the positive control (threshold >=1 px, so a stray repaint in band would also pass)

window-color.ps1:147-162,220 | banner capture holds real content (positive control) | whole GhozttyBannerOverlay window, inset 2 | distinct colours >=2 | SOUND | window is the banner band itself
window-color.ps1:136-140,159,221 | tint reaches banner band fill | 1px at (2,2) of overlay | single-pixel exact | SOUND | single pixel on band fill
window-color.ps1:229-232 | glass capture holds real content | whole pane GL capture (capture-pane IPC), step 4 inset 2 | distinct colours >=4 | SOUND | capture is pane-only (app readback), no chrome in it
window-color.ps1:230,233 | tint reached GL clear colour | whole pane GL capture | MODE within 6 of 334455 | SOUND | mode of a pane-only capture is its background

window-composite.ps1:201-207,210-213 | each pane glass at its own rect | 1px at each pane centre of composite | single-pixel near (tol 24) | SOUND | single pixel on subject; two distinct tints give a swap check
window-composite.ps1:219-221 | divider band survives composition | 1px at gap midpoint | single-pixel near 00ff00 | SOUND | single pixel on divider
window-composite.ps1:226-230 | raw parent capture lacks pane A glass | 1px at pane A centre | single-pixel NOT near tint | SOUND | negative single-pixel control
window-composite.ps1:95-104,263-265 | one divider band down a scanline across both panes after 3 drags | one pixel column through pane A centre spanning both panes + gap | count of runs of green px ==1 | SOUND | single-column scan for divider colour 00ff00; raw-capture run count printed, not scored

== lib/ helpers ==
lib/TestDesktop.ps1:2388-2399 (AllSentinel, used 2370-2379) | sync PrintWindow drew something | 8x8 grid across whole window | all samples == magenta sentinel => fail | SOUND | claim is only that WM_PRINTCLIENT drew anything; one painted chrome sample passes, so it cannot vouch that any particular child/surface was captured
lib/TestDesktop.ps1:4325-4348,4471-4490 (Test-TestCaptureUniform; throw in Get-TestWindowPixels) | capture is not one flat colour | whole window interior, inset 8, grid MaxStep 16 | all sampled px equal => throw (unless -AllowUniform) | SOUND | claim is window not blank; whole-capture aggregate, so chrome alone defeats it while the terminal surface is flat (documented T1282); callers must not read it as surface captured
lib/TestDesktop.ps1:4376-4405 (Get-TestCaptureContent) | Distinct / TopShare of capture | whole window inset 8, grid 48 | distinct count + top-colour share | MIXED | HELPER: whole-capture aggregate; its own header records chrome over an unreadable surface scoring 23 distinct / 0.60 TopShare, so chrome alone clears a Distinct>=8 floor. No caller in this partition
lib/TestDesktop.ps1:4561-4579 (Get-TestDistinctColors) | distinct colours | whole capture inset 8 step 3 | distinct count capped 64 | MIXED | HELPER: default region is the whole shot, so caption/borders/title text alone supply >=8 colours when the surface is flat. Partition callers viewer-find, viewer-toc-emphasis, window-color use it on card/banner windows that ARE the subject (SOUND there); ChromeGeometry.ps1:521 uses it on a whole top-level window (MIXED, below)
lib/TestDesktop.ps1:4512-4544 (Get-TestBrightness) | mean luminance of a rect | default Rect = whole capture (inset 8, step 4) | mean luminance | MIXED | HELPER: default is whole window; chrome can satisfy a mean-luminance threshold meant for the surface (T216 mid-paint black reads 0). No caller in this partition
lib/TestDesktop.ps1:4502-4508 (Get-TestPixel) | one pixel in screen coords | 1px | single-pixel | SOUND | single-pixel accessor
lib/ColorMath.ps1:187-212 (Measure-Box) | box summary Mode/Darkest/Lightest/Distinct | caller-chosen box | mode + luminance extremes + distinct count | SOUND | subject-safe only if caller boxes the subject; partition callers (viewer-error-card, viewer-toc-emphasis) do. Its .Distinct over a large box is a region aggregate (only printed at toc-emphasis l.266, not asserted)
lib/PaneCapture.ps1:232-251 (Get-TestPaneColorCount) | distinct colours in pane GL capture | whole pane capture, step 4 inset 2 | distinct count | SOUND | capture contains only the pane glass (no window chrome)
lib/PaneCapture.ps1:256-279 (Get-TestPaneDominantColor) | dominant colour of pane | whole pane capture step 4 | MODE | SOUND | mode over pane-only capture is its background
lib/PaneCapture.ps1:284-296 (Test-PaneColorNear) | colour near target | string compare | channel distance | SOUND | comparator only
lib/HoverCapture.ps1:77-84,147 (Changed field) | hover move altered a pixel | WHOLE WINDOW, app-side photo before vs after move | boolean any-pixel-changed | MIXED | HELPER: whole-window aggregate; a probe asserting this control lit can be satisfied by another element changing (previously hovered control un-lighting, tooltip, focus ring). Header says to pair with pixel samples. No caller in this partition
lib/WindowComposite.ps1:152-166 | composite = parent PrintWindow + per-pane glass | whole window | no assertion; parent taken -AllowUniform | SOUND | returns bitmap only; refuses (null) if any pane lacks a capture or placement, so a flat parent fill cannot pass as glass
lib/ChromeGeometry.ps1:518-526 (Get-TestTabExtents capture gate) | the tab strip has painted | WHOLE top-level window capture (-Sync) | distinct colours >=8 | MIXED | caption/chrome, borders and title text alone give >=8 colours even if the tab strip row has not painted (terminal surface is flat); gate accepts a capture with no tabs. Consequence limited: next step scans only the strip row, so an unpainted strip yields zero extents, not a false positive
lib/ChromeGeometry.ps1:528-561 (Get-TestTabExtents scan) | tab runs on strip row | single row rowY=StripTop+BarH-2, RunLeft..RunRight | per-px diff >8 from bg px at RunRight-2, runs >= MinTabW/2 | SOUND | one-pixel-high strip row; bg reference placed where no tab can be

COUNT: 49 entries (35 script-level assertion groups + 14 lib entries); MIXED = 6
```
