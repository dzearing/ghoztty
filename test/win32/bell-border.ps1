# bell-border.ps1 - T1919 acceptance: `bell-features = border` frames the pane
# that rang, on Windows as on Mac (SurfaceView.BellBorderOverlay).
#
#   1. A BEL in an unfocused pane shows a GhozttyBellBorder popup over EXACTLY
#      that pane's rect, at Mac's 3pt stroke scaled to the window's DPI, and
#      the fade-in completes at full opacity.
#   2. The frame follows the pane: a window resize and a window move re-glue
#      it to the pane's new rect.
#   3. A key in the pane is the pane being looked at: the frame fades out and
#      its popup goes away.
#   4. Without the feature (a second launch, `bell-features = no-border`) a BEL
#      makes no frame at all.
#
# CAPTURE LIMIT, named rather than quietly dropped: the frame paints through
# UpdateLayeredWindow and never services WM_PAINT, so PrintWindow (what
# Get-TestWindowPixels uses) has nothing to render, and there is no screen
# composite off the input desktop. The frame's PIXELS - Mac's yellow at 50%,
# premultiplied, in the outer stroke only - and the easeInOut curve are
# decided in bell_math.zig and unit-tested in every lane; this script proves
# the window half (which pane, where, how wide, when). Viewer panes cannot
# ring and `Window.updateBellBorders` skips them by construction.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl launches the FIRST app without `border` too, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\bell-border.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1919-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1919')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Wait-Log([int]$From, [string]$Pattern, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From) |
            Where-Object { $_ -match $Pattern } | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }

