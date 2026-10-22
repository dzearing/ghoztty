<#
.SYNOPSIS
    T1032 acceptance - every point a test clicks at is in SCREEN coordinates,
    and the suite cannot gain a click that is not without this going red.

.DESCRIPTION
    THE DEFECT: Send-TestMouse takes a SCREEN point and converts it itself
    (T263). A caller that passes a CLIENT point - an offset from the window's
    own corner - clicks one client origin up and to the left of its aim, where
    nothing is. The post succeeds, the helper returns $true, and the test then
    fails against a feature that works. T318 paid for it with `-X $geo.KillX`
    and a Kill button that "opened nothing". T327 wrote the rule down in three
    places and audited every site by hand; writing it down was the only thing
    stopping it happening again. This is the check that makes it a rule.

    The analyzer is `lib\ClickCoordAudit.ps1` - read its header for the rule,
    how a value is resolved (scoped assignments, keyed literals, lib helpers),
    and how a local wrapper's parameter is audited at the wrapper's CALLERS.

    Sections:

      A. The analyzer against fixtures, BOTH directions: T318's exact shape is
         caught, client-only literals are caught, a geometry object's own
         client-space Left is caught; screen-derived forms, a parameter
         forwarded through a wrapper (and a wrapper of a wrapper) and a
         declared screen variable are not. Send-TestClickStorm's exemption is
         asserted, not implicit.

      B. The sweep over test\win32 (lib\ included) reports ZERO findings. T327
         established that every site is correct, so a finding here is either a
         new defect or a bug in the analyzer - never a baseline.

      C. Teeth on REAL code, every run: T318's fix reverted in its own file is
         caught; a wrapper's caller losing its origin term is caught at the
         wrapper call; the chooser geometry's client-space Left is caught; the
         one declared screen source, undeclared, is caught; a planted file
         under a swept tree is caught by the sweep itself.

      D. Scope: what the sweep read, the wrappers it had to see through, and
         that every named producer and declared screen variable still exists
         and is still needed (a stale declaration is a hole).

      E. NEGATIVE CONTROL: with every evidence source switched off, the same
         sweep must fail nearly every site. Without it, B's zero could be an
         analyzer that accepts everything.

    `-Only` / $env:GHOZTTY_HARNESS_FLOOR_ONLY scopes B and E to the changed
    scripts (T1969). A scoped run never stamps.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files, it does not build
    # or run anything.
    # isolation: none - a static audit over script TEXT; nothing here launches
    # ghoztty or runs a CLI verb.
