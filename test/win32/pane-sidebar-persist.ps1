# T1847 acceptance: the pane sidebar's pin, hidden flag and width survive a
# restart (Mac `PaneSidebarState` keeps the new-window defaults in
# UserDefaults, and `SessionLayoutManifest` records each window's pin and
# hidden flags).
#
# Two stores, two sections:
#
#   A. The new-window DEFAULTS (`%LOCALAPPDATA%\ghoztty\pane_sidebar-debug`),
#      session persistence OFF so nothing is restored and every window is new:
#        1. A fresh profile opens on the rail and has written no file.
#        2. The pin writes `1 0 240`; an edge drag to 300 writes `1 0 300`.
#        3. Relaunched, the new window opens PINNED at 300 DIP.
#        4. ctrl+shift+s writes `1 1 300`; relaunched, the sidebar is hidden.
#   B. The per-window flags in the SESSION LAYOUT, persistence ON:
#        5. A pinned window records `"pane_sidebar_pinned":true` in the
#           manifest.
#        6. With the defaults file rewritten to "unpinned", the restored window
#           still comes back PINNED: the manifest outranks the defaults, and
#           (Mac parity) the restored choice becomes the next default.
#        7. A manifest with the fields stripped (a pre-T1847 one) restores the
#           window on the defaults instead: the rail.
#
# Isolation: LOCALAPPDATA points at a throwaway dir for every launched
# instance, so the defaults file, the manifest and the agent state dir are all
# this run's own. Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never
# takes the user's foreground - asserted by the foreground watcher.
# -NegativeControl deletes the defaults file before the step-3 relaunch, so
# the window opens on the rail and the run MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-persist.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
# A launch that found another instance on the shared pipe would forward and
# exit; this run's instances answer only to it.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1847')

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$fakeLocal = Join-Path $env:TEMP ("ghoztty-t1847-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $fakeLocal 'ghoztty') | Out-Null
$prefFile = Join-Path $fakeLocal 'ghoztty\pane_sidebar-debug'
$manifest = Join-Path $fakeLocal 'ghoztty\session-layout-debug.json'
$errlog = Join-Path $fakeLocal 'app-stderr.log'

function Read-Pref { if (Test-Path $prefFile) { (Get-Content $prefFile -Raw).Trim() } else { '<absent>' } }
function Wait-Pref([string]$Want, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        if ((Read-Pref) -eq $Want) { return $true }
        Start-Sleep -Milliseconds 150
    } while ((Get-Date) -lt $deadline)
    return $false
}
function Read-Manifest { if (Test-Path $manifest) { Get-Content $manifest -Raw } else { '' } }
function Wait-Manifest([string]$Pattern, [int]$Ms = 6000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        if ((Read-Manifest) -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $false
}
# No BOM: PS 5.1's UTF8 encoding writes one, the JSON parser rejects the file,
# and restore silently falls back to a fresh window (session-restore-maximized.ps1).
function Write-NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale) }
function Near([int]$A, [int]$B) { [math]::Abs($A - $B) -le 2 }
function Width-Is($top, [double]$Dip) {
    $sb = Get-Sidebar $top
    return ($null -ne $sb -and $sb.Visible -and (Near $sb.Width (Px $Dip)))
}
function Describe($top) {
    $sb = Get-Sidebar $top
    if ($null -eq $sb) { return '<none>' }
    return "visible=$($sb.Visible) width=$($sb.Width)"
}

# The rail's pin: centered in the 28 DIP tile at the top of the 44 DIP card,
# which sits a 12 DIP margin in (pane-sidebar.ps1's Get-PinCenter).
function Get-RailPin($sb) {
    $margin = Px 12; $card = Px 44; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $sb.Left + $margin + $inset + [int]($tile / 2); Y = $sb.Top + $margin + $inset + [int]($tile / 2) }
}
function Invoke-EdgeDrag($top, $target, [int]$x0, [int]$y, [double[]]$steps) {
    $ok = Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $x0 -Y $y -Action down
    $x = $x0
    foreach ($s in $steps) {
        $x = $x0 + (Px $s)
        [void](Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $x -Y $y -Action move)
        Start-Sleep -Milliseconds 120
    }
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $x -Y $y -Action up)
    Start-Sleep -Milliseconds 500
    return $ok
}
function Send-HideChord($top) {
    $p = @(Get-Panes $top) | Select-Object -First 1
    if ($null -eq $p) { return $false }
    [void](Focus-TestWindow -Window $top -Child ([IntPtr]$p.Hwnd))
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$p.Hwnd) -Modifiers ctrl,shift -Key S
    Start-Sleep -Milliseconds 600
    return $r
}

