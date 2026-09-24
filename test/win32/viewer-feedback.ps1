# T634 acceptance: the viewer feedback composer's CHROME.
#
# What is asserted, in the shape the task's validation criteria ask for:
#
#   A. the feedback button OPENS the composer: a `GhozttyViewerFeedback` child
#      window appears, visible, directly under the nav bar.
#   B. the nav bar stays visible the whole time the composer is open -- it
#      carries the only affordance that closes it, so it must not auto-hide
#      out from under it.
#   C. the page is INSET by the composer's band, and gets the space back when
#      it closes (the WebView2 widget's own top edge moves, both ways).
#   D. the pill GROWS with its content and SHRINKS again: typed newlines make
#      the band taller, backspacing them makes it shorter.
#   E. Escape closes it (a pane-scoped chord, live only in the composer).
#   F. text typed into the composer SURVIVES closing and reopening -- the
#      state lives on the pane, not on the toolbar window.
#   G. Ctrl+Enter sends, and a COMPLETE report folder lands in the throwaway
#      repo's `temp/feedback/new/` (T636): the queue is polled the way a
#      watcher polls it, so a folder seen without its `report.json` would fail
#      the atomicity assertion; the JSON's worktree branch/commit are the
#      throwaway repo's exact revision; and the composer empties and closes
#      itself behind the confirmation.
#   H. the composer's chords are PANE-SCOPED: Escape and Ctrl+Enter delivered
#      to a terminal pane produce no composer activity at all.
#   J. the two circular actions EXPLAIN THEMSELVES and answer the KEYBOARD
#      (T640): each has a tooltip naming what it does and its chord, registered
#      on its forgiving hit box; Tab walks text -> "+" -> send -> text and
#      shift+Tab walks back; and Space or Enter on the focused button does what
#      a click does. Both halves are accessibility -- before this the only way
#      to learn what a button did was to press it, and the only way to press
#      one was with a mouse.
#
# ORACLES, and why they are what they are. This runs on the BACKGROUND test
# desktop, where CopyFromScreen and SendInput are dead (T233), so nothing out
# here can look at a painted pill. Two things are readable instead, and both
# are the real thing rather than a proxy:
#
#   * the composer is a REAL child window, so its class, visibility and rect
#     are readable with the ordinary window helpers -- that is what makes A,
#     C and D geometric assertions rather than log-scraping.
#   * the pane states each open/close in its own stderr:
#         viewer feedback pane=<id> open=<bool> bar_h=<px> worktree=<path>
#             staging=<worktree-relative draft folder, or <none>>
#     and each send as
#         viewer feedback pane=<id> action=send bytes=<n> quotes=<n> ...
#         viewer feedback pane=<id> filed=<bool> stem=<name> status=<text>
#     which is what F and G read. G's real oracle, though, is the FILE the
#     send produced -- a watcher's view of the report rather than the pane's
#     view of itself.
#
# THE SURFACE. The composer's text box is a WebView2 page (T934), and this
# script drives THAT page, not the RichEdit fallback it used to pin (T1706).
# Typing, caret moves, selection, cut/paste and undo go in over the DevTools
# protocol (lib\WebViewCdp.ps1), because a posted WM_CHAR does not reach a
# Chromium renderer and there is no input desktop here. The page's own document
# is read back the same way.
#
# The chords NATIVE owns -- Ctrl+Enter, Esc, Tab -- are not the page's: the
# controller's AcceleratorKeyPressed claims them and posts
# WM_APP_COMPOSER_CHORD (WM_APP+2, vk + Mods bits) to the band, which runs them
# (ViewerFeedbackWeb.zig). A synthetic key cannot prove the first hop, because
# native reads modifiers from GetKeyState; so these arms post that SECOND hop,
# which is the band's real entry point for the web surface, and the pure
# classification is pinned by unit tests in `viewer_accel.zig`.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-feedback.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = "-fbtest$PID"

# WHICH SURFACE THIS SUITE DRIVES: the web composer, the one users get (T1706).
# Stated rather than assumed, so a stale `richedit` left in the environment by
# another run cannot quietly move the suite back onto the fallback -- and arm C2
# asserts the app agreed.
. (Join-Path $PSScriptRoot 'lib\ComposerSurface.ps1')
# ComposerSurface.ps1 turns on strict mode, and a dot-sourced file's strict mode
# is the CALLER's; this script's helpers read properties of maybe-null results
# on purpose (`$s.Open` on a state nobody logged yet), so it stays off here.
Set-StrictMode -Off
Set-ComposerSurface 'web'
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
. (Join-Path $PSScriptRoot 'lib\WebViewCdp.ps1')

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass, and the
# guard-stamping child below reads the same state and refuses to write.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-OnlyPaneId($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0].id
}

# --- window plumbing ---------------------------------------------------------
# One viewer host window is expected in this run (one viewer pane), so these
# return the first match rather than making every caller thread a handle.

function Get-ViewerHost($appPid) {
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
            return [pscustomobject]@{ Top = [IntPtr]$top.Hwnd; Pane = [IntPtr]$h.Hwnd }
        }
    }
    return $null
}

function Get-ChromeChild($paneHwnd, [string]$Class) {
    $c = @(Get-TestChildWindows -Window $paneHwnd -Class $Class)
    if ($c.Count -lt 1) { return $null }
    return [IntPtr]$c[0].Hwnd
}

# The WebView2 widget's own window, whose TOP is the page's real inset -- i.e.
# the thing `controller.setBounds` actually moves. `Chrome_WidgetWin_0` is the
# controller's own host window; the Chromium windows under it (_1, the render
# widget, the D3D intermediate) follow it and are not what the pane positions.
#
# `-Class $null` is load-bearing: Get-TestChildWindows DEFAULTS to
# 'GhozttyTerminal', so an unfiltered-looking call with no -Class silently
# enumerates nothing (which is how this returned empty on its first run).
#
# The web composer's page is a Chrome_WidgetWin_0 too, a DESCENDANT of the pane
# through the band (T1706), and it sits above the page's own. Every
# Chrome_WidgetWin_0 under the band is therefore skipped, or the "page top"
# would be the composer's text box.
function Get-ContentTop($paneHwnd) {
    $skip = @()
    foreach ($b in @(Get-TestChildWindows -Window $paneHwnd -Class 'GhozttyViewerFeedback')) {
        foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$b.Hwnd) -Class $null)) { $skip += [int64]$c.Hwnd }
    }
    $best = $null
    foreach ($c in @(Get-TestChildWindows -Window $paneHwnd -Class $null)) {
        if ([string]$c.Class -ne 'Chrome_WidgetWin_0') { continue }
        if ($skip -contains [int64]$c.Hwnd) { continue }
        if ($c.Height -le 0) { continue }
        if ($null -eq $best -or $c.Top -lt $best) { $best = [int]$c.Top }
    }
    return $best
}

