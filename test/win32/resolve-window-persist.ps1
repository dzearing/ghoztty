# Window-opened-during-resolve persistence acceptance (tracker T1688).
#
# THE BEHAVIOR. The app keeps shells alive across restarts by handing them to
# the local session agent, and finding (or spawning) that agent takes a moment
# at startup. While it does, the app keeps answering IPC (T188) - so a
# `+new-window` issued in the first second of a launch used to be served from
# INSIDE the resolve, get "no agent yet", and open as a plain local shell: a
# window that looks normal, reports `session_id: null` forever, and is simply
# gone after the next restart. `test\win32\restore-session-dup.ps1` hit it about
# two runs in five.
#
# The fix holds that one request until the resolve returns, and serves it then.
#
# Sections:
#   A. Deterministic: the resolve is held open 2.5s by the debug hook
#      GHOZTTY_AGENT_RESOLVE_DELAY_MS, so the `+new-window` is GUARANTEED to
#      land inside it. The window must come up with a session, and so must the
#      launch window.
#   B. Natural: three cold launches with no hook at all, each asking for a
#      window straight away - the shape that found the bug. Every one must be
#      persisted.
#
# `-NegativeControl` runs section A with GHOZTTY_IPC_NO_RESOLVE_DEFER=1, which
# turns the fix off (debug builds only), so the run is seen scoring RED against
# the exact state it exists to refuse (go.md step 3).
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: every
# launch gets its own IPC endpoint, agent lineage and %LOCALAPPDATA% (so each
# one is a genuinely COLD agent spawn and restores nothing), runs on the
# background test desktop, and only ever kills ghoztty / ghoztty-agent processes
# launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\resolve-window-persist.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:passes = 0
$script:failures = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')

$transcript = New-TestTranscript -Name 'resolve-window-persist'
$savedLocalAppData = $env:LOCALAPPDATA
$sandboxes = @()
$td = New-TestDesktop

function Ghoz([string[]]$GhozArgs) {
    return (Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs -Desktop $td -TimeoutSec 60)
}

# Every pane the app reports, as {window, sid}. Same text slicing as
# restore-session-dup.ps1: the JSON tree nests splits, and only the flat
# per-window leaf facts matter here.
function Get-Panes {
    $j = (Ghoz @('+list', '--json')).Output
    $rows = @()
    foreach ($c in ($j -split '(?="target":")')) {
        $t = [regex]::Match($c, '^"target":"(?<t>[^"]*)"')
        if (-not $t.Success) { continue }
        foreach ($m in [regex]::Matches($c, '"pid":(?<p>\d+),"tty"')) {
            $s = [regex]::Match($c.Substring($m.Index), '"session_id":(?<s>"[^"]*"|null)')
            $sid = if ($s.Success -and $s.Groups['s'].Value -ne 'null') { $s.Groups['s'].Value.Trim('"') } else { $null }
            $rows += [pscustomobject]@{ window = $t.Groups['t'].Value; sid = $sid }
        }
    }
    return $rows
}

# Poll until `$Name` is listed and every listed pane has settled on a session,
# or the timeout passes. An ATTACH publishes its id from the IO thread, so the
# window appearing and its pane knowing its session are different moments. A
# pane that never gets one is exactly the defect, and it still fails the
# assertion: the wait returns the last state it saw rather than hanging.
function Wait-Settled([string]$Name, [int]$TimeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $p = @(Get-Panes)
        $mine = @($p | Where-Object { $_.window -eq $Name })
        if ($mine.Count -ge 1 -and @($p | Where-Object { -not $_.sid }).Count -eq 0) { return $p }
        Start-Sleep -Milliseconds 700
    } while ((Get-Date) -lt $deadline)
    return @(Get-Panes)
}

function Show-Panes($panes) {
    return (($panes | ForEach-Object { "$($_.window)=$(if ($_.sid) { $_.sid } else { '<none>' })" }) -join ', ')
}

# One cold launch in its own sandbox: ask for `$Name` straight away (the CLI
# starts the app and then sends the request, which is the launch-time race),
# wait for the panes to settle, report them, and tear the app AND its agent
# down so the next launch is cold again.
function Invoke-ColdLaunch([string]$Tag, [string]$Name) {
    $sandbox = Join-Path $env:TEMP "ghoztty-t1688-$Tag-$PID"
    $script:sandboxes += $sandbox
    [void](Set-GhozttyTestIsolation -Tag $Tag -ReleaseSandbox -SandboxRoot $sandbox -Quiet)
    # The isolation checks print their verdict; it is carried back in `log`
    # rather than left in the pipeline, where it would become the return value.
    $log = @(Assert-GhozttyPrivateEndpoint -Exe $Exe)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void](Ghoz @('+new-window', "--target=$Name"))
    $ms = $sw.ElapsedMilliseconds
    $panes = Wait-Settled -Name $Name
    $log += @(Assert-GhozttyIsolated -Exe $Exe)
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900)
    return [pscustomobject]@{ panes = $panes; ms = $ms; log = $log }
}

& {

try {
    "== A: a window asked for while the resolve is held open"
    $env:GHOZTTY_AGENT_RESOLVE_DELAY_MS = '2500'
    if ($NegativeControl) { $env:GHOZTTY_IPC_NO_RESOLVE_DEFER = '1' }
    $r = Invoke-ColdLaunch -Tag 'rdA' -Name 'rdA'
    Remove-Item Env:GHOZTTY_AGENT_RESOLVE_DELAY_MS -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_IPC_NO_RESOLVE_DEFER -ErrorAction SilentlyContinue
    $r.log
    "  +new-window answered in $($r.ms)ms; panes: " + (Show-Panes $r.panes)

    $mine = @($r.panes | Where-Object { $_.window -eq 'rdA' })
    Assert "A1 the requested window opened" ($mine.Count -ge 1)
    Assert "A2 the window asked for mid-resolve is persisted (has a session)" (@($mine | Where-Object { $_.sid }).Count -ge 1 -and @($mine | Where-Object { -not $_.sid }).Count -eq 0)
    $launch = @($r.panes | Where-Object { $_.window -ne 'rdA' })
    Assert "A3 the launch window is persisted too" ($launch.Count -ge 1 -and @($launch | Where-Object { -not $_.sid }).Count -eq 0)

    if (-not $NegativeControl) {
        "== B: three natural cold launches, window asked for straight away"
        foreach ($i in 1..3) {
            $r = Invoke-ColdLaunch -Tag "rdB$i" -Name "rdB$i"
            $r.log
            "  run ${i}: +new-window answered in $($r.ms)ms; panes: " + (Show-Panes $r.panes)
            $mine = @($r.panes | Where-Object { $_.window -eq "rdB$i" })
            Assert "B$i every pane of cold launch $i is persisted, the asked-for window included" ($mine.Count -ge 1 -and @($r.panes | Where-Object { -not $_.sid }).Count -eq 0)
        }
    }

} catch {
    "  FAIL setup: $_"
    $script:failures++
} finally {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900)
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
    foreach ($s in $sandboxes) { Remove-Item -LiteralPath $s -Recurse -Force -ErrorAction SilentlyContinue }
}

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard resolve-window-persist -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

exit (Complete-TestTranscript -Name 'resolve-window-persist' -Path $transcript `
        -Label 'T1688 RESOLVE-WINDOW-PERSIST' -Pass $script:passes -Fail $script:failures).Code
