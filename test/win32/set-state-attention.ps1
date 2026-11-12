# set-state-attention.ps1 - T2907 acceptance: a pane that starts waiting on the
# user flashes its background window's taskbar button, the Windows translation
# of Mac's Dock bounce (BaseTerminalController.setupActivityStatePublisher ->
# NSApp.requestUserAttention).
#
#   0. needs_input on the ACTIVE window (the launch window, which keeps the
#      activation on the test desktop) is logged `active=true flash=false`:
#      the user is looking at it.
#   1. `+set-state --state=needs_input` on a pane of a background window asks
#      for attention once: the app logs `activity attention needs_input=true
#      active=false flash=true`.
#   2. A repeat `needs_input` is not a transition: no second request.
#   3. A window target that is already needs_input asks nothing either.
#   4. Back to idle logs the move out (flash=false); needs_input again asks
#      again - once per transition, never per set.
#   5. OSC 7777 from inside the pane takes the same route as the CLI.
#
# On the test desktop the launch window stays the active one, so it stages
# "the user is looking at it" and a CLI-opened second window stages "in the
# background" without ever touching the user's own foreground. The rule itself
# is unit-tested in activity_attention.zig.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects a SECOND flash on the repeat set, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\set-state-attention.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2907-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2907')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Wait-Log([int]$From, [string]$Pattern, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From) |
            Where-Object { $_ -match $Pattern } | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
function Count-Log([int]$From, [string]$Pattern) {
    @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From |
        Where-Object { $_ -match $Pattern }).Count
}

$FlashLine = 'activity attention needs_input=true active=false flash=true'
$OutLine = 'activity attention needs_input=false .*flash=false'

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2907'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @(
        '--session-persistence=false',
        '--command=powershell.exe -NoLogo'
    )
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))

    # A second window holds the pane under test. The launch window keeps the
    # activation on the test desktop (a CLI-opened window does not take it),
    # so the second window is in the background. `--name` on +new-window
    # names its first PANE; the window's own target is read from +list.
    Assert "setup: +new-window (first pane wa) exit 0 ($(Get-CliErr))" ((Invoke-Cli "+new-window --name=wa --shell=powershell") -eq 0)
    Start-Sleep -Milliseconds 1500
    Assert "setup: +split s1 beside wa exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --target=wa --direction=right --name=s1 --shell=powershell") -eq 0)
    Start-Sleep -Milliseconds 1500
    [void](Invoke-Cli "+list --json")
    $activeTarget = $null; $winName = $null
    try {
        $json = Get-Content "$tmp\out.txt" -Raw | ConvertFrom-Json
        foreach ($w in @($json.data.windows | ForEach-Object { $_ })) {
            $raw = $w | ConvertTo-Json -Depth 30 -Compress
            if ($w.focused) { $activeTarget = $w.target }
            if ($raw -match '"name":"s1"') { $winName = $w.target }
        }
    } catch { "  +list parse failed: $($_.Exception.Message)" }
    "  active window: $activeTarget; s1's window: $winName"
    Assert "setup: +list names an active window and s1's window, and they differ" (
        $activeTarget -and $winName -and $activeTarget -ne $winName)
    Assert "setup: no flash was asked for before any state was set" ((Count-Log 0 'flash=true') -eq 0)

    "== 0: needs_input on the ACTIVE window is logged without a flash"
    $mark = Get-LogCount
    Assert "+set-state $activeTarget needs_input exit 0 ($(Get-CliErr))" ((Invoke-Cli "+set-state --target=$activeTarget --state=needs_input") -eq 0)
    $act = Wait-Log $mark 'activity attention needs_input=true active=true flash=false' 4000
    "  $act"
    Assert "the active window did not flash (log)" ($null -ne $act)
    $mark = Get-LogCount
    Assert "+set-state $activeTarget idle exit 0" ((Invoke-Cli "+set-state --target=$activeTarget --state=idle") -eq 0)
    [void](Wait-Log $mark $OutLine 4000)

    "== 1: needs_input on a pane of a background window flashes once"
    $mark = Get-LogCount
    Assert "+set-state s1 needs_input exit 0 ($(Get-CliErr))" ((Invoke-Cli "+set-state --target=s1 --state=needs_input") -eq 0)
    $hit = Wait-Log $mark ([regex]::Escape($FlashLine)) 4000
    "  $hit"
    Assert "the app asked for attention (log)" ($null -ne $hit)

    "== 2: a repeat needs_input is not a transition"
    $mark = Get-LogCount
    Assert "+set-state s1 needs_input again exit 0" ((Invoke-Cli "+set-state --target=s1 --state=needs_input") -eq 0)
    "== 3: a window target while already needs_input asks nothing"
    if ($winName) {
        Assert "+set-state <window> needs_input exit 0 ($(Get-CliErr))" ((Invoke-Cli "+set-state --target=$winName --state=needs_input") -eq 0)
    }
    Start-Sleep -Milliseconds 1200
    $repeats = Count-Log $mark 'activity attention'
    $want = if ($NegativeControl) { 1 } else { 0 }
    Assert "no attention line for the repeats (saw $repeats, want $want)" ($repeats -eq $want)

    "== 4: out to idle and back flashes again"
    $mark = Get-LogCount
    Assert "+set-state <window> idle exit 0" ((Invoke-Cli "+set-state --target=$winName --state=idle") -eq 0)
    $out = Wait-Log $mark $OutLine 4000
    "  $out"
    Assert "the move out of needs_input is logged without a flash" ($null -ne $out)
    $mark = Get-LogCount
    Assert "+set-state s1 needs_input exit 0" ((Invoke-Cli "+set-state --target=s1 --state=needs_input") -eq 0)
    $again = Wait-Log $mark ([regex]::Escape($FlashLine)) 4000
    Assert "a fresh transition flashes again (log)" ($null -ne $again)
    $mark = Get-LogCount
    Assert "+set-state <window> idle exit 0" ((Invoke-Cli "+set-state --target=$winName --state=idle") -eq 0)
    [void](Wait-Log $mark $OutLine 4000)

    "== 5: OSC 7777 from inside the pane takes the same route"
    $mark = Get-LogCount
    $osc = $null
    for ($try = 0; $try -lt 4 -and -not $osc; $try++) {
        [void](Invoke-Cli "+send-keys --target=s1 `"[Console]::Write([char]27 + ']7777;needs_input' + [char]7)`" Enter")
        $osc = Wait-Log $mark ([regex]::Escape($FlashLine)) 2500
    }
    "  $osc"
    Assert "OSC 7777 needs_input asked for attention (log)" ($null -ne $osc)

    if ($script:failures -gt 0) {
        "  -- app log, attention/state lines --"
        Get-Content $script:errlog -ErrorAction SilentlyContinue |
            Where-Object { $_ -match 'attention|set.state|7777|new.window|lookup|registry' } | Select-Object -Last 40 | ForEach-Object { "  | $_" }
        [void](Invoke-Cli "+list --json")
        "  +list: $((Get-Content "$tmp\out.txt" -Raw) -replace '\s+', ' ')" | ForEach-Object { $_.Substring(0, [Math]::Min(1500, $_.Length)) }
    }
    Assert "no crash" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard set-state-attention -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2907' -Path $transcript `
        -Label 'T2907 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
