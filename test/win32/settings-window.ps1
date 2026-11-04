# T2675 acceptance: the Settings window shell - Mac's Cmd-, window
# (docs/reference/settings.md, Mac 9287de0ff) exists on Windows. open_config
# (Ctrl+, / the Settings menu item / the palette) opens ONE native window
# (a second invocation focuses it), Advanced > All Settings lists every schema
# key with the All / Changed filter, the sidebar Search narrows across every
# row, editing a row writes one line to this dev build's config and applies
# live, an invalid value shows inline with the file untouched, Reset removes
# the line, a repeatable key takes and drops values, and a key that a LATER
# include sets is read-only with Mac's "Set in X, which loads after your
# config." note. T2585 adds the curated pages (section J): Mac's sidebar
# order and per-page counts, labelled rows with an on/off switch or a value
# popup, conditions that dim a row, env and the Mac-only keys kept off the
# pages, the "Not on other pages" filter, the "<Page> >" reveal link, and
# search listing curated rows before the rest.
#
# THE ORACLE IS THE MODEL AND THE FILE. What a row reads and whether a write
# reached the file are decisions, invisible in pixels, so they are read through
# the debug-only `settings` IPC action (src/apprt/win32/ipc_settings.zig),
# whose ops call the same functions the window's clicks and keys call, and by
# reading the config file itself. The WINDOW is structural: one top-level
# GhozttySettings titled "Settings", however many times it is asked for.
#
# THE CONFIG IS DRIVEN: XDG_CONFIG_HOME points at a temp dir holding this dev
# build's own config-debug.ghostty (font-size = 13, an include) and the include
# (cursor-style = bar), so "set in your file" and "overridden by a later
# include" are reachable states. GHOZTTY_SETTINGS_BACKUP_DIR keeps the
# once-per-session backup out of the box's real backup folder.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never
# steals the user's foreground.
#
# -NegativeControl inverts a load-bearing claim (an invalid value leaves the
# file untouched) - that run MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-settings$PID"

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

function Invoke-Settings([string[]]$ipcArgs) {
    return Invoke-GhozttyIpc -Action 'settings' -Arguments $ipcArgs
}

function Find-Row($state, [string]$key) {
    foreach ($r in @($state.data.rows)) { if ([string]$r.key -eq $key) { return $r } }
    return $null
}

function Read-Config {
    if (-not (Test-Path $cfgFile)) { return '' }
    return [System.IO.File]::ReadAllText($cfgFile)
}

function Get-KeyLines([string]$text, [string]$key) {
    return @(($text -split "`r?`n") | Where-Object { $_ -match ('^\s*' + [regex]::Escape($key) + '\s*=') })
}

$work = Join-Path $env:TEMP "ghoztty-settings-$PID"
$cfgHome = Join-Path $work 'xdg'
$cfgDir = Join-Path $cfgHome 'ghostty'
$cfgFile = Join-Path $cfgDir 'config-debug.ghostty'
$laterFile = Join-Path $cfgDir 'later.ghostty'
$backupDir = Join-Path $work 'backups'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
[System.IO.File]::WriteAllText($cfgFile, "font-size = 13`nconfig-file = later.ghostty`n")
[System.IO.File]::WriteAllText($laterFile, "cursor-style = bar`n")

