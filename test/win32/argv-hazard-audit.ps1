<#
.SYNOPSIS
    T782 acceptance - a PowerShell script must not hand the ghoztty CLI free
    text on a native argv, where PowerShell 5.1 silently destroys it.

.DESCRIPTION
    T279 measured the defect with a GetCommandLineW oracle and fixed the call
    sites it could enumerate BY HAND. A hand enumeration is a snapshot: nothing
    stopped the next script from writing `& $exe "--title=$label"` again, and
    the symptom when it does is text that arrives with pieces missing, at exit
    0, with every log line reporting success.

    Three sections:

      A. The analyzer (`lib\ArgvHazardAudit.ps1`) against fixtures, both
         directions - the T279 shapes are named, and the interpolation this
         suite legitimately writes (a pane guid on `--target=`, a literal given
         a name three lines up, a TEMP path built with Join-Path, the safe
         `--keys-file=` transport) resolves quietly. An analyzer that reports
         thirty innocent call sites is an analyzer nobody runs, so the quiet
         direction is checked as hard as the loud one.

      B. The sweep over `scripts\` and `test\win32\`. Every ghoztty call in
         every script must carry a literal, or state its intent with an
         `# argv-audit:` marker. This is the assertion with the value; A is
         what makes it trustworthy.

      C. `-TeethCheck` - the negative control. It plants the exact 2026-08-11
         defect (a resume command interpolated onto `--command=`) into a real
         file in the suite directory and requires section B's sweep to go RED
         naming it, then removes it. A check never observed failing is not a
         check.

    Section A also measures the analyzer against the LIVE corruption rather
    than only against its own opinion: A13 runs three payloads through a real
    child process's argv the naive way and requires them to arrive corrupted,
    which is the property that makes every finding in section B worth acting
    on.

    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.

.NOTES
    # persistence: launches no GUI and no ghoztty - this reads scripts, and the
    # one child it starts is a powershell that prints its own argv. No IPC
    # endpoint, no user state.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ArgvHazardAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "ghoztty-t782-$PID"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$enc = New-Object Text.UTF8Encoding $false
# Fixtures are written with two PLACEHOLDERS - `%V%` for the `+` of a ghoztty
# verb, `%SP%` for Start-Process - and expanded on the way to disk. The fixture
# on disk is therefore exactly the text the analyzer has to read, while THIS
# script's own text contains no `+verb` and no launch statement. Three sibling
# audits scan script text rather than behaviour (isolation-meta reads a `+verb`
# as "this drives the CLI and must claim a private endpoint",
# launch-preflight-audit and stderr-launch-capture read a Start-Process as a
# real app launch), and a fixture written literally makes all three report a
# script that launches nothing and drives nothing.
function Expand-FixtureText([string]$Body) {
    return ($Body.Replace('%V%', '+').Replace('%SP%', ('Start' + '-' + 'Process')))
}
function Write-Fixture([string]$Rel, [string]$Body) {
    $p = Join-Path $tmp $Rel
    [IO.File]::WriteAllText($p, (Expand-FixtureText $Body), $enc)
    $p
}
function Fixture-Findings([string]$Path) {
    Reset-ArgvHazardCache
    @(Get-ArgvHazardFindings -Repo $tmp -Paths @($Path) -IncludeExempt)
}
function Fixture-Open([string]$Path) {
    Reset-ArgvHazardCache
    @(Get-ArgvHazardFindings -Repo $tmp -Paths @($Path))
}

# ============================================================================
Write-Host '== A: the analyzer, against fixtures'
# ============================================================================

# A1: the live 2026-08-11 defect - the loop's own relaunch command on argv.
$a1 = Write-Fixture 'a1.ps1' @'
$exe = 'C:\x\ghoztty.exe'
$resume = 'claude --continue "read go.md and go"'
& $exe %V%new-window --title=loop "--command=$resume"
'@
$fa1 = Fixture-Findings $a1
Assert 'A1 the T279 shape - a composed command on --command= - is named' (
    (@($fa1).Count -eq 1) -and ($fa1[0].Carrier -eq '--command')) (
    (@($fa1) | ForEach-Object { "$($_.Carrier)@$($_.Line)" }) -join ',')
Assert 'A2 and it is named at the line that writes it' (
    (@($fa1).Count -eq 1) -and ($fa1[0].Line -eq 3)) (
    "line $(if (@($fa1).Count) { $fa1[0].Line } else { 'none' })")

# A3: ids are NOT the hazard. A pane guid, a window name and a pid cannot carry
# a quote or end in a backslash, and reporting them is how an audit becomes
# noise nobody reads.
$a3 = Write-Fixture 'a3.ps1' @'
$exe = 'C:\x\ghoztty.exe'
$pane = '3FCBD5B5-C4E6-44BC-8971-274CB20C8917'
& $exe %V%read "--name=$pane" --lines=40
& $exe %V%split "--target=$pane" --view=readme.md
& $exe %V%list --json
'@
Assert 'A3 a pane id on --target=/--name= is not a finding' (
    @(Fixture-Findings $a3).Count -eq 0) (
    ((Fixture-Findings $a3) | ForEach-Object { $_.Carrier }) -join ',')

# A4: a literal that was given a NAME is still a literal. Without this fold the
# sweep reports every test that hoisted its payload to a variable, and the
# reviewer's first question is why the tool cannot read the line above.
$a4 = Write-Fixture 'a4.ps1' @'
$exe = 'C:\x\ghoztty.exe'
$banner = 'a long banner that wraps over several lines in a narrow pane'
$tail = "$banner and then some"
& $exe %V%set-banner --target=w1 $banner
& $exe %V%set-banner --target=w1 $tail
'@
Assert 'A4 a variable whose every assignment is a literal folds to one' (
    @(Fixture-Findings $a4).Count -eq 0) (
    ((Fixture-Findings $a4) | ForEach-Object { "$($_.Text)@$($_.Line)" }) -join ',')

# A5: a PARAMETER is free text - it is exactly what a caller composed - and it
# is free text only INSIDE the function that declares it. A helper elsewhere in
# the file taking a `$banner` must not make A4's literal unreadable.
$a5 = Write-Fixture 'a5.ps1' @'
$exe = 'C:\x\ghoztty.exe'
function Format-Row([string]$banner) { "row: $banner" }
function Send-Banner([string]$banner) {
    & $exe %V%set-banner --target=w1 $banner
}
$banner = 'a literal banner'
& $exe %V%set-banner --target=w2 $banner
'@
$fa5 = Fixture-Findings $a5
Assert 'A5 a parameter is a finding, and only inside its own function' (
    (@($fa5).Count -eq 1) -and ($fa5[0].Line -eq 4)) (
    (@($fa5) | ForEach-Object { "line $($_.Line)" }) -join ',')

# A6: a TEMP path is safe, and the reason is precise - a Windows path cannot
# contain a `"`, and a literal leaf settles the trailing-backslash half. A BARE
# base is not safe, because a drive root ends in the backslash that makes
# PowerShell's closing quote read as escaped.
$a6 = Write-Fixture 'a6.ps1' @'
$exe = 'C:\x\ghoztty.exe'
$probe = Join-Path $env:TEMP 'ghoztty-probe.ps1'
& $exe %V%send-keys --target=p1 "powershell -File $probe" Enter
& $exe %V%new-window "--working-directory=$env:TEMP"
'@
$fa6 = Fixture-Findings $a6
Assert 'A6 a Join-Path TEMP path is safe; a bare directory variable is not' (
    (@($fa6).Count -eq 1) -and ($fa6[0].Carrier -eq '--working-directory')) (
    (@($fa6) | ForEach-Object { "$($_.Carrier)@$($_.Line)" }) -join ',')

# A7: the safe transport. `--keys-file=` exists so a PROMPT never rides argv at
# all (T210), and the flag is deliberately not a carrier.
$a7 = Write-Fixture 'a7.ps1' @'
$exe = 'C:\x\ghoztty.exe'
$file = Join-Path $env:TEMP 'prompt.txt'
& $exe %V%send-keys --target=p1 "--keys-file=$file"
'@
Assert 'A7 the --keys-file= transport is not a finding' (
    @(Fixture-Findings $a7).Count -eq 0) (
    ((Fixture-Findings $a7) | ForEach-Object { $_.Carrier }) -join ',')

# A8: a .ps1 invoked with & binds its parameters IN PROCESS. No command line is
# composed, so PowerShell's composer never runs and there is nothing to
# corrupt - and a script that took `--title=` would otherwise look like a CLI.
$a8 = Write-Fixture 'a8.ps1' @'
$label = 'a title with a " quote'
& .\helper.ps1 %V%rename "--title=$label"
& "$PSScriptRoot\helper.ps1" %V%set-banner "$label"
'@
Assert 'A8 a & .\script.ps1 call is not a native argv at all' (
    @(Fixture-Findings $a8).Count -eq 0) (
    ((Fixture-Findings $a8) | ForEach-Object { $_.Carrier }) -join ',')

# A9: another program's command line is not this audit's question, even when it
# interpolates. The finding needs the call to be GHOZTTY's.
$a9 = Write-Fixture 'a9.ps1' @'
$script_ = 'C:\x\build.ps1'
$msg = 'anything at all'
& powershell.exe -NoProfile -File $script_ "--title=$msg"
'@
Assert 'A9 a non-ghoztty native call is out of scope' (
    @(Fixture-Findings $a9).Count -eq 0) (
    ((Fixture-Findings $a9) | ForEach-Object { $_.Carrier }) -join ',')

# A10: Start-Process does not quote its -ArgumentList elements either (T200),
# so the same text through it is the same defect.
$a10 = Write-Fixture 'a10.ps1' @'
$exe = 'C:\x\ghoztty.exe'
$prompt = 'claude --continue "read go.md and go"'
%SP% -FilePath $exe -ArgumentList @('%V%new-window', "--command=$prompt")
'@
$fa10 = Fixture-Findings $a10
Assert 'A10 Start-Process -ArgumentList carries the same hazard' (
    (@($fa10).Count -eq 1) -and ($fa10[0].Carrier -eq '--command')) (
    (@($fa10) | ForEach-Object { $_.Carrier }) -join ',')

# A11: the stated-intent exemption, and its SCOPE. A marker states the intent
# for ONE call site - the site written below it is reported as loudly as ever,
# which is the whole difference between this and a file-wide suppression.
$a11 = Write-Fixture 'a11.ps1' @'
$exe = 'C:\x\ghoztty.exe'
$id = "T123-$PID"
# argv-audit: a fixture proving the marker exempts THIS call
& $exe %V%rename --target=w1 "--title=$id"
$later = $host.Name
& $exe %V%rename --target=w1 "--title=$later"
'@
$fa11open = Fixture-Open $a11
$fa11all = Fixture-Findings $a11
Assert 'A11 an # argv-audit: marker exempts the call it sits above' (
    (@($fa11open).Count -eq 1) -and ($fa11open[0].Line -eq 6)) (
    (@($fa11open) | ForEach-Object { "line $($_.Line)" }) -join ',')
Assert 'A12 an exempt site is still SEEN, so a control can assert on it' (
    (@($fa11all).Count -eq 2) -and
    (@($fa11all | Where-Object { $_.Exempt }).Count -eq 1)) (
    (@($fa11all) | ForEach-Object { "line $($_.Line) exempt=$($_.Exempt)" }) -join ',')

