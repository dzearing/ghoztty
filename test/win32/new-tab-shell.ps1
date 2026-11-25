# T3753 acceptance: a new tab on a chosen shell, from the tab strip's "+" and
# from File > New Tab.
#
# WHAT THE USER ASKED FOR (T3735, 2026-11-25)
#
# "i have no way to choose to spawn a shell of a different type" - and the
# Windows convention for that is Windows Terminal's: the new-tab control drops
# down a list of shells. Here a right-click on "+" hangs that list from the
# button, and the window menu's File > New Tab opens onto the same list. Both
# read the catalog Settings > Shell offers (T3750) and both put the same rows in
# the same order: "Default Shell" under the New Tab chord, a separator, then one
# row per installed shell.
#
#   A. The catalog, read through the debug `settings --op=shells` seam
#      (SettingsWindow.installedShells, the function both menus build from).
#   B. A right-click on "+" opens a popup whose rows are, in order, Default Shell
#      with the New Tab chord, a separator, and exactly the catalog's labels.
#   C. Escape on that popup opens nothing; picking the Windows PowerShell row
#      opens ONE new tab whose shell process is powershell.exe while the app's
#      default shell is cmd.exe - so the pick, not the default, chose it.
#      (Persistence off: the plain ConPTY path.)
#   D. File > New Tab (F10, F, T) is a submenu with the same rows; picking the
#      Windows PowerShell row there opens a powershell.exe tab too.
#   E. With session persistence on, the "+" pick opens an AGENT session on
#      powershell.exe (the leaf carries a session id).
#
# Nothing here starts WSL: the catalog reads the registry, and no pick names a
# distro. Every menu is driven by posted messages on the background test
# desktop and read with MN_GETHMENU, as menu-bar.ps1 does.
#
# Hermetic: per-run LOCALAPPDATA and XDG config, a private IPC endpoint
# (lib\Isolation), the agent under test pinned; only processes whose
# ExecutablePath is the exe/agent under test are ever stopped.
#
# -NegativeControl expects the "+" popup to carry ONE MORE row than the catalog,
# which MUST fail: it proves B.3 compares rows rather than passing on any list.
#
#   powershell -NoProfile -File test\win32\new-tab-shell.ps1
param(
    [string]$Exe = '',
    [string]$AgentExe = '',
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Exe) { $Exe = Join-Path $repoRoot 'zig-out\bin\ghoztty.exe' }
if (-not $AgentExe) { $AgentExe = Join-Path $repoRoot 'zig-out\bin\ghoztty-agent.exe' }

$script:passes = 0
$script:failures = 0
$script:skipped = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'NEW-TAB-SHELL' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'NEW-TAB-SHELL' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc

# HMENU reads only (a menu handle is not a desktop object). Same walk as
# menu-bar.ps1: "<path>/<label>[\t<accel>]", submenus as "<label> >",
# separators as "---"; GetSubMenu is asked BEFORE the separator bit because a
# popup row's state carries its item count in the high byte.
Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public class NtsMenuRead {
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint idItem, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu, int pos);
    public static string[] Tree(IntPtr menu) {
        var acc = new List<string>();
        if (menu != IntPtr.Zero) Walk(menu, "", acc);
        return acc.ToArray();
    }
    static void Walk(IntPtr menu, string prefix, List<string> acc) {
        int n = GetMenuItemCount(menu);
        for (uint i = 0; i < (uint)n; i++) {
            uint state = GetMenuState(menu, i, 0x400);
            IntPtr sub = GetSubMenu(menu, (int)i);
            if (sub == IntPtr.Zero && (state & 0x800) != 0) { acc.Add(prefix + "---"); continue; }
            var sb = new StringBuilder(260);
            GetMenuStringW(menu, i, sb, 260, 0x400);
            string label = sb.ToString();
            if (sub != IntPtr.Zero) { acc.Add(prefix + label + " >"); Walk(sub, prefix + label + "/", acc); }
            else acc.Add(prefix + label);
        }
    }
}
'@

