<#
.SYNOPSIS
    T689 acceptance - no launch of the app under test throws away what it said
    on the way out.

.DESCRIPTION
    THE DEFECT THIS GUARDS. A debug build writes std.log to stderr and nothing
    else: no Windows event-log record, no crash dump. So a launch that redirects
    neither stream discards the app's entire account of itself at exactly the
    moment it becomes interesting - the moment the GUI dies mid-run. That is the
    state pane-banner.ps1 was in when its instance disappeared: a red line, no
    log, and a re-run with an edit as the only way to learn anything. 127 of the
    suite's 251 launch sites were in that state when this was written, which is
    what a per-call-site convention decays to.

    WHAT IS ASSERTED

      A (sweep)   every launch of the app under test in test\win32 keeps its
                  stderr - by passing the path itself, by passing something
                  built from it, by every caller of its helper passing it, by
                  going through Start-OnTestDesktop (which fills the path in),
                  or by a `# stderr: <reason>` marker for a site where none of
                  those is the answer (a cmd.exe fixture, a node server).
      B (teeth)   the sweep can say NO. Synthetic scripts exercise each
                  declaration form and one uncaptured Start-Process, so a sweep
                  that has quietly stopped finding launch sites fails here
                  instead of reporting a clean A.
      C (text)    a launch spelled inside a string or a block comment is
                  not a launch - and a real launch AFTER a quoted string on the
                  same line still is. Without this the analyzer harnesses
                  contribute phantom rows no edit could ever declare.
      D (doc)     the rule is written down in docs\claude\testing.md, so the
                  next person to add a launch has something to read.
      E (live)    the credit section A gives every Start-OnTestDesktop site is
                  worth something: launch through the helper with no -StdErr,
                  and read the child's stderr back off disk.

    `-TeethCheck` proves the section-A assertion can fail: it injects a
    synthesized uncaptured launch into the swept directory and requires the
    sweep to go red. Run it after any change to the analyzer.

    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.

.NOTES
    # persistence: launches no ghoztty GUI - sections A-D score source text, and
    # section E launches cmd.exe. Nothing here starts the terminal, so there is
    # no session to restore.
    # isolation: none needed - no ghoztty binary is ever run, so there is no IPC
    # endpoint, no agent and no state directory to move off the user's.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\PersistenceSweep.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-stderr-launch-$PID"
New-Item -ItemType Directory -Force $root | Out-Null

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

