# T1966 acceptance: a script-opened BACKGROUND window (`+new-window` without
# `--focus`, T1797) opens at the same frame a focused new window does - the
# remembered size, the cascade position, and the remembered MAXIMIZED state.
# The win32 half of main ec6c793d7, where Mac's background path skipped the
# initial-frame setup and came up at the 800x600 placeholder.
#
# On win32 the size and cascade position are decided at CreateWindowExW, before
# either show path runs, so arm A is the regression guard that keeps it so. The
# maximized state was the real gap: Windows has no maximize-without-activate
# show command, so the background path dropped it until T1966 maximized by
# style and showed with SW_SHOWNA.
#
#   A  memory "W H 0": bg window and --focus window both open at W x H, each
#      cascaded 30px from the window before it
#   B  memory "W H 1": bg window opens MAXIMIZED, does not activate, restores
#      down to W x H; the --focus window opens maximized too
#
# -NegativeControl inverts B's "bg window is maximized" assert and MUST fail:
# a run that passes with it means the oracle cannot see the maximized state.
#
# Isolation: LOCALAPPDATA is a throwaway dir for the app (the placement memory
# lives there), the IPC pipe is private, and everything runs on a background
# test desktop. Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\background-window-frame.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-bgframe$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$fakeLocal = Join-Path $env:TEMP ("ghoztty-t1966-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $fakeLocal 'ghoztty') | Out-Null
$memFile = Join-Path $fakeLocal 'ghoztty\window_placement-debug'

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

# Piped, not redirected: ghoztty.exe is GUI-subsystem, so PowerShell only waits
# for it when its stdout goes to a pipe.
function Invoke-Cli([string[]]$CliArgs) { ((& $exe @CliArgs 2>&1 | ForEach-Object { "$_" }) -join ' ').Trim() }

