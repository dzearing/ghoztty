# T3751 acceptance: the command palette's "... with Shell" rows.
#
# "New Tab with Shell...", "New Window with Shell...", "Split Right with
# Shell..." and "Split Down with Shell..." are a SECOND STEP: picking one keeps
# the palette open and swaps its list for the installed shells (the list
# Settings > Shell offers, read here through `settings --op=shells`). Picking a
# shell opens the tab / window / split on THAT shell, built the way
# `--shell=<spec>` builds it.
#
# The oracle is the new pane's PROCESS, read from `+list --json` leaf pids: the
# app's default shell here is cmd.exe (a hermetic empty config), so a pane
# running powershell.exe / pwsh.exe / bash.exe can only have come from the
# pick. A positive control asserts the first pane IS cmd.exe, so a pass cannot
# be "every pane runs PowerShell anyway".
#
# Sections, each run with session persistence ON (agent-backed panes) and OFF
# (plain ConPTY panes):
#   A  each of the four rows opens its target on Windows PowerShell
#   B  a second shell (pwsh when installed, else cmd) proves the pick, not a
#      constant, chooses; Git Bash (a path with a space) when installed
#   C  negative controls: a shell filter matching nothing opens nothing and
#      leaves the step open; Escape goes back to the command list (palette
#      still open), and a second Escape closes it
#
# WSL (CLAUDE.md: never start WSL unasked): the WSL rows run the same code path
# with a `wsl:<distro>` spec; `-Wsl` adds a distro arm, otherwise it is SKIPPED
# with the reason. Runs on a BACKGROUND desktop (lib\TestDesktop.ps1), so it
# never takes the user's foreground; only touches this repo's zig-out builds.
#
#   powershell -NoProfile -File test\win32\palette-shell-pick.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$Wsl,
    [switch]$NegativeControl,
    # Diagnostics: the app's stderr (debug log) for each arm, to this path + arm.
    [string]$StdErrLog,
    # Which persistence arms to run (diagnostics); both by default.
    [string[]]$Arms = @('true', 'false')
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $AgentExe)) { $AgentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe' }

$script:failures = 0
$script:passes = 0
$script:skipped = 0
$root = Join-Path $env:TEMP "ghoztty-palette-shell-pick-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}
function Stop-TestProcs { [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900) }

function Run-Cli($argsLine, $out, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Leaves-Of-Node($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of-Node $node.left) + @(Leaves-Of-Node $node.right) }
    return @()
}
function Snapshot-Windows($tmp, $tag) {
    Run-Cli '+list --json' "$tmp\list-$tag.json" 20 | Out-Null
    $tree = $null
    try { $tree = (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch {}
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
# name -> pid of every terminal leaf, plus the window and tab counts.
function Get-Layout($tmp, $tag) {
    $wins = @(Snapshot-Windows $tmp $tag)
    $map = @{}
    $tabs = 0
    foreach ($w in $wins) {
        foreach ($t in @($w.tabs)) {
            $tabs++
            foreach ($l in @(Leaves-Of-Node $t.splits)) {
                if ([string]$l.name -ne '') { $map[[string]$l.name] = [int]$l.pid }
            }
        }
    }
    return [pscustomobject]@{ Panes = $map; Windows = $wins.Count; Tabs = $tabs }
}
# The first pane not in $known that reports a live process.
function Wait-NewPane($tmp, $tag, $known, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $lay = Get-Layout $tmp "$tag-$i"
        foreach ($k in $lay.Panes.Keys) {
            if ($known.ContainsKey($k) -or $lay.Panes[$k] -le 0) { continue }
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($lay.Panes[$k])"
            if ($null -ne $p) { return [pscustomobject]@{ Name = $k; Proc = $p; Layout = $lay } }
        }
        $i++
        Start-Sleep -Milliseconds 700
    }
    return $null
}
function Proc-Name($found) { if ($null -eq $found) { return '(no new pane)' } return [string]$found.Proc.Name }

function Find-Palette { Get-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyCommandPalette' }
# Whether the palette goes away within $ms (polled), and the converse: it
# is still up after that long, i.e. the last key did not close it.
function Wait-PaletteGone([int]$ms = 3000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        if ((Find-Palette) -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return ((Find-Palette) -eq [IntPtr]::Zero)
}
function Test-PaletteStays([int]$ms = 800) { return (-not (Wait-PaletteGone $ms)) }

# Open the palette on the first window's first pane and return its EDIT, or
# Zero. The chord goes to the terminal; the search box is a standard EDIT, so
# text goes in as WM_CHAR and Enter/Escape as posted keys.
function Open-Palette($label) {
    $top = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    $vis = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($vis.Count -lt 1) { return [IntPtr]::Zero }
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window ([IntPtr]$top) -Target ([IntPtr]$vis[0].Hwnd) -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyCommandPalette' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    if ($popup -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    return (Find-TestWindowEx -Parent $popup -Class 'EDIT')
}
function Type-Enter($edit, $text) {
    Send-TestControlText -Control $edit -Text $text | Out-Null
    $ok = Send-TestControlKey -Control $edit -Key Enter
    return $ok
}

# One pick: row filter -> Enter -> shell filter -> Enter; returns the new pane.
function Pick($tmp, $id, $row, $shellFilter) {
    $known = (Get-Layout $tmp "$id-k").Panes
    $edit = Open-Palette $id
    if ($edit -eq [IntPtr]::Zero) { "  (palette did not open for $id)"; return $null }
    [void](Type-Enter $edit $row)
    # The step keeps the palette open on the same search box.
    if (-not (Test-PaletteStays)) { "  (palette closed after '$row' - no shell step)"; return $null }
    [void](Type-Enter $edit $shellFilter)
    return (Wait-NewPane $tmp $id $known)
}

$td = New-TestDesktop
Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'palshell')
Assert-GhozttyPrivateEndpoint -Exe $Exe

Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)

$haveGitBash = $false
$havePwsh = $false

function Run-Arm($persist) {
    $tmp = Join-Path $root "p-$persist"
    $xdg = Join-Path $tmp 'xdg'
    New-Item -ItemType Directory -Force (Join-Path $xdg 'ghostty') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $xdg 'ghostty\config-debug.ghostty'), "font-size = 13`n")
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    $env:XDG_CONFIG_HOME = $xdg
    try {
        # persistence: both, from $persist, into a throwaway $env:LOCALAPPDATA.
        $se = if ($StdErrLog) { @{ StdErr = "$StdErrLog.$persist.log" } } else { @{} }
        $script:app = Start-OnTestDesktop -Exe $Exe -Arguments @("--session-persistence=$persist") @se
    } finally { Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
    $p = "[persistence=$persist]"

    $first = Wait-NewPane $tmp "first" @{} 60
    AssertEq "0 positive control: the first pane runs the default shell $p" 'cmd.exe' (Proc-Name $first)
    if ($null -eq $first) { return }

    $shells = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=shells')
    $labels = @($shells.data.shells | ForEach-Object { [string]$_.label })
    Assert "0 the shell list is readable and offers Windows PowerShell $p" ($labels -contains 'Windows PowerShell (powershell.exe)')
    $script:havePwsh = $labels -contains 'PowerShell 7 (pwsh.exe)'
    $script:haveGitBash = $labels -contains 'Git Bash (bash.exe)'

    # ---- C: negative controls ----
    $known = (Get-Layout $tmp 'c-k').Panes
    $edit = Open-Palette 'c'
    Assert "C0 palette opened $p" ($edit -ne [IntPtr]::Zero)
    if ($edit -ne [IntPtr]::Zero) {
        [void](Type-Enter $edit 'Split Right with Shell')
        [void](Type-Enter $edit 'ZZZZNOSHELL')
        Assert "C1 a shell filter matching nothing leaves the palette open $p" (Test-PaletteStays)
        [void](Send-TestControlKey -Control $edit -Key Escape)
        Assert "C2 Escape in the shell step goes back, the palette stays open $p" (Test-PaletteStays)
        # Back on the command list: a command row runs again. 'New Window'
        # also matches 'New Window with Shell...', which sorts after it; this
        # section runs first in the arm so no Recent entry reorders the two
        # (a "Split Left" filter would run "Focus Split Left" - it sorts first).
        [void](Type-Enter $edit 'New Window')
        $r = Wait-NewPane $tmp "c3-$persist" $known 20
        AssertEq "C3 after Escape the list is the commands again: 'New Window' opens a default cmd.exe window $p" 'cmd.exe' (Proc-Name $r)
        # Exactly one pane came of the whole sequence: the dead-end filter
        # opened nothing.
        $after = (Get-Layout $tmp 'c3post').Panes
        AssertEq "C1 ... and the no-match Enter opened no pane (one new pane in all) $p" ($known.Count + 1) $after.Count
        $edit = Open-Palette 'c4'
        if ($edit -ne [IntPtr]::Zero) {
            [void](Send-TestControlKey -Control $edit -Key Escape)
            Assert "C4 Escape on the command list closes the palette $p" (Wait-PaletteGone)
        }
    }


    # ---- A: each row opens its target on the picked shell ----
    $lay0 = Get-Layout $tmp 'a0'
    $r = Pick $tmp "a1-$persist" 'Split Right with Shell' 'powershell.exe'
    $want = if ($NegativeControl) { 'cmd.exe' } else { 'powershell.exe' }
    AssertEq "A1 Split Right with Shell > Windows PowerShell opens a powershell.exe split $p" $want (Proc-Name $r)
    if ($r) { AssertEq "A1 it is a split: same window and tab count $p" "$($lay0.Windows)/$($lay0.Tabs)" "$($r.Layout.Windows)/$($r.Layout.Tabs)" }

    $r = Pick $tmp "a2-$persist" 'Split Down with Shell' 'powershell.exe'
    AssertEq "A2 Split Down with Shell > Windows PowerShell opens a powershell.exe split $p" 'powershell.exe' (Proc-Name $r)

    $lay = Get-Layout $tmp 'a3pre'
    $r = Pick $tmp "a3-$persist" 'New Tab with Shell' 'powershell.exe'
    AssertEq "A3 New Tab with Shell > Windows PowerShell opens a powershell.exe tab $p" 'powershell.exe' (Proc-Name $r)
    if ($r) { AssertEq "A3 it is a new tab $p" ($lay.Tabs + 1) $r.Layout.Tabs }

    # ---- B: another shell, so the pick (not a constant) decides. Never
    # cmd.exe here: it is the default, so a pane on it proves nothing. ----
    $second = if ($script:havePwsh) { @('pwsh.exe', 'pwsh.exe') }
        elseif ($script:haveGitBash) { @('bash.exe', 'bash.exe') }
        else { @('powershell.exe', 'powershell.exe') }
    $lay = Get-Layout $tmp 'b1pre'
    $r = Pick $tmp "b1-$persist" 'New Window with Shell' $second[0]
    AssertEq "B1 New Window with Shell > $($second[0]) opens a $($second[1]) window $p" $second[1] (Proc-Name $r)
    if ($r) { AssertEq "B1 it is a new window $p" ($lay.Windows + 1) $r.Layout.Windows }

    if ($script:haveGitBash) {
        $r = Pick $tmp "b2-$persist" 'New Tab with Shell' 'bash.exe'
        AssertEq "B2 New Tab with Shell > Git Bash (a path with a space) opens bash.exe $p" 'bash.exe' (Proc-Name $r)
    } else {
        $script:skipped++
        "  SKIP B2 Git Bash arm - Git for Windows is not installed"
    }

    if ($persist -eq 'true') {
        $agents = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
            Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq [System.IO.Path]::GetFullPath($AgentExe)) })
        Assert "0 the persistence-on arm ran agent-backed panes" ($agents.Count -ge 1)
    }
    Stop-TestProcs
}

