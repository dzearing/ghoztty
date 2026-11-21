# T158 acceptance: every launch in test\win32 says what it wants session
# persistence to do, and the flag that says "don't restore" actually stops the
# restore.
#
#   powershell -NoProfile -File test\win32\persistence-flag.ps1
#
# THE DEFECT THIS GUARDS. Session persistence is ON by default, so a GUI
# launched without `--session-persistence=false` restores whatever panes the
# last launch left behind - and the script's own setup assertions then describe
# someone else's layout. It is not a dirty-box problem: each launch writes the
# manifest the NEXT one restores, so a multi-section script poisons itself on a
# clean machine. T131 hit it in pane-banner.ps1 and T155 hit it again in
# split-dim.ps1 and split-zoom-nav.ps1, where both scripts failed
# `default setup: 2 visible panes` against a build whose geometry was
# independently verified correct. The cost is misattribution: it presents as a
# product regression in whatever change happens to be in flight.
#
# WHAT IS ASSERTED
#
#   A (sweep)   every launch of the app under test in test\win32 declares its
#               intent - by passing the flag, by passing something built from
#               it, by every caller of its helper passing it, or by a
#               `# persistence: <reason>` marker for a site where none of those
#               fit (a CLI verb, a throwaway-LOCALAPPDATA launch, a forward-and-
#               exit second instance).
#   B (teeth)   the sweep can say NO. Synthetic scripts in a temp directory
#               exercise each declaration form and one undeclared launch, so a
#               sweep that has quietly stopped finding launch sites at all fails
#               here instead of reporting a clean A.
#
# The LIVE half - does the flag every other script relies on actually stop a
# restore, and does a launch without it actually restore - used to be section C
# here. Since T1572 it is test\win32\persistence-restore.ps1, with its own
# guard-due row: this script is a harness-floor member, and the floor's rule is
# that a member reads source and launches nothing (scripts\lib\HarnessFloor.ps1).
# The live control was the floor's one recurring false red.
#
# Non-interactive and static: it reads test\win32 and plants fixture scripts in
# a temp directory. It launches nothing.
#
# isolation: none - every CLI verb in this file is fixture text in a here-string;
# nothing here launches ghoztty or dials an endpoint.
param(
    # T1969: sweep only these changed top-level scripts in section A (repo-
    # relative). scripts\harness-floor.ps1 -Scoped passes the same list through
    # $env:GHOZTTY_HARNESS_FLOOR_ONLY; lib\HarnessScope.ps1 says when it is
    # ignored. A scoped run never stamps.
    [string[]]$Only
)

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-persistence-flag-$PID"

. (Join-Path $PSScriptRoot 'lib\PersistenceSweep.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessScope.ps1')
$scope = Get-HarnessScope -Repo $repo -Self $PSCommandPath -Only $Only

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