function Get-Tops { @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyWindow' | Where-Object Visible) }

function Wait-NewTop([int64[]]$before, [string]$label) {
    for ($i = 0; $i -lt 50; $i++) {
        $new = @(Get-Tops | Where-Object { $before -notcontains $_.Hwnd })
        if ($new.Count -ge 1) { Start-Sleep -Milliseconds 800; return [int64]$new[0].Hwnd }
        Start-Sleep -Milliseconds 200
    }
    Write-Host "SETUP FAIL: $label never opened a window"
    return [int64]0
}

function Open-Window([string[]]$extra, [string]$label) {
    $before = @(Get-Tops | ForEach-Object { $_.Hwnd })
    Write-Host "      +new-window $($extra -join ' '): $(Invoke-Cli (@('+new-window') + $extra))"
    $w = Wait-NewTop $before $label
    if ($w -eq 0) { throw "SETUP FAIL: $label" }
    return $w
}

function Rect([int64]$h) { Get-TestWindowRect -Window ([IntPtr]$h) }
function Size([int64]$h) { $r = Rect $h; "$($r.Width),$($r.Height)" }
function NormalSize([int64]$h) { $r = Get-TestWindowNormalRect -Window ([IntPtr]$h); "$($r.Width),$($r.Height)" }
function Zoomed([int64]$h) { [bool](Test-TestWindowZoomed -Window ([IntPtr]$h)) }

# Launch the app with the memory file seeded to $mem; sets $script:appPid/$script:w1.
function Launch([string]$mem) {
    Kill-RepoInstances
    Set-Content -Path $memFile -Value $mem -Encoding Ascii
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        # -KeepWindowPlacement: the seeded memory file IS the subject here.
        $a = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -KeepWindowPlacement
    } finally { $env:LOCALAPPDATA = $saved }
    $script:appPid = $a.Pid
    $script:launched += $a.Pid
    $script:w1 = [int64](Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow')
    if ($script:w1 -eq 0) { throw 'SETUP FAIL: first window not found' }
    Start-Sleep -Seconds 2
    Assert (-not (Test-TestDesktopLeak -ProcessId $a.Pid)) 'launch: window is NOT enumerable on the interactive desktop'
}

$script:launched = @()
Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # A size no default produces, in this monitor's pixels: the probe launch
    # reads the scale, then the memory is written at that scale (4th token).
    Launch '300 300 0'
    $dpi = [int](Get-TestWindowDpi -Window ([IntPtr]$script:w1))
    $W = [int][math]::Round(950 * $dpi / 96.0, [System.MidpointRounding]::AwayFromZero); $H = [int][math]::Round(640 * $dpi / 96.0, [System.MidpointRounding]::AwayFromZero)
    Kill-RepoInstances

    # ---- A: restored memory --------------------------------------------------
    Launch "$W $H 0 $dpi"
    Assert ((Size $script:w1) -eq "$W,$H") "A: first window opened at the remembered $W,$H (got $(Size $script:w1))"
    $r1 = Rect $script:w1
    $w2 = Open-Window @() 'A bg'
    Assert ((Size $w2) -eq "$W,$H") "A: background window opened at the remembered $W,$H (got $(Size $w2))"
    $r2 = Rect $w2
    Assert ($r2.Left -eq $r1.Left + 30 -and $r2.Top -eq $r1.Top + 30) "A: background window cascaded 30px from the first ($($r1.Left),$($r1.Top) -> $($r2.Left),$($r2.Top))"
    Assert ((Get-TestActiveWindow -Window ([IntPtr]$script:w1)) -ne $w2) 'A: background window did not activate'
    $w3 = Open-Window @('--focus') 'A focus'
    Assert ((Size $w3) -eq "$W,$H") "A: --focus window opened at the same $W,$H (got $(Size $w3))"
    $r3 = Rect $w3
    Assert ($r3.Left -eq $r2.Left + 30 -and $r3.Top -eq $r2.Top + 30) "A: --focus window cascaded the same way ($($r2.Left),$($r2.Top) -> $($r3.Left),$($r3.Top))"

    # ---- B: maximized memory -------------------------------------------------
    Launch "$W $H 1 $dpi"
    Assert (Zoomed $script:w1) 'B: first window opened maximized (the memory works at all)'
    $activeBefore = [int64](Get-TestActiveWindow -Window ([IntPtr]$script:w1))
    $w2 = Open-Window @() 'B bg'
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the background window is NOT maximized - this run MUST fail'
        Assert (-not (Zoomed $w2)) 'B (inverted): background window opened restored'
    } else {
        Assert (Zoomed $w2) 'B: background window opened MAXIMIZED, like a focused one'
    }
    $wa = Get-TestWorkArea
    $rz = Rect $w2
    Assert ($rz.Width -ge $wa.Width -and $rz.Height -ge $wa.Height) "B: ...and covers the work area ($($rz.Width)x$($rz.Height) >= $($wa.Width)x$($wa.Height))"
    $activeAfter = [int64](Get-TestActiveWindow -Window ([IntPtr]$script:w1))
    Assert ($activeAfter -eq $activeBefore -and $activeAfter -ne $w2) "B: maximizing did not activate it (active $activeBefore -> $activeAfter, new=$w2)"
    Assert ((NormalSize $w2) -eq "$W,$H") "B: its restore-down size is the remembered $W,$H (got $(NormalSize $w2))"
    $w3 = Open-Window @('--focus') 'B focus'
    Assert (Zoomed $w3) 'B: --focus window opened maximized too'
    Send-TestSysCommand -Window ([IntPtr]$w2) -Command restore | Out-Null
    $got = ''
    for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 200; $got = Size $w2; if ($got -eq "$W,$H" -and -not (Zoomed $w2)) { break } }
    Assert ((-not (Zoomed $w2)) -and $got -eq "$W,$H") "B: restore takes the background window down to $W,$H (got $got)"
    Assert (-not ((Get-Process -Id $script:appPid -ErrorAction SilentlyContinue) -eq $null)) 'B: no crash'
    Complete-TestBody  # T1039: the last statement of the body
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item -Recurse -Force $fakeLocal -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard background-window-frame -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'T1966 BACKGROUND WINDOW FRAME' -MinPass 19
