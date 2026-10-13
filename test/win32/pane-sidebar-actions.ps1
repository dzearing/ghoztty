# T1845 acceptance: acting on a pane from the Windows pane sidebar (Mac
# 597a193cc's PaneSidebarRow.contextMenu / click, PaneSidebarView's trash
# header button, BaseTerminalController.killPane).
#
# Layout: the first pane P, then four `+split right`s -> s1..s4, sidebar
# pinned to the panel. Rows are found from the app's own `pane sidebar rows`
# log line (each row's center and pane id), since a background desktop cannot
# be photographed row by row. What it checks:
#
#   1. Right-click a grid row: a popup menu reading Stash Pane / Move to New
#      Window / Close Pane; choosing Stash Pane stashes that pane.
#   2. Right-click a stashed row: Restore / Swap with Focused Pane (Alt+Click)
#      first; Escape dismisses it and nothing changes.
#   3. Alt-click the stashed row: it SWAPS with the focused pane - it is back
#      on screen and the pane that had focus is the one stashed now, still one
#      stashed, still four on screen.
#   4. The menu's Restore brings the swapped-out pane back.
#   5. The menu's Move to New Window takes s4 into a second window.
#   6. The menu's Close Pane closes s3 through the ordinary (interactive)
#      close - an idle shell, so no confirmation - and +list loses it.
#   7. Trash mode: the header's trash button turns it on (log, and the header
#      caption turns red); a row's x kills s2 at once - no undo parking - and
#      Escape posted to the window leaves trash mode.
#   8. On the rail, trash mode puts the x on each tile's corner: a click on
#      the corner kills s1, and a click on the tile's body only focuses.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl right-clicks the empty header instead of a row in step 1
# and expects a menu, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-actions.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1845-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1845')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
Add-Type -AssemblyName System.Drawing

# HMENU reads only: these take a menu HANDLE, not a window, so they are not
# desktop-bound and run fine in this process.
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class SbMenuRead {
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint id, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);
    // One entry per item: "SEP", or the caption ("~" first when grayed).
    public static string[] Items(IntPtr menu) {
        if (menu == IntPtr.Zero) return new string[0];
        int n = GetMenuItemCount(menu);
        if (n < 0) n = 0;
        var outp = new string[n];
        for (uint i = 0; i < (uint)n; i++) {
            uint state = GetMenuState(menu, i, 0x400); // MF_BYPOSITION
            if ((state & 0x800) != 0) { outp[i] = "SEP"; continue; } // MF_SEPARATOR
            var sb = new StringBuilder(256);
            GetMenuStringW(menu, i, sb, 256, 0x400);
            outp[i] = (((state & 0x1) != 0) ? "~" : "") + sb.ToString().Replace("\t", " / ");
        }
        return outp;
    }
}
'@

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { (Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue) }

# Every leaf object in `+list --json`: anything carrying both `id` and `pid`.
function Get-Leaves {
    [void](Invoke-Cli '+list --json')
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$out.Add($o) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($raw | ConvertFrom-Json) } catch { return @() }
    # Unrolled on purpose: every call site wraps it in @() (a `return ,`
    # here would come back as ONE element holding the whole array).
    return $out.ToArray()
}
function Get-Leaf([string]$Id) { @(Get-Leaves) | Where-Object { $_.id -eq $Id -or $_.name -eq $Id } | Select-Object -First 1 }
function Test-Stashed($leaf) { ($null -ne $leaf) -and ($leaf.PSObject.Properties.Name -contains 'stashed') -and ($leaf.stashed -eq $true) }
function Wait-Until([scriptblock]$Cond, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        if (& $Cond) { return $true }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale) }

function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
# The LAST line matching $Pattern logged after line $Skip, waiting up to $Ms.
function Wait-Log([string]$Pattern, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    $hit = $null
    do {
        Start-Sleep -Milliseconds 150
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    } while (-not $hit -and (Get-Date) -lt $deadline)
    if ($hit) {
        Start-Sleep -Milliseconds 300
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    }
    return $hit
}
function Test-LogSince([string]$Pattern, [int]$Skip) {
    return (@(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }).Count -gt 0)
}

