# T934 acceptance: the feedback composer's WEB surface.
#
# The composer's text rect stopped being a RichEdit and became a second
# `ICoreWebView2Controller` hosting our own contenteditable page (D43's answer).
# This script is that surface's acceptance; `test\win32\viewer-feedback.ps1`
# keeps proving the EDITING semantics against the RichEdit fallback it pins
# itself to, because window messages cannot drive a Chromium window from the
# background test desktop.
#
# What is asserted:
#
#   A. opening the composer creates a WEB surface -- the pane says
#      `viewer feedback composer surface=web`, not one of the `richedit(...)`
#      degrades.
#   B. the page LOADED: `viewer composer ready` means NavigateToString took the
#      document, the engine parsed it, and its script ran far enough to post.
#   C. the round trip WORKS in both directions: the host seeded the page from
#      the pane's buffer and the page read its own document back and pushed a
#      snapshot up -- `viewer composer echo pane=<id> bytes=0 lines=1` for an
#      empty composer. Nothing else outside the process can see that channel.
#   D. the view is a real child of the band, sized inside it -- i.e. the
#      controller's bounds were set from the pill's text rect rather than left
#      at 0x0.
#   E. closing the composer GIVES THE RENDERER BACK (D43's own mitigation):
#      the controller is destroyed and its window tree goes with it.
#   F. reopening builds a new one, loads, and echoes again -- the lazy
#      create/destroy cycle is repeatable rather than a one-shot.
#   G. the band is still exactly the height the pane reserved for it, so the
#      swap did not move the geometry.
#   H. TYPING reaches the web surface from the background desktop (T1702):
#      lib\WebViewCdp.ps1 arms the runtime's DevTools port, finds the composer's
#      page, types text and an Enter into it, and reads the document back - and
#      the HOST's own echo line agrees on the byte count, so the keystrokes went
#      through the page into the pane's buffer, not just into a DOM. Ctrl+Z /
#      Ctrl+Y, which the PAGE owns (T983), take the typing back and forth.
#
# ORACLES. This runs on the background test desktop, where CopyFromScreen and
# SendInput are dead (T233), so nothing here looks at a painted caret. Two
# things are readable and both are the real thing:
#
#   * the controller's window tree is REAL windows, so its existence, its
#     parentage and its rect are ordinary window-helper reads.
#   * the composer states every step of its own lifecycle in stderr, and the
#     `echo` line is a number the PAGE produced -- a value that cannot exist
#     unless the document loaded, the seed arrived and the snapshot came back.
#
# Typing is section H, and it goes through the DevTools protocol rather than
# the window: a posted WM_CHAR does not reach a Chromium renderer, and there is
# no input desktop here. (The in-process `host floor` test in `ViewerPane.zig`
# still drives a real controller through open, seed, quote, send and a report
# on disk.) What H does NOT prove is a chord NATIVE owns - Ctrl+Enter, Esc -
# because native reads modifiers from the OS keyboard state; see the header of
# lib\WebViewCdp.ps1.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-composer.ps1
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
$env:GHOZTTY_PIPE_SUFFIX = "-fbwebtest$PID"
# The DEFAULT surface, stated rather than assumed: this suite is about the web
# composer, and a stale `richedit` left in the environment by another run would
# turn every arm below into a confusing failure.
$env:GHOZTTY_COMPOSER_SURFACE = 'web'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T1702: the DevTools driver, armed before the launch below - the runtime reads
# the switch when the app's browser process starts.
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
. (Join-Path $PSScriptRoot 'lib\WebViewCdp.ps1')
$cdpPort = Enable-WebViewCdp
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

function Get-ViewerHost($appPid) {
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
            return [pscustomobject]@{ Top = [IntPtr]$top.Hwnd; Pane = [IntPtr]$h.Hwnd }
        }
    }
    return $null
}

# `-Class $null` is load-bearing: Get-TestChildWindows DEFAULTS to
# 'GhozttyTerminal', so an unfiltered-looking call with no -Class enumerates
# nothing at all.
function Get-ChromeChild($paneHwnd, [string]$Class) {
    $c = @(Get-TestChildWindows -Window $paneHwnd -Class $Class)
    if ($c.Count -lt 1) { return $null }
    return [IntPtr]$c[0].Hwnd
}

