# T1789 acceptance: a config reload applies `background-opacity` to OPEN windows.
#
# Mac re-runs `syncAppearance` on reload, so changing background-opacity makes
# every open window translucent (or opaque) at once. Windows applied it only at
# window creation: `setTranslucent` ran in Window.init and from the toggle, and
# `Window.onConfigChange` never called it, so 1.0 -> 0.6 left every open window
# opaque until it was closed and a new one opened. The viewer host had the same
# gap one level down - it is composed as an opaque layer only when created under
# a translucent config, so a viewer opened at 1.0 would paint its chrome
# invisible once the window turned translucent.
#
# THE ORACLE. The pixel half - "does the desktop show through" - is DWM's
# composite, which exists only on the input desktop, and that is
# translucent-window.ps1's job (an input-desktop exception). What a background
# desktop CAN observe is the product's own decision: `Window.setTranslucent`
# logs `window translucent=<bool>` only after DWM accepted the switch (a refusal
# logs a warning and changes nothing), and the viewer host's WS_EX_LAYERED bit
# is readable across processes. Lines are COUNTED before and after each step,
# so a stale line from an earlier step can never satisfy a later one.
#
#   A  baseline at 1.0: no translucent switch; the viewer host is NOT layered
#      (the control - the reload must be what layers it).
#   B  1.0 -> 0.6 reload: the window turns translucent and the viewer host,
#      created under the opaque config, becomes an opaque layer.
#   C  toggle_background_opacity, then a 0.6 -> 0.8 reload: the window stays
#      opaque. The user's toggle survives a reload, as Mac's isBackgroundOpaque
#      does - which is why the toggle is its own flag now.
#   D  toggle back (translucent), then 0.8 -> 1.0: the window turns opaque.
#   E  1.0 -> 0.6 again: translucent again - nothing stale from D.
#
# Runs on a background Win32 desktop (lib/TestDesktop.ps1); hermetic via a
# per-run LOCALAPPDATA + a private pipe suffix, session persistence off.
# -NegativeControl inverts assertion B, so a passing run proves B can fail.
# Only touches ghoztty processes launched from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\opacity-reload.ps1
param(
    [string]$ExePath,
    [switch]$Interactive,
    [switch]$NegativeControl
)

# T351: shared reset/kill helpers, ahead of isolation (drops an inherited
# $GHOZTTY_IPC_SOCKET - a test never wants the caller pane's endpoint).
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
# Arms the run: a body that throws part-way cannot print a green verdict (T329).
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$root = Join-Path $env:TEMP "ghoztty-opreload-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$conf = Join-Path $root 'opacity.conf'

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 600) }