#>
[CmdletBinding()]
param(
    # T1969: sweep only these changed top-level scripts in sections B and E.
    [string[]]$Only
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessScope.ps1')
. (Join-Path $PSScriptRoot 'lib\ClickCoordAudit.ps1')
$scope = Get-HarnessScope -Repo $Repo -Self $PSCommandPath -Only $Only

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

$tmp = Join-Path $env:TEMP "ghoztty-t1032-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

$Root = Join-Path $Repo 'test\win32'
$LibRoot = Join-Path $Root 'lib'

# The variables a script DECLARES screen-space: a point the analyzer cannot
# see the derivation of because it is parsed out of the app's own log. Each
# names the file, the variables and why. Kept here, not as markers in the
# file, so declaring one does not edit (and re-due) the harness that owns it.
$Declared = @(
    [pscustomobject]@{ File = 'test\win32\viewer-feedback-capture.ps1'; Vars = @('vsX', 'vsY')
        Why = 'the virtual-screen origin the app logs as `capture=begin bounds=X,Y` - screen space by definition' }
)
# Sites that are the defect ON PURPOSE - a negative control proving the client
# reading misses. Each names the file, the exact finding detail and why. Kept
# here so allowing one does not edit (and re-due) the harness that owns it.
$Allow = @(
    [pscustomobject]@{ File = 'test\win32\test-desktop-harness.ps1'; Detail = 'Get-TestMouseRoute -X 8'
        Why = 'the T327 negative control: the client offset read as screen must hit-test HTNOWHERE' }
    [pscustomobject]@{ File = 'test\win32\test-desktop-harness.ps1'; Detail = 'Get-TestMouseRoute -Y 8'
        Why = 'the same control, Y axis' }
)
function Test-Allowed($Finding) {
    $rel = Get-ClickCoordRelativePath -Path $Finding.Path -Repo $Repo
    foreach ($a in $Allow) { if ($a.File -ieq $rel -and $a.Detail -eq $Finding.Detail) { return $true } }
    return $false
}
$ScreenVars = @{}
foreach ($d in $Declared) { $ScreenVars[$d.File] = @($d.Vars) }

$ctx = Get-ClickCoordLibContext -LibRoot $LibRoot

function Fixture([string]$Body, $Context, [string[]]$Vars = @()) {
    if ($null -eq $Context) { $Context = New-ClickCoordContext }
    # Unrolled here and re-collected by the `@(...)` at every call site: the
    # analyzer returns its findings comma-wrapped, which an `@()` would nest.
    $found = Get-ClickCoordFindings -Path 'fixture.ps1' -Text ($Body -split "`n") -Context $Context -ScreenVars $Vars
    foreach ($x in $found) { $x }
}
function Show($Findings) { return (@($Findings | ForEach-Object { "$($_.Line):$($_.Kind):$($_.Detail)" }) -join '; ') }
function HardOf($Findings) { return @($Findings | Where-Object { (Get-ClickCoordHardKinds) -contains $_.Kind }) }

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer, both directions'
# ===========================================================================

$good = @'
$r = Get-TestWindowRect -Window $top -Client
[void](Send-TestMouse -Window $top -X ($r.Left + 20) -Y ($r.Top + 10))
$pt = Get-TestPixel -Shot $shot -X 1 -Y 1
[void](Send-TestMouse -Window $top -X $pt.X -Y $pt.Y)
$cx = [int](($r.Left + $r.Right) / 2); $cy = [Math]::Max($r.Top, 0) + 4
[void](Send-TestMouse -Window $top -X $cx -Y $cy)
$m = [pscustomobject]@{ ClientLeft = $r.Left; ClientTop = $r.Top }
[void](Send-TestMouse -Window $top -X ($m.ClientLeft + 5) -Y ($m.ClientTop + 5))
$p = @(($r.Left + 1), ($r.Top + 1))
[void](Send-TestMouse -Window $top -X $p[0] -Y $p[1])
foreach ($w in @(Get-TestChildWindows -Window $top)) { [void](Send-TestMouse -Window $top -X ($w.Left + 2) -Y ($w.Top + 2)) }
'@
$f = @(Fixture $good)
AssertEq "A1 rect origins, probes, arithmetic, keyed literals, indexes and loops are screen evidence ($(Show $f))" 0 $f.Count

$f = @(Fixture '[void](Send-TestMouse -Window $chooser -X $geo.KillX -Y $geo.KillY -Button left -Action click)')
Assert "A2 T318's exact shape - a property with no visible origin - is caught on both axes ($(Show $f))" (
    $f.Count -eq 2 -and @($f | Where-Object { $_.Kind -eq 'no-evidence' }).Count -eq 2)

$f = @(Fixture "`$geo = [pscustomobject]@{ KillX = 40; KillY = 12 }`n[void](Send-TestMouse -Window `$w -X `$geo.KillX -Y `$geo.KillY)")
AssertEq "A3 ...and so is the same property when a literal defines it as a client offset ($(Show $f))" 2 $f.Count

$f = @(Fixture '[void](Send-TestMouse -Window $w -X 10 -Y 20)')
AssertEq 'A4 a bare literal point is caught' 2 $f.Count

$geoObj = @'
function Get-Geo([double]$s) { $left = [int](16 * $s); return [pscustomobject]@{ Left = $left; Top = 8; KillX = $left + 40 } }
$geo = Get-Geo 1.0
[void](Send-TestMouse -Window $w -X ($geo.Left + 4) -Y ($geo.Top + 4))
'@
$f = @(Fixture $geoObj)
AssertEq "A5 a geometry object's own Left/Top (built by a literal, client-space) is NOT a rect origin ($(Show $f))" 2 $f.Count

$wrap = @'
function Click-At([IntPtr]$top, [int]$x, [int]$y) {
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Button left -Action click)
}
function Click-Center($top, $rect) { Click-At $top ([int](($rect.Left + $rect.Right) / 2)) ([int](($rect.Top + $rect.Bottom) / 2)) }
$r = Get-TestWindowRect -Window $top
Click-At $top ($r.Left + 5) ($r.Top + 5)
Click-At -top $top -y ($r.Top + 9) -x ($r.Left + 9)
Click-Center $top $r
'@
$f = @(Fixture $wrap)
AssertEq "A6 a parameter forwarded through a wrapper (positional, named, nested) is judged at its screen-derived callers ($(Show $f))" 0 $f.Count
$f = @(Fixture ($wrap + "`nClick-At `$top 40 12"))
Assert "A7 ...and a wrapper caller passing a client offset is caught AT THE CALLER, naming the wrapper ($(Show $f))" (
    $f.Count -eq 2 -and @($f | Where-Object { $_.Sink -eq 'Click-At' -and $_.Line -eq 9 }).Count -eq 2)