foreach ($a in $Arms) { Run-Arm $a }

# ---- WSL arm (opt-in, or when a distro is already running) ----
. (Join-Path $repo 'scripts\lib\WslState.ps1')
if ($Wsl -or (Test-WslDefaultDistroRunning)) {
    $tmp = Join-Path $root 'wsl'
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # persistence: on (default), into a throwaway $env:LOCALAPPDATA - the real-WSL arm.
    $script:app = Start-OnTestDesktop -Exe $Exe -Arguments @()
    $first = Wait-NewPane $tmp 'wfirst' @{} 60
    $shells = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=shells')
    $distro = @($shells.data.shells | Where-Object { [string]$_.spec -like 'wsl:*' } | Select-Object -First 1)
    if ($distro.Count -eq 1) {
        $r = Pick $tmp 'w1' 'Split Right with Shell' ([string]$distro[0].label)
        AssertEq "W1 Split Right with Shell > $($distro[0].label) opens wsl.exe" 'wsl.exe' (Proc-Name $r)
        $cl = if ($r) { [string]$r.Proc.CommandLine } else { '' }
        Assert "W1 ... on that distro, at ~ ($cl)" ($cl -match ('-d\s+"?' + [regex]::Escape($distro[0].spec.Substring(4)) + '"?\s+--cd\s+~'))
    } else {
        $script:skipped++
        "  SKIP W1 - no WSL distro is registered"
    }
    Stop-TestProcs
} else {
    $script:skipped++
    "  SKIP W1 the WSL arm - $(Get-WslSkipReason); pass -Wsl to run it (it boots the WSL2 VM)"
}

Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -eq $savedAgentBin) { Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
else { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

Complete-TestBody
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard palette-shell-pick -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
""
Write-TestVerdict -Label 'T3751 ACCEPTANCE' -Pass $script:passes -Fail $script:failures -Skipped ([int]$script:skipped)
