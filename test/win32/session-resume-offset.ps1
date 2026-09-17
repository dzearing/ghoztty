# T739 acceptance: the resume offset a re-attach records must be the agent's
# stream head, not the head plus the size of the repaint the agent just injected.
#
# The defect: `Remote.appliedOffset()` - the number persisted in the session
# manifest as the NEXT attach's `last_byte_offset` - counted every byte fed to
# the parser. Two of the things the agent sends on ATTACH are not stream bytes
# at all: its `[N bytes of scrollback lost]` marker, and the `grid_snapshot`
# repaint of the visible screen. So every single re-attach recorded a position
# PAST the end of the agent's stream by exactly the repaint's size (169 bytes,
# measured while landing T666). The next attach was then clamped back to the
# head (T532) and whatever real output sat between the two was never replayed -
# invisible on a quiet pane, because the repaint covers the same screen, and
# silently lost output on a busy one.
#
# The fix labels the injection on the wire (`DATA_REPAINT`, 0x15, gated on
# `capability.repaint_data`), because it cannot be inferred: a repaint anchored
# at the head and the first LIVE frame after it are identical on the wire.
#
# The arms, all scored from the app's own attach log - the only place either
# number is observable, since a pane that skipped 169 bytes and a pane that did
# not look exactly the same:
#
#   A. Three kill/restore cycles of a QUIET pane. Every attach must report
#      `requested == head`, and the "recorded offset ... is ahead of the agent's
#      stream head" clamp warning must never appear.
#   B. The teeth, from the same tree: the same cycles with
#      GHOZTTY_RESUME_COUNT_BYTES=1, which puts the pre-T739 accounting back and
#      changes nothing else. The overshoot MUST return and the clamp MUST fire -
#      arm A asserts the absence of something, and an absence is evidence only
#      when the same harness can be made to see it present.
#   C. Skew: the same cycles with GHOSTTY_AGENT_SUPPRESS_CAPS=repaint_data, an
#      agent advertising the HELLO of a build that predates 0x15. The pane must
#      still restore, still be live, and still not overshoot.
#   D. The case the framing actually exists for (T804): the same cycles against
#      a peer that does NOT repaint on attach (GHOSTTY_AGENT_QUIET_ATTACH=1),
#      with the capability on. requested == head, with nothing behind the
#      injection to correct it.
#   E. The teeth for D, and the measurement T804 was filed for: the same
#      non-repainting peer with the LABEL taken away
#      (+ GHOSTTY_AGENT_SUPPRESS_CAPS=repaint_data). The overshoot MUST return
#      and the clamp MUST fire.
#
# Arm C passing is worth reading carefully, because it says where the fix
# actually lives. The accounting is client-side and anchor-authoritative, so on
# WINDOWS it lands even against an old agent: ConPTY repaints after every
# attach, that paint is real stream data anchored at the head, and it re-states
# the true position over the miscounted one. What the 0x15 framing buys is that
# the position is right BY CONSTRUCTION rather than because something arrived
# afterwards to correct it - which is the only thing that holds for a peer that
# does not repaint on attach.
#
# That last sentence is what arms D and E measure, and until T804 nothing did:
# C is green either way, so the labelling could have been wrong end to end and
# this harness would still have said ALL PASS. The peer it needs is one whose
# child answers a geometry change with silence - a POSIX agent, which this seat
# does not have - so the agent grows a second test seam beside the capability
# suppression it already has: GHOSTTY_AGENT_QUIET_ATTACH records an attaching
# client's geometry and leaves the child alone, which is a ConPTY that does not
# repaint, which is the POSIX shape. D and E then differ in exactly one bit -
# whether the injected repaint is LABELLED - and they come out opposite, which
# is the claim.
#
# Hermetic: a per-run LOCALAPPDATA, GHOSTTY_LOCAL_AGENT_BIN and IPC pipe suffix,
# run on a BACKGROUND Win32 desktop, and it only ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\session-resume-offset.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Cycles = 3,
    # Debugging only: run a subset of the arms. A partial run cannot stamp the
    # guard (a skipped section never does), so this is for iterating on one arm,
    # never for reporting a verdict.
    [string[]]$Arms = @('A', 'B', 'C', 'D', 'E'),
    [switch]$KeepRoot,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$repo = 'D:\git\ghoztty'
