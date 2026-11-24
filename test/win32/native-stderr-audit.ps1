<#
.SYNOPSIS
    T2176 acceptance - a native call whose stderr is redirected cannot end a
    script that runs under ErrorActionPreference Stop.

.DESCRIPTION
    THE DEFECT (T1215): under `$ErrorActionPreference = 'Stop'`, Windows
    PowerShell 5.1 turns ANY stderr line from a native call with its stderr
    redirected (`2>$null`, `2>&1`) into a terminating error. The ghoztty CLI
    prints "Waiting for Ghoztty to answer ..." on stderr whenever the app is
    slow, on its way to succeeding, so a slow box ends the run with no verdict
    and past its cleanup. soak.ps1's 30-minute run died that way at its
    teardown `+close` after every assertion had passed. The fix is
    `Invoke-Tolerant { ... }` (lib\NativeTolerant.ps1). This sweeps the IDIOM
    with the analyzer in `lib\NativeStderrAudit.ps1` (its header has the rules).

    Sections:

      A. The analyzer against fixtures, BOTH directions: a redirected app call
         under Stop is reported (2>$null, 2>&1, *>, a bare `ghoztty`, a
         variable assigned a .exe path); the same call wrapped in
         Invoke-Tolerant, unredirected, under Continue, in a function that
         sets Continue, or carrying `# native-stderr: <reason>` is not; a
         marker with no reason exempts nothing; a function with no assignment
         inherits the file's Stop.

      B. NEGATIVE CONTROL against the real thing: soak.ps1 as it stood BEFORE
         the T1215 fix (read from git) is flagged on its teardown `+close`, and
         the file as it stands now is not.

      C. The trap and the helper, LIVE on this PowerShell: a redirected native
         stderr line under Stop throws (so the audit is about something real),
         and the same call inside Invoke-Tolerant survives, leaves the caller's
         Stop in force, returns the call's stdout and carries its exit code.

      D. The ratchet. The sites present on 2026-11-24 are a per-file count in
         `native-stderr-audit.baseline.json`. A file ABOVE its count fails, a
         file BELOW it fails naming `-UpdateBaseline`, and a new file with a
         finding fails - so a new call wraps itself or says why.

      E. Scope: the sweep looked at the whole tree and says how much.

      T. Teeth, every run: a planted file under a swept tree is flagged AND
         fails the ratchet.

    `-UpdateBaseline` rewrites the baseline from the current sweep. Use it in
    the commit that removes a site, never to make a red run go green.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files; section C runs
    # cmd.exe to write one line on stderr, nothing else.
    # isolation: none - the ghoztty verbs here are fixture text for the analyzer, nothing is executed
