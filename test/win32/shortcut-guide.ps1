# T2591 acceptance: the keyboard shortcut guide - Mac's searchable window of
# the EFFECTIVE keybindings (docs/reference/keyboard-shortcuts.md) - exists on
# Windows, lists the live config's bindings with plain names, marks what the
# user customized, searches by word and by key combo in any modifier order,
# filters by category, toggles unbound actions, runs a safe action in the
# terminal window, writes a printable cheat sheet, and closes the Mac way.
#
# THE ORACLE IS THE MODEL. Which bindings are live, which were customized and
# what a key-combo search finds are decisions, invisible in pixels, so they are
# read through the debug-only `shortcut-guide` IPC action
# (src/apprt/win32/ipc_shortcut_guide.zig), which reports the same rows the
# window paints. The WINDOW is structural: one top-level GhozttyShortcutGuide
# titled "Keyboard Shortcuts", however many times it is asked for.
#
# THE CONFIG IS DRIVEN, NOT OBSERVED: --config-default-files=false plus two
# --keybind flags make "added a binding" and "unbound a default" reachable
# states rather than whatever this box's config happens to say.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never
# steals the user's foreground. The cheat sheet op WRITES the file and never
# opens a browser.
#
# -NegativeControl inverts a load-bearing claim (the user's added binding is
# reported as customized) - that run MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-shortcuts$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-Guide([string[]]$ipcArgs) {
    return Invoke-GhozttyIpc -Action 'shortcut-guide' -Arguments $ipcArgs
}

function Find-Row($state, [string]$id) {
    foreach ($r in @($state.data.rows)) { if ([string]$r.id -eq $id) { return $r } }
    return $null
}

function Get-PaneCount {
    $resp = Invoke-GhozttyIpc -Action 'list'
    if ($null -eq $resp -or -not $resp.success) { return -1 }
    $script:paneCount = 0
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { $script:paneCount++ }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    & $walk $resp.data
    return $script:paneCount
}

# The "Show unbound actions" preference is this debug build's own file; back
# it up so the run leaves the box's preference exactly as it found it.
$prefPath = Join-Path $env:LOCALAPPDATA 'ghoztty\shortcut-guide-unbound-debug'
$prefExisted = Test-Path $prefPath
$prefBackup = $null
if ($prefExisted) { $prefBackup = [System.IO.File]::ReadAllText($prefPath) }
Remove-Item $prefPath -Force -ErrorAction SilentlyContinue