$scoped = @'
function Probe([int]$stripeTop) { for ($y = $stripeTop; $y -lt 9; $y++) { } }
$y = 7
[void](Send-TestMouse -Window $w -X 3 -Y $y)
'@
$f = @(Fixture $scoped)
Assert "A8 a loop variable inside one helper does not leak into another scope's same-named variable ($(Show $f))" (
    $f.Count -eq 2 -and @($f | Where-Object { $_.Sink -ne 'Send-TestMouse' }).Count -eq 0)

$f = @(Fixture '[void](Send-TestClickStorm -Targets $surfaces -Rounds 50 -X 10 -Y 10)')
AssertEq 'A9 Send-TestClickStorm is exempt: its client point is not a finding' 0 $f.Count
Assert 'A10 ...the exemption is exactly that one name, and it is not a sink' (
    (@(Get-ClickCoordExemptSinks) -join ',') -eq 'Send-TestClickStorm' -and
    -not (Get-ClickCoordBuiltinSinks).ContainsKey('send-testclickstorm'))
$tdText = [System.IO.File]::ReadAllText((Join-Path $LibRoot 'TestDesktop.ps1'))
Assert "A11 ...and its reason still holds: TestDesktop.ps1 documents its -X/-Y as CLIENT coordinates" (
    $tdText -match "THIS FUNCTION's -X/-Y are CLIENT coordinates" -and $tdText -match 'function Send-TestClickStorm')

$f = @(Fixture "# click-coord: a deliberate miss - the test asserts nothing is hit`n[void](Send-TestMouse -Window `$w -X 1 -Y 1)")
AssertEq 'A12 a stated reason on the line above exempts the site' 0 $f.Count
$f = @(Fixture "# click-coord:`n[void](Send-TestMouse -Window `$w -X 1 -Y 1)")
AssertEq 'A13 a marker with no reason exempts nothing' 2 $f.Count

$f = @(Fixture "`$click = { param(`$x, `$y) [void](Send-TestMouse -Window `$w -X `$x -Y `$y) }")
Assert "A14 a bare scriptblock's parameter is block-param, which is informational ($(Show $f))" (
    $f.Count -eq 2 -and @(HardOf $f).Count -eq 0 -and @($f | Where-Object { $_.Kind -eq 'block-param' }).Count -eq 2)

$parsed = "if (`$line -match 'bounds=(-?\d+),(-?\d+)') { `$script:vsX = [int]`$Matches[1]; `$script:vsY = [int]`$Matches[2] }`n[void](Send-TestMouse -Window `$w -X (`$script:vsX + 5) -Y (`$script:vsY + 5))"
AssertEq 'A15 a point parsed from text is caught when nobody declared it' 2 @(Fixture $parsed).Count
AssertEq 'A16 ...and clean when the script declares those variables screen-space' 0 @(Fixture $parsed -Vars @('vsX', 'vsY')).Count

$f = @(Fixture '[void](Send-TestMouse $w $w 10 20)')
AssertEq 'A17 positional binding is read the way PowerShell binds it (Window, Target, X, Y)' 2 $f.Count
$f = @(Fixture '$r = Get-TestWindowRect -Window $w; [void](Send-TestMouse -Window $w -X:($r.Left + 1) -Y:($r.Top + 1))')
AssertEq 'A18 the -X:value spelling is read too' 0 $f.Count

