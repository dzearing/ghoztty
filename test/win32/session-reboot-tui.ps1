# T1817 acceptance: a REBOOT restore of panes that were running a TUI.
#
# The Windows port of the Mac's `scripts/e2e/session-persistence.py
# --reboot-tui` (commit 7e78aacf4, merged here by T1796). Every pane the user
# restores after a reboot is running Claude Code, and the ping/echo panes the
# other restore harnesses use exercise none of what made those restores break
# on the Mac: thousands of synchronized-output frames redrawn in place, the
# queries a TUI asks between frames (DA1, DECRQM, XTVERSION, the kitty keyboard
# query), keyboard/mouse/paste modes left armed, and the alternate screen. The
# Mac fixed fourteen failures in SHARED code (the agent, termio, the inbound
# ring, the formatter), so Windows inherits the fixes - unproven until this.
#
# Three windows, each its own pane:
#
#   * tuiA - Claude Code's INLINE renderer: a 120-line conversation on the
#     primary screen under a constantly redrawn prompt box, with the queries and
#     kitty keyboard pushes a real session interleaves.
#   * tuiB - the FULL-SCREEN renderer: a line on the primary screen, then the
#     alternate screen with any-event mouse tracking and absolute frames.
#   * bare - a plain shell, the control: it carries no TUI at all, so it says
#     what a restored pane looks like when there is nothing to get wrong, and
#     it measures the pane size BEFORE the kill.
#
# Both TUI panes run a generated stream (written below, a PowerShell port of
# `scripts/e2e/tui-stream.py`) through a console writer and then idle, exactly
# the state a reboot catches a Claude Code pane in. Then the REBOOT shape: the
# app, the session manager AND its PTY holders all die (since T909 the holders
# outlive a manager on purpose, so killing the manager alone is an upgrade, not
# a reboot - see session-relaunch-notify.ps1's Stop-AgentAndHolders). The app
# relaunches on the default `restore` policy and every pane must show:
#
#   H  the dead session's history: every conversation line once, in order, the
#      final frame, no smear of stale prompt-box or full-screen frames;
#   Q  no reply to the dead program's queries typed into the new shell (a reply
#      typed into cmd.exe can do more than print junk: `>` is a redirect);
#   M  no mouse / focus / bracketed-paste mode left armed (DECRQM, asked from
#      INSIDE the pane, because the answer is delivered as input);
#   L  a live prompt that answers typed input;
#   S  the real size: no "attaching at the placeholder" in the app's log, and
#      the restored console is the size the same window had before the kill;
#   R  a resize after the restore does not blank the restored history.
#
# What does NOT port, measured rather than assumed: a Windows child writes into
# a ConPTY, and conhost re-renders what reaches the agent. So the stream the
# app sees is conhost's rendering of the TUI, not the TUI's own bytes, and a
# query may be answered by conhost rather than by Ghoztty. The assertions are
# therefore all about OUTCOMES in the pane - the thing a user sees - and a
# probe that cannot be observed through ConPTY (the kitty keyboard flags) is
# reported as information, never scored.
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1) and never
# takes the user's foreground; hermetic via a per-run LOCALAPPDATA +
# GHOSTTY_LOCAL_AGENT_BIN + a private IPC pipe suffix; only ever kills
# ghoztty / ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\session-reboot-tui.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # Stream shape. The defaults keep the inline stream several MB of raw TUI
    # output, the way a real Claude Code session is, without making the live
    # phase the slowest part of the run.
    [int]$Convo = 120,
    [int]$FramesPerLine = 20,
    [int]$FullscreenFrames = 1000,
    [switch]$KeepTemp,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-reboot-tui-$PID"

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T652: the "attached is not alive" oracle.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
# T1033: this script launches the app itself, so it asks the pre-flight
# question: are these bytes ours to drive, or the user's installed Ghoztty's?
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

