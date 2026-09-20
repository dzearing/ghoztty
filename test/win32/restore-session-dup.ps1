# Restore duplicate-session acceptance (tracker T1684).
#
# THE BEHAVIOR. A session can only be shown in ONE pane. The agent rebinds a
# session to the newest ATTACH and never refuses (T703), so a second pane naming
# the same session does not share the shell - it TAKES it, and the pane that had
# it becomes a frozen picture the user can still type into. What the user
# reported on 2026-09-20 is that shape from the outside: "opening a new window
# did not start a default shell; the pane came up already attached to the same
# process another open window was running, so two windows are typing into one
# shell".
#
# WHERE A DUPLICATE COMES FROM. The launch restore reconciles TWO sources - the
# local manifest and the agent's layout blobs - and both describe windows by
# KEY. `reconcile` already refuses an agent window whose session a local window
# claimed, but nothing stopped the LOCAL manifest itself from naming one session
# in two windows, and `mergeCarried` could write exactly that: a carried window
# was adjudicated by its key alone, so a session that came back under a NEW key
# (a Restore All, an adoption) was recorded in the live window AND in the
# carried one.
#
# WHAT THIS SCRIPT PINS. The end of that story rather than the middle: whatever
# a manifest says, a restore attaches each session to at most one pane, and the
# other pane gets a shell of its own. The manifest here is written by hand into
# exactly the state the bug produced, which is also the only way to build it
# deterministically - `mergeCarried`'s own half is pinned by unit tests in the
# `none` lane (src\apprt\win32\session_layout.zig, "T1684: ...").
#
# Sections:
#   A. One window, one session: the baseline the duplicate is built from.
#   B. The manifest is doctored to name that session in TWO windows, the app is
#      killed (the agent keeps the session), and the relaunch is asserted:
#      exactly one pane holds the recorded session, the duplicate window is back
#      with a shell of its OWN, no restored pane is left session-less, and no
#      two panes report one shell pid.
#
# `-NegativeControl` inverts section B's central assertion, so a run can be seen
# scoring RED against the state it exists to refuse (go.md step 3).
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: a private
# IPC endpoint, a private agent lineage and a private %LOCALAPPDATA% (so the
# manifest this doctors is nobody else's), every launch on the background test
# desktop, and it only ever kills ghoztty / ghoztty-agent processes launched
# from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\restore-session-dup.ps1
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

$transcript = New-TestTranscript -Name 'restore-session-dup'
$savedLocalAppData = $env:LOCALAPPDATA

# A private lineage AND a private %LOCALAPPDATA%: this script REWRITES the
# session-layout manifest, and the shared debug one belongs to every other
# debug-lineage script on the box.
$sandbox = Join-Path $env:TEMP "ghoztty-t1684-$PID"
[void](Set-GhozttyTestIsolation -Tag 'dupsess' -ReleaseSandbox -SandboxRoot $sandbox)
Assert-GhozttyPrivateEndpoint -Exe $Exe

$manifest = Join-Path $sandbox ("ghoztty\session-layout-debug-" + $env:GHOZTTY_AGENT_INSTANCE + ".json")
$td = New-TestDesktop

function Ghoz([string[]]$GhozArgs) {
    return (Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs -Desktop $td -TimeoutSec 60)
}

# Every pane the app reports, as {window, pid, sid}. The JSON tree is recursive
# (splits nest), and this script only needs the flat per-window leaf facts, so
# it slices the text at the window boundaries rather than walking objects.
function Get-Panes {
    $j = (Ghoz @('+list', '--json')).Output
    $rows = @()
    $chunks = $j -split '(?="target":")'
    foreach ($c in $chunks) {
        $t = [regex]::Match($c, '^"target":"(?<t>[^"]*)"')
        if (-not $t.Success) { continue }
        foreach ($m in [regex]::Matches($c, '"pid":(?<p>\d+),"tty"')) {
            $tail = $c.Substring($m.Index)
            $s = [regex]::Match($tail, '"session_id":(?<s>"[^"]*"|null)')
            $sid = if ($s.Success -and $s.Groups['s'].Value -ne 'null') { $s.Groups['s'].Value.Trim('"') } else { $null }
            $rows += [pscustomobject]@{
                window = $t.Groups['t'].Value
                pid    = $m.Groups['p'].Value
                sid    = $sid
            }
        }
    }
    # No `return ,` here: the comma form hands the caller a one-element array
    # HOLDING the rows, and `$_.sid` over that enumerates members instead of
    # rows. Every call site wraps in @() for the single-row case.
    return $rows
}

