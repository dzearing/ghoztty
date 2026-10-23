# T70 acceptance: the GUI self-heals the user PATH (HKCU\Environment\Path)
# so `ghoztty` resolves from any shell — the Windows analog of macOS
# CommandLineInstaller. PathInstaller.zig runs at App.init on a background
# thread; any real copy heals (T2169: the installed release and a portable
# unpack, never build output or a zip preview, never a Debug build), and
# GHOZTTY_PATH_SELFHEAL=force bypasses the gates so this script can exercise
# the flow with the zig-out debug build.
#
# Cases:
#   A gate:      launch with no env var (a Debug build) -> Path untouched,
#                nothing recorded.
#   B heal:      launch with =force on a Path missing the exe dir -> the dir
#                is appended, exactly once, value prefix + registry value
#                kind preserved. (Also the positive control proving the
#                mechanism works, so A/C/D/E no-writes are meaningful.)
#   C idempotent: relaunch with =force -> value byte-identical.
#   D variants:  entry already present as quoted + trailing-backslash +
#                different case -> not added again.
#   E %VAR%:     entry present only as an unexpanded %VAR% form -> detected
#                via expansion, not added again.
#   F ahead:     the installed release's entry present -> ours is inserted
#                just before it, so the copy launched last wins (T2169).
#   G re-point:  an earlier copy's RECORDED entry is replaced in place; the
#                install's (MSI) entry stays, exactly once.
#   H no-dup:    relaunching the owner -> byte-identical.
#   I hand-added: the same Path with nothing recorded -> the other entry is
#                not ours and stays (G's negative control).
#
# The REAL user Path is used as the base (never replaced wholesale — new
# shells during the run must keep working); the original value + kind are
# restored in a finally block. Only touches ghoztty processes running from
# this repo's zig-out.

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T1241: the GUI launches on the background test desktop, not the user's.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
$ErrorActionPreference = 'Stop'
# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches, and a pane-launched app would otherwise hand its work to
# a respawned twin mid-test.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
# T680: no CLI verbs run here, but each Launch-Gui starts a real GUI. A private
# suffix keeps that launch from single-instance-forwarding a new window into
# any other zig-out instance that happens to be alive (a leaked test instance,
# a concurrent lane) instead of coming up on its own.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'selfheal')
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
# T1033: a private pipe suffix moves the APP endpoint only - the agent pipe and
# the state files stay build-mode derived - so the exe about to be launched is
# checked for the -debug lineage before the first launch, not assumed.
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
$exeDir = Split-Path $exe -Parent

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Get-UserPathRaw {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        try {
            $kind = $k.GetValueKind('Path')
            $val = [string]$k.GetValue('Path', '',
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } catch { $kind = $null; $val = $null }
        [pscustomobject]@{ Value = $val; Kind = $kind }
    } finally { $k.Close() }
}