# A13: the analyzer's opinion measured against the real thing. Three payloads
# through a real child's argv, the naive way, must arrive CORRUPTED - otherwise
# every finding above is about a hazard that does not exist on this box.
$oracle = Write-Fixture 'oracle.ps1' @'
$i = 0
foreach ($a in $args) { "arg${i}=$a"; $i++ }
"count=$($args.Count)"
'@
function Invoke-Oracle([string[]]$Args_) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $oracle @Args_ 2>&1
    return (@($out) -join "`n")
}
$quoted = 'a "quoted phrase" mid string'
$rQuoted = Invoke-Oracle @("--title=$quoted")
Assert 'A13 a payload with an embedded quote is CORRUPTED on a naive argv' (
    $rQuoted -notmatch [regex]::Escape($quoted)) ($rQuoted -replace "`n", ' | ')
$trailing = 'C:\my dir\'
$rTrailing = Invoke-Oracle @("--title=$trailing")
Assert 'A14 a payload ending in a backslash is CORRUPTED on a naive argv' (
    $rTrailing -notmatch [regex]::Escape($trailing)) ($rTrailing -replace "`n", ' | ')
$safe = 'plain safe text'
$rSafe = Invoke-Oracle @("--title=$safe")
Assert 'A15 a payload with no quote and no trailing backslash SURVIVES' (
    ($rSafe -match [regex]::Escape("arg0=--title=$safe")) -and
    ($rSafe -match 'count=1')) ($rSafe -replace "`n", ' | ')

# A16: an empty analyzer input must not read as a clean file. ParseInput('')
# yields an empty AST that reports zero of everything, which is
# indistinguishable from a tree with nothing wrong.
$a16ast = Get-ArgvHazardAst -Path $a1
Assert 'A16 the analyzer parses the FILE when no text is passed' (
    $a16ast.Extent.Text.Length -gt 0) "len $($a16ast.Extent.Text.Length)"
Assert 'A17 the carrier and verb sets are non-empty' (
    (@(Get-ArgvHazardFlags).Count -ge 5) -and (@(Get-ArgvHazardVerbs).Count -ge 10)) (
    "$(@(Get-ArgvHazardFlags).Count) flags, $(@(Get-ArgvHazardVerbs).Count) verbs")

# ============================================================================
Write-Host ''
Write-Host '== B: the sweep over scripts\ and test\win32\'
# ============================================================================

function Get-SweepRoots {
    $out = @()
    foreach ($d in @('scripts', 'scripts\lib', 'test\win32', 'test\win32\lib')) {
        $p = Join-Path $Repo $d
        if (Test-Path -LiteralPath $p) {
            $out += @(Get-ChildItem -LiteralPath $p -Filter *.ps1 -File |
                ForEach-Object { $_.FullName })
        }
    }
    @($out)
}

Reset-ArgvHazardCache
$roots = Get-SweepRoots
$sweep = @(Get-ArgvHazardFindings -Repo $Repo -Paths $roots)
$all = @(Get-ArgvHazardFindings -Repo $Repo -Paths $roots -IncludeExempt)

