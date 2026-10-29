# T1829 acceptance: the pane sidebar's all-windows scope on Windows (Mac
# 55352e377, b4a3216cc). The header's toggle widens the sidebar from this
# window to every window, as an OUTLINE: each window a header row with its
# panes indented beneath, sorted by name (Finder order), `<project>: <worktree>`
# windows grouped under a project header. Only this window has a selection;
# another window's row raises that window and focuses the pane there.
#
# Layout: window A (P + s1, renamed "zeta"), then three more windows:
# wB "ghoztty: main" (b1 + b2, b2 stashed), wC "ghoztty: feature-2", and
# wD "Build logs". What it checks, all in A's sidebar:
#
#   1. The collapse/expand toggle, then the all-windows toggle: the roster becomes four groups in
#      name order - Build logs, then the ghoztty project (feature-2, main),
#      then zeta - with one project head and four window heads, every pane
#      listed (B's stashed one too, right after its grid row with no
#      divider or caption - T2313), one hairline before zeta, and no empty
#      well at rest. The panel paints content.
#   2. A click on B's STASHED row restores b2 in window B (the same verb as
#      ghoztty://focus).
#   3. A click on another window's header raises it (log).
#   4. A click on THIS window's header folds its panes away, and again
#      brings them back.
#   5. A click on the project header folds its windows away, and back.
#   6. Renaming B moves it in the order; closing D drops it from the list -
#      the list follows other windows, not only its own.
#   6b. The search field (T1877): every word must match (window, pane,
#      banner, folder), accents fold, "No matching panes" when empty, Escape
#      clears, Return reveals the first hit through the click's own path.
#   7. Collapsed, the rail is one tile per WINDOW (T2445) with no divider between
#      windows and no header rows.
#   8. The toggle switches back to this window's panes only, and clears a
#      query: back on, every window is listed (T1877).
#   9. Motion (T1880): sections 1, 4, 5 and 8 also assert that the switch
#      slid and each fold animated in place (`pane sidebar transition` log
#      lines; the pixel math is unit-tested in pane_sidebar_transition.zig).
#      With the effects off (the remote-session seam, never the user's
#      machine-wide "Animation effects"), the switch and a fold land with no
#      transition at all.
#
# Geometry comes from the `pane sidebar outline` log line (heads, items,
# rules, the toggle, in the column's client coordinates): a background
# desktop cannot be photographed row by row.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl never turns the scope on and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-all-windows.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1829-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1829')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
Add-Type -AssemblyName System.Drawing
if (-not ('SidebarSessionPost' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SidebarSessionPost {
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
}
"@
}

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { (Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

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
    return , $out.ToArray()
}
function Test-StashedId([string]$Id) {
    foreach ($l in (Get-Leaves)) {
        if ($l.id -eq $Id -or $l.name -eq $Id) {
            return ($l.PSObject.Properties.Name -contains 'stashed') -and ($l.stashed -eq $true)
        }
    }
    return $false
}
function Wait-Stashed([string]$Id, [bool]$Want, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        if ((Test-StashedId $Id) -eq $Want) { return $true }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale) }

function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
# The LAST line matching $Pattern logged after line $Skip, waiting up to
# $Ms for one to appear (and a further 300 ms for later ones to settle).
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

# Parse a `pane sidebar outline` line.
function Read-Outline([string]$Line) {
    if (-not $Line -or $Line -notmatch 'mode=(\w+) heads=(\S*) items=(\S*) rules=(\d+) scope=(-?\d+),(-?\d+)') { return $null }
    $o = @{ Raw = $Line; Mode = $Matches[1]; Rules = [int]$Matches[4]; Scope = @{ X = [int]$Matches[5]; Y = [int]$Matches[6] }; Heads = @(); Items = @() }
    $headsRaw = $Matches[2]; $itemsRaw = $Matches[3]
    foreach ($h in ($headsRaw -split ';' | Where-Object { $_ })) {
        if ($h -match '^([PW])(\d+)@(-?\d+),(-?\d+)$') { $o.Heads += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    foreach ($i in ($itemsRaw -split ';' | Where-Object { $_ })) {
        if ($i -match '^g(\d+)([gs])@(-?\d+),(-?\d+)$') { $o.Items += , @{ Group = [int]$Matches[1]; Sec = $Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    # T2340: each head's chevron and window icon (`$null` on a project head),
    # in heads order.
    $o.Chev = @(); $o.HIcon = @()
    if ($Line -match ' chev=(\S*)') { foreach ($c in ($Matches[1] -split ';' | Where-Object { $_ })) { $xy = $c -split ','; $o.Chev += , @{ X = [int]$xy[0]; Y = [int]$xy[1] } } }
    if ($Line -match ' hicon=(\S*)') {
        foreach ($c in ($Matches[1] -split ';' | Where-Object { $_ })) {
            if ($c -eq '-') { $o.HIcon += , $null } else { $xy = $c -split ','; $o.HIcon += , @{ X = [int]$xy[0]; Y = [int]$xy[1] } }
        }
    }
    return $o
}
function Head($o, [string]$Kind, [int]$Group) { $o.Heads | Where-Object { $_.Kind -eq $Kind -and $_.Group -eq $Group } | Select-Object -First 1 }
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
# The collapse/expand toggle (T2289): the rail's first item and the panel
# header's first item, on the same pixels in both modes - centered in the
# rail card, the card's inset below its top (client coordinates).
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
}
# The all-windows toggle (T2289 header order): the toggle leads, then the
# caption; at the trailing edge sits this button alone, sm (4) in, on the
# toggle's row - trash mode's button that sat after it is gone (T2280).
function Get-ScopeCenter($sb) {
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = (Get-ToggleCenter $sb).Y }
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1829'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    # Section 9 turns motion off through the remote-session seam (T1951), the
    # same switch "Animation effects" off throws - never the user's real
    # setting, which is machine-wide.
    $script:seam = Join-Path $tmp 'remote-session.txt'
    Set-Content -Path $script:seam -Value '0' -NoNewline -Encoding ascii
    $env:GHOZTTY_TEST_REMOTE_SESSION_FILE = $script:seam
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 900))
    Start-Sleep -Milliseconds 600

    # Window A: P + s1, named "zeta" so it sorts last.
    [void](Invoke-Cli "+split --direction=right --name=s1")
    Start-Sleep -Milliseconds 700
    Assert "setup: window A renamed zeta ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=zeta") -eq 0)
    # The other windows. Each opens on the test desktop, never the user's.
    Assert "setup: wB opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1 --title=`"ghoztty: main`"") -eq 0)
    Start-Sleep -Milliseconds 1200
    Assert "setup: b2 split in wB ($(Get-CliErr))" ((Invoke-Cli "+split --target=b1 --direction=right --name=b2") -eq 0)
    Start-Sleep -Milliseconds 700
    Assert "setup: b2 stashed ($(Get-CliErr))" ((Invoke-Cli "+stash --target=b2") -eq 0)
    Assert "setup: b2 reads stashed" (Wait-Stashed 'b2' $true)
    Assert "setup: wC opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wC --name=c1 --title=`"ghoztty: feature-2`"") -eq 0)
    Start-Sleep -Milliseconds 1200
    Assert "setup: wD opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wD --name=d1 --title=`"Build logs`"") -eq 0)
    Start-Sleep -Milliseconds 1200

    "== 1: the toggle lists every window as an outline, sorted and grouped"
    $sb = Get-Sidebar $top
    Assert "A has a sidebar" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top
    # T2290: the rail's card at 240 DIP, in the rail's 12 DIP insets (flat).
    $panelW = (Px 12) + (Px 240) + (Px 12)
    Assert "expanded: the 240 DIP card in its insets ($($sb.Width) vs $panelW)" ([math]::Abs($sb.Width - $panelW) -le 1)
    $mark = Get-LogCount
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: the toggle is never clicked - this run MUST fail"
    } else {
        Assert "toggle click delivered" (ClickAt $top $sb (Get-ScopeCenter $sb))
    }
    $scopeLine = Wait-Log 'pane sidebar scope all_windows=true' $mark
    Assert "the toggle turned the all-windows scope on (log)" ($null -ne $scopeLine)
    # T1880: the switch slides (Mac 0.3 s), toward all windows, and ends.
    Assert "...and slid there: a scope transition ran on the panel (log)" ($null -ne (Wait-Log 'pane sidebar transition scope surface=rail ms=300' $mark 2000))
    Assert "...which finished on its own (log)" ($null -ne (Wait-Log 'pane sidebar transition done surface=rail' $mark 2000))
    $groups = Wait-Log 'pane sidebar all-windows groups=' $mark
    "  $groups"
    Assert "four groups, every pane" ($groups -match 'groups=4 panes=6 ')
    Assert "name order, the lone windows first (T2421), then the project: Build logs | zeta | ghoztty/feature-2 | ghoztty/main" ($groups -match 'order=Build logs\|zeta\|ghoztty/feature-2\|ghoztty/main$')
    # T1924 (Mac 321e61d7c): the caption counts the windows, and every window
    # but this one opens folded.
    Assert "the ALL WINDOWS caption counts four windows" ($groups -match ' windows=4 ')
    Assert "every other window opens folded, this one open (folded=3)" ($groups -match ' folded=3 ')
    $o0 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "folded by default: only zeta's two rows show, under four window heads" ($null -ne $o0 -and $o0.Items.Count -eq 2 -and @($o0.Items | Where-Object Group -ne 1).Count -eq 0 -and @($o0.Heads | Where-Object Kind -eq 'W').Count -eq 4)
    # A chevron unfolds another window without raising it.
    $chevLine = Wait-Log 'pane sidebar outline mode=expanded' $mark
    $chev = @()
    if ($chevLine -match ' chev=(\S*)') { $chev = @($Matches[1] -split ';' | Where-Object { $_ } | ForEach-Object { $xy = $_ -split ','; @{ X = [int]$xy[0]; Y = [int]$xy[1] } }) }
    Assert "each head logs its chevron ($($chev.Count) for $($o0.Heads.Count))" ($null -ne $o0 -and $chev.Count -eq $o0.Heads.Count)
    foreach ($gi in 0, 2, 3) {
        $o0 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' 0 1000)
        $chevLine = Wait-Log 'pane sidebar outline mode=expanded' 0 1000
        $chev = @()
        if ($chevLine -match ' chev=(\S*)') { $chev = @($Matches[1] -split ';' | Where-Object { $_ } | ForEach-Object { $xy = $_ -split ','; @{ X = [int]$xy[0]; Y = [int]$xy[1] } }) }
        $k = -1
        for ($j = 0; $j -lt $o0.Heads.Count; $j++) { if ($o0.Heads[$j].Kind -eq 'W' -and $o0.Heads[$j].Group -eq $gi) { $k = $j } }
        $mark = Get-LogCount
        if ($k -ge 0 -and $k -lt $chev.Count) { [void](ClickAt $top $sb $chev[$k]) }
        Assert "group $($gi)'s chevron unfolded it (log)" ($null -ne (Wait-Log 'pane sidebar unfold' $mark 2000))
        Assert "...without raising its window" ($null -eq (Wait-Log 'pane sidebar raise window' $mark 300))
    }
    $groups = Wait-Log 'pane sidebar all-windows groups=' $mark
    Assert "unfolded: nothing is folded now" ($groups -match ' folded=0 ')
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "the outline geometry was logged" ($null -ne $o)
    if ($null -eq $o) { return }
    "  heads: $(($o.Heads | ForEach-Object { "$($_.Kind)$($_.Group)" }) -join ' ')  items: $(($o.Items | ForEach-Object { "g$($_.Group)$($_.Sec)" }) -join ' ')  rules=$($o.Rules)"
    Assert "one project head and four window heads" ((@($o.Heads | Where-Object Kind -eq 'P').Count -eq 1) -and (@($o.Heads | Where-Object Kind -eq 'W').Count -eq 4))
    Assert "the project head names its first window (group 2)" ($null -ne (Head $o 'P' 2))
    Assert "every pane is a row, B's stash included" ($o.Items.Count -eq 6 -and @($o.Items | Where-Object { $_.Group -eq 3 -and $_.Sec -eq 's' }).Count -eq 1)
    # T2313 (Mac 47b39b1cb): a window's stash has no divider or caption in
    # all windows - B's stashed row follows its grid row at a grid row's own
    # pitch - and since T2340 (Mac c4dbe30be) no hairline between top-level
    # windows either: their headers set them apart.
    Assert "no hairline at all - not before zeta, not before B's stash ($($o.Rules))" ($o.Rules -eq 0)
    # T2340 (Mac c4dbe30be, 28f6cde09): grouped windows are not indented -
    # every window head's chevron is in one column - and each carries a
    # window icon; the project head has none.
    $wChev = @(); $iconsOk = ($o.HIcon.Count -eq $o.Heads.Count -and $o.Chev.Count -eq $o.Heads.Count)
    for ($k = 0; $iconsOk -and $k -lt $o.Heads.Count; $k++) {
        if ($o.Heads[$k].Kind -eq 'W') {
            $wChev += $o.Chev[$k].X
            if ($null -eq $o.HIcon[$k] -or $o.HIcon[$k].X -le $o.Chev[$k].X) { $iconsOk = $false }
        } elseif ($null -ne $o.HIcon[$k]) { $iconsOk = $false }
    }
    Assert "every window head carries a window icon after its chevron, the project head none (T2340)" $iconsOk
    Assert "every window head's chevron is in one column, grouped or not ($($wChev -join ','), T2340)" ($wChev.Count -eq 4 -and @($wChev | Select-Object -Unique).Count -eq 1)
    $bRows = @($o.Items | Where-Object { $_.Group -eq 3 })
    $zRows = @($o.Items | Where-Object { $_.Group -eq 1 })
    if ($bRows.Count -eq 2 -and $zRows.Count -eq 2) {
        $bPitch = $bRows[1].Y - $bRows[0].Y
        $zPitch = $zRows[1].Y - $zRows[0].Y
        Assert "B's stashed row sits a plain row's pitch under its grid row ($bPitch vs zeta's $zPitch)" ($bPitch -eq $zPitch)
    } else { Assert "setup: B and zeta each list two rows ($($bRows.Count), $($zRows.Count))" $false }
    Assert "at rest the outline lays out no empty well (T2313, Mac b7de64ce8)" ($o.Raw -match ' tray=-')
    $ordered = $true
    for ($k = 1; $k -lt $o.Heads.Count; $k++) { if ($o.Heads[$k].Y -le $o.Heads[$k - 1].Y) { $ordered = $false } }
    Assert "heads stack top to bottom in outline order" $ordered
    $zeta = Head $o 'W' 1
    $zetaRows = @($o.Items | Where-Object Group -eq 1)
    Assert "this window's panes sit under its header" ($null -ne $zeta -and $zetaRows.Count -eq 2 -and ($zetaRows | ForEach-Object { $_.Y -gt $zeta.Y }) -notcontains $false)
    try {
        $shot = Get-TestWindowPixels -Window ([IntPtr]$sb.Hwnd) -Sync
        $path = Join-Path $env:TEMP 't1829-all-windows.png'
        $shot.Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $c = Get-TestCaptureContent -Shot $shot
        Close-TestWindowPixels -Shot $shot
        "  (saved $path; distinct=$($c.Distinct))"
        Assert "the outline paints content" ($c.Distinct -ge 3)
    } catch { Assert "the outline capture worked ($($_.Exception.Message))" $false }

    "== 2: another window's stashed row restores the pane in its own window"
    $row = $o.Items | Where-Object { $_.Group -eq 3 -and $_.Sec -eq 's' } | Select-Object -First 1
    $mark = Get-LogCount
    if ($row) { [void](ClickAt $top $sb $row) }
    Assert "b2 was restored by the click" (Wait-Stashed 'b2' $false)
    Assert "it went through the other-window path (log)" ($null -ne (Wait-Log 'pane sidebar focus other window section=stashed' $mark 2000))
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "A's list followed: B's stash is gone, both its panes are grid rows" ($null -ne $o -and @($o.Items | Where-Object { $_.Group -eq 3 -and $_.Sec -eq 'g' }).Count -eq 2)

    "== 3: another window's header raises that window"
    $mark = Get-LogCount
    $h = Head $o 'W' 0
    if ($h) { [void](ClickAt $top $sb $h) }
    Assert "clicking Build logs' header raised it (log)" ($null -ne (Wait-Log 'pane sidebar raise window' $mark 2000))

    "== 4: this window's header folds its panes, and unfolds them"
    $mark = Get-LogCount
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' 0 1000)
    $h = Head $o 'W' 1
    if ($h) { [void](ClickAt $top $sb $h) }
    $o2 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "folded: zeta's rows are gone, its header stays" ($null -ne $o2 -and @($o2.Items | Where-Object Group -eq 1).Count -eq 0 -and $null -ne (Head $o2 'W' 1))
    # T1880: the fold covers the rows top-down (Mac 0.22 s) - measured against
    # the list after it, not dropped because the head moved.
    Assert "the fold animated (log)" ($null -ne (Wait-Log 'pane sidebar transition fold surface=rail ms=220' $mark 2000))
    Assert "...and finished without landing early" (($null -ne (Wait-Log 'pane sidebar transition done surface=rail' $mark 2000)) -and ($null -eq (Wait-Log 'transition fold lands' $mark 200)))
    $mark = Get-LogCount
    $h = Head $o2 'W' 1
    if ($h) { [void](ClickAt $top $sb $h) }
    $o3 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "unfolded: zeta's two rows are back" ($null -ne $o3 -and @($o3.Items | Where-Object Group -eq 1).Count -eq 2)
    Assert "...revealed top-down: the unfold animated and finished in place" (($null -ne (Wait-Log 'pane sidebar transition fold surface=rail' $mark 2000)) -and ($null -ne (Wait-Log 'pane sidebar transition done surface=rail' $mark 2000)) -and ($null -eq (Wait-Log 'transition fold lands' $mark 200)))

    "== 5: the project header folds its windows, and unfolds them"
    $mark = Get-LogCount
    $h = Head $o3 'P' 2
    if ($h) { [void](ClickAt $top $sb $h) }
    $o4 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "folded: the project's window heads and rows are gone" ($null -ne $o4 -and $null -eq (Head $o4 'W' 2) -and $null -eq (Head $o4 'W' 3) -and @($o4.Items | Where-Object { $_.Group -in 2, 3 }).Count -eq 0)
    Assert "folded: the project head itself stays" ($null -ne $o4 -and $null -ne (Head $o4 'P' 2))
    Assert "...and the project's fold animated in place too (log)" (($null -ne (Wait-Log 'pane sidebar transition fold surface=rail' $mark 2000)) -and ($null -eq (Wait-Log 'transition fold lands' $mark 200)))
    $mark = Get-LogCount
    $h = Head $o4 'P' 2
    if ($h) { [void](ClickAt $top $sb $h) }
    $o5 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "unfolded: both windows are back" ($null -ne $o5 -and $null -ne (Head $o5 'W' 2) -and $null -ne (Head $o5 'W' 3))

    "== 6: the list follows other windows: a rename re-sorts, a close drops"
    $mark = Get-LogCount
    Assert "+rename wB alpha ($(Get-CliErr))" ((Invoke-Cli "+rename --target=wB --title=alpha") -eq 0)
    $g = Wait-Log 'pane sidebar all-windows groups=4.*order=alpha\|' $mark
    "  $g"
    Assert "renamed B sorts first, out of the project" ($g -match 'order=alpha\|Build logs\|zeta\|ghoztty/feature-2$')
    Assert "...and keeps the fold the user flipped (folded=0)" ($g -match ' folded=0 ')
    # A window opened while the list shows arrives folded (T1924), and the
    # caption's count follows it.
    $mark = Get-LogCount
    Assert "+new-window wE ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wE --name=e1 --title=`"mid`"") -eq 0)
    $g = Wait-Log 'pane sidebar all-windows groups=5 ' $mark 6000
    "  $g"
    Assert "the new window arrives folded, and the caption counts five" ($null -ne $g -and $g -match ' windows=5 folded=1 ')
    $mark = Get-LogCount
    Assert "+close wE ($(Get-CliErr))" ((Invoke-Cli "+close --target=wE") -eq 0)
    Assert "...and it leaves the list" ($null -ne (Wait-Log 'pane sidebar all-windows groups=4 .*windows=4 ' $mark 6000))
    $mark = Get-LogCount
    Assert "+close wD ($(Get-CliErr))" ((Invoke-Cli "+close --target=wD") -eq 0)
    $g = Wait-Log 'pane sidebar all-windows groups=3 ' $mark 6000
    "  $g"
    Assert "closing D dropped it from A's list" ($g -match 'order=alpha\|zeta\|ghoztty/feature-2$')

    "== 6b: the search field filters by every word, Escape clears, Return reveals (T1877)"
    # Windows now: alpha (b1, b2), ghoztty: feature-2 (c1), zeta (P, s1).
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' 0 1000)
    $line = Wait-Log 'pane sidebar outline mode=expanded' 0 1000
    $sp = $null
    if ($line -match ' search=(-?\d+),(-?\d+) nomatch=(\d)') { $sp = @{ X = [int]$Matches[1]; Y = [int]$Matches[2] } }
    Assert "the outline logs a search field under the header" ($null -ne $sp -and $null -ne $o -and @($o.Heads | Where-Object { $_.Y -le $sp.Y }).Count -eq 0)
    # A real click activates its window (WM_MOUSEACTIVATE); a posted one off
    # the input desktop cannot, and section 3 raised another window.
    Assert "setup: window A is the active window again" (Set-TestActiveWindow -Window $top)
    $mark = Get-LogCount
    if ($sp) { [void](ClickAt $top $sb $sp) }
    Assert "a click in the field gives the column the keyboard (log)" ($null -ne (Wait-Log 'pane sidebar search focus=true' $mark 3000))
    # Escape on an EMPTY field gives the caret back to the pane (Mac).
    $mark = Get-LogCount
    [void](Send-TestControlKey -Control ([IntPtr]$sb.Hwnd) -Key Escape)
    Assert "Escape on an empty field releases the caret (log)" ($null -ne (Wait-Log 'pane sidebar search released the caret' $mark 2000))
    # The keyboard itself, read back from the thread (focus is asynchronous).
    $focusedAway = $false
    for ($i = 0; $i -lt 20 -and -not $focusedAway; $i++) {
        $fh = Get-TestFocusedWindow -Window $top
        $focusedAway = ($fh -ne [IntPtr]::Zero -and $fh -ne [IntPtr]$sb.Hwnd)
        if (-not $focusedAway) { Start-Sleep -Milliseconds 100 }
    }
    Assert "...and the keyboard really left the column for the pane" $focusedAway
    $mark = Get-LogCount
    if ($sp) { [void](ClickAt $top $sb $sp) }
    Assert "a second click takes it back" ($null -ne (Wait-Log 'pane sidebar search focus=true' $mark 3000))
    $mark = Get-LogCount
    [void](Send-TestControlText -Control ([IntPtr]$sb.Hwnd) -Text 'feature')
    $g = Wait-Log 'pane sidebar all-windows groups=1 .*search=1 ' $mark
    "  $g"
    Assert "'feature' keeps only the window it names" ($g -match 'panes=1 .*order=ghoztty/feature-2$')
    $mark = Get-LogCount
    [void](Send-TestControlText -Control ([IntPtr]$sb.Hwnd) -Text ' zeta')
    $g = Wait-Log 'pane sidebar all-windows groups=0 ' $mark
    Assert "every word must match: 'feature zeta' matches nothing" ($null -ne $g -and $g -match 'lines=0 search=2')
    Assert "the empty result says No matching panes" ($null -ne (Wait-Log 'pane sidebar outline mode=expanded.* nomatch=1' $mark 2000))
    $mark = Get-LogCount
    [void](Send-TestControlKey -Control ([IntPtr]$sb.Hwnd) -Key Escape)
    Assert "Escape clears the query (log)" ($null -ne (Wait-Log 'pane sidebar search cleared by escape' $mark 2000))
    $g = Wait-Log 'pane sidebar all-windows groups=3 .*search=0 ' $mark
    Assert "cleared: every window is listed again" ($null -ne $g)
    $mark = Get-LogCount
    # Diacritics fold both ways (Mac's .diacriticInsensitive): 'f`u{00EB}ature'.
    [void](Send-TestControlText -Control ([IntPtr]$sb.Hwnd) -Text ("f" + [char]0x00EB + "ature"))
    $g = Wait-Log 'pane sidebar all-windows groups=1 .*search=1 ' $mark
    Assert "an accented query still finds feature-2" ($null -ne $g -and $g -match 'order=ghoztty/feature-2$')
    $mark = Get-LogCount
    [void](Send-TestControlKey -Control ([IntPtr]$sb.Hwnd) -Key Enter)
    Assert "Return reveals the first hit (log)" ($null -ne (Wait-Log 'pane sidebar search reveal first hit own=false' $mark 2000))
    Assert "...through the other-window focus path, as a click would" ($null -ne (Wait-Log 'pane sidebar focus other window section=grid' $mark 2000))
    Assert "...and the field let go of the keyboard as the other window took it" ($null -ne (Wait-Log 'pane sidebar search focus=false' $mark 3000))
    $mark = Get-LogCount
    [void](Send-TestControlKey -Control ([IntPtr]$sb.Hwnd) -Key Escape)
    Assert "Escape clears it again" ($null -ne (Wait-Log 'pane sidebar all-windows groups=3 .*search=0 ' $mark))

    "== 6c: a new window's terminal gets the caret, not its search field (T2366)"
    # Mac 470526d63: a window ordered in while the shared list shows every
    # window handed the caret to its search field. Here the frame's
    # WM_SETFOCUS forwards to the pane, and the field takes the keyboard only
    # from a click. Start with the caret IN A's field, so a new window that
    # inherited it would show.
    Assert "setup: window A is the active window again" (Set-TestActiveWindow -Window $top)
    $mark = Get-LogCount
    if ($sp) { [void](ClickAt $top $sb $sp) }
    Assert "setup: A's search field holds the keyboard" ($null -ne (Wait-Log 'pane sidebar search focus=true' $mark 3000))
    $tops = @(Get-TestWindows -ProcessId $app.Pid | ForEach-Object { $_.Hwnd })
    $mark = Get-LogCount
    Assert "+new-window wF ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wF --name=f1 --title=`"fresh`"") -eq 0)
    $topF = [IntPtr]::Zero
    for ($i = 0; $i -lt 40 -and $topF -eq [IntPtr]::Zero; $i++) {
        $n = @(Get-TestWindows -ProcessId $app.Pid | Where-Object { $tops -notcontains $_.Hwnd }) | Select-Object -First 1
        if ($n) { $topF = [IntPtr]$n.Hwnd } else { Start-Sleep -Milliseconds 150 }
    }
    Assert "the new window is on screen" ($topF -ne [IntPtr]::Zero)
    Assert "...and its sidebar shows the search field (log)" ($null -ne (Wait-Log 'pane sidebar outline mode=expanded.* search=-?\d+,-?\d+ ' $mark 4000))
    if ($topF -ne [IntPtr]::Zero) {
        $sbF = Get-Sidebar $topF
        Assert "the new window has an expanded sidebar ($($sbF.Width))" ($null -ne $sbF -and [math]::Abs($sbF.Width - $panelW) -le 1)
        # Activation is the moment a field could steal it: activate it the
        # way a click or Alt+Tab would, then away and back.
        foreach ($round in 'opened', 'reactivated') {
            if ($round -eq 'reactivated') {
                [void](Set-TestActiveWindow -Window $top)
                Start-Sleep -Milliseconds 400
            }
            [void](Set-TestActiveWindow -Window $topF)
            $cls = ''
            for ($i = 0; $i -lt 30 -and $cls -ne 'GhozttyTerminal'; $i++) {
                Start-Sleep -Milliseconds 100
                $fh = Get-TestFocusedWindow -Window $topF
                $cls = if ($fh -ne [IntPtr]::Zero) { Get-TestWindowClass -Window $fh } else { '' }
                $inF = $fh -ne [IntPtr]::Zero -and $null -ne (Get-TestChildWindows -Window $topF | Where-Object { $_.Hwnd -eq [int64]$fh })
                if (-not $inF) { $cls = '' }
            }
            Assert "${round}: the keyboard is in the new window's terminal (class '$cls')" ($cls -eq 'GhozttyTerminal')
            Assert "${round}: ...and not in its search field" ($null -ne $sbF -and $fh -ne [IntPtr]$sbF.Hwnd)
        }
        Assert "the new window's field never took the keyboard (log)" ($null -eq (Wait-Log 'pane sidebar search focus=true' $mark 300))
        # A click still focuses it, and Escape gives it back.
        $lineF = Wait-Log 'pane sidebar outline mode=expanded.* search=' $mark 1000
        $spF = $null
        if ($lineF -match ' search=(-?\d+),(-?\d+) ') { $spF = @{ X = [int]$Matches[1]; Y = [int]$Matches[2] } }
        $mark = Get-LogCount
        if ($spF -and $sbF) { [void](ClickAt $topF $sbF $spF) }
        Assert "a click in the new window's field still takes the keyboard (log)" ($null -ne (Wait-Log 'pane sidebar search focus=true' $mark 3000))
        if ($sbF) { [void](Send-TestControlKey -Control ([IntPtr]$sbF.Hwnd) -Key Escape) }
    }
    $mark = Get-LogCount
    Assert "+close wF ($(Get-CliErr))" ((Invoke-Cli "+close --target=wF") -eq 0)
    Assert "...and it leaves the list" ($null -ne (Wait-Log 'pane sidebar all-windows groups=3 .*windows=3 ' $mark 6000))
    Assert "setup: window A is the active window again" (Set-TestActiveWindow -Window $top)

    "== 7: collapsed, the rail is one tile per WINDOW, with no divider between them (T2445, Mac 9e2e2902a; T2425)"
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    $railOutline = Wait-Log 'pane sidebar outline mode=mini' $mark
    $o6 = Read-Outline $railOutline
    $sb = Get-Sidebar $top
    Assert "the column is the 76 DIP rail ($($sb.Width))" ([math]::Abs($sb.Width - (Px 76)) -le 1)
    if ($o6) { "  rail items: $(($o6.Items | ForEach-Object { "g$($_.Group)$($_.Sec)" }) -join ' ') rules=$($o6.Rules)" }
    $tileGroups = if ($o6) { @($o6.Items | ForEach-Object { $_.Group } | Sort-Object -Unique) } else { @() }
    Assert "one tile per window (3 tiles for 5 panes in 3 windows, each a different window), no header rows" ($null -ne $o6 -and $o6.Items.Count -eq 3 -and $tileGroups.Count -eq 3 -and $o6.Heads.Count -eq 0)
    Assert "no hairline between the three windows ($($o6.Rules))" ($null -ne $o6 -and $o6.Rules -eq 0)
    $wsel = $null
    if ($railOutline -match ' wtiles=(\d+) wsel=(\S+)') { $wtiles = [int]$Matches[1]; $wsel = $Matches[2] } else { $wtiles = -1 }
    Assert "the log counts them as window tiles (wtiles=$wtiles)" ($wtiles -eq 3)
    Assert "this window's tile is the selected one (wsel=$wsel)" ($null -ne $wsel -and $wsel -ne '-')
    # Its tooltip is the window's full title - one line, no pane hint under it.
    $tipLine = Wait-Log 'pane sidebar tips .* mode=mini tile0=' $mark 2000
    $tile0 = if ($tipLine -match ' tile0=(.*)$') { $Matches[1] } else { $null }
    "  tile0 tip: $tile0"
    Assert "a window tile's tip is its title alone ('$tile0')" ($null -ne $tile0 -and $tile0.Length -gt 0 -and $tile0 -notmatch '\|')
    # Another window's tile raises that window.
    $other = if ($o6) { $o6.Items | Where-Object { "g$($_.Group)" -ne $wsel } | Select-Object -First 1 } else { $null }
    $mark = Get-LogCount
    if ($other) { [void](ClickAt $top $sb @{ X = $other.X; Y = $other.Y }) }
    Assert "clicking another window's tile is a window tile click (log)" ($null -ne (Wait-Log 'pane sidebar window tile click own=false' $mark 2000))
    Assert "...that raises its window (log)" ($null -ne (Wait-Log 'pane sidebar raise window' $mark 2000))
    Assert "...and drags nothing: no row drag started (log)" ($null -eq (Wait-Log 'pane sidebar row drag start' $mark 300))
    Assert "setup: window A is the active window again" (Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 400
    $sb = Get-Sidebar $top

    "== 7b: the rail's + above every window opens a new window (T2407, Mac theAllWindowsRailsPlusOpensAWindow)"
    $railLine = Wait-Log 'pane sidebar outline mode=mini' 0 1000
    $radd = $null
    if ($railLine -match ' radd=(-?\d+),(-?\d+)') { $radd = @{ X = [int]$Matches[1]; Y = [int]$Matches[2] } }
    $firstY = if ($o6 -and $o6.Items.Count -gt 0) { @($o6.Items | ForEach-Object { $_.Y } | Sort-Object)[0] } else { $null }
    Assert "the rail logs a + slot above its first tile (radd=$($radd.X),$($radd.Y), first tile y=$firstY)" ($null -ne $radd -and $null -ne $firstY -and $radd.Y -lt $firstY)
    $tops = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })
    $mark = Get-LogCount
    if ($radd) { [void](ClickAt $top $sb $radd) }
    $topN = [IntPtr]::Zero
    for ($i = 0; $i -lt 40 -and $topN -eq [IntPtr]::Zero; $i++) {
        $n = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { $tops -notcontains $_.Hwnd }) | Select-Object -First 1
        if ($n) { $topN = [IntPtr]$n.Hwnd } else { Start-Sleep -Milliseconds 150 }
    }
    Assert "the rail's + opened a new window, not a pane in this one" ($topN -ne [IntPtr]::Zero)
    Assert "...and the shared list now counts four windows (log)" ($null -ne (Wait-Log 'pane sidebar all-windows groups=4 .*windows=4 ' $mark 6000))
    if ($topN -ne [IntPtr]::Zero) {
        $mark = Get-LogCount
        [void][SidebarSessionPost]::PostMessageW($topN, [uint32]0x0010, [IntPtr]0, [IntPtr]::Zero)
        Assert "setup: the new window closed again (log)" ($null -ne (Wait-Log 'pane sidebar all-windows groups=3 .*windows=3 ' $mark 6000))
    }
    Assert "setup: window A is the active window again" (Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 400
    $sb = Get-Sidebar $top

    "== 8: the toggle switches back to this window's panes"
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top
    $mark = Get-LogCount
    [void](Send-TestControlText -Control ([IntPtr]$sb.Hwnd) -Text 'zeta')
    Assert "re-expanded, a query filters the panel again" ($null -ne (Wait-Log 'pane sidebar all-windows groups=1 .*search=1 .*order=zeta$' $mark))
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    # A frame from inside the slide, for a human to look at (not asserted:
    # where in its 300 ms the capture lands is up to the box).
    try {
        Start-Sleep -Milliseconds 60
        $shot = Get-TestWindowPixels -Window ([IntPtr]$sb.Hwnd) -Sync
        $path = Join-Path $env:TEMP 't1880-scope-midflight.png'
        $shot.Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        Close-TestWindowPixels -Shot $shot
        "  (saved $path)"
    } catch { "  (mid-flight capture failed: $($_.Exception.Message))" }
    Assert "the toggle turned the scope off (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=false' $mark 2000))
    Assert "...sliding back the other way (log)" ($null -ne (Wait-Log 'pane sidebar transition scope surface=rail' $mark 2000))
    # Turning the scope off clears the filter (Mac): back on, nothing is hidden.
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    $g = Wait-Log 'pane sidebar all-windows groups=' $mark
    "  $g"
    Assert "the scope came back with no filter" ($null -ne $g -and $g -match 'groups=3 .*search=0 ')
    Assert "...and the flipped folds forgotten: the other two windows fold again (T1924)" ($null -ne $g -and $g -match ' windows=3 folded=2 ')

    "== 9: with animations off, the switch and the folds just land (T1880)"
    Start-Sleep -Milliseconds 500
    Set-Content -Path $script:seam -Value '1' -NoNewline -Encoding ascii
    $mark = Get-LogCount
    [void][SidebarSessionPost]::PostMessageW($top, [uint32]0x02B1, [IntPtr]0, [IntPtr]::Zero)
    Assert "setup: the effects went off (log)" ($null -ne (Wait-Log 'low-power: visual effects off' $mark 6000))
    Start-Sleep -Milliseconds 800
    $sb = Get-Sidebar $top
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    Assert "the switch still switched (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=false' $mark 2000))
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    Assert "...both ways (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=true' $mark 2000))
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    # zeta's header (this window, a lone window: group 1 since T2421).
    $h = if ($o) { Head $o 'W' 1 } else { $null }
    if ($h) { [void](ClickAt $top $sb $h) }
    Assert "a header still folds (log)" ($null -ne (Wait-Log 'pane sidebar (un)?fold' $mark 2000))
    Assert "...and none of it animated: no transition started" ($null -eq (Wait-Log 'pane sidebar transition' $mark 500))
    Set-Content -Path $script:seam -Value '0' -NoNewline -Encoding ascii
    [void][SidebarSessionPost]::PostMessageW($top, [uint32]0x02B1, [IntPtr]0, [IntPtr]::Zero)

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
        update -Guard pane-sidebar-all-windows -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1829' -Path $transcript `
        -Label 'T1829 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