# --- process helpers: ONLY ever the binaries under test ----------------------
function Get-TestApps {
    return (Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgentProcs {
    return (Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe })
}
function Stop-Everything {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-TestAgentProcs | Where-Object { $_.CommandLine -notmatch '--pty-host' })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    # settle: the agent's pty hosts outlive it briefly and are stopped second
    Start-Sleep -Milliseconds 700
    foreach ($p in (Get-TestAgentProcs | Where-Object { $_.CommandLine -match '--pty-host' })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    # settle: let the killed processes release the private pipe before the next launch binds it
    Start-Sleep -Milliseconds 400
}

# --- CLI plumbing (on the test desktop) --------------------------------------
function Run-CliArgs([string[]]$argv, [string]$out, [int]$timeoutSec = 15) {
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $argv -TimeoutSec $timeoutSec
    $text = if ($null -ne $r.Output) { $r.Output } else { '' }
    [System.IO.File]::WriteAllText($out, $text)
    if ($r.TimedOut) { return $null }
    return $r.ExitCode
}
function Out-Text([string]$f) { if (Test-Path $f) { return (Get-Content $f -Raw) } return '' }

function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function Get-Tree([string]$tag) {
    $rc = Run-CliArgs @('+list', '--json') "$tmp\list-$tag.json" 12
    if ($rc -ne 0) { return $null }
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}
function All-Leaves($tree) {
    $acc = @()
    $wins = if ($null -eq $tree) { @() } elseif ($null -ne $tree.data) { @($tree.data.windows) } else { @($tree.windows) }
    foreach ($w in $wins) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Tab-Total($tree) {
    $wins = if ($null -eq $tree) { @() } elseif ($null -ne $tree.data) { @($tree.data.windows) } else { @($tree.windows) }
    $n = 0
    foreach ($w in $wins) { $n += @($w.tabs).Count }
    return $n
}
function Known-Ids([string]$tag) {
    $ids = @{}
    foreach ($l in (All-Leaves (Get-Tree $tag))) { $ids[[string]$l.id] = $true }
    return $ids
}
# The first leaf not in $known whose shell is up, with its process.
function Wait-NewLeaf($known, [string]$tag, [int]$timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        foreach ($l in (All-Leaves (Get-Tree "$tag$i"))) {
            if ($known.ContainsKey([string]$l.id) -or [int]$l.pid -le 0) { continue }
            $p = Get-Process -Id ([int]$l.pid) -ErrorAction SilentlyContinue
            if ($null -ne $p) { return [pscustomobject]@{ Leaf = $l; Proc = $p } }
        }
        $i++
        Start-Sleep -Milliseconds 600
    }
    return $null
}

# persistence: stated per section by Write-Config (off for B-D, on for E) before each launch.
function Start-TestApp([string]$title, [int]$timeoutSec = 45) {
    # The app's default shell is cmd.exe, so a powershell.exe tab can only
    # have come from the pick. The strip is forced on: with one tab `auto`
    # hides it (T234), and the "+" is the subject.
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @(
        "--title=$title", '--command=cmd.exe', '--window-show-tab-bar=always'))
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $rc = Run-CliArgs @('+list', '--json') "$tmp\list-up-$title.json" 10
        if ($rc -eq 0 -and (Out-Text "$tmp\list-up-$title.json") -match '\S') {
            $app = @(Get-TestApps | Where-Object { $_.CommandLine -like "*$title*" })
            if ($app.Count -ge 1) { return [int]$app[0].ProcessId }
        }
        Start-Sleep -Milliseconds 600
    }
    return 0
}
function Write-Config([string]$body) {
    $cfgDir = Join-Path $tmp 'xdg\ghostty'
    New-Item -ItemType Directory -Force $cfgDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cfgDir 'config'), $body)
    $env:XDG_CONFIG_HOME = Join-Path $tmp 'xdg'
}