# The latest `pane sidebar rows` line: every row's center (column client
# coordinates), its section and its pane id, plus the trash toggle's center.
function Get-Rows {
    $line = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pane sidebar rows ' }) | Select-Object -Last 1
    if (-not $line -or $line -notmatch 'mode=(\w+) heads=\S* items=(\S*) rules=\d+ scope=-?\d+,-?\d+ trash=(-?\d+),(-?\d+)') { return $null }
    $o = @{ Mode = $Matches[1]; Trash = @{ X = [int]$Matches[3]; Y = [int]$Matches[4] }; Items = @() }
    foreach ($i in ($Matches[2] -split ';' | Where-Object { $_ })) {
        if ($i -match '^g\d+([gs])@(-?\d+),(-?\d+)#(\S+)$') { $o.Items += , @{ Sec = $Matches[1]; X = [int]$Matches[2]; Y = [int]$Matches[3]; Id = $Matches[4] } }
    }
    return $o
}
function Wait-Rows([scriptblock]$Cond, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $r = Get-Rows
        if ($r -and (& $Cond $r)) { return $r }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return Get-Rows
}
function Row($rows, [string]$Id) { $rows.Items | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }

function At($top, $sb, $pt, [string]$Button = 'left', [string[]]$Mods = @()) {
    $x = $sb.Left + $pt.X; $y = $sb.Top + $pt.Y
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y $y -Action move)
    Start-Sleep -Milliseconds 120
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $x -Y $y -Button $Button -Action click -Modifiers $Mods
}
function Get-PinCenter($sb, [string]$Mode) {
    if ($Mode -eq 'mini') {
        $margin = Px 12; $card = Px 44; $tile = Px 28
        $inset = [int][math]::Truncate(($card - $tile) / 2)
        return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
    }
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = Px 18 }
}

