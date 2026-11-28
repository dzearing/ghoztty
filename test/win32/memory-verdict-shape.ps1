# T2673 acceptance: test\win32\lib\MemoryVerdictShape.ps1, the rule that says
# which memory-harness runs may stamp their guard.
#
#   A. The default window-close-memory run (no args, or -ExePath naming this
#      checkout's own zig-out exe, or more cycles) has the verdict shape: no
#      reasons, so it stamps.
#   B. Every diagnostic switch is a reason on its own - the 2026-11-03 shape
#      (-ReleaseSandbox -Report against a ReleaseFast -ExePath) first, then
#      each bisect / census / warm-up knob - and a one-reason run still counts
#      as one (the PS 5.1 unroll trap).
#   C. Test-RepoDefaultExe: unset and this checkout's exe are default; another
#      checkout's, a zig-out-release exe, and garbage are not.
#   D. Wiring: window-close-memory.ps1 and hidden-window-memory.ps1 dot-source
#      the lib, gate their stamp on it, and print NOT STAMPED when refused.
#
#   -NegativeControl adds one inverted assertion a healthy tree MUST fail, so
#   the run ends with exactly one failure.
#
# Pure: launches nothing.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\MemoryVerdictShape.ps1')

$script:fail = 0
$script:pass = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" }
}
function Reasons { param([hashtable]$A) @(Get-WindowCloseMemoryDiagnosticReason -Repo $repo @A) }

try {
$own = Join-Path $repo 'zig-out\bin\ghoztty.exe'

Write-Host '--- A. verdict shape stamps ---'
Assert (@(Reasons @{}).Count -eq 0) 'a bare run has no diagnostic reason'
Assert (@(Reasons @{ ExePath = $own }).Count -eq 0) "-ExePath naming this checkout's zig-out exe is still the verdict"
Assert (@(Reasons @{ ExePath = $own.ToUpperInvariant() }).Count -eq 0) '...compared case-insensitively'
Assert (@(Reasons @{ Cycles = 20 }).Count -eq 0) 'more cycles than the default is still the verdict'
Assert (@(Reasons @{ AppArgs = @() }).Count -eq 0) 'an empty -AppArgs is not a reason'

Write-Host '--- B. diagnostic runs do not ---'
$rel = Join-Path $repo 'zig-out-release\bin\ghoztty.exe'
$nov3 = @(Reasons @{ ExePath = $rel; ReleaseSandbox = $true; Report = $true })
Assert ($nov3.Count -eq 3) "the 2026-11-03 run (-ReleaseSandbox -Report, release -ExePath) has 3 reasons (got $($nov3.Count): $($nov3 -join '; '))"
Assert (($nov3 -join ' ') -match '-ReleaseSandbox' -and ($nov3 -join ' ') -match '-Report' -and ($nov3 -join ' ') -match 'zig-out-release') '...and names each of them'
$cases = [ordered]@{
    'ReleaseSandbox'     = @{ ReleaseSandbox = $true }
    'Report'             = @{ Report = $true }
    'Shape single'       = @{ Shape = 'single' }
    'Cycles 5'           = @{ Cycles = 5 }
    'Warmup 4'           = @{ Warmup = 4 }
    'Warmup 0'           = @{ Warmup = 0 }
    'MaxWarmup 0'        = @{ MaxWarmup = 0 }
    'AppArgs'            = @{ AppArgs = @('--undo-timeout=0') }
    'Resize'             = @{ Resize = $true }
    'CloseSplitFirst'    = @{ CloseSplitFirst = $true }
    'HeapCensus'         = @{ HeapCensus = $true }
    'HeapCensusCommands' = @{ HeapCensusCommands = @('!heap -s') }
    'HeapCensusRegions'  = @{ HeapCensusRegions = $true }
    'NegativeControl'    = @{ NegativeControl = $true }
    'foreign ExePath'    = @{ ExePath = 'C:\elsewhere\ghoztty.exe' }
}
foreach ($k in $cases.Keys) {
    $got = @(Reasons $cases[$k])
    Assert ($got.Count -eq 1) "$k alone is exactly one reason (got $($got.Count))"
}

Write-Host '--- C. Test-RepoDefaultExe ---'
Assert (Test-RepoDefaultExe $repo '') 'unset -ExePath is the default exe'
Assert (Test-RepoDefaultExe $repo $own) "this checkout's zig-out exe is the default"
Assert (-not (Test-RepoDefaultExe $repo $rel)) 'a zig-out-release exe is not'
Assert (-not (Test-RepoDefaultExe $repo 'D:\some\other\checkout\zig-out\bin\ghoztty.exe')) "another checkout's exe is not"
Assert (-not (Test-RepoDefaultExe $repo ([string][char]0))) 'an unparseable path is not (and does not throw)'

if ($NegativeControl) {
    Assert (@(Reasons @{ ReleaseSandbox = $true }).Count -eq 0) 'NEGATIVE CONTROL: a sandbox run must not read as the verdict (this must FAIL)'
}

Write-Host '--- D. wiring ---'
$wcm = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'window-close-memory.ps1'))
Assert ($wcm.Contains("lib\MemoryVerdictShape.ps1")) 'window-close-memory.ps1 dot-sources the lib'
Assert ($wcm -match '\$diag = @\(Get-WindowCloseMemoryDiagnosticReason' -and $wcm -match '\$diag\.Count -eq 0\) \{') 'window-close-memory.ps1 stamps only when the lib names no reason'
Assert ($wcm -match '-ReleaseSandbox:\$ReleaseSandbox' -and $wcm -match '-Report:\$Report' -and $wcm -match '-ExePath \$ExePath') '...and hands the lib the sandbox, -Report and -ExePath it ran with'
Assert ($wcm.Contains('NOT STAMPED (diagnostic run')) '...and says NOT STAMPED when it refuses'
$hwm = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'hidden-window-memory.ps1'))
Assert ($hwm.Contains("lib\MemoryVerdictShape.ps1") -and $hwm -match 'Test-RepoDefaultExe \$repo \$ExePath') 'hidden-window-memory.ps1 checks -ExePath through the lib'
Assert ($hwm -match '-and -not \$foreignExe\) \{' -and $hwm.Contains('NOT STAMPED (diagnostic run')) '...gates its stamp on it and says NOT STAMPED'

Complete-TestBody  # T1039: the run reached the end of its body
} finally { }

# --- stamp (T783) -----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard memory-verdict-shape -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'MEMORY-VERDICT-SHAPE' -MinPass 30
