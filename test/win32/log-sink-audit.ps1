# T1679 meta-check: no acceptance script spells the app's log sink by name.
#
# THE DEFECT THIS CLOSES. The Windows app's log sink is named by build mode
# (src\os\log_rotate.zig `live_name`): a Debug build appends to
# %LOCALAPPDATA%\ghoztty\ghoztty-debug.log (T1508), every other mode to
# ghoztty.log. A Debug build is the only thing an acceptance script may
# launch, so a harness that spells `ghoztty.log` reads a file nobody writes -
# an empty string - and every `-notmatch` over it passes for free. T901's first
# draft of a section did exactly that and scored green on nothing. soak.ps1 and
# profile-latency.ps1 did the same whenever they were pointed at a Debug build.
#
# THE RULE (test\win32\lib\LogSinkAudit.ps1): get the sink from
# `Get-GhozttyAppLogPath -Exe $exe` (BuildMode.ps1), or declare once in the file
#     # @log-sink-literal - <why the literal name is right here>
#
# Sections:
#
#   A  the scanner bites on a planted read, and stays quiet on comments and on
#      a declared literal; a marker without a reason does not count
#   B  end to end: a copy of a real harness with its derived path swapped for
#      the literal is a finding in a scratch tree, and the original is not
#   C  the live suite is clean
#   D  the check is wired into the harness floor, which is what runs it
#
# Static: no app, no CLI, no zig build - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\log-sink-audit.ps1
#   powershell -NoProfile -File test\win32\log-sink-audit.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it reads files and
# writes fixtures under temp\.
#
# @log-sink-literal - section A and B plant the literal as the scanner's fixtures
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer, and the dot-source is also what ARMS the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\LogSinkAudit.ps1')
. (Join-Path $Repo 'scripts\lib\HardDelete.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

$fixtureDir = Join-Path $Repo ("temp\log-sink-audit-{0}" -f $PID)

try {
    # -----------------------------------------------------------------------
    "== A: the scanner bites, and only on code"
    # -----------------------------------------------------------------------
    # The T901 shape: read the sink, assert something is NOT in it.
    $planted = "`$log = Join-Path `$env:LOCALAPPDATA 'ghoztty\ghoztty.log'`r`nAssert 'no crash line' ((Get-Content `$log -Raw) -notmatch 'panic')"
    $hits = @(Find-LogSinkLiteralLines -Text $planted)
    Assert 'A1 a planted ghoztty.log read is a finding' ($hits.Count -eq 1) "(got $($hits.Count))"
    Assert 'A2 ...at the line that spells it' ($hits.Count -ge 1 -and $hits[0] -eq 1) "(got $($hits -join ','))"
    $escaped = "if (`$t -match 'ghoztty\.log') { }"
    Assert 'A3 a regex-escaped spelling is a finding too' (@(Find-LogSinkLiteralLines -Text $escaped).Count -eq 1)
    $comments = "# reads ghoztty.log`r`n    # also ghoztty.log`r`n<#`r`n ghoztty.log`r`n#>`r`n`$x = 1"
    Assert 'A4 comment lines and comment blocks are not code' (@(Find-LogSinkLiteralLines -Text $comments).Count -eq 0)
    Assert 'A5 the Debug sink name is not the release literal' (
        @(Find-LogSinkLiteralLines -Text "`$p = 'ghoztty\ghoztty-debug.log'").Count -eq 0)
    Assert 'A6 a declared literal is excused' (
        Test-LogSinkLiteralDeclared -Text ("# @log-sink-literal - release-only arm`r`n" + $planted))
    Assert 'A7 a marker with no reason is not' (
        -not (Test-LogSinkLiteralDeclared -Text ("# @log-sink-literal`r`n" + $planted)))
    Assert 'A8 a marker that is not a comment line is not' (
        -not (Test-LogSinkLiteralDeclared -Text ("`$m = '@log-sink-literal - x'`r`n" + $planted)))

    # -----------------------------------------------------------------------
    ""
    "== B: end to end over a scratch tree built from a real harness"
    # -----------------------------------------------------------------------
    # soak.ps1 is the script this task fixed; put its old line back in a copy
    # and the tree-wide sweep must name that copy - and only that copy.
    $src = Join-Path $PSScriptRoot 'soak.ps1'
    $text = [System.IO.File]::ReadAllText($src)
    Assert 'B0 premise: soak.ps1 derives its sink' ($text -match 'Get-GhozttyAppLogPath -Exe \$exe')
    $scratchWin = Join-Path $fixtureDir 'test\win32'
    New-Item -ItemType Directory -Force -Path $scratchWin | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $scratchWin 'derived.ps1'), $text)
    $regressed = $text -replace 'Get-GhozttyAppLogPath -Exe \$exe', 'Join-Path $env:LOCALAPPDATA ''ghoztty\ghoztty.log'''
    [System.IO.File]::WriteAllText((Join-Path $scratchWin 'regressed.ps1'), $regressed)
    $found = @(Get-LogSinkAuditFindings -Root $fixtureDir)
    $paths = @($found | ForEach-Object { Split-Path -Leaf $_.Path })
    Assert 'B1 the regressed copy is a finding' ($paths -contains 'regressed.ps1') "(got: $($paths -join ', '))"
    Assert 'B2 the original is not' ($paths -notcontains 'derived.ps1') "(got: $($paths -join ', '))"

    # -----------------------------------------------------------------------
    ""
    "== C: the live suite is clean"
    # -----------------------------------------------------------------------
    $scanned = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'test\win32') -Recurse -Filter '*.ps1' -File).Count
    Assert 'C0 premise: the sweep has a suite to read' ($scanned -gt 100) "(scanned $scanned)"
    $live = @(Get-LogSinkAuditFindings -Root $Repo)
    foreach ($f in $live) { "    spells the sink without declaring why: $($f.Path) line(s) $(@($f.Lines) -join ',')" }
    Assert "C1 no test\win32 script spells the log sink without declaring why ($scanned scanned)" ($live.Count -eq 0) "($($live.Count) found)"

    # -----------------------------------------------------------------------
    ""
    "== D: the check is wired into the floor that runs it"
    # -----------------------------------------------------------------------
    . (Join-Path $Repo 'scripts\lib\HarnessFloor.ps1')
    $names = @(Get-HarnessFloorAudits | ForEach-Object { [string]$_.Name })
    Assert 'D1 log-sink-audit.ps1 is a member of the harness floor' `
        ($names -contains 'log-sink-audit.ps1') "(set: $($names.Count) rows)"
    Assert 'D2 it is not listed as a pending exception' `
        (-not (Get-HarnessFloorPending).ContainsKey('log-sink-audit.ps1'))

    # -----------------------------------------------------------------------
    # Negative control: the sweep over the scratch tree must find the
    # regressed copy; assert - INVERTED - that it does not. A working sweep
    # fails this, so a healthy repo scores exactly 1 FAILURE here.
    # -----------------------------------------------------------------------
    if ($NegativeControl) {
        ""
        "NEGATIVE CONTROL: asserting the regressed copy goes unreported - a working sweep MUST fail this"
        Assert 'N1 the regressed copy goes unreported (inverted)' ($paths -notcontains 'regressed.ps1') "(1 finding is the healthy answer)"
    }
}
catch {
    # T1511: score the throw rather than unwinding past it to a green verdict.
    Assert 'the run finished its sections' $false "(threw: $($_.Exception.Message))"
    $_.ScriptStackTrace
}
finally {
    if (Test-Path -LiteralPath $fixtureDir) { [void](Remove-TreeHard -Path $fixtureDir) }
}

Complete-TestBody

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
