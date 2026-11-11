# T1468 acceptance: a screen reader can name and follow the feedback composer's
# owner-drawn chrome.
#
# The composer's two circular actions and its strip of pictures are painted by
# the band, not hosted as windows, so until T1468 Windows had nothing to say
# about them: Tab reached all of them and Narrator was silent. The band now
# answers WM_GETOBJECT with an IAccessible of its own, and this script reads it
# exactly the way Narrator's MSAA proxy does - a real cross-process
# AccessibleObjectFromWindow, then the IAccessible vtable (lib\AccProbe.ps1).
#
#   A. An open, empty composer describes itself: a group named "Feedback
#      composer" whose children are the text surface (handed out as its own
#      object) and the two actions as push buttons, named, with their keyboard
#      shortcuts - and the send button reported UNAVAILABLE while there is
#      nothing to send. Each button's location is inside the band.
#   B. Two pasted pictures become two list items named after their chips
#      (Image #1, Image #2) and placed in strip order between the text and the
#      actions; each says where it sits ("Attached picture 1 of 2"), and the
#      send button is no longer unavailable.
#   C. Focus is reported: Tab onto the strip and the object's focus is the
#      ringed tile; Tab again and it is the screenshot button. Each move also
#      raised the focus event a reader listens for (the band says so in its
#      own stderr, naming the same child).
#   D. Hit testing: the centre of a button's reported location hit-tests to
#      that button, and the centre of a tile to that tile.
#   E. Actions: the reader's "do default action" on Image #2 selects its chip,
#      exactly as a click does; "take focus" on the send button moves the
#      keyboard there.
#   F. Negative control: a child id past the end is refused, not answered -
#      the probe is able to see a failure.
#
# Runs on the BACKGROUND test desktop; nothing is seen or heard, which is the
# point - the object IS what a reader would be told.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-feedback-a11y.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-fba11y$PID"

. (Join-Path $PSScriptRoot 'lib\ComposerSurface.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
. (Join-Path $PSScriptRoot 'lib\WebViewCdp.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\AccProbe.ps1')
# AccProbe.ps1 and ComposerSurface.ps1 turn on strict mode, and a dot-sourced
# file's strict mode is the CALLER's: under it TestScore's arming reads an
# unset global and the run reports DID NOT FINISH over a clean body.
Set-StrictMode -Off
# T1510: the shared scorer, which also ARMS the run - a body that unwinds
# before `Complete-TestBody` may not print a pass and may not stamp.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

Add-Type -AssemblyName System.Drawing

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# MSAA constants (oleacc.h).
$ROLE_GROUPING = 0x14
$ROLE_LISTITEM = 0x22
$ROLE_PUSHBUTTON = 0x2B
$STATE_UNAVAILABLE = 0x1
$STATE_FOCUSED = 0x4
$SELFLAG_TAKEFOCUS = 0x1

function Stop-RepoInstances {
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

function Get-ChromeChild($paneHwnd, [string]$Class) {
    $c = @(Get-TestChildWindows -Window $paneHwnd -Class $Class)
    if ($c.Count -lt 1) { return $null }
    return [IntPtr]$c[0].Hwnd
}

function Wait-LogLine($errlog, [string]$Pattern) {
    for ($t = 0; $t -lt 40; $t++) {
        $hit = $null
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match $Pattern) { $hit = $Matches }
        }
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Wait-WorktreeShown($errlog, $paneId) {
    $m = Wait-LogLine $errlog "viewer worktree pane=$([regex]::Escape($paneId)) feedback=shown"
    return ($null -ne $m)
}

function Wait-FeedbackOpen($errlog, $paneId) {
    $m = Wait-LogLine $errlog "viewer feedback pane=$([regex]::Escape($paneId)) open=true bar_h=\d+"
    return ($null -ne $m)
}

# The count of a log line, so a wait can ask for the NEXT occurrence.
function Get-LogCount($errlog, [string]$Pattern) {
    $n = 0
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match $Pattern) { $n++ }
    }
    return $n
}

function Wait-LogCountAbove($errlog, [string]$Pattern, [int]$Before) {
    for ($t = 0; $t -lt 40; $t++) {
        if ((Get-LogCount $errlog $Pattern) -gt $Before) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# The LAST value of a capture group across the log.
function Get-LastCapture($errlog, [string]$Pattern) {
    $v = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match $Pattern) { $v = $Matches[1] }
    }
    return $v
}

