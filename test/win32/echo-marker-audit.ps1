<#
.SYNOPSIS
    T1143 acceptance - a harness that waits in a pane for a marker it typed
    there has to say whether seeing the shell's ECHO of that marker is enough.

.DESCRIPTION
    THE DEFECT (T1116): holder-volume.ps1 typed a flood command ending in a
    unique end marker, then waited for the marker on screen as proof the flood
    had finished. The shell echoes the command line, so the marker was on
    screen the instant the keys landed: the wait scored a flood that had not
    started, and in one run was still printing a minute later. The fix typed
    the marker in two halves the command joins, so only its OUTPUT holds it.

    Seeing the echo is fine for "the pane is live" or "the scrollback came
    back", and wrong for "the command ran". Nothing in the source says which a
    wait means, so a subject-scoped hand sweep cannot close the class - the
    T1143 sweep read every site in the tree and found the rest were presence
    checks, which says nothing about the next script. This sweeps the IDIOM
    with the analyzer in `lib\EchoMarkerAudit.ps1` (its header has the rules).

    Sections:

      A. The analyzer against fixtures, BOTH directions: the split form and a
         needle with literal text of its own yield nothing; a bare typed
         marker in a Wait-*, a -match and a .Contains() is reported; typing
         carries through an assignment and a --keys-file write; an option
         (`--target=$pane`, quoted or not) is an address, not keystrokes; the
         exemption marker needs a reason.

      B. NEGATIVE CONTROL against the real thing: holder-volume.ps1 as it stood
         BEFORE the T1116 fix (read from git) is flagged on its flood wait, and
         the file as it stands now is not.

      C. The ratchet. The sites present on 2026-10-22 were read by the T1143
         sweep and are presence checks; they are a per-file count in
         `echo-marker-audit.baseline.json`. A file ABOVE its count fails, a
         file BELOW it fails naming `-UpdateBaseline`, and a new file with a
         finding fails - so a new wait has to split its marker or declare
         `# echo-marker: <reason>`.

      D. Scope: the sweep looked at the whole tree and says how much.

      T. Teeth, every run: a planted file under a swept tree is flagged AND
         fails the ratchet.

    `-UpdateBaseline` rewrites the baseline from the current sweep. Use it in
    the commit that removes a site, never to make a red run go green.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files, it does not build
    # or run anything.
    # isolation: none - the +send-keys verbs here are fixture text for the analyzer, nothing is executed
#>
[CmdletBinding()]
param(
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\EchoMarkerAudit.ps1')

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

$tmp = Join-Path $env:TEMP "ghoztty-t1143-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

$Root = Join-Path $Repo 'test\win32'
$BaselinePath = Join-Path $PSScriptRoot 'echo-marker-audit.baseline.json'

function Fixture([string]$Body) {
    return Get-EchoMarkerFindings -Path 'fixture.ps1' -Text ($Body -split "`n")
}
function KindsOf($Findings) { return (@($Findings | ForEach-Object { $_.Kind }) -join ',') }

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer, both directions'
# ===========================================================================

$f = Fixture @'
$head = 'T1DO'; $tail = "NE$PID"
$done = $head + $tail
$cmd = "powershell -Command 'x' + '$head' + '$tail'"
Run-CliArgs @('+send-keys', "--target=$pane", $cmd, 'Enter') "$tmp\k.txt" 12
Wait-PaneHas $tmp $pane 'flood' $done 90
'@
AssertEq "A1 the T1116 split form - halves typed, the joined marker waited for - is not a finding ($(KindsOf $f))" 0 $f.Count

$f = Fixture @'
& $Exe +send-keys --target=$pane "powershell -File $probe -Tag $tag" Enter
$seen = Wait-Text "PROBE_READY_$tag"
if ($tail -match "$tag\s*$") { }
'@
AssertEq "A2 a needle with literal text of its own is something the command PRINTS - not a finding ($(KindsOf $f))" 0 $f.Count

$f = Fixture @'
$marker = "T9MARK$PID" + 'Z'
Run-CliArgs @('+send-keys', "--target=$pane", 'echo', 'Space', $marker, 'Enter') "$tmp\k.txt" 12
Wait-PaneHas $tmp $pane 'm' $marker 20
'@
Assert "A3 a bare typed marker in a Wait-* is a wait finding ($(KindsOf $f))" ($f.Count -eq 1 -and $f[0].Kind -eq 'wait' -and $f[0].Var -eq 'marker')

$f = Fixture @'
Run-Cli "+send-keys --target=$paneId `"echo $mark`" Enter" "$tmp\sk.txt" 10
if ((Out-Text "$tmp\read.txt") -match [regex]::Escape($mark)) { return $true }
'@
Assert "A4 one +send-keys string types its payload and a -match on Escape(marker) is reported ($(KindsOf $f))" (
    $f.Count -eq 1 -and $f[0].Kind -eq 'match')

$f = Fixture @'
& $Exe +send-keys --target=$p1 "echo $m" Enter
$t = Tail $p1
Wait-Tail $p1 'x' 10
if ($t.Contains($m)) { }
'@
Assert "A5 an unquoted --target=`$p1 is an address, so only the .Contains on the marker is reported ($(KindsOf $f))" (
    $f.Count -eq 1 -and $f[0].Kind -eq 'contains' -and $f[0].Var -eq 'm')

