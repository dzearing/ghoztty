# T1797 acceptance: `ghoztty +...` commands open windows and panes in the
# BACKGROUND; `--focus` opts back in (the win32 half of main 3081022ec).
#
# Before this, every CLI-created window activated and every CLI split moved
# the keyboard into the new pane, so an agent opening a side pane - or a
# script opening a window while the user played a fullscreen game - yanked the
# user out of what they were doing. The contract now, on both platforms:
#
#   - No `--focus`: the window shows WITHOUT activating, is placed behind
#     Ghoztty's frontmost window (never over the user's app), and the pane that
#     had the keyboard keeps it. `--no-activate` is accepted and means the same.
#   - `--focus` (or `--focus=true`): the old raise-and-focus.
#
# Oracles. This runs on the background test desktop, which has no foreground
# window at all, so "did it take focus" is read from the app's own GUI thread
# (GetGUIThreadInfo: its active and focused HWND) and "is it above the user's
# app" from the real z-order (EnumWindows index). The user's app is a plain
# WinForms window from another process; "the user is in it" is that window
# activated and Ghoztty's queue holding no keyboard at all.
#
#   A  +new-window                      active/focus untouched, behind Ghoztty, under the app
#   B  +new-window --view=<file>        same, for a viewer window
#   C  +new-window --no-activate        same (the retired opt-out is a no-op)
#   D  +new-window --target=<existing>  idempotent hit raises nothing
#   E  +split --target=<window>         nothing activated
#   F  +split --view=<file> --target    nothing activated
#   R  +new-remote-window               same, over a loopback agent (the remote open tail)
#   G  +split while typing in Ghoztty   the keyboard stays on the caller's pane
#   H  +split --view while typing       same
#   I  +split --focus                   POSITIVE: the new pane takes the keyboard
#   J  +new-window --focus              POSITIVE: the new window activates
#   K  +new-window --target=<existing> --focus   POSITIVE: the existing one activates
#
# NOT covered here: the `ghoztty://focus` scheme and user keybinds, whose own
# harnesses (url-scheme.ps1, kb-actions.ps1) assert that they still focus.
# `+new-remote-window --focus` is the positive control remote-inherit.ps1
# depends on (its --from-focused arms need the remote window focused).
#
# -NegativeControl inverts arm A (asserts the new window DID activate) and
# MUST fail: a run that passes with it means arm A cannot see activation.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\cli-focus-policy.ps1
param(
    [string]$ExePath,
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Port = 0,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-focuspolicy$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
$Port = Resolve-TestPort -Name 'agent' -Port $Port

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

# Piped, not redirected: ghoztty.exe is GUI-subsystem, so PowerShell only waits
# for it when its stdout goes to a pipe.
function Invoke-Cli([string[]]$CliArgs) { ((& $exe @CliArgs 2>&1 | ForEach-Object { "$_" }) -join ' ').Trim() }

function Get-Tops { @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyWindow' | Where-Object Visible) }

# The one top-level that appeared since $before (a list of hwnds).
function Wait-NewTop([int64[]]$before, [string]$label) {
    for ($i = 0; $i -lt 50; $i++) {
        $new = @(Get-Tops | Where-Object { $before -notcontains $_.Hwnd })
        if ($new.Count -ge 1) { Start-Sleep -Milliseconds 600; return [int64]$new[0].Hwnd }
        Start-Sleep -Milliseconds 200
    }
    Write-Host "SETUP FAIL: $label never opened a window"
    return [int64]0
}

function Count-Panes([int64]$hwnd) {
    @(Get-TestChildWindows -Window ([IntPtr]$hwnd) -Class '*' |
        Where-Object { $_.Visible -and ($_.Class -eq 'GhozttyTerminal' -or $_.Class -eq 'GhozttyViewer') }).Count
}

function Active { [int64](Get-TestActiveWindow -Window ([IntPtr]$script:w1)) }
function Focused { [int64](Get-TestFocusedWindow -Window ([IntPtr]$script:w1)) }

# "The user is in another app": the foreign window active and on top, and
# Ghoztty's own queue holding no keyboard - the state a real click away leaves.
# Its ACTIVE window is recorded rather than asserted zero: a background desktop
# lets SetActiveWindow(NULL) leave the last one in place (measured: it stays
# w1), so the claim is that a command leaves it exactly as it was.
function Enter-ForeignApp {
    [void](Set-TestActiveWindow -Window ([IntPtr]$script:foreign))
    if (-not (Clear-TestActiveWindow -Window ([IntPtr]$script:w1))) {
        Write-Host 'SETUP FAIL: could not take the keyboard away from Ghoztty'; exit 1
    }
    Start-Sleep -Milliseconds 300
    $script:activeBefore = Active
}

# Assert the background contract for a window that was just opened.
function Assert-Background([int64]$win, [string]$arm) {
    $a = Active
    Assert ($a -eq $script:activeBefore -and ($win -eq 0 -or $a -ne $win)) "$arm Ghoztty's active window did not move (active=$a, before=$script:activeBefore, new=$win)"
    Assert ((Focused) -eq 0) "$arm no Ghoztty pane took the keyboard (focus=$(Focused))"
    if ($win -ne 0) {
        $zNew = Get-TestZIndex -Window ([IntPtr]$win)
        $zApp = Get-TestZIndex -Window ([IntPtr]$script:foreign)
        $zW1 = Get-TestZIndex -Window ([IntPtr]$script:w1)
        Write-Host "      z-order: app=$zApp ghoztty=$zW1 new=$zNew"
        Assert ($zNew -gt $zApp) "$arm the new window is NOT above the user's app"
        Assert ($zNew -gt $zW1) "$arm ...it sits behind Ghoztty's frontmost window"
    }
}

$viewFile = Join-Path $env:TEMP "ghoztty-focus-policy-$PID.md"
Set-Content -Path $viewFile -Value "# focus policy`n`nA viewer opened by T1797's harness." -Encoding ascii

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:appPid = 0
$foreignPid = 0
$agentPid = 0

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: arm A asserts the new window ACTIVATED - this run MUST fail'
    }

    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    $script:appPid = $app.Pid
    $script:w1 = [int64](Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow')
    if ($script:w1 -eq 0) { Write-Host 'SETUP FAIL: first window not found'; exit 1 }
    Start-Sleep -Seconds 2
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'
    $p1 = [int64](Get-TestChildWindow -Window ([IntPtr]$script:w1) -Class 'GhozttyTerminal')

    # The user's app: a plain window owned by another process.
    $formScript = "Add-Type -AssemblyName System.Windows.Forms; `$f = New-Object Windows.Forms.Form; `$f.Text = 'T1797 user app'; `$f.Width = 900; `$f.Height = 700; [Windows.Forms.Application]::Run(`$f)"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($formScript))
    $f = Start-OnTestDesktop -Exe "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Arguments @('-NoProfile', '-EncodedCommand', $enc)
    $foreignPid = $f.Pid
    $script:foreign = [int64](Wait-TestWindow -ProcessId $f.Pid -Class $null)
    if ($script:foreign -eq 0) { Write-Host 'SETUP FAIL: the stand-in user app never opened'; exit 1 }

    # ---- A: +new-window ---------------------------------------------------
    Enter-ForeignApp
    $before = @(Get-Tops | ForEach-Object { $_.Hwnd })
    Write-Host "      +new-window: $(Invoke-Cli @('+new-window', '--target=bg1'))"
    $w2 = Wait-NewTop $before 'A'
    if ($NegativeControl) {
        Assert ((Active) -eq $w2) 'A: the new window activated (negative control)'
    } else {
        Assert-Background $w2 'A:'
    }

    # ---- B: +new-window --view --------------------------------------------
    Enter-ForeignApp
    $before = @(Get-Tops | ForEach-Object { $_.Hwnd })
    Write-Host "      +new-window --view: $(Invoke-Cli @('+new-window', "--view=$viewFile"))"
    $w3 = Wait-NewTop $before 'B'
    Start-Sleep -Seconds 2   # a viewer's WebView2 comes up asynchronously
    Assert-Background $w3 'B:'

    # ---- C: --no-activate is the default spelled out ------------------------
    Enter-ForeignApp
    $before = @(Get-Tops | ForEach-Object { $_.Hwnd })
    Write-Host "      +new-window --no-activate: $(Invoke-Cli @('+new-window', '--no-activate'))"
    $w4 = Wait-NewTop $before 'C'
    Assert-Background $w4 'C:'

    # ---- D: an idempotent hit raises nothing --------------------------------
    Enter-ForeignApp
    $out = Invoke-Cli @('+new-window', '--target=bg1')
    Start-Sleep -Milliseconds 600
    $nTops = @(Get-Tops).Count
    Assert ($nTops -eq 4) "D: the existing target was found, not recreated ($nTops windows)"
    Assert-Background 0 'D:'

    # ---- E: +split into a background window --------------------------------
    Enter-ForeignApp
    $n = Count-Panes $w2
    Write-Host "      +split --target=bg1: $(Invoke-Cli @('+split', '--target=bg1'))"
    Start-Sleep -Milliseconds 900
    Assert ((Count-Panes $w2) -eq $n + 1) "E: the split landed ($n -> $(Count-Panes $w2) panes)"
    Assert-Background 0 'E:'

    # ---- F: a viewer split -------------------------------------------------
    Enter-ForeignApp
    $n = Count-Panes $w2
    Write-Host "      +split --view --target=bg1: $(Invoke-Cli @('+split', '--target=bg1', "--view=$viewFile"))"
    Start-Sleep -Seconds 2
    Assert ((Count-Panes $w2) -eq $n + 1) "F: the viewer split landed ($n -> $(Count-Panes $w2) panes)"
    Assert-Background 0 'F:'

    # ---- R: +new-remote-window over a loopback agent -------------------------
    $env:GHOSTTY_AGENT_LOCK = Join-Path $env:TEMP "ghoztty-focus-policy-agent-$PID.lock"
    $agent = Start-OnTestDesktop -Exe $AgentExe -Arguments @('--listen', "127.0.0.1:$Port", '--headless')
    $agentPid = $agent.Pid
    Start-Sleep -Seconds 2
    Enter-ForeignApp
    $before = @(Get-Tops | ForEach-Object { $_.Hwnd })
    Write-Host "      +new-remote-window: $(Invoke-Cli @('+new-remote-window', '--host=127.0.0.1', "--port=$Port", '--name=rem1'))"
    $wr = Wait-NewTop $before 'R'
    Assert ($wr -ne 0) 'R: the remote window opened'
    Assert-Background $wr 'R:'

    # ---- G/H: the user is typing in Ghoztty --------------------------------
    if (-not (Focus-TestWindow -Window ([IntPtr]$script:w1) -Child ([IntPtr]$p1))) {
        Write-Host 'SETUP FAIL: could not put the keyboard in the first pane'; exit 1
    }
    Start-Sleep -Milliseconds 400
    Assert ((Focused) -eq $p1) 'G: setup - the keyboard is in the first pane'
    $n = Count-Panes $script:w1
    [void](Invoke-Cli @('+split', '--direction=right'))
    Start-Sleep -Milliseconds 900
    Assert ((Count-Panes $script:w1) -eq $n + 1) 'G: the split landed in the window being typed in'
    Assert ((Focused) -eq $p1) "G: the keyboard stayed on the pane it was in (focus=$(Focused), wanted $p1)"
    Assert ((Active) -eq $script:w1) 'G: ...and that window stayed active'

    [void](Invoke-Cli @('+split', '--direction=down', "--view=$viewFile"))
    Start-Sleep -Seconds 2
    Assert ((Count-Panes $script:w1) -eq $n + 2) 'H: the viewer split landed'
    Assert ((Focused) -eq $p1) "H: the keyboard stayed on the pane it was in (focus=$(Focused))"

    # ---- I/J/K: --focus is the opt-in (positive controls) ------------------
    $termsBefore = @(Get-TestChildWindows -Window ([IntPtr]$script:w1) -Class 'GhozttyTerminal' | ForEach-Object { $_.Hwnd })
    [void](Invoke-Cli @('+split', '--direction=right', '--focus'))
    Start-Sleep -Milliseconds 1200
    $newTerm = @(Get-TestChildWindows -Window ([IntPtr]$script:w1) -Class 'GhozttyTerminal' |
        Where-Object { $termsBefore -notcontains $_.Hwnd } | ForEach-Object { $_.Hwnd })
    Assert ($newTerm.Count -eq 1 -and (Focused) -eq $newTerm[0]) "I: +split --focus moved the keyboard into the new pane (focus=$(Focused))"

    Enter-ForeignApp
    $before = @(Get-Tops | ForEach-Object { $_.Hwnd })
    [void](Invoke-Cli @('+new-window', '--target=fg1', '--focus'))
    $w5 = Wait-NewTop $before 'J'
    Start-Sleep -Milliseconds 600
    Assert ($w5 -ne 0 -and (Active) -eq $w5) "J: +new-window --focus activated the new window (active=$(Active), new=$w5)"

    Enter-ForeignApp
    [void](Invoke-Cli @('+new-window', '--target=bg1', '--focus=true'))
    Start-Sleep -Milliseconds 900
    Assert ((Active) -eq $w2) "K: an existing target with --focus=true is activated (active=$(Active), want $w2)"

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    $launched += $script:GhozttyTestDesktopPids
    Complete-TestBody  # T1039: the last statement of the body
} finally {
    if ($script:appPid) { Stop-Process -Id $script:appPid -Force -ErrorAction SilentlyContinue }
    if ($foreignPid) { Stop-Process -Id $foreignPid -Force -ErrorAction SilentlyContinue }
    if ($agentPid) { Stop-Process -Id $agentPid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $viewFile -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard cli-focus-policy -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'cli-focus-policy' -MinPass 35
