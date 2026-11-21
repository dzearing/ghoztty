# P2 acceptance (spec Phases P2 / tracker T12): +split, +rename, +send-keys
# against a debug build. Non-interactive; exits nonzero on any failure.
# Only ever touches ghoztty processes running from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\ipc-p2.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-p2-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T441: give this run its OWN IPC endpoint before any CLI call. Without it every
# `& $Exe` below inherits the caller pane's baked `$GHOZTTY_IPC_SOCKET` — this
# floor would measure the user's INSTALLED release, and `+send-keys` would type
# into their live panes.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ipcp2')

# T1193: every CLI call runs ON THE TEST DESKTOP. `+new-window` auto-launches
# the app, and the window lands on the desktop of the process that spawned it -
# so this floor threw a window across the user's screen on every run.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Exact-exe matching is still the rule (T53b); the reset now also kills the
# sibling agent and drops the debug session-layout manifest, so a pane this
# script created in a PREVIOUS run cannot be focused in place of the fixture.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}
# Every CLI call goes through here (T1193). The harness captures the child's
# stdout and stderr to a file, which is what the old `cmd /c ... > file` dance
# was for: a GUI-subsystem exe writes zero bytes to a PowerShell `>` (T245).
function Ghoz([string[]]$GhozArgs) {
    return Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
}
# T1285: a call the run cannot continue without - see lib\FloorFixture.ps1.
. (Join-Path $PSScriptRoot 'lib\FloorFixture.ps1')
function Need([string]$What, [string[]]$GhozArgs) {
    return Need-Ghoz -What $What -GhozArgs $GhozArgs -Exe $Exe
}
function Get-List {
    return (Ghoz @('+list')).Output
}
function Get-IdeJson {
    # T1285: the JSON comes off STDOUT alone. Sharing one stream with the CLI's
    # diagnostics is how a 5s "Waiting for Ghoztty to answer" notice turned a
    # slow answer into "Invalid JSON primitive: Waiting."
    # T894: and a snapshot that does not parse stops the run with ONE setup
    # failure carrying the raw answer. Returning $null here instead lets every
    # caller below raise `Cannot index into a null array`, which is neither a
    # PASS nor a FAIL and so leaves its assertions unscored.
    $jsonArgs = @('+list', '--json')
    $call = Ghoz $jsonArgs
    $j = $null
    try { $j = $call.StdOut | ConvertFrom-Json } catch {}
    Need-Parsed 'the +list --json snapshot' $jsonArgs $call $j
    $j.data.windows | Where-Object { $_.target -eq 'p2ide' }
}

# T1727: the same snapshot for a POLL. A parse failure here is "not yet", never
# a scored setup failure - Need-Parsed inside a poll would score once per
# attempt (the P3 rearranged-tree wait reads raw for the same reason). The
# asserted snapshot after each wait still goes through the checked Get-IdeJson.
function Get-IdeJsonRaw {
    $j = $null
    try { $j = (Ghoz @('+list', '--json')).StdOut | ConvertFrom-Json } catch {}
    if ($null -eq $j) { return $null }
    $j.data.windows | Where-Object { $_.target -eq 'p2ide' }
}

function Get-IdeLeafCount($ide) {
    if ($null -eq $ide) { return -1 }
    return ([regex]::Matches(($ide | ConvertTo-Json -Depth 15), '"type":\s*"leaf"')).Count
}

# T379: poll +list until a pattern shows, so the FIRST launch of a
# just-replaced exe (cold: Defender scan, no cache) cannot outrun a fixed
# sleep. Warm runs resolve on the first poll.
function Wait-ListMatch([string]$Pattern, [int]$TimeoutSec = 20) {
    # T1677: one shared poll whose window is granted ON TOP of one +list
    # call's own bound, so a single cold call cannot spend the whole wait.
    return Wait-FloorListMatch -Pattern $Pattern -TimeoutSec $TimeoutSec -GetList { Get-List }
}

# T379: tee every PASS/FAIL line to a transcript so a red run keeps its
# evidence past a `| Select-Object -Last 1` summary; the trailer names it.
# T900: and a RED one is COPIED somewhere the next re-run cannot truncate -
# the 2026-08-16 flake's transcript was overwritten by the green re-run that
# followed it ninety seconds later. See lib\Transcript.ps1.
. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 'ipc-p2'

$td = New-TestDesktop

