# T2914: what background windows cost, measured the way Mac 68a8344f0 was.
#
# Sixteen windows behind one foreground window that covers them all - Mac's
# mix: busy panes printing (a circling border while busy), panes spinning
# their titles, a git-status viewer, idle shells - and the app's own CPU over
# a fixed window of time. Run twice: once with GHOZTTY_TEST_NO_OCCLUSION=1,
# the debug seam that turns the hidden-window skip off (the "before": every
# covered window keeps presenting, holding titles and polling), and once as
# shipped. Only ghoztty.exe is measured: the shells and the printing loops
# cost the same either way.
#
# A MEASUREMENT, not a pass/fail gate: it prints the two numbers and their
# ratio. Runs on a background test desktop, so nothing takes the user's
# focus. Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File scripts\hidden-windows-cpu.ps1 [-Seconds 20] [-Windows 16]
param([string]$ExePath, [int]$Seconds = 20, [int]$Windows = 16, [switch]$Interactive)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'test\win32\lib\CleanSlate.ps1')
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-hidcpu$PID"
. (Join-Path $repo 'test\win32\lib\TestDesktop.ps1')

function Invoke-Verb([string[]]$VerbArgs) {
    $out = @(& $exe @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

# What each background window runs, in Mac's proportions.
function Get-Role([int]$i) {
    switch ($i % 8) {
        { $_ -in 0, 1, 2 } { return 'busy' }
        { $_ -in 3, 4 } { return 'title' }
        5 { return 'viewer' }
        default { return 'idle' }
    }
}

# The loops are script files: a command line with quotes inside would be
# mangled on its way through PowerShell 5.1 to a native exe.
$busyPs = Join-Path $env:TEMP "ghoztty-hidcpu-busy-$PID.ps1"
$titlePs = Join-Path $env:TEMP "ghoztty-hidcpu-title-$PID.ps1"
[IO.File]::WriteAllText($busyPs, '$i = 0; while ($true) { $i++; Write-Host ("busy line " + $i); Start-Sleep -Milliseconds 50 }')
[IO.File]::WriteAllText($titlePs, '$f = "|/-\"; $i = 0; while ($true) { $i++; $host.UI.RawUI.WindowTitle = ("spin " + $f[$i % 4]); Start-Sleep -Milliseconds 100 }')
$busyCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $busyPs"
$titleCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $titlePs"

function Measure-Run([bool]$Baseline) {
    $label = if ($Baseline) { 'before (occlusion off)' } else { 'after (as shipped)' }
    if ($Baseline) { $env:GHOZTTY_TEST_NO_OCCLUSION = '1' } else { Remove-Item Env:GHOZTTY_TEST_NO_OCCLUSION -ErrorAction SilentlyContinue }
    $errlog = Join-Path $env:TEMP "ghoztty-hidden-windows-cpu-$PID-$([int]$Baseline).log"
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    [void](New-TestDesktop -Interactive:$Interactive)
    try {
        $launchArgs = @('--config-default-files=false', '--session-persistence=false', '--confirm-close-surface=false')
        $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
        $appPid = $app.Pid
        $first = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
        if ($first -eq [IntPtr]::Zero) { throw 'no window appeared' }
        Start-Sleep -Seconds 2
        $wa = Get-TestWorkArea
        for ($i = 0; $i -lt $Windows; $i++) {
            $role = Get-Role $i
            $a = @('+new-window', "--target=bg$i", "--name=bgp$i")
            switch ($role) {
                'busy' { $a += "--command=$busyCmd" }
                'title' { $a += "--command=$titleCmd" }
                'viewer' { $a += "--working-directory=$repo"; $a += '--view=git-status:' }
            }
            $r = Invoke-Verb $a
            if ($r.Code -ne 0) { throw "window $i ($role) did not open: $($r.Text)" }
        }
        Start-Sleep -Seconds 3
        # Spread them over the work area so no two are exactly stacked, then
        # one foreground window over the whole of it.
        $tops = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')
        $k = 0
        foreach ($t in $tops) {
            $x = $wa.Left + 20 + (($k % 4) * [int]($wa.Width / 5))
            $y = $wa.Top + 20 + ([math]::Floor($k / 4) % 4) * [int]($wa.Height / 5)
            [void](Set-TestWindowPos -Window ([IntPtr][int64]$t.Hwnd) -X $x -Y $y -Width ([int]($wa.Width / 4)) -Height ([int]($wa.Height / 4)))
            $k++
        }
        $r = Invoke-Verb @('+new-window', '--target=front', '--name=frontp', '--focus')
        if ($r.Code -ne 0) { throw "the foreground window did not open: $($r.Text)" }
        Start-Sleep -Seconds 2
        $known = @($tops | ForEach-Object { [int64]$_.Hwnd })
        $front = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow') | Where-Object { $known -notcontains [int64]$_.Hwnd } | Select-Object -First 1
        if (-not $front) { throw 'the foreground window is not on the desktop' }
        [void](Set-TestWindowPos -Window ([IntPtr][int64]$front.Hwnd) -X $wa.Left -Y $wa.Top -Width $wa.Width -Height $wa.Height)
        # Let shells start and the visibility poll settle.
        Start-Sleep -Seconds 6
        $p = Get-Process -Id $appPid
        $t0 = $p.TotalProcessorTime.TotalMilliseconds
        $w0 = Get-Date
        Start-Sleep -Seconds $Seconds
        $p.Refresh()
        $cpuMs = $p.TotalProcessorTime.TotalMilliseconds - $t0
        $wallMs = ((Get-Date) - $w0).TotalMilliseconds
        $pct = [math]::Round(100.0 * $cpuMs / $wallMs, 1)
        $hid = @(Select-String -Path $errlog -Pattern 'window hidden: panes stop presenting' -SimpleMatch -ErrorAction SilentlyContinue).Count
        Write-Host ("  {0}: {1} windows behind one, ghoztty.exe {2}% of one core over {3}s ({4} 'window hidden' log lines)" -f $label, $Windows, $pct, $Seconds, $hid)
        return $pct
    } finally {
        [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
        Remove-TestDesktop
        Remove-Item Env:GHOZTTY_TEST_NO_OCCLUSION -ErrorAction SilentlyContinue
    }
}

Start-TestForegroundWatch
$before = Measure-Run $true
$after = Measure-Run $false
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
if ($leaked.Count -gt 0) { Write-Host "WARNING: a test-desktop app became foreground on the interactive desktop ($($leaked -join ','))" -ForegroundColor Yellow }
Remove-Item $busyPs, $titlePs -ErrorAction SilentlyContinue
$ratio = if ($after -gt 0) { [math]::Round($before / $after, 1) } else { 'inf' }
Write-Host ("HIDDEN WINDOWS CPU before={0}% after={1}% ({2}x less) windows={3} seconds={4}" -f $before, $after, $ratio, $Windows, $Seconds)