#>
[CmdletBinding()]
param(
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\NativeStderrAudit.ps1')
. (Join-Path $PSScriptRoot 'lib\NativeTolerant.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function AssertEq([string]$name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path $env:TEMP "ghoztty-t2176-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

$Root = Join-Path $Repo 'test\win32'
$BaselinePath = Join-Path $PSScriptRoot 'native-stderr-audit.baseline.json'

# `return ,` so a one-finding result stays an array: a lone pscustomobject has a
# $null .Count under 5.1, which read as zero findings.
function Fixture([string]$Body) {
    return , @(Get-NativeStderrFindings -Path 'fixture.ps1' -Text ($Body -split "`n"))
}

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer, both directions'
# ===========================================================================

$f = Fixture @'
$ErrorActionPreference = 'Stop'
& $exe +close --target=x 2>$null | Out-Null
$o = & $exe +list --json 2>&1
& $exe +read --name=p *> $null
'@
AssertEq 'A1 under Stop, 2>$null, 2>&1 and *> on an app call are each reported' 3 $f.Count

$f = Fixture @'
$ErrorActionPreference = 'Stop'
$gz = Join-Path $Repo 'zig-out\bin\ghoztty.exe'
& $gz +list 2>$null
ghoztty +list 2>&1
'@
AssertEq 'A2 a variable the file assigns a .exe path, and a bare ghoztty command, are app calls' 2 $f.Count

$f = Fixture @'
$ErrorActionPreference = 'Stop'
Invoke-Tolerant { & $exe +close --target=x 2>$null | Out-Null }
$j = Invoke-Tolerant { & $exe +list --json 2>$null }
& $exe +list
'@
AssertEq 'A3 inside Invoke-Tolerant, and with no redirection, nothing is reported' 0 $f.Count

$f = Fixture @'
$ErrorActionPreference = 'Continue'
& $exe +list 2>&1
function Quiet { $ErrorActionPreference = 'SilentlyContinue'; & $exe +list 2>$null }
'@
AssertEq 'A4 under Continue - the file''s, or a function''s own - nothing is reported' 0 $f.Count

$f = Fixture @'
$ErrorActionPreference = 'Stop'
function Loud { & $exe +list 2>$null }
function Soft {
    $ErrorActionPreference = 'Continue'
    & $exe +list 2>$null
}
'@
AssertEq 'A5 a function with no assignment inherits the file''s Stop; one that sets Continue does not' 1 $f.Count

$f = Fixture @'
& $exe +list 2>$null
$ErrorActionPreference = 'Stop'
& $exe +list 2>$null
'@
Assert "A6 a call BEFORE the file switches to Stop is not reported, the one after is ($(@($f | ForEach-Object { 'L' + $_.Line }) -join ','))" (
    $f.Count -eq 1 -and $f[0].Line -eq 3)

$f = Fixture @'
$ErrorActionPreference = 'Stop'
# native-stderr: the error IS the assertion - this call is meant to fail
& $exe +close --target=nope 2>&1
& $exe +close --target=nope 2>&1  # native-stderr: same, on the line itself
'@
AssertEq 'A7 a stated reason on the line or the line above exempts the site' 0 $f.Count

$f = Fixture @'
$ErrorActionPreference = 'Stop'
# native-stderr:
& $exe +close --target=nope 2>&1
'@
AssertEq 'A8 a marker with no reason exempts nothing' 1 $f.Count

$f = Fixture @'
$ErrorActionPreference = 'Stop'
& $Body 2>&1
Get-ChildItem x 2>$null
& $exe +list 2>$null | Out-Null
'@
AssertEq 'A9 a scriptblock variable and a cmdlet are not app calls' 1 $f.Count

$f = Fixture 'function Broken( {'
Assert 'A10 a file that does not parse is reported, not skipped' ($f.Count -eq 1 -and $f[0].Kind -eq 'parse-error')

# ===========================================================================
Write-Host ''
Write-Host '== B: negative control - the real T1215 defect, before and after'
# ===========================================================================

$pre = @(& git -C $Repo show '038dfd496~1:test/win32/soak.ps1' 2>$null)
Assert "B1 soak.ps1 before the T1215 fix was read from git ($($pre.Count) lines)" ($pre.Count -gt 500)
$preHits = @(Get-NativeStderrFindings -Path 'soak.pre-T1215.ps1' -Text $pre)
$teardown = @($preHits | Where-Object { $_.Detail -match '\+close --target=soak 2>\$null' })
Assert "B2 and its teardown +close is flagged ($($preHits.Count) site(s): $(@($preHits | ForEach-Object { 'L' + $_.Line }) -join ','))" (
    $teardown.Count -ge 1)
$now = @(Get-Content -LiteralPath (Join-Path $Root 'soak.ps1'))
$nowHits = @(Get-NativeStderrFindings -Path 'soak.ps1' -Text $now)
AssertEq 'B3 the file as it stands now (every such call in Invoke-Tolerant) has no finding' 0 $nowHits.Count

# ===========================================================================
Write-Host ''
Write-Host '== C: the trap and the helper, live'
# ===========================================================================

$script:threwBareC = $false
$script:threwWrappedC = $false
& {
    $ErrorActionPreference = 'Stop'
    try { & cmd.exe /c 'echo Waiting for Ghoztty to answer 1>&2' 2>$null | Out-Null } catch { $script:threwBareC = $true }
    try {
        $script:outC = Invoke-Tolerant { & cmd.exe /c 'echo payload& echo Waiting for Ghoztty to answer 1>&2& exit 7' 2>$null }
        $script:codeC = $LASTEXITCODE
    } catch { $script:threwWrappedC = $true }
    $script:prefC = $ErrorActionPreference
}
$threwBare = [bool]$script:threwBareC
$threwWrapped = [bool]$script:threwWrappedC
Assert 'C1 on this PowerShell a redirected native stderr line under Stop throws (the trap is real)' $threwBare
Assert 'C2 the same line inside Invoke-Tolerant does not' (-not $threwWrapped)
AssertEq 'C3 and the caller is still under Stop afterwards' 'Stop' $script:prefC
AssertEq 'C4 the call''s stdout comes back' 'payload' ("$($script:outC)".Trim())
AssertEq 'C5 and its exit code is in $LASTEXITCODE' 7 $script:codeC

# ===========================================================================
Write-Host ''
Write-Host '== D: the ratchet over test\win32'
# ===========================================================================

$all = @(Get-NativeStderrSweep -Roots @($Root))
$hard = @($all | Where-Object { $_.Kind -ne 'parse-error' })
$current = @{}
foreach ($x in $hard) {
    $rel = Get-NativeStderrRelativePath -Path $x.Path -Repo $Repo
    if (-not $current.ContainsKey($rel)) { $current[$rel] = 0 }
    $current[$rel] = $current[$rel] + 1
}

if ($UpdateBaseline) {
    $obj = [ordered]@{
        note      = 'Per-file counts of native-stderr-audit findings: a call of the app (or another native exe) with stderr redirected, in a script running under ErrorActionPreference Stop, where the CLI''s "Waiting for Ghoztty to answer" note ends the run (T1215). Recorded 2026-11-24 by T2176; worked down by wrapping each site in Invoke-Tolerant (lib\NativeTolerant.ps1). May only go DOWN. See docs/design/windows-parity-tasks/T2176.md.'
        generated = (Get-Date -Format 'yyyy-MM-dd')
        files     = [ordered]@{}
    }
    foreach ($k in ($current.Keys | Sort-Object)) { $obj.files[$k] = $current[$k] }
    $json = ($obj | ConvertTo-Json -Depth 5)
    [System.IO.File]::WriteAllText($BaselinePath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  baseline rewritten: $($current.Keys.Count) file(s)"
}

Assert 'D0 the baseline exists' (Test-Path -LiteralPath $BaselinePath)
$baseFiles = @{}
if (Test-Path -LiteralPath $BaselinePath) {
    $base = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    foreach ($p in $base.files.PSObject.Properties) { $baseFiles[$p.Name] = [int]$p.Value }
}

$cmp = Compare-NativeStderrBaseline -Current $current -Baseline $baseFiles
foreach ($r in $cmp.Regressed) { Write-Host "      NEW: $r" -ForegroundColor Red }
if (@($cmp.Regressed).Count -gt 0) {
    foreach ($x in $hard) {
        $rel = Get-NativeStderrRelativePath -Path $x.Path -Repo $Repo
        if (@($cmp.Regressed | Where-Object { $_.StartsWith("$rel ") }).Count -gt 0) {
            Write-Host "      $rel`:$($x.Line) $($x.Detail)"
            Write-Host '        -> wrap it: Invoke-Tolerant { ... } (lib\NativeTolerant.ps1), or say why: # native-stderr: <reason>'
        }
    }
}
AssertEq 'D1 no file has gained a redirected app call under Stop' 0 @($cmp.Regressed).Count
foreach ($i in $cmp.Improved) { Write-Host "      FIXED: $i" }
Assert 'D2 the baseline matches the tree (-UpdateBaseline in the commit that removes a site)' (
    @($cmp.Improved).Count -eq 0)
$parse = @($all | Where-Object { $_.Kind -eq 'parse-error' })
foreach ($x in $parse) { Write-Host "      $(Get-NativeStderrRelativePath $x.Path $Repo):$($x.Line) $($x.Detail)" -ForegroundColor Red }
AssertEq 'D3 nothing in the tree fails to parse' 0 $parse.Count

# ===========================================================================
Write-Host ''
Write-Host '== E: scope'
# ===========================================================================

$ps1Count = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse).Count
$libCount = @(Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Filter *.ps1 -File).Count
Assert "E1 the sweep walked test\win32 ($ps1Count .ps1 files, $libCount of them in lib\)" (
    $ps1Count -ge 300 -and $libCount -ge 20)
$stopFiles = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse |
    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match "ErrorActionPreference\s*=\s*'Stop'" }).Count