$errlog = Join-Path $env:TEMP 'ghoztty-settings-window-stderr.log'
$script:launched = @()
$app = $null

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: section D asserts the refused value DID change the file - this run MUST fail"
    }
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_SETTINGS_BACKUP_DIR = $backupDir
    try {
        $sp = @{
            Exe       = $exe
            Arguments = @('--session-persistence=false', '--background=#101014')
        }
        if (-not $ExePath) { $sp.StdErr = $errlog }
        $app = Start-OnTestDesktop @sp
    } finally {
        Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_SETTINGS_BACKUP_DIR -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if (-not $app -or ($app.Process -and $app.Process.HasExited)) {
        Write-TestAssertedNothing -Reason 'GUI did not come up' -Label 'settings-window'
        exit 1
    }
    $script:launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'no terminal window appeared' -Label 'settings-window'
        exit 1
    }

    # =====================================================================
    # A: open_config opens ONE window, Mac's title; a second one focuses it.
    # =====================================================================
    $closed = Invoke-Settings @('--op=state')
    Assert ($null -ne $closed -and -not $closed.success) 'A: asking for state with no window open is refused, not a silent open'

    # The real action, as Ctrl+, / the Settings menu item fire it.
    $s = Invoke-Settings @('--op=action')
    if ($null -eq $s -or -not $s.success) {
        Write-TestAssertedNothing -Reason 'the settings IPC action never answered' -Label 'settings-window'
        exit 1
    }
    Assert ([bool]$s.data.open) 'A: open_config opens the Settings window (not the raw file)'
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttySettings')
    Assert ($wins.Count -eq 1) "A: exactly one Settings window exists ($($wins.Count))"
    if ($wins.Count -ge 1) {
        $title = Get-TestWindowText -Window ([IntPtr]$wins[0].Hwnd)
        Assert ($title -eq 'Settings') "A: the window carries Mac's title (got '$title')"
        Assert ($wins[0].Visible) 'A: the window is visible'
    }
    [void](Invoke-Settings @('--op=action'))
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttySettings')
    Assert ($wins.Count -eq 1) "A: a second open_config focuses it rather than stacking another ($($wins.Count))"
    # Ghostty's XDG join writes a '/' before the subdir; the file is the same.
    Assert ((([string]$s.data.file) -replace '/', '\') -ieq $cfgFile) "A: it writes this dev build's own file (file='$($s.data.file)')"
    Assert ([string]$s.data.page -eq 'panes') "A: it opens on the first page, Panes & Windows (page='$($s.data.page)')"

    # Ctrl+, is the default chord (the shortcut guide lists the live bindings).
    $g = Invoke-GhozttyIpc -Action 'shortcut-guide' -Arguments @('--op=open', '--query=settings')
    $row = $null
    if ($g -and $g.success) { foreach ($r in @($g.data.rows)) { if ([string]$r.id -eq 'open_config') { $row = $r } } }
    Assert ($null -ne $row -and (@($row.keys) -contains 'Ctrl+,')) "A: open_config is bound to Ctrl+, (keys: $(if ($row) { @($row.keys) -join ', ' }))"
    [void](Invoke-GhozttyIpc -Action 'shortcut-guide' -Arguments @('--op=close'))

    # =====================================================================
    # B: All Settings lists every schema key; Changed and Search narrow it.
    # =====================================================================
    $s = Invoke-Settings @('--op=state', '--page=advanced', '--filter=all')
    $total = [int]$s.data.total
    $rows = @($s.data.rows)
    Assert ($total -gt 100) "B: the schema has every key ($total)"
    Assert ($rows.Count -eq $total) "B: All lists every key ($($rows.Count) of $total)"
    $fs = Find-Row $s 'font-size'
    Assert ($null -ne $fs -and [string]$fs.value -eq '13') "B: font-size reads the file's 13 (got '$($fs.value)')"
    Assert ($fs -and [bool]$fs.modified -and [bool]$fs.set_in_file) 'B: ...and is marked changed and set in your file'
    $cs = Find-Row $s 'cursor-style'
    Assert ($null -ne $cs -and [bool]$cs.readonly) 'C0: cursor-style, set in a later include, is read-only'
    Assert ($cs -and ([string]$cs.override) -like '*later.ghostty') "C0: ...naming the include that sets it (override='$($cs.override)')"

    $s = Invoke-Settings @('--op=state', '--filter=changed')
    $changed = @($s.data.rows)
    Assert ($changed.Count -gt 0 -and $changed.Count -lt $total) "B: Changed narrows the list ($($changed.Count) of $total)"
    $unmod = @($changed | Where-Object { -not [bool]$_.modified })
    Assert ($unmod.Count -eq 0) "B: every Changed row differs from the default (offenders: $(@($unmod | ForEach-Object { $_.key }) -join ', '))"
    Assert ($null -ne (Find-Row $s 'font-size') -and $null -ne (Find-Row $s 'cursor-style')) 'B: Changed includes the file key and the include key'

    $s = Invoke-Settings @('--op=state', '--query=font-size')
    Assert ([bool]$s.data.searching) 'B: typing in Search switches to results'
    $hits = @($s.data.rows)
    Assert ($hits.Count -ge 1 -and $hits.Count -lt $total) "B: Search narrows across every row ($($hits.Count))"
    Assert ($null -ne (Find-Row $s 'font-size')) 'B: ...and finds font-size'
    $s = Invoke-Settings @('--op=state', '--query=zzqqnotasetting')
    Assert (@($s.data.rows).Count -eq 0 -and [int]$s.data.matched -eq 0) 'B: a search that matches nothing lists nothing'
    $s = Invoke-Settings @('--op=state', '--query=', '--filter=all')
    Assert (-not [bool]$s.data.searching -and @($s.data.rows).Count -eq $total) 'B: clearing the search brings the page back'

    # =====================================================================
    # C: editing a row writes ONE line and applies live.
    # =====================================================================
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=15')
    Assert ([bool]$s.data.ok) 'C: committing 15 into font-size succeeds'
    $text = Read-Config
    $lines = @(Get-KeyLines $text 'font-size')
    Assert ($lines.Count -eq 1 -and $lines[0] -match '15') "C: the file holds exactly one font-size line, now 15 ($($lines -join ' | '))"
    Assert ($text -match 'config-file = later\.ghostty') 'C: the rest of the file is untouched'
    $fs = Find-Row $s 'font-size'
    Assert ($fs -and [string]$fs.value -eq '15') "C: the row reads 15 (got '$($fs.value)')"
    Assert ($fs -and [string]$fs.effective -eq '15') "C: the change applied live - the running config says 15 (got '$($fs.effective)')"
    $backups = @(Get-ChildItem $backupDir -ErrorAction SilentlyContinue)
    Assert ($backups.Count -eq 1) "C: the first write backed the file up once ($($backups.Count))"

    # =====================================================================
    # D: an invalid value shows inline and the file is untouched.
    # =====================================================================
    $before = Read-Config
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=abc')
    Assert (-not [bool]$s.data.ok) 'D: committing abc into font-size is refused'
    $fs = Find-Row $s 'font-size'
    Assert ($fs -and -not [string]::IsNullOrEmpty([string]$fs.problem)) "D: the row shows the parser's problem inline ('$($fs.problem)')"
    Assert ([string]$s.data.editing -eq '') "D: the field is not left in edit (editing='$($s.data.editing)')"
    $after = Read-Config
    $script:negReached = $true
    $wantSame = -not $NegativeControl
    Assert (($after -eq $before) -eq $wantSame) 'D: the file is byte-for-byte untouched'
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=16')
    $fs = Find-Row $s 'font-size'
    Assert ($fs -and $null -eq $fs.problem) 'D: a good value clears the problem'

    # =====================================================================
    # E: a key a later include sets is read-only.
    # =====================================================================
    $before = Read-Config
    $s = Invoke-Settings @('--op=set', '--key=cursor-style', '--value=underline')
    Assert (-not [bool]$s.data.ok) 'E: an edit to the overridden cursor-style is refused'
    Assert ((Read-Config) -eq $before) 'E: ...and writes nothing'
    Assert (@(Get-KeyLines (Read-Config) 'cursor-style').Count -eq 0) 'E: your file still does not set cursor-style'

    # =====================================================================
    # F: Reset removes the line.
    # =====================================================================
    $s = Invoke-Settings @('--op=reset', '--key=font-size')
    Assert ([bool]$s.data.ok) 'F: Reset font-size succeeds'
    Assert (@(Get-KeyLines (Read-Config) 'font-size').Count -eq 0) 'F: the file no longer sets font-size'
    $fs = Find-Row $s 'font-size'
    Assert ($fs -and -not [bool]$fs.set_in_file -and -not [bool]$fs.modified) 'F: the row is back at its default'
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=')
    Assert (@(Get-KeyLines (Read-Config) 'font-size').Count -eq 0) 'F: an emptied field on a default key writes nothing'

    # =====================================================================
    # G: a repeatable key takes and drops values.
    # =====================================================================
    $s = Invoke-Settings @('--op=add', '--key=font-family', '--value=Consolas')
    Assert ([bool]$s.data.ok) 'G: adding Consolas to font-family succeeds'
    $ff = Find-Row $s 'font-family'
    Assert ($ff -and [bool]$ff.repeatable -and (@($ff.file_values) -contains 'Consolas')) "G: the row lists it (file_values: $(if ($ff) { @($ff.file_values) -join ', ' }))"
    Assert (@(Get-KeyLines (Read-Config) 'font-family').Count -eq 1) 'G: one font-family line is in the file'
    $s = Invoke-Settings @('--op=add', '--key=font-family', '--value=Cascadia Mono')
    $ff = Find-Row $s 'font-family'
    Assert ($ff -and @($ff.file_values).Count -eq 2) "G: a second value appends ($(if ($ff) { @($ff.file_values) -join ', ' }))"
    $s = Invoke-Settings @('--op=remove', '--key=font-family', '--index=0')
    $ff = Find-Row $s 'font-family'
    Assert ($ff -and (@($ff.file_values) -join ',') -eq 'Cascadia Mono') "G: removing the first chip keeps the rest ($(if ($ff) { @($ff.file_values) -join ', ' }))"

    # =====================================================================
    # H: the full doc on demand, and the window paints.
    # =====================================================================
    $s = Invoke-Settings @('--op=doc', '--key=font-size')
    Assert ([string]$s.data.doc -eq 'font-size') "H: the doc button shows font-size's full documentation (doc='$($s.data.doc)')"
    $s = Invoke-Settings @('--op=doc', '--key=font-size')
    Assert ($null -eq $s.data.doc) 'H: ...and pressing it again hides it'
    $shot = Join-Path $work 'settings.png'
    $s = Invoke-Settings @('--op=shot', "--path=$shot")
    Assert ($s.success -and (Test-Path $shot)) 'H: the window renders to a PNG'
    if (Test-Path $shot) {
        Add-Type -AssemblyName System.Drawing
        $bmp = [System.Drawing.Bitmap]::FromFile($shot)
        try {
            $colors = @{}
            for ($y = 0; $y -lt $bmp.Height; $y += 7) {
                for ($x = 0; $x -lt $bmp.Width; $x += 7) { $colors[$bmp.GetPixel($x, $y).ToArgb()] = 1 }
            }
            Assert ($colors.Count -ge 8) "H: ...with real content in it ($($colors.Count) distinct sampled colours, $($bmp.Width)x$($bmp.Height))"
        } finally { $bmp.Dispose() }
    }

    # =====================================================================
    # J: the curated pages (T2585).
    # =====================================================================
    $s = Invoke-Settings @('--op=state', '--page=panes')
    $ids = @($s.data.pages | ForEach-Object { [string]$_.id }) -join ','
    Assert ($ids -eq 'panes,terminal,keyboard,session,remote,updates,advanced') "J: the sidebar is Mac's page order less Appearance ($ids)"
    $ps = Find-Row $s 'macos-pane-style'
    Assert ($ps -and [string]$ps.label -eq 'Style' -and [string]$ps.control -eq 'segmented' -and [string]$ps.shown -eq 'Elevated') "J: Panes & Windows shows the pane Style as a choice reading Elevated (label='$($ps.label)' control='$($ps.control)' shown='$($ps.shown)')"
    $gl = Find-Row $s 'macos-pane-glass'
    $dv = Find-Row $s 'split-divider-color'
    Assert ($gl -and [bool]$gl.enabled -and $dv -and -not [bool]$dv.enabled) 'J: under Elevated, Glass panes is live and Divider color (flat only) is dimmed'
    $before = Read-Config
    $s = Invoke-Settings @('--op=choose', '--key=macos-pane-style', '--value=flat')
    Assert ([bool]$s.data.ok -and @(Get-KeyLines (Read-Config) 'macos-pane-style').Count -eq 1 -and (Read-Config) -match 'macos-pane-style = flat') 'J: picking Flat writes one macos-pane-style = flat line'
    $gl = Find-Row $s 'macos-pane-glass'
    $dv = Find-Row $s 'split-divider-color'
    Assert ($gl -and -not [bool]$gl.enabled -and $dv -and [bool]$dv.enabled) 'J: ...which dims Glass panes and makes Divider color live'
    $s = Invoke-Settings @('--op=toggle', '--key=maximize')
    $mx = Find-Row $s 'maximize'
    Assert ([bool]$s.data.ok -and $mx -and [string]$mx.shown -eq 'On' -and (Read-Config) -match '(?m)^maximize = true') "J: the Open windows filling the screen switch turns on and writes maximize = true (shown='$($mx.shown)')"
    $pc = @($s.data.pages | Where-Object { $_.id -eq 'panes' })[0]
    Assert ($pc -and [int]$pc.count -eq 2) "J: the sidebar counts the page's two changed keys ($($pc.count))"
    $s = Invoke-Settings @('--op=toggle', '--key=maximize')
    Assert ((Read-Config) -match '(?m)^maximize = false') 'J: the switch turns back off (maximize = false)'
    $s = Invoke-Settings @('--op=reset', '--key=maximize')
    $s = Invoke-Settings @('--op=choose', '--key=macos-pane-style', '--value=')
    Assert (@(Get-KeyLines (Read-Config) 'macos-pane-style').Count -eq 0) 'J: picking the unset choice takes the key back out of the file'
    $mid = Read-Config
    $s = Invoke-Settings @('--op=choose', '--key=scrollbar', '--value=sometimes')
    Assert (-not [bool]$s.data.ok -and (Read-Config) -eq $mid) 'J: a value the parser refuses is not written from a popup either'

    $s = Invoke-Settings @('--op=state', '--page=terminal')
    $keys = @($s.data.rows | ForEach-Object { [string]$_.key })
    Assert (($keys -contains 'scrollback-limit') -and ($keys -contains 'command-shell') -and ($keys -contains 'copy-on-select')) "J: Terminal lists shell, scrollback and copy & paste keys ($($keys.Count) rows)"
    Assert (-not ($keys -contains 'env')) 'J: env is not on the Terminal page (Mac 3a183ffd1)'
    $s = Invoke-Settings @('--op=state', '--page=updates')
    $keys = @($s.data.rows | ForEach-Object { [string]$_.key })
    Assert (($keys -contains 'auto-update') -and -not ($keys -contains 'auto-update-channel')) "J: Updates carries auto-update and no tip channel ($($keys -join ','))"
    $s = Invoke-Settings @('--op=state', '--page=keyboard')
    $keys = @($s.data.rows | ForEach-Object { [string]$_.key })
    Assert (-not ($keys -contains 'macos-option-as-alt')) 'J: the Mac-only Option-key setting is not on Keyboard'

    $s = Invoke-Settings @('--op=state', '--page=advanced', '--filter=uncovered')
    $unc = @($s.data.rows)
    $curatedLeak = @($unc | Where-Object { $null -ne $_.curated_page })
    Assert ($unc.Count -gt 0 -and $unc.Count -lt $total -and $curatedLeak.Count -eq 0) "J: Not on other pages lists only uncurated keys ($($unc.Count) of $total; leaks: $(@($curatedLeak | ForEach-Object { $_.key }) -join ','))"
    Assert ($null -ne (Find-Row $s 'env')) 'J: ...env among them'
    $s = Invoke-Settings @('--op=reveal', '--key=scrollbar', '--filter=all')
    Assert ([bool]$s.data.ok -and [string]$s.data.page -eq 'terminal' -and [string]$s.data.revealed -eq 'scrollbar') "J: the Terminal link on scrollback opens Terminal at that row (page='$($s.data.page)' revealed='$($s.data.revealed)')"

    $s = Invoke-Settings @('--op=state', '--query=scroll')
    $first = @($s.data.rows)[0]
    Assert ([int]$s.data.curated_hits -ge 2 -and $first -and -not [string]::IsNullOrEmpty([string]$first.label)) "J: search lists curated rows first ($($s.data.curated_hits) curated; first='$($first.key)')"
    [void](Invoke-Settings @('--op=state', '--query='))
    $shot2 = Join-Path $work 'settings-panes.png'
    $s = Invoke-Settings @('--op=shot', '--page=panes', "--path=$shot2")
    Assert ($s.success -and (Test-Path $shot2) -and (Get-Item $shot2).Length -gt 4000) 'J: a curated page renders to a PNG'

    # =====================================================================
    # I: Esc clears the search, then closes; refusals are typed.
    # =====================================================================
    $s = Invoke-Settings @('--op=state', '--query=cursor')
    $s = Invoke-Settings @('--op=escape')
    Assert ([bool]$s.data.open -and [string]$s.data.query -eq '') "I: the first Esc clears the search (query='$($s.data.query)')"
    $bad = Invoke-Settings @('--op=explode')
    Assert ($null -ne $bad -and -not $bad.success) 'I: an unknown op is refused'
    $bad = Invoke-Settings @('--op=state', '--filter=some')
    Assert ($null -ne $bad -and -not $bad.success) 'I: an unknown filter is refused'
    $s = Invoke-Settings @('--op=escape')
    Assert (-not [bool]$s.data.open) 'I: the next Esc closes the window'
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttySettings')
    Assert ($wins.Count -eq 0) "I: the window is gone ($($wins.Count))"
    $s = Invoke-Settings @('--op=action')
    Assert ([bool]$s.data.open -and $null -eq (Find-Row $s 'font-size').problem) 'I: reopening reads the file afresh'
    [void](Invoke-Settings @('--op=close'))

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Complete-TestBody
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
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
        update -Guard settings-window -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'settings-window'
