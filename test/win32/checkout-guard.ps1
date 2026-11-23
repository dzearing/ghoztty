# T1996 acceptance: test\win32\lib\CheckoutGuard.ps1 - an acceptance script run
# by hand from one checkout must not grade another checkout's build.
#
#   A. The literal the guard checks is the runner's literal
#      ($script:ApRepoLiteral in scripts\lib\AcceptanceParallel.ps1).
#   B. A lane-B-shaped FIXTURE checkout (a temp dir holding a copy of the real
#      test\win32\lib, guard included) runs fixture scripts BARE, the way a guard-due `run:` line does:
#        B1/B2 a literal -Exe default is REFUSED through BuildMode and through
#              TestScore, before the body runs, naming the re-rooted value;
#        B3    the same script with -Exe re-rooted runs;
#        B4    the Test-Path fallback is refused while the fixture has no
#              build, and runs once it has one;
#        B5    GHOZTTY_TEST_FOREIGN_CHECKOUT=1 runs it and says so;
#        B6    a `# @repo-literal-fixture` parameter is data, not refused;
#        B7    a caller outside <checkout>\test\win32 is not an acceptance run.
#   C. The pure function: the literal checkout itself is never refused, and a
#      sibling sharing the prefix (D:\git\ghoztty-b) is not the literal.
#   D. Wiring: both libraries load the guard; suite-run re-roots in a foreign
#      checkout; guard-due prints the runner form there. D4 (T2007): every
#      script that spells the literal checkout loads the guard, directly or
#      through a library that does - with a probe proving the audit flags one
#      that does not.
#   E. The agent half (T2006), run bare from the same fixture checkout:
#        E1 a script with no lineage set gets its own (aph-<pid>) and its
#           autostart teardown armed;
#        E2 a lineage-hostile script is REFUSED before its body runs;
#        E3 ...unless it declares `# @lineage-safe - <why>`;
#        E4 a lineage that is already set (the runner's) is left alone;
#        E5 GHOZTTY_TEST_FOREIGN_CHECKOUT=1 skips both halves;
#        E6 the literal checkout mints nothing (lane A unchanged);
#        E7 the guard's hostile patterns are the runner's, and the two agree
#           about every real script in test\win32.
#
#   -NegativeControl strips the guard's auto-run from the fixture copy, so B1,
#   B2, the refused half of B4, B5, E1, E2 and E3 MUST fail - proof this harness
#   can go red.
#
# Non-interactive. Launches nothing but child powershell processes; the fixture
# scripts print a marker instead of starting an app.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:fail = 0
$script:pass = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" }
}

$lit = 'D:\git\ghoztty'  # @repo-literal-fixture
$fx = Join-Path $env:TEMP ("cg-fixture-{0}" -f $PID)