# The draft staging folder the pane last reported (T645) -- worktree-relative,
# e.g. `temp/feedback/.staging/20260908T051200Z-a3f9c2`. The stem inside it is
# random, so this line is the only way a test can name the folder the footer
# link points at.
function Get-FeedbackStaging($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) open=\w+ bar_h=\d+ worktree=\S+ staging=(\S+)") {
            if ($Matches[1] -ne '<none>') { $hit = $Matches[1] }
        }
    }
    return $hit
}

# The pane's LAST reported composer state, from the GUI's stderr.
function Get-FeedbackState($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) open=(\w+) bar_h=(\d+)") {
            $hit = [pscustomobject]@{ Open = ($Matches[1] -eq 'true'); BarH = [int]$Matches[2] }
        }
    }
    return $hit
}

function Wait-FeedbackState($errlog, $paneId, [bool]$Open) {
    for ($t = 0; $t -lt 40; $t++) {
        $s = Get-FeedbackState $errlog $paneId
        if ($s -and $s.Open -eq $Open) { return $s }
        Start-Sleep -Milliseconds 250
    }
    return (Get-FeedbackState $errlog $paneId)
}

# The last `action=send bytes=N quotes=M` the pane reported, or $null.
function Get-LastSendLen($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) action=send bytes=(\d+)") {
            $hit = [int]$Matches[1]
        }
    }
    return $hit
}

# The last `buffer=N` (the composer's RAW text length) the pane reported.
function Get-LastSendBuffer($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) action=send bytes=\d+ buffer=(\d+)") {
            $hit = [int]$Matches[1]
        }
    }
    return $hit
}

# The composer's tooltips and its keyboard focus, from the same stderr oracle
# the rest of this file uses and for the same reason (T640): the two circular
# actions are owner-painted chrome on a background desktop where nothing can
# take a screenshot or rest a pointer. The band logs one tips line per CHANGE,
# so the newest describes the composer as it stands.
function Get-FeedbackTips($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $tail = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback tips pane=$([regex]::Escape($paneId))(.*)$") { $tail = $Matches[1] }
    }
    if ($null -eq $tail) { return $null }
    $tips = @{}
    $rx = '(\w+):paint=(-?\d+),(-?\d+),(-?\d+),(-?\d+):tool=(-?\d+),(-?\d+),(-?\d+),(-?\d+):text="([^"]*)"'
    foreach ($m in [regex]::Matches($tail, $rx)) {
        $g = $m.Groups
        $tips[$g[1].Value] = [pscustomobject]@{
            Paint = @([int]$g[2].Value, [int]$g[3].Value, [int]$g[4].Value, [int]$g[5].Value)
            Tool  = @([int]$g[6].Value, [int]$g[7].Value, [int]$g[8].Value, [int]$g[9].Value)
            Text  = $g[10].Value
        }
    }
    return $tips
}

function Wait-FeedbackTips($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        $tips = Get-FeedbackTips $errlog $paneId
        if ($tips -and $tips.ContainsKey('send')) { return $tips }
        Start-Sleep -Milliseconds 250
    }
    return (Get-FeedbackTips $errlog $paneId)
}

# A tool rect must COVER its painted square and be strictly bigger than it --
# the design system's hit box exceeds the paint, and a tip registered on the
# paint would go quiet in exactly the margin a click still lands in. Same
# assertion the nav bar's tips carry (viewer-worktree.ps1, T639).
function Test-FeedbackTipIsHitBox($tip) {
    if (-not $tip) { return $false }
    $p = $tip.Paint
    $h = $tip.Tool
    if ($h[0] -gt $p[0] -or $h[1] -gt $p[1] -or $h[2] -lt $p[2] -or $h[3] -lt $p[3]) { return $false }
    return (($h[2] - $h[0]) -gt ($p[2] - $p[0])) -and (($h[3] - $h[1]) -gt ($p[3] - $p[1]))
}

# Where keyboard focus last LANDED inside the composer: text, snapshot or send.
function Get-FeedbackFocus($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback focus pane=$([regex]::Escape($paneId)) stop=(\w+)") {
            $hit = $Matches[1]
        }
    }
    return $hit
}

# How many sends the pane has reported so far. A COUNT rather than the last
# `bytes=` value: two different reports can be the same length, and comparing
# the number would then read a real send as no send at all (which is exactly
# what 'copyme' and 'tab me' did on the first run of the arm below).
function Get-FeedbackSendCount($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return 0 }
    $n = 0
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) action=send bytes=\d+") { $n++ }
    }
    return $n
}

function Wait-FeedbackFocus($errlog, $paneId, [string]$Stop) {
    for ($t = 0; $t -lt 40; $t++) {
        $f = Get-FeedbackFocus $errlog $paneId
        if ($f -eq $Stop) { return $f }
        Start-Sleep -Milliseconds 150
    }
    return (Get-FeedbackFocus $errlog $paneId)
}

# Every report folder currently in the queue, with whether it is COMPLETE. A
# folder without its `report.json` is what a watcher must never see -- the
# publish is a rename of a finished folder, so such a state cannot exist.
function Get-QueueFolders($queueDir) {
    if (-not (Test-Path $queueDir)) { return @() }
    return @(Get-ChildItem -Path $queueDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Name     = $_.Name
            Complete = (Test-Path (Join-Path $_.FullName 'report.json'))
        }
    })
}

