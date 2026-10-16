<#
.SYNOPSIS
  Acceptance test for the parallel due-acceptance runner (T1960):
  scripts\acceptance-parallel.ps1 runs acceptance scripts about four at a time,
  each worker in its own mirror of the repo, and gives the verdicts a serial
  run gives.

.DESCRIPTION
  What this holds, and why each is the thing that would break:

    A  The classifier reads CODE, not comments: a pattern in a comment does not
       pin a script, the same pattern in code does; a `# @timing-sensitive`
       declaration makes it exclusive; a parameter defaulting to the repo's
       literal path is injected rather than refused; any other literal repo
       path pins it to main. And the real suite's ten declared timing-sensitive
       scripts classify exclusive.
    B  A worker root mirrors the repo (junction per directory, hard link per
       file, its own zig-out of hard links) and tearing it down never reaches
       the real tree - PS 5.1's recursive delete follows junctions, so this is
       the arm that keeps a test run from emptying the repo.
    C  THE PLANTED OVERLAP (validation criterion 2). A stand-in app runs out of
       worker 1's zig-out; worker 2's own CleanSlate kill (Stop-RepoGhoztty,
       loaded from worker 2's mirror) and the runner's per-worker sweep both
       leave it alive, CleanSlate refuses worker 1's exe outright as "not under
       the repo", and worker 1's own kill does take it (the positive control:
       a kill that never kills anything would pass the first half).
    D  The schedule (criterion 3), measured from the fixture scripts' OWN
       timestamps rather than the runner's: a `# @timing-sensitive` script and
       an exclusive one overlap nothing, two main scripts never overlap, the
       parallel ones really do overlap, each worker child runs in its own root
       with its own LOCALAPPDATA / agent lineage / no inherited pane socket and
       an injected exe that exists. A script red beside others and green alone
       is re-run, reported PARALLEL-SENSITIVE, and scored by the alone run. And
       the overlap oracle itself goes red on a planted bad schedule.
    E  The same fixture set at -Width 1 and -Width 4 scores the same final
       verdicts (criterion 1 at fixture level; the real due set is compared in
       T1960's own validation).
    F  T1961. A STALE zig-out is refused before any script starts (planted:
       a source newer than the exe; the probe script must never run), with the
       fresh run as its positive control; a failed rebuild refuses, a rebuild
       that relinks nothing still clears it once; -FailFast starts nothing
       after the first red and names what it skipped; `due` orders the most
       specific harness first.

  The "app" here is a renamed copy of ping.exe started with no window, and the
  scripts are fixtures written into a throwaway repo under %TEMP%, so the run
  takes a minute or two and never shows anything on the user's desktop.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.
  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $RepoRoot 'scripts\lib\AcceptanceParallel.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

function Invoke-Child {
    # A child powershell's text, stderr included. PS 5.1 turns a native
    # command's stderr into ErrorRecords under `2>&1`, which THROW under
    # ErrorActionPreference=Stop - so this one call runs with Continue.
    param([string]$Command)
    $ErrorActionPreference = 'Continue'
    return @(& powershell -NoProfile -ExecutionPolicy Bypass -Command $Command 2>&1 | ForEach-Object { "$_" })
}

function Write-Fixture {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
$fake = Join-Path $env:TEMP "ap-repo-$tag"
$wbase = Get-AcceptanceWorkerBase -Repo $fake
$fixLog = Join-Path $env:TEMP "ap-log-$tag"
$planted = @()

function Remove-FakeTree {
    foreach ($p in $script:planted) { try { if (-not $p.HasExited) { $p.Kill() } } catch {} }
    if (Test-Path -LiteralPath $wbase) {
        foreach ($w in (Get-ChildItem -LiteralPath $wbase -Directory -Force)) {
            if ($w.Name -like '*-local') { [IO.Directory]::Delete($w.FullName, $true) }
            else { Remove-AcceptanceWorkerRoot -Root $w.FullName }
        }
        [IO.Directory]::Delete($wbase, $true)
    }
    if (Test-Path -LiteralPath $fake) {
        foreach ($link in (Join-Path $fake 'test\win32\lib'), (Join-Path $fake 'scripts')) {
            if (Test-ApReparsePoint $link) { Remove-ApJunction $link }
        }
        Remove-ApLinkTree $fake
    }
    if (Test-Path -LiteralPath $fixLog) { [IO.Directory]::Delete($fixLog, $true) }
}

try {
    # ---- the throwaway repo ----------------------------------------------------
    foreach ($d in 'src', 'test\win32', 'zig-out\bin', 'zig-out\share', 'zig-out-other') {
        New-Item -ItemType Directory -Force (Join-Path $fake $d) | Out-Null
    }
    Write-Fixture (Join-Path $fake 'src\a.txt') 'source'
    Write-Fixture (Join-Path $fake 'build.zig') 'build'
    Write-Fixture (Join-Path $fake 'zig-out\share\x.txt') 'share'
    Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') (Join-Path $fake 'zig-out\bin\ghoztty.exe')
    # The real harness libs, through a junction, so a worker's CleanSlate is
    # loaded FROM the worker's mirror and derives the worker's root.
    cmd /d /c "mklink /J `"$(Join-Path $fake 'test\win32\lib')`" `"$(Join-Path $RepoRoot 'test\win32\lib')`"" | Out-Null
    # ...and the scripts\lib they load in turn (BuildMode.ps1 -> BuildCache.ps1).
    cmd /d /c "mklink /J `"$(Join-Path $fake 'scripts')`" `"$(Join-Path $RepoRoot 'scripts')`"" | Out-Null

    # ---- A: classifier -----------------------------------------------------------
    $lit = $fake
    $cls = @{
        'cls-plain'     = "param()`n'ALL PASS'`n"
        'cls-comment'   = "# Set-Clipboard and local-agent-debug only in a comment`n<# zig build here too #>`n'ALL PASS'`n"
        'cls-clip'      = "if (`$false) { Set-Clipboard 'x' }`n'ALL PASS'`n"
        'cls-timing'    = "# @timing-sensitive - fixture`n'ALL PASS'`n"
        'cls-unsafe'    = "# @parallel-unsafe`n'ALL PASS'`n"
        'cls-agentdir'  = "`$d = 'ghoztty\local-agent-debug'`n'ALL PASS'`n"
        'cls-inject'    = "param([string]`$Exe = '$lit\zig-out\bin\ghoztty.exe', [string]`$Repo = '$lit')`nif (-not (Test-Path `$Exe)) { `$Exe = '$lit\zig-out\bin\ghoztty.exe' }`n'ALL PASS'`n"
        'cls-literal'   = "`$x = '$lit\src\a.txt'`n'ALL PASS'`n"
    }
    foreach ($k in $cls.Keys) { Write-Fixture (Join-Path $fake "test\win32\$k.ps1") $cls[$k] }
    $c = @{}
    foreach ($k in $cls.Keys) { $c[$k] = Get-AcceptanceScriptClass -Path (Join-Path $fake "test\win32\$k.ps1") -RepoLiteral $lit }
    Check 'A1 a script with nothing shared is parallel' ($c['cls-plain'].Class -eq 'parallel') $c['cls-plain'].Class
    Check 'A2 patterns that appear only in comments do not pin a script' ($c['cls-comment'].Class -eq 'parallel') ($c['cls-comment'].Reasons -join '; ')
    Check 'A3 the clipboard in code makes it exclusive' ($c['cls-clip'].Class -eq 'exclusive') $c['cls-clip'].Class
    Check 'A4 # @timing-sensitive makes it exclusive' ($c['cls-timing'].Class -eq 'exclusive' -and ($c['cls-timing'].Reasons -join ' ') -match 'timing-sensitive') ($c['cls-timing'].Reasons -join '; ')
    Check 'A5 # @parallel-unsafe makes it exclusive' ($c['cls-unsafe'].Class -eq 'exclusive') $c['cls-unsafe'].Class
    Check 'A6 the unscoped agent state dir in code makes it main' ($c['cls-agentdir'].Class -eq 'main') $c['cls-agentdir'].Class
    $inj = $c['cls-inject']
    Check 'A7 repo-path parameter defaults and the Test-Path fallback are injected, not refused' `
        ($inj.Class -eq 'parallel' -and $inj.Inject['Exe'] -eq 'zig-out\bin\ghoztty.exe' -and $inj.Inject.Contains('Repo') -and $inj.Inject['Repo'] -eq '') `
        ("class=$($inj.Class) inject=$(($inj.Inject.Keys | ForEach-Object { "$_=$($inj.Inject[$_])" }) -join ',') reasons=$($inj.Reasons -join ';')")
    Check 'A8 any other literal repo path pins it to main' ($c['cls-literal'].Class -eq 'main') $c['cls-literal'].Class
    $marked = 'drag-perf', 'ipc-startup-latency', 'layout-capture-cost', 'pane-ingest-lag', 'profile-latency',
    'resize-debounce', 'resize-flicker', 'send-keys-soak', 'soak', 'chooser-session-cpu'
    $notExcl = @($marked | Where-Object { (Get-AcceptanceScriptClass -Path (Join-Path $PSScriptRoot "$_.ps1") -RepoLiteral $RepoRoot).Class -ne 'exclusive' })
    Check 'A9 the suite''s declared timing-sensitive scripts all classify exclusive' ($notExcl.Count -eq 0) ($notExcl -join ', ')
    foreach ($k in $cls.Keys) { Remove-Item -LiteralPath (Join-Path $fake "test\win32\$k.ps1") -Force }

    # The `due` job list, from the shape guard-due check -Json really prints
    # (an array). PS 5.1 hands a JSON array down as ONE object; the first cut
    # looped over that and answered "nothing is due" over 13 due rows.
    $gj = ConvertTo-Json -Depth 3 -InputObject @(
        [pscustomobject]@{ Name = 'a'; Kind = 'due'; Advisory = $false; Script = 'test\win32\a.ps1'; RunArgs = '' },
        [pscustomobject]@{ Name = 'b'; Kind = 'current'; Advisory = $false; Script = 'test\win32\b.ps1'; RunArgs = '' },
        [pscustomobject]@{ Name = 'c'; Kind = 'due'; Advisory = $true; Script = 'test\win32\c.ps1'; RunArgs = '' },
        [pscustomobject]@{ Name = 'd'; Kind = 'due'; Advisory = $false; Script = 'test\win32\d.ps1'; RunArgs = '-RequireX' },
        [pscustomobject]@{ Name = 'a2'; Kind = 'due'; Advisory = $false; Script = 'test\win32\a.ps1'; RunArgs = '' })
    $dj = @(Get-AcceptanceDueJobs -GuardJson $gj)
    Check 'A10 due = every blocking DUE row, once per script+args, with its run args' `
        ($dj.Count -eq 2 -and $dj[0].Script -eq 'test\win32\a.ps1' -and $dj[1].Script -eq 'test\win32\d.ps1' -and $dj[1].Args -eq '-RequireX') `
        (($dj | ForEach-Object { "$($_.Script) $($_.Args)" }) -join ' | ')

    # A timeout declaration counts only as a real comment. test\win32\suite-run.ps1
    # writes one into a fixture here-string, and the raw-line regex capped that
    # harness itself at 40s - the first `due` run scored it STALL.
    $hs = "`$f = @'`n# suite-timeout-sec: 40`n'@`n'ALL PASS'`n"
    $real = "# suite-timeout-sec: 1200`r`n'ALL PASS'`r`n"
    Check 'A11 a timeout declared in a real comment counts (CRLF too); one inside a here-string does not' `
        ((Get-ScriptTimeout -Text $real) -eq 1200 -and (Get-ScriptTimeout -Text $hs) -eq 0) `
        ("real=$(Get-ScriptTimeout -Text $real) herestring=$(Get-ScriptTimeout -Text $hs)")

    # ---- B: worker root ------------------------------------------------------------
    $w1 = Join-Path $wbase 'w1'; $w2 = Join-Path $wbase 'w2'
    $n1 = Sync-AcceptanceWorkerRoot -Repo $fake -Root $w1
    $n2 = Sync-AcceptanceWorkerRoot -Repo $fake -Root $w2
    Check 'B1 every top-level directory is a junction, the repo''s zig-out is a real directory' `
        ((Test-ApReparsePoint (Join-Path $w1 'src')) -and (Test-ApReparsePoint (Join-Path $w1 'test')) -and
        (Test-Path (Join-Path $w1 'zig-out\bin\ghoztty.exe')) -and -not (Test-ApReparsePoint (Join-Path $w1 'zig-out'))) ''
    Check 'B2 other zig-out* dirs are not mirrored' (-not (Test-Path (Join-Path $w1 'zig-out-other'))) ''
    Check 'B3 zig-out is hard-linked file for file' ($n1 -eq 2 -and $n2 -eq 2) "linked $n1 / $n2"
    Write-Fixture (Join-Path $fake 'src\a.txt') 'edited'
    Check 'B4 the mirror shows the live tree (an edit in the repo is visible through it)' `
        ((Get-Content -Raw (Join-Path $w1 'src\a.txt')) -eq 'edited') ''
    $again = Sync-AcceptanceWorkerRoot -Repo $fake -Root $w1
    Check 'B5 re-syncing an existing root is clean and idempotent' ($again -eq 2 -and (Test-ApReparsePoint (Join-Path $w1 'src'))) "linked $again"
    $probe = Join-Path $env:TEMP "ap-probe-$tag"
    Sync-AcceptanceWorkerRoot -Repo $fake -Root $probe | Out-Null
    Remove-AcceptanceWorkerRoot -Root $probe
    Check 'B6 tearing a root down removes it and leaves every mirrored file in the repo' `
        (-not (Test-Path $probe) -and (Test-Path (Join-Path $fake 'src\a.txt')) -and (Test-Path (Join-Path $fake 'build.zig')) -and
        (Test-Path (Join-Path $fake 'zig-out\bin\ghoztty.exe')) -and (Test-Path (Join-Path $fake 'test\win32\lib\CleanSlate.ps1'))) ''
    $trap = Join-Path $env:TEMP "ap-trap-$tag"
    New-Item -ItemType Directory -Force $trap | Out-Null
    cmd /d /c "mklink /J `"$(Join-Path $trap 'link')`" `"$(Join-Path $fake 'src')`"" | Out-Null
    $refused = $false
    try { Remove-ApLinkTree $trap } catch { $refused = $true }
    Check 'B7 the link-tree delete refuses a tree holding a junction (it would follow it)' `
        ($refused -and (Test-Path (Join-Path $fake 'src\a.txt'))) ''
    Remove-ApJunction (Join-Path $trap 'link'); [IO.Directory]::Delete($trap, $true)

    # ---- C: the planted overlap -----------------------------------------------------
    $exe1 = Join-Path $w1 'zig-out\bin\ghoztty.exe'
    $exe2 = Join-Path $w2 'zig-out\bin\ghoztty.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo -ArgumentList $exe1, '-n 120 127.0.0.1'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
    $app1 = [System.Diagnostics.Process]::Start($psi); $planted += $app1
    Start-Sleep -Milliseconds 500
    $seen = @(Get-CimInstance Win32_Process -Filter "ProcessId=$($app1.Id)")
    Check 'C0 the stand-in app runs out of worker 1 (ExecutablePath is the worker path)' `
        ($seen.Count -eq 1 -and $seen[0].ExecutablePath -ieq $exe1) "$($seen[0].ExecutablePath)"

    $cs2 = Join-Path $w2 'test\win32\lib\CleanSlate.ps1'
    $cs1 = Join-Path $w1 'test\win32\lib\CleanSlate.ps1'
    $out2 = Invoke-Child ". '$cs2'; Stop-RepoGhoztty -Exe '$exe2' -SettleMs 0"
    Check 'C1 worker 2''s clean-slate kill leaves worker 1''s app alive' (-not $app1.HasExited) ($out2 -join ' | ')
    $out3 = Invoke-Child ". '$cs2'; try { Stop-RepoGhoztty -Exe '$exe1' -SettleMs 0; 'NOT REFUSED' } catch { 'REFUSED: ' + `$_.Exception.Message }"
    Check 'C2 worker 2''s CleanSlate refuses worker 1''s exe as not under its repo' `
        (($out3 -join ' ') -match 'REFUSED: .*not under the repo' -and -not $app1.HasExited) ($out3 -join ' | ')
    $swept = Stop-ApWorkerProcess -Root $w2
    Check 'C3 the runner''s per-worker sweep of worker 2 leaves worker 1''s app alive' ($swept -eq 0 -and -not $app1.HasExited) "swept $swept"
    $out4 = Invoke-Child ". '$cs1'; Stop-RepoGhoztty -Exe '$exe1' -SettleMs 0"
    $app1.WaitForExit(5000) | Out-Null
    Check 'C4 positive control: worker 1''s own clean-slate does kill it' ($app1.HasExited) ($out4 -join ' | ')

    # ---- D: the schedule ------------------------------------------------------------
    New-Item -ItemType Directory -Force (Join-Path $fixLog 'running') | Out-Null
    $prologue = @'
$me = Split-Path -Leaf $PSCommandPath
$start = Get-Date
$runFile = Join-Path $env:AP_FIXTURE_LOG ('running\' + [guid]::NewGuid().ToString('N'))
Set-Content -LiteralPath $runFile -Value $me
function Save-Record([string]$verdictKind, [int]$others) {
    Remove-Item -LiteralPath $runFile -Force -ErrorAction SilentlyContinue
    $rec = [pscustomobject]@{ name = $me; start = $start.ToString('o'); end = (Get-Date).ToString('o')
        root = $PSScriptRoot; local = $env:LOCALAPPDATA; inst = $env:GHOZTTY_AGENT_INSTANCE
        sock = $env:GHOZTTY_IPC_SOCKET; exe = $script:Exe; exeOk = [bool]($script:Exe -and (Test-Path $script:Exe)); others = $others }
    $rec | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $env:AP_FIXTURE_LOG ($me + '.' + [guid]::NewGuid().ToString('N') + '.json'))
}
'@
    $exeParam = "param([string]`$Exe = '$fake\zig-out\bin\ghoztty.exe')`n"
    $fx = [ordered]@{
        'p1'     = $exeParam + $prologue + "Start-Sleep -Seconds 4`nSave-Record pass 0`n'ALL PASS'`n"
        'p2'     = $exeParam + $prologue + "Start-Sleep -Seconds 4`nSave-Record pass 0`n'ALL PASS'`n"
        'flaky'  = $exeParam + $prologue + "Start-Sleep -Seconds 2`n`$n = @(Get-ChildItem (Join-Path `$env:AP_FIXTURE_LOG 'running')).Count - 1`nSave-Record x `$n`nif (`$n -gt 0) { '1 FAILURE(S)'; exit 1 }`n'ALL PASS'`n"
        'p3'     = $exeParam + $prologue + "Start-Sleep -Seconds 4`nSave-Record pass 0`n'ALL PASS'`n"
        'p4'     = $exeParam + $prologue + "Start-Sleep -Seconds 3`nSave-Record pass 0`n'ALL PASS'`n"
        'tsens'  = "# @timing-sensitive - fixture`n" + $prologue + "Start-Sleep -Seconds 2`nSave-Record pass 0`n'ALL PASS'`n"
        'excl'   = $prologue + "if (`$false) { Set-Clipboard 'x' }`nStart-Sleep -Seconds 2`nSave-Record pass 0`n'ALL PASS'`n"
        'm1'     = $prologue + "`$d = 'local-agent-debug'`nStart-Sleep -Seconds 3`nSave-Record pass 0`n'ALL PASS'`n"
        'm2'     = $prologue + "`$d = 'local-agent-debug'`nStart-Sleep -Seconds 3`nSave-Record pass 0`n'ALL PASS'`n"
        'red'    = $prologue + "Save-Record fail 0`n'1 FAILURE(S)'`nexit 1`n"
        'skipper' = $prologue + "Save-Record skip 0`n'SKIP ALL: fixture box cannot answer'`nexit 0`n"
    }
    foreach ($k in $fx.Keys) { Write-Fixture (Join-Path $fake "test\win32\$k.ps1") $fx[$k] }
    $jobs = @($fx.Keys | ForEach-Object { [pscustomobject]@{ Script = "test\win32\$_.ps1"; Args = '' } })

    $env:AP_FIXTURE_LOG = $fixLog
    $env:GHOZTTY_IPC_SOCKET = '\\.\pipe\ap-fixture-must-not-leak'
    $priorInst = $env:GHOZTTY_AGENT_INSTANCE
    Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $res4 = @(Invoke-AcceptanceRun -Repo $fake -Jobs $jobs -Width 4 -LogDir (Join-Path $fixLog 'w4') -TimeoutSec 120)
    $clock.Stop()
    $wall4 = $clock.Elapsed.TotalSeconds
    $recs = @(Get-ChildItem -LiteralPath $fixLog -Filter *.json | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json } |
        ForEach-Object { $_ | Add-Member -NotePropertyName s -NotePropertyValue ([datetime]$_.start) -PassThru | Add-Member -NotePropertyName e -NotePropertyValue ([datetime]$_.end) -PassThru })
    Get-ChildItem -LiteralPath $fixLog -Filter *.json | Remove-Item -Force

    $ov = @(Test-AcceptanceOverlap -Results $res4)
    Check 'D1 the runner''s own timeline shows no schedule violation' ($ov.Count -eq 0) ($ov -join ' | ')
    function Test-Ov($a, $b) { return ($a.s -lt $b.e -and $b.s -lt $a.e) }
    $alone = @($recs | Where-Object { $_.name -in @('tsens.ps1', 'excl.ps1') })
    $hits = @(foreach ($x in $alone) { foreach ($y in $recs) { if ($y -ne $x -and (Test-Ov $x $y)) { "$($x.name)~$($y.name)" } } })
    Check 'D2 a timing-sensitive and an exclusive script overlap nothing (fixtures'' own clocks)' `
        ($alone.Count -eq 2 -and $hits.Count -eq 0) ("records=$($alone.Count) overlaps=" + ($hits -join ','))
    $mains = @($recs | Where-Object { $_.name -in @('m1.ps1', 'm2.ps1') })
    Check 'D3 two main-lane scripts never run at once' ($mains.Count -eq 2 -and -not (Test-Ov $mains[0] $mains[1])) ''
    $par = @($recs | Where-Object { $_.name -match '^p\d' })
    $pairs = 0
    for ($a = 0; $a -lt $par.Count; $a++) { for ($b = $a + 1; $b -lt $par.Count; $b++) { if (Test-Ov $par[$a] $par[$b]) { $pairs++ } } }
    $sumSec = ($res4 | Where-Object { $_.Phase -eq 'pool' } | ForEach-Object { ($_.Ended - $_.Started).TotalSeconds } | Measure-Object -Sum).Sum
    Check 'D4 the parallel scripts really ran side by side' ($par.Count -eq 4 -and $pairs -ge 3 -and $wall4 -lt $sumSec) ("overlapping pairs=$pairs wall=$([int]$wall4)s script-time=$([int]$sumSec)s")
    $roots = @($par | ForEach-Object { $_.root } | Sort-Object -Unique)
    $locals = @($par | ForEach-Object { $_.local } | Sort-Object -Unique)
    $insts = @($par | ForEach-Object { $_.inst } | Sort-Object -Unique)
    $okRoots = @($par | Where-Object { $_.root -like "$wbase\w*\test\win32" }).Count -eq $par.Count
    Check 'D5 each parallel child ran from a worker root, with a worker LOCALAPPDATA and agent lineage' `
        ($okRoots -and $roots.Count -ge 3 -and $locals.Count -eq $roots.Count -and $insts.Count -eq $roots.Count -and
        @($par | Where-Object { $_.inst -like 'apw*' -and $_.local -like "$wbase\w*-local" }).Count -eq $par.Count) `
        ("roots=$($roots -join ',') locals=$($locals.Count) insts=$($insts -join ',')")
    Check 'D6 no worker child inherited the caller''s pane socket' (@($par | Where-Object { $_.sock }).Count -eq 0) ''
    Check 'D7 the injected -Exe names the worker''s own copy, and it exists' `
        (@($par | Where-Object { $_.exeOk -and $_.exe -like "$wbase\w*\zig-out\bin\ghoztty.exe" }).Count -eq $par.Count) (($par | ForEach-Object { $_.exe }) -join ',')
    $nonpar = @($recs | Where-Object { $_.name -in @('m1.ps1', 'm2.ps1', 'tsens.ps1', 'excl.ps1') })
    Check 'D8 main and exclusive scripts ran from the real repo with the caller''s environment' `
        (@($nonpar | Where-Object { $_.root -eq (Join-Path $fake 'test\win32') -and $_.sock -and -not $_.inst }).Count -eq 4) ''
    $f4 = @(Get-AcceptanceFinal -Results $res4)
    $byName = @{}; foreach ($f in $f4) { $byName[$f.Name] = $f }
    Check 'D9 a red script stays red, a SKIP ALL scores skip' ($byName['red.ps1'].Kind -eq 'fail' -and $byName['skipper.ps1'].Kind -eq 'skip') ''
    $fl = $byName['flaky.ps1']
    Check 'D10 red beside others and green alone: re-run, PARALLEL-SENSITIVE, scored by the alone run' `
        ($fl.PoolKind -eq 'fail' -and $fl.AloneKind -eq 'pass' -and $fl.Kind -eq 'pass' -and $fl.ParallelSensitive) `
        ("pool=$($fl.PoolKind) alone=$($fl.AloneKind) final=$($fl.Kind)")
    Check 'D11 a script red both ways is not called parallel-sensitive' ($byName['red.ps1'].AloneKind -eq 'fail' -and -not $byName['red.ps1'].ParallelSensitive) ''

    # The oracle can go red: plant the three bad schedules it exists to catch.
    $t0 = Get-Date
    $mk = { param($n, $cl, $slot, $s, $e, $ph = 'pool') [pscustomobject]@{ Name = $n; Class = $cl; Slot = $slot; Phase = $ph; Started = $t0.AddSeconds($s); Ended = $t0.AddSeconds($e) } }
    $badX = @(Test-AcceptanceOverlap -Results @((& $mk 'a' 'exclusive' 0 0 10), (& $mk 'b' 'parallel' 1 5 15)))
    $badM = @(Test-AcceptanceOverlap -Results @((& $mk 'a' 'main' 0 0 10), (& $mk 'b' 'main' 0 5 15)))
    $badS = @(Test-AcceptanceOverlap -Results @((& $mk 'a' 'parallel' 2 0 10), (& $mk 'b' 'parallel' 2 5 15)))
    $good = @(Test-AcceptanceOverlap -Results @((& $mk 'a' 'parallel' 1 0 10), (& $mk 'b' 'parallel' 2 5 15), (& $mk 'c' 'main' 0 0 15), (& $mk 'd' 'exclusive' 0 16 20)))
    Check 'D12 negative control: the overlap oracle flags an exclusive overlap, two mains, and a reused slot' `
        ($badX.Count -eq 1 -and $badM.Count -eq 1 -and $badS.Count -eq 1 -and $good.Count -eq 0) "x=$($badX.Count) m=$($badM.Count) s=$($badS.Count) good=$($good.Count)"

    # ---- E: serial and parallel agree -----------------------------------------------
    $res1 = @(Invoke-AcceptanceRun -Repo $fake -Jobs $jobs -Width 1 -LogDir (Join-Path $fixLog 'w1') -TimeoutSec 120)
    $f1 = @(Get-AcceptanceFinal -Results $res1)
    $diff = @(foreach ($f in $f1) { if ($byName[$f.Name].Kind -ne $f.Kind) { "$($f.Name): serial=$($f.Kind) width4=$($byName[$f.Name].Kind)" } })
    Check 'E1 -Width 1 and -Width 4 score the same final verdicts' ($f1.Count -eq $f4.Count -and $diff.Count -eq 0) ($diff -join ' | ')
    Check 'E2 -Width 1 runs every script from the real repo, one at a time' `
        (@($res1 | Where-Object { $_.Class -eq 'serial' }).Count -eq $jobs.Count -and @(Test-AcceptanceOverlap -Results $res1).Count -eq 0) ''

    # ---- F: stale build refused up front, fail fast (T1961) -------------------------
    . (Join-Path $RepoRoot 'scripts\lib\AcceptanceFresh.ps1')
    $fexe = Join-Path $fake 'zig-out\bin\ghoztty.exe'
    $witness = Join-Path $fake 'zig-out\bin\.build-fresh-witness.json'
    $marker = Join-Path $fixLog 'probe-ran.txt'
    Write-Fixture (Join-Path $fake 'test\win32\probe.ps1') "Set-Content -LiteralPath (Join-Path `$env:AP_FIXTURE_LOG 'probe-ran.txt') -Value ran`n'ALL PASS'`n"
    $now = Get-Date
    function Set-FixtureAge([bool]$Stale) {
        # Stale: the newest source is newer than the exe. Fresh: the reverse.
        Remove-Item -LiteralPath $witness -Force -ErrorAction SilentlyContinue
        foreach ($f in (Join-Path $fake 'src\a.txt'), (Join-Path $fake 'build.zig')) { (Get-Item $f).LastWriteTime = $now.AddHours(-2) }
        (Get-Item $fexe).LastWriteTime = $now.AddHours(-1)
        if ($Stale) { (Get-Item (Join-Path $fake 'src\a.txt')).LastWriteTime = $now.AddMinutes(-5) }
    }
    function Invoke-Runner([string]$ArgText) {
        $ErrorActionPreference = 'Continue'
        $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$RepoRoot\scripts\acceptance-parallel.ps1' $ArgText -Repo '$fake' -LogDir '$fixLog\runner'; exit `$LASTEXITCODE" 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
    }

    Set-FixtureAge $true
    $r = Invoke-Runner "run -Scripts probe.ps1 -Width 1 -NoRebuild"
    Check 'F1 THE PLANTED STALE BUILD: the run is refused (exit 4) before any script starts' `
        ($r.Code -eq 4 -and $r.Text -match 'BUILD STALE - REFUSED, nothing launched' -and $r.Text -match 'src\\a\.txt' -and -not (Test-Path $marker)) `
        ("exit=$($r.Code) probeRan=$(Test-Path $marker) :: $($r.Text)")
    Set-FixtureAge $false
    $r = Invoke-Runner "run -Scripts probe.ps1 -Width 1 -NoRebuild"
    Check 'F2 positive control: the same run over a fresh exe starts the script and passes' `
        ($r.Code -eq 0 -and $r.Text -match 'BUILD FRESH' -and (Test-Path $marker)) ("exit=$($r.Code) :: $($r.Text)")
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

    Set-FixtureAge $true
    $p = Invoke-AcceptanceFreshPreflight -Repo $fake -Builder { param($x) $false }
    Check 'F3 a stale exe whose rebuild FAILS refuses the run' ($p.State -eq 'refused' -and -not $p.Ok -and $p.Line -match 'rebuild FAILED') $p.Line
    $script:builds = 0
    $p = Invoke-AcceptanceFreshPreflight -Repo $fake -Builder { param($x) $script:builds++; $true }
    $p2 = Invoke-AcceptanceFreshPreflight -Repo $fake -Builder { param($x) $script:builds++; $true }
    Check 'F4 a stale exe is rebuilt ONCE; a build that relinked nothing still clears it (witness), so the next ask builds nothing' `
        ($p.State -eq 'rebuilt' -and $p.Ok -and $p2.State -eq 'fresh' -and $script:builds -eq 1 -and (Test-Path $witness)) "first=$($p.State) second=$($p2.State) builds=$($script:builds)"
    Set-FixtureAge $false
    $p = Invoke-AcceptanceFreshPreflight -Repo $fake -Builder { throw 'a fresh exe must not be rebuilt' }
    Check 'F5 a fresh exe is not rebuilt' ($p.State -eq 'fresh' -and $p.Ok) $p.Line
    Rename-Item -LiteralPath $fexe -NewName 'ghoztty.exe.away'
    $p = Invoke-AcceptanceFreshPreflight -Repo $fake -NoRebuild
    Rename-Item -LiteralPath "$fexe.away" -NewName 'ghoztty.exe'
    Check 'F6 a missing exe is refused, not waved through' ($p.State -eq 'refused' -and $p.Line -match 'no ghoztty.exe') $p.Line

    # Fail fast: the first red stops anything new from starting.
    $ffJobs = @('red', 'p1', 'p2', 'p3', 'p4', 'excl') | ForEach-Object { [pscustomobject]@{ Script = "test\win32\$_.ps1"; Args = '' } }
    $ff1 = @(Invoke-AcceptanceRun -Repo $fake -Jobs $ffJobs -Width 1 -LogDir (Join-Path $fixLog 'ff1') -TimeoutSec 120 -FailFast)
    Check 'F7 -FailFast at -Width 1: the red is the last thing that ran' ($ff1.Count -eq 1 -and $ff1[0].Name -eq 'red.ps1') (($ff1 | ForEach-Object { $_.Name }) -join ',')
    $ff2 = @(Invoke-AcceptanceRun -Repo $fake -Jobs $ffJobs -Width 2 -LogDir (Join-Path $fixLog 'ff2') -TimeoutSec 120 -FailFast)
    $ran2 = @($ff2 | Where-Object { $_.Phase -eq 'pool' } | ForEach-Object { $_.Name })
    Check 'F8 -FailFast in the pool: the running neighbour finishes, nothing else starts, no exclusive, the red is still confirmed alone' `
        ($ran2.Count -eq 2 -and $ran2 -contains 'red.ps1' -and $ran2 -contains 'p1.ps1' -and $ran2 -notcontains 'excl.ps1' -and
        @($ff2 | Where-Object { $_.Phase -eq 'confirm' -and $_.Name -eq 'red.ps1' }).Count -eq 1) ("pool=" + ($ran2 -join ','))
    $ffAll = @(Invoke-AcceptanceRun -Repo $fake -Jobs @($ffJobs | Select-Object -Skip 1) -Width 2 -LogDir (Join-Path $fixLog 'ff3') -TimeoutSec 120 -FailFast)
    Check 'F9 -FailFast with nothing red runs everything' (@($ffAll | Where-Object { $_.Phase -eq 'pool' }).Count -eq 5) "$($ffAll.Count)"
    $r = Invoke-Runner "run -Scripts 'red.ps1,probe.ps1' -Width 1 -FailFast"
    Check 'F10 the runner names what -FailFast never ran, and a skipped script is not GREEN' `
        ($r.Code -eq 1 -and $r.Text -match 'NOT RUN \(-FailFast stopped at the first red\): probe\.ps1' -and $r.Text -match 'ACCEPTANCE RED' -and -not (Test-Path $marker)) `
        ("exit=$($r.Code) :: $($r.Text)")

    # Most specific harness first: the changed feature's own row before the sweeps.
    $oj = ConvertTo-Json -Depth 4 -InputObject @(
        [pscustomobject]@{ Kind = 'due'; Advisory = $false; Script = 'test\win32\audit.ps1'; RunArgs = ''; Files = @(1..400 | ForEach-Object { "f$_" }) },
        [pscustomobject]@{ Kind = 'due'; Advisory = $false; Script = 'test\win32\feature.ps1'; RunArgs = ''; Files = @('a', 'b', 'c') },
        [pscustomobject]@{ Kind = 'due'; Advisory = $false; Script = 'test\win32\mid.ps1'; RunArgs = ''; Files = @(1..9 | ForEach-Object { "m$_" }) },
        [pscustomobject]@{ Kind = 'due'; Advisory = $false; Script = 'test\win32\feature2.ps1'; RunArgs = ''; Files = @('x', 'y', 'z') })
    $order = (@(Get-AcceptanceDueJobs -GuardJson $oj) | ForEach-Object { Split-Path -Leaf $_.Script }) -join ','
    Check 'F11 due runs the most specific harness first, ties in guard order' ($order -eq 'feature.ps1,feature2.ps1,mid.ps1,audit.ps1') $order
    if ($priorInst) { $env:GHOZTTY_AGENT_INSTANCE = $priorInst }
}
catch { Write-Host "FAIL  the harness threw: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"; $script:Failures++ }
finally {
    Remove-Item Env:AP_FIXTURE_LOG -ErrorAction SilentlyContinue
    try { Remove-FakeTree } catch { Write-Host "FAIL  teardown: $($_.Exception.Message)"; $script:Failures++ }
}

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard acceptance-parallel -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