# The composer's own web view: a `Chrome_WidgetWin_0` parented to the BAND.
# That parentage is the assertion -- the pane's page has one too, but it hangs
# off the pane, and confusing the two would let this pass with no composer view
# at all.
function Get-ComposerView($fb) {
    foreach ($c in @(Get-TestChildWindows -Window $fb -Class $null)) {
        if ([string]$c.Class -ne 'Chrome_WidgetWin_0') { continue }
        return $c
    }
    return $null
}

function Measure-LogLine($errlog, [string]$Pattern) {
    if (-not (Test-Path $errlog)) { return 0 }
    $n = 0
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match $Pattern) { $n++ }
    }
    return $n
}

function Wait-Log($errlog, [string]$Pattern, [int]$AtLeast = 1) {
    for ($t = 0; $t -lt 60; $t++) {
        if ((Measure-LogLine $errlog $Pattern) -ge $AtLeast) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

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

function Wait-WorktreeShown($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer worktree pane=$([regex]::Escape($paneId)) feedback=shown") { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Reveal the nav bar and click its trailing feedback button -- the same
# mechanism viewer-feedback.ps1 uses, seeded open with
# WM_APP_VIEWER_FOCUS_ADDRESS (WM_APP+22) because a hidden bar has never been
# placed.
function Invoke-FeedbackButton($view) {
    [void](Send-TestRawMessage -Window $view.Pane -Message 0x8016)
    Start-Sleep -Milliseconds 600
    $nb = Get-ChromeChild $view.Pane 'GhozttyViewerNav'
    if (-not $nb) { return $false }
    $rect = Get-TestWindowRect $nb
    if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { return $false }
    $scale = $rect.Height / 36.0
    $x = [int]($rect.Right - [Math]::Round(18 * $scale))
    $y = [int]($rect.Top + $rect.Height / 2)
    return (Send-TestMouse -Window $view.Top -Target $nb -X $x -Y $y)
}

# A THROWAWAY working tree, not this repo: the composer only opens in a pane
# that has somewhere to file, and pointing that at this checkout would put junk
# in the user's own report queue.
$work = Join-Path $env:TEMP ("ghoztty-composer-accept-" + $PID)
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
$workRoot = (& git -C $work rev-parse --show-toplevel 2>$null | Out-String).Trim().Replace('/', '\')
if (-not $workRoot) { Write-Host "SETUP FAIL: could not make a throwaway repo at $work"; exit 1 }

$viewFile = Join-Path $work 'README.md'

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-composer-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    $r = Invoke-Verb @('+new-window', '--target=cmpwin', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'cmpwin')) 'the viewer window exists'
    $paneId = Get-OnlyPaneId 'cmpwin'
    Assert ($null -ne $paneId) "the viewer window has exactly one pane (id '$paneId')"
    Assert (Wait-WorktreeShown $errlog $paneId) 'the pane resolved a worktree, so the composer can open'

    $view = $null
    for ($t = 0; $t -lt 20; $t++) {
        $view = Get-ViewerHost $appPid
        if ($view) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $view) 'the viewer host window was found'
    if (-not $view) { throw 'no viewer host window' }

    # --- A. opening builds a WEB surface -------------------------------------
    Assert (Invoke-FeedbackButton $view) 'the revealed nav bar took a click at the feedback button'
    $s = Wait-FeedbackState $errlog $paneId $true
    Assert ($s -and $s.Open) "the pane reports the composer OPEN (state '$($s.Open)')"

    Assert (Wait-Log $errlog 'viewer feedback composer surface=web' 1) `
        'the composer chose the WEB surface (surface=web)'
    $degraded = Measure-LogLine $errlog 'viewer feedback composer surface=richedit'
    Assert ($degraded -eq 0) `
        "...and never fell back to the RichEdit ($degraded degrade(s) logged)"

    # --- B. the page loaded --------------------------------------------------
    Assert (Wait-Log $errlog 'viewer composer page loading bytes=\d+' 1) `
        'the document was handed to NavigateToString'
    Assert (Wait-Log $errlog 'viewer composer ready' 1) `
        'the page loaded and its script posted `ready` back'

    # --- C. the round trip, in both directions -------------------------------
    # An empty composer is zero bytes and one line, and BOTH numbers came from
    # the page: `bytes` is what its own read path walked out of the DOM,
    # `lines` is what it measured. A host that seeded but never heard back, or
    # heard back garbage, cannot produce this line.
    Assert (Wait-Log $errlog "viewer composer echo pane=$([regex]::Escape($paneId)) bytes=0 lines=1" 1) `
        'the page echoed the seeded (empty) document back as 0 bytes on 1 line'

    # --- D. the view is a real child of the band, sized inside it ------------
    $fb = $null
    for ($t = 0; $t -lt 20; $t++) {
        $fb = Get-ChromeChild $view.Pane 'GhozttyViewerFeedback'
        if ($fb) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $fb) 'a GhozttyViewerFeedback band exists'
    if (-not $fb) { throw 'no composer band' }

    $cv = $null
    for ($t = 0; $t -lt 20; $t++) {
        $cv = Get-ComposerView $fb
        if ($cv -and $cv.Width -gt 0) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $cv) 'the band hosts a WebView2 controller window'
    Assert ($cv -and $cv.Width -gt 0 -and $cv.Height -gt 0) `
        "...placed inside the pill rather than left at 0x0 ($($cv.Width)x$($cv.Height))"

    $fbRect = Get-TestWindowRect $fb
    Assert ($cv -and $fbRect -and $cv.Width -lt $fbRect.Width -and $cv.Height -lt $fbRect.Height) `
        'the view fills the pill''s TEXT RECT, not the whole band'
    # --- G. the band is still the height the pane reserved -------------------
    Assert ($fbRect -and $s -and $fbRect.Height -eq $s.BarH) `
        "the band is exactly the height the pane reserved ($($fbRect.Height) vs $($s.BarH))"

    # --- E. closing gives the renderer back ----------------------------------
    $destroyedBefore = Measure-LogLine $errlog 'viewer composer destroyed'
    Assert (Invoke-FeedbackButton $view) 're-clicking the feedback button reaches the pane'
    $s2 = Wait-FeedbackState $errlog $paneId $false
    Assert ($s2 -and -not $s2.Open) "the composer closed (state '$($s2.Open)')"
    Assert (Wait-Log $errlog 'viewer composer destroyed' ($destroyedBefore + 1)) `
        'closing DESTROYED the controller (D43''s lazy-lifetime mitigation)'

    $gone = $null
    for ($t = 0; $t -lt 20; $t++) {
        $gone = Get-ComposerView $fb
        if (-not $gone) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -eq $gone) '...and its window tree went with it'

    # --- F. reopening builds a new one ---------------------------------------
    Assert (Invoke-FeedbackButton $view) 'the feedback button reopens the composer'
    $s3 = Wait-FeedbackState $errlog $paneId $true
    Assert ($s3 -and $s3.Open) 'the composer reopens'
    Assert (Wait-Log $errlog 'viewer feedback composer surface=web' 2) `
        'the reopened composer is a WEB surface again'
    Assert (Wait-Log $errlog 'viewer composer ready' 2) `
        '...whose page loaded again'
    Assert (Wait-Log $errlog "viewer composer echo pane=$([regex]::Escape($paneId)) bytes=0 lines=1" 2) `
        '...and echoed again -- the create/destroy cycle is repeatable'

    $cv2 = $null
    for ($t = 0; $t -lt 20; $t++) {
        $cv2 = Get-ComposerView $fb
        if ($cv2 -and $cv2.Width -gt 0) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $cv2 -and $cv2.Width -gt 0) 'a fresh controller window is back in the band'

    # --- H. typing reaches the web surface (T1702) ---------------------------
    # The negative control first: a port nobody armed answers with NO targets,
    # so the finds below cannot be scoring a driver that sees pages everywhere.
    $unarmed = Get-FreePort
    Assert (@(Get-CdpTargets -Port $unarmed).Count -eq 0) `
        "an unarmed port ($unarmed) lists no pages"

    $cdp = $null
    try {
        $cdp = Find-CdpComposer -Port $cdpPort
    } catch {
        Write-Host "      $($_.Exception.Message)"
    }
    Assert ($null -ne $cdp) "the composer's page was found on the DevTools port ($cdpPort)"
    if ($cdp) {
        try {
            # A non-ASCII letter on purpose: the page counts UTF-16 units and the
            # host counts UTF-8 bytes (the T648 boundary), so the host's byte
            # count below only matches when the text crossed intact.
            $first = 'h' + [char]0xE9 + 'llo'
            Send-CdpComposerText $cdp $first
            Send-CdpKey $cdp 'Enter'
            Send-CdpComposerText $cdp 'world'
            $want = $first + "`n" + 'world'
            $got = Wait-CdpComposerText $cdp $want
            Assert ($got -ceq $want) "typed text reads back from the page ('$($got -replace "`n", '\n')')"

            # Undo takes 'world' back and leaves the first line. Not compared to an
            # exact string: the engine restores the post-Enter document, whose
            # empty last line it may keep as a trailing "\n" text placeholder
            # rather than a <br> - the page serializes that as a second break
            # (T1705), which is a separate defect from whether undo worked.
            Send-CdpKey $cdp 'z' -Ctrl
            $undone = Get-CdpComposerText $cdp
            $undoOk = ($undone -notmatch 'w') -and $undone.StartsWith($first + "`n")
            Assert $undoOk `
                "Ctrl+Z (the page's own undo) took typing back ('$($undone -replace "`n", '\n')')"
            if (-not $undoOk) {
                $html = Invoke-CdpEval $cdp "JSON.stringify(document.getElementById('c').innerHTML)"
                Write-Host "      the box after Ctrl+Z: $html"
            }
            Send-CdpKey $cdp 'y' -Ctrl
            $redone = Wait-CdpComposerText $cdp $want
            Assert ($redone -ceq $want) "Ctrl+Y put it back ('$($redone -replace "`n", '\n')')"

            Send-CdpKey $cdp 'Backspace'
            $bs = Wait-CdpComposerText $cdp ($first + "`n" + 'worl')
            Assert ($bs -ceq ($first + "`n" + 'worl')) 'Backspace removed exactly one character'
        } finally {
            Close-Cdp $cdp
        }

        # The typing reached the HOST, not just a DOM: close the composer (its
        # page is destroyed), reopen it, and the new page is seeded from the
        # pane's buffer. The first echo after an open states that buffer's
        # UTF-8 size, and the new page must read back the same document.
        $final = $first + "`n" + 'worl'
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($final)
        $destroyed = Measure-LogLine $errlog 'viewer composer destroyed'
        Assert (Invoke-FeedbackButton $view) 'the feedback button closes the typed-into composer'
        Assert (Wait-Log $errlog 'viewer composer destroyed' ($destroyed + 1)) '...and its page is destroyed'
        Assert (Invoke-FeedbackButton $view) 'the feedback button reopens it'
        Assert (Wait-Log $errlog "viewer composer echo pane=$([regex]::Escape($paneId)) bytes=$bytes lines=2" 1) `
            "the HOST held the typing: the reopened page echoed $bytes bytes on 2 lines"
        $cdp2 = $null
        try {
            $cdp2 = Find-CdpComposer -Port $cdpPort
            $back = Wait-CdpComposerText $cdp2 $final
            Assert ($back -ceq $final) "the reopened page was seeded with the typed text ('$($back -replace "`n", '\n')')"
        } catch {
            Assert $false "the reopened composer's page could be read: $($_.Exception.Message)"
        } finally {
            Close-Cdp $cdp2
        }
    }

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
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this harness been run against the composer as it now stands?".
# Red leaves the stamp alone -- red stays due.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-composer -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail
