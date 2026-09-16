<#
.SYNOPSIS
    T272 + T276 acceptance - an acceptance script that can only run on the INPUT
    DESKTOP must be declared interactive-by-design, and the declaration must be
    true.

.DESCRIPTION
    Four sections:

      A. The declaration parser (`lib\ForegroundAudit.ps1`) against fixtures:
         a well-formed marker is read, a malformed one is named rather than
         silently dropped, and prose around the markers is ignored.

      B. The detector, both directions. The interesting half is what is NOT a
         finding: two thirds of this suite MENTIONS `SendInput` in a header
         explaining that it is dead on a background desktop, and reading those
         as violations would push 22 innocent scripts onto the exception list -
         the same rot from the other direction.

      D. The screen-DC family (T276) - the sites that need the input desktop
         while grabbing nothing. T272's rule was "takes the foreground", so its
         sweep could not see `color-contrast.ps1`, which read the composited
         screen with `GetDC(NULL)` + `GetPixel`. The load-bearing negative here
         is `GetDC($hwnd)`: a WINDOW DC is fine off the desktop, so a P/Invoke
         declaration must never trip the rule - only a call site naming the
         screen does.

      E. The scope (T780) - `lib\` is swept too, because a harness helper that
         reads the composited screen would make every script calling it
         input-desktop-only while the sweep read none of them. A helper states
         its intent on one `# input-desktop-helper:` line with a reason, which
         is the exemption; outside `lib\` that marker means nothing.

      C. The sweep over `test\win32\*.ps1` and `test\win32\lib\*.ps1`: every
         site is declared or marked, and every declaration still names a script
         that needs the input desktop.

    `-TeethCheck` proves the section-C assertion can fail: it writes three real
    violators into the swept tree - a live `SendInput`, a live screen-DC read,
    and an unmarked `lib\` helper, all on no list - and requires the sweep to
    find each. Run it after any change to the analyzer.

.NOTES
    # persistence: launches no GUI - this scores scripts, it does not run them.

    # foreground-audit: this script's fixtures are string literals holding the
    # very P/Invokes it detects (`[Drv]::SendInput(...)`), so it NAMES every
    # watched API without calling one. It takes no foreground: it launches
    # nothing, and section C's planted violator is deleted in a finally block.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Suite = Join-Path $Repo 'test\win32'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ForegroundAudit.ps1')

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

# ===========================================================================
Write-Host ''
Write-Host '== A: the declaration list, parsed out of the harness header'
# ===========================================================================

$declFixture = @(
    '# ESCAPE HATCH: -Interactive skips the desktop entirely.'
    '#'
    '# @input-desktop-exception: alpha.ps1 -- (T1) the injection timing IS the measurement.'
    '# @input-desktop-exception: beta.ps1 -- (T2) the subject is a real right-click.'
    '# prose about SendInput being dead here, which is not a declaration.'
)
$d = @(Get-ForegroundAuditDeclarations -Text $declFixture)
AssertEq 'A1 both marker lines are read' 2 @($d | Where-Object { -not $_.Malformed }).Count
AssertEq 'A2 the script name is captured' 'alpha.ps1' $d[0].Script
AssertEq 'A3 the reason is captured whole' '(T1) the injection timing IS the measurement.' $d[0].Reason
AssertEq 'A4 the marker line number is reported' 3 $d[0].Line

$badFixture = @(
    '# @input-desktop-exception: gamma.ps1'
    '# @input-desktop-exception: -- a reason with no script'
)
$bad = @(Get-ForegroundAuditDeclarations -Text $badFixture)
AssertEq 'A5 a declaration with no reason is malformed, not dropped' 2 @($bad | Where-Object { $_.Malformed }).Count

# The harness header is the real list; if this is empty the whole check is off.
$live = @(Get-ForegroundAuditDeclarations -Path (Join-Path $Suite 'lib\TestDesktop.ps1'))
Assert 'A6 the live harness header declares at least one exception' (@($live | Where-Object { -not $_.Malformed }).Count -ge 1)
AssertEq 'A7 and none of its declarations are malformed' 0 @($live | Where-Object { $_.Malformed }).Count

# ===========================================================================
Write-Host ''
Write-Host '== B: what is and is not a grab site'
# ===========================================================================

function SiteCount([string[]]$Text) { return @(Get-ForegroundAuditSites -Text $Text).Count }

Assert 'B1 a live P/Invoke call is a grab site' ((SiteCount @(
    '$null = [Drv]::SetForegroundWindow($hwnd)'
)) -ge 1)

Assert 'B2 so is a P/Invoke declared inside an Add-Type here-string' ((SiteCount @(
    'Add-Type @'''
    'public class Drv {'
    '  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int cb);'
    '}'
    ''''
)) -ge 1)

AssertEq 'B3 a PowerShell comment mentioning it is NOT a grab site' 0 (SiteCount @(
    '# SendInput is BLOCKED on a background desktop; posted messages replace it.'
    '# SetForegroundWindow fails there too.'
    'Send-TestKeys -Window $top -Key T'
))

AssertEq 'B4 nor is a C# comment inside an embedded here-string' 0 (SiteCount @(
    'Add-Type @'''
    'public class Drv {'
    '  // SendInput is dead off the input desktop - posted messages instead.'
    '  /* SetCursorPos too */'
    '  public static void Post() { }'
    '}'
    ''''
))

$sites = @(Get-ForegroundAuditSites -Text @(
    'Add-Type @'''
    'public class Drv {'
    '  public static void A() { }'
    '  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);'
    '}'
    ''''
))
AssertEq 'B5 a here-string site reports the line the call is really on' 4 $sites[0].Line

Assert 'B6 a hardcoded -Interactive is a grab site' ((SiteCount @(
    '$td = New-TestDesktop -Interactive'
)) -ge 1)

AssertEq 'B7 but forwarding the debug switch is not' 0 (SiteCount @(
    '$td = New-TestDesktop -Interactive:$Interactive'
))

# The analyzer as a whole, driven off an injected declaration list.
$decl = @([pscustomobject]@{ Script = 'declared.ps1'; Reason = 'because'; Line = 9; Malformed = $false })
$tmp = Join-Path $env:TEMP "ghoztty-t272-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null
Set-Content -LiteralPath (Join-Path $tmp 'declared.ps1') -Encoding ascii `
    -Value '$null = [Drv]::SendInput(1, $i, 40)'
