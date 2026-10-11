# T1823 acceptance: scripts\focus-pull-scan.ps1, the claim's report of a shell
# "How do you want to open this file?" picker left on the user's desktop.
#
#   A. Constructed state, never a real picker: -ProcessJson stands in for the
#      live process list, so this harness puts nothing on anybody's screen.
#      One picker -> FOCUS PULL naming its pid and start time; two -> both;
#      none (and garbage input) -> silent. Every arm exits 0: the report must
#      never be able to fail the claim.
#   B. Wiring: go-loop-exec.ps1 claim calls the script and indents its lines.
#   C. The live list runs at all (whatever it finds, it exits 0).
#
#   -NegativeControl adds one inverted assertion a healthy tree MUST fail, so
#   the run ends with exactly one failure.
#
# Non-interactive. Launches nothing that shows a window.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$scan = Join-Path $repo 'scripts\focus-pull-scan.ps1'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:fail = 0
$script:pass = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" }
}

function Invoke-Scan([string]$json) {
    # In-process, not a child powershell: PS 5.1 strips the embedded quotes
    # from a JSON argument on its way through a native command line.
    $global:LASTEXITCODE = 0
    $out = & $scan -ProcessJson $json 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
}

try {
Write-Host '--- A. constructed state ---'
$one = Invoke-Scan '[{"ProcessId":59836,"CreationDate":"2026-10-11 00:17:52","CommandLine":"C:\\WINDOWS\\system32\\OpenWith.exe -Embedding"}]'
Assert ($one.Out -match 'FOCUS PULL: 1 ') 'one picker reports FOCUS PULL with a count of 1'
Assert ($one.Out -match 'pid 59836 since 2026-10-11 00:17:52') 'the report names the pid and when it appeared'
Assert ($one.Out -match 'T1823') 'the report names the known caller task'
Assert ($one.Exit -eq 0) 'a picker never fails the claim (exit 0)'

$two = Invoke-Scan '[{"ProcessId":26580,"CreationDate":"2026-10-10 10:52:25"},{"ProcessId":59836,"CreationDate":"2026-10-11 00:17:52"}]'
Assert (($two.Out -match 'FOCUS PULL: 2 ') -and ($two.Out -match 'pid 26580') -and ($two.Out -match 'pid 59836')) `
    'two pickers are both named'

$none = Invoke-Scan '[]'
Assert (-not $none.Out.Trim()) 'no picker -> silent'
Assert ($none.Exit -eq 0) 'no picker -> exit 0'
$junk = Invoke-Scan 'not json'
Assert ((-not $junk.Out.Trim()) -and $junk.Exit -eq 0) 'garbage input -> silent, exit 0'

if ($NegativeControl) {
    Assert ($none.Out -match 'FOCUS PULL') 'NEGATIVE CONTROL: an empty list must not report (this must FAIL)'
}

Write-Host '--- B. wiring ---'
$exec = [IO.File]::ReadAllText((Join-Path $repo 'scripts\go-loop-exec.ps1'))
Assert ($exec.Contains("'focus-pull-scan.ps1'")) 'claim calls focus-pull-scan.ps1'

Write-Host '--- C. live list ---'
$live = & powershell -NoProfile -ExecutionPolicy Bypass -File $scan 2>&1 | ForEach-Object { $_.ToString() } | Out-String
Assert ($LASTEXITCODE -eq 0) "the live scan runs and exits 0 ($(if ($live.Trim()) { 'it reports a picker' } else { 'nothing to report' }))"

Complete-TestBody  # T1039: the run reached the end of its body
} finally { }

# --- stamp (T783) -----------------------------------------------------------
# A green run records the content of every file this harness covers; a red run
# leaves the stamp alone on purpose - red must stay due.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard focus-pull-scan -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'FOCUS-PULL-SCAN' -MinPass 9