function Set-UserPathRaw([string]$value, $kind) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try { $k.SetValue('Path', $value, $kind) } finally { $k.Close() }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# Launch the GUI, give the self-heal thread time to run, kill it. Returns
# $true if the process survived (didn't crash at init).
function Launch-Gui([string]$healEnv) {
    Kill-RepoInstances
    if ($null -ne $healEnv) { $env:GHOZTTY_PATH_SELFHEAL = $healEnv }
    try {
        # persistence: off. This helper launches and kills the GUI several times
        # in a row; with it on, each launch writes the manifest the NEXT one
        # restores, so the later arms start with panes the self-heal check never
        # asked for (T158).
        # T1241: on the TEST desktop, so the window this throws up does not land
        # across whatever the user is reading. The env var above still reaches it -
        # StartProcess passes a null lpEnvironment, so the child inherits ours.
        $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    } finally {
        Remove-Item Env:GHOZTTY_PATH_SELFHEAL -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    $alive = -not $app.Process.HasExited
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    return $alive
}

# Poll until the raw user Path contains $needle (substring), up to $secs.
function Wait-PathContains([string]$needle, [int]$secs) {
    for ($t = 0; $t -lt $secs * 4; $t++) {
        if ((Get-UserPathRaw).Value -like "*$needle*") { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# T2169: the entry is ONE owned value, recorded here (the debug lineage's name,
# so this run never moves the release record), and placed ahead of the
# installed release's entry, which the MSI owns and nothing may remove.
$ownerKey = 'HKCU:\Software\Ghoztty'
$ownerValue = 'PathEntry-debug'
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty'
$oldCopy = 'C:\ghoztty-t2169-old-copy\Ghoztty'

function Get-Owned {
    if (-not (Test-Path $ownerKey)) { return $null }
    $p = Get-ItemProperty $ownerKey -Name $ownerValue -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return [string]$p.$ownerValue
}
# Untyped on purpose: a [string] parameter turns $null into "" (PS5.1), which
# would record an empty owner instead of removing the value.
function Set-Owned($value) {
    if ($null -eq $value) {
        if (Test-Path $ownerKey) { Remove-ItemProperty $ownerKey -Name $ownerValue -ErrorAction SilentlyContinue }
        return
    }
    if (-not (Test-Path $ownerKey)) { New-Item $ownerKey -Force | Out-Null }
    Set-ItemProperty $ownerKey -Name $ownerValue -Value $value -Type String
}
function Count-Entries([string]$value, [string]$dir) {
    @(($value -split ';') | Where-Object { $_.Trim().Trim('"').TrimEnd('\') -eq $dir.TrimEnd('\') }).Count
}

# Poll until the owned-entry record reads $want, up to $secs.
function Wait-Owned([string]$want, [int]$secs) {
    for ($t = 0; $t -lt $secs * 4; $t++) {
        if ((Get-Owned) -eq $want) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$td = New-TestDesktop

$orig = Get-UserPathRaw
if ($null -eq $orig.Kind) {
    Write-Host 'SETUP FAIL: user Path value absent — refusing to run against a profile with no PATH'
    exit 1
}
$origOwned = Get-Owned
$ownerKeyExisted = Test-Path $ownerKey

# Base value for the tests: the real Path minus any existing zig-out entry
# (normally none; guards a re-run after an aborted script), minus the installed
# release's entry (the cases that need one add it back, so where the heal
# places its entry is measured rather than inherited from the box), and minus
# a trailing separator, so an appended or inserted entry has one known shape.
$base = ((($orig.Value -split ';') | Where-Object {
    $e = $_.Trim().Trim('"').TrimEnd('\')
    $e -ne $exeDir -and $e -ne $installDir -and $e -ne $oldCopy
}) -join ';').TrimEnd(';')

try {
    # --- A: build-mode gate - no env var, a Debug build -> no write, as on Mac.
    Set-UserPathRaw $base $orig.Kind
    Set-Owned $null
    $alive = Launch-Gui $null
    Assert $alive 'A gate: GUI survived launch'
    Assert ((Get-UserPathRaw).Value -eq $base) 'A gate: Path untouched (Debug build, no force)'
    Assert ($null -eq (Get-Owned)) 'A gate: no owned entry recorded'

    # --- B: forced heal on a Path missing the entry.
    Set-UserPathRaw $base $orig.Kind
    $alive = Launch-Gui 'force'
    Assert $alive 'B heal: GUI survived launch'
    Assert (Wait-PathContains $exeDir 10) 'B heal: exe dir appeared on the user Path'
    $after = Get-UserPathRaw
    $expected = if ($base.TrimEnd() -match ';$') { "$($base.TrimEnd())$exeDir" } else { "$base;$exeDir" }
    Assert ($after.Value -eq $expected) 'B heal: appended exactly once at the end, prefix intact'
    Assert ($after.Kind -eq $orig.Kind) 'B heal: registry value kind preserved'
    Assert (Wait-Owned $exeDir 5) 'B heal: the entry is recorded as owned'

    # --- C: idempotent — entry already present verbatim -> byte-identical.
    $healed = (Get-UserPathRaw).Value
    $alive = Launch-Gui 'force'
    Assert $alive 'C idempotent: GUI survived launch'
    Assert ((Get-UserPathRaw).Value -eq $healed) 'C idempotent: Path byte-identical after relaunch'

    # --- D: entry present as quoted + trailing backslash + different case.
    $variant = $base + ';"' + $exeDir.ToUpper() + '\"'
    Set-UserPathRaw $variant $orig.Kind
    $alive = Launch-Gui 'force'
    Assert $alive 'D variants: GUI survived launch'
    Assert ((Get-UserPathRaw).Value -eq $variant) 'D variants: quoted/case/trailing-backslash form detected, no duplicate'

    # --- E: entry present only as an unexpanded %VAR% form.
    $env:GHOZTTY_T70_DIR = $exeDir
    $varform = $base + ';%GHOZTTY_T70_DIR%'
    Set-UserPathRaw $varform $orig.Kind
    $alive = Launch-Gui 'force'
    Remove-Item Env:GHOZTTY_T70_DIR -ErrorAction SilentlyContinue
    Assert $alive 'E %VAR%: GUI survived launch'
    Assert ((Get-UserPathRaw).Value -eq $varform) 'E %VAR%: expanded form detected, no duplicate'

    # --- F (T2169): a copy other than the install goes AHEAD of the install's
    # entry, so the copy launched last is the one `ghoztty` resolves to.
    $withInstall = "$base;$installDir"
    Set-UserPathRaw $withInstall $orig.Kind
    Set-Owned $null
    $alive = Launch-Gui 'force'
    Assert $alive 'F ahead: GUI survived launch'
    Assert (Wait-PathContains $exeDir 10) 'F ahead: exe dir appeared on the user Path'
    Assert ((Get-UserPathRaw).Value -eq "$base;$exeDir;$installDir") 'F ahead: inserted just before the install entry'

    # --- G (T2169): the last launch re-points the owned entry. An earlier
    # copy's RECORDED entry is dropped; the install's entry stays exactly once.
    $stale = "$base;$oldCopy;$installDir"
    Set-UserPathRaw $stale $orig.Kind
    Set-Owned $oldCopy
    $alive = Launch-Gui 'force'
    Assert $alive 'G re-point: GUI survived launch'
    Assert (Wait-PathContains $exeDir 10) 'G re-point: exe dir appeared on the user Path'
    $g = (Get-UserPathRaw).Value
    Assert ($g -eq "$base;$exeDir;$installDir") 'G re-point: previous owned entry replaced in place'
    Assert ((Count-Entries $g $oldCopy) -eq 0) 'G re-point: the earlier copy''s entry is gone'
    Assert ((Count-Entries $g $installDir) -eq 1) 'G re-point: the install (MSI) entry untouched, exactly once'
    Assert (Wait-Owned $exeDir 5) 'G re-point: the record now names this copy'

    # --- H (T2169): relaunching the owner never duplicates it.
    $alive = Launch-Gui 'force'
    Assert $alive 'H no-dup: GUI survived launch'
    $h = (Get-UserPathRaw).Value
    Assert ($h -eq $g) 'H no-dup: Path byte-identical after relaunch'
    Assert ((Count-Entries $h $exeDir) -eq 1) 'H no-dup: exactly one entry for this copy'

    # --- I (T2169): an entry nobody recorded is not ours to remove.
    $handAdded = "$base;$oldCopy;$installDir"
    Set-UserPathRaw $handAdded $orig.Kind
    Set-Owned $null
    $alive = Launch-Gui 'force'
    Assert $alive 'I hand-added: GUI survived launch'
    Assert (Wait-PathContains $exeDir 10) 'I hand-added: exe dir appeared on the user Path'
    Assert ((Get-UserPathRaw).Value -eq "$base;$oldCopy;$exeDir;$installDir") 'I hand-added: unrecorded entry kept, ours placed ahead of the install'
} finally {
    Kill-RepoInstances
    Set-UserPathRaw $orig.Value $orig.Kind
    Set-Owned $origOwned
    # The app creates the key on its first record; a box that had none gets
    # none back, or the run leaves durable state behind (T1230).
    if (-not $ownerKeyExisted -and (Test-Path $ownerKey) -and
        @((Get-Item $ownerKey).GetValueNames()).Count -eq 0 -and
        @((Get-Item $ownerKey).GetSubKeyNames()).Count -eq 0) {
        Remove-Item $ownerKey -ErrorAction SilentlyContinue
    }
    Remove-Item Env:GHOZTTY_T70_DIR -ErrorAction SilentlyContinue
    Remove-TestDesktop | Out-Null
}

$restored = Get-UserPathRaw
Assert ($restored.Value -eq $orig.Value -and $restored.Kind -eq $orig.Kind) 'cleanup: original user Path restored'
Assert ((Get-Owned) -eq $origOwned) 'cleanup: original owned-entry record restored'

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