Set-Content -LiteralPath (Join-Path $tmp 'undeclared.ps1') -Encoding ascii `
    -Value '$null = [Drv]::SetForegroundWindow($hwnd)'
Set-Content -LiteralPath (Join-Path $tmp 'migrated.ps1') -Encoding ascii `
    -Value '# SendInput is dead here; posted messages replace it.'
$files = @(Get-ChildItem -LiteralPath $tmp -Filter *.ps1 -File | ForEach-Object { $_.FullName })

$f = @(Get-ForegroundAuditFindings -Files $files -Declared $decl)
AssertEq 'B8 the undeclared grabber is the only finding' 1 $f.Count
AssertEq 'B9 and it is named as undeclared' 'undeclared' $f[0].Kind
Assert 'B10 naming the script' ($f[0].Path -match 'undeclared\.ps1')

$stale = @([pscustomobject]@{ Script = 'migrated.ps1'; Reason = 'was'; Line = 9; Malformed = $false }) + $decl
$f = @(Get-ForegroundAuditFindings -Files $files -Declared $stale)
Assert 'B11 a declaration for a script that no longer grabs is named stale' (@($f | Where-Object { $_.Kind -eq 'stale-declaration' }).Count -eq 1)

$f = @(Get-ForegroundAuditFindings -Files $files -Declared @(
    [pscustomobject]@{ Script = ''; Reason = 'junk'; Line = 3; Malformed = $true }))
Assert 'B12 a malformed declaration is a finding' (@($f | Where-Object { $_.Kind -eq 'malformed-declaration' }).Count -ge 1)

$f = @(Get-ForegroundAuditFindings -Files $files -Declared @())
Assert 'B13 an empty declaration list is a finding, not a free pass' (@($f | Where-Object { $_.Kind -eq 'malformed-declaration' }).Count -ge 1)

# The narrow marker, for a file that NAMES the APIs without calling them.
Assert 'B14 the stated-intent marker exempts a file that only names the APIs' (
    Test-ForegroundAuditExempt -Text @('# foreground-audit: the fixtures are strings', '[Drv]::SendInput(1)'))
