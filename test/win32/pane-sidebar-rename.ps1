# T2339 acceptance: renaming in place from the pane sidebar (Mac 379a352ef,
# a13bf6f43). Hovered, a window header, a project header and a terminal
# pane's row each lead their buttons with a pencil; it turns the name into a
# field that opens with its text selected. Return or clicking away keeps what
# was typed, Escape cancels, an unchanged name pins nothing.
#
#   P. Panes (this window's list): a pane with a banner title is renamed - the
#      name outranks the banner, and +list reports it as the pane's title;
#      emptied, the banner's title names it again. A viewer row has no pencil.
#   W. Windows (all-windows scope): typing `proj: three` moves window A into
#      group proj; Return on an unchanged name keeps everything; Escape after
#      typing changes nothing; clicking away keeps what was typed; emptied, A
#      follows its own title again, and a rename after that still pins.
#   G. Project groups: renaming proj to web retitles every window in it;
#      emptied, each window goes back to its own name, ungrouped.
#
# Geometry comes from the sidebar's own log lines: `pane sidebar rows` (this
# window's list: `items=` with each row's pane id) and `pane sidebar outline`
# (all windows), each carrying the pencils - `hr=` per head and `ir=` per shown
# row (`-` where a row has none). Which head is which is read from the groups
# line's `order=`. The field is typed into with posted WM_CHAR / WM_KEYDOWN at
# the column, the way pane-sidebar-all-windows.ps1 drives the search field.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl clicks window A's header name beside its pencil in section
# W1, which raises the window rather than renaming it, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-rename.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2339-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2339')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { (Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

# Every pane `+list --json` reports (anything carrying both `id` and `pid`).
function Get-Panes {
    [void](Invoke-Cli '+list --json')
    $raw = Get-CliOut
    $script:found = @()
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { $script:found += , $o }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($raw | ConvertFrom-Json) } catch { return @() }
    return $script:found
}
function Get-PaneByName([string]$Name) {
    return @(Get-Panes | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}
function Wait-Until([scriptblock]$Cond, [int]$Ms = 5000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        if (& $Cond) { return $true }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

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
function Test-LogSince([string]$Pattern, [int]$Skip) {
    return @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }).Count -gt 0
}

# `X,Y;` points (or `-;` for none) after ` $Key=`, as hashtables or $null.
function Read-Points([string]$Line, [string]$Key) {
    if ($Line -notmatch " $Key=(\S*)") { return @() }
    $out = @()
    foreach ($p in ($Matches[1] -split ';' | Where-Object { $_ })) {
        if ($p -eq '-') { $out += , $null; continue }
        $xy = $p -split ','
        $out += , @{ X = [int]$xy[0]; Y = [int]$xy[1] }
    }
    return $out
}
function Read-Heads([string]$Line) {
    if ($Line -notmatch 'heads=(\S*) items=') { return @() }
    $heads = @()
    foreach ($h in ($Matches[1] -split ';' | Where-Object { $_ })) {
        if ($h -match '^([PW])(\d+)@(-?\d+),(-?\d+)$') { $heads += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    return $heads
}
# The all-windows outline: heads and each head's pencil.
function Get-Outline([int]$Skip) {
    $line = Wait-Log 'pane sidebar outline mode=expanded' $Skip
    if (-not $line) { return $null }
    return @{ Heads = @(Read-Heads $line); Hr = @(Read-Points $line 'hr'); Line = $line }
}
# This window's list: each shown row's pane id and center, and its pencil.
function Get-Rows([int]$Skip) {
    $line = Wait-Log 'pane sidebar rows mode=expanded' $Skip
    if (-not $line) { return $null }
    $rows = @()
    if ($line -match ' items=(\S*)') {
        foreach ($it in ($Matches[1] -split ';' | Where-Object { $_ })) {
            if ($it -match '^g0[gs]@(-?\d+),(-?\d+)#(.+)$') { $rows += , @{ X = [int]$Matches[1]; Y = [int]$Matches[2]; Id = $Matches[3] } }
        }
    }
    return @{ Rows = $rows; Ir = @(Read-Points $line 'ir'); Line = $line }
}
function Get-Order([int]$Skip) {
    $g = Wait-Log 'pane sidebar all-windows groups=' $Skip
    if ($g -notmatch 'order=(.*)$') { return @() }
    return @($Matches[1] -split '\|')
}
function Wait-Order([string]$Want, [int]$Skip, [int]$Ms = 4000) {
    $line = Wait-Log ('pane sidebar all-windows groups=.*order=' + [regex]::Escape($Want) + '$') $Skip $Ms
    return ($null -ne $line)
}
# The head index of window group $Name (an `order=` entry), or -1.
function Find-WindowHead($o, [string[]]$Order, [string]$Name) {
    $gi = [array]::IndexOf($Order, $Name)
    if ($null -eq $o -or $gi -lt 0) { return -1 }
    for ($j = 0; $j -lt $o.Heads.Count; $j++) { if ($o.Heads[$j].Kind -eq 'W' -and $o.Heads[$j].Group -eq $gi) { return $j } }
    return -1
}
function Find-ProjectHead($o) {
    if ($null -eq $o) { return -1 }
    for ($j = 0; $j -lt $o.Heads.Count; $j++) { if ($o.Heads[$j].Kind -eq 'P') { return $j } }
    return -1
}
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 44; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
}
function Get-ScopeCenter($sb) {
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = (Get-ToggleCenter $sb).Y }
}
function Type-Field($sb, [string]$Text) { [void](Send-TestControlText -Control ([IntPtr]$sb.Hwnd) -Text $Text) }
function Key-Field($sb, [string]$Key) { [void](Send-TestControlKey -Control ([IntPtr]$sb.Hwnd) -Key $Key) }

