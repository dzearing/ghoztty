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
#      two panes report one shell pid. And (T1687) the pane that was refused
#      the session SAYS so - a restored-elsewhere notice in its banner slot and
#      its scrollback - while the pane that kept it says nothing.
#   C. The same duplicate with each pane bringing its own banner back: the
#      refused pane keeps ITS banner (T422) and the notice stays in the
#      scrollback only.
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

# The APP only: the agent has to survive this, because it is what still holds
# the session the doctored manifest names. The shared kill is what waits for the
# processes to actually be gone (T688) instead of sleeping and hoping.
function Stop-App {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 1500)
}

# Wait until at least `$Want` panes are reporting a session id AND no listed
# pane is still without one. Polled rather than slept: an ATTACH publishes its
# id from the IO thread, so "the window is there" and "the pane knows its
# session" are different moments - and the two halves of the condition settle
# at different times. Waiting on the count alone returned the instant the
# restored panes were up, with the probe window this run launched itself still
# mid-attach, and B5 ("no restored pane is left without a session") then scored
# that moment as the defect it exists to catch. A wait that times out still
# returns the state it last saw, so a pane that genuinely never gets a shell
# still fails the assertion rather than hanging.
# `$Ignore` names the windows this script opened only to DRIVE the app - the
# probe that triggers the relaunch - whose own persistence is not the subject
# and is the one most exposed to T1688. Everything else must have settled.
#
# `$Require` names windows that must be PRESENT before the wait is over. A
# restore brings its windows back one at a time, so a count alone is satisfied
# by the wrong three: the run that exposed this had window-1, the probe and
# dupsessA settled while dupsessB was still being replayed, and scored its
# absence as the defect. Naming what the restore owes is the only condition
# that cannot be met early.
function Wait-Panes {
    param(
        [int]$Want,
        [int]$TimeoutSec = 60,
        [string[]]$Ignore = @(),
        [string[]]$Require = @()
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $p = @(Get-Panes)
        $unsettled = @($p | Where-Object { -not $_.sid -and $Ignore -notcontains $_.window })
        $absent = @($Require | Where-Object { $w = $_; -not (@($p | Where-Object { $_.window -eq $w }).Count) })
        if (@($p | Where-Object { $_.sid }).Count -ge $Want -and
            $unsettled.Count -eq 0 -and $absent.Count -eq 0) { return $p }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    return @(Get-Panes)
}

# Every terminal leaf as a real object - {window, id, sid, banner} - for the
# arms that need a leaf's pane id and banner (T1687). Walked rather than
# regex-sliced: the banner is free text and may contain anything the slicer
# above keys on. Viewer leaves carry no `pid` and are skipped.
function Get-Leaves {
    $raw = (Ghoz @('+list', '--json')).Output
    $out = New-Object System.Collections.ArrayList
    try { $doc = $raw | ConvertFrom-Json } catch { return @() }
    $walk = {
        param($node, $window)
        if ($null -eq $node) { return }
        if ($node -is [System.Array]) { foreach ($n in $node) { & $walk $n $window }; return }
        if ($node -isnot [System.Management.Automation.PSCustomObject]) { return }
        $names = $node.PSObject.Properties.Name
        if ($names -contains 'target') { $window = [string]$node.target }
        if ($names -contains 'pid' -and $names -contains 'session_id') {
            [void]$out.Add([pscustomobject]@{
                window = $window
                id     = [string]$node.id
                sid    = $node.session_id
                banner = [string]$node.banner
            })
        }
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Value -is [System.Array] -or $p.Value -is [System.Management.Automation.PSCustomObject]) {
                & $walk $p.Value $window
            }
        }
    }
    & $walk $doc ''
    return $out.ToArray()
}

# The pane's own scrollback, whitespace squeezed out: a notice WRAPS in a narrow
# pane, so the raw text never holds the sentence verbatim.
function Read-Tight([string]$PaneId) {
    $r = Ghoz @('+read', "--name=$PaneId", '--lines=400')
    return (([string]$r.Output) -replace "`0", '') -replace '\s', ''
}

# Poll until the leaf in `$Window` that does NOT hold `$Sid` shows a banner
# matching `$Pattern`, and hand back what was last seen. The notice banner is
# published from the pane's IO thread after bring-up (T977), so "the window is
# back" and "its banner is up" are different moments.
function Wait-LoserBanner([string[]]$Windows, [string]$Sid, [string]$Pattern, [int]$TimeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $leaves = @(Get-Leaves | Where-Object { $Windows -contains $_.window })
        $loser = @($leaves | Where-Object { $_.sid -and $_.sid -ne $Sid })
        if ($loser.Count -ge 1 -and $loser[0].banner -match $Pattern) { break }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    return $leaves
}

