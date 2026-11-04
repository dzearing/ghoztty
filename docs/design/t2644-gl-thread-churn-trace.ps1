# T2644: run glchurn.exe on the test desktop and log the stack of every committing
# NtAllocateVirtualMemory (cdb invasive attach), stopping after -Hits.
# Third repro argument is the FLAGS bitmask (header of t2644-gl-thread-churn.zig); mode 7 = 3 GL-free threads per iteration beside a live context.
param([int]$Flags = 0, [int]$N = 3000, [int]$Mode = 6, [int]$Hits = 150, [int]$AttachAfterMs = 4000)
. 'D:\git\ghoztty\test\win32\lib\TestDesktop.ps1'
. 'D:\git\ghoztty\scripts\lib\CrashCatch.ps1'
$cdb = Get-CdbPath
$exe = Join-Path $PSScriptRoot 'glchurn.exe'
$err = Join-Path $PSScriptRoot "trace-out-$Mode.txt"
$log = Join-Path $PSScriptRoot "trace-cdb-$Mode.txt"
$cf = Join-Path $PSScriptRoot "trace-$Mode.cdb"
$bpf = Join-Path $PSScriptRoot "trace-bp-$Mode.txt"
@(
    '.if (dwo(@rsp+28) & 0x1000) {',
    '  r $t1 = @$t1 + 1',
    '  .printf "ALLOC size=%p tid=%x\n", poi(@r9), @$tid',
    '  kn 14',
    ('  .if (@$t1 > 0n' + $Hits + ') { qd }'),
    '}',
    'gc'
) | Set-Content -Path $bpf -Encoding ascii
@(
    'r $t1 = 0',
    ('bp ntdll!NtAllocateVirtualMemory "$$><' + ($bpf -replace '\\', '\\') + '"'),
    'g'
) | Set-Content -Path $cf -Encoding ascii
$td = New-TestDesktop
try {
    $p = Start-OnTestDesktop -Exe $exe -Arguments @("$N", "$Mode", "$Flags") -StdErr $err
    Start-Sleep -Milliseconds $AttachAfterMs
    $sym = 'srv*https://msdl.microsoft.com/download/symbols'
    & $cdb -p $p.Pid -y $sym -cf $cf 2>&1 | ForEach-Object { "$_" } | Out-File -FilePath $log -Encoding utf8
    $deadline = (Get-Date).AddMinutes(4)
    while ((Get-Process -Id $p.Pid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}
finally { Remove-TestDesktop }
"cdb log: $log"
Get-Content $err | Select-Object -Last 3
