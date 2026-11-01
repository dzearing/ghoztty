# T2599 standalone WGL repro harness: builds repro.exe, drives it on the test
# desktop (never the user's), and samples the process's dedicated GPU memory
# after every step. See README.md for what each scenario asks.
param(
    [string[]]$Scenarios = @('one', 'two', 'two-live', 'shared', 'noswap2', 'gdi2', 'park', 'live-1swap', 'live-0swap', 'churn'),
    [int]$Reps = 3
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$tw = Join-Path $repo 'test\win32'
. (Join-Path $tw 'lib\TestDesktop.ps1')
. (Join-Path $tw 'lib\ProcessMemory.ps1')

$outDir = Join-Path $repo 'temp\t2599-wgl-multichild'
New-Item -ItemType Directory -Force $outDir | Out-Null
$exe = Join-Path $outDir 'repro.exe'
$src = Join-Path $PSScriptRoot 'repro.zig'
if (-not (Test-Path $exe) -or (Get-Item $src).LastWriteTime -gt (Get-Item $exe).LastWriteTime) {
    Push-Location $outDir
    try {
        & zig build-exe $src -target x86_64-windows -lc -lopengl32 -lgdi32 -luser32 -O Debug --subsystem windows
        if ($LASTEXITCODE -ne 0) { throw "repro build failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
}

if (-not ('T2599Msg' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class T2599Msg {
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
}
'@
}

# Dedicated GPU MB once two consecutive reads agree.
function Gpu([int]$procId) {
    $prev = -1.0
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 700
        $g = Get-GpuBytes $procId
        if (-not $g) { return $null }
        $v = [math]::Round($g.Dedicated / 1MB, 2)
        if ($v -eq $prev) { return $v }
        $prev = $v
    }
    return $prev
}

# Per scenario: S = setup steps, H = one hide/show rep, M = one minimize/restore
# rep. Each step is @(cmd, arg) for WM_APP (the table is in repro.zig).
$plans = @{
    'one'        = @{ S = @(@(1, 0)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'two'        = @{ S = @(@(1, 0), @(1, 0), @(2, 0)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'two-live'   = @{ S = @(@(1, 0), @(1, 0)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'shared'     = @{ S = @(@(1, 0), @(9, 0)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'noswap2'    = @{ S = @(@(1, 0), @(1, 1), @(2, 0)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'gdi2'       = @{ S = @(@(1, 0), @(8, 0), @(2, 0)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'park'       = @{ S = @(@(1, 0), @(1, 0), @(11, 0)); H = @(@(3, 0), @(12, 0), @(14, 0)); M = @(@(5, 0), @(13, 0), @(14, 0)) }
    'live-1swap' = @{ S = @(@(1, 0), @(1, 0)); H = @(@(3, 0), @(12, 0), @(14, 0)); M = @(@(5, 0), @(13, 0), @(14, 0)) }
    'live-0swap' = @{ S = @(@(1, 0), @(1, 0)); H = @(@(3, 0), @(12, 0)); M = @(@(5, 0), @(13, 0)) }
    'churn'      = @{ S = @(@(1, 0), @(1, 0), @(2, 0), @(1, 0), @(2, 0), @(1, 0), @(2, 0)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    # T2610: one presenter child, renderer threads on shared contexts
    'pres-helper'     = @{ S = @(@(20, 0), @(21, 0), @(21, 0)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'pres-pane'       = @{ S = @(@(20, 0), @(21, 1), @(21, 1)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'pres-pane3'      = @{ S = @(@(20, 0), @(21, 1), @(21, 1), @(21, 1)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'pres-churn'      = @{ S = @(@(20, 0), @(21, 1), @(21, 1), @(23, 0), @(21, 1), @(23, 0), @(21, 1), @(23, 0)); H = @(@(3, 0), @(4, 0)); M = @(@(5, 0), @(6, 0)) }
    'pres-churn-live' = @{ S = @(@(20, 0), @(21, 1), @(21, 1)); H = @(@(23, 0), @(21, 1), @(3, 0), @(4, 0)); M = @(@(23, 0), @(21, 1), @(5, 0), @(6, 0)) }
}
$names = @{ 1 = 'add-gl'; 2 = 'destroy'; 3 = 'hide'; 4 = 'show'; 5 = 'minimize'; 6 = 'restore'; 7 = 'present'; 8 = 'add-gdi'; 9 = 'add-ctx'; 11 = 'park'; 12 = 'show-np'; 13 = 'rest-np'; 14 = 'pres-c0'; 20 = 'add-pres'; 21 = 'add-rend'; 22 = 'pres-all'; 23 = 'del-rend' }

$summary = @()
Start-TestForegroundWatch
$td = New-TestDesktop
try {
    foreach ($sc in $Scenarios) {
        $plan = $plans[$sc]
        if (-not $plan) { Write-Host "unknown scenario $sc"; continue }
        $app = Start-OnTestDesktop -Exe $exe
        $h = [IntPtr][int64](Wait-TestWindow -ProcessId $app.Pid -Class 'T2599Repro' -TimeoutMs 10000)
        $base = Gpu $app.Pid
        if ($null -eq $base) { Write-Host 'SKIP: GPU Process Memory counters are not readable here'; break }
        function Step([int]$cmd, [int]$arg) {
            [void][T2599Msg]::SendMessageW($h, 0x8000, [IntPtr]$cmd, [IntPtr]$arg)
            $v = Gpu $app.Pid
            Write-Host ("  {0,-10} {1,-9} ded={2,7}" -f $sc, $names[$cmd], $v)
        }
        Write-Host ("  {0,-10} {1,-9} ded={2,7}" -f $sc, 'base', $base)
        foreach ($s in $plan.S) { Step $s[0] $s[1] }
        $before = Gpu $app.Pid
        for ($i = 0; $i -lt $Reps; $i++) { foreach ($s in $plan.H) { Step $s[0] $s[1] } }
        $afterHide = Gpu $app.Pid
        for ($i = 0; $i -lt $Reps; $i++) { foreach ($s in $plan.M) { Step $s[0] $s[1] } }
        $afterMin = Gpu $app.Pid
        $summary += [pscustomobject]@{
            Scenario   = $sc
            Setup      = $before
            HidePerRep = [math]::Round(($afterHide - $before) / $Reps, 2)
            MinPerRep  = [math]::Round(($afterMin - $afterHide) / $Reps, 2)
        }
        [void][T2599Msg]::SendMessageW($h, 0x8000, [IntPtr]10, [IntPtr]0)
        Start-Sleep -Milliseconds 800
        try { Stop-Process -Id $app.Pid -Force -ErrorAction Stop } catch { }
    }
} finally {
    Remove-TestDesktop
    [void](Stop-TestForegroundWatch)
}
$summary | Format-Table -AutoSize | Out-String | Write-Host
