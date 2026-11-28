<#
.SYNOPSIS
  Acceptance test for scripts\perf-baseline.ps1's CPU reader and its idle-CPU
  compare (T3111).

.DESCRIPTION
  Two defects hid a "7x idle CPU regression" for three baselines:

  1. The reader summed offsets 0x20 + 0x28 of the SystemProcessInformation
     record as "user + kernel". 0x20 is CreateTime, a constant, so every
     cpu_pct was user time only. Section A proves the old offset really is
     CreateTime on this box (negative control: the bug was real), then runs
     the script's own -SelfTest, which checks the fixed reader against
     Get-Process.
  2. -Compare judged idle CPU with the busy floor (+-0.5 points), so
     0.03% -> 0.21% passed as "within tolerance". Section B feeds it
     baseline-1 against baseline-3 and requires release idle CPU to come out
     OUT under the idle_cpu_pct family; baseline-2 against baseline-3 (the
     same 0.21 twice) is the control that must stay ok, and busy CPU must keep
     the wide family.
  Section C is synthetic JSON for the T3111 leaves (cpu_cycle_pct and the
  agent's idle_cpu_cycle_pct), so the new metrics are judged as idle CPU too.

  Pure logic: no exe, no window, no agent. ASCII-only by design.

  powershell -NoProfile -File test\win32\perf-baseline-reader.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passes = 0
$script:failures = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name$(if ($detail) { " -- $detail" })"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pb = Join-Path $repo 'scripts\perf-baseline.ps1'
$audit = Join-Path $repo 'docs\design\perf-audit'
$work = Join-Path $env:TEMP "perf-baseline-reader-$PID"
New-Item -ItemType Directory -Force $work | Out-Null

function Invoke-Pb([string[]]$PbArgs) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $pb @PbArgs 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Lines = @($out) }
}
function Get-Row($Lines, [string]$Metric) {
    return @($Lines | Where-Object { $_ -match ('^(ok|OUT)\s+' + [regex]::Escape($Metric) + '\s') }) | Select-Object -First 1
}