function Get-MenuItems([IntPtr]$menuWnd) {
    $r = Invoke-TestMessage -Window $menuWnd -Message 0x01E1   # MN_GETHMENU
    if ($r -eq [long]::MinValue -or $r -eq 0) { return @() }
    return @([SbMenuRead]::Items([IntPtr]$r))
}
# Keys into the menu's modal loop: posted, so focus is never touched.
function Send-MenuKey([IntPtr]$w, [string]$key) {
    [void](Send-TestControlKey -Control $w -Key $key)
    Start-Sleep -Milliseconds 150
}
function Test-MenuGone([int]$gpid, [int]$ms = 2000) {
    for ($t = 0; $t -lt $ms; $t += 50) {
        if ((Get-TestWindow -ProcessId $gpid -Class '#32768') -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}
# Right-click a row and return the menu's items (empty when none opened).
# Leaves the menu up for the caller to drive.
function Open-RowMenu($top, $sb, $row) {
    [void](At $top $sb @{ X = $row.X; Y = $row.Y } 'right')
    $popup = Wait-TestPopupMenu -ProcessId $script:appPid -TimeoutMs 2500
    if ($popup -eq [IntPtr]::Zero) { return @() }
    return @(Get-MenuItems $popup)
}
# Pick the $n-th enabled command (1-based) of the open menu with Down x n, Enter.
function Select-MenuItem($top, [int]$n) {
    for ($k = 0; $k -lt $n; $k++) { Send-MenuKey $top 'Down' }
    Send-MenuKey $top 'Enter'
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1845'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    $script:appPid = $app.Pid
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowSize -Window $top -Width (Px 1400) -Height (Px 800))
    Start-Sleep -Milliseconds 600

    $leaves = @(Get-Leaves)
    $idP = if ($leaves.Count -ge 1) { $leaves[0].id } else { '' }
    Assert "setup: +list --json answers with the first pane" ($idP -ne '')
    foreach ($n in 1..4) {
        [void](Invoke-Cli "+split --direction=right --name=s$n")
        Start-Sleep -Milliseconds 700
    }
    $ids = @{}
    foreach ($l in @(Get-Leaves)) {
        if ($l.name) { $ids[[string]$l.name] = $l.id }
    }
    Assert "setup: five panes listed (P + s1..s4)" ((@(Get-Leaves)).Count -eq 5 -and $ids.ContainsKey('s1') -and $ids.ContainsKey('s4'))

    # Pin: the panel lays out the rows the menu is opened on.
    $sb = Get-Sidebar $top
    if ($null -eq $sb) { "  SETUP FAIL: no sidebar"; $script:failures++; return }
    [void](At $top $sb (Get-PinCenter $sb 'mini'))
    $rows = Wait-Rows { param($r) $r.Mode -eq 'expanded' -and $r.Items.Count -eq 5 }
    $sb = Get-Sidebar $top
    Assert "setup: pinned, the rows line lists all five rows" ($null -ne $rows -and $rows.Mode -eq 'expanded' -and $rows.Items.Count -eq 5)
    if ($null -eq $rows -or $rows.Items.Count -lt 5) { return }

    "== 1: right-click a grid row -> Stash Pane / Move to New Window / Close Pane"
    $rowP = Row $rows $idP
    $target = if ($NegativeControl) { @{ X = Px 30; Y = Px 18 } } else { @{ X = $rowP.X; Y = $rowP.Y } }
    if ($NegativeControl) { "  NEGATIVE CONTROL: right-clicking the header, not a row - this run MUST fail" }
    $items = @(Open-RowMenu $top $sb $target)
    "  menu: $($items -join ' | ')"
    Assert "a popup menu opened on the row" ($items.Count -gt 0)
    Assert "it reads Stash Pane | SEP | Move to New Window | SEP | Close Pane" (($items -join '|') -eq '&Stash Pane|SEP|Move to &New Window|SEP|&Close Pane')
    if ($items.Count -gt 0) { Select-MenuItem $top 1 }
    Assert "the menu closed on the choice" (Test-MenuGone $app.Pid)
    Assert "Stash Pane stashed P" (Wait-Until { Test-Stashed (Get-Leaf $idP) })

    "== 2: right-click a stashed row -> Restore and the Alt-click swap first"
    $rows = Wait-Rows { param($r) (Row $r $idP).Sec -eq 's' }
    $rowP = Row $rows $idP
    $items = @(Open-RowMenu $top $sb $rowP)
    "  menu: $($items -join ' | ')"
    Assert "it reads Restore | Swap with Focused Pane / Alt+Click | SEP | Move to New Window | SEP | Close Pane" `
        (($items -join '|') -eq '&Restore|S&wap with Focused Pane / Alt+Click|SEP|Move to &New Window|SEP|&Close Pane')
    if ($items.Count -gt 0) { Send-MenuKey $top 'Escape' }
    Assert "Escape dismissed it" (Test-MenuGone $app.Pid)
    Assert "and P is still stashed" (Test-Stashed (Get-Leaf $idP))

    "== 3: Alt-click the stashed row swaps it with the focused pane"
    $mark = Get-LogCount
    $before = @(Get-Leaves | Where-Object { -not (Test-Stashed $_) } | ForEach-Object { $_.id })
    [void](At $top $sb @{ X = $rowP.X; Y = $rowP.Y } 'left' @('Alt'))
    Assert "the swap ran (log)" ($null -ne (Wait-Log 'pane sidebar swapped stashed pane' $mark))
    Assert "P is back on screen" (Wait-Until { -not (Test-Stashed (Get-Leaf $idP)) })
    $nowStashed = @(Get-Leaves | Where-Object { Test-Stashed $_ })
    Assert "exactly one pane is stashed now ($($nowStashed.Count))" ($nowStashed.Count -eq 1)
    $swappedOut = if ($nowStashed.Count -eq 1) { $nowStashed[0].id } else { '' }
    Assert "the stashed one is a pane that WAS on screen (the focused one)" ($swappedOut -ne '' -and $before -contains $swappedOut)
    Assert "still four on screen" ((@(Get-Panes $top | Where-Object Visible)).Count -eq 4)

    "== 4: the menu's Restore brings the swapped-out pane back"
    $rows = Wait-Rows { param($r) (Row $r $swappedOut).Sec -eq 's' }
    $items = @(Open-RowMenu $top $sb (Row $rows $swappedOut))
    if ($items.Count -gt 0) { Select-MenuItem $top 1 }
    Assert "it is restored" (Wait-Until { -not (Test-Stashed (Get-Leaf $swappedOut)) })
    Assert "five on screen" (Wait-Until { (@(Get-Panes $top | Where-Object Visible)).Count -eq 5 })

    "== 5: Move to New Window takes s4 into a window of its own"
    $rows = Wait-Rows { param($r) $r.Items.Count -eq 5 -and @($r.Items | Where-Object { $_.Sec -eq 's' }).Count -eq 0 }
    $items = @(Open-RowMenu $top $sb (Row $rows $ids['s4']))
    if ($items.Count -gt 0) { Select-MenuItem $top 2 }   # Stash, Move to New Window
    Assert "a second window opened" (Wait-Until { (@(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')).Count -eq 2 })
    Assert "this window has four panes left" (Wait-Until { (@(Get-Panes $top)).Count -eq 4 })

    "== 6: Close Pane closes s3 the ordinary way"
    $mark = Get-LogCount
    $rows = Wait-Rows { param($r) $r.Items.Count -eq 4 }
    $items = @(Open-RowMenu $top $sb (Row $rows $ids['s3']))
    if ($items.Count -gt 0) { Select-MenuItem $top 3 }   # Stash, Move, Close
    Assert "it went through the interactive close (log)" ($null -ne (Wait-Log 'pane sidebar close pane \(interactive\)' $mark))
    Assert "s3 is gone from +list" (Wait-Until { $null -eq (Get-Leaf $ids['s3']) })

    "== 7: trash mode - the header button, a one-click kill, Escape"
    $rows = Wait-Rows { param($r) $r.Items.Count -eq 3 }
    $mark = Get-LogCount
    [void](At $top $sb $rows.Trash)
    Assert "the trash button turned trash mode on (log)" ($null -ne (Wait-Log 'pane sidebar trash mode on=true' $mark))
    # The x is the row's trailing button: 20 DIP, sm (4) inside the 8 DIP fill inset.
    $rowS2 = Row $rows $ids['s2']
    $kx = $sb.Width - (Px 8) - (Px 4) - [int]((Px 20) / 2)
    $mark = Get-LogCount
    [void](At $top $sb @{ X = $kx; Y = $rowS2.Y })
    Assert "the x killed it (log)" ($null -ne (Wait-Log 'pane sidebar kill pane' $mark))
    Assert "s2 is gone from +list" (Wait-Until { $null -eq (Get-Leaf $ids['s2']) })
    Assert "no confirmation dialog came up" ((Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero)
    Assert "and nothing was parked for undo" (-not (Test-LogSince 'parked closed pane for undo' $mark))
    Assert "trash mode is still on after a kill" (-not (Test-LogSince 'pane sidebar trash mode on=false' $mark))
    $mark = Get-LogCount
    $pane0 = (@(Get-Panes $top))[0].Hwnd
    [void](Send-TestControlKey -Control ([IntPtr]$pane0) -Key 'Escape')
    Assert "Escape left trash mode (log)" ($null -ne (Wait-Log 'pane sidebar trash mode on=false' $mark))

    "== 8: on the rail, the x sits on a tile's corner"
    $mark = Get-LogCount
    [void](At $top $sb $rows.Trash)
    Assert "trash mode on again (log)" ($null -ne (Wait-Log 'pane sidebar trash mode on=true' $mark))
    [void](At $top $sb (Get-PinCenter $sb 'expanded'))   # unpin: the rail
    $rows = Wait-Rows { param($r) $r.Mode -eq 'mini' -and $r.Items.Count -eq 2 }
    $sb = Get-Sidebar $top
    Assert "back on the rail with two tiles" ($rows.Mode -eq 'mini' -and $rows.Items.Count -eq 2)
    # Let the card that unpinning opened contract (the pointer is elsewhere).
    [void](Wait-Log 'pane sidebar card close' $mark 3000)
    $tileS1 = Row $rows $ids['s1']
    $tileP = Row $rows $idP
    # A click on P's tile BODY (its bottom-right) still only focuses.
    $half = [int]((Px 28) / 2)
    $mark = Get-LogCount
    [void](At $top $sb @{ X = $tileP.X + $half - (Px 3); Y = $tileP.Y + $half - (Px 3) })
    Start-Sleep -Milliseconds 500
    Assert "a click on the tile's body killed nothing" ((-not (Test-LogSince 'pane sidebar kill pane' $mark)) -and $null -ne (Get-Leaf $idP))
    # The corner x: 13 DIP, 2 DIP over the tile's top-left corner.
    $kcx = $tileS1.X - $half - (Px 2) + [int]((Px 13) / 2)
    $kcy = $tileS1.Y - $half - (Px 2) + [int]((Px 13) / 2)
    $mark = Get-LogCount
    [void](At $top $sb @{ X = $kcx; Y = $kcy })
    Assert "the tile's x killed s1 (log)" ($null -ne (Wait-Log 'pane sidebar kill pane' $mark))
    Assert "s1 is gone from +list" (Wait-Until { $null -eq (Get-Leaf $ids['s1']) })
    Assert "P is still there" ($null -ne (Get-Leaf $idP))

    Assert "no crash" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-actions -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1845' -Path $transcript `
        -Label 'T1845 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