# ---------------------------------------------------------------------------
# A: the sweep over the real suite
# ---------------------------------------------------------------------------
Say '== A: every launch site in test\win32 declares its persistence intent'
Say (Format-HarnessScopeLine $scope)
if ($scope.Scoped) {
    $sites = @(Get-GhozttyLaunchSites -Root $PSScriptRoot -Files $scope.Files)
    $read = @(@($scope.Files) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    Assert ($read.Count -ge 1 -and $read.Count -eq @($scope.Rel).Count) `
        "A0 the scoped sweep read every changed script ($($read.Count) of $(@($scope.Rel).Count); $($sites.Count) launch site(s))"
} else {
    $sites = @(Get-GhozttyLaunchSites -Root $PSScriptRoot)
    Assert ($sites.Count -ge 100) "A0 the sweep found the suite's launch sites (found $($sites.Count))"
}
$undeclared = @($sites | Where-Object { -not $_.Declared })
foreach ($u in $undeclared) {
    Say ("      undeclared: {0}:{1}  {2}" -f $u.File, $u.Line, $u.Stmt)
}
Assert ($undeclared.Count -eq 0) `
    "A1 no launch leaves persistence unstated (undeclared: $($undeclared.Count) of $($sites.Count))"
$byHow = $sites | Group-Object { ($_.How -split ':')[0] } | ForEach-Object { "$($_.Name)=$($_.Count)" }
Say ("      declared by: " + ($byHow -join ', '))

# ---------------------------------------------------------------------------
# B: the sweep's own teeth
# ---------------------------------------------------------------------------
Say '== B: the sweep can say no'
$fix = Join-Path $root 'sweepfix'
New-Item -ItemType Directory -Force $fix | Out-Null

# The fixtures spell the launch call as @@LAUNCH@@ and substitute it below,
# because section A sweeps THIS file too: a literal `Start-OnTestDesktop` inside
# a here-string reads to the sweep as an undeclared launch site, and the teeth
# check would fail the very assertion it exists to protect.
$literal = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--session-persistence=false')
'@
$viaVar = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$launchArgs = @('--session-persistence=false') + $extra
$sp = @{ Exe = $exe; Arguments = $launchArgs }
$app = @@LAUNCH@@ @sp
'@
$viaMarker = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# persistence: on (default) - a reason a reader can weigh.
$app = @@LAUNCH@@ -Exe $exe
'@
$viaCallers = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
function Launch-Gui([string[]]$ExtraArgs) {
    return (@@LAUNCH@@ -Exe $exe -Arguments $ExtraArgs)
}
$a = Launch-Gui @('--session-persistence=false')
$b = Launch-Gui @('--session-persistence=true')
'@
$undeclaredFix = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--window-width=100')
'@
$otherImage = @'
$agentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
$a = @@LAUNCH@@ -Exe $agentExe -Arguments @('--listen', '127.0.0.1:7777')
'@
$badValue = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--session-persistence=nope')
'@
# T697: the shape the sweep used to miss - a marker written once on the helper's
# own header, further above the launch than the fixed six-line window reached.
$viaFnMarker = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# `ghoztty <argv>`, with the CLI's own environment.
# persistence: a CLI invocation - it opens no window, so there is nothing to restore.
function Run-Cli($argv) {
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $tmp
    $out = Join-Path $tmp 'out.txt'
    $err = "$out.err"
    $code = $null
    $p = @@LAUNCH@@ -Exe $exe -Arguments $argv
    $env:LOCALAPPDATA = $saved
    return $p
}
$r = Run-Cli @('+list')
'@
# ... and the boundary that keeps it honest: the marker declares the function it
# is written on, not every function that happens to sit below it.
$fnScope = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# persistence: a CLI invocation - nothing to restore.
function Run-Declared($argv) {
    $g = 1
    $h = 2
    $i = 3
    $j = 4
    $k = 5
    $l = 6
    $p = @@LAUNCH@@ -Exe $exe -Arguments $argv
    return $p
}
function Run-Other($argv) {
    $a = 1
    $b = 2
    $c = 3
    $d = 4
    $e = 5
    $f = 6
    $q = @@LAUNCH@@ -Exe $exe -Arguments $argv
    return $q
}
$x = Run-Declared @('+list')
$y = Run-Other @('+list')
'@
# The other half of T697: the window is the comment BLOCK, not a line count, so a
# marker at the top of a long explanation still declares the launch under it.
$longBlock = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# persistence: on (default) - the first line of a long block that explains why.
# This launch restores on purpose: the section below is about what comes back,
# so turning persistence off would delete the fixture the assertions read.
# The block runs past six lines deliberately, because that is what a reader
# writes when the reason takes a paragraph rather than a sentence, and the
# marker belongs at the top of the reason rather than buried at the bottom of
# it where a fixed-size window would happen to catch it.
$app = @@LAUNCH@@ -Exe $exe
'@

# T1012. An image taken from the ENVIRONMENT is cmd.exe, not the terminal: five
# `ping` fixtures were reported as ghoztty launches nobody had declared, and no
# edit to any of them could have been right, since cmd.exe has no session to
# persist. The pair says it in both directions - an env var whose name says
# ghoztty is still ours, and still has to declare.
$envImage = @'
$d = @@LAUNCH@@ -Exe $env:ComSpec -Arguments @('/c', 'ping -n 3 127.0.0.1 >nul')
'@
$envOurs = @'
$d = @@LAUNCH@@ -Exe $env:GHOZTTY_TEST_EXE -Arguments @('--window-width=100')
'@
# T1012. Same shape one hop away: a tool looked up on PATH names itself, and
# `$node = Get-Command node` carries no `.exe` literal for the image check to
# read, so the dashboard's node server read as an undeclared ghoztty launch.
$pathTool = @'
$node = Get-Command node -ErrorAction SilentlyContinue
$srv = @@LAUNCH@@ -FilePath $node.Source -ArgumentList '--port 7788'
'@
# T1012. The third marker scope: a script whose HEADER reasons about persistence
# for the whole run has declared every launch in it (update-graceful.ps1 wrote
# exactly that and was still reported undeclared). Only the LEADING block counts
# - `headerlate.ps1` writes the same sentence after the code starts, where it
# belongs to whatever it sits on and declares nothing.
$fileHeader = @'
# A fixture script.
# persistence: on (default) - the run has its own LOCALAPPDATA.
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$a = 1
$b = 2
$c = 3
$d = 4
$e = 5
$f = 6
$g = 7
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--window-width=100')
'@
$headerLate = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$other = 1
# persistence: on (default) - written too late to be the file's header.
$a = 1
$b = 2
$c = 3
$d = 4
$e = 5
$f = 6
$g = 7
function Run-Other { return $other }
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--window-width=100')
'@

foreach ($pair in @(
        @{ Name = 'literal.ps1'; Body = $literal },
        @{ Name = 'envimage.ps1'; Body = $envImage },
        @{ Name = 'envours.ps1'; Body = $envOurs },
        @{ Name = 'pathtool.ps1'; Body = $pathTool },
        @{ Name = 'fileheader.ps1'; Body = $fileHeader },
        @{ Name = 'headerlate.ps1'; Body = $headerLate },
        @{ Name = 'viavar.ps1'; Body = $viaVar },
        @{ Name = 'viamarker.ps1'; Body = $viaMarker },
        @{ Name = 'viacallers.ps1'; Body = $viaCallers },
        @{ Name = 'undeclared.ps1'; Body = $undeclaredFix },
        @{ Name = 'otherimage.ps1'; Body = $otherImage },
        @{ Name = 'badvalue.ps1'; Body = $badValue },
        @{ Name = 'fnmarker.ps1'; Body = $viaFnMarker },
        @{ Name = 'fnscope.ps1'; Body = $fnScope },
        @{ Name = 'longblock.ps1'; Body = $longBlock })) {
    $body = $pair.Body -replace '@@LAUNCH@@', 'Start-OnTestDesktop'
    Set-Content -Path (Join-Path $fix $pair.Name) -Value $body -Encoding ASCII
}

$fixSites = @(Get-GhozttyLaunchSites -Root $fix)
function Fix-How($file) {
    $row = $fixSites | Where-Object { $_.File -eq $file } | Select-Object -First 1
    if (-not $row) { return '<no site found>' }
    return $row.How
}
Assert ((Fix-How 'literal.ps1') -eq 'literal') "B1 a flag in the launch statement declares it (got '$(Fix-How 'literal.ps1')')"
Assert ((Fix-How 'viavar.ps1') -like 'var:*') "B2 a flag reached through a splat declares it (got '$(Fix-How 'viavar.ps1')')"
Assert ((Fix-How 'viamarker.ps1') -eq 'marker') "B3 a '# persistence:' marker declares it (got '$(Fix-How 'viamarker.ps1')')"
Assert ((Fix-How 'viacallers.ps1') -like 'callers:*') "B4 a helper whose every caller passes the flag declares it (got '$(Fix-How 'viacallers.ps1')')"
$bad = @($fixSites | Where-Object { $_.File -eq 'undeclared.ps1' })
Assert ($bad.Count -eq 1 -and -not $bad[0].Declared) `
    "B5 a launch that never mentions persistence is reported UNDECLARED (got $($bad.Count) site(s), declared=$(if ($bad.Count) { $bad[0].Declared } else { 'n/a' }))"
Assert (@($fixSites | Where-Object { $_.File -eq 'otherimage.ps1' }).Count -eq 0) `
    'B6 a launch of a different image (the agent) is not swept at all'
# A value `parseBool` rejects is logged and dropped, so the setting keeps its
# default: the launch looks explicit and restores anyway. That must not read as
# a declaration.
$badRow = @($fixSites | Where-Object { $_.File -eq 'badvalue.ps1' })
Assert ($badRow.Count -eq 1 -and -not $badRow[0].Declared) `
    "B7 a flag with a value the CLI rejects is NOT a declaration (got $($badRow.Count) site(s), declared=$(if ($badRow.Count) { $badRow[0].Declared } else { 'n/a' }))"

# T697. The sweep read a marker on a function header as no marker at all, and
# reported the site as work nobody had considered. These three say the opposite
# in both directions: the header declares the launches inside its function, it
# does NOT declare the next function's, and a long comment block is one unit.
Assert ((Fix-How 'fnmarker.ps1') -eq 'marker:fn:Run-Cli') `
    "B8 a marker on the enclosing function's header declares its launch, and says where (got '$(Fix-How 'fnmarker.ps1')')"
$scoped = @($fixSites | Where-Object { $_.File -eq 'fnscope.ps1' } | Sort-Object Line)
Assert ($scoped.Count -eq 2 -and $scoped[0].How -eq 'marker:fn:Run-Declared' -and -not $scoped[1].Declared) `
    ("B9 that marker declares ONLY its own function - the next one is still undeclared " +
        "(got $($scoped.Count) site(s): $(($scoped | ForEach-Object { if ($_.How) { $_.How } else { 'undeclared' } }) -join ', '))")
Assert ((Fix-How 'longblock.ps1') -eq 'marker') `
    "B10 a marker at the top of a comment block longer than six lines still declares it (got '$(Fix-How 'longblock.ps1')')"

# T1012. Three sweep reads that produced work nobody could do, each with the
# control that keeps the new rule from swallowing a real site.
Assert (@($fixSites | Where-Object { $_.File -eq 'envimage.ps1' }).Count -eq 0) `
    'B11 a launch of $env:ComSpec (cmd.exe) is not swept as the terminal'
$envOursRow = @($fixSites | Where-Object { $_.File -eq 'envours.ps1' })
Assert ($envOursRow.Count -eq 1 -and -not $envOursRow[0].Declared) `
    ("B12 but an env var whose NAME says ghoztty IS swept, and still has to declare " +
        "(got $($envOursRow.Count) site(s), declared=$(if ($envOursRow.Count) { $envOursRow[0].Declared } else { 'n/a' }))")
Assert (@($fixSites | Where-Object { $_.File -eq 'pathtool.ps1' }).Count -eq 0) `
    'B13 a tool found on PATH (Get-Command node) is not swept as the terminal'
Assert ((Fix-How 'fileheader.ps1') -eq 'marker:file') `
    "B14 a marker in the script's HEADER declares the launches in it (got '$(Fix-How 'fileheader.ps1')')"
$lateRow = @($fixSites | Where-Object { $_.File -eq 'headerlate.ps1' })
Assert ($lateRow.Count -eq 1 -and -not $lateRow[0].Declared) `
    ("B15 and the same sentence written after the code starts is not a header, so it " +
        "declares nothing (got $($lateRow.Count) site(s), declared=$(if ($lateRow.Count) { $lateRow[0].Declared } else { 'n/a' }))")

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# --- stamp (T783/T1012) ----------------------------------------------------
# A clean green run RECORDS the content of everything this covers, so
# scripts\guard-due.ps1 can answer "has anybody asked the suite as it now stands
# whether every launch declares its intent?". Red stays due: only a green sweep
# re-stamps. Nothing owned that question until now, which is how the undeclared
# count went from 14 to 52 with no run in between. A scoped run (T1969) read
# only the changed scripts, so it stamps nothing.
Complete-TestBody  # T1039/T1511: before the stamp, which is a child process reading this run's state
if ($script:fail -eq 0 -and -not $scope.Scoped) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard persistence-flag -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label ('PERSISTENCE-FLAG' + (Get-HarnessScopeLabel $scope))