Assert 'B1 the sweep actually looked at the tree' (@($roots).Count -ge 300) `
    "$(@($roots).Count) scripts"
Assert 'B2 no ghoztty call puts unexplained free text on a native argv' (
    $sweep.Count -eq 0)
foreach ($f in $sweep) {
    Write-Host "      $($f.File):$($f.Line) [$($f.Carrier)] $($f.Text)" -ForegroundColor Red
}
# The exempt set is REPORTED, not assumed empty: every one of them is a human
# statement that the text cannot carry a quote or end in a backslash, and a
# reader deciding whether to trust B2 wants to see how many there are.
Assert 'B3 every remaining site states its intent with a marker' (
    @($all | Where-Object { $_.Exempt }).Count -eq $all.Count) (
    "$(@($all | Where-Object { $_.Exempt }).Count) of $($all.Count)")
Write-Host "      $(@($all).Count) explained site(s)"

# B4: the sites T279 converted must NOT be reported - they went through
# Invoke-NativeExact, which composes the command line to the CRT's own rules.
$t279 = @($all | Where-Object {
    $_.File -like 'scripts\go-loop-exec.ps1' -or
    $_.File -like 'scripts\go-loop-watchdog.ps1' -or
    $_.File -like 'scripts\watchdog-ghoztty-windows.ps1' })
Assert 'B4 the call sites T279 converted are not reported at all' (
    $t279.Count -eq 0) (
    ($t279 | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', ')

# B5: and the suite's deliberate naive control IS seen. `cli-argv-fidelity.ps1`
# section D sends the hazardous payloads the naive way and requires them to
# arrive corrupted; an analyzer that could not see that shape in a real file
# would have nothing to say about section B's zero.
$control = @($all | Where-Object { $_.File -like '*cli-argv-fidelity.ps1' })
Assert 'B5 the naive negative control in cli-argv-fidelity.ps1 IS seen' (
    $control.Count -ge 2) ("$($control.Count) site(s)")
Assert 'B6 ...and it is explained rather than silently invisible' (
    (@($control | Where-Object { $_.Exempt }).Count -eq $control.Count)) (
    ($control | ForEach-Object { "$($_.Line) exempt=$($_.Exempt)" }) -join ', ')

# ============================================================================
if ($TeethCheck) {
    Write-Host ''
    Write-Host '== C: teeth - the sweep must go red on a planted violator'
    # ========================================================================
    $planted = Join-Path $PSScriptRoot 'zz-t782-teeth-fixture.ps1'
    try {
        [IO.File]::WriteAllText($planted, (Expand-FixtureText @'
# A synthesized violator (T782 teeth check) - the exact 2026-08-11 defect. If
# this file is still here, a teeth run did not clean up after itself: delete it.
$exe = 'C:\x\ghoztty.exe'
$resume = 'claude --continue "read go.md and go"'
& $exe %V%new-window --title=loop "--command=$resume"
'@), $enc)
        Reset-ArgvHazardCache
        $teeth = @(Get-ArgvHazardFindings -Repo $Repo -Paths (Get-SweepRoots))
        $named = @($teeth | Where-Object {
            $_.File -like '*zz-t782-teeth-fixture.ps1' -and $_.Carrier -eq '--command' })
        Assert 'C1 the sweep names the planted hazardous call' (@($named).Count -eq 1) `
            ("found: " + ((@($teeth) | ForEach-Object { "$($_.File):$($_.Carrier)" }) -join ', '))
        Assert 'C2 and it fails the run rather than merely mentioning it' (
            @($teeth).Count -gt 0)

        # C3: a marker on the planted site clears it again - the exemption is
        # the documented way out, and it has to work or the audit is a wall.
        [IO.File]::WriteAllText($planted, (Expand-FixtureText @'
# A synthesized violator (T782 teeth check), exempted. Delete this file if a
# teeth run left it behind.
$exe = 'C:\x\ghoztty.exe'
$resume = 'claude --continue "read go.md and go"'
# argv-audit: a fixture, never run - the teeth check plants it on purpose
& $exe %V%new-window --title=loop "--command=$resume"
'@), $enc)
        Reset-ArgvHazardCache
        $teeth2 = @(Get-ArgvHazardFindings -Repo $Repo -Paths (Get-SweepRoots))
        Assert 'C3 a marker on the planted site clears the sweep again' (
            @($teeth2 | Where-Object { $_.File -like '*zz-t782-teeth-fixture.ps1' }).Count -eq 0) (
            ($teeth2 | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', ')
    } finally {
        Remove-Item -LiteralPath $planted -Force -ErrorAction SilentlyContinue
    }
    Assert 'C4 the planted violator is removed again' (
        -not (Test-Path -LiteralPath $planted))
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files, and never a teeth check -
# that run deliberately plants a violator.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard argv-hazard -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'ARGV HAZARD AUDIT' -MinPass 22