function Wait-WorktreeShown($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer worktree pane=$([regex]::Escape($paneId)) feedback=shown") { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Reveal the nav bar and click its trailing feedback button. Same mechanism as
# viewer-worktree.ps1 section 3: a hidden bar has never been placed, so it is
# seeded open with WM_APP_VIEWER_FOCUS_ADDRESS (WM_APP+22) first.
function Invoke-FeedbackButton($view) {
    [void](Send-TestRawMessage -Window $view.Pane -Message 0x8016)
    Start-Sleep -Milliseconds 600
    $nb = Get-ChromeChild $view.Pane 'GhozttyViewerNav'
    if (-not $nb) { return $false }
    $rect = Get-TestWindowRect $nb
    if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { return $false }
    # The bar is 36 DIP tall, so its height IS the scale. The trailing button's
    # center is 4 DIP of band edge plus half of its 28 DIP square.
    $scale = $rect.Height / 36.0
    $x = [int]($rect.Right - [Math]::Round(18 * $scale))
    $y = [int]($rect.Top + $rect.Height / 2)
    return (Send-TestMouse -Window $view.Top -Target $nb -X $x -Y $y)
}

# --- the web composer's two input routes (T1706) ----------------------------

# A chord NATIVE owns, delivered the way the web surface delivers it: the
# controller's accelerator handler posts WM_APP_COMPOSER_CHORD (WM_APP+2) to
# the band with the virtual key in wParam and input.Mods bits in lParam
# (shift=1, ctrl=2, alt=4). See the header for why the first hop is not driven.
$script:ChordMsg = 0x8002
$script:ModShift = 1
$script:ModCtrl = 2
function Send-ComposerChord($band, [int]$Vk, [int]$Mods = 0) {
    return (Send-TestRawMessage -Window $band -Message $script:ChordMsg `
            -WParam ([IntPtr]$Vk) -LParam ([IntPtr]$Mods))
}

# A DevTools session on the composer's CURRENT page. Closing the composer
# destroys its page and opening builds a new one, so every reopen needs a new
# session; the pages already used are skipped, because a destroyed target can
# still be listed for a moment after it goes.
$script:cdpPort = 0
$script:cdpSeen = @()
function Connect-Composer {
    $c = $null
    try {
        $c = Find-CdpComposer -Port $script:cdpPort -Exclude $script:cdpSeen
    } catch {
        Write-Host "      $($_.Exception.Message)"
        return $null
    }
    $script:cdpSeen += $c.Url
    return $c
}

# Empty the box the way a person does: select everything, delete it.
function Clear-Composer($cdp) {
    Set-CdpComposerFocus -Conn $cdp
    Send-CdpKey $cdp 'a' -Ctrl
    Send-CdpKey $cdp 'Delete'
    $got = Wait-CdpComposerText $cdp ''
    if ($got -ne '') { Show-ComposerDom $cdp 'after Ctrl+A, Delete' }
    return $got
}

# The box's markup, printed when a read-back disagrees: the serialized text
# alone cannot tell a <br> placeholder from a newline in a text node.
function Show-ComposerDom($cdp, [string]$When) {
    try {
        $html = Invoke-CdpEval $cdp "JSON.stringify(document.getElementById('c').innerHTML)"
        $geo = Invoke-CdpEval $cdp ("(function(){var e=document.getElementById('c');" +
            "return e.scrollHeight+'/'+getComputedStyle(e).lineHeight;})()")
        Write-Host "      the box $When`: $html (scrollHeight/lineHeight $geo)"
    } catch {}
}

# The band's height once it satisfies `$Ok`, or its last height at the
# deadline. The page reports its wrapped line count asynchronously, so a
# single sample right after a keystroke races the relayout.
function Wait-BandHeight($band, [scriptblock]$Ok, [int]$TimeoutMs = 3000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        $h = (Get-TestWindowRect $band).Height
        if ((& $Ok $h) -or (Get-Date) -ge $deadline) { return $h }
        Start-Sleep -Milliseconds 100
    }
}

