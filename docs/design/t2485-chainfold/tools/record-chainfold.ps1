<#
  T2485 recorder (T2485 evidence tool; becomes test\win32\chainfold-capture.ps1 once the
  oracle settles). Launches a sandboxed RELEASE build with N side-by-side
  panes, drags the first divider right with the real pointer so the panes to
  its right chain-collapse, and writes EVERY composed frame of the window rect
  as PNG plus a timeline.json. Gated on nobody being at the box.

  powershell -NoProfile -File docs\design\t2485-chainfold\tools\record-chainfold.ps1 -Exe <ghoztty.exe> -Out <dir> [-Panes 6] [-WinW 1600] [-WinH 800] [-DragPanes 3.4] [-DragMs 1600]
#>
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$Panes = 6,
    [int]$WinW = 1600, [int]$WinH = 800,   # DIP
    [double]$DragPanes = 3.4,              # how many pane widths the grip travels
    [int]$DragMs = 1600,
    [string]$Style = '',
    [string]$StdErr = ''                   # keep the app's log (debug build + GHOZTTY_LOG=debug)
)
$ErrorActionPreference = 'Stop'
$t2485Lib = Join-Path $PSScriptRoot '..\..\..\..\test\win32\lib'
. (Join-Path $t2485Lib 'Isolation.ps1')
. (Join-Path $t2485Lib 'FrameLabDriver.ps1')
. (Join-Path $t2485Lib 'FrameLabInput.ps1')

Import-FrameLabDriver; Import-FrameCapture; Import-FrameLabInput

$p = Get-UserPresence
if ($p.Present) { "SKIP user present: $($p.Reason)"; exit 3 }

Set-GhozttyTestIsolation -Tag t2485 -ReleaseSandbox | Out-Null
$null = New-Item -ItemType Directory -Force -Path $Out
$frames = Join-Path $Out 'frames'
$null = New-Item -ItemType Directory -Force -Path $frames
$conf = Join-Path $Out 'config'
$lines = @('confirm-close-surface = false', 'undo-timeout = 0', 'window-save-state = never')
if ($Style) { $lines += "macos-pane-style = $Style" }
[IO.File]::WriteAllText($conf, (($lines -join "`n") + "`n"))

# A pane that shows text and then idles: a numbered column of lines.
function PaneArgv([int]$i) {
    $cmd = "1..60 | % { 'pane $i  line ' + `$_ + '  the quick brown fox jumps over the lazy dog' }; Start-Sleep 600"
    return @('powershell', '-NoProfile', '-Command', $cmd)
}

