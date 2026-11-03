param([string]$Base, [string]$End)
function Sum([string]$p) { $h=@{}; foreach ($l in Get-Content $p) { if ($l -match '^REGION (0x[0-9a-f`]+) (0x[0-9a-f`]+)') { $a=[Convert]::ToUInt64(($matches[1] -replace '`','').Substring(2),16); $z=[Convert]::ToUInt64(($matches[2] -replace '`','').Substring(2),16); $k=[math]::Floor($a/1GB); $h[$k]=[double]$h[$k]+$z } }; $h }
$b=Sum $Base; $e=Sum $End
$keys = @($b.Keys) + @($e.Keys) | Sort-Object -Unique
$keys | ForEach-Object { [pscustomobject]@{ GB=('{0:x}' -f ([uint64]$_*1GB)); BaseMB=[math]::Round([double]$b[$_]/1MB,1); EndMB=[math]::Round([double]$e[$_]/1MB,1); DeltaMB=[math]::Round(([double]$e[$_]-[double]$b[$_])/1MB,1) } } | Where-Object { [math]::Abs($_.DeltaMB) -ge 0.3 } | Format-Table -AutoSize | Out-String