try {
    # --- A. the reader ---------------------------------------------------
    ''
    '-- A. the CPU-time reader'
    if (-not ('T3111Spi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class T3111Spi {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    public static long ReadAt(int pid, int off) {
        int len = 8 << 20;
        for (int tries = 0; tries < 4; tries++, len *= 2) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                int ret;
                int st = NtQuerySystemInformation(5, buf, len, out ret);
                if ((uint)st == 0xC0000004u) continue;
                if (st != 0) return -1;
                long p = buf.ToInt64();
                while (true) {
                    if (Marshal.ReadIntPtr(new IntPtr(p + 0x50)).ToInt64() == pid) return Marshal.ReadInt64(new IntPtr(p + off));
                    int next = Marshal.ReadInt32(new IntPtr(p));
                    if (next == 0) return -1;
                    p += next;
                }
            } finally { Marshal.FreeHGlobal(buf); }
        }
        return -1;
    }
}
'@
    }
    # Negative control: the offset the old reader took as kernel time is the
    # process's creation FILETIME. If this ever stops being true the record
    # layout changed and the reader must be re-derived, not kept green.
    $at20 = [T3111Spi]::ReadAt($PID, 0x20)
    $start = (Get-Process -Id $PID).StartTime.ToFileTime()
    Assert 'A1 offset 0x20 is CreateTime (the old reader counted it as kernel time)' ([math]::Abs($at20 - $start) -lt 10000000) "0x20=$at20 StartTime=$start"
    $st = Invoke-Pb @('-SelfTest')
    $st.Lines | ForEach-Object { "     $_" }
    Assert 'A2 perf-baseline -SelfTest exits 0' ($st.Exit -eq 0) "exit $($st.Exit)"
    Assert 'A3 its user, kernel, total and cycle lines all read ok' `
        (@($st.Lines | Where-Object { $_ -match '^SELFTEST (user|kernel|total|cycles) .* ok$' }).Count -eq 4) ''

    # --- B. compare: baseline-1 vs baseline-3 -----------------------------
    ''
    '-- B. -Compare judges idle CPU on its own floor'
    $b13 = Invoke-Pb @('-Compare', "$audit\baseline-1.json,$audit\baseline-3.json")
    $row = Get-Row $b13.Lines 'release.idle.cpu_pct'
    Assert 'B1 baseline-1 vs baseline-3: release idle CPU 0.03 -> 0.21 is OUT' ($row -match '^OUT\s.*idle_cpu_pct\)$') "row: $row"
    Assert 'B2 and the compare exits 1' ($b13.Exit -eq 1) "exit $($b13.Exit)"
    $b23 = Invoke-Pb @('-Compare', "$audit\baseline-2.json,$audit\baseline-3.json")
    $row = Get-Row $b23.Lines 'release.idle.cpu_pct'
    Assert 'B3 control: baseline-2 vs baseline-3 (0.21 both) stays ok' ($row -match '^ok\s.*idle_cpu_pct\)$') "row: $row"
    $row = Get-Row $b23.Lines 'release.busy.cpu_pct'
    Assert 'B4 busy CPU keeps the wide cpu_pct family' ($row -match '\(\+-\S+ cpu_pct\)$') "row: $row"

    # --- C. the T3111 leaves ----------------------------------------------
    ''
    '-- C. new idle leaves are judged as idle CPU'
    $mk = {
        param($cyc, $agentCyc, $busy)
        [ordered]@{ schema = 'ghoztty-perf-baseline/1'; builds = [ordered]@{ release = [ordered]@{
            idle = [ordered]@{ cpu_pct = 0.2; cpu_cycle_pct = $cyc }
            busy = [ordered]@{ cpu_pct = $busy }
            agent = [ordered]@{ idle_cpu_cycle_pct = $agentCyc } } } } | ConvertTo-Json -Depth 6
    }
    $fa = Join-Path $work 'a.json'; $fb = Join-Path $work 'b.json'
    (& $mk 0.10 0.02 20.0) | Set-Content -Path $fa -Encoding ascii
    (& $mk 0.30 0.20 25.0) | Set-Content -Path $fb -Encoding ascii
    $syn = Invoke-Pb @('-Compare', "$fa,$fb")
    $syn.Lines | Where-Object { $_ -match '^(ok|OUT)' } | ForEach-Object { "     $_" }
    Assert 'C1 idle cpu_cycle_pct 0.10 -> 0.30 is OUT' ((Get-Row $syn.Lines 'release.idle.cpu_cycle_pct') -match '^OUT\s.*idle_cpu_pct\)$') ''
    Assert 'C2 agent idle_cpu_cycle_pct 0.02 -> 0.20 is OUT' ((Get-Row $syn.Lines 'release.agent.idle_cpu_cycle_pct') -match '^OUT\s.*idle_cpu_pct\)$') ''
    Assert 'C3 busy 20 -> 25 is within the wide floor' ((Get-Row $syn.Lines 'release.busy.cpu_pct') -match '^ok\s') ''

    # --- D. the descendant walk refuses a recycled parent pid (T3235) ----
    # A process whose parent exited keeps the dead pid as ParentProcessId; once
    # Windows hands that pid to a process in the tree, the stranger looked like
    # its child (one agent sample: a 2.6 GB "session child").
    ''
    '-- D. descendant walk vs a recycled parent pid'
    . (Join-Path $PSScriptRoot 'lib\ProcessMemory.ps1')
    $t0 = Get-Date '2026-11-18T12:00:00'
    $row = { param($id, $pp, $born, $mb) [pscustomobject]@{ ProcessId = $id; ParentProcessId = $pp; CreationDate = $born; Name = "p$id"; PrivatePageCount = $mb * 1MB } }
    $rows = @(
        (& $row 100 1 $t0 10),
        (& $row 200 100 $t0.AddSeconds(1) 12),          # a real child
        (& $row 300 200 $t0.AddSeconds(2) 5),           # a real grandchild
        (& $row 400 200 $t0.AddHours(-1) 2600),         # older than 200: its parent was a dead process that once had pid 200
        (& $row 500 400 $t0.AddSeconds(3) 7),           # the stranger's own child
        (& $row 600 100 $null 1)                        # no creation time: kept, as before
    )
    # Control: the fixture really carries the trap a parent-pid walk falls into.
    Assert 'D0 control: two rows name 200 as parent' (@($rows | Where-Object { $_.ParentProcessId -eq 200 }).Count -eq 2) ''
    # Select-Descendants returns its array whole (`return ,`), so assign it
    # before enumerating: piped straight on, it is ONE item.
    $d1 = Select-Descendants $rows 100
    $got = @($d1 | ForEach-Object { [int]$_.ProcessId } | Sort-Object)
    Assert 'D1 descendants are 200, 300, 600 only' (($got -join ',') -eq '200,300,600') "got $($got -join ',')"
    $got2 = Select-Descendants $rows 400
    Assert 'D2 the stranger still owns its own child' ($got2.Count -eq 1 -and [int]$got2[0].ProcessId -eq 500) "got $($got2.Count)"
    $none = Select-Descendants $rows 999
    Assert 'D3 a pid with no children has none' ($none.Count -eq 0) "got $($none.Count)"

    # E (T3880): -Exe is honoured. `$exe` and `$Exe` are one variable in
    # PowerShell, and the script assigned the default build path before it
    # read the parameter, so every -Exe A/B measured zig-out-release twice.
    # -PrintExe resolves and exits before anything launches.
    $pb = Join-Path $repo 'scripts\perf-baseline.ps1'
    $want = Join-Path $work 'zig-out-t3880\bin\ghoztty.exe'
    $o1 = (& powershell -NoProfile -ExecutionPolicy Bypass -File $pb -Build Release -Exe $want -PrintExe 2>&1 | ForEach-Object { "$_" } | Out-String)
    Assert 'E1 -Exe names the exe the run measures' ($o1 -match [regex]::Escape("PERF BASELINE EXE: $want")) $o1.Trim()
    $o2 = (& powershell -NoProfile -ExecutionPolicy Bypass -File $pb -Build Release -PrintExe 2>&1 | ForEach-Object { "$_" } | Out-String)
    $def = Join-Path $repo 'zig-out-release\bin\ghoztty.exe'
    Assert 'E2 no -Exe keeps the build tree default' ($o2 -match [regex]::Escape("PERF BASELINE EXE: $def")) $o2.Trim()
    $o3 = (& powershell -NoProfile -ExecutionPolicy Bypass -File $pb -Build Debug -Exe 'C:\Users\x\ghoztty.exe' -PrintExe 2>&1 | ForEach-Object { "$_" } | Out-String)
    Assert 'E3 an -Exe outside a zig-out tree is still refused' ($o3 -match 'must be a zig-out') $o3.Trim()

    # --- F. viewer growth across the T3169 control-tab change (T3881) -----
    # baseline-5's viewer.open.growth carries the control tab's driver arena
    # (~40 MB) that baseline-4's never had; scored straight it read as a
    # 6 -> 50 MB regression. A pre-control document is scored against the
    # later one's growth_vs_warm, and only then.
    ''
    '-- F. viewer open growth vs the T3169 control tab'
    $b45 = Invoke-Pb @('-Compare', "$audit\baseline-4.json,$audit\baseline-5.json")
    $row = Get-Row $b45.Lines 'release.viewer.open.growth.private_mb'
    Assert 'F1 baseline-4 vs baseline-5: release viewer growth 6.0 vs growth_vs_warm 10.4 is ok' ($row -match '^ok\s.*\s10\.40\s.*vs b\.growth_vs_warm\)$') "row: $row"
    Assert 'F2 and the compare says the definition changed' (@($b45.Lines | Where-Object { $_ -like 'DEFINITION CHANGED release.viewer.open.growth*' }).Count -eq 1) ''
    $mkv = {
        param([bool]$control, $growth, $warm)
        $v = [ordered]@{ open = [ordered]@{ growth = [ordered]@{ private_mb = $growth } } }
        if ($null -ne $warm) { $v.open.growth_vs_warm = [ordered]@{ private_mb = $warm } }
        if ($control) { $v.control = [ordered]@{ leak = [ordered]@{ private_mb = 40.0 } } }
        [ordered]@{ schema = 'ghoztty-perf-baseline/1'; builds = [ordered]@{ release = [ordered]@{ viewer = $v } } } | ConvertTo-Json -Depth 8
    }
    $va = Join-Path $work 'va.json'; $vb = Join-Path $work 'vb.json'
    # Negative control: a real regression past the control tab still goes OUT.
    (& $mkv $false 6.0 $null) | Set-Content -Path $va -Encoding ascii
    (& $mkv $true 70.0 30.0) | Set-Content -Path $vb -Encoding ascii
    $neg = Invoke-Pb @('-Compare', "$va,$vb")
    Assert 'F3 negative control: growth_vs_warm 6 -> 30 MB is OUT' ((Get-Row $neg.Lines 'release.viewer.open.growth.private_mb') -match '^OUT\s.*vs b\.growth_vs_warm\)$') ''
    # Both documents carry the control tab: growth is scored against growth.
    (& $mkv $true 50.0 10.0) | Set-Content -Path $va -Encoding ascii
    (& $mkv $true 52.0 11.0) | Set-Content -Path $vb -Encoding ascii
    $same = Invoke-Pb @('-Compare', "$va,$vb")
    $row = Get-Row $same.Lines 'release.viewer.open.growth.private_mb'
    Assert 'F4 both post-T3169: growth is scored against growth, untagged' ($row -match '^ok\s.*\s52\.00\s.*mb\)$') "row: $row"
    Assert 'F5 and no definition note' (@($same.Lines | Where-Object { $_ -like 'DEFINITION CHANGED*' }).Count -eq 0) ''

    Complete-TestBody
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard perf-baseline-reader -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T3111 PERF-BASELINE READER' -Pass $script:passes -Fail $script:failures