# Write a SECOND window into the manifest, under its own key, naming the SAME
# session as the window that records `$Sid` - the state the carried-window merge
# used to be able to write. `$Banner`, when given, is put on every leaf of BOTH
# windows, so the restore brings each pane's own banner back (T422).
function Write-DupManifest([string]$Sid, [string]$DupId, [string]$DupName, [string]$Banner) {
    $doc = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    $orig = @($doc.windows | Where-Object { ($_ | ConvertTo-Json -Depth 30) -match [regex]::Escape($Sid) })
    if ($orig.Count -lt 1) { return 0 }
    $dup = ($orig[0] | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $dup.id = $DupId
    foreach ($pair in @(@('uuid', "uuid-$DupId"), @('ipc_name', $DupName))) {
        if ($dup.PSObject.Properties.Name -contains $pair[0]) { $dup.($pair[0]) = $pair[1] }
        else { $dup | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
    }
    if ($Banner) {
        foreach ($w in @($orig[0], $dup)) {
            foreach ($tab in @($w.tabs)) {
                foreach ($node in @($tab.nodes)) {
                    if (-not $node.leaf) { continue }
                    if ($node.leaf.PSObject.Properties.Name -contains 'banner') { $node.leaf.banner = $Banner }
                    else { $node.leaf | Add-Member -NotePropertyName banner -NotePropertyValue $Banner }
                }
            }
        }
    }
    $doc.windows = @($doc.windows) + @($dup)
    # No Set-Content here: PS 5.1's utf8 writes a BOM, and the manifest reader
    # parses JSON from byte zero.
    [System.IO.File]::WriteAllText(
        $manifest,
        ($doc | ConvertTo-Json -Depth 40),
        (New-Object System.Text.UTF8Encoding($false)))
    return $orig.Count
}

function Show-Panes($panes) {
    return (($panes | ForEach-Object { "$($_.window)=$(if ($_.sid) { $_.sid } else { '<none>' })" }) -join ', ')
}

& {

try {
    "== A: one window, one session"
    # T1688: a window created while the app is still resolving its link to the
    # session manager is handed no agent at all and opens as a plain local
    # shell - no session id, ever. That is a real defect and has its own task;
    # it is not this script's subject, and it lands on the FIRST window this
    # script opens because that is the window closest to the launch. So the
    # fixture is BUILT rather than assumed: a window that came up unpersisted
    # is closed and asked for again, and the attempts are printed so a run that
    # needed three is visible as one that needed three. If no attempt produces
    # a persisted window, A1 fails loudly - a regression that stopped windows
    # being persisted at all still scores red rather than retrying forever.
    $mine = @()
    $panes = @()
    foreach ($attempt in 1..3) {
        [void](Ghoz @('+new-window', '--target=dupsessA'))
        $panes = Wait-Panes -Want 2 -TimeoutSec 25
        "  attempt ${attempt}: " + (Show-Panes $panes)
        $mine = @($panes | Where-Object { $_.window -eq 'dupsessA' -and $_.sid })
        if ($mine.Count -eq 1) { break }
        "  dupsessA came up without a session (T1688); closing it and asking again"
        [void](Ghoz @('+close', '--target=dupsessA'))
        Start-Sleep -Milliseconds 1500
    }
    Assert-GhozttyIsolated -Exe $Exe
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
    $named = Write-DupManifest -Sid $sid -DupId 'dup-window' -DupName 'dupsessB'
    Assert "B1 the manifest records the session under test" ($named -ge 1)
    if ($named -lt 1) { throw "the manifest does not name $sid" }
    "  manifest now names $sid in two windows (dupsessA, dupsessB)"

    # Relaunch. The restore replays both windows; only one of them may take the
    # session.
    [void](Ghoz @('+new-window', '--target=dupsessProbe'))
    $panes = Wait-Panes -Want 3 -TimeoutSec 90 -Ignore 'dupsessProbe' -Require 'dupsessB'
    "  panes after restore: " + (Show-Panes $panes)

    $withSid = @($panes | Where-Object { $_.sid -eq $sid })
    $onlyOne = ($withSid.Count -eq 1)
    if ($NegativeControl) { $onlyOne = -not $onlyOne }
    Assert "B2 exactly ONE pane holds the recorded session" $onlyOne
    Assert "B3 the duplicate window came back" (@($panes | Where-Object { $_.window -eq 'dupsessB' }).Count -ge 1)
    Assert "B4 some other pane has a session of its own" (@($panes | Where-Object { $_.sid -and $_.sid -ne $sid }).Count -ge 1)
    # The probe is excluded by name, not by luck: it is the window this script
    # launched to trigger the restore, it is not part of the manifest under
    # test, and it opens at the one moment T1688 can strike. A restored pane
    # without a session is the defect B5 is here for.
    $restored = @($panes | Where-Object { $_.window -ne 'dupsessProbe' })
    Assert "B5 no restored pane is left without a session" (@($restored | Where-Object { -not $_.sid }).Count -eq 0)

    # And the panes really are different shells, not one pid reported twice.
    $pids = @($panes | Where-Object { $_.pid } | ForEach-Object { $_.pid })
    Assert "B6 no two panes report the same shell pid" ($pids.Count -eq (@($pids | Sort-Object -Unique)).Count)

    # T1687: the pane that got a fresh shell SAYS so. Before, it came up looking
    # like any new terminal, so the pane the user expected their work in was
    # silently a different one. Neither window had a banner of its own, so the
    # notice may take the slot (T422) as well as the scrollback (T423).
    $pair = @('dupsessA', 'dupsessB')
    $leaves = @(Wait-LoserBanner -Windows $pair -Sid $sid -Pattern 'Session restored elsewhere')
    $loser = @($leaves | Where-Object { $_.sid -and $_.sid -ne $sid })
    $winner = @($leaves | Where-Object { $_.sid -eq $sid })
    "  leaves: " + (($leaves | ForEach-Object { "$($_.window)[$($_.id.Substring(0, [Math]::Min(8, $_.id.Length)))] banner='$($_.banner)'" }) -join '; ')
    Assert "B7 the pane refused the session shows the restored-elsewhere banner" `
        ($loser.Count -eq 1 -and $loser[0].banner -match 'Session restored elsewhere')
    $loserText = if ($loser.Count -eq 1) { Read-Tight $loser[0].id } else { '' }
    Assert "B8 ... and says so in its own scrollback, not only the banner" `
        ($loserText.Contains('Sessionrestoredelsewhere:') -and $loserText.Contains('Nothingwasclosed;thisisafreshshell.'))
    Assert "B9 ... and never with the agent-restart sentence, which would say the work was lost" `
        ($loser.Count -eq 1 -and $loser[0].banner -notmatch 'Session interrupted' -and -not $loserText.Contains('Sessioninterrupted'))
    $winnerText = if ($winner.Count -eq 1) { Read-Tight $winner[0].id } else { 'unread' }
    Assert "B10 the pane that kept the session shows no such notice" `
        ($winner.Count -eq 1 -and $winner[0].banner -notmatch 'restored elsewhere' -and -not $winnerText.Contains('Sessionrestoredelsewhere'))
    # The refused pane is a different shell, so it is a different pane: adopting
    # the recorded id gave both panes one id, and every `--target=<id>` then
    # reached whichever the registry found first (measured: B8 read the WINNER's
    # scrollback until the refused pane stopped adopting it).
    $ids = @($leaves | ForEach-Object { $_.id })
    Assert "B11 the two panes have different pane ids" `
        ($ids.Count -eq 2 -and (@($ids | Sort-Object -Unique)).Count -eq 2)
    $holder = if ($winner.Count -eq 1) { $winner[0].window } else { 'dupsessA' }

    "== C: a pane that brings its OWN banner back keeps it (T422)"
    # Same duplicate, but both windows now carry a banner of their own. The
    # notice's banner copy yields the slot to it; the scrollback copy stays.
    Stop-App
    $own = 'T1687-own-banner'
    $named = Write-DupManifest -Sid $sid -DupId 'dup-window-c' -DupName 'dupsessC' -Banner $own
    Assert "C1 the manifest records the session under test again" ($named -ge 1)
    if ($named -lt 1) { throw "the manifest no longer names $sid" }
    [void](Ghoz @('+new-window', '--target=dupsessProbe2'))
    [void](Wait-Panes -Want 3 -TimeoutSec 90 -Ignore @('dupsessProbe', 'dupsessProbe2') -Require 'dupsessC')
    $pairC = @($holder, 'dupsessC')
    $leavesC = @(Wait-LoserBanner -Windows $pairC -Sid $sid -Pattern ([regex]::Escape($own)))
    $loserC = @($leavesC | Where-Object { $_.sid -and $_.sid -ne $sid })
    "  leaves: " + (($leavesC | ForEach-Object { "$($_.window) banner='$($_.banner)'" }) -join '; ')
    Assert "C2 exactly one of the pair was refused the session" ($loserC.Count -eq 1)
    Assert "C3 the refused pane kept its OWN banner rather than the notice's" `
        ($loserC.Count -eq 1 -and $loserC[0].banner -match [regex]::Escape($own) -and $loserC[0].banner -notmatch 'restored elsewhere')
    $loserCText = if ($loserC.Count -eq 1) { Read-Tight $loserC[0].id } else { '' }
    Assert "C4 ... and still carries the notice in its scrollback" `
        ($loserCText.Contains('Sessionrestoredelsewhere:'))

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

# Top level, after the block: the body-complete rule reads the script's own
# flow, and a marker buried inside `& { ... }` is invisible to it (and to a
# reader asking where the run ends).
Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard restore-session-dup -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

exit (Complete-TestTranscript -Name 'restore-session-dup' -Path $transcript `
        -Label 'T1684 RESTORE-SESSION-DUP' -Pass $script:passes -Fail $script:failures).Code
