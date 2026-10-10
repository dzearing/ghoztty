<#
.SYNOPSIS
  Acceptance test for scripts\lib\LaneDesktop.ps1 and floor-lane.ps1's
  lane-desktop launch and input-desktop window check (T1813).

.DESCRIPTION
  Measured 2026-10-10 with a fullscreen game in front: one win32 test lane put
  12 visible test windows on the user's screen. The fix runs every lane on a
  background desktop its whole process tree inherits, and checks the input
  desktop for windows the lane's tree owns, turning any into a red lane.

  Nothing in this file puts a window on the user's screen. The planted window
  in sections B and C lives on a desktop of its own, and the check is pointed
  at that desktop - the same code path, aimed somewhere harmless.

  Sections:
    A  a lane runs on the lane desktop, and so does a child it starts
    B  the window check finds a planted window, and only on its desktop
    C  floor-lane scores a lane that shows a window as FAIL and names it
       (teeth), and the same lane with no window as PASS (control)

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.
  ASCII-only by design.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $RepoRoot 'scripts\lib\LaneDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

$floor = Join-Path $RepoRoot 'scripts\floor-lane.ps1'
$Sandbox = Join-Path $env:TEMP ("floor-lane-desktop-test-{0}" -f $PID)
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null
$libPath = Join-Path $RepoRoot 'scripts\lib\LaneDesktop.ps1'
$probeDesk = "GhozttyLaneProbe-$PID"
$planted = @()

# Prints the desktop it runs on, and (with -Nested) that of a child it starts
# the ordinary way - Start-Process, no lpDesktop - which is how zig and the
# build runner start the test binaries.
$where = Join-Path $Sandbox 'where.ps1'
Set-Content -LiteralPath $where -Encoding ASCII -Value @(
    'param([switch]$Nested)',
    (". '" + $libPath + "'"),
    '"DESKTOP=" + [GhozttyLaneDesktop]::CurrentDesktopName()',
    'if ($Nested) {',
    '  $o = Join-Path (Split-Path -Parent $PSCommandPath) "nested.txt"',
    '  Start-Process -FilePath cmd.exe -ArgumentList ("/c powershell -NoProfile -File `"" + $PSCommandPath + "`" > `"" + $o + "`" 2>&1") -WindowStyle Hidden -Wait',
    '  "NESTED " + (Get-Content $o)',
    '}')

# Shows a window and keeps it up for $Seconds. Run only on a desktop that is
# not the user's.
$show = Join-Path $Sandbox 'show.ps1'
Set-Content -LiteralPath $show -Encoding ASCII -Value @(
    'param([int]$Seconds = 6)',
    'Add-Type -AssemblyName System.Windows.Forms',
    '$f = New-Object System.Windows.Forms.Form',
    '$f.Text = "T1813 planted window"; $f.ShowInTaskbar = $false',
    '$f.Show()',
    '$end = (Get-Date).AddSeconds($Seconds)',
    'while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }',
    '$f.Close()')

# The control for C: the same lane shape with no window.
$sleep = Join-Path $Sandbox 'sleep.ps1'
Set-Content -LiteralPath $sleep -Encoding ASCII -Value 'Start-Sleep -Seconds 4'

function Invoke-Floor {
    param([string]$Command, [hashtable]$Env = @{})
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $floor -Lane none -Command $Command `
            -SampleSeconds 1 -NoSweep -NoCatch -NoSoloConfirm -MinFreeGB 0 -MinCommitFreeGB 0 2>&1 |
            ForEach-Object { $_.ToString() }
        $code = $LASTEXITCODE
    }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $text = $out -join "`n"
    $log = ''
    if ($text -match 'log: (\S+\.log)') { $log = $Matches[1] }
    return [pscustomobject]@{ Code = $code; Text = $text; Log = $log }
}