function Stop-App {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 1500
}

# Wait until at least `$Want` panes are reporting a session id. Polled rather
# than slept: an ATTACH publishes its id from the IO thread, so "the window is
# there" and "the pane knows its session" are different moments.
function Wait-Panes([int]$Want, [int]$TimeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $p = @(Get-Panes)
        if (@($p | Where-Object { $_.sid }).Count -ge $Want) { return $p }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    return @(Get-Panes)
}

function Show-Panes($panes) {
    return (($panes | ForEach-Object { "$($_.window)=$(if ($_.sid) { $_.sid } else { '<none>' })" }) -join ', ')
}

& {

try {
    "== A: one window, one session"
    [void](Ghoz @('+new-window', '--target=dupsessA'))
    $panes = Wait-Panes 2
    "  panes: " + (Show-Panes $panes)
    Assert-GhozttyIsolated -Exe $Exe
    $mine = @($panes | Where-Object { $_.window -eq 'dupsessA' -and $_.sid })
    Assert "A1 the dupsessA pane came up with a session of its own" ($mine.Count -eq 1)
    if ($mine.Count -ne 1) { throw "no dupsessA pane to build the duplicate from" }
    $sid = $mine[0].sid
    "  session under test: $sid"

    # The manifest is written on a debounce; give the sync time to land it.
    $deadline = (Get-Date).AddSeconds(25)
    while (-not (Test-Path $manifest) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 700 }
    Assert "A2 the manifest was written to $manifest" (Test-Path $manifest)
    if (-not (Test-Path $manifest)) { throw "no manifest to doctor" }

    "== B: the same session named by TWO manifest windows"
    Stop-App
    $doc = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    $orig = @($doc.windows | Where-Object { ($_ | ConvertTo-Json -Depth 30) -match [regex]::Escape($sid) })
    Assert "B1 the manifest records the session under test" ($orig.Count -ge 1)
    if ($orig.Count -lt 1) { throw "the manifest does not name $sid" }

    # A SECOND window, its own key, naming the SAME session - the state the
    # carried-window merge used to be able to write.
    $dup = ($orig[0] | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $dup.id = 'dup-window'
    foreach ($pair in @(@('uuid', 'uuid-dup-window'), @('ipc_name', 'dupsessB'))) {
        if ($dup.PSObject.Properties.Name -contains $pair[0]) { $dup.($pair[0]) = $pair[1] }
        else { $dup | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
    }
    $doc.windows = @($doc.windows) + @($dup)
    # No Set-Content here: PS 5.1's utf8 writes a BOM, and the manifest reader
    # parses JSON from byte zero.
    [System.IO.File]::WriteAllText(
        $manifest,
        ($doc | ConvertTo-Json -Depth 40),
        (New-Object System.Text.UTF8Encoding($false)))
    "  manifest now describes $((@($doc.windows)).Count) window(s), two of them naming $sid"

    # Relaunch. The restore replays both windows; only one of them may take the
    # session.
    [void](Ghoz @('+new-window', '--target=dupsessProbe'))
    $panes = Wait-Panes 3 90
    "  panes after restore: " + (Show-Panes $panes)

    $withSid = @($panes | Where-Object { $_.sid -eq $sid })
    $onlyOne = ($withSid.Count -eq 1)
    if ($NegativeControl) { $onlyOne = -not $onlyOne }
    Assert "B2 exactly ONE pane holds the recorded session" $onlyOne
    Assert "B3 the duplicate window came back" (@($panes | Where-Object { $_.window -eq 'dupsessB' }).Count -ge 1)
    Assert "B4 some other pane has a session of its own" (@($panes | Where-Object { $_.sid -and $_.sid -ne $sid }).Count -ge 1)
    Assert "B5 no restored pane is left without a session" (@($panes | Where-Object { -not $_.sid }).Count -eq 0)

    # And the panes really are different shells, not one pid reported twice.
    $pids = @($panes | Where-Object { $_.pid } | ForEach-Object { $_.pid })
    Assert "B6 no two panes report the same shell pid" ($pids.Count -eq (@($pids | Sort-Object -Unique)).Count)

    Complete-TestBody  # T1039: the run reached the end of its body
} catch {
    "  FAIL setup: $_"
    $script:failures++
} finally {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900)
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

} 2>&1 | Tee-Object -FilePath $transcript

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard restore-session-dup -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

exit (Complete-TestTranscript -Name 'restore-session-dup' -Path $transcript `
        -Label 'T1684 RESTORE-SESSION-DUP' -Pass $script:passes -Fail $script:failures).Code