function Wait-Focus($errlog, $paneId, [string]$Stop) {
    $pat = "viewer feedback focus pane=$([regex]::Escape($paneId)) stop=(\w+)"
    for ($t = 0; $t -lt 30; $t++) {
        if ((Get-LastCapture $errlog $pat) -eq $Stop) { return $Stop }
        Start-Sleep -Milliseconds 250
    }
    return (Get-LastCapture $errlog $pat)
}

function Wait-AccDump($band, $td, [scriptblock]$Test) {
    $d = $null
    for ($t = 0; $t -lt 30; $t++) {
        $d = Get-AccDump -Window $band -Desktop $td
        if (-not $d.Error -and (& $Test $d)) { return $d }
        Start-Sleep -Milliseconds 250
    }
    return $d
}

function Get-PngBytes([int]$W, [int]$H, [int]$Seed) {
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, ($x * 7 + $Seed) % 256, ($y * 11 + $Seed) % 256, 90))
        }
    }
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return , $ms.ToArray()
}

$script:ChordMsg = 0x8002
function Send-ComposerChord($band, [int]$Vk, [int]$Mods = 0) {
    return (Send-TestRawMessage -Window $band -Message $script:ChordMsg `
            -WParam ([IntPtr]$Vk) -LParam ([IntPtr]$Mods))
}

function Invoke-FeedbackButton($view) {
    [void](Send-TestRawMessage -Window $view.Pane -Message 0x8016)
    Start-Sleep -Milliseconds 600
    $nb = Get-ChromeChild $view.Pane 'GhozttyViewerNav'
    if (-not $nb) { return $false }
    $rect = Get-TestWindowRect $nb
    if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { return $false }
    $scale = $rect.Height / 36.0
    $x = [int]($rect.Right - (Get-TestChromeDip -Dip 18 -Scale $scale))
    $y = [int]($rect.Top + $rect.Height / 2)
    return (Send-TestMouse -Window $view.Top -Target $nb -X $x -Y $y)
}

function Test-Inside($c, $rect) {
    if (-not $c -or -not $rect) { return $false }
    return ($c.W -gt 0 -and $c.H -gt 0 -and
        $c.X -ge $rect.Left -and $c.Y -ge $rect.Top -and
        ($c.X + $c.W) -le $rect.Right -and ($c.Y + $c.H) -le $rect.Bottom)
}

# --- a THROWAWAY working tree, not this repo ---------------------------------
$work = Join-Path $env:TEMP ("ghoztty-fba11y-accept-" + $PID)
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Content -Path (Join-Path $work 'README.md') -Encoding utf8 -Value @('# Throwaway', '', 'a paragraph', '')
& git -C $work init --initial-branch=main *> $null
& git -C $work add -A *> $null
& git -C $work -c user.name='ghoztty test' -c user.email='test@ghoztty' commit -m 'throwaway' *> $null
$viewFile = Join-Path $work 'README.md'

Stop-RepoInstances
$script:cdpPort = Enable-WebViewCdp
$cdp = $null
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP "ghoztty-viewer-feedback-a11y-stderr-$PID.log"
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    $r = Invoke-Verb @('+new-window', '--target=a11ywin', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'a11ywin')) 'the viewer window exists'
    $paneId = Get-OnlyPaneId 'a11ywin'
    Assert ($null -ne $paneId) "the viewer window has exactly one pane (id '$paneId')"
    Assert (Wait-WorktreeShown $errlog $paneId) 'the pane resolved a worktree, so it can file a report'

    $view = $null
    for ($t = 0; $t -lt 20; $t++) {
        $view = Get-ViewerHost $appPid
        if ($view) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $view) 'the viewer host window was found'
    if (-not $view) { throw 'no viewer host window' }

    Assert (Invoke-FeedbackButton $view) 'the revealed nav bar took a click at the feedback button'
    Assert (Wait-FeedbackOpen $errlog $paneId) 'the pane reports the composer OPEN'
    Assert (Wait-ComposerSurface $errlog 'web') `
        "...on the web surface users get (got '$(Get-ComposerSurface $errlog)')"

    $fb = $null
    for ($t = 0; $t -lt 20; $t++) {
        $fb = Get-ChromeChild $view.Pane 'GhozttyViewerFeedback'
        if ($fb) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $fb) 'a GhozttyViewerFeedback child window exists'
    if (-not $fb) { throw 'no composer window' }

    try { $cdp = Find-CdpComposer -Port $script:cdpPort } catch { Write-Host "  $($_.Exception.Message)" }
    Assert ($null -ne $cdp) "the composer's page answers on the DevTools port"
    if (-not $cdp) { throw 'no composer page to drive' }

    # --- A. the empty composer describes itself ------------------------------
    $d = Wait-AccDump $fb $td { param($x) $x.Self -and $x.Self.Count -ge 3 }
    Assert (-not $d.Error) "the band answers for its client area (probe: '$($d.Error)')"
    if ($d.Error) { throw "no accessible object: $($d.Raw)" }
    Assert ($d.Self.Name -eq 'Feedback composer') "the band is named 'Feedback composer' (got '$($d.Self.Name)')"
    Assert ($d.Self.Role -eq "$ROLE_GROUPING") "...and is a grouping (role '$($d.Self.Role)')"
    Assert ($d.Self.Count -eq 3) `
        "an empty composer has three children: the text surface and two actions (got $($d.Self.Count); raw: $($d.Raw -replace "`n", ' ; '))"

    $text = Get-AccChild $d 1
    Assert ($text -and $text.Obj) 'child 1 is the text surface, handed out as its own object'

    $bandRect = Get-TestWindowRect $fb
    $snap = Get-AccChild $d 2
    Assert ($snap -and $snap.Name -eq 'Add a screenshot of the screen') "child 2 is named 'Add a screenshot of the screen' (got '$($snap.Name)')"
    Assert ($snap -and $snap.Role -eq "$ROLE_PUSHBUTTON") "...a push button (role '$($snap.Role)')"
    Assert ($snap -and $snap.Key -eq 'Ctrl+Shift+S') "...whose shortcut is Ctrl+Shift+S (got '$($snap.Key)')"
    Assert ($snap -and $snap.Action -eq 'Press') "...whose default action is Press (got '$($snap.Action)')"
    Assert ($snap -and -not (Test-AccState $snap.State $STATE_UNAVAILABLE)) "...and it can be pressed (state '$($snap.State)')"
    Assert (Test-Inside $snap $bandRect) "...located inside the band ($($snap.X),$($snap.Y) $($snap.W)x$($snap.H))"

    $send = Get-AccChild $d 3
    Assert ($send -and $send.Name -eq 'Send feedback') "child 3 is named 'Send feedback' (got '$($send.Name)')"
    Assert ($send -and $send.Key -eq 'Ctrl+Enter') "...whose shortcut is Ctrl+Enter (got '$($send.Key)')"
    Assert ($send -and (Test-AccState $send.State $STATE_UNAVAILABLE)) `
        "...reported UNAVAILABLE while there is nothing to send (state '$($send.State)')"
    Assert (Test-Inside $send $bandRect) "...located inside the band ($($send.X),$($send.Y) $($send.W)x$($send.H))"

    # --- B. pictures become named list items, in strip order -----------------
    Send-CdpComposerImage -Conn $cdp -Bytes (Get-PngBytes 40 30 17)
    Send-CdpComposerImage -Conn $cdp -Bytes (Get-PngBytes 20 12 91)
    $d = Wait-AccDump $fb $td { param($x) $x.Self -and $x.Self.Count -eq 5 }
    Assert ($d.Self.Count -eq 5) "two pictures add two children (count $($d.Self.Count))"
    $t1 = Get-AccChild $d 2
    $t2 = Get-AccChild $d 3
    Assert ($t1 -and $t1.Name -eq 'Image #1') "child 2 is the first picture, named after its chip (got '$($t1.Name)')"
    Assert ($t2 -and $t2.Name -eq 'Image #2') "child 3 is the second (got '$($t2.Name)')"
    Assert ($t1 -and $t1.Role -eq "$ROLE_LISTITEM") "...as list items (role '$($t1.Role)')"
    Assert ($t1 -and $t1.Desc -eq 'Attached picture 1 of 2') "...that say where they sit (got '$($t1.Desc)')"
    Assert ($t1 -and $t1.Action -eq 'Select in report') "...and what pressing one does (got '$($t1.Action)')"
    Assert (Test-Inside $t1 (Get-TestWindowRect $fb)) "...located inside the band ($($t1.X),$($t1.Y) $($t1.W)x$($t1.H))"
    $snap = Get-AccChild $d 4
    $send = Get-AccChild $d 5
    Assert ($snap -and $snap.Name -eq 'Add a screenshot of the screen') "the actions follow the pictures (child 4 '$($snap.Name)')"
    Assert ($send -and $send.Name -eq 'Send feedback' -and -not (Test-AccState $send.State $STATE_UNAVAILABLE)) `
        "...and send can be pressed now there is a report (child 5 '$($send.Name)', state '$($send.State)')"

    # --- C. focus is reported, and announced ---------------------------------
    $accFocusPat = "viewer feedback acc focus pane=$([regex]::Escape($paneId)) child=(\d+)"
    $before = Get-LogCount $errlog $accFocusPat
    [void](Send-ComposerChord $fb 0x09)
    Assert ((Wait-Focus $errlog $paneId 'carousel') -eq 'carousel') 'Tab from the text lands on the strip'
    $d = Wait-AccDump $fb $td { param($x) $x.Focus -eq '2' -or $x.Focus -eq '3' }
    Assert ($d.Focus -eq '2' -or $d.Focus -eq '3') "the object reports a picture as focused (focus '$($d.Focus)')"
    $ft = Get-AccChild $d ([int]("0" + ($d.Focus -replace '\D', '')))
    Assert ($ft -and (Test-AccState $ft.State $STATE_FOCUSED)) "...and that picture's state says FOCUSED (state '$($ft.State)')"
    Assert (Wait-LogCountAbove $errlog $accFocusPat $before) 'the move raised a focus event'
    Assert ((Get-LastCapture $errlog $accFocusPat) -eq $d.Focus) `
        "...naming the same child the object reports ($(Get-LastCapture $errlog $accFocusPat) vs $($d.Focus))"

    $before = Get-LogCount $errlog $accFocusPat
    [void](Send-TestControlKey -Control $fb -Key Tab)
    Assert ((Wait-Focus $errlog $paneId 'snapshot') -eq 'snapshot') 'Tab again lands on the screenshot button'
    $d = Wait-AccDump $fb $td { param($x) $x.Focus -eq '4' }
    Assert ($d.Focus -eq '4') "the object reports the screenshot button as focused (focus '$($d.Focus)')"
    Assert ((Wait-LogCountAbove $errlog $accFocusPat $before) -and (Get-LastCapture $errlog $accFocusPat) -eq '4') `
        "...and the focus event named it ($(Get-LastCapture $errlog $accFocusPat))"

    # --- D. hit testing ------------------------------------------------------
    $snap = Get-AccChild $d 4
    $hit = Invoke-AccAction -Window $fb -Desktop $td -Op hitTest -A ($snap.X + [int]($snap.W / 2)) -B ($snap.Y + [int]($snap.H / 2))
    Assert ($hit -eq '4') "the centre of the screenshot button hit-tests to it (got '$hit')"
    $t2 = Get-AccChild $d 3
    $hit = Invoke-AccAction -Window $fb -Desktop $td -Op hitTest -A ($t2.X + [int]($t2.W / 2)) -B ($t2.Y + [int]($t2.H / 2))
    Assert ($hit -eq '3') "the centre of Image #2 hit-tests to it (got '$hit')"

    # --- E. actions run, the way a click does --------------------------------
    $r = Invoke-AccAction -Window $fb -Desktop $td -Op doDefault -A 3
    Assert ($r -eq 'ok') "the reader's default action on Image #2 is accepted (got '$r')"
    $m = Wait-LogLine $errlog "viewer feedback pane=$([regex]::Escape($paneId)) thumbnail=#2 chip=(\d+)\.\.(\d+)"
    Assert ($null -ne $m) "...and selects Image #2's chip, as a click on the tile does"
    $d = Wait-AccDump $fb $td { param($x) $x.Selection -eq '3' }
    Assert ($d.Selection -eq '3') "the object then reports Image #2 as the selection (got '$($d.Selection)')"

    $r = Invoke-AccAction -Window $fb -Desktop $td -Op select -A $SELFLAG_TAKEFOCUS -B 5
    Assert ($r -eq 'ok') "the reader's take-focus on the send button is accepted (got '$r')"
    Assert ((Wait-Focus $errlog $paneId 'send') -eq 'send') 'the keyboard moves to the send button'
    $d = Wait-AccDump $fb $td { param($x) $x.Focus -eq '5' }
    Assert ($d.Focus -eq '5') "the object reports the send button as focused (focus '$($d.Focus)')"

    # --- F. negative control: the probe can see a refusal --------------------
    $bad = Invoke-AccAction -Window $fb -Desktop $td -Op name -A 99
    Assert ($bad -eq '!80070057') "a child id past the end is refused with E_INVALIDARG, not named (got '$bad')"
    $good = Invoke-AccAction -Window $fb -Desktop $td -Op name -A 5
    Assert ($good -eq 'Send feedback') "...while the same call on a real id answers (got '$good')"

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} catch {
    # The foreground-leak check below is part of this run too, so this try
    # cannot END in `Complete-TestBody`; it scores its own throw instead, so
    # an unwind here can never reach a green verdict (T1511 shape).
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Close-Cdp $cdp
    Disable-WebViewCdp
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this harness been run against the composer as it now
# stands?". Red leaves the stamp alone - red stays due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-feedback-a11y -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'VIEWER FEEDBACK A11Y ACCEPTANCE'
