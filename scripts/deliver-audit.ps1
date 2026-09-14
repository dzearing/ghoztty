# The unattended reader for `deliver-windows-build.ps1 -VerifyOnly` (T727).
#
# The audit itself is a flag on the delivery script, and a flag nobody invokes
# is not an improvement over 2026-08-10, when both portable install locations
# held a DEBUG ghoztty.exe beside a release ghoztty.com for seventeen hours and
# the only way to notice was to read file sizes by hand. So the audit needs a
# caller that runs without anyone asking, and a verdict that survives the run:
#
#   * `go-loop-exec.ps1 claim` calls this once per turn. It is a no-op after the
#     first run of the day, costs a couple of seconds when it is not, and can
#     never fail the claim - a sleeping NAS is a SKIP, exactly as it is for the
#     delivery path.
#   * `go-loop-health.ps1` reads the watermark this writes and reports
#     `deliver=` beside `digest=` and `publish=`, so the state is on the
#     dashboard without anybody running anything.
#
# The watermark is the same shape as the daily publish's, for the same reason:
# one JSON object, local date, and a result a reader can act on without knowing
# how the audit works.
#
#   powershell -NoProfile -File scripts\deliver-audit.ps1 [-Force] [-Strict]
[CmdletBinding(PositionalBinding = $false)]
param(
    # Empty: $PSScriptRoot is not reliably bound inside a param default.
    [string]$Repo = '',
    # Where the verdict is kept, so a reader that never runs the audit can still
    # report it. Same directory as the daily publish's watermark.
    [string]$Watermark = (Join-Path $env:LOCALAPPDATA 'ghoztty\deliver-audit.json'),
    # Run even though today's audit has already happened.
    [switch]$Force,
    # Exit 1 when the audit found a wrong location. Off by default: the claim
    # calls this, and a stale portable copy must not be able to stop the loop.
    [switch]$Strict,
    # Pass through to the audit: ask the stricter question (a commit, or HEAD).
    [string]$ExpectedCommit = '',
    # Pass through to the audit. Empty means "the delivery script's own
    # defaults", which is what the loop wants; the acceptance harness passes a
    # sandbox so it never reads a real install location.
    [string[]]$Targets = @(),
    [string]$LooseAgentDir = '',
    [string]$ZipPath = '',
    [switch]$NoZip,
    # Seconds before the audit is abandoned. A NAS that has gone to sleep can
    # hold a directory probe for a long time, and this runs inside the claim.
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path $PSScriptRoot -Parent }
if (-not $Watermark) { $Watermark = Join-Path $env:LOCALAPPDATA 'ghoztty\deliver-audit.json' }

$today = (Get-Date).ToString('yyyy-MM-dd')

function Read-Watermark {
    if (-not (Test-Path -LiteralPath $Watermark)) { return $null }
    try { return (Get-Content -LiteralPath $Watermark -Raw) | ConvertFrom-Json } catch { return $null }
}

function Write-Watermark($Result, $Problems, $Expect, $Summary) {
    $dir = Split-Path $Watermark -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $obj = [ordered]@{
        date     = $today
        at       = (Get-Date).ToString('o')
        result   = $Result
        problems = [int]$Problems
        expect   = [string]$Expect
        summary  = [string]$Summary
    }
    try { Set-Content -LiteralPath $Watermark -Value ($obj | ConvertTo-Json -Depth 3) -Encoding UTF8 } catch {
        Write-Host "  note: the audit verdict could not be recorded ($($_.Exception.Message))"
    }
}

$wm = Read-Watermark
if (-not $Force -and $wm -and [string]$wm.date -eq $today) {
    $n = [int]$wm.problems
    $what = if ([string]$wm.result -eq 'ok') { "ok +$($wm.expect)" } else { "$($wm.result) ($n problem(s))" }
    Write-Host "DELIVER AUDIT $what (already run today)"
    exit 0
}