# A THROWAWAY working tree, not this repo (T636).
#
# Since the report writer landed, arm G's Ctrl+Enter FILES a report into the
# worktree the pane's content belongs to. Pointed at this checkout, every
# acceptance run would drop a junk report into the user's own
# `temp/feedback/new/` queue for their watcher to pick up. A temp repo is also
# what makes the revision assertions exact: this one's branch and commit are
# whatever the developer happens to be on.
$work = Join-Path $env:TEMP ("ghoztty-feedback-accept-" + $PID)
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Content -Path (Join-Path $work 'README.md') -Encoding utf8 -Value @(
    '# Throwaway',
    '',
    'a paragraph in the throwaway repo',
    ''
)
& git -C $work init --initial-branch=main *> $null
& git -C $work add -A *> $null
& git -C $work -c user.name='ghoztty test' -c user.email='test@ghoztty' commit -m 'throwaway' *> $null
# git prints FORWARD slashes on Windows; the app normalizes them at the one
# place the string enters it (viewer_worktree.parseRoot), so the comparison
# below has to be against the normalized form rather than git's own.
$workRoot = (& git -C $work rev-parse --show-toplevel 2>$null | Out-String).Trim().Replace('/', '\')
if (-not $workRoot) { Write-Host "SETUP FAIL: could not make a throwaway repo at $work"; exit 1 }
$workCommit = (& git -C $work rev-parse HEAD 2>$null | Out-String).Trim()
$queueDir = Join-Path $work 'temp\feedback\new'
$stagingDir = Join-Path $work 'temp\feedback\.staging'

$viewFile = Join-Path $work 'README.md'

Stop-RepoInstances
# Armed BEFORE launch: the runtime reads the switch when the app's browser
# process starts, on the first viewer pane.
$script:cdpPort = Enable-WebViewCdp
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-feedback-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # --- setup: a viewer pane on a file inside this repo ---------------------
    $r = Invoke-Verb @('+new-window', '--target=fbwin', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'fbwin')) 'the viewer window exists'
    $paneId = Get-OnlyPaneId 'fbwin'
    Assert ($null -ne $paneId) "the viewer window has exactly one pane (id '$paneId')"
    Assert (Wait-WorktreeShown $errlog $paneId) 'the pane resolved a worktree, so the button is present'

    $view = $null
    for ($t = 0; $t -lt 20; $t++) {
        $view = Get-ViewerHost $appPid
        if ($view) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $view) 'the viewer host window was found'
    if (-not $view) { throw 'no viewer host window' }

    # The WebView2 widget is created ASYNCHRONOUSLY, after the pane host window
    # it hangs off exists - so this is a wait, like every other window lookup in
    # this script, and not a single sample. It was the one lookup here without
    # one, and the cost was two bugs at once: it went red on a box where the
    # widget simply took longer to arrive (measured: reproducible in the main
    # repo, green in a fresh worktree, on IDENTICAL code), and its null then
    # made the "page moved down" comparison below pass VACUOUSLY, since
    # `<int> -gt $null` is `<int> -gt 0`.
    $contentBefore = $null
    for ($t = 0; $t -lt 40; $t++) {
        $contentBefore = Get-ContentTop $view.Pane
        if ($null -ne $contentBefore) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $contentBefore) "the WebView2 widget was found (page top $contentBefore)"

    # --- A. the button opens the composer ------------------------------------
    Assert (Invoke-FeedbackButton $view) 'the revealed nav bar took a click at the feedback button'
    $s = Wait-FeedbackState $errlog $paneId $true
    Assert ($s -and $s.Open) "the pane reports the composer OPEN (state '$($s.Open)')"
    Assert ($s -and $s.BarH -gt 0) "...reserving a band of $($s.BarH) px"

    $fb = $null
    for ($t = 0; $t -lt 20; $t++) {
        $fb = Get-ChromeChild $view.Pane 'GhozttyViewerFeedback'
        if ($fb) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $fb) 'a GhozttyViewerFeedback child window exists'
    Assert ($fb -and (Test-TestWindowVisible $fb)) 'the composer window is visible'

    $fbRect = Get-TestWindowRect $fb
    Assert ($fbRect -and $fbRect.Height -eq $s.BarH) `
        "the composer window is exactly the band it reported ($($fbRect.Height) vs $($s.BarH))"

    # --- B. the nav bar stays open under it ----------------------------------
    $nb = Get-ChromeChild $view.Pane 'GhozttyViewerNav'
    Assert ($nb -and (Test-TestWindowVisible $nb)) 'the nav bar is still visible while the composer is open'
    $nbRect = Get-TestWindowRect $nb
    Assert ($nbRect -and $fbRect -and $fbRect.Top -eq $nbRect.Bottom) `
        "the composer sits directly under the nav bar ($($fbRect.Top) vs $($nbRect.Bottom))"

    # --- C. the page is inset by the band ------------------------------------
    $contentOpen = Get-ContentTop $view.Pane
    Assert ($null -ne $contentBefore -and $null -ne $contentOpen -and $contentOpen -gt $contentBefore) `
        "the page moved down for the composer ($contentBefore -> $contentOpen)"

    # --- C2. the editing surface is the web page (T934, T1706) ---------------
    # The band paints the pill; the text lives in a WebView2 page filling the
    # pill's text rect. Everything below types into THAT, so this arm first
    # proves the app put the composer on it -- a suite that silently landed on
    # the RichEdit fallback would fail every typing arm with no explanation.
    Assert (Wait-ComposerSurface $errlog 'web') `
        "the composer opened on the web surface (got '$(Get-ComposerSurface $errlog)')"
    $cv = $null
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($c in @(Get-TestChildWindows -Window $fb -Class $null)) {
            if ([string]$c.Class -eq 'Chrome_WidgetWin_0' -and $c.Width -gt 0) { $cv = $c; break }
        }
        if ($cv) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $cv) "the composer's page is placed inside the pill ($($cv.Width)x$($cv.Height))"
    $cdp = Connect-Composer
    Assert ($null -ne $cdp) "the composer's page answers on the DevTools port ($($script:cdpPort))"
    if (-not $cdp) { throw 'no composer page to type into' }

    # The empty composer shows a placeholder: the page's box carries the cue
    # text the host sent it, and the stylesheet paints it while the box is
    # empty. Read from the page, since the painted cue is not observable here.
    $cue = Invoke-CdpEval $cdp "document.getElementById('c').getAttribute('data-placeholder')"
    Assert ([string]$cue -ne '') "the empty composer carries a placeholder ('$cue')"
    Assert ((Get-CdpComposerText $cdp) -eq '') 'the composer opens empty'

    # --- D. the pill grows with content, and shrinks again -------------------
    # Enter is pressed as a KEY into the page, the path a person takes: only
    # Ctrl+Enter is the composer's, and a bare Enter must stay a newline.
    $h1 = (Get-TestWindowRect $fb).Height
    Send-CdpComposerText $cdp 'one'
    Send-CdpKey $cdp 'Enter'
    Send-CdpComposerText $cdp 'two'
    Send-CdpKey $cdp 'Enter'
    Send-CdpComposerText $cdp 'three'
    $typed = Wait-CdpComposerText $cdp "one`ntwo`nthree"
    Assert ($typed -ceq "one`ntwo`nthree") "three typed lines read back from the page ('$($typed -replace "`n", '\n')')"
    $h3 = Wait-BandHeight $fb { param($h) $h -gt $h1 }
    Assert ($h3 -gt $h1) "three lines make the composer taller ($h1 -> $h3)"

    $contentTall = Get-ContentTop $view.Pane
    Assert ($null -ne $contentTall -and $contentTall -gt $contentOpen) `
        "...and the page followed it down ($contentOpen -> $contentTall)"

    # Backspace the last line away: the band must give the space BACK, which is
    # the half a "grows with content" implementation forgets.
    for ($i = 0; $i -lt 6; $i++) { Send-CdpKey $cdp 'Backspace' }
    $twoLines = Wait-CdpComposerText $cdp "one`ntwo"
    Assert ($twoLines -ceq "one`ntwo") "six Backspaces took the last line away ('$($twoLines -replace "`n", '\n')')"
    if ($twoLines -cne "one`ntwo") { Show-ComposerDom $cdp 'after six Backspaces' }
    $h2 = Wait-BandHeight $fb { param($h) $h -lt $h3 }
    Assert ($h2 -lt $h3) "deleting a line gives the space back ($h3 -> $h2)"
    $contentTwoLine = Get-ContentTop $view.Pane
    Assert ($null -ne $contentTwoLine -and $contentTwoLine -lt $contentTall) `
        "...and the page came back up with it ($contentTall -> $contentTwoLine)"

    # --- E/F. Escape closes; the text survives the round trip ----------------
    # Escape through the band's chord entry, which is where the web surface's
    # accelerator handler sends it. Closing destroys the page, so the session
    # on it goes too.
    Close-Cdp $cdp; $cdp = $null
    [void](Send-ComposerChord $fb 0x1B)
    $s = Wait-FeedbackState $errlog $paneId $false
    Assert ($s -and -not $s.Open) "Escape closes the composer (state '$($s.Open)')"
    Assert (-not (Test-TestWindowVisible $fb)) 'the composer window is hidden once closed'

    # The page gets back EXACTLY the composer's band -- not all the way to
    # where it started, because the nav bar is still revealed (the composer
    # pinned it, and its ordinary auto-hide deadline has only just been armed).
    # That distinction is the whole point of measuring against the bar rather
    # than against the opening value.
    $contentClosed = Get-ContentTop $view.Pane
    Assert ($null -ne $contentClosed -and $contentClosed -eq ($contentTwoLine - $h2)) `
        "the page got the composer's band back ($contentTwoLine -> $contentClosed, band $h2)"
    Assert ($contentClosed -eq (Get-TestWindowRect $nb).Bottom) `
        'the page now starts at the nav bar, with nothing reserved for a closed composer'

    Assert (Invoke-FeedbackButton $view) 're-clicking the feedback button reaches the pane'
    $s = Wait-FeedbackState $errlog $paneId $true
    Assert ($s -and $s.Open) 'the composer reopens'
    # The new page is seeded from the pane's buffer and then reports its own
    # line count, so the height settles a moment after the open.
    $hBack = Wait-BandHeight $fb { param($h) $h -eq $h2 }
    Assert ($hBack -eq $h2) `
        "the reopened composer is still the size its TEXT makes it ($hBack vs $h2) -- state lives on the pane"

    # --- G. Ctrl+Enter sends, and a complete report lands on disk (T636) -----
    # `@(...)` at every call site, not just inside the function: PowerShell
    # unrolls a one-element array on return, and `.Count` on the bare object is
    # $null -- which reads as "0 folders" and passes a test that should fail.
    Assert (@(Get-QueueFolders $queueDir).Count -eq 0) 'the queue starts empty'

    # --- G1. the draft's own folder (T645) -----------------------------------
    # The composer minted a stem when it opened, and the footer link names that
    # folder. Opening created NOTHING: a composer opened and closed without a
    # word must leave no folder behind.
    $draftRel = Get-FeedbackStaging $errlog $paneId
    Assert ($null -ne $draftRel) "the pane names the draft's staging folder ('$draftRel')"
    $draftStem = $null
    if ($draftRel) {
        Assert ($draftRel -like 'temp/feedback/.staging/*') `
            "...under the staging area, forward-slashed for display ('$draftRel')"
        $draftStem = $draftRel.Split('/')[-1]
    }
    $draftDir = if ($draftStem) { Join-Path $stagingDir $draftStem } else { $null }
    Assert ($draftDir -and -not (Test-Path $draftDir)) `
        'opening the composer created no folder -- the draft materializes on reveal or on send'

    # What the footer link is FOR: the user opens that folder and drops a file
    # in. The click itself launches File Explorer, which is not a thing to do on
    # a background test desktop, so the DROP is done here directly -- the
    # property under test is that the send publishes whatever is in the folder.
    if ($draftDir) {
        New-Item -ItemType Directory -Path $draftDir -Force | Out-Null
        Set-Content -Path (Join-Path $draftDir 'dropped.log') -Encoding utf8 -Value 'the log they dragged in'
    }

    [void](Send-ComposerChord $fb 0x0D $script:ModCtrl)
    $len = $null
    for ($t = 0; $t -lt 20; $t++) {
        $len = Get-LastSendLen $errlog $paneId
        if ($null -ne $len) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $len) "Ctrl+Enter reaches the pane as a send (bytes=$len)"
    Assert ($null -ne $len -and $len -gt 0) `
        "...and the text typed before the close/reopen is still there (bytes=$len)"

    # Poll the queue the way a watcher does, and record whether one was ever
    # observed WITHOUT its report.json. The publish is a single rename of a
    # folder that is already finished, so the answer must be never -- that is
    # the atomicity property, asserted rather than assumed.
    $folders = @()
    $sawPartial = $false
    for ($t = 0; $t -lt 80; $t++) {
        $folders = @(Get-QueueFolders $queueDir)
        foreach ($f in $folders) { if (-not $f.Complete) { $sawPartial = $true } }
        if ($folders.Count -gt 0 -and -not $sawPartial) { break }
        Start-Sleep -Milliseconds 50
    }
    Assert ($folders.Count -eq 1) "exactly one report folder appeared (got $($folders.Count))"
    Assert (-not $sawPartial) 'no folder was ever visible in the queue without its report.json'
    Assert (-not (Test-Path (Join-Path $stagingDir $folders[0].Name))) `
        'the staging folder is gone -- it WAS the published one, renamed'
    # The published folder is the DRAFT's folder under the DRAFT's name (T645),
    # which is what makes the file dropped into it a part of the report rather
    # than something stranded in a staging directory nobody drains.
    Assert ($draftStem -and $folders[0].Name -eq $draftStem) `
        "the report was filed under the draft's own stem ('$($folders[0].Name)' vs '$draftStem')"
    Assert (Test-Path (Join-Path $queueDir (Join-Path $folders[0].Name 'dropped.log'))) `
        '...and the file dropped into the draft folder rode along into the queue'

    $reportPath = Join-Path $queueDir (Join-Path $folders[0].Name 'report.json')
    $report = $null
    try { $report = Get-Content $reportPath -Raw | ConvertFrom-Json } catch { }
    Assert ($null -ne $report) "the report parses as JSON ($reportPath)"
    if ($report) {
        Assert ($report.version -ge 2) "...with the shared schema version (got $($report.version))"
        Assert ($report.body.Length -gt 0) "...a body ($($report.body.Length) chars)"
        Assert ($report.source.kind -eq 'file') "...the source kind ('$($report.source.kind)')"
        Assert ($report.source.relativePath -eq 'README.md') `
            "...the path repo-relative and forward-slashed ('$($report.source.relativePath)')"
        Assert ($report.source.paneID -eq $paneId) `
            "...the pane it came from ('$($report.source.paneID)')"
        Assert ($report.worktree.path -eq $workRoot) `
            "...the worktree it was filed into ('$($report.worktree.path)')"
        # The revision half T633 did not ship: this is the exact commit the
        # throwaway repo is on, so a stale or guessed value cannot pass.
        Assert ($report.worktree.branch -eq 'main') `
            "...the branch the user was on ('$($report.worktree.branch)')"
        Assert ($report.worktree.commit -eq $workCommit) `
            "...and the commit ('$($report.worktree.commit)')"
    }

    # On success the composer empties and says so, then closes itself behind
    # the confirmation.
    $filed = $false
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) filed=true stem=(\S+)") {
                $filed = $true
            }
        }
        if ($filed) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert $filed 'the pane reports the report as filed'
    $sClosed = Wait-FeedbackState $errlog $paneId $false
    Assert ($sClosed -and -not $sClosed.Open) 'the composer closes itself behind the confirmation'

    # ...and the rest of the arms need it open again.
    Assert (Invoke-FeedbackButton $view) 're-opening the composer after a send reaches the pane'
    $s = Wait-FeedbackState $errlog $paneId $true
    Assert ($s -and $s.Open) 'the composer is open again for the editing arms'
    $cdp = Connect-Composer
    Assert ($null -ne $cdp) 'the reopened composer has a page to type into'
    if (-not $cdp) { throw 'no composer page after the send' }
    # The send emptied the pane's BUFFER, not just a view of it: the page a
    # reopen builds is seeded from that buffer, and it holds nothing.
    $afterSend = Wait-CdpComposerText $cdp ''
    Assert ($afterSend -eq '') "the composer is empty after a successful send (got '$afterSend')"

    # --- I. it edits like a text control: caret and selection (T635) ---------
    # The T634 surface could only append and backspace, so every check here is
    # one it could not have passed. The oracle is the page's own document.
    Send-CdpComposerText $cdp 'bcd'
    $start = Wait-CdpComposerText $cdp 'bcd'
    Assert ($start -ceq 'bcd') "the composer starts from a known state (got '$start')"

    # Home, then type: an appending buffer would put the 'a' at the END.
    # `-KeepCaret`, because the driver otherwise puts the caret at the end.
    Send-CdpKey $cdp 'Home'
    Send-CdpComposerText $cdp 'a' -KeepCaret
    $caretText = Wait-CdpComposerText $cdp 'abcd'
    Assert ($caretText -ceq 'abcd') `
        "Home moves the caret and typing inserts there (got '$caretText', want 'abcd')"

    # Shift+Right twice selects 'ab'; typing replaces the SELECTION.
    Send-CdpKey $cdp 'Home'
    Send-CdpKey $cdp 'ArrowRight' -Shift
    Send-CdpKey $cdp 'ArrowRight' -Shift
    Send-CdpComposerText $cdp 'Z' -KeepCaret
    $selText = Wait-CdpComposerText $cdp 'Zcd'
    Assert ($selText -ceq 'Zcd') `
        "a keyboard selection is replaced by what is typed over it (got '$selText', want 'Zcd')"

    # Word wrap: one long unbroken-by-newlines line still grows the pill,
    # which only a surface that wraps can do.
    Assert ((Clear-Composer $cdp) -eq '') 'Ctrl+A then Delete empties the composer'
    $hEmpty = Wait-BandHeight $fb { param($h) $h -le $h1 }
    Send-CdpComposerText $cdp ('wrap ' * 60)
    $hWrapped = Wait-BandHeight $fb { param($h) $h -gt $hEmpty }
    Assert ($hWrapped -gt $hEmpty) `
        "a long line with no newlines in it wraps and grows the pill ($hEmpty -> $hWrapped)"

    # ...and the wrap FOLLOWS the pane. Narrowing the window re-wraps the same
    # text onto more lines, which the composer only notices if the page
    # re-measures after being resized (a layout pass is driven by that count,
    # so the naive version leaves the pill a stale height until the next
    # keystroke; composer.js watches its box with a ResizeObserver for this).
    $winRect = Get-TestWindowRect $view.Top
    [void](Set-TestWindowSize -Window $view.Top -Width ([int]($winRect.Width * 0.6)) -Height $winRect.Height)
    $hNarrow = Wait-BandHeight $fb { param($h) $h -gt $hWrapped }
    Assert ($hNarrow -gt $hWrapped) `
        "narrowing the pane re-wraps and the pill follows without a keystroke ($hWrapped -> $hNarrow)"
    [void](Set-TestWindowSize -Window $view.Top -Width $winRect.Width -Height $winRect.Height)
    $hWide = Wait-BandHeight $fb { param($h) $h -eq $hWrapped }
    Assert ($hWide -eq $hWrapped) `
        "...and widening it back gives the height back ($hNarrow -> $hWide, want $hWrapped)"

    # --- J. the standard editing chords (T635) -------------------------------
    Assert ((Clear-Composer $cdp) -eq '') 'the composer is cleared for the editing chords'
    Send-CdpComposerText $cdp 'copyme'
    [void](Wait-CdpComposerText $cdp 'copyme')

    # Shift+End selects the line, and Ctrl+X takes it. These are the ENGINE's
    # own editing commands, reached through the page like a keyboard would;
    # the clipboard they use is the real one.
    Send-CdpKey $cdp 'Home'
    Send-CdpKey $cdp 'End' -Shift
    Send-CdpKey $cdp 'x' -Ctrl
    $afterCut = Wait-CdpComposerText $cdp ''
    Assert ($afterCut -eq '') "Shift+End then Ctrl+X cuts the line away (got '$afterCut')"

    # ...and Ctrl+V brings it back, twice, which proves the clipboard round
    # trip rather than an undo that happens to look the same. A text paste is
    # the engine's own (composer.js only takes a paste that carries a picture).
    Send-CdpKey $cdp 'v' -Ctrl
    Send-CdpKey $cdp 'v' -Ctrl
    $afterPaste = Wait-CdpComposerText $cdp 'copymecopyme'
    Assert ($afterPaste -ceq 'copymecopyme') `
        "Ctrl+V pastes what Ctrl+X took (got '$afterPaste', want 'copymecopyme')"

    # Ctrl+Z undoes the last paste. The page takes the undo chords itself
    # (T983) and asks the engine first, so these are its steps.
    Send-CdpKey $cdp 'z' -Ctrl
    $afterUndo = Wait-CdpComposerText $cdp 'copyme'
    Assert ($afterUndo -ceq 'copyme') `
        "Ctrl+Z undoes the last edit (got '$afterUndo', want 'copyme')"

    # ...and a second Ctrl+Z steps back again (the first paste).
    Send-CdpKey $cdp 'z' -Ctrl
    $afterUndo2 = Wait-CdpComposerText $cdp ''
    Assert ($afterUndo2 -eq '') `
        "a second Ctrl+Z undoes the first paste too (got '$afterUndo2', want '')"

    # Typed text undoes as the WORD, not a letter and not nothing (T644). Typed
    # one KEY at a time, as a person types it, so the engine's grouping of
    # consecutive keystrokes is what is under test rather than one insertion.
    foreach ($ch in [char[]]'undome') { Send-CdpKey $cdp ([string]$ch) }
    $typedWord = Wait-CdpComposerText $cdp 'undome'
    Assert ($typedWord -ceq 'undome') "a word typed key by key lands (got '$typedWord')"
    Send-CdpKey $cdp 'z' -Ctrl
    $afterTypeUndo = Wait-CdpComposerText $cdp ''
    Assert ($afterTypeUndo -eq '') `
        "Ctrl+Z after typing a word removes the word (got '$afterTypeUndo', want '')"

    # Text back for the mirror check below, typed the ordinary way.
    Send-CdpComposerText $cdp 'copyme'
    [void](Wait-CdpComposerText $cdp 'copyme')

    # The pane's own buffer tracked all of it. The oracle is the PAGE's own
    # document, serialized the way it reports it -- the invariant is "the
    # buffer is what the page holds", not a hard-coded number, and it is what
    # the report writer reads.
    #
    # `buffer=`, not `bytes=`: since T636 a send also reports the RENDERED body
    # length, which is deliberately not the same number (it is trimmed, and
    # quoted lines carry a `> `). This arm is about the mirror, so it reads the
    # raw buffer. Read BEFORE the send: a send closes the composer and its page.
    $ctlText = Get-CdpComposerText $cdp
    $ctlBytes = [System.Text.Encoding]::UTF8.GetByteCount($ctlText)
    Close-Cdp $cdp; $cdp = $null
    $bufBefore = Get-LastSendBuffer $errlog $paneId
    [void](Send-ComposerChord $fb 0x0D $script:ModCtrl)
    $bufAfter = $null
    for ($t = 0; $t -lt 20; $t++) {
        $bufAfter = Get-LastSendBuffer $errlog $paneId
        if ($bufAfter -ne $bufBefore) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($bufAfter -eq $ctlBytes) `
        "the pane's buffer mirrors the page through all of it (buffer=$bufAfter, page holds $ctlBytes)"

    # That probe was a REAL send (T636), so it filed a second report and the
    # composer is clearing and closing itself behind the confirmation. Wait it
    # out rather than letting it land in the middle of the next arm, which
    # compares the composer's open state across a terminal-pane chord.
    [void](Wait-FeedbackState $errlog $paneId $false)

    # --- J. the two actions explain themselves and answer the keyboard ------
    # T640. Both halves are accessibility, not polish: before this the only way
    # to learn what a circular button did was to press it, and there was no way
    # to press either one without a mouse.
    Assert (Invoke-FeedbackButton $view) 're-opening the composer for the keyboard arms'
    [void](Wait-FeedbackState $errlog $paneId $true)
    # The band window is the one the earlier arms resolved: it is created once
    # and hidden/shown. Its PAGE is rebuilt per open, hence a fresh session.
    # Text, so the send button is LIVE -- it is disabled while there is nothing
    # to send, and focus does not stop on a dead control.
    $cdp = Connect-Composer
    Assert ($null -ne $cdp) 'the composer has a page for the keyboard arms'
    if ($cdp) {
        Send-CdpComposerText $cdp 'tab me'
        [void](Wait-CdpComposerText $cdp 'tab me')
        Close-Cdp $cdp; $cdp = $null
    }
    Start-Sleep -Milliseconds 400

    $tips = Wait-FeedbackTips $errlog $paneId
    Assert ($tips -and $tips.ContainsKey('snapshot') -and $tips.ContainsKey('send')) `
        "both actions registered a tooltip (got '$(@($tips.Keys) -join ",")')"
    if ($tips -and $tips.ContainsKey('snapshot') -and $tips.ContainsKey('send')) {
        Assert ($tips['snapshot'].Text -match 'screenshot' -and $tips['snapshot'].Text -match 'Ctrl\+Shift\+S') `
            "the '+' names the screenshot and its chord ('$($tips['snapshot'].Text)')"
        Assert ($tips['send'].Text -match 'Send' -and $tips['send'].Text -match 'Ctrl\+Enter') `
            "the arrow names the send and its chord ('$($tips['send'].Text)')"
        Assert (Test-FeedbackTipIsHitBox $tips['snapshot']) `
            "the '+' tip covers its HIT box, not just its painted square"
        Assert (Test-FeedbackTipIsHitBox $tips['send']) `
            'the send tip covers its HIT box too'
    }

    # The walk. The first step is a Tab in the PAGE (where focus really is),
    # which reaches the band as the chord the accelerator handler posts; the
    # rest are posted at the BAND, because from there the band itself is the
    # focused window -- the two actions are painted by it, not child controls.
    [void](Send-ComposerChord $fb 0x09)
    Assert ((Wait-FeedbackFocus $errlog $paneId 'snapshot') -eq 'snapshot') `
        "Tab from the text reaches the '+' button (focus '$(Get-FeedbackFocus $errlog $paneId)')"
    [void](Send-TestControlKey -Control $fb -Key Tab)
    Assert ((Wait-FeedbackFocus $errlog $paneId 'send') -eq 'send') `
        "...then the send button (focus '$(Get-FeedbackFocus $errlog $paneId)')"
    [void](Send-TestControlKey -Control $fb -Key Tab)
    Assert ((Wait-FeedbackFocus $errlog $paneId 'text') -eq 'text') `
        "...and back to the text, which is where a Tab off the end has to go (focus '$(Get-FeedbackFocus $errlog $paneId)')"

    # Shift+Tab from the text walks it backwards, again as the page's chord
    # hop, which carries the shift in its own Mods bits.
    [void](Send-ComposerChord $fb 0x09 $script:ModShift)
    Assert ((Wait-FeedbackFocus $errlog $paneId 'send') -eq 'send') `
        "shift+Tab from the text walks back to the send button (focus '$(Get-FeedbackFocus $errlog $paneId)')"

    # Space presses the focused button -- the same action a click does. The
    # oracle is the send the pane reports, and the focus line is still `send`
    # when it happens, which is the ring surviving its own activation.
    $sendsBeforeSpace = Get-FeedbackSendCount $errlog $paneId
    [void](Send-TestControlKey -Control $fb -Key Space)
    $sentBySpace = $false
    for ($t = 0; $t -lt 40; $t++) {
        if ((Get-FeedbackSendCount $errlog $paneId) -gt $sendsBeforeSpace) { $sentBySpace = $true; break }
        Start-Sleep -Milliseconds 250
    }
    Assert $sentBySpace 'Space on the focused send button files the report, the way a click does'
    Assert ((Get-FeedbackFocus $errlog $paneId) -eq 'send') `
        'the send fired with focus still on the send button (nothing dropped the ring first)'
    [void](Wait-FeedbackState $errlog $paneId $false)

    # And Enter is the other key every Windows button answers. Same walk, same
    # oracle -- what is being proved is the second half of the branch, not the
    # walk again.
    Assert (Invoke-FeedbackButton $view) 're-opening the composer for the Enter arm'
    [void](Wait-FeedbackState $errlog $paneId $true)
    $cdp = Connect-Composer
    Assert ($null -ne $cdp) 'the composer has a page for the Enter arm'
    if ($cdp) {
        Send-CdpComposerText $cdp 'enter me'
        [void](Wait-CdpComposerText $cdp 'enter me')
        Close-Cdp $cdp; $cdp = $null
    }
    Start-Sleep -Milliseconds 400
    [void](Send-ComposerChord $fb 0x09)
    [void](Wait-FeedbackFocus $errlog $paneId 'snapshot')
    [void](Send-TestControlKey -Control $fb -Key Tab)
    Assert ((Wait-FeedbackFocus $errlog $paneId 'send') -eq 'send') `
        'two Tabs reach the send button again'
    $sendsBeforeEnter = Get-FeedbackSendCount $errlog $paneId
    [void](Send-TestControlKey -Control $fb -Key Enter)
    $sentByEnter = $false
    for ($t = 0; $t -lt 40; $t++) {
        if ((Get-FeedbackSendCount $errlog $paneId) -gt $sendsBeforeEnter) { $sentByEnter = $true; break }
        Start-Sleep -Milliseconds 250
    }
    Assert $sentByEnter 'Enter on the focused send button files the report too'
    [void](Wait-FeedbackState $errlog $paneId $false)

    # --- K. an IME's composed text lands, and the mirror ends correct (T642) --
    # The web surface gets IME from the engine: an input method drives a
    # composition in the page (compositionstart/update, the underlined
    # intermediate string) and then COMMITS its result. That is exactly what the
    # DevTools protocol can drive without an IME installed -- this box has one
    # input method (en-US) and adding a Japanese one needs elevation and a
    # language download on the user's daily-driver machine -- so the arms below
    # run a real composition through the engine: Input.imeSetComposition with
    # the intermediate text, then Input.insertText with the result, which is the
    # commit.
    #
    # Before T1706 this arm posted WM_IME_STARTCOMPOSITION / WM_IME_CHAR /
    # WM_IME_ENDCOMPOSITION at the RichEdit fallback; those messages mean
    # nothing to a Chromium window, and the page-side route replaces them. What
    # still needs a real IME -- the candidate window, reconversion -- is the
    # manual check in docs/design/windows-parity-ime-manual.md.
    Assert (Invoke-FeedbackButton $view) 're-opening the composer for the IME arms'
    [void](Wait-FeedbackState $errlog $paneId $true)
    $cdp = Connect-Composer
    Assert ($null -ne $cdp) 'the composer has a page for the IME arms'
    if (-not $cdp) { throw 'no composer page for the IME arms' }
    Assert ((Clear-Composer $cdp) -eq '') 'the composer is empty before the composition'

    # ASCII source for a non-ASCII string: this file stays ASCII-only, because
    # PowerShell 5.1 reads a UTF-8 script as ANSI and would mojibake a literal.
    $imeChars = @(0x65E5, 0x672C, 0x8A9E)   # JA "nihongo"
    $imeText = -join ($imeChars | ForEach-Object { [char]$_ })
    # Codepoints, not the string, in failure messages: a message that printed
    # the text itself would arrive as mojibake in the transcript.
    function Show-Codepoints([string]$s) { return (([char[]]$s | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' ') }

    # The composition in flight: the intermediate reading, then the converted
    # string, each replacing the last - the way an IME updates it.
    $composeOk = $true
    try {
        Set-CdpComposerFocus -Conn $cdp
        [void](Invoke-Cdp $cdp 'Input.imeSetComposition' @{ text = 'nihon'; selectionStart = 5; selectionEnd = 5 })
        [void](Invoke-Cdp $cdp 'Input.imeSetComposition' @{ text = $imeText; selectionStart = 3; selectionEnd = 3 })
        # The commit.
        [void](Invoke-Cdp $cdp 'Input.insertText' @{ text = $imeText })
    } catch {
        $composeOk = $false
        Write-Host "      $($_.Exception.Message)"
    }
    Assert $composeOk 'the page accepted a composition and its commit'
    $imeGot = Wait-CdpComposerText $cdp $imeText
    Assert ($imeGot -ceq $imeText) `
        "a composed string lands in the composer (got '$(Show-Codepoints $imeGot)', want '$(Show-Codepoints $imeText)')"

    # Typing continues normally afterwards, AT THE CARET the commit left - the
    # failure this catches is a composition that ends leaving the caret where
    # the composition STARTED, so the next letter lands in front of it.
    # `-KeepCaret` so the driver does not move the caret itself; the RichEdit
    # arm could not ask this question (its fake composition had no result
    # string to leave the caret after).
    Send-CdpComposerText $cdp 'ok' -KeepCaret
    $imeMixed = Wait-CdpComposerText $cdp ($imeText + 'ok')
    Assert ($imeMixed -ceq ($imeText + 'ok')) `
        "typing continues after the commit, at its end (got '$(Show-Codepoints $imeMixed)', want '$(Show-Codepoints ($imeText + 'ok'))')"

    # And the mirror. The page reports DURING a composition too, so the pane's
    # buffer sees intermediate text on the way through; what has to be true is
    # that it is right at the end. The oracle is the byte length the pane
    # reports at send time against the UTF-8 encoding of what the page holds --
    # three CJK characters are nine bytes, so an arm that counted UTF-16 units
    # would pass on ASCII and lie here.
    $imeWantBytes = [System.Text.Encoding]::UTF8.GetByteCount((Get-CdpComposerText $cdp))
    Close-Cdp $cdp; $cdp = $null
    $bufBeforeIme = Get-LastSendBuffer $errlog $paneId
    [void](Send-ComposerChord $fb 0x0D $script:ModCtrl)
    $bufAfterIme = $null
    for ($t = 0; $t -lt 20; $t++) {
        $bufAfterIme = Get-LastSendBuffer $errlog $paneId
        if ($bufAfterIme -ne $bufBeforeIme) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($bufAfterIme -eq $imeWantBytes) `
        "the pane's buffer mirrors the composed text exactly (buffer=$bufAfterIme bytes, page holds $imeWantBytes)"
    [void](Wait-FeedbackState $errlog $paneId $false)

    # --- H. the chords are pane-scoped ---------------------------------------
    # A terminal pane gets the same two chords. Nothing composer-shaped may
    # happen: no open/close transition, no send.
    $r = Invoke-Verb @('+new-window', '--target=fbterm')
    Assert ($r.Code -eq 0) "+new-window (terminal) exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'fbterm')) 'the terminal window exists'
    $sendsBefore = Get-LastSendLen $errlog $paneId
    $stateBefore = Get-FeedbackState $errlog $paneId
    $termTop = [IntPtr]::Zero
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        $h = [IntPtr]$top.Hwnd
        if (@(Get-TestChildWindows -Window $h -Class 'GhozttyViewer').Count -eq 0) { $termTop = $h; break }
    }
    Assert ($termTop -ne [IntPtr]::Zero) 'the terminal window was found'
    if ($termTop -ne [IntPtr]::Zero) {
        $surf = @(Get-TestChildWindows -Window $termTop -Class 'GhozttyTerminal')
        if ($surf.Count -gt 0) {
            [void](Send-TestKeys -Window $termTop -Target ([IntPtr]$surf[0].Hwnd) -Key Escape)
            [void](Send-TestKeys -Window $termTop -Target ([IntPtr]$surf[0].Hwnd) -Key Enter -Modifiers Ctrl)
            Start-Sleep -Milliseconds 800
        }
        Assert ($surf.Count -gt 0) 'the terminal surface window was found'
    }
    $sendsAfter = Get-LastSendLen $errlog $paneId
    $stateAfter = Get-FeedbackState $errlog $paneId
    Assert ($sendsAfter -eq $sendsBefore) `
        'Escape/Ctrl+Enter in a TERMINAL pane sent no feedback (the chords are pane-scoped)'
    Assert ($stateAfter.Open -eq $stateBefore.Open) `
        '...and did not open or close the viewer pane''s composer either'

    # --- app survived all of it ----------------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} catch {
    # T1511: the foreground-leak check below is part of this run too, so this
    # try cannot END in `Complete-TestBody`. It SCORES its own throw instead -
    # the other half of the same rule: an unwind here can no longer reach a
    # green verdict.
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    # The throwaway repo goes with the run, reports and all -- it exists so the
    # send has somewhere to file that is not the user's own queue.
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this harness been run against the composer as it now
# stands?". Red leaves the stamp alone - red stays due.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-feedback -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail
