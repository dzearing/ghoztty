# T682 acceptance: the WINDOW-scoped chords a focused viewer pane can reach.
#
# THE BUG. `viewer_accel.forwards()` names the bound actions a focused viewer
# hands back to the app; everything it does not name stays with the WebView2
# page. T126 found `toggle_hero_mode` missing from that list and added it. The
# same sweep left two behind: `reset_window_size` and `toggle_tab_overview`,
# both implemented on win32, both window-scoped, and both dead while a viewer
# held focus - a viewer-only window has no terminal to press them from at all.
# The `else` arm of `Window.performViewerBindingAction` logged a drift warning
# nobody reads, which is how the gap stayed quiet. (The list and the switch are
# now held together at COMPILE time - `Window.viewer_dispatch_tags` - so the
# next one cannot be a log line. This script measures the behavior.)
#
# THE ORACLES, and why there are two.
#   - SIZE: GetClientRect of the top-level GhozttyWindow. `reset_window_size`
#     has a visible effect, so the subject arm is a real measurement.
#   - THE PAGE'S OWN KEY LOG: `toggle_tab_overview` is a deliberate no-op on
#     this platform (as on Mac - only the GTK apprt has an overview to show),
#     so "it worked" cannot be seen in the window. What IS observable, and is
#     the whole reason to forward it, is that the app CLAIMS the chord instead
#     of letting it fall through to the page - which is what a terminal pane
#     does with it. The served page mirrors every keydown it sees into
#     `document.title`, which `DocumentTitleChanged` carries into the leaf's
#     title in `+list --json` (viewer-panes.ps1 section 11d's oracle).
#
# THREE POSITIVE CONTROLS, because every claim here is of the form "nothing
# happened" and would pass for free against dead key injection (T216):
#   A. f8 = toggle_maximize, ALREADY forwarded before this task: pressed at the
#      viewer it must maximize. If it does not, injection is broken and the run
#      ABORTS rather than returning a T682 verdict.
#   B. f10, bound to NOTHING: the page must record it. Proves the page's key
#      log is live, so "the page did not see f9" means something.
#   C. f7 = clear_screen, a bound action `forwards()` deliberately does NOT
#      admit: the page must record it too. That is the other half of the rule -
#      terminal-content actions stay with the page - and it is what keeps this
#      script honest about a build that simply claimed every chord.
#
# Pre-fix shape: f9 and f6 appear in the page's key log and the window never
# resizes. -NegativeControl asserts exactly that, so it must FAIL on a healthy
# build.
#
# T1803 widened the rule from a hand-kept list to the core's classification
# (`Binding.Action.requires`), and added two arms:
#   S3. ctrl+shift+f9 = toggle_background_opacity, a window action the old
#       list never named, which reaches the core through the window's
#       terminal: from a focused viewer it must now turn the translucent
#       window opaque and, pressed again, translucent (oracle: the app's own
#       `window translucent=` log line, opacity-reload.ps1's). Pre-fix, the
#       page got the F9. (Not float-on-top: off the input desktop there is no
#       foreground window, and a topmost band change does not stick - T277.)
#   S4. ctrl+a = toggle_maximize: a binding on one of the page's own editing
#       chords must NOT be taken from the page - the window stays restored and
#       the page logs the ctrl+a. (Mac's page claims those before any binding
#       is asked; WebView2's accelerator hop fires first, so it is spelled out.)
#
# T1849 asked the stash pair to answer from a focused viewer too (T1803 had
# already admitted both; this is the on-box proof that card was owed):
#   S5. ctrl+shift+m - the Windows DEFAULT stash_pane chord, not a --keybind -
#       pressed at the viewer stashes the VIEWER (not the terminal the core
#       would have performed it through), and the page never sees the M.
#   S6. with the terminal stashed by +stash, ctrl+shift+f2 = restore_stashed_pane
#       pressed at the viewer brings the terminal back.
#   Oracle: the leaf's `stashed` flag in +list --json (ipc-stash.ps1's).
#
# Runs on the BACKGROUND test desktop; only touches ghoztty processes running
# from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-window-chords.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint (inherited through CreateProcessW): the user's own
# instance is never queried or disturbed.
$env:GHOZTTY_PIPE_SUFFIX = "-vwctest$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-viewer-window-chords-stderr.log'
Remove-Item $errlog -Force -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:haveLog = $false
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# "width,height" of a window's client area (the harness is per-monitor-v2 DPI
# aware, so these are physical pixels).
function Get-Client([IntPtr]$top) {
    $r = Get-TestWindowRect -Window $top -Client
    return "$($r.Width),$($r.Height)"
}
function Wait-Client([IntPtr]$top, [string]$want, [int]$ms = 5000) {
    $last = ''
    for ($t = 0; $t -lt [int]($ms / 200); $t++) {
        Start-Sleep -Milliseconds 200
        $last = Get-Client $top
        if ($last -eq $want) { return $last }
    }
    return $last
}

# ---- the page's key log ----------------------------------------------------

# A raw-TCP server, not HttpListener: the latter needs a URL ACL this box does
# not grant a non-elevated test (relay-account.ps1's shape, reused by
# viewer-panes.ps1). The page records every keydown into document.title.
$script:port = Resolve-TestPort -Name 'key-log page server'
$script:pageJob = Start-Job -ScriptBlock {
    param($port)
    $html = '<html><head><title>keys=none</title></head><body>t682' +
        '<script>var s=[];addEventListener("keydown",function(e){' +
        's.push((e.ctrlKey?"c":"")+(e.altKey?"a":"")+(e.shiftKey?"s":"")+e.key);' +
        'document.title="keys="+s.join("-")});</script></body></html>'
    $payload = [Text.Encoding]::UTF8.GetBytes($html)
    $head = "HTTP/1.1 200 OK`r`nContent-Type: text/html`r`nCache-Control: no-store`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
    $out = ([Text.Encoding]::UTF8.GetBytes($head) + $payload)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    while ($true) {
        # Pending() first, never a bare accept: a job parked inside the
        # synchronous AcceptTcpClient() can never service a stop request, so
        # the harness's own teardown hangs on it forever (T1517).
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 25; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            Start-Sleep -Milliseconds 50
            $buf = New-Object byte[] 8192
            while ($stream.DataAvailable) { if ($stream.Read($buf, 0, $buf.Length) -le 0) { break } }
            $stream.Write($out, 0, $out.Length)
            $stream.Flush()
        } catch {}
        $client.Close()
    }
} -ArgumentList $script:port

function Get-Leaves($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

# The viewer leaf's title, i.e. the page's key log. '' when the leaf is gone.
function Get-KeyLog {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return '' }
    foreach ($w in @(($json | ConvertFrom-Json).data.windows)) {
        foreach ($tab in @($w.tabs)) {
            foreach ($leaf in @(Get-Leaves $tab.splits)) {
                if ($leaf.name -eq 't682view') { return [string]$leaf.title }
            }
        }
    }
    return ''
}
# Poll for the log to CHANGE from a known value (a page keydown is async all
# the way through DocumentTitleChanged), returning whatever it settles on.
function Wait-KeyLog([string]$from, [int]$ms = 4000) {
    $last = $from
    for ($t = 0; $t -lt [int]($ms / 200); $t++) {
        Start-Sleep -Milliseconds 200
        $last = Get-KeyLog
        if ($last -ne $from) { return $last }
    }
    return $last
}

# ---------------------------------------------------------------------------

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$app = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: the subject arms are inverted to the PRE-FIX shape - this run MUST fail'
    }

    # 120x20 cells so `initial_size` stores a default that is nowhere near the
    # 800x600 fallback; session persistence off so no earlier run's layout
    # restores over the fixture (T158).
    $cliArgs = @(
        '--config-default-files=false'
        '--session-persistence=false'
        '--window-width=120'
        '--window-height=20'
        # KEY CHOICE IS LOAD-BEARING. Most bare F-keys are Chromium's own
        # accelerators and never reach a page keydown at all: F1 help, F3 find,
        # F5 reload, F6 address bar, F7 caret browsing, F10 menu, F11
        # fullscreen, F12 devtools. Worse, F10 MOVES the browser's focus, so
        # every chord posted after one silently lands nowhere - measured here
        # as three arms that "the page did not see" with no accel event behind
        # them. Only F2/F4/F8/F9 are inert, so those are the whole vocabulary,
        # with ctrl+shift+f8 for the fifth binding.
        '--keybind=ctrl+shift+f8=toggle_tab_overview'
        '--keybind=f2=clear_screen'
        '--keybind=f8=toggle_maximize'
        '--keybind=f9=reset_window_size'
        '--background-opacity=0.9'
        '--keybind=ctrl+shift+f9=toggle_background_opacity'
        '--keybind=ctrl+a=toggle_maximize'
        # T1849: restore has no Windows default; F2 is inert to Chromium.
        '--keybind=ctrl+shift+f2=restore_stashed_pane'
    )
    $sp = @{ Exe = $exe; Arguments = $cliArgs }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $launched += $script:GhozttyTestDesktopPids
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'GUI is NOT enumerable on the interactive desktop'
    $script:haveLog = (Test-Path $errlog)
    if (-not $script:haveLog) {
        Write-Host 'NOTE: no debug log (release build) - delivery is assumed rather than proven'
    }

    # The viewer, split off the launch window's terminal.
    $splitOut = (& $exe +split --direction=right --name=t682view "--view=http://127.0.0.1:$($script:port)/" 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String).Trim()
    Write-Host "INFO  +split --view: $splitOut"
    Start-Sleep -Seconds 4

    # Its Chromium input child: the only HWND in WebView2's chain whose loop
    # turns a posted WM_KEYDOWN into an AcceleratorKeyPressed event (probed
    # on-box - viewer-panes.ps1 section 11b, reused by hero-nav.ps1 arm E).
    $chrome = [IntPtr]::Zero
    $viewHost = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $chrome -eq [IntPtr]::Zero; $t++) {
        foreach ($h in @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')) {
            if (-not $h.Visible) { continue }
            $widget = @(Get-TestChildWindows -Window ([IntPtr][int64]$h.Hwnd) -Class '*' |
                Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' })
            if ($widget.Count -ge 1) {
                $chrome = [IntPtr][int64]$widget[0].Hwnd
                $viewHost = [IntPtr][int64]$h.Hwnd
            }
        }
        if ($chrome -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
    }
    if ($chrome -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: the viewer pane has no Chromium input child'; exit 1 }

    $log0 = ''
    for ($t = 0; $t -lt 30 -and $log0 -notlike 'keys=*'; $t++) {
        Start-Sleep -Milliseconds 300
        $log0 = Get-KeyLog
    }
    Assert ($log0 -eq 'keys=none') "setup: the page is up and its key log is empty (got '$log0')"
    if ($log0 -ne 'keys=none') {
        Write-Host '--- +list --json ---'
        Write-Host ((& $exe +list --json 2>&1 | ForEach-Object { $_.ToString() } | Out-String).Trim())
        Write-Host 'ABORT: no page key log to read'; exit 1
    }

    # Post a chord at the viewer's Chromium child and ASSERT it arrived. Every
    # subject arm below is of the form "the page did not see X", which is
    # trivially true of a chord that was never delivered - and that is not
    # hypothetical: three arms read as clean passes that way before the key
    # vocabulary above was pinned down. `accel key vk=…` is logged by
    # `onAcceleratorKeyPressed` for EVERY chord WebView2 hands us, claimed or
    # not, so a delta of one is proof of delivery independent of the verdict.
    # A release build logs nothing; the check then says so instead of passing
    # vacuously.
    function Get-AccelCount([int]$vk) {
        if (-not $script:haveLog) { return -1 }
        $pat = 'accel key vk=0x{0:x}' -f $vk
        return @(Select-String -Path $errlog -Pattern ([regex]::Escape($pat)) -AllMatches |
            ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
    }
    function Send-AtViewer([string]$key, [int]$vk, [string[]]$mods = @()) {
        $before = Get-AccelCount $vk
        Focus-TestWindow -Window $top -Child $viewHost | Out-Null
        Start-Sleep -Milliseconds 400
        Send-TestViewerChord -Window $top -Target $chrome -Key $key -Modifiers $mods | Out-Null
        Start-Sleep -Milliseconds 1000
        if (-not $script:haveLog) { return $true }
        for ($t = 0; $t -lt 15; $t++) {
            if ((Get-AccelCount $vk) -gt $before) { return $true }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }

    # --- CONTROL A: a chord that was ALREADY forwarded answers here ---------
    Assert (Send-AtViewer 'F8' 0x77) 'CONTROL A: f8 reached the viewer accelerator hop'
    $zoomed = $false
    for ($t = 0; $t -lt 15; $t++) { Start-Sleep -Milliseconds 200; if (Test-TestWindowZoomed -Window $top) { $zoomed = $true; break } }
    if (-not $zoomed) {
        Write-Host 'ABORT: f8 at the viewer did not maximize - injection or binding is broken, not a T682 verdict'
        exit 1
    }
    Write-Host 'OK    CONTROL A: toggle_maximize already answered from a focused viewer'
    Send-AtViewer 'F8' 0x77 | Out-Null   # restore
    Start-Sleep -Milliseconds 800
    Assert (-not (Test-TestWindowZoomed -Window $top)) 'CONTROL A: f8 again restored the window'
    Assert ((Get-KeyLog) -eq 'keys=none') 'CONTROL A: ...and the page never saw f8 (a forwarded chord is claimed)'

    $init = Get-Client $top
    Write-Host "INFO  configured default client = $init"
    Assert ($init -ne '800,600') "setup: the configured default is not the 800x600 fallback ($init)"

    # --- CONTROL B: the page's key log is LIVE ------------------------------
    # f4 is bound to nothing, so no accelerator claims it and the page must
    # record it. Without this, "the page did not see f9" is true of a dead log.
    Assert ((Get-KeyLog) -eq 'keys=none') 'CONTROL B: the log is still empty before the unbound chord'
    Assert (Send-AtViewer 'F4' 0x73) 'CONTROL B: f4 reached the viewer accelerator hop'
    $logB = Wait-KeyLog 'keys=none'
    Assert ($logB -match 'F4') "CONTROL B: an UNBOUND chord reaches the page (log='$logB')"

    # --- CONTROL C: a bound-but-not-forwarded chord also reaches the page ----
    # clear_screen is terminal content, which `forwards()` deliberately keeps
    # away from the app while a viewer has focus.
    $before = Get-KeyLog
    Assert (Send-AtViewer 'F2' 0x71) 'CONTROL C: f2 reached the viewer accelerator hop'
    $logC = Wait-KeyLog $before
    Assert ($logC -match 'F2') "CONTROL C: clear_screen is NOT forwarded, so the page sees f2 (log='$logC')"

    # --- SUBJECT 1: reset_window_size (T682) --------------------------------
    Set-TestWindowSize -Window $top -Width 240 -Height 130 -Grow | Out-Null
    Start-Sleep -Milliseconds 500
    $stretched = Get-Client $top
    Assert ($stretched -ne $init) "S1: manual resize moved the window off its default ($init -> $stretched)"

    $beforeS1 = Get-KeyLog
    Assert (Send-AtViewer 'F9' 0x78) 'S1: f9 reached the viewer accelerator hop'
    $after = Wait-Client $top $init
    if ($NegativeControl) {
        Assert ($after -ne $init) "S1 (inverted): reset from the viewer did NOT resize ($after)"
    } else {
        Assert ($after -eq $init) "S1: reset_window_size from a focused viewer returned to the default ($after == $init)"
    }
    $logS1 = Get-KeyLog
    if ($NegativeControl) {
        Assert ($logS1 -match 'F9') "S1 (inverted): f9 leaked into the page (log='$logS1')"
    } else {
        Assert ($logS1 -eq $beforeS1) "S1: ...and f9 never reached the page (log='$logS1')"
    }

    # --- SUBJECT 2: toggle_tab_overview (T682) ------------------------------
    # A deliberate no-op on this platform, so the claim is exactly one thing:
    # the app takes the chord rather than leaking it into the page, which is
    # what the same keystroke does from a terminal pane.
    $sizeBefore = Get-Client $top
    $beforeS2 = Get-KeyLog
    Assert (Send-AtViewer 'F8' 0x77 @('ctrl', 'shift')) 'S2: ctrl+shift+f8 reached the viewer accelerator hop'
    Start-Sleep -Milliseconds 1200
    $logS2 = Get-KeyLog
    # `-notmatch 'F8'`, not equality: the bare Control and Shift keydowns that
    # BUILD the chord are not accelerators and do reach the page, so the log
    # grows either way. Only the F8 itself is the claim - and it appears in
    # this log for no other reason, since CONTROL A's bare f8 was claimed too.
    Assert ($beforeS2 -notmatch 'F8') 'S2: no earlier arm put an F8 in the page log'
    if ($NegativeControl) {
        Assert ($logS2 -match 'F8') "S2 (inverted): ctrl+shift+f8 leaked into the page (log='$logS2')"
    } else {
        Assert ($logS2 -notmatch 'F8') "S2: toggle_tab_overview is claimed, not leaked to the page (log='$logS2')"
    }
    Assert ((Get-Client $top) -eq $sizeBefore) 'S2: ...and the no-op disturbed nothing (window unchanged)'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'S2: no crash'
    Assert (Test-TestWindowResponsive -Window $top) 'S2: the window is still pumping messages'

    # --- SUBJECT 3: a window action the old allowlist never named (T1803) ---
    function Get-SwitchCount([string]$want) {
        return @(Select-String -Path $errlog -Pattern "window translucent=$want" -ErrorAction SilentlyContinue).Count
    }
    function Wait-SwitchCount([string]$want, [int]$before) {
        for ($t = 0; $t -lt 25; $t++) {
            Start-Sleep -Milliseconds 200
            if ((Get-SwitchCount $want) -gt $before) { return $true }
        }
        return $false
    }
    $beforeS3 = Get-KeyLog
    Assert ($beforeS3 -notmatch 'F9') 'S3: no earlier arm put an F9 in the page log'
    if (-not $script:haveLog) {
        Write-Host 'NOTE  S3: no debug log (release build) - the translucency oracle is unavailable; only the page leg is asserted'
    } else {
        $n0 = Get-SwitchCount 'true'
        Assert ($n0 -ge 1) "S3: the 0.9-opacity window started out translucent (translucent=true lines: $n0, log: $errlog)"
    }
    $opaque0 = Get-SwitchCount 'false'
    Assert (Send-AtViewer 'F9' 0x78 @('ctrl', 'shift')) 'S3: ctrl+shift+f9 reached the viewer accelerator hop'
    $toggled = if ($script:haveLog) { Wait-SwitchCount 'false' $opaque0 } else { $true }
    $logS3 = Get-KeyLog
    if ($NegativeControl) {
        Assert (-not $toggled) 'S3 (inverted): the opacity toggle from the viewer did nothing'
        Assert ($logS3 -match 'F9') "S3 (inverted): ctrl+shift+f9 leaked into the page (log='$logS3')"
    } else {
        Assert $toggled 'S3: toggle_background_opacity from a focused viewer turned the window opaque'
        Assert ($logS3 -notmatch 'F9') "S3: ...and the chord never reached the page (log='$logS3')"
        $trans0 = Get-SwitchCount 'true'
        Send-AtViewer 'F9' 0x78 @('ctrl', 'shift') | Out-Null
        if ($script:haveLog) {
            Assert (Wait-SwitchCount 'true' $trans0) 'S3: pressed again, the window is translucent again'
        }
    }

    # --- SUBJECT 4: the page keeps its own editing chords (T1803) -----------
    Assert (-not (Test-TestWindowZoomed -Window $top)) 'S4: the window starts restored'
    $beforeS4 = Get-KeyLog
    Assert (Send-AtViewer 'A' 0x41 @('ctrl')) 'S4: ctrl+a reached the viewer accelerator hop'
    $logS4 = Wait-KeyLog $beforeS4
    $zoom4 = $false
    for ($t = 0; $t -lt 8; $t++) { Start-Sleep -Milliseconds 200; if (Test-TestWindowZoomed -Window $top) { $zoom4 = $true; break } }
    if ($NegativeControl) {
        Assert $zoom4 'S4 (inverted): the binding took ctrl+a from the page'
    } else {
        Assert (-not $zoom4) 'S4: a binding on ctrl+a did not fire from a focused viewer'
        Assert ($logS4 -match '(=|-)ca($|-)') "S4: ...the page saw ctrl+a instead (log='$logS4')"
    }
    if ($zoom4) { Send-AtViewer 'F8' 0x77 | Out-Null }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'S4: no crash'

    # --- SUBJECT 5/6: the stash pair from a focused viewer (T1849) ----------
    function Get-AllLeaves {
        $json = (& $exe +list --json 2>$null | Out-String).Trim()
        if (-not $json) { return @() }
        $out = @()
        foreach ($w in @(($json | ConvertFrom-Json).data.windows)) {
            foreach ($tab in @($w.tabs)) { $out += @(Get-Leaves $tab.splits) }
        }
        return $out
    }
    function Test-Stashed($leaf) {
        return ($null -ne $leaf) -and ($leaf.PSObject.Properties.Name -contains 'stashed') -and ($leaf.stashed -eq $true)
    }
    function Get-ViewLeaf { @(Get-AllLeaves | Where-Object { $_.name -eq 't682view' })[0] }
    function Get-TermLeaf { @(Get-AllLeaves | Where-Object { $_.name -ne 't682view' })[0] }
    # Poll until $pred holds of a leaf (re-read each time), returning the verdict.
    function Wait-Leaf([scriptblock]$get, [bool]$stashed, [int]$ms = 5000) {
        for ($t = 0; $t -lt [int]($ms / 200); $t++) {
            if ((Test-Stashed (& $get)) -eq $stashed) { return $true }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }

    $term = Get-TermLeaf
    Assert ($null -ne $term -and $term.id) "S5: setup: the launch terminal has a pane id ($($term.id))"
    Assert (-not (Test-Stashed (Get-ViewLeaf)) -and -not (Test-Stashed $term)) 'S5: setup: nothing is stashed yet'

    $beforeS5 = Get-KeyLog
    Assert ($beforeS5 -notmatch 'csM') 'S5: no earlier arm put a ctrl+shift+M in the page log'
    Assert (Send-AtViewer 'M' 0x4D @('ctrl', 'shift')) 'S5: ctrl+shift+m reached the viewer accelerator hop'
    $viewStashed = Wait-Leaf { Get-ViewLeaf } $true
    $logS5 = Get-KeyLog
    if ($NegativeControl) {
        Assert (-not $viewStashed) 'S5 (inverted): the default stash chord at the viewer stashed nothing'
        Assert ($logS5 -match 'csM') "S5 (inverted): ctrl+shift+m leaked into the page (log='$logS5')"
    } else {
        Assert $viewStashed 'S5: the default stash chord at a focused viewer stashed the VIEWER'
        Assert (-not (Test-Stashed (Get-TermLeaf))) 'S5: ...not the terminal the core would have performed it through'
        Assert ($logS5 -notmatch 'csM') "S5: ...and the page never saw the chord (log='$logS5')"
    }

    # Put the viewer back by CLI (not under test), then stash the terminal so
    # the viewer is the only pane on screen and a restore has something to do.
    if (Test-Stashed (Get-ViewLeaf)) { & $exe +restore --target=t682view 2>&1 | Out-Null }
    Assert (Wait-Leaf { Get-ViewLeaf } $false) 'S6: setup: +restore put the viewer back on screen'
    & $exe +stash "--target=$($term.id)" 2>&1 | Out-Null
    Assert (Wait-Leaf { Get-TermLeaf } $true) 'S6: setup: +stash took the terminal out of the grid'

    $beforeS6 = Get-KeyLog
    Assert ($beforeS6 -notmatch 'csF2') 'S6: no earlier arm put a ctrl+shift+F2 in the page log'
    Assert (Send-AtViewer 'F2' 0x71 @('ctrl', 'shift')) 'S6: ctrl+shift+f2 reached the viewer accelerator hop'
    $termBack = Wait-Leaf { Get-TermLeaf } $false
    $logS6 = Get-KeyLog
    if ($NegativeControl) {
        Assert (-not $termBack) 'S6 (inverted): restore_stashed_pane from the viewer restored nothing'
        Assert ($logS6 -match 'csF2') "S6 (inverted): ctrl+shift+f2 leaked into the page (log='$logS6')"
    } else {
        Assert $termBack 'S6: restore_stashed_pane from a focused viewer brought the terminal back'
        Assert ($logS6 -notmatch 'csF2') "S6: ...and the page never saw the chord (log='$logS6')"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'S6: no crash'
} finally {
    if ($script:pageJob) { Stop-Job $script:pageJob -ErrorAction SilentlyContinue; Remove-Job $script:pageJob -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Stop-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due, and a negative-control run is red by construction.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-window-chords -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