# Launch with LOCALAPPDATA redirected; returns the top window. Keeps the
# placement memory (and so the defaults file) - the relaunch half of every
# step is the subject.
function Launch([bool]$Persist) {
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    $flag = if ($Persist) { '--session-persistence=true' } else { '--session-persistence=false' }
    try {
        # persistence: per section - OFF for the defaults file (A), ON for the manifest (B).
        $a = Start-OnTestDesktop -Exe $Exe -StdErr $errlog -KeepWindowPlacement `
            -Arguments @($flag, '--macos-pane-style=flat')
    } finally { $env:LOCALAPPDATA = $saved }
    Start-Sleep -Seconds 3
    $script:app = $a
    $script:launched += $a.Pid
    $t = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($t -ne [IntPtr]::Zero) {
        $dpi = Get-TestWindowDpi -Window $t
        if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
        # Wide enough for the pinned panel (>= 720 DIP).
        [void](Set-TestWindowSize -Window $t -Width (Px 1100) -Height (Px 700))
        Start-Sleep -Milliseconds 700
    }
    return $t
}
function Stop-App {
    if ($script:app) { Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1847'

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$script:launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    "== 1: a fresh profile opens on the rail and writes nothing"
    $top = Launch $false
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $script:app.Pid))
    Assert "the 68 DIP rail is up ($(Describe $top))" (Width-Is $top 68)
    Assert "no defaults file yet ($(Read-Pref))" ((Read-Pref) -eq '<absent>')

    "== 2: the pin and an edge drag write the defaults file"
    $sb = Get-Sidebar $top
    $pin = Get-RailPin $sb
    Assert "pin click delivered" (Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $pin.X -Y $pin.Y -Action click)
    Start-Sleep -Milliseconds 600
    Assert "pinned: the 240 DIP panel ($(Describe $top))" (Width-Is $top 240)
    Assert "the file says pinned, shown, 240 ($(Read-Pref))" (Wait-Pref '1 0 240')
    $sb = Get-Sidebar $top
    [void](Invoke-EdgeDrag $top $sb.Hwnd ($sb.Right - 2) ($sb.Top + (Px 300)) @(30, 60))
    Assert "the drag widened the panel to 300 ($(Describe $top))" (Width-Is $top 300)
    Assert "the drag's end wrote the width ($(Read-Pref))" (Wait-Pref '1 0 300')
    Stop-App

    "== 3: relaunched, a new window opens pinned at the remembered width"
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: deleting the defaults file - this run MUST fail"
        Remove-Item $prefFile -Force -ErrorAction SilentlyContinue
    }
    $top = Launch $false
    Assert "relaunched" ($top -ne [IntPtr]::Zero)
    Assert "the new window is pinned at 300 DIP ($(Describe $top))" (Width-Is $top 300)

    "== 4: hidden survives a restart too"
    Assert "ctrl+shift+s delivered" (Send-HideChord $top)
    $sb = Get-Sidebar $top
    Assert "the sidebar is hidden ($(Describe $top))" ($null -eq $sb -or -not $sb.Visible)
    Assert "the file says hidden ($(Read-Pref))" (Wait-Pref '1 1 300')
    Stop-App
    $top = Launch $false
    $sb = Get-Sidebar $top
    Assert "relaunched, the new window's sidebar is hidden ($(Describe $top))" ($top -ne [IntPtr]::Zero -and ($null -eq $sb -or -not $sb.Visible))
    Assert "ctrl+shift+s shows it again" (Send-HideChord $top)
    Assert "pinned at 300 again ($(Describe $top))" (Width-Is $top 300)
    Assert "the file says shown ($(Read-Pref))" (Wait-Pref '1 0 300')
    Stop-App

    "== 5: a pinned window records its flags in the session layout"
    Remove-Item $manifest -Force -ErrorAction SilentlyContinue
    $top = Launch $true
    Assert "launched with persistence on" ($top -ne [IntPtr]::Zero)
    Assert "it opens pinned from the defaults ($(Describe $top))" (Width-Is $top 300)
    # Any layout change schedules a manifest write; a resize is one.
    [void](Set-TestWindowSize -Window $top -Width (Px 1120) -Height (Px 700))
    Assert "the manifest records pane_sidebar_pinned:true" (Wait-Manifest '"pane_sidebar_pinned"\s*:\s*true')
    Assert "and pane_sidebar_hidden:false" ((Read-Manifest) -match '"pane_sidebar_hidden"\s*:\s*false')
    Stop-App

    "== 6: the manifest outranks the defaults on restore"
    Write-NoBom $prefFile "0 0 240`n"
    $top = Launch $true
    Assert "restored" ($top -ne [IntPtr]::Zero)
    Assert "the restored window is PINNED although the default says rail ($(Describe $top))" (Width-Is $top 240)
    Assert "and the restored choice became the next default, as on Mac ($(Read-Pref))" (Wait-Pref '1 0 240')
    Stop-App

    "== 7: a manifest without the fields restores on the defaults"
    $m = Read-Manifest
    $stripped = $m -replace ',\s*"pane_sidebar_(pinned|hidden)"\s*:\s*(true|false)', ''
    Assert "setup: both fields stripped" ($stripped -ne $m -and $stripped -notmatch 'pane_sidebar_')
    Write-NoBom $manifest $stripped
    Write-NoBom $prefFile "0 0 240`n"
    $top = Launch $true
    Assert "restored" ($top -ne [IntPtr]::Zero)
    Assert "the window is on the rail, the default ($(Describe $top))" (Width-Is $top 68)
    Stop-App

    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($script:launched | Select-Object -Unique)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}
Remove-Item -Recurse -Force $fakeLocal -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-persist -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1847' -Path $transcript `
        -Label 'T1847 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