$root = Join-Path $env:TEMP "ghoztty-resume-offset-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}

# Kill ONLY the app: the detached agent keeps its PTYs, which is the whole
# scenario (quit / crash / upgrade, then re-attach).
function Stop-AppOnly {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 900)
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: on (default) - the restore path IS the subject.
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit, or ExitCode reads empty and
    # every `-eq 0` gate scores a working CLI as a failure (lib\ExitCodeAudit.ps1).
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tag, $timeoutSec = 12) {
    Run-CliArgs @('+list', '--json') "$tmp\list-$tag.json" $timeoutSec | Out-Null
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function All-Leaves($tree) {
    if ($null -eq $tree) { return , @() }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    $acc = @()
    foreach ($w in @($windows)) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Wait-PaneId($tag, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        foreach ($leaf in All-Leaves (Get-List $tag)) {
            if ($leaf.id) { return [string]$leaf.id }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

# ---- app log (the oracle) --------------------------------------------------
# Debug builds are Console-subsystem, so std.log goes to STDERR, captured per
# launch. Opened ReadWrite because the app still holds the handle.
function Read-AppLog($path) {
    if (-not $path -or -not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le 0) { return '' }
            $buf = New-Object byte[] $fs.Length
            $n = $fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        } finally { $fs.Dispose() }
    } catch { return '' }
}
# Poll: the line may not be flushed yet, and a single read would turn a timing
# gap into a false failure.
function Wait-AttachLine($path, $timeoutSec = 40) {
    # `labeled=` is the negotiated `repaint_data` bit as the CLIENT saw it, and
    # arms D/E turn on it being opposite in the two runs - so it is read from the
    # same line rather than inferred from the env var the arm set (T804).
    $rx = 'attach: requested=(\d+) head=(\d+) resumed_at=(\d+) repaints=(\w+) labeled=(\w+)'
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $m = [regex]::Match((Read-AppLog $path), $rx)
        if ($m.Success) {
            return @{
                requested = [uint64]$m.Groups[1].Value
                head      = [uint64]$m.Groups[2].Value
                resumed   = [uint64]$m.Groups[3].Value
                repaints  = ($m.Groups[4].Value -eq 'true')
                labeled   = ($m.Groups[5].Value -eq 'true')
            }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}
function Log-HasClampWarning($path) {
    return ((Read-AppLog $path) -match 'is ahead of the agent''s stream head')
}

# The manifest write is DEBOUNCED off layout mutations, and this test kills the
# app outright (no graceful quit, so no final sync) - so the capture whose
# offset the next launch resumes from has to be provoked. A window title pin is
# the cheapest mutation: it marks the layout dirty and changes nothing about the
# tree, and prints nothing into the pane (which matters here - the pane must
# stay QUIET after the capture, or `requested == head` is not the claim).
function Provoke-ManifestWrite($pane, $tag) {
    # Provoke until the recorded offset SETTLES, not once (T804). A single
    # capture races the pane: bytes still on their way from the agent are applied
    # after the snapshot is taken, and the manifest then holds a position BELOW
    # the head - which reads here as `requested != head` and is a property of the
    # sleep, not of the accounting. It was a rare flake in arms A and C, where
    # the next cycle's live output hides it; in the quiet arms the head never
    # moves again, so an early capture is wrong for the rest of the run (seen:
    # `D.1 requested offset == agent head (16 vs 409)`).
    #
    # Two consecutive reads agreeing is the settle condition, and the title
    # changes each round so every round is a genuine layout mutation rather than
    # a no-op the debounce can coalesce.
    $prev = [uint64]::MaxValue
    for ($k = 1; $k -le 8; $k++) {
        Run-CliArgs @('+rename', "--target=$pane", "--title=t739-quiet-$k") "$tmp\ren-$tag-$k.txt" 12 | Out-Null
        Start-Sleep -Milliseconds 900
        $offsets = @(Manifest-Offsets)
        $cur = if ($offsets.Count -gt 0) { ($offsets | Measure-Object -Maximum).Maximum } else { [uint64]0 }
        if ($cur -gt 0 -and $cur -eq $prev) { return }
        $prev = $cur
    }
}
function Manifest-Path { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }
function Manifest-Offsets {
    $p = Manifest-Path
    if (-not (Test-Path $p)) { return @() }
    $raw = Out-Text $p
    return @([regex]::Matches($raw, '"screen_snapshot_offset"\s*:\s*(\d+)') |
        ForEach-Object { [uint64]$_.Groups[1].Value })
}

# One kill/restore cycle. Returns the attach numbers the restored pane logged.
function Invoke-RestoreCycle($n, $arm) {
    Stop-AppOnly
    $log = Join-Path $tmp "app-$arm-$n.err.txt"
    # persistence: on (default) - a restore is the entire point.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @() -StdErr $log
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 45000
    if ($top -eq [IntPtr]::Zero) { return @{ up = $false; log = $log } }
    $att = Wait-AttachLine $log 45
    return @{ up = $true; log = $log; attach = $att; pid = $app.Pid }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$saved = @{
    lad  = $env:LOCALAPPDATA
    bin  = $env:GHOSTTY_LOCAL_AGENT_BIN
    pipe = $env:GHOZTTY_PIPE_SUFFIX
    supp = $env:GHOSTTY_AGENT_SUPPRESS_CAPS
    seam = $env:GHOZTTY_RESUME_COUNT_BYTES
    qa   = $env:GHOSTTY_AGENT_QUIET_ATTACH
}
$env:GHOZTTY_PIPE_SUFFIX = "-resumeoffset$PID"

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

$null = Assert-GhozttyIsolatedBuild -Exe $Exe
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)

$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

foreach ($arm in $Arms) {
    # Removed, not emptied: an empty value is still a value the agent reads.
    [Environment]::SetEnvironmentVariable('GHOSTTY_AGENT_SUPPRESS_CAPS', $null)
    [Environment]::SetEnvironmentVariable('GHOZTTY_RESUME_COUNT_BYTES', $null)
    [Environment]::SetEnvironmentVariable('GHOSTTY_AGENT_QUIET_ATTACH', $null)
    switch ($arm) {
        'A' { Say "== A: $Cycles kill/restore cycles of a quiet pane - the recorded offset IS the head" }
        'B' {
            Say "== B: teeth - the pre-T739 accounting, from this same tree, must overshoot"
            $env:GHOZTTY_RESUME_COUNT_BYTES = '1'
        }
        'C' {
            Say "== C: skew - an agent that predates DATA_REPAINT still restores, live and unclamped"
            # The running agent already negotiated WITH the capability; a fresh
            # one has to come up under the suppression for the HELLO to change.
            $env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'repaint_data'
        }
        'D' {
            Say "== D: a peer that does NOT repaint on attach - the label alone has to hold the position"
            # The POSIX shape on a ConPTY seat: the agent records the attaching
            # client's geometry and leaves the child alone, so the repaint it
            # injects is the LAST thing on the wire and nothing arrives behind it
            # to re-state the true position (T804).
            $env:GHOSTTY_AGENT_QUIET_ATTACH = '1'
        }
        'E' {
            Say "== E: teeth for D - the same silent peer with the label taken away MUST overshoot"
            $env:GHOSTTY_AGENT_QUIET_ATTACH = '1'
            $env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'repaint_data'
        }
    }
    Stop-TestProcs
    Remove-Item -Recurse -Force (Join-Path $tmp 'ghoztty') -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null

    # Launch 0: an ordinary OPEN. Nothing is injected on an open, so this
    # launch's offset accounting is exact on any build - it is the baseline the
    # cycles below start from.
    $log0 = Join-Path $tmp "app-$arm-0.err.txt"
    # persistence: on (default) - this launch WRITES the manifest every restore
    # cycle below reads back; with the flag there would be no session to resume.
    # (Its own restore is a no-op: the arm wiped the per-run LOCALAPPDATA above.)
    $app0 = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t739') -StdErr $log0
    $up0 = (Wait-TestWindow -ProcessId $app0.Pid -Class 'GhozttyWindow' -TimeoutMs 45000) -ne [IntPtr]::Zero
    Assert "$arm.0 the first launch came up" $up0
    if (-not $up0) { continue }
    $pane = Wait-PaneId "$arm-0" 45
    Assert "$arm.0 the startup pane is addressable" ($null -ne $pane)
    if (-not $pane) { continue }
    # A live pane, not a painted one: everything below is about what its session
    # has produced, so a frozen pane would make the numbers meaningless.
    Assert "$arm.0 the pane is live before any restore" `
        (Test-PaneLive -Exe $Exe -Target $pane -Tmp $tmp -Tag "$arm-live0")
    Provoke-ManifestWrite $pane "$arm-0"
    Assert "$arm.0 the manifest recorded a resume offset" (@(Manifest-Offsets | Where-Object { $_ -gt 0 }).Count -ge 1)

    $overshoots = 0
    $warned = 0
    $cyclesRun = 0
    for ($i = 1; $i -le $Cycles; $i++) {
        $r = Invoke-RestoreCycle $i $arm
        Assert "$arm.$i the restored app came up" ($r.up)
        if (-not $r.up) { break }
        $att = $r.attach
        Assert "$arm.$i the restored pane re-ATTACHED (its numbers are in the log)" ($null -ne $att)
        if ($null -eq $att) { break }
        $cyclesRun++
        Say "     requested=$($att.requested) head=$($att.head) resumed_at=$($att.resumed) labeled=$($att.labeled)"
        if ($att.requested -gt $att.head) { $overshoots++ }
        if (Log-HasClampWarning $r.log) { $warned++ }

        # The bit D and E differ in, read from the client's own attach line
        # rather than assumed from the env var this arm exported (T804). Without
        # it a suppression that silently failed to reach the agent would make E
        # look like a green D and take the measurement with it.
        if ($arm -eq 'D') {
            Assert "$arm.$i the injected repaint is LABELLED on the wire" ($att.labeled)
        } elseif ($arm -eq 'C' -or $arm -eq 'E') {
            Assert "$arm.$i the agent really did drop the label (pre-0x15 HELLO)" (-not $att.labeled)
        }

        if ($arm -ne 'B' -and $arm -ne 'E') {
            # The claim, exactly: for a pane that has produced nothing since the
            # manifest was written, the position we recorded is the position the
            # session reached - not that plus our own repaint.
            #
            # Arm C holds it too, and that is not luck: the anchor-authoritative
            # accounting is client-side, so it lands even when the agent frames
            # its repaint as plain DATA - the ConPTY paint that follows the
            # repaint is anchored at the head and re-states the true position.
            # What the 0x15 framing adds is that this no longer DEPENDS on
            # something arriving afterwards to correct it (a peer that does not
            # repaint on attach has nothing behind the injection).
            Assert "$arm.$i requested offset == agent head ($($att.requested) vs $($att.head))" `
                ($att.requested -eq $att.head)
            Assert "$arm.$i the resume was honored, not clamped" ($att.resumed -eq $att.requested)
        }

        $pane = Wait-PaneId "$arm-$i" 45
        Assert "$arm.$i the restored pane is addressable" ($null -ne $pane)
        if (-not $pane) { break }
        # D/E are the arms about what happens when NOTHING follows the injected
        # repaint, so nothing may follow it here either: the liveness probe types
        # into the pane, and those bytes are real stream data anchored at the true
        # head - the same backstop the ConPTY repaint is, arriving from the test
        # instead of from conhost. Measured: with the probe inside the loop arm E
        # overshot on some cycles and not others, which is that race. So D/E
        # probe ONCE, after the last cycle's numbers have been read and its
        # manifest written, and rely on "addressable" in between.
        $quietArm = ($arm -eq 'D' -or $arm -eq 'E')
        if (-not $quietArm) {
            Assert "$arm.$i the restored pane is LIVE, not a picture" `
                (Test-PaneLive -Exe $Exe -Target $pane -Tmp $tmp -Tag "$arm-live$i")
        }
        Provoke-ManifestWrite $pane "$arm-$i"
        if ($quietArm -and $i -eq $Cycles) {
            # Last of all: the seam must not have frozen the pane. A quiet ATTACH
            # skips the child-side geometry call, and a pane that stopped
            # accepting input would satisfy every number above while being dead.
            Assert "$arm the pane is still LIVE after $Cycles quiet re-attaches" `
                (Test-PaneLive -Exe $Exe -Target $pane -Tmp $tmp -Tag "$arm-livefinal")
        }
    }

    if ($arm -eq 'E') {
        # The measurement T804 exists for. Against a peer that repaints on
        # attach the label can be taken away and the position still comes out
        # right (arm C) - so C alone can never tell a correct labelling from a
        # broken one. Take the repaint behind the injection away too and the
        # miscount has nothing to correct it: the overshoot is back, on every
        # cycle after the first, and the clamp fires on it. That D is green
        # under exactly these conditions is therefore the label doing the work,
        # and not something else arriving afterwards.
        $want = $cyclesRun - 1
        Assert "E an unlabelled repaint with nothing behind it overshoots the head ($overshoots of $cyclesRun cycles, want $want)" `
            ($cyclesRun -gt 1 -and $overshoots -eq $want)
        Assert "E ...and the clamp fires on it, which is where output would be lost ($warned of $cyclesRun)" `
            ($cyclesRun -gt 1 -and $warned -eq $want)
    } elseif ($arm -eq 'B') {
        # Teeth: with the old accounting nothing else about the run changes, so
        # arm A's green is only evidence because this arm goes red. The
        # overshoot is the injected repaint's size, on every cycle, and the
        # clamp that catches it is where the real output was being skipped.
        # All but the FIRST cycle, and that exception is structural rather than
        # slack: cycle 1 resumes from an offset the OPEN-era launch recorded,
        # and an OPEN has no injected repaint to miscount. The error is minted
        # BY an attach, so it shows up from the attach after the first.
        $want = $cyclesRun - 1
        Assert "B the pre-T739 accounting overshoots the head ($overshoots of $cyclesRun cycles, want $want)" `
            ($cyclesRun -gt 1 -and $overshoots -eq $want)
        Assert "B ...and the clamp fires on it, which is where output was lost ($warned of $cyclesRun)" `
            ($cyclesRun -gt 1 -and $warned -eq $want)
    } else {
        Assert "$arm no attach was ever clamped back to the head ($warned warning(s) across $cyclesRun cycles)" `
            ($cyclesRun -gt 0 -and $warned -eq 0)
        Assert "$arm no attach ever asked to resume past the stream head ($overshoots of $cyclesRun)" `
            ($cyclesRun -gt 0 -and $overshoots -eq 0)
    }
}
Complete-TestBody  # T1039: the run reached the end of its body

} finally {
    Stop-TestProcs
    Stop-TestForegroundWatch
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    $env:GHOSTTY_AGENT_SUPPRESS_CAPS = $saved.supp
    $env:GHOZTTY_RESUME_COUNT_BYTES = $saved.seam
    $env:GHOSTTY_AGENT_QUIET_ATTACH = $saved.qa
    # -KeepRoot leaves the per-launch app logs behind: they are the only record
    # of what each attach decided, and a failing arm is unreadable without them.
    if ($KeepRoot) { Write-Host "  (kept: $root)" }
    else { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
}

# --- stamp (T783) -----------------------------------------------------------
# Only a run that scored EVERY arm may stamp: `-Arms` exists for iterating on
# one of them, and a stamp written from a subset would record that this harness
# has been run against the code as it stands when most of it never executed -
# the same lie the freshness gate at the top refuses.
$allArms = @('A', 'B', 'C', 'D', 'E')
$ranEveryArm = (@(Compare-Object $allArms @($Arms)).Count -eq 0)
if ($script:failures -eq 0 -and $ranEveryArm) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts\guard-due.ps1') `
        update -Guard resume-offset -Repo $repoRoot 2>&1 | ForEach-Object { "  $_" }
} elseif (-not $ranEveryArm) {
    Write-Host "  (partial run: -Arms $($Arms -join ',') - the guard is NOT stamped)"
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures
