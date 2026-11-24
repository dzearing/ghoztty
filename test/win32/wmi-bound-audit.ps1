# T2024 meta-check: the shared acceptance libraries never call WMI unbounded.
#
# THE DEFECT THIS CLOSES. On 2026-10-16 the CIMWin32 provider host stalled for
# 24 minutes. Every acceptance script running at the time sat inside its own
# `Get-CimInstance Win32_Process`, which has no timeout unless it is given one:
# finished scripts were scored in clumps 50-90 s late, and a process-count
# assertion wrote its last line two seconds after the replacement host came up.
# A lookup that answers late, or empty, reads as a product failure.
#
# THE RULE (test\win32\lib\ProcessTable.ps1): a process lookup reads the kernel
# through `Get-OsProcess`; a query that needs a field only WMI has is bounded
# (`Get-BoundedCimProcess`, or `-OperationTimeoutSec` on the call) and throws
# 'WMI did not answer' instead of returning an empty list.
#
# Sections:
#
#   A  the scanner bites on planted unbounded calls, and stays quiet on bounded
#      ones, comments and strings
#   B  end to end: a copy of a converted lib with its old WMI line put back is a
#      finding in a scratch tree, and the original is not
#   C  the live libraries are clean (the GATE), and the per-script count is
#      reported against the follow-up task that converts them
#   D  the kernel table answers, agrees with WMI on this process, and the bounded
#      query names a timeout instead of returning nothing
#   E  the check is wired into the harness floor, which is what runs it
#
# Static apart from D, which reads this box's own process table: no app, no CLI,
# no zig build - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\wmi-bound-audit.ps1
#   powershell -NoProfile -File test\win32\wmi-bound-audit.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it reads files and
# writes fixtures under temp\.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer, and the dot-source is also what ARMS the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\WmiBoundAudit.ps1')
. (Join-Path $PSScriptRoot 'lib\ProcessTable.ps1')
. (Join-Path $Repo 'scripts\lib\HardDelete.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

$fixtureDir = Join-Path $Repo ("temp\wmi-bound-audit-{0}" -f $PID)

try {
    # -----------------------------------------------------------------------
    "== A: the scanner bites, and only on unbounded calls"
    # -----------------------------------------------------------------------
    $planted = "`$all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue`r`n`$x = 1"
    $hits = @(Find-UnboundedWmiCalls -Text $planted)
    Assert 'A1 a planted unbounded Get-CimInstance is a finding' ($hits.Count -eq 1) "(got $($hits.Count))"
    Assert 'A2 ...at the line that calls it' ($hits.Count -ge 1 -and $hits[0].Line -eq 1) "(got $($hits | ForEach-Object Line))"
    Assert 'A3 Get-WmiObject is always a finding (it cannot be bounded)' (
        @(Find-UnboundedWmiCalls -Text "Get-WmiObject Win32_Process -OperationTimeoutSec 5").Count -eq 1)
    Assert 'A4 the gcim alias is a finding' (@(Find-UnboundedWmiCalls -Text "gcim Win32_Process").Count -eq 1)
    Assert 'A5 a call inside a pipeline in a function is a finding' (
        @(Find-UnboundedWmiCalls -Text "function f { @(Get-CimInstance Win32_Process | Where-Object { `$_.Name }) }").Count -eq 1)
    Assert 'A6 -OperationTimeoutSec bounds it' (
        @(Find-UnboundedWmiCalls -Text "Get-CimInstance Win32_Process -OperationTimeoutSec 20").Count -eq 0)
    Assert 'A7 ...and so does an unambiguous abbreviation of it' (
        @(Find-UnboundedWmiCalls -Text "Get-CimInstance Win32_Process -Operation 20").Count -eq 0)
    Assert 'A8 a splat whose literal carries the key bounds it' (
        @(Find-UnboundedWmiCalls -Text "`$cim = @{ ClassName = 'Win32_Process'; OperationTimeoutSec = 5 }`r`nGet-CimInstance @cim").Count -eq 0)
    Assert 'A9 a splat whose literal does not carry it is a finding' (
        @(Find-UnboundedWmiCalls -Text "`$cim = @{ ClassName = 'Win32_Process' }`r`nGet-CimInstance @cim").Count -eq 1)
    $comments = "# Get-CimInstance Win32_Process`r`n<#`r`n Get-CimInstance Win32_Process`r`n#>`r`n`$re = 'Get-CimInstance\s+Win32_Process'"
    Assert 'A10 comments, comment blocks and strings are not calls' (@(Find-UnboundedWmiCalls -Text $comments).Count -eq 0)

    # -----------------------------------------------------------------------
    ""
    "== B: end to end over a scratch tree built from a converted lib"
    # -----------------------------------------------------------------------
    # PaneIdle.ps1 is one of the libraries this task converted; put its old
    # line back in a copy and the sweep must name that copy - and only that copy.
    $src = Join-Path $PSScriptRoot 'lib\PaneIdle.ps1'
    $text = [System.IO.File]::ReadAllText($src)
    Assert 'B0 premise: PaneIdle.ps1 reads the kernel table' ($text -match '\$all = @\(Get-OsProcess\)')
    New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fixtureDir 'converted.ps1'), $text)
    $regressed = $text.Replace('$all = @(Get-OsProcess)', '$all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue')
    [System.IO.File]::WriteAllText((Join-Path $fixtureDir 'regressed.ps1'), $regressed)
    $found = @(Get-WmiBoundAuditFindings -Dir $fixtureDir)
    $paths = @($found | ForEach-Object { Split-Path -Leaf $_.Path })
    Assert 'B1 the regressed copy is a finding' ($paths -contains 'regressed.ps1') "(got: $($paths -join ', '))"
    Assert 'B2 the converted original is not' ($paths -notcontains 'converted.ps1') "(got: $($paths -join ', '))"

    # -----------------------------------------------------------------------
    ""
    "== C: the live libraries are clean"
    # -----------------------------------------------------------------------
    $libDir = Join-Path $Repo 'test\win32\lib'
    $libCount = @(Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -File).Count
    Assert 'C0 premise: the sweep has libraries to read' ($libCount -gt 20) "(scanned $libCount)"
    $live = @(Get-WmiBoundAuditFindings -Dir $libDir)
    foreach ($f in $live) { "    unbounded WMI call: $($f.Path) line(s) $(@($f.Lines) -join ',')" }
    Assert "C1 no test\win32\lib library calls WMI unbounded ($libCount scanned)" ($live.Count -eq 0) "($($live.Count) found)"
    # The scripts themselves are the follow-up's job (T3611); counted, not gated,
    # so the number is visible every run and a conversion shows as it lands.
    $scripts = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'test\win32') -Filter '*.ps1' -File |
        ForEach-Object {
            $h = @(Find-UnboundedWmiCalls -Text ([System.IO.File]::ReadAllText($_.FullName)))
            if ($h.Count -gt 0) { [pscustomobject]@{ Name = $_.Name; Count = $h.Count } }
        })
    $calls = 0; foreach ($s in $scripts) { $calls += $s.Count }
    "    INFO: $($scripts.Count) acceptance script(s) still make $calls unbounded WMI call(s) - converted under T3611"

    # -----------------------------------------------------------------------
    ""
    "== D: the kernel table and the bounded query"
    # -----------------------------------------------------------------------
    $all = @(Get-OsProcess)
    Assert 'D1 the kernel table lists processes' ($all.Count -gt 20) "(got $($all.Count))"
    $me = @($all | Where-Object { $_.ProcessId -eq $PID })
    Assert 'D2 ...including this one' ($me.Count -eq 1) "(got $($me.Count))"
    $mine = [System.Diagnostics.Process]::GetCurrentProcess()
    Assert 'D3 its image path is this process''s' ($me.Count -eq 1 -and $me[0].ExecutablePath -eq $mine.MainModule.FileName) "(got '$($me[0].ExecutablePath)')"
    Assert 'D4 its creation time is this process''s, to the second' (
        $me.Count -eq 1 -and $null -ne $me[0].CreationDate -and
        [math]::Abs(($me[0].CreationDate - $mine.StartTime).TotalSeconds) -lt 1) "(got $($me[0].CreationDate) vs $($mine.StartTime))"
    $named = @(Get-OsProcess -Name ([System.IO.Path]::GetFileName($mine.MainModule.FileName).ToUpperInvariant()) -CommandLine |
        Where-Object { $_.ProcessId -eq $PID })
    Assert 'D5 -Name filters without regard to case, and -CommandLine reads it' (
        $named.Count -eq 1 -and $named[0].CommandLine -match 'wmi-bound-audit') "(got $($named.Count) row(s): '$($named[0].CommandLine)')"
    Assert 'D6 a name nobody runs is an empty table, not a phantom row' (@(Get-OsProcess -Name 'no-such-image-t2024.exe').Count -eq 0)
    $b = @(Get-BoundedCimProcess -Filter "ProcessId=$PID" -Property ProcessId, ParentProcessId)
    Assert 'D7 the bounded WMI query answers on a healthy box' ($b.Count -eq 1 -and [int]$b[0].ParentProcessId -eq $me[0].ParentProcessId) "(got $($b.Count))"
    # A namespace that does not exist cannot answer: the helper must throw its
    # named message, never hand back an empty list a caller would score.
    $threw = ''
    try {
        function Get-CimInstance { param($ClassName, $Filter, $Property, $OperationTimeoutSec, $ErrorAction)
            throw [Microsoft.Management.Infrastructure.CimException]::new('The operation has timed out.') }
        [void](Get-BoundedCimProcess -Filter "ProcessId=$PID" -TimeoutSec 3)
    } catch { $threw = $_.Exception.Message }
    finally { Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue }
    Assert 'D8 a WMI query that does not answer throws "WMI did not answer", never an empty list' (
        $threw -match '^WMI did not answer within 3s') "(got: '$threw')"

    # -----------------------------------------------------------------------
    ""
    "== E: the check is wired into the floor that runs it"
    # -----------------------------------------------------------------------
    . (Join-Path $Repo 'scripts\lib\HarnessFloor.ps1')
    $names = @(Get-HarnessFloorAudits | ForEach-Object { [string]$_.Name })
    Assert 'E1 wmi-bound-audit.ps1 is a member of the harness floor' `
        ($names -contains 'wmi-bound-audit.ps1') "(set: $($names.Count) rows)"
    Assert 'E2 it is not listed as a pending exception' `
        (-not (Get-HarnessFloorPending).ContainsKey('wmi-bound-audit.ps1'))

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

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard wmi-bound -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