try {

    # -----------------------------------------------------------------------
    # A: the sweep over the real suite
    # -----------------------------------------------------------------------
    Say '== A: every launch site in test\win32 keeps the app''s stderr'
    $sites = @(Get-GhozttyLaunchSites -Root $PSScriptRoot)
    Assert ($sites.Count -ge 100) "A0 the sweep found the suite's launch sites (found $($sites.Count))"
    $uncaptured = @($sites | Where-Object { -not $_.CapturesStderr })
    foreach ($u in $uncaptured) {
        Say ("      uncaptured: {0}:{1}  {2}" -f $u.File, $u.Line, $u.Stmt)
    }
    Assert ($uncaptured.Count -eq 0) `
        "A1 no launch discards the app's stderr (uncaptured: $($uncaptured.Count) of $($sites.Count))"
    $byHow = $sites | Group-Object { ($_.StderrHow -split ':')[0] } | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Say ("      captured by: " + ($byHow -join ', '))

    # -----------------------------------------------------------------------
    # B: the sweep's own teeth
    # -----------------------------------------------------------------------
    Say ''
    Say '== B: the sweep can say no'
    $fix = Join-Path $root 'sweepfix'
    New-Item -ItemType Directory -Force $fix | Out-Null

    # The fixtures spell the launch call as @@TD@@/@@SP@@ and substitute it
    # below, because section A sweeps THIS file too: a literal Start-Process
    # inside a here-string would read to the sweep as a launch site of its own.
    # (Section C proves that quoting is what makes that safe.)
    $spLiteral = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$p = @@SP@@ -FilePath $exe -PassThru -RedirectStandardError (Join-Path $root 'a.err.txt')
'@
    $spViaVar = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$sp = @{ FilePath = $exe; RedirectStandardError = $err; PassThru = $true }
$p = @@SP@@ @sp
'@
    $spViaMarker = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# stderr: n/a - a copy of cmd.exe wearing our name, not the app.
$p = @@SP@@ -FilePath $exe -PassThru
'@
    $spViaCallers = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
function Launch-Gui([string]$StdErr) {
    return (@@SP@@ -FilePath $exe -PassThru @PSBoundParameters)
}
$a = Launch-Gui -StdErr 'a.txt'
$b = Launch-Gui -StdErr 'b.txt'
'@
    $spUncaptured = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$p = @@SP@@ -FilePath $exe -ArgumentList @('--session-persistence=false') -PassThru
'@
    $tdBare = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@TD@@ -Exe $exe -Arguments @('--session-persistence=false')
'@
    $tdExplicit = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@TD@@ -Exe $exe -StdErr (Join-Path $root 'app.err.txt')
'@
    $otherImage = @'
$agentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
$a = @@SP@@ -FilePath $agentExe -ArgumentList @('--listen') -PassThru
'@
    # T697: a marker written once on the helper's header, further above the
    # launch than the fixed six-line window used to reach.
    $spFnMarker = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# Runs one CLI verb and hands back the process.
# stderr: the verb's own output file is what the caller reads.
function Run-Verb($argv) {
    $a = 1
    $b = 2
    $c = 3
    $d = 4
    $e = 5
    $f = 6
    $p = @@SP@@ -FilePath $exe -PassThru
    return $p
}
$r = Run-Verb @('+list')
'@

    foreach ($pair in @(
            @{ Name = 'spliteral.ps1'; Body = $spLiteral },
            @{ Name = 'spvar.ps1'; Body = $spViaVar },
            @{ Name = 'spmarker.ps1'; Body = $spViaMarker },
            @{ Name = 'spcallers.ps1'; Body = $spViaCallers },
            @{ Name = 'spuncaptured.ps1'; Body = $spUncaptured },
            @{ Name = 'tdbare.ps1'; Body = $tdBare },
            @{ Name = 'tdexplicit.ps1'; Body = $tdExplicit },
            @{ Name = 'otherimage.ps1'; Body = $otherImage },
            @{ Name = 'spfnmarker.ps1'; Body = $spFnMarker })) {
        $body = $pair.Body -replace '@@SP@@', 'Start-Process' -replace '@@TD@@', 'Start-OnTestDesktop'
        Set-Content -Path (Join-Path $fix $pair.Name) -Value $body -Encoding ASCII
    }

    $fixSites = @(Get-GhozttyLaunchSites -Root $fix)
    function Fix-Err($file) {
        $row = $fixSites | Where-Object { $_.File -eq $file } | Select-Object -First 1
        if (-not $row) { return '<no site found>' }
        return $row.StderrHow
    }
    Assert ((Fix-Err 'spliteral.ps1') -eq 'literal') `
        "B1 -RedirectStandardError in the launch statement captures (got '$(Fix-Err 'spliteral.ps1')')"
    Assert ((Fix-Err 'spvar.ps1') -like 'var:*') `
        "B2 a redirect reached through a splat captures (got '$(Fix-Err 'spvar.ps1')')"
    Assert ((Fix-Err 'spmarker.ps1') -eq 'marker') `
        "B3 a '# stderr:' marker declares it (got '$(Fix-Err 'spmarker.ps1')')"
    Assert ((Fix-Err 'spcallers.ps1') -like 'callers:*') `
        "B4 a helper whose every caller redirects captures (got '$(Fix-Err 'spcallers.ps1')')"
    $bad = @($fixSites | Where-Object { $_.File -eq 'spuncaptured.ps1' })
    Assert ($bad.Count -eq 1 -and -not $bad[0].CapturesStderr) `
        "B5 a Start-Process that redirects nothing is reported UNCAPTURED (got $($bad.Count) site(s), captures=$(if ($bad.Count) { $bad[0].CapturesStderr } else { 'n/a' }))"
    Assert ((Fix-Err 'tdbare.ps1') -eq 'helper') `
        "B6 a bare Start-OnTestDesktop is credited to the helper's default (got '$(Fix-Err 'tdbare.ps1')')"
    Assert ((Fix-Err 'tdexplicit.ps1') -eq 'literal') `
        "B7 an explicit -StdErr still reads as the caller's own choice (got '$(Fix-Err 'tdexplicit.ps1')')"
    Assert (@($fixSites | Where-Object { $_.File -eq 'otherimage.ps1' }).Count -eq 0) `
        'B8 a launch of a different image (the agent) is not swept at all'
    # T697: the same marker window as the persistence scan, so a `# stderr:`
    # written on a helper's header is read rather than silently missed.
    Assert ((Fix-Err 'spfnmarker.ps1') -eq 'marker:fn:Run-Verb') `
        "B9 a '# stderr:' marker on the enclosing function's header declares its launch (got '$(Fix-Err 'spfnmarker.ps1')')"

    # -----------------------------------------------------------------------
    # C: text that MENTIONS a launch is not a launch
    # -----------------------------------------------------------------------
    Say ''
    Say '== C: fixture text and prose are not launch sites'
    $tfix = Join-Path $root 'textfix'
    New-Item -ItemType Directory -Force $tfix | Out-Null

    $inString = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$s = Score @('@@SP@@ -FilePath $exe -PassThru')
'@
    $inBlock = @'
<#
    Counts a BARE launch (@@SP@@ $exe names no desktop) and nothing else.
#>
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
'@
    $afterString = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
Write-Host "starting"; $p = @@SP@@ -FilePath $exe -PassThru
'@
    foreach ($pair in @(
            @{ Name = 'instring.ps1'; Body = $inString },
            @{ Name = 'inblock.ps1'; Body = $inBlock },
            @{ Name = 'afterstring.ps1'; Body = $afterString })) {
        $body = $pair.Body -replace '@@SP@@', 'Start-Process'
        Set-Content -Path (Join-Path $tfix $pair.Name) -Value $body -Encoding ASCII
    }
    $tSites = @(Get-GhozttyLaunchSites -Root $tfix)
    Assert (@($tSites | Where-Object { $_.File -eq 'instring.ps1' }).Count -eq 0) `
        'C1 a launch spelled inside a quoted string is not a site'
    Assert (@($tSites | Where-Object { $_.File -eq 'inblock.ps1' }).Count -eq 0) `
        'C2 a launch named in a <# #> block comment is not a site'
    $after = @($tSites | Where-Object { $_.File -eq 'afterstring.ps1' })
    Assert ($after.Count -eq 1 -and -not $after[0].CapturesStderr) `
        "C3 a REAL launch after a quoted string on the same line is still swept (got $($after.Count) site(s))"

    # -----------------------------------------------------------------------
    # D: the rule is written down
    # -----------------------------------------------------------------------
    Say ''
    Say '== D: the regrowth story is documented'
    $doc = Join-Path $Repo 'docs\claude\testing.md'
    $docText = ''
    if (Test-Path $doc) { $docText = (Get-Content $doc -Raw) }
    Assert ($docText -match 'stderr') 'D1 docs\claude\testing.md talks about stderr at all'
    Assert ($docText -match '#\s*stderr:') 'D2 it names the `# stderr:` marker a new launch can use'
    Assert ($docText -match 'Start-OnTestDesktop') 'D3 it names the helper that fills the path in'

    # -----------------------------------------------------------------------
    # E: the helper default, live
    # -----------------------------------------------------------------------
    Say ''
    Say '== E: a launch that names no log still gets one'
    # cmd.exe, not ghoztty: the property under test is the HELPER's redirect,
    # and a fixture that prints a known string to stderr and exits proves it in
    # a second without a build, a window or a session.
    $marker = "t689-helper-default-$PID"
    $td = $null
    try {
        $td = New-TestDesktop -Interactive:$Interactive
        # persistence: n/a - this is cmd.exe, not the terminal.
        # stderr: the POINT of this arm is that none is passed here.
        $child = Start-OnTestDesktop -Exe $env:ComSpec `
            -Arguments @('/c', "echo $marker 1>&2") -Desktop $td
        Assert ($null -ne $child -and $child.Pid -gt 0) 'E1 the fixture launched'

        $rec = @(Get-TestLaunchRecords | Where-Object { $_.Pid -eq $child.Pid })
        $logPath = if ($rec.Count) { $rec[-1].StdErr } else { '' }
        Assert ([bool]$logPath) "E2 the launch record names a log the postmortem can read (got '$logPath')"

        $text = ''
        if ($logPath) {
            for ($i = 0; $i -lt 40; $i++) {
                if (Test-Path $logPath) {
                    $text = (Get-Content $logPath -Raw -ErrorAction SilentlyContinue)
                    if ($text -match $marker) { break }
                }
                Start-Sleep -Milliseconds 250
            }
        }
        Assert ($text -match $marker) `
            "E3 the child's stderr is on disk at that path (looked for '$marker')"
    } catch {
        Assert $false "E0 the live arm threw: $_"
    } finally {
        if ($td) { Remove-TestDesktop }
    }

    # -----------------------------------------------------------------------
    # The teeth for section A itself: inject a violator and require red.
    # -----------------------------------------------------------------------
    if ($TeethCheck) {
        Say ''
        Say '== T: -TeethCheck - section A over a suite with one uncaptured launch'
        $victim = Join-Path $PSScriptRoot "zz-t689-teeth-$PID.ps1"
        $body = ($spUncaptured -replace '@@SP@@', 'Start-Process')
        Set-Content -Path $victim -Value $body -Encoding ASCII
        try {
            $after = @(Get-GhozttyLaunchSites -Root $PSScriptRoot)
            $bad2 = @($after | Where-Object { -not $_.CapturesStderr })
            Assert ($bad2.Count -eq 1 -and $bad2[0].File -eq (Split-Path -Leaf $victim)) `
                "T1 an uncaptured launch in the swept directory makes section A red (found $($bad2.Count))"
        } finally {
            Remove-Item -Force $victim -ErrorAction SilentlyContinue
        }
    }

} finally {
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

# --- stamp (T783) ----------------------------------------------------------
# A clean green run RECORDS the content of everything this covers, so
# scripts\guard-due.ps1 can answer "has anybody swept the suite as it now
# stands?". Red stays due, because only a green sweep re-stamps.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard stderr-launch-capture -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
if ($script:fail -eq 0) { Say "ALL PASS ($script:pass)"; exit 0 }
Say "$script:fail FAILURE(S) ($script:pass passed)"
exit 1
