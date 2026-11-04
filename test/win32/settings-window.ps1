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
# search listing curated rows before the rest. T2586 adds Appearance (section K):
# its Font, Cursor and Window rows, and the theme picker over the bundled and
# the user's own themes - one theme, or light & dark with each slot listing
# only its kind, the family-seeded switch, the user-wins clash and Mac's
# mismatch warning.
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
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')

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
# The user's own themes (T2586): one of each kind, and a DARK '3024 Day' that
# must replace the bundled light one (a user theme wins a name clash).
$themeDir = Join-Path $cfgDir 'themes'
New-Item -ItemType Directory -Force -Path $themeDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $themeDir 'Zz Test Light'), "background = #fafafa`nforeground = #222222`n")
[System.IO.File]::WriteAllText((Join-Path $themeDir 'Zz Test Dark'), "background = #101010`nforeground = #eeeeee`n")
[System.IO.File]::WriteAllText((Join-Path $themeDir '3024 Day'), "background = #101010`nforeground = #eeeeee`n")

$errlog = Join-Path $env:TEMP 'ghoztty-settings-window-stderr.log'
$script:launched = @()
$app = $null

[void](Set-GhozttyTestAgentLineage -Tag 'settings' -Quiet)
$agentDir = Get-GhozttyAgentStateDir -Root $env:LOCALAPPDATA -Exe $exe
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
    # T2680's Check for Updates... runs a real manual check; keep it off the
    # network (nothing listens on the discard port).
    $env:GHOZTTY_UPDATE_URL = 'http://127.0.0.1:9/releases'
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
    Assert ([string]$s.data.page -eq 'appearance') "A: it opens on the first page, Appearance (page='$($s.data.page)')"

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
    Assert ($ids -eq 'appearance,panes,terminal,keyboard,session,remote,updates,advanced') "J: the sidebar is Mac's page order ($ids)"
    $ps = Find-Row $s 'macos-pane-style'
    Assert ($ps -and [string]$ps.label -eq 'Pane style' -and [string]$ps.control -eq 'cards' -and [string]$ps.shown -eq 'Elevated') "J: Panes & Windows shows Pane style as preview cards reading Elevated (label='$($ps.label)' control='$($ps.control)' shown='$($ps.shown)')"
    $shotP = Join-Path $work 'panes.png'
    $s = Invoke-Settings @('--op=shot', "--path=$shotP")
    $cards = @($s.data.hits | Where-Object { $_.kind -eq 'pane_style' } | ForEach-Object { [string]$_.key }) -join ','
    Assert ($cards -eq 'elevated,flat') "T2680 J: the page paints Mac's two Pane style cards, Elevated then Flat ($cards)"
    $gl = Find-Row $s 'macos-pane-glass'
    $dv = Find-Row $s 'split-divider-color'
    Assert ($gl -and [bool]$gl.enabled -and $dv -and -not [bool]$dv.enabled) 'J: under Elevated, Glass panes is live and Divider color (flat only) is dimmed'
    $before = Read-Config
    $s = Invoke-Settings @('--op=click', '--value=pane_style:flat')
    Assert ([bool]$s.data.ok -and @(Get-KeyLines (Read-Config) 'macos-pane-style').Count -eq 1 -and (Read-Config) -match 'macos-pane-style = flat') 'T2680 J: clicking the Flat card writes one macos-pane-style = flat line'
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
    # T2680: Updates' version and Check for Updates...
    $shotU = Join-Path $work 'updates.png'
    $s = Invoke-Settings @('--op=shot', '--page=updates', "--path=$shotU")
    $cu = @($s.data.hits | Where-Object { $_.kind -eq 'check_updates' })
    Assert ($cu.Count -eq 1) "T2680 J: Updates paints one Check for Updates... (hits=$($cu.Count))"
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $s = Invoke-Settings @('--op=click', '--value=check_updates')
    $last = [int64]$s.data.live.last_check_ms
    Assert ([bool]$s.data.ok -and $last -ge ($t0 - 50)) "T2680 J: clicking Check for Updates... starts the manual check (last_check_ms=$last, t0=$t0)"
    Assert (-not [string]::IsNullOrEmpty([string]$s.data.live.version)) "T2680 J: Updates names the running version ($($s.data.live.version))"

    # T2680: Sessions & Agent reads the agent WITHOUT starting one. The app
    # runs with persistence off under its own lineage, so any agent process
    # appearing would be the page's doing.
    function Get-AgentPids { @(Get-CimInstance Win32_Process -Filter "Name = 'ghoztty-agent.exe'" -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.ProcessId }) }
    New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
    $portFile = Join-Path $agentDir 'port.json'
    $pidsBefore = Get-AgentPids
    $s = Invoke-Settings @('--op=state', '--page=session')
    Assert (-not [bool]$s.data.live.agent.running) "T2680 J: with no agent, Sessions & Agent says it is not running (running=$($s.data.live.agent.running))"
    # A live process holding the info file is reported, with its pid and pipe.
    $holder = Start-Process -FilePath "$env:WINDIR\System32\ping.exe" -ArgumentList '-n','60','127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        $fakePipe = "\\.\pipe\ghoztty-agent-settings-test-$PID"
        [System.IO.File]::WriteAllText($portFile, (@{ port = 0; pid = $holder.Id; pipe = $fakePipe } | ConvertTo-Json -Compress))
        $s = Invoke-Settings @('--op=state', '--page=session')
        $ag = $s.data.live.agent
        Assert ([bool]$ag.running -and [int]$ag.pid -eq $holder.Id -and [string]$ag.pipe -eq $fakePipe) "T2680 J: a live agent is reported running with its pid and pipe (running=$($ag.running) pid=$($ag.pid) want=$($holder.Id) pipe=$($ag.pipe))"
        $shotS = Join-Path $work 'session.png'
        $s = Invoke-Settings @('--op=shot', "--path=$shotS")
        Assert ($s.success -and (Test-Path $shotS)) 'T2680 J: the Sessions & Agent page paints with the agent lines'
    } finally {
        try { Stop-Process -Id $holder.Id -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Milliseconds 300
    $s = Invoke-Settings @('--op=state', '--page=session')
    Assert (-not [bool]$s.data.live.agent.running) "T2680 J: once that pid is gone, a leftover port.json does not read as running (running=$($s.data.live.agent.running))"
    Remove-Item $portFile -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500
    $newAgents = @(Get-AgentPids | Where-Object { $pidsBefore -notcontains $_ })
    Assert ($newAgents.Count -eq 0) "T2680 J: opening Sessions & Agent started no ghoztty-agent process (new: $($newAgents -join ','))"

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
    # K: Appearance (T2586) - Font / Cursor / Window rows and the theme picker.
    # =====================================================================
    $s = Invoke-Settings @('--op=state', '--page=appearance')
    $keys = @($s.data.rows | ForEach-Object { [string]$_.key })
    Assert ((($keys -contains 'font-family') -and ($keys -contains 'font-size') -and ($keys -contains 'cursor-style') -and ($keys -contains 'background-opacity') -and ($keys -contains 'window-theme'))) "K: Appearance lists the font, cursor and window keys ($($keys -join ','))"
    Assert (-not ($keys -contains 'background-blur') -and -not ($keys -contains 'macos-titlebar-style')) 'K: ...and not the two Window keys the win32 runtime never reads'
    $wt = Find-Row $s 'window-theme'
    Assert ($wt -and [string]$wt.label -eq 'Window appearance' -and [string]$wt.shown -eq 'Match the theme') "K: Window appearance reads Mac's label for auto (shown='$($wt.shown)')"
    $th = $s.data.theme
    Assert ($th -and [int]$th.light_count -gt 20 -and [int]$th.dark_count -gt 20) "K: the bundled themes are read and split by kind ($($th.light_count) light, $($th.dark_count) dark)"
    $ut = @($th.user_themes)
    $zl = @($ut | Where-Object { $_.name -eq 'Zz Test Light' })[0]
    $zd = @($ut | Where-Object { $_.name -eq 'Zz Test Dark' })[0]
    $dy = @($ut | Where-Object { $_.name -eq '3024 Day' })[0]
    Assert ($zl -and [bool]$zl.light -and $zd -and -not [bool]$zd.light) 'K: the user themes folder is read, each theme sorted by its background'
    Assert ($dy -and -not [bool]$dy.light) "K: the user's own '3024 Day' replaces the bundled one (a user theme wins a clash)"
    Assert (-not [bool]$th.follows -and $null -eq $th.light) 'K: with no theme set the section reads One theme, Default'

    $s = Invoke-Settings @('--op=theme-pick', '--key=light', '--value=Catppuccin Latte')
    Assert ([bool]$s.data.ok -and @(Get-KeyLines (Read-Config) 'theme').Count -eq 1 -and (Read-Config) -match '(?m)^theme = Catppuccin Latte\r?$') 'K: picking a theme in One theme mode writes theme = <name>'
    $s = Invoke-Settings @('--op=theme-mode', '--value=true')
    Assert ([bool]$s.data.ok -and (Read-Config) -match '(?m)^theme = light:Catppuccin Latte,dark:Catppuccin Frappe\r?$' -and [bool]$s.data.theme.follows) "K: switching to Light & dark keeps Latte for light and seeds dark with the first dark theme of its family, Frappe - Mac's rule (theme='$($s.data.theme.light)'/'$($s.data.theme.dark)')"
    $s = Invoke-Settings @('--op=theme-pick', '--key=dark', '--value=Zz Test Dark')
    Assert ([bool]$s.data.ok -and (Read-Config) -match '(?m)^theme = light:Catppuccin Latte,dark:Zz Test Dark\r?$') 'K: a dark-mode pick fills only the dark slot (and takes a user theme)'
    $mid = Read-Config
    $s = Invoke-Settings @('--op=theme-pick', '--key=dark', '--value=No Such Theme')
    Assert (-not [bool]$s.data.ok -and (Read-Config) -eq $mid) 'K: a name the catalog does not hold is refused and the file is untouched'
    $s = Invoke-Settings @('--op=set', '--key=theme', '--value=light:Zz Test Dark,dark:Zz Test Dark')
    Assert ([string]$s.data.theme.mismatch -eq 'light') "K: a hand-edited dark theme in the light slot raises Mac's mismatch warning (mismatch='$($s.data.theme.mismatch)')"
    $s = Invoke-Settings @('--op=theme-pick', '--key=light', '--value=Zz Test Light')
    Assert ([bool]$s.data.ok -and $null -eq $s.data.theme.mismatch) 'K: picking a light theme for light mode clears it'

    # The tile grid (T2682, Mac ThemeSection): tabs list one kind with the
    # tab's pick first, 11 tiles then "All N", a case-folding filter, and a
    # tile click writes the tab's slot. theme = light:Zz Test Light,dark:Zz Test Dark.
    [void](Invoke-Settings @('--op=set', '--key=theme', '--value=light:Zz Test Light,dark:Zz Test Dark'))
    $s = Invoke-Settings @('--op=theme-tab', '--value=light')
    $g = $s.data.theme
    $tiles = @($g.tiles)
    Assert ([string]$g.tab -eq 'light' -and $tiles.Count -eq 11 -and [bool]$g.more -and [int]$g.kind_total -eq [int]$g.light_count -and [int]$g.matched -eq [int]$g.light_count) "K: the light tab shows 11 tiles then All N ($($tiles.Count) tiles, more=$($g.more), $($g.matched) of $($g.kind_total) light)"
    Assert ([string]$tiles[0] -eq 'Zz Test Light' -and [string]$g.selected -eq 'Zz Test Light' -and -not ($tiles -contains 'Zz Test Dark')) "K: the light pick's tile is first and selected, and no dark theme is listed (first='$($tiles[0])' selected='$($g.selected)')"
    $s = Invoke-Settings @('--op=theme-tab', '--value=dark')
    $g = $s.data.theme
    $tiles = @($g.tiles)
    Assert ([string]$g.tab -eq 'dark' -and [string]$tiles[0] -eq 'Zz Test Dark' -and [string]$g.selected -eq 'Zz Test Dark' -and -not ($tiles -contains 'Zz Test Light')) "K: the dark tab lists dark themes with the dark pick first (first='$($tiles[0])' selected='$($g.selected)')"
    $s = Invoke-Settings @('--op=theme-filter', '--value=MOCHA')
    $g = $s.data.theme
    $tiles = @($g.tiles)
    $off = @($tiles | Where-Object { $_ -notmatch '(?i)mocha' })
    Assert ([bool]$g.filter_focused -and [string]$g.filter -eq 'MOCHA' -and $tiles.Count -ge 1 -and $off.Count -eq 0 -and ($tiles -contains 'Catppuccin Mocha') -and -not [bool]$g.more) "K: typing MOCHA in the filter narrows the dark tiles to names holding it, any case ($($tiles -join ', '))"
    $s = Invoke-Settings @('--op=theme-filter', '--value=zzqq-nothing')
    Assert (@($s.data.theme.tiles).Count -eq 0 -and [int]$s.data.theme.matched -eq 0) 'K: a filter nothing matches leaves no tiles'
    [void](Invoke-Settings @('--op=theme-filter', '--value='))
    $s = Invoke-Settings @('--op=theme-all')
    $g = $s.data.theme
    Assert ([bool]$g.show_all -and @($g.tiles).Count -eq [int]$g.dark_count -and -not [bool]$g.more) "K: All N dark themes shows every dark tile ($(@($g.tiles).Count) of $($g.dark_count))"
    $s = Invoke-Settings @('--op=theme-tab', '--value=dark')
    Assert (-not [bool]$s.data.theme.show_all -and @($s.data.theme.tiles).Count -eq 11) 'K: a tab click collapses the grid again'

    # The painted grid, clicked through the window's own click path.
    $shotGrid = Join-Path $work 'settings-theme-grid.png'
    [void](Invoke-Settings @('--op=reveal', '--key=font-family'))
    $s = Invoke-Settings @('--op=shot', '--page=appearance', "--path=$shotGrid")
    $painted = @($s.data.theme.painted_tiles)
    Assert ($painted.Count -ge 2 -and [string]$painted[0] -eq 'Zz Test Dark' -and [bool]$s.data.theme.painted_all) "K: the page paints the tiles, the pick first, and the All N tile ($($painted.Count) painted, first='$($painted[0])', all=$($s.data.theme.painted_all))"
    $target = [string]$painted[1]
    $s = Invoke-Settings @('--op=click', "--value=theme_tile:$target")
    Assert ([bool]$s.data.ok -and (Read-Config) -match "(?m)^theme = light:Zz Test Light,dark:$([regex]::Escape($target))\r?$") "K: clicking a dark tile in light & dark mode writes it into the dark slot only ($target)"
    [void](Invoke-Settings @('--op=shot', "--path=$shotGrid"))
    $s = Invoke-Settings @('--op=click', '--value=theme_tab:light')
    Assert ([bool]$s.data.ok -and [string]$s.data.theme.tab -eq 'light' -and [string]@($s.data.theme.tiles)[0] -eq 'Zz Test Light') "K: clicking the light tab shows the light themes (tab='$($s.data.theme.tab)')"
    [void](Invoke-Settings @('--op=shot', "--path=$shotGrid"))
    $s = Invoke-Settings @('--op=click', '--value=theme_all')
    Assert ([bool]$s.data.ok -and [bool]$s.data.theme.show_all -and @($s.data.theme.tiles).Count -eq [int]$s.data.theme.light_count) 'K: clicking All N light themes shows them all'
    [void](Invoke-Settings @('--op=set', '--key=theme', '--value=light:Zz Test Light,dark:Zz Test Dark'))
    $shot3 = Join-Path $work 'settings-appearance.png'
    $s = Invoke-Settings @('--op=shot', '--page=appearance', "--path=$shot3")
    Assert ($s.success -and (Test-Path $shot3) -and (Get-Item $shot3).Length -gt 4000) 'K: the Appearance page renders to a PNG'
    $s = Invoke-Settings @('--op=theme-mode', '--value=false')
    $one = @(Get-KeyLines (Read-Config) 'theme')
    Assert ([bool]$s.data.ok -and -not [bool]$s.data.theme.follows -and $one.Count -eq 1 -and $one[0] -match '^theme = Zz Test (Light|Dark)\s*$') "K: back to One theme keeps the slot the system is showing ($($one -join ' | '))"
    # One theme: the tabs only filter, and a tile replaces the one theme.
    [void](Invoke-Settings @('--op=theme-tab', '--value=dark'))
    $s = Invoke-Settings @('--op=shot', "--path=$shotGrid")
    $pick = [string]@($s.data.theme.painted_tiles)[1]
    $s = Invoke-Settings @('--op=click', "--value=theme_tile:$pick")
    $one = @(Get-KeyLines (Read-Config) 'theme')
    Assert ([bool]$s.data.ok -and $pick.Length -gt 0 -and $one.Count -eq 1 -and $one[0] -match "^theme = $([regex]::Escape($pick))\s*$" -and [string]$s.data.theme.selected -eq $pick) "K: in One theme mode a tile click replaces the one theme ($($one -join ' | '))"
    [void](Invoke-Settings @('--op=shot', "--path=$shotGrid"))
    $s = Invoke-Settings @('--op=click', '--value=theme_mode:follow')
    Assert ([bool]$s.data.ok -and [bool]$s.data.theme.follows -and (Read-Config) -match '(?m)^theme = light:[^,\r\n]+,dark:[^,\r\n]+\r?$') "K: clicking Use's Light & dark segment switches to light & dark ($(@(Get-KeyLines (Read-Config) 'theme') -join ' | '))"
    [void](Invoke-Settings @('--op=shot', "--path=$shotGrid"))
    $s = Invoke-Settings @('--op=click', '--value=theme_mode:one')
    Assert ([bool]$s.data.ok -and -not [bool]$s.data.theme.follows -and @(Get-KeyLines (Read-Config) 'theme').Count -eq 1) "K: clicking Use's One theme segment goes back to one theme"
    $s = Invoke-Settings @('--op=reset', '--key=theme')
    Assert (@(Get-KeyLines (Read-Config) 'theme').Count -eq 0) 'K: Reset takes the theme back out of the file'

    # =====================================================================
    # L: the curated controls (T2681) - slider, stepper, megabytes, color,
    # flags, shell and folder each read and write the value text the parser
    # accepts. Every op is the function the control's gesture calls.
    # =====================================================================
    # Slider: Dim unfocused panes shows 1 - opacity as a percentage.
    $s = Invoke-Settings @('--op=state', '--page=panes')
    $dm = Find-Row $s 'unfocused-split-opacity'
    Assert ($dm -and [string]$dm.control -eq 'slider' -and [string]$dm.display -eq '30%') "L: Dim unfocused panes is a slider reading 30% for the default 0.7 opacity (control='$($dm.control)' display='$($dm.display)')"
    $s = Invoke-Settings @('--op=slide', '--key=unfocused-split-opacity', '--value=0.62')
    $dm = Find-Row $s 'unfocused-split-opacity'
    Assert ([bool]$s.data.ok -and (Read-Config) -match '(?m)^unfocused-split-opacity = 0\.6\r?$' -and [string]$dm.display -eq '40%') "L: releasing the slider at 0.62 snaps to the 0.05 step and writes 0.6, read as 40% (display='$($dm.display)')"
    # Only rows on screen paint (and so record hits): scroll each control
    # into view before photographing or clicking it.
    $shotL = Join-Path $work 'controls-panes.png'
    [void](Invoke-Settings @('--op=reveal', '--key=unfocused-split-opacity'))
    $s = Invoke-Settings @('--op=shot', "--path=$shotL")
    $sl = @($s.data.hits | Where-Object { $_.kind -eq 'slider' -and $_.key -eq 'unfocused-split-opacity' })
    Assert ($sl.Count -eq 1) "L: the page paints the slider's track ($($sl.Count))"
    [void](Invoke-Settings @('--op=reveal', '--key=macos-hero-carousel-ratio'))
    [void](Invoke-Settings @('--op=shot', "--path=$shotL"))
    $s = Invoke-Settings @('--op=click', '--value=slider:macos-hero-carousel-ratio')
    $cr = @(Get-KeyLines (Read-Config) 'macos-hero-carousel-ratio')
    Assert ([bool]$s.data.ok -and $cr.Count -eq 1 -and $cr[0] -match '= 0\.(3|35|4)\s*$') "L: clicking the middle of Carousel width's track writes the middle of its 0.1-0.6 range ($($cr -join ' | '))"
    [void](Invoke-Settings @('--op=reset', '--key=macos-hero-carousel-ratio'))
    [void](Invoke-Settings @('--op=reset', '--key=unfocused-split-opacity'))

    # Stepper: the arrows step by 5 inside 120..800; typing is range-checked.
    $s = Invoke-Settings @('--op=state', '--page=panes')
    $mw = Find-Row $s 'macos-pane-min-width'
    $base = [double]$mw.display
    Assert ($mw -and [string]$mw.control -eq 'stepper' -and $base -ge 120) "L: Stack panes narrower than is a stepper ($($mw.display))"
    $s = Invoke-Settings @('--op=step', '--key=macos-pane-min-width', '--value=up')
    $want = [string]([int]($base + 5))
    Assert ([bool]$s.data.ok -and (Read-Config) -match "(?m)^macos-pane-min-width = $want\r?$") "L: the up arrow writes one step more ($want)"
    $mid = Read-Config
    $s = Invoke-Settings @('--op=set', '--key=macos-pane-min-width', '--value=90')
    $mw = Find-Row $s 'macos-pane-min-width'
    Assert (-not [bool]$s.data.ok -and [string]$mw.problem -eq 'Enter a number from 120 to 800' -and (Read-Config) -eq $mid) "L: typing 90 is refused with Mac's range problem and writes nothing ('$($mw.problem)')"
    $s = Invoke-Settings @('--op=set', '--key=macos-pane-min-width', '--value=300')
    Assert ([bool]$s.data.ok -and (Read-Config) -match '(?m)^macos-pane-min-width = 300\r?$' -and $null -eq (Find-Row $s 'macos-pane-min-width').problem) 'L: typing 300 writes it and clears the problem'
    [void](Invoke-Settings @('--op=reset', '--key=macos-pane-min-width'))

    # Megabytes: scrollback-limit reads and writes in MB.
    $s = Invoke-Settings @('--op=state', '--page=terminal')
    $sb = Find-Row $s 'scrollback-limit'
    Assert ($sb -and [string]$sb.control -eq 'megabytes' -and [string]$sb.display -eq '10') "L: Scrollback size reads the default 10000000 bytes as 10 MB (display='$($sb.display)')"
    $s = Invoke-Settings @('--op=set', '--key=scrollback-limit', '--value=25')
    $sb = Find-Row $s 'scrollback-limit'
    Assert ([bool]$s.data.ok -and (Read-Config) -match '(?m)^scrollback-limit = 25000000\r?$' -and [string]$sb.display -eq '25') "L: typing 25 MB writes 25000000 bytes and reads back as 25 (display='$($sb.display)')"
    $mid = Read-Config
    $s = Invoke-Settings @('--op=set', '--key=scrollback-limit', '--value=5000')
    $sb = Find-Row $s 'scrollback-limit'
    Assert (-not [bool]$s.data.ok -and [string]$sb.problem -eq 'Enter a size in megabytes, 0 to 4096' -and (Read-Config) -eq $mid) "L: 5000 MB is refused with Mac's problem ('$($sb.problem)')"
    [void](Invoke-Settings @('--op=reset', '--key=scrollback-limit'))

    # Shell: the default label, a missing program refused, a real one written.
    $s = Invoke-Settings @('--op=state', '--page=terminal')
    $sh = Find-Row $s 'command'
    Assert ($sh -and [string]$sh.control -eq 'shell' -and [string]$sh.display -eq 'Default shell (cmd.exe)') "L: Shell reads its Windows default (display='$($sh.display)')"
    $mid = Read-Config
    $s = Invoke-Settings @('--op=shell', '--key=command', '--value=zzznotashell -l')
    $sh = Find-Row $s 'command'
    Assert (-not [bool]$s.data.ok -and [string]$sh.problem -eq "zzznotashell isn't on your PATH." -and (Read-Config) -eq $mid) "L: a program that is not on PATH is refused with Mac's problem ('$($sh.problem)')"
    $s = Invoke-Settings @('--op=shell', '--key=command', '--value=cmd.exe /K')
    $sh = Find-Row $s 'command'
    Assert ([bool]$s.data.ok -and (Read-Config) -match '(?m)^command = cmd\.exe /K\r?$' -and [string]$sh.display -eq 'cmd.exe /K' -and $null -eq $sh.problem) "L: cmd.exe /K is found on PATH and written (display='$($sh.display)')"
    $cs = Find-Row $s 'command-shell'
    Assert ($cs -and [string]$cs.display -eq 'The --shell flag, else cmd.exe') "L: Shell for scripted windows names its fallback (display='$($cs.display)')"
    [void](Invoke-Settings @('--op=reset', '--key=command'))

    # Folder: Home / Where Ghoztty was launched / a folder shown with ~.
    $s = Invoke-Settings @('--op=state', '--page=terminal')
    $wd = Find-Row $s 'working-directory'
    Assert ($wd -and [string]$wd.control -eq 'folder' -and [string]$wd.display -eq 'Home folder') "L: Start new windows in reads Home folder when unset (display='$($wd.display)')"
    $s = Invoke-Settings @('--op=choose', '--key=working-directory', '--value=inherit')
    $wd = Find-Row $s 'working-directory'
    Assert ([bool]$s.data.ok -and (Read-Config) -match '(?m)^working-directory = inherit\r?$' -and [string]$wd.display -eq 'Where Ghoztty was launched') "L: Where Ghoztty was launched writes inherit (display='$($wd.display)')"
    $folder = Join-Path $env:USERPROFILE 'Documents'
    $s = Invoke-Settings @('--op=choose', '--key=working-directory', "--value=$folder")
    $wd = Find-Row $s 'working-directory'
    Assert ([bool]$s.data.ok -and [string]$wd.display -eq '~\Documents') "L: a chosen folder under the profile reads as ~\Documents (display='$($wd.display)')"
    $s = Invoke-Settings @('--op=choose', '--key=working-directory', '--value=')
    Assert (@(Get-KeyLines (Read-Config) 'working-directory').Count -eq 0) 'L: Home folder takes the key back out of the file'

    # Flags: shell integration features as checkboxes, every flag written.
    $s = Invoke-Settings @('--op=state', '--page=terminal')
    $fl = Find-Row $s 'shell-integration-features'
    $names = @($fl.flags | ForEach-Object { [string]$_.name })
    $sudo0 = @($fl.flags | Where-Object { $_.name -eq 'sudo' })[0]
    Assert ($fl -and [string]$fl.control -eq 'flags' -and ($names -contains 'cursor') -and ($names -contains 'sudo') -and $sudo0 -and -not [bool]$sudo0.on) "L: Features lists the schema's flags with sudo off by default ($($names -join ','))"
    $s = Invoke-Settings @('--op=flag', '--key=shell-integration-features', '--value=sudo:true')
    $line = @(Get-KeyLines (Read-Config) 'shell-integration-features')
    $fl = Find-Row $s 'shell-integration-features'
    $sudo1 = @($fl.flags | Where-Object { $_.name -eq 'sudo' })[0]
    $explicit = ($line.Count -eq 1) -and ($names | Where-Object { $line[0] -notmatch "(^|[ ,=])(no-)?$([regex]::Escape($_))(,|\s*$)" }).Count -eq 0
    Assert ([bool]$s.data.ok -and $line.Count -eq 1 -and $line[0] -match '[ ,=]sudo(,|\s*$)' -and $line[0] -notmatch 'no-sudo' -and $sudo1 -and [bool]$sudo1.on) "L: ticking sudo turns it on ($($line -join ' | '))"
    Assert ($explicit) "L: ...and writes every flag explicitly, as Mac's ($($line -join ' | '))"
    [void](Invoke-Settings @('--op=reset', '--key=shell-integration-features'))

    # Color: unset reads the default's name; a pick writes #rrggbb; Use <x>
    # takes it out again.
    $s = Invoke-Settings @('--op=state', '--page=appearance')
    $cc = Find-Row $s 'cursor-color'
    Assert ($cc -and [string]$cc.control -eq 'color' -and [string]$cc.display -eq 'Theme') "L: Cursor color reads Theme when unset (display='$($cc.display)')"
    $s = Invoke-Settings @('--op=color', '--key=cursor-color', '--value=#FF8800')
    $cc = Find-Row $s 'cursor-color'
    Assert ([bool]$s.data.ok -and (Read-Config) -match '(?m)^cursor-color = #ff8800\r?$' -and [string]$cc.display -eq '#ff8800') "L: the color dialog's pick writes #ff8800 (display='$($cc.display)')"
    $shotC = Join-Path $work 'controls-appearance.png'
    [void](Invoke-Settings @('--op=reveal', '--key=cursor-color'))
    $s = Invoke-Settings @('--op=shot', "--path=$shotC")
    $useLink = @($s.data.hits | Where-Object { $_.kind -eq 'color_reset' -and $_.key -eq 'cursor-color' })
    $well = @($s.data.hits | Where-Object { $_.kind -eq 'color_well' -and $_.key -eq 'cursor-color' })
    Assert ($useLink.Count -eq 1 -and $well.Count -eq 1) "L: a set color paints its well and the Use Theme link (well=$($well.Count) link=$($useLink.Count))"
    $s = Invoke-Settings @('--op=click', '--value=color_reset:cursor-color')
    Assert ([bool]$s.data.ok -and @(Get-KeyLines (Read-Config) 'cursor-color').Count -eq 0) 'L: clicking Use Theme takes cursor-color back out of the file'
    [void](Invoke-Settings @('--op=reveal', '--key=shell-integration-features'))
    $s = Invoke-Settings @('--op=shot', "--path=$shotL")
    $fh = @($s.data.hits | Where-Object { $_.kind -eq 'flag' -and $_.key -eq 'shell-integration-features' })
    Assert ($fh.Count -eq $names.Count) "L: Features paints one checkbox per flag ($($fh.Count) of $($names.Count))"
    $popups = 0
    foreach ($k in @('command', 'working-directory')) {
        [void](Invoke-Settings @('--op=reveal', "--key=$k"))
        $s = Invoke-Settings @('--op=shot', "--path=$shotL")
        $popups += @($s.data.hits | Where-Object { $_.kind -eq 'choice' -and $_.key -eq $k }).Count
    }
    Assert ($popups -eq 2) "L: Shell and Start new windows in paint as popups ($popups of 2)"

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
    # GHOZTTY_SETTINGS_SHOTS=<dir> keeps the page photographs for an eye
    # check against Mac's (T2682's theme grid); they go with $work otherwise.
    if ($env:GHOZTTY_SETTINGS_SHOTS -and (Test-Path $work)) {
        New-Item -ItemType Directory -Force -Path $env:GHOZTTY_SETTINGS_SHOTS | Out-Null
        Copy-Item -Path (Join-Path $work '*.png') -Destination $env:GHOZTTY_SETTINGS_SHOTS -Force -ErrorAction SilentlyContinue
    }
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
