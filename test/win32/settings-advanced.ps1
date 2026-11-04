# T2676 acceptance: the rest of Settings > Advanced and the change toast -
# Mac's ConfigFileSection and SettingsToast (docs/reference/settings.md,
# Mac 9287de0ff) on Windows. Advanced shows the file Settings writes with Open
# in Editor and Show in Explorer, every other file Ghostty loads in load order
# (tagged "also loaded" / "included", each with Open), Backups with Restore...,
# and the Current file disclosure; every write raises the "Saved ... - applied
# live - Show Change - Undo" toast, which times out unless expanded; Restore
# puts a backup back and is itself undoable; and Undo after an outside edit
# refuses with Mac's "The config file changed since" and leaves the file alone.
#
# THE ORACLE IS THE MODEL AND THE FILE. What the section lists and what the
# toast offers are read through the debug-only `settings` IPC action
# (src/apprt/win32/ipc_settings.zig), whose ops call the same functions the
# window's clicks call, and by reading the config file itself. What a button
# would launch is read from the window's GHOZTTY_SETTINGS_SHELL_DRY record, so
# no editor or Explorer window ever opens.
#
# THE CONFIG IS DRIVEN: XDG_CONFIG_HOME points at a temp dir holding this dev
# build's own config-debug.ghostty (font-size = 13, an include), the XDG
# config.ghostty (loaded before it), and an include chain later.ghostty ->
# nested.ghostty, so "also loaded", "included" and load order are all
# reachable. GHOZTTY_SETTINGS_BACKUP_DIR keeps backups out of the box's own.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never
# steals the user's foreground.
#
# -NegativeControl inverts a load-bearing claim (an Undo over an outside edit
# leaves the file alone) - that run MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-settingsadv$PID"

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

function Read-Config {
    if (-not (Test-Path $cfgFile)) { return '' }
    return [System.IO.File]::ReadAllText($cfgFile)
}