$f = Fixture @'
$done = "T969DONE$PID" + "Z"
$floodCmd = "powershell -Command `"1..9 | % { 'F' }; 'x' + '$done'`""
[IO.File]::WriteAllText($floodFile, $floodCmd, [Text.Encoding]::ASCII)
Run-CliArgs @('+send-keys', "--target=$pane", "--keys-file=$floodFile", 'Enter') "$tmp\k.txt" 15
$floodDone = Wait-PaneHas $tmp $pane 'flood' $done 90
'@
Assert "A6 typing carries through a --keys-file write and an assignment - the T1116 shape ($(KindsOf $f))" (
    $f.Count -eq 1 -and $f[0].Var -eq 'done')

$f = Fixture @'
& $Exe +send-keys --target=$pane "echo $mark" Enter
# echo-marker: a liveness check - the shell echoing the line is the proof
Wait-PaneHas $tmp $pane 'm' $mark 20
'@
AssertEq 'A7 a stated reason on the line above exempts the site' 0 $f.Count

$f = Fixture @'
& $Exe +send-keys --target=$pane "echo $mark" Enter
# echo-marker:
Wait-PaneHas $tmp $pane 'm' $mark 20
'@
AssertEq 'A8 a marker with no reason exempts nothing' 1 $f.Count

$f = Fixture @'
$mark = 'X'
Wait-PaneHas $tmp $pane 'm' $mark 20
'@
AssertEq 'A9 a marker nobody typed is not a finding' 0 $f.Count

$f = Fixture 'function Broken( {'
Assert 'A10 a file that does not parse is reported, not skipped' ($f.Count -eq 1 -and $f[0].Kind -eq 'parse-error')

# ===========================================================================
Write-Host ''
Write-Host '== B: negative control - the real T1116 defect, before and after'
# ===========================================================================

$pre = @(& git -C $Repo show '870693615~1:test/win32/holder-volume.ps1' 2>$null)
Assert "B1 holder-volume.ps1 before the T1116 fix was read from git ($($pre.Count) lines)" ($pre.Count -gt 300)
$preHits = Get-EchoMarkerFindings -Path 'holder-volume.pre-T1116.ps1' -Text $pre
$preDone = @($preHits | Where-Object { $_.Var -eq 'done' })
Assert "B2 and its flood wait on the echoed end marker is flagged ($(@($preDone | ForEach-Object { 'L' + $_.Line }) -join ','))" (
    $preDone.Count -ge 1)
$now = @(Get-Content -LiteralPath (Join-Path $Root 'holder-volume.ps1'))
$nowDone = @(Get-EchoMarkerFindings -Path 'holder-volume.ps1' -Text $now | Where-Object { $_.Var -eq 'done' })
AssertEq 'B3 the file as it stands now (marker typed in halves) has no finding on it' 0 $nowDone.Count

# ===========================================================================
Write-Host ''
Write-Host '== C: the ratchet over test\win32'
# ===========================================================================

$all = Get-EchoMarkerSweep -Roots @($Root)
$hard = @($all | Where-Object { $_.Kind -ne 'parse-error' })
$current = @{}
foreach ($x in $hard) {
    $rel = Get-EchoMarkerRelativePath -Path $x.Path -Repo $Repo
    if (-not $current.ContainsKey($rel)) { $current[$rel] = 0 }
    $current[$rel] = $current[$rel] + 1
}

if ($UpdateBaseline) {
    $obj = [ordered]@{
        note      = 'Per-file counts of echo-marker-audit findings: waits for a marker the same script typed into the pane, where the echo of the typed line satisfies the wait. Every site here was read by the T1143 sweep (2026-10-22) and is a presence check (pane is live, scrollback came back), not proof a command ran. May only go DOWN; a new site splits its marker or carries # echo-marker: <reason>. See docs/design/windows-parity-tasks/T1143.md.'
        generated = (Get-Date -Format 'yyyy-MM-dd')
        files     = [ordered]@{}
    }
    foreach ($k in ($current.Keys | Sort-Object)) { $obj.files[$k] = $current[$k] }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $BaselinePath -Encoding ascii
    Write-Host "  baseline rewritten: $($current.Keys.Count) file(s)"
}

Assert 'C0 the baseline exists' (Test-Path -LiteralPath $BaselinePath)
$baseFiles = @{}
if (Test-Path -LiteralPath $BaselinePath) {
    $base = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    foreach ($p in $base.files.PSObject.Properties) { $baseFiles[$p.Name] = [int]$p.Value }
}

$cmp = Compare-EchoMarkerBaseline -Current $current -Baseline $baseFiles
foreach ($r in $cmp.Regressed) { Write-Host "      NEW: $r" -ForegroundColor Red }
if (@($cmp.Regressed).Count -gt 0) {
    foreach ($x in $hard) {
        $rel = Get-EchoMarkerRelativePath -Path $x.Path -Repo $Repo
        if (@($cmp.Regressed | Where-Object { $_.StartsWith("$rel ") }).Count -gt 0) {
            Write-Host "      $rel`:$($x.Line) $($x.Kind) `$$($x.Var): $($x.Detail)"
            Write-Host '        -> type the marker in halves the command joins, or say why the echo is enough: # echo-marker: <reason>'
        }
    }
}
AssertEq 'C1 no file has gained a wait its own echo can satisfy' 0 @($cmp.Regressed).Count
foreach ($i in $cmp.Improved) { Write-Host "      FIXED: $i" }
Assert 'C2 the baseline matches the tree (-UpdateBaseline in the commit that removes a site)' (
    @($cmp.Improved).Count -eq 0)
$parse = @($all | Where-Object { $_.Kind -eq 'parse-error' })
foreach ($x in $parse) { Write-Host "      $(Get-EchoMarkerRelativePath $x.Path $Repo):$($x.Line) $($x.Detail)" -ForegroundColor Red }
AssertEq 'C3 nothing in the tree fails to parse' 0 $parse.Count

# ===========================================================================
Write-Host ''
Write-Host '== D: scope'
# ===========================================================================

$ps1Count = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse).Count
$libCount = @(Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Filter *.ps1 -File).Count
Assert "D1 the sweep walked test\win32 ($ps1Count .ps1 files, $libCount of them in lib\)" (
    $ps1Count -ge 300 -and $libCount -ge 20)
$sendKeysFiles = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse |
    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '\+send-keys' }).Count
Assert "D2 and it had something to read: $sendKeysFiles script(s) type into a pane with +send-keys" ($sendKeysFiles -ge 50)

# ===========================================================================
Write-Host ''
Write-Host '== T: the teeth (C1 must be able to score red)'
# ===========================================================================

$fakeRoot = Join-Path $tmp 'test\win32'
New-Item -ItemType Directory -Force $fakeRoot | Out-Null
Set-Content -LiteralPath (Join-Path $fakeRoot 'planted-echo.ps1') -Encoding ascii -Value @(
    '$m = "PLANT$PID"',
    '& $Exe +send-keys --target=$pane "echo $m" Enter',
    'Wait-PaneHas $tmp $pane ''p'' $m 20')
$planted = Get-EchoMarkerSweep -Roots @($fakeRoot)
Assert 'T1 a typed-marker wait planted in a scratch file under a swept tree is flagged' (
    $planted.Count -eq 1 -and $planted[0].Kind -eq 'wait')
$withPlant = @{}
foreach ($k in $current.Keys) { $withPlant[$k] = $current[$k] }
$withPlant['test\win32\planted-echo.ps1'] = 1
$cmpT = Compare-EchoMarkerBaseline -Current $withPlant -Baseline $baseFiles
Assert 'T2 and the ratchet fails on it - a new file cannot arrive excused' (
    @($cmpT.Regressed | Where-Object { $_ -like 'test\win32\planted-echo.ps1 *' }).Count -eq 1)
$oneMore = @{}
foreach ($k in $current.Keys) { $oneMore[$k] = $current[$k] }
$anyKey = @($baseFiles.Keys | Sort-Object)[0]
if ($anyKey) { $oneMore[$anyKey] = $baseFiles[$anyKey] + 1 }
$cmpU = Compare-EchoMarkerBaseline -Current $oneMore -Baseline $baseFiles
Assert "T3 and one more site in a baselined file fails too ($anyKey)" (
    $anyKey -and @($cmpU.Regressed | Where-Object { $_ -like "$anyKey *" }).Count -eq 1)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard echo-marker -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-Host "  sweep: $ps1Count script(s); $($hard.Count) typed-marker wait(s) across $($current.Keys.Count) file(s) (baseline: presence checks read by T1143)"
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'ECHO MARKER AUDIT' -MinPass 20