# --- menu helpers -------------------------------------------------------------
function Get-MenuTree([IntPtr]$menuWnd) {
    $r = Invoke-TestMessage -Window $menuWnd -Message 0x01E1   # MN_GETHMENU, sent
    if ($r -eq [long]::MinValue -or $r -eq 0) { return @() }
    return [NtsMenuRead]::Tree([IntPtr]$r)
}
function Test-MenuGone([int]$gpid, [int]$ms = 2500) {
    for ($t = 0; $t -lt $ms; $t += 50) {
        if ((Get-TestWindow -ProcessId $gpid -Class '#32768') -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}
function Close-AnyMenu([IntPtr]$top, [int]$gpid) {
    if (-not (Test-MenuGone $gpid 100)) {
        [void](Send-TestControlKey -Control $top -Key 'Escape')
        if (-not (Test-MenuGone $gpid 1000)) { [void](Invoke-TestMessage -Window $top -Message 0x001F) }
        [void](Test-MenuGone $gpid 1500)
    }
}
# Right-click the "+" where the app says it is (+list --json chrome, T231).
function Open-PlusMenu([IntPtr]$top, [int]$gpid) {
    $r = Get-TestStripRegions -Window $top -Exe $Exe
    if ($null -eq $r -or $null -eq $r.NewTab) { return [IntPtr]::Zero }
    $cr = Get-TestWindowRect -Window $top -Client
    [void](Send-TestMouse -Window $top -Target $top -X ($cr.Left + $r.NewTab.CenterX) -Y ($cr.Top + $r.NewTab.CenterY) -Button right -Action click)
    return (Wait-TestPopupMenu -ProcessId $gpid -TimeoutMs 3000)
}
# Walk the open popup's keyboard selection down $n rows (separators are
# skipped by the menu itself) and choose it.
function Pick-Row([IntPtr]$top, [int]$downs) {
    for ($k = 0; $k -lt $downs; $k++) {
        [void](Send-TestControlKey -Control $top -Key 'Down')
        Start-Sleep -Milliseconds 80
    }
    [void](Send-TestControlKey -Control $top -Key 'Enter')
}
# The "+" is placed once the strip has laid out at the new size: wait for the
# app to report it rather than for a fixed time after the resize.
function Wait-PlusPlaced([IntPtr]$top, [int]$ms = 5000) {
    for ($t = 0; $t -lt $ms; $t += 100) {
        $r = Get-TestStripRegions -Window $top -Exe $Exe
        if ($null -ne $r -and $null -ne $r.NewTab) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}
# A submenu is open once the process shows $n popup menus at once.
function Wait-MenuDepth([int]$gpid, [int]$n, [int]$ms = 3000) {
    for ($t = 0; $t -lt $ms; $t += 50) {
        if (@(Get-TestWindows -ProcessId $gpid -Class '#32768').Count -ge $n) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}
# "label<TAB>accel" -> label / accel.
function Label-Of([string]$row) { $i = $row.IndexOf("`t"); if ($i -ge 0) { return $row.Substring(0, $i) } return $row }
function Accel-Of([string]$row) { $i = $row.IndexOf("`t"); if ($i -ge 0) { return $row.Substring($i + 1) } return '' }

$root = Join-Path $env:TEMP "ghoztty-new-tab-shell-$PID"
$tmp = Join-Path $root 'run'
$savedLocalAppData = $env:LOCALAPPDATA
$savedXdg = $env:XDG_CONFIG_HOME
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

try {
    Stop-Everything
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    Write-Config "session-persistence = false`n"

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'newtabshell3753')
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
    . (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
    $td = New-TestDesktop

    $appPid = Start-TestApp 't3753-nts'
    Assert 'premise: the app is up and answering IPC' ($appPid -gt 0)
    if ($appPid -le 0) { Write-TestVerdict -Label 'NEW-TAB-SHELL' -Pass $script:passes -Fail $script:failures }
    Assert-GhozttyIsolated -Exe $Exe
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    Assert 'premise: the window is found on the test desktop' ($top -ne [IntPtr]::Zero)
    # Wide enough that the "+" sits on bare strip, clear of the caption group.
    Set-TestWindowSize -Window $top -Width 1400 -Height 800 | Out-Null
    Assert 'premise: the strip reports where "+" is' (Wait-PlusPlaced $top)

    # --- A: the catalog -------------------------------------------------------
    Say '== A: the shells the menus list'
    $sj = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=shells')
    $shells = @(if ($sj -and $sj.success) { @($sj.data.shells) | ForEach-Object { $_ } })
    $labels = @($shells | ForEach-Object { ([string]$_.label) -replace '&', '&&' })
    $specs = @($shells | ForEach-Object { [string]$_.spec })
    Assert "A.1 the catalog answers with a list ($($shells.Count) shells)" ($shells.Count -gt 0)
    $psIdx = [array]::IndexOf($specs, 'powershell.exe')
    Assert "A.2 Windows PowerShell is in it (index $psIdx)" ($psIdx -ge 0)

    # --- B: the "+" dropdown's rows --------------------------------------------
    Say '== B: a right-click on "+" lists the shells'
    $menu = Open-PlusMenu $top $appPid
    Assert 'B.1 a right-click on "+" opens a popup' ($menu -ne [IntPtr]::Zero)
    $rows = @(if ($menu -ne [IntPtr]::Zero) { Get-MenuTree $menu })
    Close-AnyMenu $top $appPid
    Say ("    rows: " + (($rows | ForEach-Object { $_ -replace "`t", ' <tab> ' }) -join ' | '))
    Assert "B.2 the first row is Default Shell under the New Tab chord (got '$(if ($rows.Count) { $rows[0] -replace "`t", ' <tab> ' })')" `
        ($rows.Count -ge 1 -and (Label-Of $rows[0]) -eq '&Default Shell' -and (Accel-Of $rows[0]) -eq 'Ctrl+T')
    $want = @('---') + $labels
    if ($NegativeControl) { $want += 'NEGATIVE CONTROL: a row the catalog does not have' }
    $got = @(if ($rows.Count -gt 1) { $rows[1..($rows.Count - 1)] })
    $same = ($got.Count -eq $want.Count)
    if ($same) { for ($i = 0; $i -lt $got.Count; $i++) { if ($got[$i] -cne $want[$i]) { $same = $false } } }
    Assert "B.3 then a separator and exactly the catalog's labels, in order ($($got.Count) rows vs $($want.Count))" $same

    # --- C: picking from it ------------------------------------------------------
    Say '== C: picking a shell from the "+" dropdown (persistence off)'
    $tabs0 = Tab-Total (Get-Tree 'c0')
    $knownEsc = Known-Ids 'c0k'
    $menu = Open-PlusMenu $top $appPid
    [void](Send-TestControlKey -Control $top -Key 'Escape')
    Assert 'C.1 Escape closes the dropdown' (Test-MenuGone $appPid)
    # An absence: give a wrongly opened pane the time a real pick takes to show.
    $stray = Wait-NewLeaf $knownEsc 'c1-' 3
    Assert "C.2 and opens no tab ($tabs0 -> $(Tab-Total (Get-Tree 'c1')))" ($null -eq $stray -and (Tab-Total (Get-Tree 'c1b')) -eq $tabs0)

    $known = Known-Ids 'c2'
    $menu = Open-PlusMenu $top $appPid
    Assert 'C.3 the dropdown opens again' ($menu -ne [IntPtr]::Zero)
    if ($psIdx -ge 0 -and $menu -ne [IntPtr]::Zero) {
        Pick-Row $top ($psIdx + 2)   # Default Shell, then the shell rows
        Assert 'C.4 choosing a row closes the dropdown' (Test-MenuGone $appPid)
        $new = Wait-NewLeaf $known 'c3-'
        Assert "C.5 a new pane appeared" ($null -ne $new)
        Assert "C.6 its shell is powershell.exe, not the default cmd.exe (got '$(if ($new) { $new.Proc.ProcessName })')" `
            ($null -ne $new -and $new.Proc.ProcessName -ieq 'powershell')
        Assert "C.7 as a TAB ($tabs0 -> $(Tab-Total (Get-Tree 'c4')))" ((Tab-Total (Get-Tree 'c4b')) -eq ($tabs0 + 1))
    }
    Close-AnyMenu $top $appPid

    # --- D: File > New Tab --------------------------------------------------------
    Say '== D: File > New Tab is the same list'
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    $known = Known-Ids 'd0'
    $tabsD = Tab-Total (Get-Tree 'd0b')
    [void](Send-TestSysKey -Window $pane -Key F10 -Action down)
    [void](Send-TestSysKey -Window $pane -Key F10 -Action up)
    $root0 = Wait-TestPopupMenu -ProcessId $appPid -TimeoutMs 3000
    Assert 'D.1 F10 opens the window menu' ($root0 -ne [IntPtr]::Zero)
    $tree = @(if ($root0 -ne [IntPtr]::Zero) { Get-MenuTree $root0 })
    $sub = @($tree | Where-Object { $_.StartsWith('&File/New &Tab/') } | ForEach-Object { $_.Substring('&File/New &Tab/'.Length) })
    Assert 'D.2 File > New Tab is a submenu' ($tree -contains '&File/New &Tab >')
    Assert "D.3 its first row is Default Shell under the New Tab chord (got '$(if ($sub.Count) { $sub[0] -replace "`t", ' <tab> ' })')" `
        ($sub.Count -ge 1 -and (Label-Of $sub[0]) -eq '&Default Shell' -and (Accel-Of $sub[0]) -eq 'Ctrl+T')
    $gotD = @(if ($sub.Count -gt 1) { $sub[1..($sub.Count - 1)] })
    $sameD = ($gotD.Count -eq (@('---') + $labels).Count)
    if ($sameD) { $w = @('---') + $labels; for ($i = 0; $i -lt $gotD.Count; $i++) { if ($gotD[$i] -cne $w[$i]) { $sameD = $false } } }
    Assert "D.4 then a separator and the same catalog rows as the '+' dropdown" $sameD
    if ($root0 -ne [IntPtr]::Zero -and $psIdx -ge 0) {
        [void](Send-TestControlKey -Control $top -Key 'F')
        [void](Wait-MenuDepth $appPid 2)
        [void](Send-TestControlKey -Control $top -Key 'T')   # opens the submenu, Default Shell selected
        Assert 'D.4b New Tab opens its submenu' (Wait-MenuDepth $appPid 3)
        Pick-Row $top ($psIdx + 1)
        Assert 'D.5 choosing the row closes the menu' (Test-MenuGone $appPid)
        $new = Wait-NewLeaf $known 'd1-'
        Assert "D.6 File > New Tab > Windows PowerShell opens a powershell.exe pane (got '$(if ($new) { $new.Proc.ProcessName })')" `
            ($null -ne $new -and $new.Proc.ProcessName -ieq 'powershell')
        Assert "D.7 as a tab ($tabsD -> $(Tab-Total (Get-Tree 'd2')))" ((Tab-Total (Get-Tree 'd2b')) -eq ($tabsD + 1))
    }
    Close-AnyMenu $top $appPid

    # --- E: session persistence on --------------------------------------------------
    Say '== E: the "+" pick with session persistence on'
    Stop-Everything
    Write-Config "session-persistence = true`n"
    $appPid = Start-TestApp 't3753-ntse'
    Assert 'E.0 premise: the app is up with session persistence' ($appPid -gt 0)
    if ($appPid -gt 0) {
        $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
        Set-TestWindowSize -Window $top -Width 1400 -Height 800 | Out-Null
        [void](Wait-PlusPlaced $top)
        $known = Known-Ids 'e0'
        $menu = Open-PlusMenu $top $appPid
        Assert 'E.1 the dropdown opens' ($menu -ne [IntPtr]::Zero)
        if ($menu -ne [IntPtr]::Zero -and $psIdx -ge 0) {
            Pick-Row $top ($psIdx + 2)
            $new = Wait-NewLeaf $known 'e1-'
            Assert "E.2 the new pane runs powershell.exe (got '$(if ($new) { $new.Proc.ProcessName })')" `
                ($null -ne $new -and $new.Proc.ProcessName -ieq 'powershell')
            Assert "E.3 in an agent session (session_id '$(if ($new) { $new.Leaf.session_id })')" `
                ($null -ne $new -and [string]$new.Leaf.session_id -ne '')
        }
        Close-AnyMenu $top $appPid
    }

    Complete-TestBody
} finally {
    Stop-Everything
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedXdg) { $env:XDG_CONFIG_HOME = $savedXdg } else { Remove-Item env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts\guard-due.ps1') `
        update -Guard new-tab-shell -Repo $repoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'NEW-TAB-SHELL' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