function Invoke-Fixture([string]$path, [string[]]$extra = @(), [hashtable]$envs = @{}) {
    $saved = @{}
    foreach ($k in $envs.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
    try {
        $global:LASTEXITCODE = 0
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @extra 2>&1 | ForEach-Object { $_.ToString() } | Out-String
        return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

try {
Write-Host '--- A. one literal ---'
$apText = [IO.File]::ReadAllText((Join-Path $repo 'scripts\lib\AcceptanceParallel.ps1'))
$cgText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\CheckoutGuard.ps1'))
$apLit = [regex]::Match($apText, "(?m)^\`$script:ApRepoLiteral\s*=\s*'([^']+)'").Groups[1].Value
$cgLit = [regex]::Match($cgText, "(?m)^\`$script:CgRepoLiteral\s*=\s*'([^']+)'").Groups[1].Value
Assert ($apLit -and $apLit -eq $cgLit) "the guard's literal ($cgLit) is the runner's ($apLit)"

Write-Host '--- B. a lane-B-shaped checkout, run bare ---'
$lib = Join-Path $fx 'test\win32\lib'
$null = New-Item -ItemType Directory -Force -Path $lib, (Join-Path $fx 'scripts')
# The whole library dir: BuildMode and TestScore load their own neighbours.
Copy-Item -Path (Join-Path $PSScriptRoot 'lib\*') -Destination $lib -Recurse -Force
if ($NegativeControl) {
    $g = Join-Path $lib 'CheckoutGuard.ps1'
    $t = [IO.File]::ReadAllText($g) -replace '(?m)^\$script:CgMintedLineage = Assert-TestCheckout\s*$', '$script:CgMintedLineage = $null # (negative control: auto-run removed)'
    [IO.File]::WriteAllText($g, $t)
}
$fxExe = Join-Path $fx 'zig-out\bin\ghoztty.exe'

$viaBuildMode = Join-Path $fx 'test\win32\fx-buildmode.ps1'
[IO.File]::WriteAllText($viaBuildMode, @'
param([string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Write-Host "BODY-RAN exe=$Exe"
'@)
$viaScore = Join-Path $fx 'test\win32\fx-score.ps1'
[IO.File]::WriteAllText($viaScore, @'
param([string]$Repo = 'D:\git\ghoztty', [string]$Root = 'x')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Write-Host "BODY-RAN repo=$Repo"
'@)
$viaFallback = Join-Path $fx 'test\win32\fx-fallback.ps1'
[IO.File]::WriteAllText($viaFallback, @'
param([string]$ExePath)
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
$exe = $ExePath
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
Write-Host "BODY-RAN exe=$exe"
'@)
$viaMarker = Join-Path $fx 'test\win32\fx-marker.ps1'
[IO.File]::WriteAllText($viaMarker, @'
param(
    [string]$RepoLiteral = 'D:\git\ghoztty'  # @repo-literal-fixture
)
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Write-Host "BODY-RAN literal=$RepoLiteral"
'@)
$viaTool = Join-Path $fx 'scripts\fx-tool.ps1'
[IO.File]::WriteAllText($viaTool, @'
param([string]$Repo = 'D:\git\ghoztty')
. (Join-Path $PSScriptRoot '..\test\win32\lib\TestScore.ps1')
Write-Host "BODY-RAN tool"
'@)

$b1 = Invoke-Fixture $viaBuildMode
Assert (($b1.Out -match 'REFUSED') -and ($b1.Out -notmatch 'BODY-RAN') -and $b1.Exit -ne 0) "B1 a literal -Exe default is refused through BuildMode before the body runs (exit $($b1.Exit))"
Assert ($b1.Out.Contains("pass -Exe '$fxExe'")) 'B1 the refusal names the re-rooted -Exe to pass instead'
Assert ($b1.Out -match 'acceptance-parallel\.ps1 run -Scripts fx-buildmode\.ps1') 'B1 the refusal names the runner command'

$b2 = Invoke-Fixture $viaScore
Assert (($b2.Out -match 'REFUSED') -and ($b2.Out -notmatch 'BODY-RAN') -and $b2.Exit -ne 0) "B2 a literal -Repo default is refused through TestScore (exit $($b2.Exit))"
Assert ($b2.Out -notmatch '-Root is') 'B2 a caller parameter named like a guard local (-Root) is read from the caller, not shadowed'

$b3 = Invoke-Fixture $viaBuildMode @('-Exe', $fxExe)
Assert (($b3.Out -match 'BODY-RAN') -and $b3.Exit -eq 0) 'B3 the same script with -Exe re-rooted at its own checkout runs'

$b4a = Invoke-Fixture $viaFallback @('-ExePath', $fxExe)
Assert (($b4a.Out -match 'build this checkout first') -and ($b4a.Out -notmatch 'BODY-RAN')) 'B4 the Test-Path fallback is refused while this checkout has no build'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $fxExe)
[IO.File]::WriteAllText($fxExe, '')
$b4b = Invoke-Fixture $viaFallback @('-ExePath', $fxExe)
Assert (($b4b.Out -match "BODY-RAN exe=$([regex]::Escape($fxExe))") -and $b4b.Exit -eq 0) 'B4 ...and runs its own build once it has one'

$b5 = Invoke-Fixture $viaBuildMode @() @{ GHOZTTY_TEST_FOREIGN_CHECKOUT = '1' }
Assert (($b5.Out -match 'BODY-RAN') -and ($b5.Out -match '\[checkout-guard\] GHOZTTY_TEST_FOREIGN_CHECKOUT=1')) 'B5 the hatch runs it and says it was used'

$b6 = Invoke-Fixture $viaMarker
Assert (($b6.Out -match 'BODY-RAN') -and $b6.Exit -eq 0) 'B6 a parameter marked @repo-literal-fixture is data, not refused'

$b7 = Invoke-Fixture $viaTool
Assert (($b7.Out -match 'BODY-RAN tool') -and $b7.Exit -eq 0) 'B7 a caller outside <checkout>\test\win32 is not refused'

Write-Host '--- C. the pure function ---'
$lookup = { param($n) if ($n -eq 'Exe') { "$lit\zig-out\bin\ghoztty.exe" } elseif ($n -eq 'Repo') { "$lit-b" } else { $null } }
$same = @(Get-ForeignCheckoutFindings -ScriptPath $viaBuildMode -Checkout $lit -Lookup $lookup -Literal $lit)
Assert ($same.Count -eq 0) 'C1 in the literal checkout itself nothing is refused'
$sib = @(Get-ForeignCheckoutFindings -ScriptPath $viaScore -Checkout "$lit-b" -Lookup $lookup -Literal $lit)
Assert ($sib.Count -eq 0) "C2 $lit-b shares the prefix but is not the literal"
$foreign = @(Get-ForeignCheckoutFindings -ScriptPath $viaBuildMode -Checkout "$lit-b" -Lookup $lookup -Literal $lit)
Assert ($foreign.Count -eq 1 -and $foreign[0].Contains("pass -Exe '$lit-b\zig-out\bin\ghoztty.exe'")) 'C3 from the sibling, the literal -Exe is the one finding, re-rooted'

Write-Host '--- D. wiring ---'
$bm = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\BuildMode.ps1'))
$ts = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\TestScore.ps1'))
Assert ($bm.Contains("'CheckoutGuard.ps1'") -and $ts.Contains("'CheckoutGuard.ps1'")) 'D1 BuildMode.ps1 and TestScore.ps1 both load the guard'
$sr = [IO.File]::ReadAllText((Join-Path $repo 'scripts\suite-run.ps1'))
Assert ($sr -match 'Get-AcceptanceScriptClass' -and $sr -match 'T1996') 'D2 suite-run re-roots a script''s literal parameters in a foreign checkout'
$gd = [IO.File]::ReadAllText((Join-Path $repo 'scripts\guard-due.ps1'))
Assert ($gd -match 'acceptance-parallel\.ps1 run -Scripts' -and $gd -match 'T1996') 'D3 guard-due prints the runner form of run: in a foreign checkout'

# D4 (T2007): the guard only sees a script that loads it. Every script in
# test\win32 that spells the literal checkout outside a comment or a
# `# @repo-literal-fixture` line must dot-source the guard, directly or
# through a library that does (transitively: BuildMode, TestScore,
# CleanSlate, TestDesktop, ...). Three scripts once loaded none and so ran
# lane A's files from lane B unrefused.
function Get-CgLoadRegex([string]$name) {
    "(?m)^[^#\r\n]*(?<![\w$])\.\s+[^\r\n]*[\\/'""]$([regex]::Escape($name))\.ps1['""]"
}
function Get-CgGuardLibs([string]$libDir) {
    $text = @{}
    foreach ($l in @(Get-ChildItem -LiteralPath $libDir -Filter '*.ps1' -File)) { $text[$l.BaseName] = [IO.File]::ReadAllText($l.FullName) }
    $reach = @{ 'CheckoutGuard' = $true }
    do {
        $grew = $false
        foreach ($k in @($text.Keys)) {
            if ($reach.ContainsKey($k)) { continue }
            foreach ($r in @($reach.Keys)) {
                if ($text[$k] -match (Get-CgLoadRegex $r)) { $reach[$k] = $true; $grew = $true; break }
            }
        }
    } while ($grew)
    @($reach.Keys)
}
function Test-CgScriptUnguarded([string]$text, [string[]]$guardLibs) {
    $litRx = '(?i)' + [regex]::Escape($lit) + '(?![\w-])'
    $spells = @($text -split "\r?\n" | Where-Object { $_ -match $litRx -and $_ -notmatch '@repo-literal-fixture' -and $_ -notmatch '^\s*#' }).Count -gt 0
    if (-not $spells) { return $false }
    foreach ($g in $guardLibs) { if ($text -match (Get-CgLoadRegex $g)) { return $false } }
    $true
}
$guardLibs = @(Get-CgGuardLibs (Join-Path $PSScriptRoot 'lib'))
Assert (($guardLibs -contains 'BuildMode') -and ($guardLibs -contains 'TestScore')) "D4 the guard is reached through $($guardLibs.Count) libraries, BuildMode and TestScore among them"
$probeBare = "param([string]`$Repo = '$lit')`n`$x = Get-Content (Join-Path `$Repo 'a.txt')"
$probeLoaded = "param([string]`$Repo = '$lit')`n. (Join-Path `$PSScriptRoot 'lib\TestScore.ps1')"
Assert ((Test-CgScriptUnguarded $probeBare $guardLibs) -and -not (Test-CgScriptUnguarded $probeLoaded $guardLibs)) 'D4 the audit flags a literal -Repo default that loads no guard library, and passes the same script once it does'
$unguarded = @()
$nSpell = 0
foreach ($f in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
    $t = [IO.File]::ReadAllText($f.FullName)
    if (Test-CgScriptUnguarded $t @('__none__')) { $nSpell++ }
    if (Test-CgScriptUnguarded $t $guardLibs) { $unguarded += $f.Name }
}
Assert ($nSpell -gt 0 -and $unguarded.Count -eq 0) "D4 every one of the $nSpell scripts that spell $lit loads the guard$(if ($unguarded.Count) { ' - not: ' + ($unguarded -join ', ') })"

Write-Host '--- E. the agent half (T2006) ---'
$noLineage = @{ GHOZTTY_AGENT_INSTANCE = $null; GHOZTTY_TEST_FOREIGN_CHECKOUT = $null }
$viaLineage = Join-Path $fx 'test\win32\fx-lineage.ps1'
[IO.File]::WriteAllText($viaLineage, @'
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
$armed = if ($env:GHOZTTY_AGENT_INSTANCE) { @($global:GhozttyHarnessRunInstances | Where-Object { $_ -and $_ -eq $env:GHOZTTY_AGENT_INSTANCE }).Count } else { 0 }
Write-Host "BODY-RAN lineage=[$env:GHOZTTY_AGENT_INSTANCE] armed=$armed"
'@)
$viaHostile = Join-Path $fx 'test\win32\fx-hostile.ps1'
[IO.File]::WriteAllText($viaHostile, @'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$state = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
Write-Host "BODY-RAN state=$state"
'@)
$viaSafe = Join-Path $fx 'test\win32\fx-safe.ps1'
[IO.File]::WriteAllText($viaSafe, @'
# @lineage-safe - the name below is fixture text; this script starts no agent
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$text = 'local-agent-debug'
Write-Host "BODY-RAN safe lineage=[$env:GHOZTTY_AGENT_INSTANCE]"
'@)

$e1 = Invoke-Fixture $viaLineage @() $noLineage
$e1Inst = [regex]::Match($e1.Out, 'lineage=\[(aph-\d+)\]').Groups[1].Value
Assert (($e1.Exit -eq 0) -and $e1Inst) "E1 a bare run with no lineage gets its own (lineage=[$e1Inst])"
Assert ($e1Inst -and $e1.Out -match 'armed=1') 'E1 ...with its autostart teardown armed'
Assert ($e1.Out -match "\[checkout-guard\].*GHOZTTY_AGENT_INSTANCE=$([regex]::Escape($e1Inst))") 'E1 ...and says so'

$e2 = Invoke-Fixture $viaHostile @() $noLineage
Assert (($e2.Out -match 'REFUSED') -and ($e2.Out -notmatch 'BODY-RAN') -and $e2.Exit -ne 0) "E2 a lineage-hostile script is refused before its body runs (exit $($e2.Exit))"
Assert ($e2.Out -match 'unscoped agent state dir') 'E2 the refusal names the reason'

$e3 = Invoke-Fixture $viaSafe @() $noLineage
Assert (($e3.Out -match 'BODY-RAN safe lineage=\[aph-\d+\]') -and $e3.Exit -eq 0) 'E3 a declared @lineage-safe script runs, under its own lineage'

$e4 = Invoke-Fixture $viaLineage @() @{ GHOZTTY_AGENT_INSTANCE = 'apm-4242'; GHOZTTY_TEST_FOREIGN_CHECKOUT = $null }
Assert (($e4.Out -match 'BODY-RAN lineage=\[apm-4242\] armed=0') -and $e4.Exit -eq 0) 'E4 a lineage already set (the runner''s) is left alone'

$e5 = Invoke-Fixture $viaHostile @() @{ GHOZTTY_AGENT_INSTANCE = $null; GHOZTTY_TEST_FOREIGN_CHECKOUT = '1' }
Assert (($e5.Out -match 'BODY-RAN') -and $e5.Exit -eq 0) 'E5 GHOZTTY_TEST_FOREIGN_CHECKOUT=1 skips the agent half too'

$e6 = Get-CheckoutLineageDecision -ScriptPath $viaHostile -Checkout $lit -Literal $lit
$e6b = Get-CheckoutLineageDecision -ScriptPath $viaLineage -Checkout $lit -Literal $lit
Assert ($e6.Action -eq 'none' -and $e6b.Action -eq 'none' -and -not $e6b.Instance) 'E6 in the literal checkout nothing is minted or refused (lane A unchanged)'
$e6c = Get-CheckoutLineageDecision -ScriptPath $viaLineage -Checkout "$lit-b" -Literal $lit -ProcessId 77
Assert ($e6c.Action -eq 'mint' -and $e6c.Instance -eq 'aph-77') "E6 from $lit-b the same script mints aph-<pid>"

. (Join-Path $repo 'scripts\lib\AcceptanceParallel.ps1')
$apKeys = @($script:ApMainPatterns.Keys) -join ' | '
$cgKeys = @($script:CgLineageHostilePatterns.Keys) -join ' | '
Assert ($apKeys -eq $cgKeys) 'E7 the guard''s lineage-hostile patterns are the runner''s ApMainPatterns'
$disagree = @()
$nHostile = 0
foreach ($f in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
    $runner = (@((Get-AcceptanceScriptClass -Path $f.FullName).Unscoped).Count -gt 0)
    $guard = (@(Get-LineageHostileReasons -ScriptPath $f.FullName).Count -gt 0)
    if ($guard) { $nHostile++ }
    if ($runner -ne $guard) { $disagree += "$($f.Name) runner=$runner guard=$guard" }
}
Assert ($disagree.Count -eq 0) "E7 the guard and the runner agree on every script ($nHostile hostile)$(if ($disagree.Count) { ': ' + ($disagree -join '; ') })"

if ($NegativeControl) { Write-Host '(negative control: B1, B2, B4, B5, E1, E2 and E3 above must FAIL)' }

Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if (Test-Path -LiteralPath $fx) { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard checkout-guard -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'CHECKOUT-GUARD' -MinPass 30
