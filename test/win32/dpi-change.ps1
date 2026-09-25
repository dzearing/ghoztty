# T1579 acceptance: a DPI change and a settings change reach every terminal
# pane with nothing open.
#
# WHAT THE DEFECT WAS. A terminal pane is a WS_CHILD, and Windows sends
# WM_DPICHANGED and the WM_SETTINGCHANGE broadcast to TOP-LEVEL windows only.
# The top-level GhozttyWindow had no WM_DPICHANGED arm at all, and its
# WM_SETTINGCHANGE arm never told the panes' scrollbars; the only receivers in a
# pane's orbit were its search and palette POPUPS. So moving a window to a
# monitor with a different scale left the terminal at the old one unless one of
# those popups happened to be open - and even then the core was never handed
# the new content scale, so the grid's glyphs stayed the old size regardless.
#
# THE ORACLE. This box's two monitors share one scale, so a real move cannot
# produce the message. The script sends the top-level window the message
# Windows would (WM_DPICHANGED, new DPI in wparam, lparam 0 = "keep the size")
# and measures what the user would see: the terminal's COLUMN COUNT, read from
# inside the pane with `mode con`. The pane's pixel size does not move, so the
# only way the column count can change is the font changing size - which is the
# whole of the defect. The debug build also states what it forwarded
# (`window dpi changed dpi= panes=`, `window setting change forwarded panes=`).
#
# Arms:
#   A. control - two panes; each reports a column count.
#   B. WM_DPICHANGED at 1.5x the current DPI: the window's chrome reports the
#      new DPI (+list --json chrome.dpi), both panes were told, and BOTH panes'
#      column counts dropped - including the one that is not focused.
#   C. WM_DPICHANGED back to the original DPI: the column counts come back.
#   D. WM_SETTINGCHANGE with no popup open: the window forwards it to both
#      panes (the scrollbar-mode half of the task), and the app survives it.
#
# -NegativeControl sends arm B's message to nobody and MUST fail B.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\dpi-change.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-dpichange$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-dpi-change-stderr.log'
$tmp = Join-Path $env:TEMP "ghoztty-t1579-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
# T1511: the shared scorer, which also ARMS the run - a body that unwinds before
# `Complete-TestBody` may not print a pass and may not stamp.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

if (-not ('T1579.Native' -as [type])) {
    Add-Type -Namespace T1579 -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint msg, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
'@
}
# Windows refuses a WM_DPICHANGED from another process (the send fails), so
# the debug build takes the same path through WM_APP+38 (Window.zig
# WM_APP_TEST_DPICHANGED) - same wparam, same handler, no suggested rect.
$WM_DPICHANGED = 0x8000 + 38
$WM_SETTINGCHANGE = 0x001A

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# Synchronous, so the handler has run by the time this returns.
function Send-Top([int64]$top, [int]$msg, [uint64]$wparam) {
    $r = [UIntPtr]::Zero
    $ok = [T1579.Native]::SendMessageTimeoutW([IntPtr]$top, [uint32]$msg, [UIntPtr]$wparam, [IntPtr]::Zero, 0x2, 10000, [ref]$r)
    if ($ok -eq [IntPtr]::Zero) {
        Write-Host "      send 0x$('{0:X}' -f $msg) failed: GetLastError=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        return $false
    }
    return $true
}