$deliver = Join-Path $PSScriptRoot 'deliver-windows-build.ps1'
if (-not (Test-Path -LiteralPath $deliver -PathType Leaf)) {
    Write-Host "DELIVER AUDIT skipped: $deliver is not there"
    exit 0
}

# `-Command`, not `-File`: the audit takes a string ARRAY (-Targets), and
# `-File` has no array syntax at all - every argument after it is a bare string,
# so a two-location audit would arrive as one location named "a,b". An empty
# string is the other half of the same problem: `-LooseAgentDir ''` under -File
# disappears and binds the next flag to it.
function Lit([string]$s) { "'" + ($s -replace "'", "''") + "'" }
$cmd = "& $(Lit $deliver) -VerifyOnly"
if ($ExpectedCommit) { $cmd += " -ExpectedCommit $(Lit $ExpectedCommit)" }
if ($Targets.Count) { $cmd += " -Targets @($(@($Targets | ForEach-Object { Lit $_ }) -join ','))" }
if ($PSBoundParameters.ContainsKey('LooseAgentDir')) { $cmd += " -LooseAgentDir $(Lit $LooseAgentDir)" }
if ($PSBoundParameters.ContainsKey('ZipPath')) { $cmd += " -ZipPath $(Lit $ZipPath)" }
if ($NoZip) { $cmd += ' -NoZip' }
$cmd += '; exit $LASTEXITCODE'
$quoted = "-NoProfile -ExecutionPolicy Bypass -Command `"$($cmd -replace '"', '\"')`""

# Out-of-process with a deadline: a probe into a sleeping share is the one thing
# here that can take minutes, and this runs inside the turn's claim.
$out = Join-Path $env:TEMP "ghoztty-deliver-audit-$PID.txt"
$p = Start-Process -FilePath 'powershell' -ArgumentList $quoted -NoNewWindow -PassThru `
    -RedirectStandardOutput $out -RedirectStandardError "$out.err"
# T1247's trap: cache the handle before the child can exit, or ExitCode is empty.
$null = $p.Handle
if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    try { $p.Kill() } catch { }
    Write-Host "DELIVER AUDIT skipped: the audit did not finish within ${TimeoutSeconds}s (a sleeping share?)"
    Write-Watermark 'skipped' 0 '' "timed out after ${TimeoutSeconds}s"
    exit 0
}
$code = $p.ExitCode
$text = ''
foreach ($f in @($out, "$out.err")) {
    if (Test-Path -LiteralPath $f) {
        $text += ((Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) + "`n")
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
}
$lines = @($text -split "`r?`n" | Where-Object { $_ -match '\S' })
$verdictLine = @($lines | Where-Object { $_ -like 'AUDIT *' })[-1]
if (-not $verdictLine) { $verdictLine = 'AUDIT UNKNOWN: the audit printed no verdict' }

$expect = ''
if ($verdictLine -match '\+([0-9a-f]{7,40})') { $expect = $Matches[1] }
$problems = 0
if ($verdictLine -match '(\d+) problem') { $problems = [int]$Matches[1] }

$result = switch ($code) {
    0 { if ($verdictLine -like 'AUDIT SKIPPED*') { 'skipped' } else { 'ok' } }
    1 { 'wrong' }
    default { 'skipped' }
}
Write-Watermark $result $problems $expect $verdictLine

Write-Host "DELIVER AUDIT $result : $verdictLine"
if ($result -eq 'wrong') {
    # The names, not just the count: this line is read in a claim report, and
    # "7 problem(s)" with no subject is a number nobody can act on.
    foreach ($l in @($lines | Where-Object { $_ -match '^\s+- ' } | Select-Object -First 6)) { Write-Host "  $($l.Trim())" }
    Write-Host '  see it in full: powershell -NoProfile -File scripts\deliver-windows-build.ps1 -VerifyOnly'
    if ($Strict) { exit 1 }
}
exit 0
