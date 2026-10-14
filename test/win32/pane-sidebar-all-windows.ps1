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
#   1. The pin, then the all-windows toggle: the roster becomes four groups in
#      name order - Build logs, then the ghoztty project (feature-2, main),
#      then zeta - with one project head and four window heads, every pane
#      listed (B's stashed one too), and a hairline before zeta and before
#      B's stash. The panel paints content.
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
#   7. Unpinned, the rail shows every pane as a tile with a hairline between
#      windows and no header rows.
#   8. The toggle switches back to this window's panes only, and clears a
#      query: back on, every window is listed (T1877).
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
    $o = @{ Mode = $Matches[1]; Rules = [int]$Matches[4]; Scope = @{ X = [int]$Matches[5]; Y = [int]$Matches[6] }; Heads = @(); Items = @() }
    $headsRaw = $Matches[2]; $itemsRaw = $Matches[3]
    foreach ($h in ($headsRaw -split ';' | Where-Object { $_ })) {
        if ($h -match '^([PW])(\d+)@(-?\d+),(-?\d+)$') { $o.Heads += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    foreach ($i in ($itemsRaw -split ';' | Where-Object { $_ })) {
        if ($i -match '^g(\d+)([gs])@(-?\d+),(-?\d+)$') { $o.Items += , @{ Group = [int]$Matches[1]; Sec = $Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    return $o
}
function Head($o, [string]$Kind, [int]$Group) { $o.Heads | Where-Object { $_.Kind -eq $Kind -and $_.Group -eq $Group } | Select-Object -First 1 }
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
function Get-PinCenter($sb, [string]$Mode) {
    if ($Mode -eq 'mini') {
        $margin = Px 12; $card = Px 44; $tile = Px 28
        $inset = [int][math]::Truncate(($card - $tile) / 2)
        return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
    }
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = Px 18 }
}
# The all-windows toggle: the 28 DIP button 2 DIP left of the pin.
function Get-ScopeCenter($sb) {
    # Mac's header order, trailing edge first: pin, trash (T1845), then this
    # toggle - two 28 DIP buttons and two 2 DIP gaps in from the pin's sm inset.
    return @{ X = $sb.Width - (Px 4) - 2 * ((Px 28) + (Px 2)) - [int]((Px 28) / 2); Y = Px 18 }
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
    [void](ClickAt $top $sb (Get-PinCenter $sb 'mini'))
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top
    Assert "pinned: the 240 DIP panel ($($sb.Width))" ([math]::Abs($sb.Width - (Px 240)) -le 1)
    $mark = Get-LogCount
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: the toggle is never clicked - this run MUST fail"
    } else {
        Assert "toggle click delivered" (ClickAt $top $sb (Get-ScopeCenter $sb))
    }
    $scopeLine = Wait-Log 'pane sidebar scope all_windows=true' $mark
    Assert "the toggle turned the all-windows scope on (log)" ($null -ne $scopeLine)
    $groups = Wait-Log 'pane sidebar all-windows groups=' $mark
    "  $groups"
    Assert "four groups, every pane" ($groups -match 'groups=4 panes=6 ')
    Assert "name order, the project grouped: Build logs | ghoztty/feature-2 | ghoztty/main | zeta" ($groups -match 'order=Build logs\|ghoztty/feature-2\|ghoztty/main\|zeta$')
    # T1924 (Mac 321e61d7c): the caption counts the windows, and every window
    # but this one opens folded.
    Assert "the ALL WINDOWS caption counts four windows" ($groups -match ' windows=4 ')
    Assert "every other window opens folded, this one open (folded=3)" ($groups -match ' folded=3 ')
    $o0 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "folded by default: only zeta's two rows show, under four window heads" ($null -ne $o0 -and $o0.Items.Count -eq 2 -and @($o0.Items | Where-Object Group -ne 3).Count -eq 0 -and @($o0.Heads | Where-Object Kind -eq 'W').Count -eq 4)
    # A chevron unfolds another window without raising it.
    $chevLine = Wait-Log 'pane sidebar outline mode=expanded' $mark
    $chev = @()
    if ($chevLine -match ' chev=(\S*)') { $chev = @($Matches[1] -split ';' | Where-Object { $_ } | ForEach-Object { $xy = $_ -split ','; @{ X = [int]$xy[0]; Y = [int]$xy[1] } }) }
    Assert "each head logs its chevron ($($chev.Count) for $($o0.Heads.Count))" ($null -ne $o0 -and $chev.Count -eq $o0.Heads.Count)
    foreach ($gi in 0, 1, 2) {
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
    Assert "the project head names its first window (group 1)" ($null -ne (Head $o 'P' 1))
    Assert "every pane is a row, B's stash included" ($o.Items.Count -eq 6 -and @($o.Items | Where-Object { $_.Group -eq 2 -and $_.Sec -eq 's' }).Count -eq 1)
    Assert "two hairlines: before zeta, and before B's stash ($($o.Rules))" ($o.Rules -eq 2)
    $ordered = $true
    for ($k = 1; $k -lt $o.Heads.Count; $k++) { if ($o.Heads[$k].Y -le $o.Heads[$k - 1].Y) { $ordered = $false } }
    Assert "heads stack top to bottom in outline order" $ordered
    $zeta = Head $o 'W' 3
    $zetaRows = @($o.Items | Where-Object Group -eq 3)
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
    $row = $o.Items | Where-Object { $_.Group -eq 2 -and $_.Sec -eq 's' } | Select-Object -First 1
    $mark = Get-LogCount
    if ($row) { [void](ClickAt $top $sb $row) }
    Assert "b2 was restored by the click" (Wait-Stashed 'b2' $false)
    Assert "it went through the other-window path (log)" ($null -ne (Wait-Log 'pane sidebar focus other window section=stashed' $mark 2000))
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "A's list followed: B's stash is gone, both its panes are grid rows" ($null -ne $o -and @($o.Items | Where-Object { $_.Group -eq 2 -and $_.Sec -eq 'g' }).Count -eq 2)

    "== 3: another window's header raises that window"
    $mark = Get-LogCount
    $h = Head $o 'W' 0
    if ($h) { [void](ClickAt $top $sb $h) }
    Assert "clicking Build logs' header raised it (log)" ($null -ne (Wait-Log 'pane sidebar raise window' $mark 2000))

    "== 4: this window's header folds its panes, and unfolds them"
    $mark = Get-LogCount
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' 0 1000)
    $h = Head $o 'W' 3
    if ($h) { [void](ClickAt $top $sb $h) }
    $o2 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "folded: zeta's rows are gone, its header stays" ($null -ne $o2 -and @($o2.Items | Where-Object Group -eq 3).Count -eq 0 -and $null -ne (Head $o2 'W' 3))
    $mark = Get-LogCount
    $h = Head $o2 'W' 3
    if ($h) { [void](ClickAt $top $sb $h) }
    $o3 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "unfolded: zeta's two rows are back" ($null -ne $o3 -and @($o3.Items | Where-Object Group -eq 3).Count -eq 2)

    "== 5: the project header folds its windows, and unfolds them"
    $mark = Get-LogCount
    $h = Head $o3 'P' 1
    if ($h) { [void](ClickAt $top $sb $h) }
    $o4 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "folded: the project's window heads and rows are gone" ($null -ne $o4 -and $null -eq (Head $o4 'W' 1) -and $null -eq (Head $o4 'W' 2) -and @($o4.Items | Where-Object { $_.Group -in 1, 2 }).Count -eq 0)
    Assert "folded: the project head itself stays" ($null -ne $o4 -and $null -ne (Head $o4 'P' 1))
    $mark = Get-LogCount
    $h = Head $o4 'P' 1
    if ($h) { [void](ClickAt $top $sb $h) }
    $o5 = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "unfolded: both windows are back" ($null -ne $o5 -and $null -ne (Head $o5 'W' 1) -and $null -ne (Head $o5 'W' 2))

    "== 6: the list follows other windows: a rename re-sorts, a close drops"
    $mark = Get-LogCount
    Assert "+rename wB alpha ($(Get-CliErr))" ((Invoke-Cli "+rename --target=wB --title=alpha") -eq 0)
    $g = Wait-Log 'pane sidebar all-windows groups=4.*order=alpha\|' $mark
    "  $g"
    Assert "renamed B sorts first, out of the project" ($g -match 'order=alpha\|Build logs\|ghoztty/feature-2\|zeta$')
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
    Assert "closing D dropped it from A's list" ($g -match 'order=alpha\|ghoztty/feature-2\|zeta$')

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

    "== 7: unpinned, the rail shows every pane with a hairline between windows"
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-PinCenter $sb 'expanded'))
    $o6 = Read-Outline (Wait-Log 'pane sidebar outline mode=mini' $mark)
    $sb = Get-Sidebar $top
    Assert "the column is the 68 DIP rail ($($sb.Width))" ([math]::Abs($sb.Width - (Px 68)) -le 1)
    if ($o6) { "  rail items: $(($o6.Items | ForEach-Object { "g$($_.Group)$($_.Sec)" }) -join ' ') rules=$($o6.Rules)" }
    Assert "every pane is a tile (5) and there are no header rows" ($null -ne $o6 -and $o6.Items.Count -eq 5 -and $o6.Heads.Count -eq 0)
    Assert "two hairlines between the three windows ($($o6.Rules))" ($null -ne $o6 -and $o6.Rules -eq 2)

    "== 7b: the open card carries the field, and stays open while it has the caret (T1877)"
    Start-Sleep -Milliseconds 900   # section 7's card has contracted
    $o7 = Wait-Log 'pane sidebar card open reason=unpin' 0 1000
    $fx = $null; $fy = $null
    if ($o7 -match 'search=(-?\d+),(-?\d+),(-?\d+),(-?\d+)') {
        $fx = [int](([int]$Matches[1] + [int]$Matches[3]) / 2); $fy = [int](([int]$Matches[2] + [int]$Matches[4]) / 2)
        Assert "the open card lays out a search field ($($Matches[1])..$($Matches[3]))" ([int]$Matches[3] -gt [int]$Matches[1])
    } else { Assert "the open card logged its search field" $false }
    [void](ClickAt $top $sb (Get-PinCenter $sb 'mini'))   # pin
    Start-Sleep -Milliseconds 600
    $sb = Get-Sidebar $top
    Assert "setup: window A is active for the card's click" (Set-TestActiveWindow -Window $top)
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-PinCenter $sb 'expanded'))   # unpin: the card opens
    # The click in its field must beat the 280 ms grace period the open
    # started, so it is the very next thing (pane-sidebar.ps1 7b's shape).
    $card = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyPaneSidebarCard'
    $clicked = $false
    if ($card -ne [IntPtr]::Zero -and $null -ne $fx) {
        $cr = Get-TestWindowRect -Window $card
        $clicked = Send-TestMouse -Window $top -Target $card -X ($cr.Left + $fx) -Y ($cr.Top + $fy) -Action click
    }
    Assert "the click reached the open card's field" $clicked
    Assert "...and the column took the keyboard for it (log)" ($null -ne (Wait-Log 'pane sidebar search focus=true' $mark 2000))
    Start-Sleep -Milliseconds 900
    $closedEarly = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $mark | Where-Object { $_ -match 'pane sidebar card close' }).Count
    Assert "with the caret in its field the card did not contract in 3x the grace period ($closedEarly)" ($closedEarly -eq 0)
    $mark = Get-LogCount
    [void](Send-TestControlText -Control ([IntPtr]$sb.Hwnd) -Text 'zeta')
    Assert "the card's field filters its outline" ($null -ne (Wait-Log 'pane sidebar all-windows groups=1 .*search=1 .*order=zeta$' $mark))
    [void](Send-TestControlKey -Control ([IntPtr]$sb.Hwnd) -Key Escape)   # clears
    [void](Send-TestControlKey -Control ([IntPtr]$sb.Hwnd) -Key Escape)   # gives the caret back
    $closeLine = Wait-Log 'pane sidebar card close reason=left' $mark 3000
    Assert "with the caret given back, the card contracted (log)" ($null -ne $closeLine)
    $g = Wait-Log 'pane sidebar all-windows groups=' $mark
    Assert "...and the rail lists every pane again" ($null -ne $g -and $g -match 'search=0 ')

    "== 8: the toggle switches back to this window's panes"
    Start-Sleep -Milliseconds 900   # let the unpin's open card contract
    [void](ClickAt $top $sb (Get-PinCenter $sb 'mini'))
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top
    $mark = Get-LogCount
    [void](Send-TestControlText -Control ([IntPtr]$sb.Hwnd) -Text 'zeta')
    Assert "re-pinned, a query filters the panel again" ($null -ne (Wait-Log 'pane sidebar all-windows groups=1 .*search=1 .*order=zeta$' $mark))
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    Assert "the toggle turned the scope off (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=false' $mark 2000))
    # Turning the scope off clears the filter (Mac): back on, nothing is hidden.
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    $g = Wait-Log 'pane sidebar all-windows groups=' $mark
    "  $g"
    Assert "the scope came back with no filter" ($null -ne $g -and $g -match 'groups=3 .*search=0 ')
    Assert "...and the flipped folds forgotten: the other two windows fold again (T1924)" ($null -ne $g -and $g -match ' windows=3 folded=2 ')

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
