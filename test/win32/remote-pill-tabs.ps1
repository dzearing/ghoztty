# T1435 acceptance: a degraded remote pill must not squeeze the tab strip out
# of the titlebar.
#
# Why this exists. On a window with 2+ tabs the tab strip and the caption share
# one row (T205), and the seam between them - `band_left` - is one group gap
# left of the caption cluster's leading edge, which on a remote window is the
# connection PILL. So the pill's width decides how much row the tabs get. T1433
# (D93) made a dropping link's pill say `<name> - Reconnecting... 3/5` instead
# of just the status, which roughly doubles the capsule exactly when the link
# wobbles. `remote-pill.ps1` reads the pill's own width and runs with the strip
# turned off, so nothing measured what that growth does to the tabs beside it.
#
# What this asserts, and how. Everything about the strip is read from the app's
# PUBLISHED hit regions (`+list --json` chrome, T231 - the very rects its hit
# tests read), and the pill's width from its own oracle line (`remote pill
# mode=... w=`); nothing is re-derived from the layout in PowerShell.
#
#   1. CONNECTED, several tabs, a narrow window: every tab is laid out (no
#      `null` rect), the "+" is laid out, nothing in the run crosses the pill's
#      leading edge, and a pointer move onto each tab's center hovers THAT tab
#      (the app's `tab hover tab=<i>` oracle) - laid out AND hit-testable.
#   2. DROPPED: the pill grows (its oracle width goes up), and the strip's band
#      gives up EXACTLY the width the pill took - the seam moved by the pill's
#      delta and by nothing else. Every tab is still laid out and still hovers,
#      nothing crosses the (now wider) pill, and the run is still a usable width
#      (each tab at least the strip's 60 DIP floor less a gap).
#   3. RECOVERED (the pill's own Reconnect click, against a restarted agent):
#      the pill shrinks back and the band returns to its connected width, tabs
#      intact and hoverable again.
#
# NEGATIVE CONTROL: -NegativeControl inverts section 2's seam assertion (asserts
# the band did NOT move when the pill grew) and MUST fail.
#
# Runs on the background test desktop; only ever touches ghoztty processes
# started by this script.
param(
    [string]$ExePath,
    [string]$AgentExe,
    [int]$Port = 0,
    [int]$Tabs = 4,
    # Client width in DIP: narrow enough that the run is under pressure once the
    # pill grows (the tabs fall back to an equal share), wide enough that every
    # tab still fits at the degraded pill width - which is the claim being
    # tested. Below about 700 DIP with 4 tabs the claim is FALSE today: the
    # degraded status alone costs ~120 DIP and two tabs lose their rect.
    # `-WidthDip 620` is that repro (filed by T1435; see its progress log).
    [int]$WidthDip = 760,
    [switch]$NegativeControl
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not $AgentExe) { $AgentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe' }
$env:GHOZTTY_PIPE_SUFFIX = "-rempilltabs$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
$Port = Resolve-TestPort -Name 'agent' -Port $Port
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# T1127: the agent's `--pty-host` holders outlive a per-pid kill by design.
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Ok([string]$msg) { $script:pass++; Write-Host "  PASS  $msg" }
function Bad([string]$msg) { $script:fail++; Write-Host "  FAIL  $msg" }
function Check([bool]$cond, [string]$msg) { if ($cond) { Ok $msg } else { Bad $msg } }

$HTOBJECT = 19
$WM_NCLBUTTONDOWN = 0x00A1; $WM_NCLBUTTONUP = 0x00A2
function PackPoint([int]$x, [int]$y) {
    return [IntPtr](([int64]($y -band 0xFFFF) -shl 16) -bor [int64]($x -band 0xFFFF))
}

New-TestDesktop | Out-Null
$agent = $null
$tmp = Join-Path $env:TEMP "ghoztty-rempilltabs-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    Write-Host "T1435 degraded remote pill vs the tab strip"
    Write-Host "  exe:   $exe"
    Write-Host "  agent: $AgentExe"

    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
    Assert-GhozttyIsolatedAgent -Exe $AgentExe | Out-Null
    $agent = Start-Process -FilePath $AgentExe -ArgumentList "--listen", "127.0.0.1:$Port", "--headless" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if ($agent.HasExited) { throw 'SETUP FAIL: loopback agent exited immediately' }

    $applog = Join-Path $tmp 'app.log'
    $proc = Start-OnTestDesktop -Exe $exe -StdErr $applog -Arguments @(
        '--config-default-files=false',
        '--session-persistence=false',
        '--background=#000000'
    )
    $local = Wait-TestWindow -ProcessId $proc.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($local -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no GhozttyWindow appeared' }
    Start-Sleep -Milliseconds 2000
    $before = @(Get-TestWindows -ProcessId $proc.Pid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })

    cmd /c "`"$exe`" +new-remote-window --host=127.0.0.1 --port=$Port > `"$tmp\open.txt`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        throw "SETUP FAIL: +new-remote-window exit $LASTEXITCODE - $(Get-Content "$tmp\open.txt" -Raw)"
    }
    $remote = [IntPtr]::Zero
    for ($i = 0; $i -lt 20 -and $remote -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 500
        foreach ($w in (Get-TestWindows -ProcessId $proc.Pid -Class 'GhozttyWindow')) {
            if ($before -contains $w.Hwnd) { continue }
            $remote = [IntPtr]$w.Hwnd
        }
    }
    if ($remote -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no remote GhozttyWindow appeared' }
    Start-Sleep -Seconds 2

    # More tabs on the REMOTE window: ctrl+t at its focused surface.
    # Focus the window first (it opened beside the local one, which may still
    # hold the desktop's focus), then aim the chord at the surface the app
    # itself focused - remote-inherit.ps1's recipe.
    for ($t = 1; $t -lt $Tabs; $t++) {
        Focus-TestWindow -Window $remote | Out-Null
        Start-Sleep -Milliseconds 400
        $fw = Get-TestFocusedWindow -Window $remote
        if ($fw -eq 0) {
            $vis = @(Get-TestChildWindows -Window $remote -Class 'GhozttyTerminal' | Where-Object Visible)
            if ($vis.Count -gt 0) { $fw = $vis[0].Hwnd }
        }
        [void](Send-TestKeys -Window $remote -Target ([IntPtr]$fw) -Modifiers ctrl -Key T)
        Start-Sleep -Milliseconds 1200
    }

    $dpi = [int](Get-TestWindowDpi -Window $remote)
    $scale = $dpi / 96.0
    $px = { param($dip) Get-TestChromeDip -Dip $dip -Scale $scale }
    $winR = Get-TestWindowRect -Window $remote
    $cliR = Get-TestWindowRect -Window $remote -Client
    $frameW = $winR.Width - $cliR.Width
    Set-TestWindowSize -Window $remote -Width ((& $px $WidthDip) + $frameW) -Height 600 | Out-Null
    Start-Sleep -Milliseconds 1500

    # The strip must exist before anything below means anything: a window whose
    # ctrl+t did not land has one tab, no strip, and nothing to squeeze.
    if ($null -eq (Get-TestStripRegions -Window $remote -Exe $exe -TimeoutMs 10000)) {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $raw = & $exe +list --json 2>$null | Out-String } finally { $ErrorActionPreference = $old }
        $n = '?'
        try {
            foreach ($w in ($raw | ConvertFrom-Json).data.windows) {
                if ([int64]$w.id -eq [int64]$remote) { $n = @($w.tabs).Count }
            }
        } catch {}
        throw "SETUP FAIL: the remote window shows no tab strip (it has $n tab(s), wanted $Tabs)"
    }

    $m = Get-TestChromeMetrics -Window $remote -StripVisible $true
    $cli = Get-TestWindowRect -Window $remote -Client
    # The pill's trailing edge: one group gap left of the caption's "...".
    $pillRight = $m.CaptionOverflowLeft - $m.PadMd
    $floor = $m.MinTabW - $m.TabGap
    Write-Host "  dpi=$dpi clientW=$($m.ClientW) pillRight=$pillRight tabFloor=$floor"

    function PillLines([string]$mode) {
        if (-not (Test-Path $applog)) { return @() }
        return @(Get-Content $applog | Select-String -Pattern "remote pill mode=$mode" | ForEach-Object { $_.Line })
    }
    function PillWidth([string]$line) {
        if ($line -match ' w=(\d+)') { return [int]$Matches[1] }
        return -1
    }

    # Every tab's center, hovered through the app's own pointer path; the
    # `tab hover tab=<i>` oracle says WHICH tab the hit test resolved.
    function HoverAll($regions) {
        $ok = 0
        for ($i = 0; $i -lt $regions.Tabs.Count; $i++) {
            $r = $regions.Tabs[$i]
            if ($null -eq $r) { continue }
            Clear-Content $applog -ErrorAction SilentlyContinue
            [void](Send-TestMouse -Window $remote -Target $remote -X ($cli.Left + $r.CenterX) -Y ($cli.Top + $r.CenterY) -Action move)
            Start-Sleep -Milliseconds 250
            if (@(Get-Content $applog -ErrorAction SilentlyContinue | Select-String -Pattern "tab hover tab=$i ").Count -gt 0) { $ok++ }
        }
        return $ok
    }

    # One state's whole verdict: laid out, clear of the pill, hoverable.
    function CheckStrip([string]$label, $regions, [int]$pillW) {
        if ($null -eq $regions) { Bad "$label - the window reports no tab strip at all"; return }
        $laid = @($regions.Tabs | Where-Object { $null -ne $_ })
        Check ($regions.Tabs.Count -eq $Tabs -and $laid.Count -eq $Tabs) `
            "$label - all $Tabs tabs are laid out ($($laid.Count) of $($regions.Tabs.Count) have a rect)"
        Check ($null -ne $regions.NewTab) "$label - the '+' is laid out"
        $pillLeft = $pillRight - $pillW
        $runRight = if ($null -ne $regions.NewTab) { $regions.NewTab.Right } else { $regions.TabsRight }
        Check ($pillW -gt 0 -and $runRight -le $pillLeft) `
            "$label - nothing in the run crosses the pill (run right=$runRight <= pill left=$pillLeft, pill w=$pillW)"
        $narrow = @($laid | Where-Object { $_.Width -lt $floor })
        Check ($laid.Count -gt 0 -and $narrow.Count -eq 0) `
            "$label - every tab keeps a usable width (min $(($laid | Measure-Object Width -Minimum).Minimum) px >= floor $floor px)"
        $hov = HoverAll $regions
        Check ($hov -eq $Tabs) "$label - a pointer on each tab hovers THAT tab ($hov of $Tabs)"
    }

    # --- 1. connected ---------------------------------------------------------
    $wC = PillWidth ((PillLines 'connected') | Select-Object -Last 1)
    $rC = Get-TestStripRegions -Window $remote -Exe $exe
    Write-Host "  connected: pill w=$wC band=$($rC.Band.Left)..$($rC.Band.Right) run right=$($rC.NewTab.Right)"
    CheckStrip 'connected' $rC $wC

    # --- 2. dropped -------------------------------------------------------------
    Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
    $agent = $null
    # The pill re-labels on every ladder rung, so its width and the strip are
    # read together and retried until they describe the same frame.
    $rD = $null; $wD = -1; $consistent = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 1000
        $line = (PillLines '(reconnecting|disconnected)') | Select-Object -Last 1
        if (-not $line) { continue }
        $wD = PillWidth $line
        $rD = Get-TestStripRegions -Window $remote -Exe $exe
        if ($null -ne $rD -and $wD -gt $wC -and ($rC.Band.Right - $rD.Band.Right) -eq ($wD - $wC)) { $consistent = $true; break }
    }
    Write-Host "  dropped:   pill w=$wD band=$($rD.Band.Left)..$($rD.Band.Right) run right=$($rD.NewTab.Right)"
    Check ($wD -gt $wC) "a dropped link WIDENS the pill (w $wC -> $wD px)"
    $moved = $rC.Band.Right - $rD.Band.Right
    if ($NegativeControl) {
        Check ($moved -eq 0) "NEGATIVE CONTROL: the strip's band did not move when the pill grew"
    } else {
        Check $consistent "the strip gives up exactly the pill's growth (band right -$moved px for pill +$($wD - $wC) px)"
    }
    CheckStrip 'dropped' $rD $wD

    # --- 3. recovered -----------------------------------------------------------
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent2.lock'
    $agent = Start-Process -FilePath $AgentExe -ArgumentList "--listen", "127.0.0.1:$Port", "--headless" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $connBefore = @(PillLines 'connected').Count
    Send-TestRawMessage -Window $remote -Message $WM_NCLBUTTONDOWN -WParam ([IntPtr]$HTOBJECT) -LParam (PackPoint 0 0) | Out-Null
    Start-Sleep -Milliseconds 150
    Send-TestRawMessage -Window $remote -Message $WM_NCLBUTTONUP -WParam ([IntPtr]$HTOBJECT) -LParam (PackPoint 0 0) | Out-Null
    $rR = $null; $wR = -1; $back = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 1000
        # HoverAll clears the log, so count from the CURRENT file, not a delta.
        $line = (PillLines 'connected') | Select-Object -Last 1
        if (-not $line) { continue }
        $wR = PillWidth $line
        $rR = Get-TestStripRegions -Window $remote -Exe $exe
        if ($null -ne $rR -and $wR -eq $wC -and $rR.Band.Right -eq $rC.Band.Right) { $back = $true; break }
    }
    Write-Host "  recovered: pill w=$wR band=$($rR.Band.Left)..$($rR.Band.Right)"
    Check $back "recovering gives the strip its width back (band right $($rR.Band.Right) == connected $($rC.Band.Right))"
    CheckStrip 'recovered' $rR $wR

    Write-Host ""
    Complete-TestBody
} catch {
    $script:fail++
    Write-Host "  FAIL  $($_.Exception.Message)"
} finally {
    if ($null -ne $agent) { Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop | Out-Null
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard remote-pill-tabs -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Unit 'checks'
