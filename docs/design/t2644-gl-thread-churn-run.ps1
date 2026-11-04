param([int]$N = 60, [int]$Mode = 1, [int]$Flags = 0)
. 'D:\git\ghoztty\test\win32\lib\TestDesktop.ps1'
$exe = Join-Path $PSScriptRoot 'glchurn.exe'
$err = Join-Path $PSScriptRoot "out-$Mode-$Flags.txt"
Remove-Item $err -ErrorAction SilentlyContinue
$td = New-TestDesktop
try {
    $p = Start-OnTestDesktop -Exe $exe -Arguments @("$N", "$Mode", "$Flags") -StdErr $err
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Process -Id $p.Pid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    Start-Sleep -Milliseconds 500
}
finally { Remove-TestDesktop }
Get-Content $err