$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$argv = @('--config-default-files=false', '--session-persistence=false', "--config-file=$conf", '-e') + (PaneArgv 1)
$proc = if ($StdErr) { Start-Process -FilePath $Exe -ArgumentList $argv -PassThru -RedirectStandardError $StdErr } else { Start-Process -FilePath $Exe -ArgumentList $argv -PassThru }
try {
    $top = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($top -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $top = [GflWin]::FindTop($proc.Id, 'GhozttyWindow') }
    if ($top -eq [IntPtr]::Zero) { throw 'window never appeared' }
    $scale = [GflWin]::WindowDpi($top) / 96.0
    $work = [GflWin]::WorkArea($top)
    $w = [math]::Min([int]($WinW * $scale), $work[2] - 40)
    $h = [math]::Min([int]($WinH * $scale), $work[3] - 40)
    [void][GflWin]::Place($top, $work[0] + 20, $work[1] + 20, $w, $h)
    Start-Sleep -Milliseconds 600

    $first = Get-FrameLabFirstPaneId $Exe $top
    if (-not $first) { throw '+list did not name the first pane' }
    $prev = $first.PaneId
    for ($i = 2; $i -le $Panes; $i++) {
        $o = Invoke-FrameLabCli $Exe (@('+split', "--target=$prev", '--direction=right', "--name=p$i", '-e') + (PaneArgv $i))
        if ($o -match '(?i)error|unknown|not found') { throw "+split p${i}: $o" }
        $prev = "p$i"
        Start-Sleep -Milliseconds 300
    }
    # Equal widths.
    $names = @($first.PaneId) + @(2..$Panes | ForEach-Object { "p$_" })
    $chain = $null
    $chain = { param([object[]]$N) if ($N.Count -eq 1) { return [ordered]@{ pane = $N[0] } }; return [ordered]@{ direction = 'horizontal'; ratio = [math]::Round(100.0 / $N.Count, 4); left = [ordered]@{ pane = $N[0] }; right = (& $chain @($N | Select-Object -Skip 1)) } }
    $json = (& $chain $names) | ConvertTo-Json -Depth 30 -Compress
    $o = Invoke-FrameLabCli $Exe @('+rearrange', "--target=$($first.PaneId)", ('--layout=' + $json.Replace('"', '\"')))
    if ($o -match '(?i)error|invalid') { throw "+rearrange: $o" }
    Start-Sleep -Milliseconds 2500

    $fr = [GflWin]::Frame($top)
    $rects = @([GflWin]::Children($top, 'GhozttyTerminal') | ForEach-Object { ConvertFrom-FrameLabChildRect $_ } | Sort-Object X)
    if ($rects.Count -ne $Panes) { throw "$($rects.Count) panes on show, want $Panes" }
    $gx = [int](($rects[0].X + $rects[0].W + $rects[1].X) / 2)
    $gy = [int]($rects[0].Y + $rects[0].H / 2)
    $paneW = $rects[1].W
    $tx = [int]($gx + $DragPanes * ($paneW + ($rects[1].X - $rects[0].X - $rects[0].W)))
    $tx = [math]::Min($tx, $fr[0] + $fr[2] - 20)

    $geo = [ordered]@{ scale = $scale; window = $fr; panes = $rects; grip = @($gx, $gy); target = @($tx, $gy); dragMs = $DragMs; exe = $Exe }
    [IO.File]::WriteAllText((Join-Path $Out 'geometry.json'), ($geo | ConvertTo-Json -Depth 6))

    $pb = New-FrameLabPath 1000
    [void]$pb.MoveTo($gx, $gy); [void]$pb.Hold(200); [void]$pb.Press(); [void]$pb.Hold(150)
    [void]$pb.Line($tx, $gy, $DragMs); [void]$pb.Hold(900); [void]$pb.Release(); [void]$pb.Hold(400)
    $path = $pb.Build()

    $s = Start-FrameCapture -X $fr[0] -Y $fr[1] -W $fr[2] -H $fr[3] -PngDir $frames -SampleEvery 1 -QueueBytes 3GB
    Start-Sleep -Milliseconds 400
    $played = Invoke-FrameLabInput -Path $path -Presence (Get-UserPresence)
    Start-Sleep -Milliseconds 1200
    $res = Stop-FrameCapture -Session $s
    if ($s -is [IDisposable]) { $s.Dispose() }
    if ($played.Skipped) { "SKIP input not sent: $($played.SkipReason)"; exit 3 }

    $F = [GliClock]::Frequency
    $tl = @($res.Timeline | ForEach-Object { [ordered]@{ i = $_.Index; qpc = $_.Qpc; png = $_.Png; sup = $_.Superseded } })
    $stamps = @($played.Stamps | ForEach-Object { [ordered]@{ qpc = $_.SentQpc; x = $_.X; y = $_.Y; flags = [int]$_.Flags } })
    $meta = [ordered]@{ freq = $F; aborted = $played.AbortReason; sent = $played.Sent; stats = $res.Stats; timeline = $tl; stamps = $stamps }
    [IO.File]::WriteAllText((Join-Path $Out 'timeline.json'), ($meta | ConvertTo-Json -Depth 6))
    "RECORDED frames=$($tl.Count) sent=$($played.Sent) abort='$($played.AbortReason)' dropped=$($res.Stats.QueueDropped) gaps=$($res.Stats.SlotGaps) out=$Out"
} finally {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
}