# Open window group $Name's field from its header's pencil; true when the
# app logged the field opening on $Text.
function Open-WindowField($top, $sb, [string]$Name, [string]$Text) {
    $o = Get-Outline 0
    $order = Get-Order 0
    $k = Find-WindowHead $o $order $Name
    if ($k -lt 0 -or $k -ge $o.Hr.Count) { return $false }
    $mark = Get-LogCount
    [void](ClickAt $top $sb $o.Hr[$k])
    return ($null -ne (Wait-Log ('pane sidebar rename begin kind=window text=' + [regex]::Escape($Text) + '$') $mark 3000))
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2339'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0
$viewFile = Join-Path $tmp 'notes.md'
Set-Content -Path $viewFile -Value "# Notes`n`nA viewer is named by its page." -Encoding ascii

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

    Assert "setup: window A renamed zeta ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=zeta") -eq 0)
    Assert "setup: A split, a2 ($(Get-CliErr))" ((Invoke-Cli "+split --target=window-1 --direction=right --name=a2") -eq 0)
    Start-Sleep -Milliseconds 1000
    Assert "setup: wB opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1 --title=`"proj: one`"") -eq 0)
    Start-Sleep -Milliseconds 1200
    Assert "setup: wC opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wC --name=c1 --title=`"proj: two`"") -eq 0)
    Start-Sleep -Milliseconds 1200
    [void](Set-TestActiveWindow -Window $top)

    $sb = Get-Sidebar $top
    Assert "A has a sidebar" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top

    "== P: a terminal pane renamed in place outranks its banner title; a viewer has no pencil"
    $a2 = Get-PaneByName 'a2'
    Assert "a2 is listed by +list" ($null -ne $a2)
    if ($null -eq $a2) { return }
    $a2id = [string]$a2.id
    $mark = Get-LogCount
    Assert "setup: a2 gets a titled banner ($(Get-CliErr))" ((Invoke-Cli "+set-banner --target=a2 `"**Build box**`"") -eq 0)
    Assert "the banner's title names a2's row (log)" ($null -ne (Wait-Log ('pane sidebar text.*#' + [regex]::Escape($a2id) + ' title=Build box ') $mark))
    $r = Get-Rows 0
    $ri = -1
    if ($r) { for ($j = 0; $j -lt $r.Rows.Count; $j++) { if ($r.Rows[$j].Id -eq $a2id) { $ri = $j } } }
    Assert "this window's list logs a pencil for every row, a2's among them ($($r.Line))" ($null -ne $r -and $ri -ge 0 -and $r.Ir.Count -eq $r.Rows.Count -and $null -ne $r.Ir[$ri])
    if ($ri -lt 0 -or $null -eq $r.Ir[$ri]) { return }
    $pencil = $r.Ir[$ri]
    Assert "the pencil sits on a2's row, toward its trailing edge" ([math]::Abs($pencil.Y - $r.Rows[$ri].Y) -le 2 -and $pencil.X -gt $r.Rows[$ri].X)

    $mark = Get-LogCount
    [void](ClickAt $top $sb $pencil)
    Assert "the pencil opens the field on the row's name, selected (log)" ($null -ne (Wait-Log 'pane sidebar rename begin kind=pane text=Build box$' $mark 3000))
    Assert "...and gives it the keyboard (log)" ($null -ne (Wait-Log 'pane sidebar rename focus=true' $mark 3000))
    Type-Field $sb 'my pane'
    $mark = Get-LogCount
    Key-Field $sb 'Enter'
    Assert "Return keeps the name; typing replaced the selection (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=return kind=pane outcome=set text=my pane$' $mark 3000))
    Assert "the name outranks the banner's title on a2's row (log)" ($null -ne (Wait-Log ('pane sidebar text.*#' + [regex]::Escape($a2id) + ' title=my pane ') $mark))
    $a2 = Get-PaneByName 'a2'
    Assert "+list reports it as a2's title (got '$($a2.title)')" ($null -ne $a2 -and $a2.title -eq 'my pane')

    $mark = Get-LogCount
    [void](ClickAt $top $sb $pencil)
    Assert "the pencil opens on the new name (log)" ($null -ne (Wait-Log 'pane sidebar rename begin kind=pane text=my pane$' $mark 3000))
    Key-Field $sb 'Backspace'
    $mark = Get-LogCount
    Key-Field $sb 'Enter'
    Assert "Backspace on the selection empties it, and empty clears the name (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=return kind=pane outcome=clear text=$' $mark 3000))
    Assert "...so the banner's title names a2 again (log)" ($null -ne (Wait-Log ('pane sidebar text.*#' + [regex]::Escape($a2id) + ' title=Build box ') $mark))

    $mark = Get-LogCount
    Assert "setup: a viewer beside a2 ($(Get-CliErr))" ((Invoke-Cli "+split --target=a2 --direction=down `"--view=$viewFile`"") -eq 0)
    $r = $null
    $ok = Wait-Until { $script:rv = Get-Rows $mark; $null -ne $script:rv -and $script:rv.Rows.Count -eq 3 } 6000
    $r = $script:rv
    $none = @($r.Ir | Where-Object { $null -eq $_ }).Count
    Assert "three rows now, and exactly one - the viewer's - has no pencil ($($r.Line))" ($ok -and $r.Ir.Count -eq 3 -and $none -eq 1)

    # The all-windows scope for the headers.
    [void](Set-TestActiveWindow -Window $top)
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    Assert "the all-windows scope is on (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=true' $mark))
    $order = Get-Order $mark
    Assert "three windows in name order, the lone window first (T2421): zeta | proj/one | proj/two ($($order -join '|'))" (($order -join '|') -eq 'zeta|proj/one|proj/two')
    $o = Get-Outline $mark
    Assert "the outline logs a pencil for every head ($($o.Line))" ($null -ne $o -and $o.Heads.Count -eq 4 -and $o.Hr.Count -eq 4)

    "== W1: a window's field holds its whole title - typing a project moves it into that group"
    $k = Find-WindowHead $o $order 'zeta'
    Assert "zeta has a window head" ($k -ge 0)
    $mark = Get-LogCount
    if ($k -ge 0) {
        $pt = $o.Hr[$k]
        if ($NegativeControl) {
            "  NEGATIVE CONTROL: clicking zeta's name beside its pencil - this run MUST fail"
            $pt = @{ X = $o.Hr[$k].X - (Px 60); Y = $o.Hr[$k].Y }
        }
        [void](ClickAt $top $sb $pt)
    }
    Assert "the window's pencil opens the field on its title (log)" ($null -ne (Wait-Log 'pane sidebar rename begin kind=window text=zeta$' $mark 3000))
    Type-Field $sb 'proj: three'
    $mark = Get-LogCount
    Key-Field $sb 'Enter'
    Assert "Return pins the typed title (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=return kind=window outcome=set text=proj: three$' $mark 3000))
    Assert "A moved into proj as three, at the edge nearest where it was (above it, T2421) - nothing re-sorts by name (T2405): proj/three | proj/one | proj/two" (Wait-Order 'proj/three|proj/one|proj/two' $mark)

    "== W2: Return on an unchanged name pins nothing"
    Assert "the field opens on proj: three" (Open-WindowField $top $sb 'proj/three' 'proj: three')
    $mark = Get-LogCount
    Key-Field $sb 'Enter'
    Assert "unchanged: kept as it was (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=return kind=window outcome=keep ' $mark 3000))
    Assert "the order did not move" (((Get-Order 0) -join '|') -eq 'proj/three|proj/one|proj/two')

    "== W3: Escape after typing changes nothing"
    Assert "the field opens on proj: one" (Open-WindowField $top $sb 'proj/one' 'proj: one')
    Type-Field $sb 'zzz'
    $mark = Get-LogCount
    Key-Field $sb 'Escape'
    Assert "Escape cancels (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=escape kind=window outcome=keep text=zzz$' $mark 3000))
    Start-Sleep -Milliseconds 400
    Assert "nothing was renamed" (-not (Test-LogSince 'order=.*zzz' $mark) -and ((Get-Order 0) -join '|') -eq 'proj/three|proj/one|proj/two')

    "== G1: a group's field holds the project; each of its windows takes the new name"
    $o = Get-Outline 0
    $k = Find-ProjectHead $o
    Assert "the project head is listed, with a pencil" ($k -ge 0 -and $k -lt $o.Hr.Count)
    $mark = Get-LogCount
    if ($k -ge 0) { [void](ClickAt $top $sb $o.Hr[$k]) }
    Assert "the group's pencil opens on the project as its titles spell it (log)" ($null -ne (Wait-Log 'pane sidebar rename begin kind=project text=proj$' $mark 3000))
    Type-Field $sb 'web'
    $mark = Get-LogCount
    Key-Field $sb 'Enter'
    Assert "Return renames the group (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=return kind=project outcome=set text=web$' $mark 3000))
    Assert "every window in it is retitled, in its place: web/three | web/one | web/two" (Wait-Order 'web/three|web/one|web/two' $mark)

    "== G2: an emptied group's windows each go back to their own names"
    $o = Get-Outline 0
    $k = Find-ProjectHead $o
    $mark = Get-LogCount
    if ($k -ge 0) { [void](ClickAt $top $sb $o.Hr[$k]) }
    Assert "the field opens on web (log)" ($null -ne (Wait-Log 'pane sidebar rename begin kind=project text=web$' $mark 3000))
    Key-Field $sb 'Backspace'
    $mark = Get-LogCount
    Key-Field $sb 'Enter'
    Assert "empty clears the group (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=return kind=project outcome=clear ' $mark 3000))
    Assert "ungrouped, each by its own name where the group was, in its order: three | one | two" (Wait-Order 'three|one|two' $mark)
    $o = Get-Outline 0
    Assert "...and no project head is left" ($null -ne $o -and (Find-ProjectHead $o) -lt 0)

    "== W4: clicking away keeps what was typed"
    Assert "the field opens on one" (Open-WindowField $top $sb 'one' 'one')
    Type-Field $sb 'alpha'
    $o = Get-Outline 0
    $sp = $null
    if ($o.Line -match ' search=(-?\d+),(-?\d+) ') { $sp = @{ X = [int]$Matches[1]; Y = [int]$Matches[2] } }
    $mark = Get-LogCount
    if ($sp) { [void](ClickAt $top $sb $sp) }
    Assert "a click elsewhere in the column keeps the name (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=click kind=window outcome=set text=alpha$' $mark 3000))
    Assert "...so the window is alpha, in its place: three | alpha | two" (Wait-Order 'three|alpha|two' $mark)

    "== W5: emptied, a window follows its own title; renamed again, it pins"
    Assert "the field opens on three (window A)" (Open-WindowField $top $sb 'three' 'three')
    Key-Field $sb 'Backspace'
    $mark = Get-LogCount
    Key-Field $sb 'Enter'
    Assert "empty clears the window's name (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=return kind=window outcome=clear ' $mark 3000))
    $own = $null
    Assert "A follows its own title: three is gone, three windows still listed" (Wait-Until {
            $ord = @(Get-Order 0)
            $script:ownName = @($ord | Where-Object { $_ -ne 'alpha' -and $_ -ne 'two' }) | Select-Object -First 1
            $ord.Count -eq 3 -and ($ord -notcontains 'three') -and $script:ownName
        } 5000)
    $own = $script:ownName
    "  (A's own title: '$own')"
    if ($own) {
        Assert "the field opens on A's own title" (Open-WindowField $top $sb $own $own)
        Type-Field $sb 'solo'
        $mark = Get-LogCount
        Key-Field $sb 'Enter'
        Assert "Return pins solo (log)" ($null -ne (Wait-Log 'pane sidebar rename end why=return kind=window outcome=set text=solo$' $mark 3000))
        Assert "A is solo, still first - by name it would sort between alpha and two (T2405): solo | alpha | two" (Wait-Order 'solo|alpha|two' $mark)
    }

    "== W6: Change Window Title renames the same way - nothing moves (T2405, Mac renameWindowKeepingPlace)"
    # A window the order has never placed: listed beside its name neighbour
    # (alpha), so only a pin keeps it there once it is renamed past two.
    $before = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })
    $mark = Get-LogCount
    Assert "setup: wD opened as m ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wD --name=d1 --title=m") -eq 0)
    Assert "wD shows beside its name neighbour: solo | alpha | m | two" (Wait-Order 'solo|alpha|m|two' $mark 6000)
    $dTop = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { $before -notcontains $_.Hwnd }) | Select-Object -First 1
    Assert "wD's window is found" ($null -ne $dTop)
    if ($null -eq $dTop) { return }
    $dHwnd = [IntPtr]$dTop.Hwnd
    $surface = Get-TestChildWindow -Window $dHwnd -Class 'GhozttyTerminal'
    Assert "wD's terminal is found" ($surface -ne [IntPtr]::Zero)
    $mark = Get-LogCount
    Assert "ctrl+shift+r delivered to wD" (Send-TestKeys -Window $dHwnd -Target $surface -Modifiers ctrl, shift -Key R)
    $dlg = [IntPtr]::Zero
    $null = Wait-Until { $script:dlg = Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyRenameDialog'; $script:dlg -ne [IntPtr]::Zero } 5000
    $dlg = $script:dlg
    Assert "the Change Window Title dialog opens" ($dlg -ne [IntPtr]::Zero)
    if ($dlg -ne [IntPtr]::Zero) {
        $edit = Find-TestWindowEx -Parent $dlg -Class 'EDIT'
        [void](Set-TestControlText -Control $edit -Text 'zzz')
        [void](Send-TestControlKey -Control $edit -Key Enter)
        Assert "the dialog pinned the order as shown (log)" ($null -ne (Wait-Log 'pane sidebar window order pinned as shown by Change Window Title' $mark 4000))
        # By name zzz would follow two: alpha | solo | two | zzz.
        Assert "wD is zzz, in its place (T2405): solo | alpha | zzz | two" (Wait-Order 'solo|alpha|zzz|two' $mark)
    }

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
if ($script:failures -gt 0 -and $script:errlog -and (Test-Path $script:errlog)) {
    $keep = Join-Path $env:TEMP 't2339-app-stderr.log'
    Copy-Item $script:errlog $keep -Force
    "  (app log kept: $keep)"
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-rename -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2339' -Path $transcript `
        -Label 'T2339 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