$f = @(Fixture "`$r = Get-TestWindowRect -Window `$w`n[void](Send-TestMouse -Window `$w -X (`$r.Left + 4) -Y 30)")
Assert "A19 one bad axis among good ones is the only finding, at its line and axis ($(Show $f))" (
    $f.Count -eq 1 -and $f[0].Param -eq 'Y' -and $f[0].Line -eq 2)

$f = @(Fixture "`$r = Get-TestWindowRect -Window `$w`n`$ok = Get-TestMouseRoute -Window `$w -X (`$r.Right - 20) -Y (`$r.Top + 8)`n`$bad = Get-TestMouseRoute -Window `$w -X 40 -Y 8")
Assert "A19b Get-TestMouseRoute is held to the same convention: the client point is caught, the screen one is not ($(Show $f))" (
    $f.Count -eq 2 -and @($f | Where-Object { $_.Sink -eq 'Get-TestMouseRoute' -and $_.Line -eq 3 }).Count -eq 2)

$f = @(Fixture '$x = 5 +')
AssertEq 'A20 a file that names no sink is not parsed at all (most of the suite; it has no site)' 0 $f.Count
$f = @(Fixture "[void](Send-TestMouse -Window `$w -X (1 +")
AssertEq 'A21 one that names a sink and fails to parse is a hard finding, not a silent pass' 'parse-error' (@($f)[0].Kind)

# Lib read-through: the real Get-TestChromeMetrics builds ClientLeft from a rect.
$f = @(Fixture "`$m = Get-TestChromeMetrics -Window `$top -StripVisible `$true`n[void](Send-TestMouse -Window `$top -X (`$m.ClientLeft + 12) -Y (`$m.ClientTop + 3))" $ctx)
AssertEq "A22 a lib helper's keyed result reads through to its own derivation (Get-TestChromeMetrics.ClientLeft) ($(Show $f))" 0 $f.Count
$f = @(Fixture "`$geo = Get-TestChooserRosterGeometry -Scale 1.0`n[void](Send-TestMouse -Window `$c -X `$geo.KillX -Y `$geo.KillY)" $ctx)
AssertEq "A23 ...and the REAL roster geometry's KillX (client-space) is caught - T318 against the lib as it stands ($(Show $f))" 2 $f.Count

# ===========================================================================
Write-Host ''
Write-Host '== B: the sweep over test\win32 must be clean'
# ===========================================================================

Write-Host (Format-HarnessScopeLine $scope)
$roots = @($Root)
if ($scope.Scoped) { $roots = @($scope.Files) }
$hits = @{}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$all = Get-ClickCoordSweep -Roots $roots -Context $ctx -ScreenVars $ScreenVars -Repo $Repo -ScreenVarHits $hits
$sweepSites = $script:ClickCoordSweepSites
$sweepFiles = $script:ClickCoordSweepFiles
$sweepWrappers = @($script:ClickCoordSweepWrappers)
$hard = @(HardOf $all | Where-Object { -not (Test-Allowed $_) })
$allowedHits = @(HardOf $all | Where-Object { Test-Allowed $_ })
$info = @($all | Where-Object { $_.Kind -eq 'block-param' })
foreach ($x in $hard) {
    Write-Host "      $(Get-ClickCoordRelativePath $x.Path $Repo):$($x.Line) $($x.Kind): $($x.Detail)" -ForegroundColor Red
}
if ($hard.Count -gt 0) {
    Write-Host '      -> offset the point by a screen rect (Get-TestWindowRect [-Client]) - see Send-TestMouse in lib\TestDesktop.ps1' -ForegroundColor Red
}
AssertEq "B1 no click in the suite lacks screen evidence ($sweepSites coordinate argument(s) judged, $([int]$sw.Elapsed.TotalSeconds)s)" 0 $hard.Count
AssertEq 'B2 nothing in the swept tree fails to parse' 0 @($all | Where-Object { $_.Kind -eq 'parse-error' }).Count
if (-not $scope.Scoped) {
    AssertEq 'B3 every allow-list entry still matches a site (a stale entry is a hole)' $Allow.Count $allowedHits.Count
}

# ===========================================================================
Write-Host ''
Write-Host '== C: teeth on real code'
# ===========================================================================