& {

Invoke-FloorBody {

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== 1: three-pane layout by name (docs/claude/cli.md example shape)"
[void](Need 'the p2ide fixture window' @('+new-window', '--target=p2ide'))
# Cold-launch guard first (T379); the settle sleep after it stays, because the
# later +send-keys sections need the pane's shell up, not just the window row.
Need-Listed 'the p2ide fixture window' '\[target: p2ide\]' (Wait-ListMatch '\[target: p2ide\]')
Start-Sleep -Seconds 3
# Before the first +send-keys: prove the instance answering is ours.
Assert-GhozttyIsolated -Exe $Exe
# T1727: every effect below is POLLED for, bounded by Wait-FloorState's clock
# (the T1156 fix P3 already carries), instead of read once after a fixed sleep
# that a slow box outruns. NominalMs is the sleep each wait replaced, so a run
# that only settles past it says so with a NOTE SLOW STATE line.
$r = Ghoz @('+split', '--target=p2ide', '--name=p2term', '--direction=down')
Assert "split 1 exit 0" ($r.ExitCode -eq 0)
# The second split goes in only once the first is registered.
[void](Wait-FloorState 'the p2term pane' -NominalMs 1000 { (Get-List) -match '\[name: p2term\]' })
$r = Ghoz @('+split', '--target=p2ide', '--name=p2logs', '--direction=right')
Assert "split 2 exit 0" ($r.ExitCode -eq 0)
$script:p2List = ''
[void](Wait-FloorState 'the three-pane layout' -NominalMs 2000 {
    $script:p2List = Get-List
    ($script:p2List -match '\[name: p2term\]') -and ($script:p2List -match '\[name: p2logs\]') -and
        ((Get-IdeLeafCount (Get-IdeJsonRaw)) -eq 3)
})
$list = $script:p2List
Assert "p2term registered" ($list -match '\[name: p2term\]')
Assert "p2logs registered" ($list -match '\[name: p2logs\]')
$ide = Get-IdeJson
$ideText = $ide | ConvertTo-Json -Depth 15
Assert "3 leaves in p2ide" (([regex]::Matches($ideText, '"type":\s*"leaf"')).Count -eq 3)

"== 2: idempotent +split --name (no new pane)"
$r = Ghoz @('+split', '--target=p2ide', '--name=p2term', '--direction=down')
Assert "exit 0" ($r.ExitCode -eq 0)
# T1727: the one settle that stays. "No new pane" has no positive state to poll
# for - the leaf that must NOT appear never does - so this is the window a late
# duplicate gets to show up in, not a guess at when an effect lands.
Start-Sleep -Seconds 1
$ideText = Get-IdeJson | ConvertTo-Json -Depth 15
Assert "still 3 leaves" (([regex]::Matches($ideText, '"type":\s*"leaf"')).Count -eq 3)

"== 3: +split --pane targeting"
$r = Ghoz @('+split', '--pane=p2term', '--direction=right', '--name=p2deep', '--percent=30')
Assert "exit 0" ($r.ExitCode -eq 0)
[void](Wait-FloorState 'the p2deep split' -NominalMs 2000 {
    $t = Get-IdeJsonRaw | ConvertTo-Json -Depth 15
    ($t -match 'p2deep') -and ($t -match '0\.7')
})
$ideText = Get-IdeJson | ConvertTo-Json -Depth 15
Assert "p2deep created" ($ideText -match 'p2deep')
Assert "percent ratio applied" ($ideText -match '0\.7')

"== 4: +send-keys executes (shell title change observable via +list)"
$r = Ghoz @('+send-keys', '--target=p2term', 'title P2-SENT-OK', 'Enter')
Assert "exit 0" ($r.ExitCode -eq 0)
Assert "command ran in pane" (Wait-FloorState 'the P2-SENT-OK shell title' -NominalMs 2000 { (Get-List) -match 'P2-SENT-OK' })

"== 5: +send-keys escapes (\n) and C-c accepted"
[void](Ghoz @('+send-keys', '--target=p2term', 'title P2-ESCAPED\n'))
Assert "escape-run title" (Wait-FloorState 'the P2-ESCAPED shell title' -NominalMs 2000 { (Get-List) -match 'P2-ESCAPED' })
$r = Ghoz @('+send-keys', '--target=p2term', 'C-c')
Assert "C-c exit 0" ($r.ExitCode -eq 0)

"== 6: +send-keys missing target errors"
$r = Ghoz @('+send-keys', '--target=p2ghost', 'x')
Assert "nonzero exit" ($r.ExitCode -ne 0)

"== 7: +rename override wins over terminal titles"
$r = Ghoz @('+rename', '--target=p2ide', '--title=P2-OVERRIDE')
Assert "rename exit 0" ($r.ExitCode -eq 0)
# Debug builds append a " [DEBUG]" marker inside the quoted title.
Assert "window title is override" (Wait-FloorState 'the P2-OVERRIDE window title' -NominalMs 1000 { (Get-List) -match 'Window: "P2-OVERRIDE( \[DEBUG\])?"' })
[void](Ghoz @('+send-keys', '--target=p2term', 'title P2-SHELL-FIGHTS\n'))
# T1727: wait for the POSITIVE (the shell's title reached the tab) first, and
# only then read the negative from that same snapshot - "override still wins"
# would otherwise pass on a title the shell simply had not changed yet.
$script:p2List = ''
Assert "tab title tracks shell" (Wait-FloorState 'the P2-SHELL-FIGHTS tab title' -NominalMs 2000 {
    $script:p2List = Get-List
    $script:p2List -match 'P2-SHELL-FIGHTS'
})
Assert "override still wins" ($script:p2List -match 'Window: "P2-OVERRIDE( \[DEBUG\])?"')

"== 8: +rename missing target errors"
$r = Ghoz @('+rename', '--target=p2ghost', '--title=x')
Assert "nonzero exit" ($r.ExitCode -ne 0)

}  # Invoke-FloorBody - teardown below runs whether or not the body stopped early

"== teardown"
[void](Ghoz @('+close', '--target=p2ide'))
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

} 2>&1 | Tee-Object -FilePath $transcript

""
# The verdict goes through the shared scorer (T271), which refuses to call a
# run with zero passing assertions a pass.
Complete-TestBody  # T1039: the run reached the end of its body
# T900: scores, and on a red run appends the verdict to the transcript,
# preserves it under a name no later run writes, and names that file in the
# verdict line - the one line a `-Last 1` summary keeps.
exit (Complete-TestTranscript -Name 'ipc-p2' -Path $transcript `
        -Label 'P2 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