# Write-Host, never the pipeline: a helper that asserts AND returns a value would
# hand its caller @('  PASS ...', $realValue).
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# The "session interrupted" notice the restore policy prints (session_notice.zig),
# matched whitespace-stripped and case-insensitively: these are wrap-proof reads.
$NOTICE = 'sessioninterrupted'
# The placeholder geometry a pane must never be brought up at (Remote.zig
# awaitRealSize) - logged by the app when the wait for the real size gives up.
$PLACEHOLDER_LOG = 'attaching at the placeholder'

function Stop-TestProcs {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}
function Stop-AppOnly {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 900)
}
# THE reboot shape: the manager and every PTY holder (same image, same path), so
# the next launch finds dead-but-relaunchable tombstones. Path-exact, so the
# user's installed agent is never touched.
function Stop-AgentAndHolders {
    [void](Stop-RepoGhoztty -Exe $Exe -AgentOnly -SettleMs 900)
    return @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe }).Count
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: on (default) - session persistence IS this script's subject.
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit, or ExitCode reads empty.
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw -Encoding UTF8 } else { '' } }

function Get-List($tag) {
    Run-CliArgs @('+list', '--json') "$tmp\list-$tag.json" 12 | Out-Null
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
# The leaf of the window (or pane) this script NAMED, by `+new-window --target`.
# `+list --json` carries a window's registered name as its `target`; the
# terminal's own `name` is matched too, for a name a restore re-registers on the
# pane rather than the window.
function Find-NamedLeaf($tree, $name) {
    if ($null -eq $tree) { return $null }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    foreach ($w in @($windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($lf in @(Leaves-Of $t.splits)) {
                if ($null -eq $lf) { continue }
                if ([string]$w.target -eq $name -or [string]$lf.name -eq $name) { return $lf }
            }
        }
    }
    return $null
}
function Wait-NamedLeaves($tag, $names, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $found = @{}
    while ((Get-Date) -lt $deadline) {
        $tree = Get-List $tag
        $found = @{}
        foreach ($n in $names) {
            $lf = Find-NamedLeaf $tree $n
            if ($null -ne $lf) { $found[$n] = [string]$lf.id }
        }
        if ($found.Count -eq $names.Count) { return $found }
        Start-Sleep -Milliseconds 600
    }
    return $found
}

function Read-Pane($id, $tag, $lines = 3000) {
    Run-CliArgs @('+read', "--name=$id", "--lines=$lines") "$tmp\read-$tag.txt" 15 | Out-Null
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '')
}
function Tight($s) { return ($s -replace '\s', '') }
function Wait-PaneTight($id, $tag, $needle, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Tight (Read-Pane $id $tag)).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        Start-Sleep -Milliseconds 800
    }
    return $false
}
# The conversation line numbers in a dump, in the order they appear. Read off
# the whitespace-stripped text so a soft wrap through a token cannot split it.
function Get-ConvoSeq($text) {
    return @([regex]::Matches((Tight $text), 'CONVO-A-(\d{4})') | ForEach-Object { [int]$_.Groups[1].Value })
}
function Test-ExactSeq($seq, $n) {
    if ($seq.Count -ne $n) { return $false }
    for ($i = 0; $i -lt $n; $i++) { if ($seq[$i] -ne $i) { return $false } }
    return $true
}
function Describe-Seq($seq) {
    $first = ($seq | Select-Object -First 3) -join ','
    $last = ($seq | Select-Object -Last 3) -join ','
    return "got $($seq.Count); first [$first] last [$last]"
}

# --- the TUI streams (a PowerShell port of scripts/e2e/tui-stream.py) ---------
$ESC = [char]27
function Rgb($i, $j) { return "$ESC[38;2;$(($i * 7 + $j * 3) % 256);$(($i * 13 + $j) % 256);$((200 + $j) % 256)m" }
function StatusLine($i) {
    $text = "ctx: $($i % 997)k/1000k | files: clean | v2.1.999 (spinner $i)"
    $sb = New-Object System.Text.StringBuilder
    for ($j = 0; $j -lt $text.Length; $j++) { [void]$sb.Append((Rgb $i $j)); [void]$sb.Append($text[$j]) }
    [void]$sb.Append("$ESC[39m$ESC[K")
    return $sb.ToString()
}
# What a real TUI asks between frames: DA1, DECRQM ?2026, XTVERSION, kitty query.
$QUERIES = "$ESC[c$ESC[?2026`$p$ESC[>0q$ESC[?u"
$RULE = ([string][char]0x2500) * 80