function Get-Mutated([string]$Rel, [string]$From, [string]$To) {
    $path = Join-Path $Repo $Rel
    $text = [System.IO.File]::ReadAllLines($path)
    $joined = $text -join "`n"
    $hit = $joined.Contains($From)
    return [pscustomobject]@{ Path = $path; Hit = $hit; Lines = (($joined.Replace($From, $To)) -split "`n"); Orig = $text }
}
function Count-Hard($Path, $Lines, $Vars = @()) {
    return @(HardOf (Get-ClickCoordFindings -Path $Path -Text $Lines -Context $ctx -ScreenVars $Vars))
}

# C1: T318, un-fixed in the file that carries the fix.
$mu = Get-Mutated 'test\win32\chooser-sessions.ps1' '-X ($cr.Left + $geo.KillX)' '-X ($geo.KillX)'
Assert 'C1 chooser-sessions.ps1 still carries the T318 fix this reverts' $mu.Hit
$before = @(Count-Hard $mu.Path $mu.Orig)
$after = @(Count-Hard $mu.Path $mu.Lines)
Assert "C2 ...and with the origin term removed, the Kill click is caught on its X axis ($(Show $after))" (
    $before.Count -eq 0 -and $after.Count -eq 1 -and $after[0].Param -eq 'X' -and $after[0].Detail -like '*$geo.KillX*')

# C3: the wrapper path, in real code: Open-TabMenu's callers in tab-color.ps1.
$mu = Get-Mutated 'test\win32\tab-color.ps1' '$tab0x = [int]($m.ClientLeft + $tabs[0].CenterX)' '$tab0x = [int]($tabs[0].CenterX)'
Assert 'C3 tab-color.ps1 still derives its tab x from the client origin' $mu.Hit
$after = @(Count-Hard $mu.Path $mu.Lines)
Assert "C4 ...and without it, the miss is caught at the WRAPPER's callers (Open-TabMenu), not inside it ($(Show $after))" (
    $after.Count -ge 1 -and @($after | Where-Object { $_.Sink -ne 'Open-TabMenu' }).Count -eq 0)

# C5: the chooser roster geometry's Left is client-space; using it as an origin is caught.
$mu = Get-Mutated 'test\win32\chooser-sessions.ps1' '-X ($cr.Left + $geo.KillX)' '-X ($geo.Left + $geo.KillX)'
$after = @(Count-Hard $mu.Path $mu.Lines)
Assert "C5 swapping the window rect for the roster geometry's own Left is caught - a Left is not evidence by name alone ($(Show $after))" (
    $mu.Hit -and $after.Count -eq 1 -and $after[0].Param -eq 'X')

# C6: the declared screen source is load-bearing.
$vfc = Join-Path $Repo 'test\win32\viewer-feedback-capture.ps1'
$vfcText = [System.IO.File]::ReadAllLines($vfc)
AssertEq 'C6 viewer-feedback-capture.ps1 is clean WITH its declaration' 0 @(Count-Hard $vfc $vfcText @('vsX', 'vsY')).Count
Assert 'C7 ...and caught without it - so the declaration decides something' (@(Count-Hard $vfc $vfcText).Count -ge 1)

# C8: the sweep itself (not only the per-file call) sees a planted file.
$fakeRoot = Join-Path $tmp 'test\win32'
New-Item -ItemType Directory -Force $fakeRoot | Out-Null
[System.IO.File]::WriteAllLines((Join-Path $fakeRoot 'planted-click.ps1'), [string[]]@(
        '$geo = Get-TestChooserRosterGeometry -Scale 1.0',
        '[void](Send-TestMouse -Window $chooser -X $geo.KillX -Y $geo.KillY -Button left -Action click)'))
$planted = @(HardOf (Get-ClickCoordSweep -Roots @($fakeRoot) -Context $ctx))
AssertEq 'C8 a T318-shaped click planted under a swept tree is caught by the sweep' 2 $planted.Count

# ===========================================================================
Write-Host ''
Write-Host '== D: scope, wrappers and declarations'
# ===========================================================================