try {
    Write-Host 'A. a lane runs on the lane desktop, and so does its child'
    $self = [GhozttyLaneDesktop]::CurrentDesktopName()
    Check 'A0 control: this harness itself is on another desktop' ($self -ne 'GhozttyLaneDesktop') $self
    $a = Invoke-Floor -Command ('powershell -NoProfile -File "' + $where + '" -Nested')
    $logText = if ($a.Log -and (Test-Path $a.Log)) { (Get-Content $a.Log) -join "`n" } else { '' }
    Check 'A1 the lane passed' ($a.Code -eq 0) $a.Text
    Check 'A2 the lane root ran on GhozttyLaneDesktop' ($logText -match '(?m)^DESKTOP=GhozttyLaneDesktop$') $logText
    Check 'A3 a child started the ordinary way inherited it' ($logText -match 'NESTED DESKTOP=GhozttyLaneDesktop') $logText
    Check 'A4 the verdict line names the desktop' ($a.Text -match 'LANE command PASS .*desktop: GhozttyLaneDesktop') $a.Text

    Write-Host 'B. the window check finds a planted window, and only on its desktop'
    $p = Start-LaneProcess -DesktopName $probeDesk -CommandLine ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $show + '" -Seconds 20')
    $planted += $p
    Check 'B0 the planting process landed on the probe desktop' ($p.LaneDesktop -eq $probeDesk)
    $hit = $null
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $hit = Get-LaneInputDesktopWindow -ProcessId @($p.Id) -DesktopName $probeDesk
        if ($hit.Looked -and $hit.Windows.Count -gt 0) { break }
        Start-Sleep -Milliseconds 250
    }
    Check 'B1 the check looked at the probe desktop' ($hit.Looked) $hit.Error
    Check 'B2 and found the planted window, by pid and class' `
        ($hit.Windows.Count -ge 1 -and ($hit.Windows -join ' ') -match ("pid=" + $p.Id + " class=WindowsForms")) ($hit.Windows -join ' | ')
    $inp = Get-LaneInputDesktopWindow -ProcessId @($p.Id)
    Check 'B3 the same pid shows nothing on the input desktop' ($inp.Looked -and $inp.Windows.Count -eq 0) ($inp.Windows -join ' | ')
    $none = Get-LaneInputDesktopWindow -ProcessId @() -DesktopName $probeDesk
    Check 'B4 an empty pid list is an honest empty answer, not a blind one' ($none.Looked -and $none.Windows.Count -eq 0)
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue

    Write-Host 'C. floor-lane scores a window on the watched desktop as a red lane'
    # The check is pointed at the LANE desktop, where this command's window
    # lands - the stand-in for "a test window reached the user's screen".
    $c = Invoke-Floor -Command ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $show + '" -Seconds 6') `
        -Env @{ GHOZTTY_FLOOR_LANE_WINDOW_DESKTOP = 'GhozttyLaneDesktop' }
    Check 'C1 teeth: a lane whose tree showed a window is FAIL' ($c.Text -match 'LANE command FAIL' -and $c.Code -eq 1) $c.Text
    Check 'C2 and it says why, naming the window' `
        ($c.Text -match "SHOWED \d+ WINDOW\(S\) ON THE USER'S DESKTOP" -and $c.Text -match 'input-desktop window: hwnd=0x[0-9A-F]+ pid=\d+ class=WindowsForms') $c.Text
    $d = Invoke-Floor -Command ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $sleep + '"') `
        -Env @{ GHOZTTY_FLOOR_LANE_WINDOW_DESKTOP = 'GhozttyLaneDesktop' }
    Check 'C3 control: the same watch over a lane with no window is PASS' ($d.Code -eq 0 -and $d.Text -match 'LANE command PASS' -and $d.Text -notmatch 'SHOWED') $d.Text
    $e = Invoke-Floor -Command ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $show + '" -Seconds 6')
    Check 'C4 and the real configuration (input desktop watched) keeps the lane window off it: PASS' `
        ($e.Code -eq 0 -and $e.Text -notmatch 'SHOWED') $e.Text

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    foreach ($p in $planted) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} }
    if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard lane-desktop -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
