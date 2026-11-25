<#
.SYNOPSIS
  Run acceptance scripts one at a time and fail if a repo ghoztty window ever
  reaches the INTERACTIVE desktop while they run (T2203).

.DESCRIPTION
  The static sweep (test\win32\desktop-launch-audit.ps1) reads source and cannot
  see a launch spelled some other way. This asks the box: while each script
  runs, it polls for a visible top-level window owned by a ghoztty* process
  whose image lives under this worktree, on the desktop this runner sits on.
  The mechanism is test\win32\lib\DesktopEscape.ps1.

  OPT-IN ONLY. It is never part of the per-turn floor or a sweep: a script that
  escapes is caught BY escaping, onto the desktop of a user who is usually at
  the machine. So it refuses, without running, every script the static sweeps
  say reaches that desktop:

    REFUSED declared-input-desktop   @input-desktop-exception in lib\TestDesktop.ps1
    REFUSED declared-user-desktop    @user-desktop-launch in lib\TestDesktop.ps1
    REFUSED static-launch-site       an undeclared launch the static audit sees

  and what is left is exactly the residue a static reading cannot judge.

  Per script it prints CLEAN, ESCAPED (with every window it saw: pid, class,
  title, image, seconds into the run) or TIMEOUT, then one summary line:

    DESKTOP ESCAPE: <n> escaped of <m> run (<r> refused)

  -Scripts   comma-separated, relative to the repo or to test\win32. Required
             unless -All.
  -All       every top-level test\win32\*.ps1 (still minus the refusals).
  -List      print each script's eligibility and exit 0 without running any.
  -TimeoutSeconds  per script (default 1800).

  Exit 0 = nothing escaped. 1 = at least one script escaped. 2 = usage.
  A TIMEOUT is reported but is not an escape.

.NOTES
  # desktop-launch-audit: launches no app itself; the scripts it runs are the
  # ones the static audit already passes.
#>
[CmdletBinding()]
param(
    [string[]]$Scripts,
    [switch]$All,
    [switch]$List,
    [int]$TimeoutSeconds = 1800,
    [string]$Suite,
    [string[]]$Roots
)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
if (-not $Suite) { $Suite = Join-Path $Repo 'test\win32' }
if (-not $Roots) { $Roots = @($Repo) }

. (Join-Path $Repo 'test\win32\lib\DesktopLaunchAudit.ps1')
. (Join-Path $Repo 'test\win32\lib\DesktopEscape.ps1')

function Resolve-EscapeScript([string]$s) {
    foreach ($cand in @($s, (Join-Path $Repo $s), (Join-Path $Suite $s))) {
        if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) { return (Resolve-Path -LiteralPath $cand).Path }
    }
    return $null
}

$targets = @()
if ($All) {
    $targets = @(Get-ChildItem -LiteralPath $Suite -Filter *.ps1 -File | Sort-Object Name | ForEach-Object { $_.FullName })
} elseif ($Scripts) {
    foreach ($s in @($Scripts | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() })) {
        $r = Resolve-EscapeScript $s.Trim()
        if (-not $r) { Write-Host "desktop-escape-run: no such script '$s'"; exit 2 }
        $targets += $r
    }
} else {
    Write-Host 'usage: desktop-escape-run.ps1 -Scripts a.ps1,b.ps1 | -All  [-List] [-TimeoutSeconds N]'
    exit 2
}

$declared = Get-DesktopEscapeDeclaredSets -Suite $Suite
$run = @(); $refused = 0
foreach ($t in $targets) {
    $el = Get-DesktopEscapeEligibility -Path $t -Suite $Suite -Declared $declared
    if (-not $el.Eligible) {
        Write-Host ("REFUSED  {0}  ({1}) - not run: it would reach the user's desktop by design" -f (Split-Path $t -Leaf), $el.Reason)
        $refused++
        continue
    }
    if ($List) { Write-Host ("ELIGIBLE {0}" -f (Split-Path $t -Leaf)) }
    $run += $t
}
if ($List) { Write-Host ("DESKTOP ESCAPE LIST: {0} eligible, {1} refused" -f $run.Count, $refused); exit 0 }

$escaped = 0
$logDir = Join-Path $env:TEMP ("desktop-escape-{0}" -f $PID)
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
foreach ($t in $run) {
    $log = Join-Path $logDir ((Split-Path $t -Leaf) + '.log')
    $res = Invoke-DesktopEscapeRun -Script $t -Roots $Roots -LogPath $log -TimeoutSeconds $TimeoutSeconds
    foreach ($l in @(Format-DesktopEscapeResult -Result $res)) { Write-Host $l }
    if ($res.Verdict -eq 'ESCAPED') { $escaped++ }
}
Write-Host ("DESKTOP ESCAPE: {0} escaped of {1} run ({2} refused)" -f $escaped, $run.Count, $refused)
if ($escaped -gt 0) { exit 1 }
exit 0