if ($scope.Scoped) {
    Assert "D1 the scoped sweep read every changed script ($sweepFiles of $(@($scope.Rel).Count))" (
        $sweepFiles -ge 1 -and $sweepFiles -eq @($scope.Rel).Count)
} else {
    Assert "D1 the sweep walked test\win32 ($sweepFiles .ps1 file(s)) and judged $sweepSites coordinate argument(s)" (
        $sweepFiles -ge 300 -and $sweepSites -ge 600)
    # T327 counted 147 Send-TestMouse call sites by hand; the sweep sees the
    # wrappers half the suite clicks through, so it judges far more arguments.
    Assert "D2 ...seeing through $($sweepWrappers.Count) local wrapper(s) to their callers" ($sweepWrappers.Count -ge 15)
    foreach ($d in $Declared) {
        foreach ($v in $d.Vars) {
            Assert "D3 the declaration $($d.File) `$$v still decides a site (a stale one is a hole)" (
                $hits.ContainsKey("$($d.File)|$($v.ToLowerInvariant())"))
        }
    }
}
$named = Get-ClickCoordNamedProducers
$missing = @($named.Keys | Where-Object { -not $ctx.LibFunctions.ContainsKey($_.ToLowerInvariant()) })
AssertEq "D4 every named screen producer still exists in lib\ ($($named.Count) named)" '' ($missing -join ', ')
foreach ($d in $Declared) {
    Assert "D5 the declared file $($d.File) exists" (Test-Path -LiteralPath (Join-Path $Repo $d.File))
}

# ===========================================================================
Write-Host ''
Write-Host '== E: negative control - with the evidence switched off, the sweep fails'
# ===========================================================================

# Same files, same sinks, same wrappers; only the evidence vocabulary is gone.
# A site that still passes is either forwarded to its wrapper's callers (which
# then fail) or proof that something other than evidence is letting it through.
$saveOrigin = $script:CLICK_ORIGIN_MEMBERS
$savePattern = $script:CLICK_PRODUCER_PATTERN
$blindCtx = New-ClickCoordContext
$blindCtx.Sinks = $ctx.Sinks; $blindCtx.LibFunctions = $ctx.LibFunctions
try {
    $script:CLICK_ORIGIN_MEMBERS = @('__no_origin__')
    $script:CLICK_PRODUCER_PATTERN = '^__no_producer__$'
    $blind = Get-ClickCoordSweep -Roots $roots -Context $blindCtx -Repo $Repo
    $blindSites = $script:ClickCoordSweepSites
    $blindForwarded = $script:ClickCoordSweepForwarded
} finally {
    $script:CLICK_ORIGIN_MEMBERS = $saveOrigin
    $script:CLICK_PRODUCER_PATTERN = $savePattern
}
$blindFailed = @($blind | Where-Object { $_.Kind -in @('no-evidence', 'block-param') }).Count
# A site inside a wrapper's body is judged at the wrapper's callers, so it
# never fails itself and is not in the denominator. Counting it held a scoped
# sweep to a whole-tree share: pane-stack-strip.ps1 alone, 6 of its 20 sites
# in one wrapper, read 70% blind with every judged site failing (T2134).
$blindJudged = $blindSites - $blindForwarded
if ($blindJudged -gt 0) {
    $ratio = [math]::Round(100.0 * $blindFailed / $blindJudged)
    Assert "E1 blind, $blindFailed of $blindJudged judged coordinate argument(s) fail ($ratio%; $blindForwarded more sit inside wrappers)" ($ratio -ge 80)
} elseif ($scope.Scoped) {
    Write-Host '      (the changed scripts click nothing - nothing to blind)'
    Assert 'E1 blind, the changed scripts still judge no site' ($sweepSites -eq 0)
} else {
    Assert 'E1 the blind sweep judged any site at all' $false
}
Assert 'E2 the evidence vocabulary was restored after the control' (
    $script:CLICK_ORIGIN_MEMBERS -contains 'left' -and $script:CLICK_PRODUCER_PATTERN -match 'Get-TestWindowRect')

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green WHOLE run records the covered files - a scoped one read
# only the changed scripts (T1969).
if ($script:fail -eq 0 -and -not $scope.Scoped) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard click-coord -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-Host "  sweep: $sweepFiles script(s), $sweepSites coordinate argument(s), $($sweepWrappers.Count) wrapper(s); $($hard.Count) finding(s)"
Write-Host "  block-param (informational - a scriptblock's caller cannot be named): $($info.Count)"
foreach ($x in $info) { Write-Host "      $(Get-ClickCoordRelativePath $x.Path $Repo):$($x.Line) $($x.Detail)" }
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label ('CLICK COORD AUDIT' + (Get-HarnessScopeLabel $scope)) -MinPass 30