function Write-Conf([string]$opacity) {
    [IO.File]::WriteAllText($conf, @"
background-opacity = $opacity
background = #101010
keybind = f9=toggle_background_opacity
"@)
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: n/a - a CLI invocation, which opens no window.
    $p = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
# Always a string: `Get-Content -Raw` of an EMPTY file is $null.
function Out-Text($f) { if (Test-Path $f) { "$(Get-Content $f -Raw)" } else { '' } }

# How many `window translucent=<want>` lines the app has logged so far.
function Count-Switch([string]$want) {
    return @(Select-String -Path $script:errlog -Pattern "window translucent=$want\b" -ErrorAction SilentlyContinue).Count
}
# Wait for the count of `window translucent=<want>` to pass $before.
function Wait-Switch([string]$want, [int]$before, [int]$timeoutMs = 6000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ((Count-Switch $want) -gt $before) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
$script:reloadN = 0
function Reload-To([string]$opacity) {
    Write-Conf $opacity
    $script:reloadN++
    $out = Join-Path $root "reload-$($script:reloadN).txt"
    $rc = Run-CliArgs @('+reload', '--config') $out 20
    return [pscustomobject]@{ Rc = $rc; Err = (Out-Text "$out.err").Trim() }
}
function Toggle-Opacity {
    [void](Send-TestKeys -Window $script:top -Target $script:pane -Key F9)
}
function Test-Layered([IntPtr]$h) {
    return (((Get-TestWindowStyle -Window $h -ExStyle) -band 0x80000) -ne 0)
}

Kill-RepoInstances
$saved = @{ lad = $env:LOCALAPPDATA; pipe = $env:GHOZTTY_PIPE_SUFFIX }
New-Item -ItemType Directory -Force (Join-Path $root 'state') | Out-Null
$env:LOCALAPPDATA = Join-Path $root 'state'
$env:GHOZTTY_PIPE_SUFFIX = "-opreload$PID"

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Write-Conf '1.0'
    $script:errlog = Join-Path $root 'app-stderr.log'
    # persistence: off - nothing here is about restore, and a restored layout would add windows the counts do not expect.
    $app = Start-OnTestDesktop -Exe $exe -StdErr $script:errlog -Arguments @(
        '--config-default-files=false',
        '--session-persistence=false',
        "--config-file=$conf"
    )
    $script:top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    Assert ($script:top -ne [IntPtr]::Zero) 'setup: top window found'
    if ($script:top -eq [IntPtr]::Zero) { throw 'no top window' }
    Set-TestWindowSize -Window $script:top -Width 1100 -Height 700 | Out-Null
    $script:pane = [IntPtr](Get-TestChildWindow -Window $script:top -Class 'GhozttyTerminal')
    Start-Sleep -Seconds 2

    # The viewer is opened under the OPAQUE config, so nothing layered it yet.
    $readme = Join-Path $repo 'README.md'
    $vout = Join-Path $root 'split-view.txt'
    $rcView = Run-CliArgs @('+split', '--direction=right', "--view=$readme") $vout 20
    Assert ($rcView -eq 0) "setup: +split --view answered (rc=$rcView $(Out-Text "$vout.err"))"
    $viewer = [IntPtr]::Zero
    for ($i = 0; $i -lt 40 -and $viewer -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 250
        $viewer = [IntPtr](Get-TestChildWindow -Window $script:top -Class 'GhozttyViewer')
    }
    Assert ($viewer -ne [IntPtr]::Zero) 'setup: the viewer host window exists'

    # --- A: baseline -----------------------------------------------------------
    Assert ((Count-Switch 'true') -eq 0) 'A: at background-opacity 1.0 the window never went translucent'
    if ($viewer -ne [IntPtr]::Zero) {
        Assert (-not (Test-Layered $viewer)) 'A: the viewer host opened under 1.0 is not an opaque layer yet (control)'
    }

    # --- B: 1.0 -> 0.6 -----------------------------------------------------------
    $t0 = Count-Switch 'true'
    $r = Reload-To '0.6'
    Assert ($r.Rc -eq 0) "B: +reload --config exits 0 (rc=$($r.Rc) $($r.Err))"
    $went = Wait-Switch 'true' $t0
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the reload did NOT turn the window translucent - this run MUST fail'
        Assert (-not $went) 'B (inverted): no translucent switch after the reload'
    } else {
        Assert $went 'B: reloading to 0.6 turns the open window translucent'
    }
    if ($viewer -ne [IntPtr]::Zero) {
        Assert (Test-Layered $viewer) 'B: the viewer host became an opaque layer, so its chrome does not vanish'
    }

    # --- C: a toggle survives a reload -------------------------------------------
    $f0 = Count-Switch 'false'
    Toggle-Opacity
    Assert (Wait-Switch 'false' $f0) 'C: toggle_background_opacity turns the window opaque'
    $t1 = Count-Switch 'true'
    $r = Reload-To '0.8'
    Assert ($r.Rc -eq 0) "C: +reload --config exits 0 (rc=$($r.Rc) $($r.Err))"
    Start-Sleep -Milliseconds 2000
    Assert ((Count-Switch 'true') -eq $t1) 'C: reloading to 0.8 leaves the toggled-opaque window opaque'

    # --- D: toggle back, then 0.8 -> 1.0 -------------------------------------------
    $t2 = Count-Switch 'true'
    Toggle-Opacity
    Assert (Wait-Switch 'true' $t2) 'D: toggling again makes the window translucent'
    $f1 = Count-Switch 'false'
    $r = Reload-To '1.0'
    Assert ($r.Rc -eq 0) "D: +reload --config exits 0 (rc=$($r.Rc) $($r.Err))"
    Assert (Wait-Switch 'false' $f1) 'D: reloading to 1.0 turns the open window opaque'

    # --- E: 1.0 -> 0.6 again ----------------------------------------------------------
    $t3 = Count-Switch 'true'
    $r = Reload-To '0.6'
    Assert ($r.Rc -eq 0) "E: +reload --config exits 0 (rc=$($r.Rc) $($r.Err))"
    Assert (Wait-Switch 'true' $t3) 'E: reloading back to 0.6 turns it translucent again'

    $refused = @(Select-String -Path $script:errlog -Pattern 'per-pixel alpha .* refused' -ErrorAction SilentlyContinue)
    Assert ($refused.Count -eq 0) "no per-pixel alpha switch was refused by DWM ($($refused.Count))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'no window leaked onto the interactive desktop'
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    $env:LOCALAPPDATA = $saved.lad
    if ($null -ne $saved.pipe) { $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe } else { Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

if ($script:fail -eq 0 -and -not $NegativeControl) {
    # A clean green run records the covered files (T783); red stays due, and
    # guard-due refuses to stamp a run that did not reach Complete-TestBody.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard opacity-reload -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -MinPass 14
