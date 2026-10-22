# T1199 acceptance: scripts\dashboard-keepalive.vbs, the windowless launcher
# the GhozttyTaskDashboard keep-alive task runs every 5 minutes, starts the
# dashboard of the checkout it lives in - not one clone's path committed in it.
#
#   A. Static: no drive-letter path outside a comment in the launcher, and
#      task-dashboard.ps1 still registers the launcher from its own
#      $PSScriptRoot (the caller T1199 names, kept in step).
#   B. Behaviour: the launcher copied into a temp checkout, beside a stub
#      task-dashboard.ps1 that records where it ran and with what arguments,
#      runs THAT stub when wscript starts it - not the real repo's, and not a
#      second fixture's.
#   C. Teeth, every run: the pre-T1199 shape (a hardcoded path, here aimed at
#      a second fixture) is caught by A's check AND starts the wrong
#      checkout's stub in B's experiment.
#
#   -NegativeControl adds one inverted assertion a healthy tree MUST fail, so
#   the run ends with exactly one failure.
#
# Non-interactive. wscript.exe is GUI-subsystem with no window, and the
# launcher starts its powershell with window style 0, so nothing appears or
# takes focus. Only the stubs run; no dashboard server is started.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$launcher = Join-Path $repo 'scripts\dashboard-keepalive.vbs'
$caller = Join-Path $repo 'scripts\task-dashboard.ps1'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:fail = 0
$script:pass = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" }
}

# Every non-comment line holding a quoted drive path ("X:\...). VBScript's
# comment marker is a leading apostrophe (or Rem).
function Get-HardcodedPaths([string]$text) {
    return @($text -split "`r?`n" | Where-Object {
        $_ -notmatch '^\s*(''|Rem\b)' -and $_ -match '"[A-Za-z]:\\'
    })
}

function New-Fixture([string]$root, [string]$vbsText) {
    $scripts = Join-Path $root 'scripts'
    New-Item -ItemType Directory -Force $scripts | Out-Null
    [IO.File]::WriteAllText((Join-Path $scripts 'dashboard-keepalive.vbs'), $vbsText)
    # The stub records its own folder and argv, which is all the launcher decides.
    $stub = '"$PSScriptRoot|$($args -join '' '')" | Set-Content -Encoding ascii (Join-Path $PSScriptRoot ''ran.txt'')'
    [IO.File]::WriteAllText((Join-Path $scripts 'task-dashboard.ps1'), $stub)
    return $scripts
}

# Start the fixture's launcher the way the scheduled task does and wait for
# whichever stub it ran. Returns the folder of the stub that ran, or $null.
function Invoke-Launcher([string]$scripts, [string[]]$watch) {
    $p = Start-Process wscript.exe -ArgumentList @('//B', '//Nologo', "`"$(Join-Path $scripts 'dashboard-keepalive.vbs')`"") -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        foreach ($w in $watch) {
            $f = Join-Path $w 'ran.txt'
            if (Test-Path $f) { return [pscustomobject]@{ Dir = $w; Line = (Get-Content -Raw $f).Trim() } }
        }
        Start-Sleep -Milliseconds 200
    }
    if ($p -and -not $p.HasExited) { $p | Stop-Process -Force -ErrorAction SilentlyContinue }
    return $null
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("t1199-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
Write-Host '--- A. static ---'
$text = Get-Content -Raw $launcher
$hard = @(Get-HardcodedPaths $text)
Assert ($hard.Count -eq 0) "the launcher commits no drive path ($(@($hard) -join ' / '))"
Assert ($text -match 'WScript\.ScriptFullName') 'the launcher locates itself from WScript.ScriptFullName'
$callerText = Get-Content -Raw $caller
Assert ($callerText -match [regex]::Escape('$PSScriptRoot\dashboard-keepalive.vbs')) 'task-dashboard.ps1 registers the launcher from its own $PSScriptRoot'

Write-Host '--- B. behaviour ---'
$a = New-Fixture (Join-Path $work 'clone-a') $text
$b = New-Fixture (Join-Path $work 'clone-b') $text
$ran = Invoke-Launcher $a @($a, $b)
Assert ($null -ne $ran) 'the launcher ran a task-dashboard.ps1 within 30s'
Assert ($ran -and $ran.Dir -eq $a) "it ran the stub in its OWN checkout (ran: $(if ($ran) { $ran.Dir } else { 'none' }))"
Assert ($ran -and $ran.Line -match '\|-Port 7788 -NoPane$') "with -Port 7788 -NoPane ($(if ($ran) { $ran.Line }))"
Assert (-not (Test-Path (Join-Path $b 'ran.txt'))) 'the other checkout''s stub did not run'

Write-Host '--- C. teeth: the pre-T1199 shape ---'
$mutant = $text -replace 'here = fso\.GetParentFolderName\(WScript\.ScriptFullName\)', "here = `"$b`""
Assert ($mutant -ne $text) 'the mutation applied (the self-locating line is where the check expects it)'
Assert (@(Get-HardcodedPaths $mutant).Count -gt 0) 'A''s check catches a hardcoded path'
$m = New-Fixture (Join-Path $work 'clone-m') $mutant
$ranM = Invoke-Launcher $m @($m, $b)
Assert ($ranM -and $ranM.Dir -eq $b) "a hardcoded launcher starts the WRONG checkout (ran: $(if ($ranM) { $ranM.Dir } else { 'none' }))"
Assert ($ranM -and $ranM.Dir -ne $m) 'so B''s own-checkout assertion would have gone red on it'

if ($NegativeControl) {
    Assert (@(Get-HardcodedPaths $text).Count -gt 0) 'NEGATIVE CONTROL: the healthy launcher must not be flagged (this must FAIL)'
}

Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    # Only this run's own fixture folder, under %TEMP%.
    if ($work -and (Test-Path $work)) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard dashboard-keepalive -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'DASHBOARD-KEEPALIVE' -MinPass 11
