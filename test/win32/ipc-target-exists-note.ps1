# T135 acceptance: `+new-window --target=<name>` against an EXISTING target
# focuses it (idempotent, exit 0) but must no longer be silent about the
# flags it drops: the server replies outcome=focused plus a note naming the
# ignored flags, and the CLI prints that note to stderr. The CLI's own
# auto-inserted cwd (marked --cwd-implicit) must NOT trigger the note.
#
#   powershell -NoProfile -File test\win32\ipc-target-exists-note.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t135-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    # T900: the PASS arm counts too. It did not until the shared scorer arrived
    # here, and a verdict that reads `$script:failures -eq 0` as ALL PASS is the
    # T271 defect verbatim - a run whose fixture died before the first assertion
    # scored green with nothing measured.
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't135')

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}

# Run one CLI call with stdout/stderr split into files; returns the exit code.
function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Exe`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Get-List {
    cmd /c "`"$Exe`" +list > `"$tmp\list.txt`" 2>&1" | Out-Null
    Get-Content "$tmp\list.txt" -Raw
}
function Wait-ListMatch([string]$Pattern, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $l = Get-List
        if ($l -match $Pattern) { return $l }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $l
}

# T900: a RED run's transcript is copied somewhere the next re-run cannot
# truncate, and the verdict line names it. See lib\Transcript.ps1.
. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't135'

& {

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== 1: fresh create is quiet"
$code = Invoke-Cli "+new-window --target=t135win"
Assert "create exit 0" ($code -eq 0)
[void](Wait-ListMatch '\[target: t135win\]')
Assert "no note on create" ([string]::IsNullOrWhiteSpace((Get-CliErr)))

"== 2: focus with create-only flags prints the note, exit stays 0"
$code = Invoke-Cli "+new-window --target=t135win --working-directory=$env:TEMP --command=whoami"
Assert "focus exit 0" ($code -eq 0)
$err = Get-CliErr
Assert "note names the target" ($err -match "target 't135win' already exists")
Assert "note names --command" ($err -match '--command')
Assert "note names --working-directory" ($err -match '--working-directory')
Assert "note suggests +close" ($err -match '\+close')
# The request must have been a focus, not a create: still exactly one window
# with that target name in the list.
$list = Get-List
Assert "still one t135win" (([regex]::Matches($list, '\[target: t135win\]')).Count -eq 1)

"== 3: bare re-focus stays silent (implicit cwd never counts)"
$code = Invoke-Cli "+new-window --target=t135win"
Assert "bare focus exit 0" ($code -eq 0)
Assert "no note on bare focus" ([string]::IsNullOrWhiteSpace((Get-CliErr)))

"== 4: explicit --working-directory alone still warns"
$code = Invoke-Cli "+new-window --target=t135win --working-directory=$env:TEMP"
Assert "explicit-cwd focus exit 0" ($code -eq 0)
$err = Get-CliErr
Assert "note names --working-directory only" (($err -match '--working-directory') -and ($err -notmatch '--command'))

"== 5: T968 - +new-window --name (no --split) names the first pane"
$code = Invoke-Cli "+new-window --name=t968pane"
Assert "named create exit 0" ($code -eq 0)
Assert "no note on named create" ([string]::IsNullOrWhiteSpace((Get-CliErr)))
# The defect: exit 0, then the very next --target=<name> said "not found".
$deadline = (Get-Date).AddSeconds(20)
do {
    $code = Invoke-Cli "+read --name=t968pane"
    if ($code -eq 0) { break }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
Assert "+read --name=<name> finds the pane (exit $code; $(Get-CliErr))" ($code -eq 0)
$code = Invoke-Cli "+send-keys --target=t968pane x"
Assert "+send-keys --target=<name> finds the pane (exit $code; $(Get-CliErr))" ($code -eq 0)
$windowsBefore = ([regex]::Matches((Get-List), '(?m)^\S.*window')).Count

"== 6: T968 - a second +new-window --name=<live pane> focuses it, and says what it dropped"
$code = Invoke-Cli "+new-window --name=t968pane --command=whoami"
Assert "re-name exit 0" ($code -eq 0)
$err = Get-CliErr
Assert "note names the pane" ($err -match "pane 't968pane' already exists")
Assert "note names --command" ($err -match '--command')
Assert "note does not list --name as dropped" ($err -notmatch '--name')
Start-Sleep -Milliseconds 1000
$windowsAfter = ([regex]::Matches((Get-List), '(?m)^\S.*window')).Count
Assert "no second window opened ($windowsBefore -> $windowsAfter)" ($windowsAfter -eq $windowsBefore)

"== teardown"
Invoke-Cli "+close --target=t968pane" | Out-Null
Invoke-Cli "+close --target=t135win" | Out-Null
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

""
# T900: the verdict now goes through the shared scorer (T271/T1039) as well as
# the transcript keeper - this script used to hand-roll `ALL PASS`/`exit 0`, so
# a run that asserted nothing scored green.
Complete-TestBody  # T1039: the run reached the end of its body
exit (Complete-TestTranscript -Name 't135' -Path $transcript `
        -Label 'T135 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