function New-InlineStream($tag, $convo, $fpl) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$ESC[?2004h$ESC[?1004h$ESC[>1u$ESC[>4;2m$ESC[?25l")
    [void]$sb.Append("$RULE`r`n> `r`n$(StatusLine 0)`r`n")
    $i = 0
    for ($n = 0; $n -lt $convo; $n++) {
        for ($f = 0; $f -lt $fpl; $f++) {
            $i++
            $dots = '.' * ($i % 4)
            [void]$sb.Append("$ESC[?2026h`r$ESC[3A$ESC[2K$RULE`r`n$ESC[2K> thinking$dots`r`n$ESC[2K$(StatusLine $i)`r`n$ESC[?2026l")
            if ($i % 7 -eq 0) { [void]$sb.Append($QUERIES) }
            if ($i % 50 -eq 0) { [void]$sb.Append("$ESC[<u$ESC[>1u") }
        }
        $num = '{0:d4}' -f $n
        [void]$sb.Append("$ESC[?2026h`r$ESC[3A$ESC[J$ESC[1mCONVO-$tag-$num$ESC[0m the assistant said something useful here`r`n$RULE`r`n> `r`n$(StatusLine $i)`r`n$ESC[?2026l")
    }
    [void]$sb.Append("$ESC[?2026h`r$ESC[3A$ESC[2K$RULE`r`n$ESC[2K> FINAL-$tag`r`n$ESC[2K$(StatusLine ($i + 1))`r`n$ESC[?25h$ESC[?2026l")
    return $sb.ToString()
}
function New-FullscreenStream($tag, $frames, $rows = 24, $cols = 80) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("BEFORE-TUI-$tag `$ claude`r`n")
    [void]$sb.Append("$ESC[?1049h$ESC[2J$ESC[H")
    [void]$sb.Append("$ESC[?1000h$ESC[?1002h$ESC[?1003h$ESC[?1006h$ESC[?2004h$ESC[?1004h")
    [void]$sb.Append("$ESC[>1u$ESC[>4;2m")
    $dots = ([string][char]0x00B7) * 20
    for ($i = 0; $i -lt $frames; $i++) {
        [void]$sb.Append("$ESC[?2026h$ESC[H")
        for ($r = 1; $r -lt ($rows - 1); $r++) { [void]$sb.Append("$ESC[$r;1H$ESC[2Kframe $i row $r $dots") }
        [void]$sb.Append("$ESC[$rows;1H$ESC[2K$(StatusLine $i)")
        [void]$sb.Append("$ESC[$($rows - 1);3H$ESC[?25h$ESC[?2026l")
        if ($i % 5 -eq 0) { [void]$sb.Append($QUERIES) }
    }
    [void]$sb.Append("$ESC[?2026h$ESC[H$ESC[2J")
    [void]$sb.Append("$ESC[1;1HFINAL-$tag last frame of the full-screen app")
    [void]$sb.Append("$ESC[$rows;1H$(StatusLine $frames)")
    [void]$sb.Append("$ESC[$($rows - 1);3H$ESC[?2026l")
    return $sb.ToString()
}

# The pane-side player: write the stream to the console (VT is interpreted - the
# same path session-relaunch.ps1's mode arming takes), then idle like a TUI
# waiting for input. ASCII-only source; the stream itself is UTF-8.
function Write-Players($dir) {
    $player = @'
param([string]$In)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$text = [IO.File]::ReadAllText($In, [Text.Encoding]::UTF8)
$chunk = 65536
for ($o = 0; $o -lt $text.Length; $o += $chunk) {
    [Console]::Out.Write($text.Substring($o, [Math]::Min($chunk, $text.Length - $o)))
}
[Console]::Out.Flush()
Start-Sleep -Seconds 999999
'@
    Set-Content -Path (Join-Path $dir 'player.ps1') -Value $player -Encoding ascii
    foreach ($t in 'A', 'B') {
        Set-Content -Path (Join-Path $dir "play$t.cmd") -Encoding ascii `
            -Value "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0player.ps1`" -In `"%~dp0stream$t.txt`""
    }
}

# --- in-pane probes ------------------------------------------------------------
# Every probe is its own generated `.cmd` (send-keys concatenates adjacent text
# words with no separator, and `\t`/`\n`/`\r`/`\e` are escapes in its text - so
# the probe directory's path must keep every separator off those letters).
function Write-ProbeScripts($dir) {
    $mode = @'
param([string]$Tag, [int]$Mode)
$esc = [char]27
$sb = New-Object System.Text.StringBuilder
[Console]::Write($esc + '[?' + $Mode + '$p')
$deadline = (Get-Date).AddSeconds(5)
try {
    $ui = $Host.UI.RawUI
    while ((Get-Date) -lt $deadline) {
        if ($ui.KeyAvailable) {
            $k = $ui.ReadKey('NoEcho,IncludeKeyDown')
            [void]$sb.Append($k.Character)
            if ($k.Character -eq 'y') { break }
        }
        else { Start-Sleep -Milliseconds 20 }
    }
}
catch { }
$raw = $sb.ToString() -replace '[^0-9;?$y]', ''
Write-Host ($Tag + '=' + $raw)
'@
    Set-Content -Path (Join-Path $dir 'mode-probe.ps1') -Value $mode -Encoding ascii
    $kitty = @'
param([string]$Tag)
$esc = [char]27
$sb = New-Object System.Text.StringBuilder
[Console]::Write($esc + '[?u')
$deadline = (Get-Date).AddSeconds(4)
try {
    $ui = $Host.UI.RawUI
    while ((Get-Date) -lt $deadline) {
        if ($ui.KeyAvailable) {
            $k = $ui.ReadKey('NoEcho,IncludeKeyDown')
            [void]$sb.Append($k.Character)
            if ($k.Character -eq 'u') { break }
        }
        else { Start-Sleep -Milliseconds 20 }
    }
}
catch { }
$raw = $sb.ToString() -replace '[^0-9?u]', ''
Write-Host ($Tag + '=K' + $raw)
'@
    Set-Content -Path (Join-Path $dir 'kitty-probe.ps1') -Value $kitty -Encoding ascii
    $size = @'
param([string]$Tag)
Write-Host ($Tag + '=' + [Console]::WindowWidth + 'x' + [Console]::WindowHeight + 'Z')
'@
    Set-Content -Path (Join-Path $dir 'size-probe.ps1') -Value $size -Encoding ascii
}
$script:probeSeq = 0
function Invoke-Probe($id, $kind, $extra, $pattern, $timeoutSec = 30) {
    $script:probeSeq++
    $tag = "PRB$($script:probeSeq)Q"
    $shim = Join-Path $probeDir "vtp$($script:probeSeq).cmd"
    Set-Content -Path $shim -Encoding ascii `
        -Value "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$kind`" -Tag $tag $extra"
    Run-CliArgs @('+send-keys', "--target=$id", $shim, 'Enter') "$tmp\probe-send-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $s = Tight (Read-Pane $id "probe-$tag" 400)
        $m = [regex]::Match($s, [regex]::Escape("$tag=") + $pattern)
        if ($m.Success) { return $m }
        Start-Sleep -Seconds 1
    }
    return $null
}
# DECRQM one mode: '1' set, '2' reset, '0' not recognized, '' no answer.
function Get-ModeValue($id, $mode) {
    $m = Invoke-Probe $id 'mode-probe.ps1' "-Mode $mode" ('\?' + $mode + ';(\d)')
    if ($null -eq $m) { return '' }
    return $m.Groups[1].Value
}
function Get-PaneSize($id) {
    $m = Invoke-Probe $id 'size-probe.ps1' '' '(\d+)x(\d+)Z'
    if ($null -eq $m) { return $null }
    return @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value)
}
function Get-KittyFlags($id) {
    $m = Invoke-Probe $id 'kitty-probe.ps1' '' 'K\??(\d*)u?' 20
    if ($null -eq $m) { return '' }
    return $m.Groups[1].Value
}

function Start-App($title, $extraArgs = @()) {
    $script:AppLog = Join-Path $tmp "applog-$title.err.txt"
    # persistence: on (default) - session persistence IS this script's subject.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $extraArgs -StdErr $script:AppLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    if ($top -eq [IntPtr]::Zero) { return 0 }
    Assert "leak: '$title' has no window on the interactive desktop" `
        (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    return [int]$app.Pid
}

# The working directories a typed-in reply could write into (cmd.exe treats `>`
# as a redirect, so an XTVERSION reply typed at a prompt creates a file).
function Get-DirNames($d) { return @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }

Stop-TestProcs
$tmp = Join-Path $root 'state'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$saved = @{ lad = $env:LOCALAPPDATA; bin = $env:GHOSTTY_LOCAL_AGENT_BIN; pipe = $env:GHOZTTY_PIPE_SUFFIX }
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# Every `+list` / `+read` / `+send-keys` below is an oracle: a user instance
# answering the shared pipe would answer them about somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = "-reboottui$PID"

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

$streamDir = Join-Path $root 'streams'
$probeDir = Join-Path $root 'probes'
$work = Join-Path $root 'work'
foreach ($d in $streamDir, $probeDir, $work) { New-Item -ItemType Directory -Force $d | Out-Null }
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $streamDir 'streamA.txt'), (New-InlineStream 'A' $Convo $FramesPerLine), $utf8)
[IO.File]::WriteAllText((Join-Path $streamDir 'streamB.txt'), (New-FullscreenStream 'B' $FullscreenFrames), $utf8)
Write-Players $streamDir
Write-ProbeScripts $probeDir
$sizeA = (Get-Item (Join-Path $streamDir 'streamA.txt')).Length
$sizeB = (Get-Item (Join-Path $streamDir 'streamB.txt')).Length
Say "  streams: inline $sizeA B, fullscreen $sizeB B"

# ============================================================================
Say "== build: two TUI panes and a bare shell, live"
# ============================================================================
# Wide, tall windows so the streams' 80-column layout is never re-wrapped, and
# so the real size can never be mistaken for the 49x17 placeholder.
$launchArgs = @('--window-width=140', '--window-height=40', "--working-directory=$work")
$appPid = Start-App 'build' $launchArgs
Assert "B1 the GUI came up" ($appPid -ne 0)
Run-CliArgs @('+new-window', '--target=tuiA', "--command=`"cmd /c $streamDir\playA.cmd`"", "--working-directory=$work") "$tmp\nwA.txt" 25 | Out-Null
Run-CliArgs @('+new-window', '--target=tuiB', "--command=`"cmd /c $streamDir\playB.cmd`"", "--working-directory=$work") "$tmp\nwB.txt" 25 | Out-Null
Run-CliArgs @('+new-window', '--target=bare', "--working-directory=$work") "$tmp\nwC.txt" 25 | Out-Null
$ids = Wait-NamedLeaves 'build' @('tuiA', 'tuiB', 'bare') 45
Assert "B2 all three named windows came up ($($ids.Keys -join ','))" ($ids.Count -eq 3)

# Live phase: the panes must FINISH their streams - and the app must keep up.
$t0 = Get-Date
Assert "B3 tuiA's stream finished rendering live (FINAL-A)" (Wait-PaneTight $ids['tuiA'] 'liveA' 'FINAL-A' 180)
Assert "B4 tuiB's stream finished rendering live (FINAL-B)" (Wait-PaneTight $ids['tuiB'] 'liveB' 'FINAL-B' 180)
Say "  both streams rendered live in $([math]::Round(((Get-Date) - $t0).TotalSeconds, 1))s"

# LIVE integrity, before any reboot - the positive control for H1: if the live
# pane already loses or duplicates conversation lines, a red H1 would be about
# the live render, not the restore.
$liveA = Read-Pane $ids['tuiA'] 'liveA-full'
$liveSeq = Get-ConvoSeq $liveA
Assert "B5 LIVE: tuiA holds every conversation line once, in order ($(Describe-Seq $liveSeq))" (Test-ExactSeq $liveSeq $Convo)

# The size the bare window's console has before the kill: S2's reference.
$preSize = Get-PaneSize $ids['bare']
Assert "B6 the bare pane reported its console size before the kill ($($preSize -join 'x'))" ($null -ne $preSize)
Assert "B7 that size is the real window, not the 49x17 placeholder" (
    $null -ne $preSize -and -not ($preSize[0] -eq 49 -and $preSize[1] -eq 17))

# Wait for the manifest to have PERSISTED both TUI screens: what a restored pane
# can show is decided before the kill, by that file.
$layout = Join-Path $tmp 'ghoztty\session-layout-debug.json'
function Get-SnapshotTexts {
    $out = @()
    try {
        $doc = Get-Content -Raw -Encoding utf8 $layout | ConvertFrom-Json
        foreach ($w in @($doc.windows)) { foreach ($t in @($w.tabs)) { foreach ($n in @($t.nodes)) {
            $b64 = [string]$n.leaf.screen_snapshot
            if ($b64 -ne '') { $out += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
        } } }
    } catch { }
    return $out
}
$persisted = $false
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $snaps = @(Get-SnapshotTexts)
    $hasA = @($snaps | Where-Object { (Tight $_).Contains('FINAL-A') }).Count -gt 0
    $hasB = @($snaps | Where-Object { (Tight $_).Contains('FINAL-B') }).Count -gt 0
    if ($hasA -and $hasB) { $persisted = $true; break }
    Start-Sleep -Milliseconds 800
}
Assert "B8 both TUI screens reached the session-layout manifest before the kill" $persisted
# Information, not a score: whether the persisted TUI screens carry the modes the
# dead programs armed. Through ConPTY that depends on what conhost forwarded; M1
# is scored either way, and this line says whether it had anything to undo.
$snapB = @(Get-SnapshotTexts | Where-Object { (Tight $_).Contains('FINAL-B') }) | Select-Object -First 1
if ($snapB) {
    $armed = @('?1000h', '?1002h', '?1003h', '?1006h', '?2004h', '?1004h', '?1049h') | Where-Object { $snapB.Contains("$ESC[$_") }
    Say "  info: tuiB's persisted screen re-arms: $(if ($armed) { $armed -join ' ' } else { 'nothing' })"
}

$dirBefore = Get-DirNames $work
Start-Sleep -Seconds 2

# ============================================================================
Say "== reboot: app, session manager and PTY holders all die"
# ============================================================================
Stop-AppOnly
$left = Stop-AgentAndHolders
Assert "K1 no session manager or PTY holder survived the reboot shape ($left)" ($left -eq 0)
Start-Sleep -Seconds 2

$appPid2 = Start-App 'restore' $launchArgs
Assert "K2 the GUI came back" ($appPid2 -ne 0)
$rid = Wait-NamedLeaves 'restore' @('tuiA', 'tuiB', 'bare') 45
Assert "K3 all three named windows were restored ($($rid.Keys -join ','))" ($rid.Count -eq 3)

foreach ($n in 'tuiA', 'tuiB', 'bare') {
    if (-not $rid.ContainsKey($n)) { continue }
    Assert "K4 $n shows the interrupted notice" (Wait-PaneTight $rid[$n] "notice-$n" $NOTICE 40)
}

# ============================================================================
Say "== H: the restored pane shows the dead session's history"
# ============================================================================
$textA = Read-Pane $rid['tuiA'] 'postA'
$tA = Tight $textA
$atA = $tA.IndexOf($NOTICE, [StringComparison]::OrdinalIgnoreCase)
$preA = if ($atA -ge 0) { $tA.Substring(0, $atA) } else { $tA }
$seqA = Get-ConvoSeq $preA
Assert "H1 tuiA: every conversation line is above the notice, once, in order ($(Describe-Seq $seqA))" (Test-ExactSeq $seqA $Convo)
Assert "H2 tuiA: the final prompt-box frame (FINAL-A) is above the notice" ($preA.Contains('FINAL-A'))
$thinking = ([regex]::Matches($preA, '>thinking')).Count
Assert "H3 tuiA: no stale prompt-box frames smeared into the restored buffer ($thinking)" ($thinking -le 1)

$textB = Read-Pane $rid['tuiB'] 'postB'
$tB = Tight $textB
$atB = $tB.IndexOf($NOTICE, [StringComparison]::OrdinalIgnoreCase)
$preB = if ($atB -ge 0) { $tB.Substring(0, $atB) } else { $tB }
# T1819: a snapshot taken inside the full-screen app is flattened into plain
# history (restore_history.altHistory) instead of being painted onto an alt
# screen the restore then has to leave - which discarded the frame.
Assert "H4 tuiB: the full-screen app's last frame (FINAL-B) is above the notice" ($preB.Contains('FINAL-B'))
$staleB = ([regex]::Matches($preB, 'frame\d+row\d+')).Count
Assert "H5 tuiB: no stale full-screen frame rows replayed ($staleB)" ($staleB -eq 0)
# The Mac also keeps the primary screen UNDER the full-screen app
# (BEFORE-TUI-B); since T1819 the session snapshot persists it beneath an
# active alt screen (session_snapshot.writePrimaryUnder), so it is scored.
$atBefore = $preB.IndexOf('BEFORE-TUI-B')
$atFinal = $preB.IndexOf('FINAL-B')
Assert "H6 tuiB: the line printed before the full-screen app started (BEFORE-TUI-B) is above its last frame ($atBefore < $atFinal)" ($atBefore -ge 0 -and $atBefore -lt $atFinal)

# ============================================================================
Say "== Q: no reply to the dead program's queries reached the new shell"
# ============================================================================
foreach ($pair in @(@('tuiA', $tA, $atA), @('tuiB', $tB, $atB))) {
    $n = $pair[0]; $t = $pair[1]; $at = $pair[2]
    $after = if ($at -ge 0) { $t.Substring($at) } else { '' }
    $junk = @('62;', '$y', '?2026;', 'ghostty1', 'ghoztty1', '?0u', '?1u', '[>0q') | Where-Object { $after.Contains($_) }
    Assert "Q1 $n`: no query reply was typed into the restored shell ($($junk -join ' '))" ($at -ge 0 -and @($junk).Count -eq 0)
}
$appeared = @(Get-DirNames $work | Where-Object { $dirBefore -notcontains $_ })
Assert "Q2 no reply was EXECUTED by a restored shell (new files in the panes' cwd: $($appeared -join ', '))" ($appeared.Count -eq 0)

# ============================================================================
Say "== L/M/S: a live prompt, no stray modes, the real size"
# ============================================================================
$sizes = @{}
foreach ($n in 'tuiA', 'tuiB', 'bare') {
    if (-not $rid.ContainsKey($n)) { continue }
    $id = $rid[$n]
    Assert "L1 $n`: the restored pane is on a live shell (typed input answers)" (
        Test-PaneLive -Exe $Exe -Target $id -Tmp $tmp -Tag "RT$n")
    foreach ($m in 1000, 1002, 1003, 1004, 1006, 2004) {
        $v = Get-ModeValue $id $m
        Assert "M1 $n`: mode ?$m is not left ON after the restore (DECRQM '$v')" ($v -ne '' -and $v -ne '1')
    }
    $k = Get-KittyFlags $id
    Say "  info: $n kitty keyboard flags after restore: $(if ($k -ne '') { $k } else { 'no reply through ConPTY' })"
    $sizes[$n] = Get-PaneSize $id
}
# The restored window is the same size as before the kill, but each restored
# pane now carries the interrupted-notice BANNER, which takes rows from the
# pane (measured: 30 rows before, 26-27 after, the command-naming notice being
# the taller one). So the claim is: the SAME width exactly, and a height that is
# the pre-kill height less at most a banner - never the 49x17 placeholder and
# never taller than the window can hold.
$bannerRows = 6
$treeS = Get-List 'sizes'
foreach ($n in 'tuiA', 'tuiB', 'bare') {
    $lf = Find-NamedLeaf $treeS $n
    Say "  info: $n carries a banner of $(([string]$lf.banner).Length) chars while its size is measured"
}
foreach ($n in 'tuiA', 'tuiB', 'bare') {
    $s = $sizes[$n]
    Assert "S1 $n`: the restored console is the window's real size ($($s -join 'x') vs $($preSize -join 'x') before the kill, banner allowance $bannerRows rows)" (
        $null -ne $s -and $null -ne $preSize -and $s[0] -eq $preSize[0] -and
        $s[1] -le $preSize[1] -and $s[1] -ge ($preSize[1] - $bannerRows) -and
        -not ($s[0] -eq 49 -and $s[1] -eq 17))
}
$appLogText = Out-Text $script:AppLog
Assert "S2 the app log is being captured (positive control: it records the panes' attaches)" ($appLogText -match 'attach: session=')
$ph = ([regex]::Matches($appLogText, [regex]::Escape($PLACEHOLDER_LOG))).Count
Assert "S3 no pane was brought up at the placeholder size ($ph '$PLACEHOLDER_LOG' lines)" ($ph -eq 0)

# ============================================================================
Say "== R: a resize after the restore does not blank the restored history"
# ============================================================================
# Every window holds exactly one pane, so resizing all of them resizes tuiA's
# without having to tell the windows apart; tuiA's text is what is scored.
function Resize-AllWindows($w, $h) {
    foreach ($win in @(Get-TestWindows -ProcessId $appPid2 -Class 'GhozttyWindow')) {
        [void](Set-TestWindowSize -Window ([IntPtr]$win.Hwnd) -Width $w -Height $h)
    }
}
Resize-AllWindows 700 500
Start-Sleep -Seconds 3
$seqR1 = Get-ConvoSeq (Read-Pane $rid['tuiA'] 'resize-narrow')
Assert "R1 after narrowing the window, tuiA still holds every conversation line ($(Describe-Seq $seqR1))" (Test-ExactSeq $seqR1 $Convo)
Resize-AllWindows 1400 900
Start-Sleep -Seconds 3
$seqR2 = Get-ConvoSeq (Read-Pane $rid['tuiA'] 'resize-wide')
Assert "R2 after widening it again, tuiA still holds every conversation line ($(Describe-Seq $seqR2))" (Test-ExactSeq $seqR2 $Convo)
Assert "R3 the resized pane is still on a live shell" (Test-PaneLive -Exe $Exe -Target $rid['tuiA'] -Tmp $tmp -Tag 'RTR')

if ($script:failures -gt 0) {
    Say "== DIAG: tuiA after restore (tail) =="
    Say (($textA -split "`n" | Select-Object -Last 40) -join "`n")
    Say "== DIAG: tuiB after restore (tail) =="
    Say (($textB -split "`n" | Select-Object -Last 40) -join "`n")
}
Stop-TestProcs

} catch {
    # T655: score the run's own throw, or a green verdict is reachable over a
    # body that never finished (lib\BodyCompleteAudit.ps1).
    Assert "RUN COMPLETED (the body threw: $($_.Exception.Message))" $false
    Say ($_.ScriptStackTrace)
} finally {
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    if ($KeepTemp) { Write-Host "  kept the run tree: $root" }
    else { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
Say "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert "G1 the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "G2 no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

# --- stamp ----------------------------------------------------------------------
# A green run records the content of every file this harness covers, so
# scripts\guard-due.ps1 can say when it is due. Red leaves the stamp alone.
Complete-TestBody
if ($script:failures -eq 0) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts\guard-due.ps1') `
        update -Guard session-reboot-tui -Repo $repoRoot 2>&1 | ForEach-Object { Say "  $_" }
}

Say ""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'SESSION-REBOOT-TUI'
