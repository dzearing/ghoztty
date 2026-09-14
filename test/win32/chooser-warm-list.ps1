# Machine-chooser WARM LIST acceptance (tracker T711).
#
# What was wrong: the chooser learned the account's machines by asking the
# relay ON THE GUI THREAD when the dialog opened, with nothing remembered from
# the last time. So ctrl+shift+n showed an empty list - and, on a slow or dead
# link, an empty list plus a frozen dialog - and once open the list never
# changed again no matter what happened to the machines behind it.
#
# What this drives, end to end, with NO relay account required:
#
#   A. a planted device cache is on screen the moment the dialog is, while the
#      directory fetch behind it is still hanging on a black-holed host. This
#      is the whole defect: the window exists, with rows in it, seconds before
#      any answer could arrive.
#   B. a fetch that FAILS does not empty the list that is already true - the
#      remembered machines stay, and the footer says what happened.
#   C. an open chooser keeps ASKING: with a relay that refuses instantly, the
#      app's own "fetch started ... quiet=true" line appears again and again on
#      the 5s poll, which is what makes a rename or a machine coming online
#      appear under the user's eyes instead of on the next open.
#   D. the poll does not outlive the chooser: closing it stops the ticks.
#
# The credential is `GHOSTTY_RELAY_TOKEN` (the env credential the CLI already
# honours) and the relay base is pointed somewhere that cannot answer, so the
# script never touches the real relay and never needs a signed-in account.
#
# The cache file this plants is the DEBUG build's own (`machines-debug.json`),
# so the user's installed release keeps its list; the previous contents are
# restored on the way out regardless.
#
#   powershell -NoProfile -File test\win32\chooser-warm-list.ps1
#
# Runs on a background test desktop and only touches ghoztty processes running
# from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = "-t711$PID"

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChooserControls.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false
$script:drove = $false

function Assert([bool]$cond, [string]$name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
}

# The list is owner-drawn and LBS_HASSTRINGS-less, so its item COUNT is its
# whole visible output: one item per row `refilter` added.
$LB_GETCOUNT = 0x018B
function Get-RowCount([IntPtr]$List) {
    return [int64](Invoke-TestMessage -Window $List -Message $LB_GETCOUNT)
}

function Count-LogMatches([string]$Path, [string]$Pattern) {
    if (-not (Test-Path $Path)) { return 0 }
    return @(Select-String -Path $Path -Pattern $Pattern -AllMatches).Count
}

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'CHOOSER WARM-LIST ACCEPTANCE' -Reason "$Exe not found"
}
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$tmp = Join-Path $env:TEMP "ghoztty-t711-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# --- plant the cache --------------------------------------------------------
# The DEBUG build's file. `account` is the empty "bare token" bucket, which is
# what a `GHOSTTY_RELAY_TOKEN` credential is keyed under.
$cacheDir = Join-Path $env:LOCALAPPDATA 'ghoztty'
$cachePath = Join-Path $cacheDir 'machines-debug.json'
$cacheBackup = Join-Path $tmp 'machines-debug.json.bak'
$hadCache = Test-Path $cachePath
if ($hadCache) { Copy-Item $cachePath $cacheBackup -Force }
New-Item -ItemType Directory -Force $cacheDir | Out-Null
$seed = '{"account":"","devices":[' +
    '{"id":"t711-a","name":"Warmbox","hostname":"warmbox.local"},' +
    '{"id":"t711-b","name":"Coldbox","hostname":"coldbox.local"}]}'
Set-Content -Path $cachePath -Value $seed -Encoding ascii

$env:GHOSTTY_RELAY_TOKEN = 'acceptance-not-a-real-token'

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # === A + B: a black-holed relay ========================================
    # 10.255.255.1 is a private address nothing answers on: the TCP connect
    # hangs rather than refusing, which is exactly the "slow link" the old
    # synchronous open froze on.
    Write-Host ''
    Write-Host '=== A: the dialog opens on remembered machines, not on the network ==='
    $env:GHOSTTY_RELAY_BASE = 'https://10.255.255.1'
    $errlog = Join-Path $tmp 'hang-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-Host 'SETUP FAIL: GUI died at launch'
        Write-TestVerdict -Label 'CHOOSER WARM-LIST ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: GhozttyWindow not found'
        Write-TestVerdict -Label 'CHOOSER WARM-LIST ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
    $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 20000
    $sw.Stop()
    $openMs = $sw.ElapsedMilliseconds
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opened the chooser'
    if ($chooser -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no chooser to score'
        Write-TestVerdict -Label 'CHOOSER WARM-LIST ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    # The budget is deliberately loose: the point is "did not wait for a
    # network round trip that cannot finish", and a TCP connect to a black hole
    # costs tens of seconds.
    Assert ($openMs -lt 5000) "A the dialog was up in ${openMs}ms with the relay unreachable"

    Start-Sleep -Milliseconds 800
    $list = Get-ChooserList -Chooser $chooser
    Assert ($null -ne $list) 'A the machine list is found'
    $rows = if ($list) { Get-RowCount ([IntPtr]$list.Hwnd) } else { -1 }
    # Local + the two remembered machines.
    Assert ($rows -eq 3) "A the two remembered machines are on screen already (rows=$rows, expected 3)"
    Assert ((Count-LogMatches $errlog 'seeded 2 machine\(s\) from cache') -gt 0) `
        'A the app says it seeded the list from the cache'
    Assert ((Count-LogMatches $errlog 'fetch started chooser=') -gt 0) `
        'A a live fetch was started behind the seeded rows'

    Write-Host ''
    Write-Host '=== B: a fetch that cannot answer does not empty the list ==='
    Start-Sleep -Seconds 6
    $rowsAfter = Get-RowCount ([IntPtr]$list.Hwnd)
    Assert ($rowsAfter -eq 3) "B the remembered machines survived the failing fetch (rows=$rowsAfter)"
    Assert (Test-TestWindowExists -Window $chooser) 'B the chooser is still up'
    Assert (-not (Select-String -Path $errlog -Pattern 'panic:' -Quiet)) 'B no panic reached the app log'

    Stop-DebugGhoztty

    # === C + D: a relay that refuses instantly, so ticks are countable =====
    Write-Host ''
    Write-Host '=== C: an open chooser keeps asking ==='
    $env:GHOSTTY_RELAY_BASE = 'https://127.0.0.1:9'
    $errlog2 = Join-Path $tmp 'refuse-stderr.log'
    $app2 = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog2
    Start-Sleep -Seconds 3
    $top2 = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyWindow'
    if ($top2 -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: second GhozttyWindow not found'
        Write-TestVerdict -Label 'CHOOSER WARM-LIST ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    $surface2 = Get-TestChildWindow -Window $top2 -Class 'GhozttyTerminal'
    [void](Send-TestKeys -Window $top2 -Target $surface2 -Modifiers ctrl, shift -Key N)
    $chooser2 = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 20000
    Assert ($chooser2 -ne [IntPtr]::Zero) 'C the chooser opened on the refusing relay'
    if ($chooser2 -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no second chooser to score'
        Write-TestVerdict -Label 'CHOOSER WARM-LIST ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }

    # Three poll intervals' worth. Every tick is a fetch of its own because the
    # refusal is immediate, so nothing is ever skipped as in-flight.
    Start-Sleep -Seconds 16
    $quiet = Count-LogMatches $errlog2 'fetch started chooser=\d+ quiet=true'
    if ($NegativeControl) {
        $script:negReached = $true
        Write-Host 'NEGATIVE CONTROL: asserting the chooser NEVER polls - this run MUST fail'
        Assert ($quiet -eq 0) "C (inverted): no poll tick ever ran (really quiet=$quiet)"
    } else {
        Assert ($quiet -ge 2) "C the 5s poll kept re-asking while the chooser was open (quiet ticks=$quiet)"
    }
    $list2 = Get-ChooserList -Chooser $chooser2
    $rows2 = if ($list2) { Get-RowCount ([IntPtr]$list2.Hwnd) } else { -1 }
    Assert ($rows2 -eq 3) "C the list stayed the remembered one through the failing ticks (rows=$rows2)"

    Write-Host ''
    Write-Host '=== D: the poll does not outlive the chooser ==='
    $filter2 = Get-ChooserFilterField -Chooser $chooser2
    if ($filter2) {
        [void](Send-TestKeys -Window $chooser2 -Target ([IntPtr]$filter2.Hwnd) -Key Escape)
    }
    Start-Sleep -Seconds 2
    Assert (-not (Test-TestWindowExists -Window $chooser2)) 'D Escape closed the chooser'
    $before = Count-LogMatches $errlog2 'fetch started chooser=\d+ quiet=true'
    Start-Sleep -Seconds 12
    $after = Count-LogMatches $errlog2 'fetch started chooser=\d+ quiet=true'
    Assert ($after -eq $before) "D no tick fired after the dialog closed (before=$before after=$after)"
    Assert (-not ($app2.Process -and $app2.Process.HasExited)) 'D the app survived the whole drive'

    $script:drove = $true
    Complete-TestBody

} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
    # Give the user's cache back exactly as it was.
    if ($hadCache) { Copy-Item $cacheBackup $cachePath -Force }
    else { Remove-Item $cachePath -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\GHOSTTY_RELAY_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\GHOSTTY_RELAY_BASE -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    Assert ($launched.Count -gt 0) 'the run actually launched apps on the test desktop'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Assert $script:drove 'the drive ran to the end (nothing threw out of it)'
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-warm-list -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-TestVerdict -Label 'CHOOSER WARM-LIST ACCEPTANCE' -Pass $script:pass -Fail $script:fail
