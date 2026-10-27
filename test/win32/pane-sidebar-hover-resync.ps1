# T2341 acceptance: the pane sidebar asks its hover again whenever its window
# is activated or deactivated, so a row covered by another window is not left
# lit (Mac 8faf92148, `HoverTrackingView.pointerLocation` + the key-change
# re-sync). Clicking a row that brings another window forward sends the
# column no WM_MOUSELEAVE - the press held the capture - and before T2341 the
# row kept its hover look, and its pane its tint, until the pointer next
# crossed the column.
#
# Layout: window A ("alpha") and window B ("beta"). Activations are real
# WM_ACTIVATEs through the test desktop's input queue (lib\TestDesktop.ps1
# `Set-TestActiveWindow`):
#
#   1. B activated over A: A's column logs `hover resync reason=deactivate`
#      for A's window with hover=none - the pointer is not on A's column
#      (a background desktop has no readable cursor, which reads exactly as
#      "another window is in front there") - and B's logs reason=activate.
#   2. A activated again ("return"): A's column logs reason=activate with
#      hover=none, so no row reads hovered when the window comes back.
#
# The rule itself (off the column -> none; on it -> what is there; a held
# item keeps every hover) is unit-tested in src\apprt\win32\pane_sidebar.zig
# `resyncedHover`. NOT covered here: a real cursor parked over a row while
# another window comes forward - that needs the user's desktop, and the loop
# never takes the user's focus.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl never activates B, so A is never deactivated and the run
# MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-hover-resync.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2341-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2341')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
function Wait-Log([string]$Pattern, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    $hit = $null
    do {
        Start-Sleep -Milliseconds 150
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    } while (-not $hit -and (Get-Date) -lt $deadline)
    return $hit
}
# Activate $top for real; the log line count from just before is left in
# $script:mark.
function Activate($top, [string]$Name) {
    $script:mark = Get-LogCount
    $ok = Set-TestActiveWindow -Window $top
    Start-Sleep -Milliseconds 700
    Assert "setup: $Name is the active window" $ok
}
function ResyncLine($top, [string]$Reason, [int]$Skip) {
    return Wait-Log "pane sidebar hover resync reason=$Reason window=$([int64]$top) " $Skip 3000
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2341'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    Start-Sleep -Seconds 3
    $topA = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($topA -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $topA
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowSize -Window $topA -Width (Px 1100) -Height (Px 800))
    Assert "setup: window A titled alpha ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=alpha") -eq 0)
    Assert "setup: window B opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1 --title=beta") -eq 0)
    Start-Sleep -Milliseconds 1500
    $topB = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { [IntPtr]$_.Hwnd -ne $topA }) | Select-Object -First 1
    Assert "setup: window B found" ($null -ne $topB)
    if ($null -eq $topB) { return }
    $topB = [IntPtr]$topB.Hwnd
    Assert "setup: both windows have a sidebar" (($null -ne (Get-Sidebar $topA)) -and ($null -ne (Get-Sidebar $topB)))
    Activate $topA 'A'

    "== 1: B comes forward over A; A's column drops its hover"
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: B is never activated - this run MUST fail"
        $mark = Get-LogCount
        Start-Sleep -Milliseconds 700
    } else {
        Activate $topB 'B'; $mark = $script:mark
    }
    $deact = ResyncLine $topA 'deactivate' $mark
    Assert "A's column asked its hover again on deactivation (log: $deact)" ($null -ne $deact)
    Assert "and no row of A's is hovered: the pointer is not on A's column" ($deact -match ' hover=none under=false')
    $act = ResyncLine $topB 'activate' $mark
    Assert "B's column asked its hover again on activation (log: $act)" ($null -ne $act)

    "== 2: back to A; no row reads hovered"
    Activate $topA 'A'; $mark = $script:mark
    $back = ResyncLine $topA 'activate' $mark
    Assert "A's column asked its hover again on activation (log: $back)" ($null -ne $back)
    Assert "and no row is hovered when A comes back" ($back -match ' hover=none under=false')

    Assert "no crash" (-not ($app.Process -and $app.Process.HasExited))
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    Assert "no test-desktop app ever became foreground on the interactive desktop" (-not ($fgSeen -contains $app.Pid))
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-hover-resync -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2341' -Path $transcript `
        -Label 'T2341 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