function Norm([string]$p) { return ($p -replace '/', '\').ToLowerInvariant() }

$work = Join-Path $env:TEMP "ghoztty-settingsadv-$PID"
$cfgHome = Join-Path $work 'xdg'
$cfgDir = Join-Path $cfgHome 'ghostty'
$cfgFile = Join-Path $cfgDir 'config-debug.ghostty'
$xdgFile = Join-Path $cfgDir 'config.ghostty'
$laterFile = Join-Path $cfgDir 'later.ghostty'
$nestedFile = Join-Path $cfgDir 'nested.ghostty'
$backupDir = Join-Path $work 'backups'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
$original = "font-size = 13`nconfig-file = later.ghostty`n"
[System.IO.File]::WriteAllText($cfgFile, $original)
[System.IO.File]::WriteAllText($xdgFile, "# the XDG file, loaded before this build's own`n")
[System.IO.File]::WriteAllText($laterFile, "cursor-style = bar`nconfig-file = nested.ghostty`n")
[System.IO.File]::WriteAllText($nestedFile, "cursor-style-blink = false`n")

$errlog = Join-Path $env:TEMP 'ghoztty-settings-advanced-stderr.log'
$script:launched = @()
$app = $null

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: section E asserts the refused Undo DID change the file - this run MUST fail"
    }
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_SETTINGS_BACKUP_DIR = $backupDir
    $env:GHOZTTY_SETTINGS_SHELL_DRY = '1'
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
        Remove-Item Env:GHOZTTY_SETTINGS_SHELL_DRY -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if (-not $app -or ($app.Process -and $app.Process.HasExited)) {
        Write-TestAssertedNothing -Reason 'GUI did not come up' -Label 'settings-advanced'
        exit 1
    }
    $script:launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'no terminal window appeared' -Label 'settings-advanced'
        exit 1
    }

    $s = Invoke-Settings @('--op=action')
    if ($null -eq $s -or -not $s.success -or $null -eq $s.data.advanced) {
        Write-TestAssertedNothing -Reason 'the settings IPC action never answered with the Advanced state' -Label 'settings-advanced'
        exit 1
    }
    # Keep the toast up while each section reads it; section F times it out.
    $s = Invoke-Settings @('--op=toast_ms', '--value=600000')

    # =====================================================================
    # A: Advanced lists the file, its siblings in load order, and backups.
    # =====================================================================
    $s = Invoke-Settings @('--op=state', '--page=advanced')
    $customs = @($s.data.customs) -join ','
    Assert ($customs -eq 'config_file,all_settings') "A: Advanced lays out Config file, then All settings (Mac's order) ($customs)"
    $adv = $s.data.advanced
    Assert ((Norm $adv.path) -eq (Norm $cfgFile)) "A: it shows the file Settings writes (path='$($adv.path)')"
    $srcs = @($adv.sources)
    $names = @($srcs | ForEach-Object { [string]$_.name }) -join ','
    Assert ($names -eq 'config.ghostty,later.ghostty,nested.ghostty') "A: every other file Ghostty loads is listed, in load order ($names)"
    $kinds = @($srcs | ForEach-Object { [string]$_.kind }) -join ','
    Assert ($kinds -eq 'also loaded,included,included') "A: the XDG file is 'also loaded' and both includes 'included' ($kinds)"
    Assert (@($adv.backups).Count -eq 0 -and -not [bool]$adv.backed_up) 'A: no backups yet, and none made this session'
    Assert ($null -eq $s.data.toast) 'A: no toast before any change'

    $s = Invoke-Settings @('--op=open_editor')
    Assert ((Norm $s.data.advanced.last_shell) -eq (Norm "open $cfgFile")) "A: Open in Editor opens the config file (launched '$($s.data.advanced.last_shell)')"
    $s = Invoke-Settings @('--op=reveal_file')
    Assert ((Norm $s.data.advanced.last_shell) -eq (Norm "explorer.exe /select,`"$cfgFile`"")) "A: Show in Explorer selects it in its folder ('$($s.data.advanced.last_shell)')"
    $s = Invoke-Settings @('--op=open_source', '--index=2')
    Assert ((Norm $s.data.advanced.last_shell) -eq (Norm "open $nestedFile")) "A: an include's Open opens that file ('$($s.data.advanced.last_shell)')"
    $s = Invoke-Settings @('--op=backups_folder')
    Assert ((Norm $s.data.advanced.last_shell) -eq (Norm "open $backupDir")) "A: Show Backups in Explorer opens the backup folder ('$($s.data.advanced.last_shell)')"

    # =====================================================================
    # B: a write raises the toast; Show Change and dismiss.
    # =====================================================================
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=15')
    Assert ([bool]$s.data.ok) 'B: setting font-size to 15 succeeds'
    $t = $s.data.toast
    Assert ($null -ne $t -and [string]$t.message -eq 'Saved font-size') "B: the toast says what changed (message='$($t.message)')"
    Assert ($t -and [string]$t.detail -eq "applied live $([char]0x00B7) backed up first") "B: ...applied live, backed up first (the session's first write) ('$($t.detail)')"
    Assert ($t -and (@($t.removed) -join '|') -eq 'font-size = 13' -and (@($t.added) -join '|') -eq 'font-size = 15') "B: the change is the one line, before and after (-$(@($t.removed) -join '|') +$(@($t.added) -join '|'))"
    $s = Invoke-Settings @('--op=show_change')
    Assert ([bool]$s.data.toast.expanded) 'B: Show Change expands the toast'
    $s = Invoke-Settings @('--op=show_change')
    Assert (-not [bool]$s.data.toast.expanded) 'B: ...and Hide Change collapses it'
    $s = Invoke-Settings @('--op=dismiss')
    Assert ($null -eq $s.data.toast) 'B: the x dismisses it'
    $adv = $s.data.advanced
    Assert ([bool]$adv.backed_up -and @($adv.backups).Count -eq 1) "B: Backups now lists this session's copy ($(@($adv.backups).Count))"
    $label = if (@($adv.backups).Count -ge 1) { [string]@($adv.backups)[0].label } else { '' }
    Assert ($label -match '^[A-Z][a-z]{2} \d{1,2}, \d{4} at \d{1,2}:\d{2} [AP]M$') "B: ...as a date, Mac's way ('$label')"

    # =====================================================================
    # C: Undo puts the file back.
    # =====================================================================
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=16')
    $before16 = Read-Config
    $s = Invoke-Settings @('--op=undo')
    Assert ([string]$s.data.undo -eq 'undone' -and $null -eq $s.data.toast) "C: Undo reverts the last change and the toast goes (undo='$($s.data.undo)')"
    Assert ((Read-Config) -match '(?m)^font-size = 15\s*$' -and (Read-Config) -ne $before16) 'C: the file is back at font-size = 15'

    # =====================================================================
    # D: Restore puts a backup back, and the toast can undo it.
    # =====================================================================
    $mid = Read-Config
    $s = Invoke-Settings @('--op=restore', '--index=0')
    Assert ([bool]$s.data.ok) 'D: restoring the newest backup succeeds'
    Assert ((Read-Config) -eq $original) "D: the file is the backed-up copy again ($((Read-Config).Trim() -replace "`n", ' | '))"
    $t = $s.data.toast
    Assert ($t -and ([string]$t.message) -like 'Restored config-debug.ghostty.*') "D: the toast names the restore (message='$($t.message)')"
    $s = Invoke-Settings @('--op=undo')
    Assert ([string]$s.data.undo -eq 'undone' -and (Read-Config) -eq $mid) "D: the toast's Undo puts the pre-restore file back (undo='$($s.data.undo)')"

    # =====================================================================
    # E: Undo after an outside edit refuses and leaves the file alone.
    # =====================================================================
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=18')
    Assert ([bool]$s.data.ok -and $null -ne $s.data.toast) 'E: a write raises the toast'
    $outside = (Read-Config) + "window-padding-x = 7`n"
    [System.IO.File]::WriteAllText($cfgFile, $outside)
    $s = Invoke-Settings @('--op=undo')
    Assert ([string]$s.data.undo -eq 'changed_since') "E: Undo after an editor saved the file is refused (undo='$($s.data.undo)')"
    Assert ([string]$s.data.advanced.file_error -like 'The config file changed since*') "E: ...with Mac's words (file_error='$($s.data.advanced.file_error)')"
    Assert ($s.data.toast -and [bool]$s.data.toast.refused) 'E: the toast stays up and says it was refused'
    $script:negReached = $true
    $wantSame = -not $NegativeControl
    Assert (((Read-Config) -eq $outside) -eq $wantSame) 'E: the outside edit is left exactly as saved'
    $s = Invoke-Settings @('--op=dismiss')

    # =====================================================================
    # F: the toast times out - unless it is expanded.
    # =====================================================================
    $s = Invoke-Settings @('--op=toast_ms', '--value=700')
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=19')
    Assert ($null -ne $s.data.toast) 'F: a write raises the toast'
    Start-Sleep -Milliseconds 2500
    $s = Invoke-Settings @('--op=state')
    Assert ($null -eq $s.data.toast) 'F: left alone, it goes by itself'
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=20')
    $s = Invoke-Settings @('--op=show_change')
    Start-Sleep -Milliseconds 2500
    $s = Invoke-Settings @('--op=state')
    Assert ($null -ne $s.data.toast -and [bool]$s.data.toast.expanded) 'F: an expanded toast stays until dismissed'
    [void](Invoke-Settings @('--op=dismiss'))

    # =====================================================================
    # F2 (T2684): a timed-out toast slides down and fades, as Mac's
    # withAnimation { dismissLastChange() } over .move(edge: .bottom) +
    # .opacity does; with Windows' animations off it just goes. The oracle
    # is the frames the window actually painted ([drop px, alpha]).
    # =====================================================================
    [void](Invoke-Settings @('--op=toast_motion', '--value=on'))
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=21')
    Assert ($null -ne $s.data.toast -and -not [bool]$s.data.toast.leaving) 'F2: a write raises the toast at rest (it appears without motion, as on Mac)'
    $sawLeaving = $false
    $deadline = (Get-Date).AddMilliseconds(3000)
    while ((Get-Date) -lt $deadline) {
        $s = Invoke-Settings @('--op=state')
        if ($s.data.toast -and [bool]$s.data.toast.leaving) { $sawLeaving = $true }
        if ($null -eq $s.data.toast) { break }
        Start-Sleep -Milliseconds 40
    }
    $m = $s.data.toast_motion
    $frames = @($m.frames | ForEach-Object { , @([int]$_[0], [int]$_[1]) })
    Assert ($null -eq $s.data.toast) 'F2: the timed-out toast is gone at the end'
    Assert $sawLeaving 'F2: ...and was seen leaving on the way (toast.leaving)'
    Assert ([bool]$m.completed -and -not [bool]$m.instant) "F2: the exit ran to its end (completed=$($m.completed) instant=$($m.instant))"
    Assert ($frames.Count -ge 3) "F2: the exit painted several frames ($($frames.Count))"
    $mono = $true
    for ($i = 1; $i -lt $frames.Count; $i++) {
        if ($frames[$i][0] -lt $frames[$i - 1][0] -or $frames[$i][1] -gt $frames[$i - 1][1]) { $mono = $false }
    }
    Assert $mono "F2: every frame is lower and fainter than the last ($(($frames | ForEach-Object { "$($_[0])/$($_[1])" }) -join ' '))"
    $between = @($frames | Where-Object { $_[0] -gt 0 -and $_[1] -gt 0 -and $_[1] -lt 255 })
    Assert ($between.Count -ge 1) 'F2: some frame is part-way down and part-faded (it moves, not jumps)'

    [void](Invoke-Settings @('--op=toast_motion', '--value=off'))
    $s = Invoke-Settings @('--op=set', '--key=font-size', '--value=22')
    Start-Sleep -Milliseconds 1500
    $s = Invoke-Settings @('--op=state')
    $m = $s.data.toast_motion
    Assert ($null -eq $s.data.toast -and -not [bool]$m.animates) 'F2: with animations off the toast still times out'
    Assert ([bool]$m.instant -and @($m.frames).Count -eq 0) "F2: ...instantly, painting no exit frames (instant=$($m.instant) frames=$(@($m.frames).Count))"
    $bad = Invoke-Settings @('--op=toast_motion', '--value=sometimes')
    Assert ($null -ne $bad -and -not $bad.success) 'F2: a toast_motion other than on/off/system is refused'
    [void](Invoke-Settings @('--op=toast_motion', '--value=system'))
    $s = Invoke-Settings @('--op=toast_ms', '--value=600000')

    # =====================================================================
    # G: the Current file disclosure, search, and the page paints.
    # =====================================================================
    $s = Invoke-Settings @('--op=current_file', '--page=advanced')
    Assert ([bool]$s.data.advanced.show_file) 'G: Current file opens'
    $shot = Join-Path $work 'advanced.png'
    $s = Invoke-Settings @('--op=shot', "--path=$shot")
    Assert ($s.success -and (Test-Path $shot) -and (Get-Item $shot).Length -gt 4000) 'G: Advanced with the toast and the file renders to a PNG'
    $s = Invoke-Settings @('--op=current_file')
    Assert (-not [bool]$s.data.advanced.show_file) 'G: ...and closes'
    $s = Invoke-Settings @('--op=state', '--query=backup')
    Assert (@($s.data.customs) -contains 'config_file') "G: searching 'backup' finds the Config file section ($(@($s.data.customs) -join ','))"
    [void](Invoke-Settings @('--op=state', '--query='))

    $bad = Invoke-Settings @('--op=toast_ms', '--value=soon')
    Assert ($null -ne $bad -and -not $bad.success) 'G: a non-number toast time is refused'
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
        update -Guard settings-advanced -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'settings-advanced'