# One BEL into pane $Target, retried: the first keys can land before the shell
# has a prompt to echo into.
function Ring([int]$From, [string]$Target, [string]$Pattern) {
    for ($try = 0; $try -lt 4; $try++) {
        [void](Invoke-Cli "+send-keys --target=$Target `"[char]7`" Enter")
        $hit = Wait-Log $From $Pattern 2500
        if ($hit) { return $hit }
    }
    return $null
}

function Start-App([string]$Features, [string]$Log) {
    $script:errlog = $Log
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $Log -Arguments @(
        '--session-persistence=false',
        '--command=powershell.exe -NoLogo',
        "--bell-features=$Features"
    )
    Start-Sleep -Seconds 3
    return $app
}

# The visible frames, and the terminal pane whose rect a frame sits on.
function Get-Borders([int]$ProcId) { @(Get-TestWindows -ProcessId $ProcId -Class 'GhozttyBellBorder') }
function Get-Panes([IntPtr]$Top) {
    @(Get-TestChildWindows -Window $Top -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left, Top)
}
function Same-Rect($a, $b) {
    $a -and $b -and $a.Left -eq $b.Left -and $a.Top -eq $b.Top -and $a.Right -eq $b.Right -and $a.Bottom -eq $b.Bottom
}
function Fmt($r) { if ($r) { "$($r.Left),$($r.Top)-$($r.Right),$($r.Bottom)" } else { '<none>' } }

# Poll until the single frame sits on the pane's rect (the re-glue rides the
# layout pass, which lands a beat after the size/move call returns).
function Wait-Glued([int]$ProcId, [IntPtr]$Top, [int]$PaneIndex, [int]$Ms = 3000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $b = @(Get-Borders $ProcId)
        $p = @(Get-Panes $Top)[$PaneIndex]
        if ($b.Count -eq 1 -and (Same-Rect $b[0] $p)) { return @{ Ok = $true; B = $b[0]; P = $p } }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return @{ Ok = $false; B = ($b | Select-Object -First 1); P = $p; N = $b.Count }
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1919'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $features = if ($NegativeControl) { 'no-border,title' } else { 'border,title' }
    $app = Start-App $features (Join-Path $tmp 'app-stderr.log')
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    Assert "setup: +split s1 (powershell) exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=s1 --shell=powershell") -eq 0)
    Start-Sleep -Milliseconds 1500
    Assert "setup: two visible panes" (@(Get-Panes $top).Count -eq 2)
    Assert "setup: no frame before any bell" (@(Get-Borders $app.Pid).Count -eq 0)

    "== 1: a BEL in the unfocused right pane frames exactly that pane"
    $mark = Get-LogCount
    $shown = Ring $mark 's1' 'bell border shown px=(\d+)'
    "  $shown"
    Assert "the app showed a frame (log)" ($null -ne $shown)
    $px = if ($shown -match 'px=(\d+)') { [int]$Matches[1] } else { -1 }
    $dpi = Get-TestWindowDpi -Window $top
    $want = [Math]::Max(1, [int][Math]::Round(3 * $dpi / 96.0, [MidpointRounding]::AwayFromZero))
    Assert "the stroke is Mac's 3pt at $dpi dpi: $want px (got $px)" ($px -eq $want)
    $g = Wait-Glued $app.Pid $top 1
    "  frame $(Fmt $g.B)  right pane $(Fmt $g.P)"
    Assert "exactly one frame, on the right pane's rect" $g.Ok
    $left = @(Get-Panes $top)[0]
    Assert "the frame is not on the left pane" (-not (Same-Rect $g.B $left))
    $faded = Wait-Log $mark 'bell border fade done alpha=255' 2000
    "  $faded"
    Assert "the fade-in finished at full opacity (log)" ($null -ne $faded)

    "== 2: the frame follows the pane through a resize and a move"
    $wr = Get-TestWindowRect -Window $top
    [void](Set-TestWindowSize -Window $top -Width ($wr.Width + 120) -Height ($wr.Height + 60))
    $g = Wait-Glued $app.Pid $top 1
    "  after resize: frame $(Fmt $g.B)  pane $(Fmt $g.P)"
    Assert "after a window resize the frame is on the pane's new rect" $g.Ok
    $before = $g.P
    $wr = Get-TestWindowRect -Window $top
    [void](Set-TestWindowPos -Window $top -X ($wr.Left + 70) -Y ($wr.Top + 40))
    $g = Wait-Glued $app.Pid $top 1
    "  after move: frame $(Fmt $g.B)  pane $(Fmt $g.P)"
    Assert "after a window move the frame is on the pane's new rect" $g.Ok
    Assert "the move really moved the pane" ($g.P -and $before -and $g.P.Left -ne $before.Left)

    "== 3: a key in the rung pane clears the bell and the frame goes away"
    $mark = Get-LogCount
    $pane = @(Get-Panes $top)[1]
    [void](Send-TestControlKey -Control ([IntPtr]$pane.Hwnd) -Key 'Right')
    $hidden = Wait-Log $mark 'bell border hidden' 3000
    "  $hidden"
    Assert "the frame faded out and hid (log)" ($null -ne $hidden)
    Assert "the fade-out ran to zero first (log)" ($null -ne (Wait-Log $mark 'bell border fade done alpha=0' 200))
    Start-Sleep -Milliseconds 200
    Assert "no visible frame remains" (@(Get-Borders $app.Pid).Count -eq 0)
    Assert "no crash" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids

    "== 4: without the feature a BEL makes no frame"
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    $app2 = Start-App 'no-border,title' (Join-Path $tmp 'app2-stderr.log')
    $top2 = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyWindow'
    if ($top2 -eq [IntPtr]::Zero) { "  SETUP FAIL: second top window not found"; $script:failures++; return }
    Assert "setup: +split s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=s1 --shell=powershell") -eq 0)
    Start-Sleep -Milliseconds 1500
    # The title glyph proves the ring landed: the bell is SET, only the frame
    # is off. +split leaves focus on the first pane, the one the title follows.
    [void](Invoke-Cli "+list --json")
    $script:focusedId = $null
    function Find-Focused($node) {
        if ($null -eq $node) { return }
        if ($node.terminal -and $node.terminal.focused) { $script:focusedId = $node.terminal.id }
        Find-Focused $node.left; Find-Focused $node.right
    }
    try { Find-Focused (Get-Content "$tmp\out.txt" -Raw | ConvertFrom-Json).data.windows[0].tabs[0].splits } catch {}
    $mark = Get-LogCount
    $rang = Ring $mark $script:focusedId 'bell title prefix=true'
    Assert "the bell rang in the second app (title glyph, log)" ($null -ne $rang)
    Start-Sleep -Milliseconds 500
    Assert "no frame was shown (log)" ($null -eq (Wait-Log 0 'bell border shown' 100))
    Assert "no frame window exists" (@(Get-Borders $app2.Pid).Count -eq 0)
    Assert "no crash (second app)" (-not ($app2.Process -and $app2.Process.HasExited))

    if ($script:failures -gt 0) {
        "  -- app log, bell lines --"
        Get-Content (Join-Path $tmp 'app-stderr.log') -ErrorAction SilentlyContinue |
            Where-Object { $_ -match 'bell' } | Select-Object -Last 20 | ForEach-Object { "  | $_" }
    }
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
        update -Guard bell-border -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1919' -Path $transcript `
        -Label 'T1919 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