Assert "E2 and it had something to read: $stopFiles script(s) run under Stop" ($stopFiles -ge 50)

# ===========================================================================
Write-Host ''
Write-Host '== T: the teeth (D1 must be able to score red)'
# ===========================================================================

$fakeRoot = Join-Path $tmp 'test\win32'
New-Item -ItemType Directory -Force $fakeRoot | Out-Null
Set-Content -LiteralPath (Join-Path $fakeRoot 'planted-stderr.ps1') -Encoding ascii -Value @(
    '$ErrorActionPreference = ''Stop''',
    '& $exe +close --target=planted 2>$null | Out-Null')
$planted = @(Get-NativeStderrSweep -Roots @($fakeRoot))
Assert 'T1 a redirected app call under Stop planted in a scratch file under a swept tree is flagged' (
    $planted.Count -eq 1 -and $planted[0].Kind -eq 'redirect')
$withPlant = @{}
foreach ($k in $current.Keys) { $withPlant[$k] = $current[$k] }
$withPlant['test\win32\planted-stderr.ps1'] = 1
$cmpT = Compare-NativeStderrBaseline -Current $withPlant -Baseline $baseFiles
Assert 'T2 and the ratchet fails on it - a new file cannot arrive excused' (
    @($cmpT.Regressed | Where-Object { $_ -like 'test\win32\planted-stderr.ps1 *' }).Count -eq 1)
$oneMore = @{}
foreach ($k in $current.Keys) { $oneMore[$k] = $current[$k] }
$anyKey = @($baseFiles.Keys | Sort-Object)[0]
if ($anyKey) { $oneMore[$anyKey] = $baseFiles[$anyKey] + 1 }
$cmpU = Compare-NativeStderrBaseline -Current $oneMore -Baseline $baseFiles
Assert "T3 and one more site in a baselined file fails too ($anyKey)" (
    $anyKey -and @($cmpU.Regressed | Where-Object { $_ -like "$anyKey *" }).Count -eq 1)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard native-stderr -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-Host "  sweep: $ps1Count script(s); $($hard.Count) redirected app call(s) under Stop across $($current.Keys.Count) file(s) (baseline: recorded by T2176, worked down by wrapping)"
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'NATIVE STDERR AUDIT' -MinPass 20
