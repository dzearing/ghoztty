<#
.SYNOPSIS
    T694 acceptance - an acceptance script takes the port the OS hands it, and
    never goes back to guessing a number.

.DESCRIPTION
    Three sections:

      A. The helpers (`lib\FreePort.ps1`). `Get-FreePort` returns something
         actually bindable; `Test-PortFree` tells a held port from a free one;
         `Resolve-TestPort` draws when given 0, passes a pinned free port
         through, and THROWS on a pinned port somebody else is holding - which
         is the case the old fixed defaults turned into a silent skip.

      B. The analyzer (`lib\FixedPortAudit.ps1`) against fixtures, both
         directions: a converted script yields nothing, and each violating
         shape - a pinned param default, a literal assignment, a literal
         endpoint - is named with its line.

      C. The sweep over `test\win32\*.ps1`: no acceptance script carries a
         fixed non-zero TCP port any more. Before T694 this stood at 32
         violations across 26 scripts, six of which shared a number with
         another script and therefore could not run near it.

    `-TeethCheck` proves the section-C assertion can fail: it writes a
    synthesized violator into the swept directory and requires the sweep to
    find it. Run it after any change to the analyzer.

    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this scores scripts, it does not run them.
    # stderr: n/a - same reason; nothing here starts ghoztty.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