$errlog = Join-Path $env:TEMP 'ghoztty-shortcut-guide-stderr.log'
$script:launched = @()
$app = $null

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: section B asserts the user's added binding is NOT customized - this run MUST fail"
    }
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $sp = @{
        Exe       = $exe
        Arguments = @(
            '--config-default-files=false', '--session-persistence=false', '--background=#101014',
            # An ADDED binding (new_tab keeps its defaults too) ...
            '--keybind=ctrl+alt+z=new_tab',
            # ... and a default UNBOUND outright (Ctrl+Shift+S is the only
            # default for the pane sidebar toggle on Windows).
            '--keybind=ctrl+shift+s=unbind'
        )
    }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if (-not $app -or ($app.Process -and $app.Process.HasExited)) {
        Write-TestAssertedNothing -Reason 'GUI did not come up' -Label 'shortcut-guide'
        exit 1
    }
    $script:launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'no terminal window appeared' -Label 'shortcut-guide'
        exit 1
    }

    # =====================================================================
    # A: the window - one per process, Mac's title.
    # =====================================================================
    $closed = Invoke-Guide @('--op=state')
    Assert ($null -ne $closed -and -not $closed.success) 'A: asking for state with no guide open is refused, not a silent open'

    $s = Invoke-Guide @('--op=open')
    if ($null -eq $s -or -not $s.success) {
        Write-TestAssertedNothing -Reason 'the shortcut-guide IPC action never answered' -Label 'shortcut-guide'
        exit 1
    }
    Assert ([bool]$s.data.open) 'A: the guide reports itself open'
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyShortcutGuide')
    Assert ($wins.Count -eq 1) "A: exactly one guide window exists ($($wins.Count))"
    if ($wins.Count -ge 1) {
        $title = Get-TestWindowText -Window ([IntPtr]$wins[0].Hwnd)
        Assert ($title -eq 'Keyboard Shortcuts') "A: the window carries Mac's title (got '$title')"
        Assert ($wins[0].Visible) 'A: the window is visible'
    }
    [void](Invoke-Guide @('--op=open'))
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyShortcutGuide')
    Assert ($wins.Count -eq 1) "A: asking twice does not stack a second window ($($wins.Count))"

    # =====================================================================
    # B: the rows are the LIVE config, compared against the defaults.
    # =====================================================================
    $s = Invoke-Guide @('--op=state')
    Assert ([int]$s.data.bound -gt 20) "B: the live config's bindings are listed ($($s.data.bound) shortcuts)"

    $guide = Find-Row $s 'show_keyboard_shortcuts'
    Assert ($null -ne $guide) 'B: the guide lists its own opener'
    if ($guide) {
        $keys = @($guide.keys)
        Assert ($keys -contains 'Ctrl+Shift+/') "B: the guide opens with Ctrl+Shift+/ on Windows (keys: $($keys -join ', '))"
        Assert (-not [bool]$guide.customized) 'B: an untouched default is not customized'
    }

    $tab = Find-Row $s 'new_tab'
    Assert ($null -ne $tab) 'B: new_tab is listed'
    if ($tab) {
        $keys = @($tab.keys)
        Assert ($keys -contains 'Ctrl+Alt+Z') "B: the user's added chord is on the row (keys: $($keys -join ', '))"
        Assert ($keys -contains 'Ctrl+T') "B: the defaults it kept are still on the row (keys: $($keys -join ', '))"
        $script:negReached = $true
        $wantCustom = -not $NegativeControl
        Assert ([bool]$tab.customized -eq $wantCustom) "B: an added binding marks the row CUSTOM (customized=$($tab.customized))"
        Assert ([bool]$tab.runnable) 'B: New Tab is offered to run'
        Assert ([string]$tab.title -eq 'New Tab') "B: the row has its plain-language title (got '$($tab.title)')"
    }

    $side = Find-Row $s 'toggle_pane_sidebar'
    Assert ($null -ne $side) 'B: a default the config unbound is still listed (without Show unbound)'
    if ($side) {
        Assert ([bool]$side.unbound_by_user) 'B: ...as unbound in your config'
        Assert ([bool]$side.customized) 'B: ...and marked CUSTOM'
        Assert (@($side.keys).Count -eq 0) "B: ...with no keys (got $(@($side.keys) -join ', '))"
    }
    Assert ([int]$s.data.customized -ge 2) "B: the footer counts the customized actions ($($s.data.customized))"

    $fam = @(@($s.data.rows) | Where-Object { [string]$_.kind -eq 'family' })
    Assert ($fam.Count -ge 1) "B: same-modifier runs collapse into family rows ($($fam.Count): $(@($fam | ForEach-Object { $_.title + ' ' + (@($_.keys) -join '/') }) -join '; '))"
    $builtin = @(@($s.data.rows) | Where-Object { [string]$_.kind -eq 'built_in' })
    Assert ($builtin.Count -ge 5) "B: built-in viewer and rearrange keys are listed ($($builtin.Count))"
    $other = @(@($s.data.rows) | Where-Object { [string]$_.category -eq 'other' })
    Assert ($other.Count -eq 0) "B: every live action has a curated description (Other: $(@($other | ForEach-Object { $_.id }) -join ', '))"

    # Categories run in Mac's order and never go backwards.
    $catOrder = @('windows', 'panes', 'hero', 'sidebar', 'viewer', 'text', 'scrolling', 'font', 'app', 'advanced', 'other')
    $prev = -1; $ordered = $true
    foreach ($r in @($s.data.rows)) {
        $i = [array]::IndexOf($catOrder, [string]$r.category)
        if ($i -lt $prev) { $ordered = $false }
        $prev = $i
    }
    Assert $ordered 'B: rows are grouped by category in Mac order'

    # =====================================================================
    # C: search - words, key combos in any modifier order, bare keys.
    # =====================================================================
    foreach ($q in @('ctrl shift p', 'Shift+Ctrl+P', 'ctrl+shift+p')) {
        $s = Invoke-Guide @('--op=state', "--query=$q")
        $hit = Find-Row $s 'toggle_command_palette'
        Assert ($null -ne $hit) "C: '$q' finds the command palette ($(@($s.data.rows).Count) rows)"
    }
    $s = Invoke-Guide @('--op=state', '--query=f11')
    Assert ($null -ne (Find-Row $s 'toggle_fullscreen')) 'C: a bare key (F11) finds Toggle Full Screen'
    $s = Invoke-Guide @('--op=state', '--query=esc')
    $esc = @(@($s.data.rows) | Where-Object { [string]$_.title -eq 'Leave Rearrange Mode' })
    Assert ($esc.Count -eq 1) "C: 'esc' finds the built-in rearrange exit"
    $s = Invoke-Guide @('--op=state', '--query=split')
    Assert (@($s.data.rows).Count -ge 2) "C: a word search finds the split actions ($(@($s.data.rows).Count))"
    Assert ($null -ne $s.data.selected) "C: searching selects the first match (selected=$($s.data.selected))"
    $s = Invoke-Guide @('--op=state', '--query=zzqqxx')
    Assert (@($s.data.rows).Count -eq 0) 'C: a search for nothing lists nothing'

    # =====================================================================
    # D: a category shows only its own rows, and a query clears it.
    # =====================================================================
    $s = Invoke-Guide @('--op=state', '--query=', '--category=panes')
    $rows = @($s.data.rows)
    $foreign = @($rows | Where-Object { [string]$_.category -ne 'panes' })
    Assert ($rows.Count -gt 0 -and $foreign.Count -eq 0) "D: Panes & Splits shows only its rows ($($rows.Count), foreign $($foreign.Count))"
    Assert ([int]$s.data.counts.panes -eq $rows.Count) "D: the sidebar count matches the list ($($s.data.counts.panes) vs $($rows.Count))"
    $s = Invoke-Guide @('--op=state', '--query=paste')
    Assert ($null -eq $s.data.category) "D: typing a search clears the category (category=$($s.data.category))"
    Assert ($null -ne (Find-Row $s 'paste_from_clipboard')) 'D: ...and searches every category'

    # =====================================================================
    # E: Show unbound actions.
    # =====================================================================
    $s0 = Invoke-Guide @('--op=state', '--query=', '--category=all', '--unbound=0')
    $s1 = Invoke-Guide @('--op=state', '--unbound=1')
    Assert (@($s1.data.rows).Count -gt @($s0.data.rows).Count) "E: Show unbound actions lists more ($(@($s0.data.rows).Count) -> $(@($s1.data.rows).Count))"
    $notBound = @(@($s1.data.rows) | Where-Object { @($_.keys).Count -eq 0 -and -not [bool]$_.unbound_by_user -and [string]$_.kind -eq 'keybind' })
    Assert ($notBound.Count -gt 0) "E: actions nothing binds are listed as not bound ($($notBound.Count))"
    Assert ((Test-Path $prefPath) -and ([System.IO.File]::ReadAllText($prefPath).Trim() -eq '1')) 'E: the toggle is remembered'
    [void](Invoke-Guide @('--op=state', '--unbound=0'))

    # =====================================================================
    # F: selection and Run - the action runs in the terminal window.
    # =====================================================================
    $before = Get-PaneCount
    $s = Invoke-Guide @('--op=state', '--query=new_split:right')
    Assert ([string]$s.data.selected -eq 'new_split:right') "F: the split row is selected (got $($s.data.selected))"
    $s = Invoke-Guide @('--op=run')
    Assert ([bool]$s.data.ran) 'F: Run reports it ran'
    Assert ([string]$s.data.last_run -eq 'new_split:right') "F: ...the selected action (got '$($s.data.last_run)')"
    Start-Sleep -Milliseconds 1200
    $after = Get-PaneCount
    Assert ($before -ge 1 -and $after -eq $before + 1) "F: the terminal window gained a pane ($before -> $after)"

    $s = Invoke-Guide @('--op=state', '--query=close_window')
    $s = Invoke-Guide @('--op=run')
    Assert (-not [bool]$s.data.ran) 'F: a destructive action (Close Window) is not run from the guide'
    $s = Invoke-Guide @('--op=state', '--query=', '--category=windows')
    $s = Invoke-Guide @('--op=select', '--down=1')
    Assert ($null -ne $s.data.selected) "F: Down selects a row (got $($s.data.selected))"
    $first = [string]$s.data.selected
    $s = Invoke-Guide @('--op=select', '--down=1')
    Assert ([string]$s.data.selected -ne $first) "F: Down again moves on ($first -> $($s.data.selected))"

    # =====================================================================
    # G: the cheat sheet.
    # =====================================================================
    $s = Invoke-Guide @('--op=cheat-sheet')
    $sheet = [string]$s.data.cheat_sheet
    Assert ($sheet -and (Test-Path $sheet)) "G: the cheat sheet is written ($sheet)"
    if ($sheet -and (Test-Path $sheet)) {
        $html = [System.IO.File]::ReadAllText($sheet)
        Assert ($html.Contains('Ghoztty Keyboard Shortcuts')) 'G: ...titled'
        Assert ($html.Contains('Ctrl+Shift+/')) 'G: ...with the bound chords'
        Assert ($html.Contains('Panes &amp; Splits')) 'G: ...by category'
        Assert ($html.Contains('window.print()')) 'G: ...and opens its own print dialog'
    }

    # =====================================================================
    # G2: the window paints - a snapshot of its client is a real image with
    # more than a background in it (the keycaps, the sidebar, the text).
    # =====================================================================
    $shot = Join-Path $env:TEMP "ghoztty-shortcut-guide-$PID.png"
    Remove-Item $shot -ErrorAction SilentlyContinue
    $s = Invoke-Guide @('--op=shot', "--path=$shot")
    Assert ($null -ne $s -and $s.success -and (Test-Path $shot)) "G2: the guide paints to a snapshot ($shot)"
    if (Test-Path $shot) {
        Add-Type -AssemblyName System.Drawing
        $bmp = [System.Drawing.Bitmap]::FromFile($shot)
        try {
            $colors = @{}
            for ($y = 0; $y -lt $bmp.Height; $y += 7) {
                for ($x = 0; $x -lt $bmp.Width; $x += 7) { $colors[$bmp.GetPixel($x, $y).ToArgb()] = 1 }
            }
            Assert ($colors.Count -ge 8) "G2: ...with real content in it ($($colors.Count) distinct sampled colours, $($bmp.Width)x$($bmp.Height))"
        } finally { $bmp.Dispose() }
        Remove-Item $shot -ErrorAction SilentlyContinue
    }

    # =====================================================================
    # H: Esc - clears the search, then the selection, then closes.
    # =====================================================================
    $s = Invoke-Guide @('--op=state', '--query=split')
    $s = Invoke-Guide @('--op=escape')
    Assert ([bool]$s.data.open -and [string]$s.data.query -eq '') "H: the first Esc clears the search (query='$($s.data.query)')"
    $s = Invoke-Guide @('--op=select', '--down=1')
    $s = Invoke-Guide @('--op=escape')
    Assert ([bool]$s.data.open -and $null -eq $s.data.selected) 'H: the next Esc clears the selection'
    $s = Invoke-Guide @('--op=escape')
    Assert (-not [bool]$s.data.open) 'H: the last Esc closes the guide'
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyShortcutGuide')
    Assert ($wins.Count -eq 0) "H: the window is gone ($($wins.Count))"

    # =====================================================================
    # I: refusals are typed.
    # =====================================================================
    $bad = Invoke-Guide @('--op=explode')
    Assert ($null -ne $bad -and -not $bad.success) 'I: an unknown op is refused'
    $badCat = Invoke-Guide @('--op=open', '--category=nope')
    Assert ($null -ne $badCat -and -not $badCat.success) 'I: an unknown category is refused'
    [void](Invoke-Guide @('--op=close'))

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Complete-TestBody
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    try {
        if ($prefExisted) { [System.IO.File]::WriteAllText($prefPath, $prefBackup) }
        else { Remove-Item $prefPath -Force -ErrorAction SilentlyContinue }
    } catch {}
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $script:launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

# --- stamp (T783) ---------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard shortcut-guide -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'shortcut-guide'