Assert 'B15 and a file without it is not exempt' (
    -not (Test-ForegroundAuditExempt -Text @('# just a comment', '[Drv]::SendInput(1)')))

$marked = Join-Path $tmp 'marked.ps1'
Set-Content -LiteralPath $marked -Encoding ascii -Value @(
    '# foreground-audit: a fixture, not a call'
    '$fixture = ''$null = [Drv]::SendInput(1, $i, 40)'''
)
$f = @(Get-ForegroundAuditFindings -Files @($marked) -Declared $decl)
AssertEq 'B16 a marked file is not swept as an undeclared grabber' 0 @($f | Where-Object { $_.Kind -eq 'undeclared' }).Count

# ===========================================================================
Write-Host ''
Write-Host '== D: the screen-DC family - input-desktop-only without grabbing'
# ===========================================================================

function ScreenDcCount([string[]]$Text) {
    return @(Get-ForegroundAuditSites -Text $Text | Where-Object { $_.Family -eq 'screen-dc' }).Count
}

Assert 'D1 a PowerShell screen-DC read is a site' ((ScreenDcCount @(
    '$hdc = [Drv]::GetDC([IntPtr]::Zero)'
)) -ge 1)

Assert 'D2 so is the C# spelling inside an Add-Type here-string' ((ScreenDcCount @(
    'Add-Type @'''
    'public class Drv {'
    '  public static int Peek() { IntPtr h = GetDC(IntPtr.Zero); return 0; }'
    '}'
    ''''
)) -ge 1)

Assert 'D3 and Graphics.CopyFromScreen' ((ScreenDcCount @(
    '$g.CopyFromScreen($x, $y, 0, 0, $size)'
)) -ge 1)

Assert 'D4 and a bare zero handle' ((ScreenDcCount @('$hdc = [Drv]::GetDC(0)')) -ge 1)

Assert 'D5 and the desktop window spelled out' ((ScreenDcCount @(
    '$hdc = [Drv]::GetWindowDC([Drv]::GetDesktopWindow())'
)) -ge 1)

# The load-bearing negatives. A WINDOW DC works off the input desktop, so
# neither a real window read nor the P/Invoke declaration behind it is a finding
# - otherwise every script that captures a window would land on the list.
AssertEq 'D6 a window DC is NOT a screen-DC site' 0 (ScreenDcCount @(
    '$hdc = [Drv]::GetDC($hwnd)'
    '$dc  = [Drv]::GetWindowDC($top)'
))
AssertEq 'D7 nor is the P/Invoke declaration it is called through' 0 (ScreenDcCount @(
    'Add-Type @'''
    'public class Drv {'
    '  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);'
    '  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);'
    '}'
    ''''
))
AssertEq 'D8 nor a comment saying CopyFromScreen is dead here' 0 (ScreenDcCount @(
    '# CopyFromScreen is dead off the input desktop; PrintWindow replaces it.'
    '# GetDC(IntPtr.Zero) likewise - DWM composes only the input desktop.'
))
AssertEq 'D9 nor a C# comment inside a here-string' 0 (ScreenDcCount @(
    'Add-Type @'''
    'public class Drv {'
    '  // GetDC(IntPtr.Zero) would be dead here.'
    '  public static void Post() { }'
    '}'
    ''''
))

# End to end through the analyzer: the same declaration list covers both
# families, because it is one exemption - "this script needs the input desktop".
Set-Content -LiteralPath (Join-Path $tmp 'probe.ps1') -Encoding ascii `
    -Value '$hdc = [Drv]::GetDC([IntPtr]::Zero); $c = [Drv]::GetPixel($hdc, 4, 4)'
$probe = @((Join-Path $tmp 'probe.ps1'))

$declProbe = @([pscustomobject]@{
    Script = 'probe.ps1'; Reason = 'its oracle is GL pixels'; Line = 11; Malformed = $false })

$f = @(Get-ForegroundAuditFindings -Files $probe -Declared $decl)
AssertEq 'D10 an undeclared screen-DC prober is a finding' 1 @($f | Where-Object { $_.Kind -eq 'undeclared' }).Count
Assert 'D11 and the detail names the composited screen, not a foreground grab' (
    @($f | Where-Object { $_.Kind -eq 'undeclared' })[0].Detail -match 'composited screen')

$f = @(Get-ForegroundAuditFindings -Files $probe -Declared $declProbe)
AssertEq 'D12 declaring it clears the finding' 0 $f.Count

# And a declaration for a script that has since migrated off the screen DC goes
# stale, exactly as a foreground one does - the list must not outlive the need.
Set-Content -LiteralPath (Join-Path $tmp 'probe.ps1') -Encoding ascii `
    -Value '$shot = Get-TestPaneCapture -Target $t; $c = $shot.Bitmap.GetPixel(4, 4)'
$f = @(Get-ForegroundAuditFindings -Files $probe -Declared $declProbe)
Assert 'D13 a migrated screen probe makes its declaration stale' (
    @($f | Where-Object { $_.Kind -eq 'stale-declaration' }).Count -eq 1)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# ===========================================================================
Write-Host ''
Write-Host '== E: lib\ is swept too, and a helper states its intent (T780)'
# ===========================================================================
# The hole this closes: the sweep was top-level only, so a new lib\ helper that
# read the composited screen would make EVERY script calling it
# input-desktop-only and not one of them would be flagged - the site would not
# be in a swept file. Scope is not a detail of the rule, it IS the rule.

$lt = Join-Path $env:TEMP "ghoztty-t780-$PID"
if (Test-Path $lt) { Remove-Item -Recurse -Force $lt -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force (Join-Path $lt 'lib') | Out-Null
$libHelper = Join-Path $lt 'lib\Probe.ps1'
$declNone = @([pscustomobject]@{ Script = 'nothing.ps1'; Reason = 'placeholder'; Line = 1; Malformed = $false })

function LibFindings([object[]]$Declared) {
    return @(Get-ForegroundAuditFindings -Root $lt -Declared $Declared)
}

Set-Content -LiteralPath $libHelper -Encoding ascii -Value @(
    'function Get-Probe { $hdc = [Drv]::GetDC([IntPtr]::Zero); return [Drv]::GetPixel($hdc, 4, 4) }'
)
$f = LibFindings $declNone
AssertEq 'E1 an unmarked lib helper that reads the screen is a finding' 1 @($f | Where-Object { $_.Kind -eq 'undeclared' }).Count
Assert 'E2 and it is the helper that is named, not its callers' (
    @($f | Where-Object { $_.Kind -eq 'undeclared' })[0].Path -match 'Probe\.ps1')

# The exemption is one findable line with a why on it - not a directory that
# was quietly out of scope.
Set-Content -LiteralPath $libHelper -Encoding ascii -Value @(
    '# input-desktop-helper: the screen read IS the measurement here.'
    'function Get-Probe { $hdc = [Drv]::GetDC([IntPtr]::Zero); return [Drv]::GetPixel($hdc, 4, 4) }'
)
AssertEq 'E3 the helper marker clears it' 0 @(LibFindings $declNone | Where-Object { $_.Kind -eq 'undeclared' }).Count

Set-Content -LiteralPath $libHelper -Encoding ascii -Value @(
    '# input-desktop-helper:'
    'function Get-Probe { $hdc = [Drv]::GetDC([IntPtr]::Zero); return [Drv]::GetPixel($hdc, 4, 4) }'
)
AssertEq 'E4 a marker with no reason states no intent and does not exempt' 1 @(LibFindings $declNone | Where-Object { $_.Kind -eq 'undeclared' }).Count

# A marker that outlives the site it excused is the same rot as a stale
# declaration: a list naming files that need no naming.
Set-Content -LiteralPath $libHelper -Encoding ascii -Value @(
    '# input-desktop-helper: the screen read IS the measurement here.'
    'function Get-Probe { return Get-TestPaneCapture -Target $t }'
)
$f = LibFindings $declNone
Assert 'E5 a marked helper that no longer grabs is a stale marker' (
    @($f | Where-Object { $_.Kind -eq 'stale-declaration' -and $_.Path -match 'Probe\.ps1' }).Count -eq 1)

# A lib helper that genuinely IS input-desktop-only can still be declared, and
# it is declared BY PATH - keys are relative to test\win32, so a helper and a
# top-level script of the same name cannot be confused with each other.
Set-Content -LiteralPath $libHelper -Encoding ascii -Value @(
    'function Get-Probe { $hdc = [Drv]::GetDC([IntPtr]::Zero); return [Drv]::GetPixel($hdc, 4, 4) }'
)
$byPath = @([pscustomobject]@{ Script = 'lib\Probe.ps1'; Reason = 'needs the composited screen'; Line = 7; Malformed = $false })
AssertEq 'E6 declaring it by path clears the finding' 0 (LibFindings $byPath).Count

$byLeaf = @([pscustomobject]@{ Script = 'Probe.ps1'; Reason = 'the bare leaf'; Line = 7; Malformed = $false })
$f = LibFindings $byLeaf
Assert 'E7 the bare leaf does NOT exempt a lib file' (
    @($f | Where-Object { $_.Kind -eq 'undeclared' -and $_.Path -match 'Probe\.ps1' }).Count -eq 1)
Assert 'E8 and that declaration reads as stale rather than silently matching' (
    @($f | Where-Object { $_.Kind -eq 'stale-declaration' }).Count -eq 1)

# The marker is for helpers only. An acceptance script is declared in
# lib\TestDesktop.ps1 or it is a finding; a helper marker is not a second door.
Remove-Item -LiteralPath $libHelper -Force
$topLevel = Join-Path $lt 'pretender.ps1'
Set-Content -LiteralPath $topLevel -Encoding ascii -Value @(
    '# input-desktop-helper: I am not a helper.'
    '$null = [Drv]::SendInput(1, $i, 40)'
)
$f = LibFindings $declNone
AssertEq 'E9 the helper marker does not exempt a top-level script' 1 @($f | Where-Object { $_.Kind -eq 'undeclared' }).Count
Assert 'E10 and the finding says the marker is only honoured under lib\' (
    @($f | Where-Object { $_.Kind -eq 'undeclared' })[0].Detail -match 'only honoured under lib')

$parsed = @(Get-ForegroundAuditDeclarations -Text @(
    '# @input-desktop-exception: lib\Probe.ps1 -- (T780) needs the composited screen.'))
AssertEq 'E11 the declaration grammar accepts a lib\ path' 'lib\Probe.ps1' $parsed[0].Script

Remove-Item -Recurse -Force $lt -ErrorAction SilentlyContinue

# The three real lib\ files that hold these APIs each carry their exemption
# line. If one ever stops, the sweep in C says so - this says WHICH mechanism
# is carrying it, so a silent drift to "nothing in lib matches any more" is
# visible here rather than as an unexplained green.
$libExempt = @{
    'TestDesktop.ps1'       = 'helper'
    'DesktopCapability.ps1' = 'helper'
    'ForegroundAudit.ps1'   = 'named-not-called'
}
foreach ($n in $libExempt.Keys) {
    $p = Join-Path $Suite "lib\$n"
    $ok = if ($libExempt[$n] -eq 'helper') {
        (Test-ForegroundAuditHelperMarker -Path $p) -and -not (Test-ForegroundAuditExempt -Path $p)
    } else {
        Test-ForegroundAuditExempt -Path $p
    }
    Assert "E12 lib\$n states its exemption ($($libExempt[$n]))" $ok
}

# ===========================================================================
Write-Host ''
Write-Host '== C: the sweep over the acceptance suite'
# ===========================================================================

$planted = @()
if ($TeethCheck) {
    # Real files in the real swept directory, not synthesized findings: the
    # claim under test is that the SWEEP notices, which a hand-made object would
    # not exercise. One per family - a screen-DC violator is invisible to the
    # pre-T276 detector, so it is the arm that proves the widening landed.
    $planted = @(
        @{ Name = 'zz-foreground-audit-teeth.ps1'
           Body = '$null = [Drv]::SendInput(1, $inputs, 40)' }
        @{ Name = 'zz-foreground-audit-teeth-screendc.ps1'
           Body = '$hdc = [Drv]::GetDC([IntPtr]::Zero)' }
        # T780: in lib\, which the sweep did not read at all until it did.
        @{ Name = 'lib\zz-foreground-audit-teeth-helper.ps1'
           Body = '$hdc = [Drv]::GetDC([IntPtr]::Zero)' }
    ) | ForEach-Object {
        $p = Join-Path $Suite $_.Name
        Set-Content -LiteralPath $p -Encoding ascii -Value @(
            '# planted by foreground-audit.ps1 -TeethCheck; deleted at the end of the run.'
            $_.Body
        )
        $p
    }
    Write-Host '  TEETH CHECK: three real undeclared violators are in the swept tree (one in lib\)'
}

try {
    $sweep = @(Get-ForegroundAuditSweep $Suite)
} finally {
    foreach ($p in $planted) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

$hardKinds = Get-ForegroundAuditHardKinds
$hard = @($sweep | Where-Object { $hardKinds -contains $_.Kind })

if ($TeethCheck) {
    Assert 'C1 goes red when an undeclared foreground grab is added' (
        @($hard | Where-Object { $_.Path -match 'zz-foreground-audit-teeth\.ps1' }).Count -eq 1)
    Assert 'C1b and when an undeclared screen-DC probe is added' (
        @($hard | Where-Object { $_.Path -match 'zz-foreground-audit-teeth-screendc' }).Count -eq 1)
    Assert 'C1c and when the unmarked helper is in lib\ (T780)' (
        @($hard | Where-Object { $_.Path -match 'zz-foreground-audit-teeth-helper' }).Count -eq 1)
} else {
    Assert 'C1 every input-desktop site in the suite is declared, and every declaration is live' ($hard.Count -eq 0)
    foreach ($h in $hard) {
        Write-Host "       $(Split-Path $h.Path -Leaf):$($h.Line) $($h.Kind) - $($h.Detail)"
    }
}

# A sweep that read no files would report zero violations and look identical to
# a clean one - the exact shape T271 exists for.
$scanned = @(Get-ChildItem -LiteralPath $Suite -Filter *.ps1 -File).Count
Assert 'C2 the sweep read the whole suite' ($scanned -gt 100)

# And the harness with it (T780). A scope regression is silent by construction:
# the findings stay at zero and nothing says fewer files were read.
$libCount = @(Get-ChildItem -LiteralPath (Join-Path $Suite 'lib') -Filter *.ps1 -File).Count
Assert "C2b the sweep reads lib\ too ($libCount helper(s))" ($libCount -ge 5)
Assert 'C2c and keys a helper by its lib\ path' (
    (Get-ForegroundAuditKey -Path (Join-Path $Suite 'lib\TestDesktop.ps1') -Root $Suite) -eq 'lib\TestDesktop.ps1')

# And it must still be finding the declared exceptions, or the detector has
# gone blind and C1 is green for the wrong reason.
$declaredNames = @(Get-ForegroundAuditDeclarations -Path (Join-Path $Suite 'lib\TestDesktop.ps1') |
    Where-Object { -not $_.Malformed } | ForEach-Object { $_.Script })
$stillGrabbing = 0
foreach ($n in $declaredNames) {
    $p = Join-Path $Suite $n
    if ((Test-Path -LiteralPath $p) -and (@(Get-ForegroundAuditSites -Path $p).Count -gt 0)) { $stillGrabbing++ }
}
AssertEq 'C3 every declared exception still needs the input desktop' $declaredNames.Count $stillGrabbing
Write-Host "  ($($declaredNames.Count) script(s) declared interactive-by-design: $($declaredNames -join ', '))"

# The widened family must be LIVE in the sweep, not merely implemented: if no
# script in the suite still reads a screen DC, C1's green says nothing about it.
# test-desktop-spike is that script by design (it MEASURES what is dead off the
# input desktop, so it has to reach both), and it is declared.
$screenDc = @()
foreach ($n in $declaredNames) {
    $p = Join-Path $Suite $n
    if (-not (Test-Path -LiteralPath $p)) { continue }
    if (@(Get-ForegroundAuditSites -Path $p | Where-Object { $_.Family -eq 'screen-dc' }).Count -gt 0) {
        $screenDc += $n
    }
}
Assert 'C4 the screen-DC family is exercised by a real declared script' ($screenDc.Count -ge 1)
Write-Host "  (screen-DC readers, all declared: $($screenDc -join ', '))"

Write-Host ''
Complete-TestBody  # T1039: the run reached the end of its body
Write-TestVerdict -Label 'T272/T276/T780 ACCEPTANCE' -Pass $script:pass -Fail $script:fail -MinPass 50