. (Join-Path $PSScriptRoot 'lib\FixedPortAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t694-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

try {

# --- A. the helpers ----------------------------------------------------------
Write-Host ''
Write-Host 'A. lib\FreePort.ps1'

$p1 = Get-FreePort
Assert "A1 Get-FreePort returns a port in the ephemeral range (got $p1)" (
    $p1 -ge 1024 -and $p1 -le 65535)
Assert 'A2 the port it returned is actually bindable' (Test-PortFree $p1)

# Hold one, and the free check must say so. This is the whole difference
# between "the fake relay never came up" and a named failure.
$held = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$held.Start()
$heldPort = $held.LocalEndpoint.Port
Assert "A3 Test-PortFree is false for a port somebody is holding ($heldPort)" (
    -not (Test-PortFree $heldPort))

# Resolve-TestPort prints what it drew - a run that later fails against a port
# has to be traceable to the number it used.
$drawnOut = Resolve-TestPort -Name 'fixture' -Port 0 6>&1
$drawn = $drawnOut | Where-Object { $_ -is [int] } | Select-Object -Last 1
$drawnSaid = ($drawnOut | Where-Object { $_ -isnot [int] } | Out-String)
Assert "A4 Resolve-TestPort draws a usable port when given 0 (got $drawn)" (
    $drawn -is [int] -and (Test-PortFree $drawn))
Assert 'A5 it PRINTS the port it drew' ($drawnSaid -match "PORT fixture = $drawn")

$pinned = Resolve-TestPort -Name 'pinned' -Port $p1 6>$null
Assert "A6 a pinned free port is passed through unchanged (got $pinned)" ($pinned -eq $p1)

$threw = $false
try { Resolve-TestPort -Name 'busy' -Port $heldPort 6>$null | Out-Null }
catch { $threw = $true; $thrownText = "$_" }
Assert 'A7 a pinned port somebody HOLDS throws instead of falling back silently' $threw
Assert 'A8 and the message names the port and the caller label' (
    $threw -and $thrownText -match "$heldPort" -and $thrownText -match 'busy')

$held.Stop()

# --- B. the analyzer, both directions ----------------------------------------
Write-Host ''
Write-Host 'B. lib\FixedPortAudit.ps1 over fixtures'

$clean = Join-Path $tmp 'clean.ps1'
@'
param([int]$RelayPort = 0, [int]$Timeout = 47911)
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
$RelayPort = Resolve-TestPort -Name 'relay' -Port $RelayPort
$base = "http://127.0.0.1:$RelayPort/"
# the old number was 47911, which is what this comment is for
$hres = -2147483645
'@ | Set-Content -LiteralPath $clean -Encoding ASCII
$v = @(Get-FixedPortViolations -Path $clean)
Assert "B1 a converted script yields no violations (got $($v.Count): $(($v | ForEach-Object { $_.Text }) -join ' | '))" (
    $v.Count -eq 0)

$dirty = Join-Path $tmp 'dirty.ps1'
@'
param([int]$RelayPort = 47911)
$ppPort = 47163
$url = "http://127.0.0.1:47999/opener.html"
'@ | Set-Content -LiteralPath $dirty -Encoding ASCII
$v = @(Get-FixedPortViolations -Path $dirty)
Assert "B2 all three violating shapes are found (got $($v.Count))" ($v.Count -eq 3)
Assert 'B3 the pinned param default is named pinned-default on line 1' (
    @($v | Where-Object { $_.Kind -eq 'pinned-default' -and $_.Line -eq 1 }).Count -eq 1)
Assert 'B4 the literal assignment is named literal-assignment on line 2' (
    @($v | Where-Object { $_.Kind -eq 'literal-assignment' -and $_.Line -eq 2 }).Count -eq 1)
Assert 'B5 the baked-in address is named literal-endpoint on line 3' (
    @($v | Where-Object { $_.Kind -eq 'literal-endpoint' -and $_.Line -eq 3 }).Count -eq 1)

# Numbers that are not ports, on lines that look port-shaped. A harness that
# cried wolf over an HRESULT would be turned off within a week.
$noise = Join-Path $tmp 'noise.ps1'
@'
$ENDSESSION_LOGOFF = -2147483648
$sig = $sig % 2147483647
$sha = '2389d318249a47333d7bfad9d05ded7247a44011'
$portWaitMs = 250
'@ | Set-Content -LiteralPath $noise -Encoding ASCII
$v = @(Get-FixedPortViolations -Path $noise)
Assert "B6 non-port numbers are not violations (got $($v.Count))" ($v.Count -eq 0)

# Fixture text inside a here-string is a script this run never executes. Built
# line by line rather than as a here-string, because a here-string containing a
# here-string terminates at the inner one's closing delimiter.
$herestring = Join-Path $tmp 'here.ps1'
@(
    ('$image = @' + "'"),
    ("`$a = Start-Agent -Arguments @('--listen', '127.0.0.1:" + 7777 + "')"),
    ("'" + '@'),
    '$x = 1'
) | Set-Content -LiteralPath $herestring -Encoding ASCII
$v = @(Get-FixedPortViolations -Path $herestring)
Assert "B7 a port inside here-string fixture text is not a violation (got $($v.Count))" (
    $v.Count -eq 0)

# --- C. the sweep ------------------------------------------------------------
Write-Host ''
Write-Host 'C. no acceptance script still guesses a port'

$sweepDir = Join-Path $Repo 'test\win32'
if ($TeethCheck) {
    # The demonstration that C1 can go red: a synthesized violator, swept like
    # any other script and removed in the finally below.
    # Assembled rather than written out, so THIS file does not trip its own
    # sweep on the line that describes the violation.
    $script:teeth = Join-Path $sweepDir 'zzz-t694-teeth.ps1'
    Set-Content -LiteralPath $script:teeth -Encoding ASCII `
        -Value ('param([int]$RelayPort = ' + 47911 + ')')
}

$found = @()
foreach ($f in (Get-ChildItem $sweepDir -Filter *.ps1 -Recurse)) {
    $found += Get-FixedPortViolations -Path $f.FullName
}
foreach ($x in $found) {
    Write-Host ("      {0}:{1} {2} :: {3}" -f (Split-Path $x.File -Leaf), $x.Line, $x.Kind, $x.Text)
}
if ($TeethCheck) {
    Assert 'C1 -TeethCheck: the sweep FOUND the synthesized violator' (
        @($found | Where-Object { $_.File -eq $script:teeth }).Count -eq 1)
}
else {
    Assert "C1 every acceptance script draws its ports (found $($found.Count) fixed)" (
        $found.Count -eq 0)
}

Write-Host ''
Complete-TestBody  # T1039: the run reached the end of its body

}
finally {
    if ($script:teeth) { Remove-Item -Force $script:teeth -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# A green run stamps the covered files (T783). A -TeethCheck run does NOT: it
# deliberately swept a violator, so it proves the analyzer has teeth rather than
# that the tree is clean.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard fixed-ports -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T694 ACCEPTANCE' -Pass $script:pass -Fail $script:fail -MinPass 12