# ReadWrite sharing: the app holds the log open for writing, and
# [IO.File]::ReadAllText refuses that and reads as empty.
function Get-ErrText {
    try {
        $fs = [IO.File]::Open($errlog, 'Open', 'Read', 'ReadWrite')
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Get-ChromeDpi {
    $out = Join-Path $tmp 'list.json'
    [void](Invoke-LivenessCli $exe '+list --json' $out 15)
    try { $j = Get-Content $out -Raw | ConvertFrom-Json } catch { return $null }
    if (-not $j.data) { return $null }
    $w = @($j.data.windows)
    if ($w.Count -lt 1) { return $null }
    return $w[0].chrome.dpi
}

# The terminal's column count as the shell inside it sees it. Each probe clears
# the screen first so the newest `Columns:` line is this probe's, not an older
# one still in the scrollback that `+read` returns.
$script:probe = 0
function Get-Columns([string]$target) {
    $script:probe++
    $n = $script:probe
    $send = Join-Path $tmp "send-$n.txt"
    $read = Join-Path $tmp "read-$n.txt"
    [void](Invoke-LivenessCli $exe "+send-keys --target=$target cls Enter" $send 15)
    Start-Sleep -Milliseconds 600
    [void](Invoke-LivenessCli $exe "+send-keys --target=$target mode Space con Enter" $send 15)
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        if ((Invoke-LivenessCli $exe "+read --name=$target --lines=200" $read 12) -ne 0) { continue }
        $txt = ''
        try { $txt = Get-Content $read -Raw } catch { $txt = '' }
        if (-not $txt) { continue }
        $m = [regex]::Matches($txt, 'Columns:\s+(\d+)')
        if ($m.Count -gt 0) { return [int]$m[$m.Count - 1].Groups[1].Value }
    }
    return $null
}

$td = New-TestDesktop -Interactive:$Interactive
Kill-RepoInstances

try {
    # persistence: off - a restored layout would seed panes this script did not
    # create, and the pane count is one of the things it asserts.
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', '--session-persistence=false')
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'

    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) 'top-level window appeared'
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 820)

    # ---- A. control -------------------------------------------------------
    Assert (Test-PaneLive -Exe $exe -Target 'window-1' -Tmp $tmp -Tag 'A') 'A0 the first pane is LIVE'
    & $exe +split --target=window-1 --name=t1579b --direction=right 2>&1 | Out-Null
    Assert (Test-PaneLive -Exe $exe -Target 't1579b' -Tmp $tmp -Tag 'A2') 'A1 the split pane is LIVE'
    # The split is focused now, so window-1 is the pane nobody is looking at.
    $colsA = Get-Columns 'window-1'
    $colsB = Get-Columns 't1579b'
    Assert ($null -ne $colsA -and $null -ne $colsB) "A2 both panes report a column count (saw '$colsA' / '$colsB')"
    $dpi0 = Get-ChromeDpi
    Assert ($dpi0 -gt 0) "A3 the window reports its DPI (saw '$dpi0')"
    if (-not ($dpi0 -gt 0) -or $null -eq $colsA -or $null -eq $colsB) { throw 'no baseline' }

    # ---- B. the DPI change ------------------------------------------------
    $dpi1 = [int][math]::Round($dpi0 * 1.5)
    $mark = (Get-ErrText).Length
    if (-not $NegativeControl) {
        Assert (Send-Top ([int64]$top) $WM_DPICHANGED ([uint64](($dpi1 -shl 16) -bor $dpi1))) 'B0 WM_DPICHANGED delivered'
    }
    Start-Sleep -Milliseconds 800
    $dpiB = Get-ChromeDpi
    Assert ($dpiB -eq $dpi1) "B1 the window's chrome adopted the new DPI (want $dpi1, saw '$dpiB')"
    $tail = (Get-ErrText).Substring($mark)
    Assert ($tail -match "window dpi changed dpi=$dpi1 panes=2") 'B2 the window forwarded the change to both panes'
    $colsA1 = Get-Columns 'window-1'
    $colsB1 = Get-Columns 't1579b'
    Assert ($null -ne $colsA1 -and $colsA1 -lt $colsA) "B3 the unfocused pane's font grew: fewer columns ($colsA -> '$colsA1')"
    Assert ($null -ne $colsB1 -and $colsB1 -lt $colsB) "B4 the focused pane's font grew: fewer columns ($colsB -> '$colsB1')"

    # ---- C. and back ------------------------------------------------------
    Assert (Send-Top ([int64]$top) $WM_DPICHANGED ([uint64](($dpi0 -shl 16) -bor $dpi0))) 'C0 WM_DPICHANGED back delivered'
    Start-Sleep -Milliseconds 800
    Assert ((Get-ChromeDpi) -eq $dpi0) "C1 the chrome is back at $dpi0"
    $colsA2 = Get-Columns 'window-1'
    $colsB2 = Get-Columns 't1579b'
    Assert ($colsA2 -eq $colsA -and $colsB2 -eq $colsB) "C2 both panes' columns came back ($colsA/$colsB -> '$colsA2'/'$colsB2')"

    # ---- D. the settings broadcast, with no popup open --------------------
    $mark = (Get-ErrText).Length
    Assert (Send-Top ([int64]$top) $WM_SETTINGCHANGE 0) 'D0 WM_SETTINGCHANGE delivered'
    Start-Sleep -Milliseconds 500
    $tail = (Get-ErrText).Substring($mark)
    Assert ($tail -match 'window setting change forwarded panes=2') 'D1 the window forwarded the setting change to both panes'
    Assert ($null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) 'D2 the app survived'
    Assert (Test-PaneLive -Exe $exe -Target 'window-1' -Tmp $tmp -Tag 'D') 'D3 the pane is still LIVE'

    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
    Complete-TestBody  # T1039: the last statement of the body, so an unwind cannot reach it
}
catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
}
finally {
    # Teardown first: it kills what it launched and records the kill as
    # deliberate. The other way round, the app is already gone when it looks
    # and it reports a crash that was this script's own kill.
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# A green run stamps the covered files (T783) so guard-due can say whether this
# harness has been run against the forwarding code as it now stands. Red leaves
# the stamp alone: red stays due.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard dpi-change -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'DPI CHANGE ACCEPTANCE'
