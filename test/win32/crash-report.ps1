<#
T1355 - a Ghoztty that dies on Windows leaves a crash report of its own.

THE DEFECT. `crash.init` did nothing on Windows: the Sentry native handler
the Mac build runs does not build for this target, so a terminal that died
left no file anywhere saying why. The exit ledger (T1686) records one line;
nothing a person could open in a debugger or attach to a bug report existed.

THE FIX, and what this script guards (src/crash/windows.zig plus the pure text
half in src/crash/windows_report.zig): an unhandled-exception filter writes
`<stamp>-<pid>.txt` and `<stamp>-<pid>.dmp` into the crash directory - the
same one `ghoztty +crash-report` lists on both platforms.

HOW IT CRASHES THE APP. Through the stock `crash:main` binding action, which
panics on the GUI thread, and then `crash:render` / `crash:io`, which panic on
the renderer and IO threads. Since T2244 the root panic handler raises every
panic as the Ghoztty panic exception (0xE0475A50) carrying its message, so a
panic reaches the unhandled-exception filter exactly the way an access
violation does. Before it a panic in a shipping (ReleaseFast) build ended in
ExitProcess(3) and wrote nothing; a Debug build only reached the filter by
accident, through the breakpoint its abort ends in.

Sections:
  A. a live app has written no report, and has not loaded dbghelp.dll - the
     dump library is loaded at crash time, so startup pays nothing for it
  B. the crash: the process exits with the exception code itself, so Windows
     and T527's postmortem still read the real reason
  C. the text report names the code, the address and its module, the pid and
     the GUI thread that crashed, and points at the dump
  D. the minidump exists and is a minidump
  E. the exit ledger still got its `crash` line - the two filters chain
     rather than the newer one hiding the older - naming the same faulting
     address as the report, with no `exit` record beside it (T1691)
  F. `ghoztty +crash-report` lists both files
  G/H. the first launch after the crash says so, and only that one (T2862)
  I. `crash:render` and `crash:io` each leave a report naming their own
     thread kind, the panic message and a dump, with the panic exit code (T2244)

-ReleaseSandbox runs the same sections against a release build named by
-ExePath (e.g. a ReleaseFast `zig build --prefix zig-out-t2244rel`), isolated
with Set-GhozttyTestIsolation -ReleaseSandbox. That is the shipping case T2244
exists for: before the fix a release panic went through std.posix.abort, which
on Windows is ExitProcess(3) outside Debug, so no filter ran and B, C and E
had nothing to read. A release run does not stamp the guard; the Debug run is
the floor.

Isolation: XDG_STATE_HOME points the crash directory at a throwaway folder,
so neither the user's crash dir nor their installed app is touched; the IPC
pipe gets a private suffix; the app runs on the background test desktop. The
error mode is set to suppress the Windows "stopped working" box, which a
child inherits, so the deliberate crash raises no UI anywhere.
#>
param(
    [string]$ExePath,
    [switch]$Interactive,
    [switch]$ReleaseSandbox
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

if ($ReleaseSandbox) {
    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 't2244rel' -ReleaseSandbox)
} else {
    $env:GHOZTTY_PIPE_SUFFIX = "-t1355crash$PID"
}
$expectMode = if ($ReleaseSandbox) { 'Release*' } else { 'Debug' }
$stateRoot = Join-Path $env:TEMP "ghoztty-t1355-$PID"
$crashDir = Join-Path $stateRoot 'ghostty\crash'
if (Test-Path $stateRoot) { Remove-Item -Recurse -Force $stateRoot }
New-Item -ItemType Directory -Force $stateRoot | Out-Null
$env:XDG_STATE_HOME = $stateRoot

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

Add-Type -Namespace T1355 -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint mode);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
'@
# SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX, inherited by the app.
$prevErrorMode = [T1355.Native]::SetErrorMode(0x0003)

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800) }

# 0xE0475A50 (windows_report.code_panic) written as a decimal: PS5.1 reads a
# hex literal with the high bit set as a NEGATIVE Int32, which then never
# equals the uint32 exit code.
$panicCode = [uint32]3762772560
$panicHex = '0xE0475A50'
# A private LOCALAPPDATA as well (T2862): sections G and H read the exit
# ledger to decide whether a launch follows a crash, and the shared debug
# ledger is appended to by every other debug launch on the box (the other loop
# lane, a parallel sweep). One of those landing between the crash and the
# relaunch would clear the crash and turn G red for a reason that is not ours.
$savedLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $stateRoot 'localappdata'
New-Item -ItemType Directory -Force (Join-Path $env:LOCALAPPDATA 'ghoztty') | Out-Null
$ledgerName = if ($ReleaseSandbox) { 'exit-log.txt' } else { 'exit-log-debug.txt' }
$ledgerPath = Join-Path $env:LOCALAPPDATA "ghoztty\$ledgerName"

# Launch the app with its log captured, wait for its window and then for the
# crash-reopen verdict line (T2862), which is logged right after the first
# window exists. Returns the line, or '' when none came.
function Start-ReopenProbe([string]$Tag) {
    $errFile = Join-Path $stateRoot "reopen-$Tag.err"
    $h = Start-OnTestDesktop -Exe $exe -AllowReleaseBuild:$ReleaseSandbox -Arguments @('--background=#101014', '--session-persistence=false') -StdErr $errFile
    if ($h.Process) { $null = $h.Process.Handle }
    $w = Wait-TestWindow -ProcessId $h.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    $line = ''
    for ($i = 0; $i -lt 60 -and -not $line; $i++) {
        if (Test-Path -LiteralPath $errFile) {
            $hit = Select-String -LiteralPath $errFile -Pattern 'crash-reopen: ' | Select-Object -Last 1
            if ($hit) { $line = $hit.Line }
        }
        if (-not $line) { Start-Sleep -Milliseconds 250 }
    }
    return [pscustomobject]@{ Pid = $h.Pid; Window = $w; Line = $line }
}

# Read a `key=value` crash report into a hashtable.
function Read-CrashFields([string]$Path) {
    $f = @{}
    foreach ($line in (Get-Content $Path)) {
        if ($line -match '^([a-z_]+)=(.*)$') { $f[$Matches[1]] = $Matches[2] }
    }
    return $f
}

# Section I (T2244): launch, crash with `crash:<Where>`, and return the exit
# code, the report's fields, the GUI thread id and whether the dump is a
# minidump. Each run is its own process, so each leaves its own pid's files.
function Invoke-ThreadCrash([string]$Where) {
    $r = [pscustomobject]@{ Pid = 0; Exited = $false; Code = $null; Fields = @{}; GuiThread = 0; DumpOk = $false; Setup = '' }
    $a = Start-OnTestDesktop -Exe $exe -AllowReleaseBuild:$ReleaseSandbox -Arguments @(
        '--background=#101014',
        '--session-persistence=false',
        "--keybind=ctrl+shift+f8=crash:$Where")
    if ($a.Process) { $null = $a.Process.Handle }
    $r.Pid = $a.Pid
    if ((Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow' -TimeoutMs 30000) -eq [IntPtr]::Zero) { $r.Setup = 'no GhozttyWindow'; return $r }
    $w = [IntPtr](@(Get-TestWindows -ProcessId $a.Pid -Class 'GhozttyWindow')[0].Hwnd)
    $p = Get-TestChildWindow -Window $w -Class 'GhozttyTerminal'
    if ($p -eq [IntPtr]::Zero) { $r.Setup = 'no terminal child'; return $r }
    $op = [uint32]0
    $r.GuiThread = [T1355.Native]::GetWindowThreadProcessId($w, [ref]$op)
    # No settle sleep: the chord is re-sent every 5s until the process exits,
    # so a pane that was not yet taking input costs a retry, not a red.
    for ($t = 0; $t -lt 150; $t++) {
        if ($t % 25 -eq 0) {
            Focus-TestWindow -Window $w -Child $p | Out-Null
            Send-TestKeys -Window $w -Target $p -Key F8 -Modifiers ctrl, shift | Out-Null
        }
        if ($a.Process.HasExited) { $r.Exited = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if ($r.Exited) { try { $r.Code = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$a.Process.ExitCode), 0) } catch { } }
    $t2 = $null
    for ($t = 0; $t -lt 25 -and -not $t2; $t++) {
        $t2 = Get-ChildItem $crashDir -Filter "*-$($a.Pid).txt" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $t2) { Start-Sleep -Milliseconds 200 }
    }
    if ($t2) {
        $r.Fields = Read-CrashFields $t2.FullName
        Write-Host ("      report ($Where): " + ((Get-Content $t2.FullName) -join ' | '))
        $dn = $r.Fields['dump']
        if ($dn) {
            $dp = Join-Path $crashDir $dn
            if (Test-Path $dp) {
                $b = [System.IO.File]::ReadAllBytes($dp)
                $r.DumpOk = ($b.Length -gt 64KB -and [System.Text.Encoding]::ASCII.GetString($b, 0, 4) -eq 'MDMP')
            }
        }
    }
    return $r
}

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $app = Start-OnTestDesktop -Exe $exe -AllowReleaseBuild:$ReleaseSandbox -Arguments @(
        '--background=#101014',
        '--session-persistence=false',
        '--keybind=ctrl+shift+f8=crash:main')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    $A = [IntPtr](@(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')[0].Hwnd)
    $pane = Get-TestChildWindow -Window $A -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal child'; exit 1 }
    $ownerPid = [uint32]0
    $guiThread = [T1355.Native]::GetWindowThreadProcessId($A, [ref]$ownerPid)

    # -------------------------------------------------------------------
    # A. Alive: nothing written, nothing extra loaded.
    # -------------------------------------------------------------------
    $before = @(Get-ChildItem $crashDir -File -ErrorAction SilentlyContinue)
    Assert ($before.Count -eq 0) "A: a live app has written no crash report ($($before.Count) file(s))"
    $mods = @()
    try { $mods = @((Get-Process -Id $appPid).Modules | ForEach-Object { $_.ModuleName }) } catch { }
    Assert ($mods.Count -gt 0) "A: the app's module list could be read ($($mods.Count) modules) - positive control for the next check"
    Assert (-not ($mods -contains 'dbghelp.dll')) 'A: dbghelp.dll is not loaded before a crash - startup pays nothing for the dump writer'

    # -------------------------------------------------------------------
    # B. The crash.
    # -------------------------------------------------------------------
    Focus-TestWindow -Window $A -Child $pane | Out-Null
    Send-TestKeys -Window $A -Target $pane -Key F8 -Modifiers ctrl, shift | Out-Null
    $exited = $false
    for ($t = 0; $t -lt 150; $t++) {
        if ($app.Process.HasExited) { $exited = $true; break }
        Start-Sleep -Milliseconds 200
    }
    Assert $exited 'B: the crash binding ended the process within 30s'
    $code = $null
    if ($exited) { try { $code = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$app.Process.ExitCode), 0) } catch { } }
    Assert ($code -eq $panicCode) ("B: the process exit code is the panic exception code (0x{0:X8}), not ExitProcess(3) and not a code the filter made up" -f $code)

    # -------------------------------------------------------------------
    # C. The text report.
    # -------------------------------------------------------------------
    $txt = $null
    for ($t = 0; $t -lt 25 -and -not $txt; $t++) {
        $txt = Get-ChildItem $crashDir -Filter "*-$appPid.txt" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $txt) { Start-Sleep -Milliseconds 200 }
    }
    Assert ($null -ne $txt) "C: a text report named *-$appPid.txt is in the crash dir"
    $fields = @{}
    if ($txt) {
        $fields = Read-CrashFields $txt.FullName
        Write-Host ("      report: " + ((Get-Content $txt.FullName) -join ' | '))
    }
    Assert ($fields['code'] -like "$panicHex (Ghoztty panic)") "C: report names the panic exception code ($($fields['code']))"
    Assert ($fields['message'] -eq 'crash binding action, crashing intentionally') "C: report carries the panic message ($($fields['message']))"
    Assert ($fields['thread_kind'] -eq 'main') "C: report names the thread kind ($($fields['thread_kind']))"
    Assert ($fields['pid'] -eq "$appPid") "C: report names the pid ($($fields['pid']))"
    Assert ($fields['thread'] -eq "$guiThread") "C: report names the crashing thread - the GUI thread $guiThread ($($fields['thread']))"
    Assert ($fields['address'] -match '^0x[0-9A-F]+$' -and $fields['address'] -ne '0x0') "C: report names a faulting address ($($fields['address']))"
    Assert ($fields['module'] -match 'ghoztty\.exe\+0x[0-9A-F]+$') "C: the address resolves to a module offset inside ghoztty.exe ($($fields['module']))"
    Assert ($fields['mode'] -like $expectMode -and $fields['build']) "C: report names the build ($($fields['build']) $($fields['mode']), want $expectMode)"

    # -------------------------------------------------------------------
    # D. The minidump.
    # -------------------------------------------------------------------
    $dmpName = $fields['dump']
    $dmp = if ($dmpName) { Join-Path $crashDir $dmpName } else { $null }
    Assert ($dmpName -like "*-$appPid.dmp") "C: report points at its dump ($dmpName)"
    $magic = ''
    if ($dmp -and (Test-Path $dmp)) {
        $bytes = [System.IO.File]::ReadAllBytes($dmp)
        if ($bytes.Length -ge 4) { $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) }
        Write-Host ("      dump: {0:N0} bytes" -f $bytes.Length)
        Assert ($bytes.Length -gt 64KB) "D: the dump is more than a header ($($bytes.Length) bytes)"
    } else {
        Assert $false 'D: the dump file exists'
    }
    Assert ($magic -eq 'MDMP') "D: the dump opens with the minidump signature ($magic)"

    # -------------------------------------------------------------------
    # E. The exit ledger still saw it.
    # -------------------------------------------------------------------
    $ledgerLine = @(Get-Content $ledgerPath -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "pid=$appPid event=crash code=$panicHex" })
    Assert ($ledgerLine.Count -eq 1) "E: the exit ledger recorded the crash too - the filters chain ($($ledgerLine.Count) line(s))"
    # T1691: the line is the crash, not merely a line. Its address is the same
    # ExceptionRecord field the crash report wrote, read by a different filter,
    # so the two agreeing proves the ledger names WHERE it died and not a
    # placeholder. And the run's ledger story is start -> crash, with no `exit`
    # beside it: a crash recorded as a clean quit would be the lie this
    # ledger exists to prevent.
    $ledgerAddr = if ($ledgerLine.Count -eq 1 -and $ledgerLine[0] -match '\baddr=(0x[0-9A-F]+)\b') { $Matches[1] } else { '' }
    Assert ($ledgerAddr -ne '' -and $ledgerAddr -eq $fields['address']) `
        "E: the ledger's crash address is the one the crash report names (ledger $ledgerAddr, report $($fields['address']))"
    $runLines = @(Get-Content $ledgerPath -ErrorAction SilentlyContinue | Where-Object { $_ -match "\bpid=$appPid event=" })
    $runEvents = @($runLines | ForEach-Object { if ($_ -match '\bevent=([a-z-]+)') { $Matches[1] } })
    Assert (($runEvents -join ',') -eq 'start,crash') "E: the crashed run's ledger entries are exactly start then crash ($($runEvents -join ','))"

    # -------------------------------------------------------------------
    # F. +crash-report lists both.
    # -------------------------------------------------------------------
    $com = Join-Path (Split-Path $exe -Parent) 'ghoztty.com'
    $cli = if (Test-Path $com) { $com } else { $exe }
    # stdout only: the listing is printed there, and a merged stderr would hand
    # Out-String host-formatted ErrorRecords (T883).
    $listing = (& $cli '+crash-report' 2>$null | Out-String)
    Assert ($listing -match [regex]::Escape("-$appPid.txt") -and $listing -match [regex]::Escape("-$appPid.dmp")) `
        "F: ghoztty +crash-report lists the report and the dump"

    # -------------------------------------------------------------------
    # G. The first launch after the crash says so (T2862).
    # -------------------------------------------------------------------
    # Windows' own crash relaunch (T2839) is off in a Debug build, so this
    # launch stands in for it: it is the first one since the crash, which is
    # exactly what the app keys on.
    $g = Start-ReopenProbe 'after-crash'
    Assert ($g.Window -ne [IntPtr]::Zero) "G: the app relaunched after the crash (pid $($g.Pid))"
    Assert ($g.Line -match 'crash-reopen: notice shown=') "G: the relaunch decided to tell the user ($($g.Line))"
    Assert ($g.Line -match "prev_pid=$appPid\b") "G: the notice is about the run that crashed (pid $appPid)"
    Assert ($g.Line -match "code=$panicHex") 'G: it carries the crash the ledger recorded'
    Assert ($g.Line -match 'body="It crashed a moment ago and was reopened\. Click to see the crash report\."') `
        'G: the sentence names the crash, how long ago, and what a click does'
    Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) 'G: the relaunched app stayed on the test desktop'
    # T1691: the crash line CLOSES the run. The relaunch read the ledger; had
    # it treated the crashed run as still open, it would also have accused it
    # of vanishing without a reason - one death told twice, the second time
    # wrongly.
    $accused = @(Get-Content $ledgerPath -ErrorAction SilentlyContinue |
        Where-Object { $_ -match "event=unrecorded-exit prev_pid=$appPid\b" })
    Assert ($accused.Count -eq 0) "G: the relaunch does not also report the crashed run as an unrecorded exit ($($accused.Count) line(s))"
    Stop-RepoInstances

    # -------------------------------------------------------------------
    # H. ...and only that launch: the next one stays quiet.
    # -------------------------------------------------------------------
    # G's `start` now sits past the crash in the ledger. The "nothing to say"
    # line is the positive control: it proves this launch reached the
    # decision, so a missing notice is a verdict and not a launch that died
    # early.
    $h2 = Start-ReopenProbe 'second'
    Assert ($h2.Window -ne [IntPtr]::Zero) "H: a second launch came up (pid $($h2.Pid))"
    Assert ($h2.Line -match 'crash-reopen: the previous run did not crash') "H: it reached the decision and said nothing ($($h2.Line))"
    Assert ($h2.Line -notmatch 'notice shown=') 'H: the crash is not announced a second time'
    Stop-RepoInstances

    # -------------------------------------------------------------------
    # I. The other two threads (T2244).
    # -------------------------------------------------------------------
    foreach ($spec in @(@{ Where = 'render'; Kind = 'renderer' }, @{ Where = 'io'; Kind = 'io' })) {
        $w = $spec.Where
        $r = Invoke-ThreadCrash $w
        Assert ($r.Setup -eq '') "I($w): the app came up for the crash ($($r.Setup))"
        Assert $r.Exited "I($w): crash:$w ended the process within 30s"
        Assert ($r.Code -eq $panicCode) ("I($w): exit code is the panic exception code (0x{0:X8})" -f $r.Code)
        Assert ($r.Fields['code'] -like "$panicHex (Ghoztty panic)") "I($w): report names the panic code ($($r.Fields['code']))"
        Assert ($r.Fields['message'] -eq 'crash request, crashing intentionally') "I($w): report carries the panic message ($($r.Fields['message']))"
        Assert ($r.Fields['thread_kind'] -eq $spec.Kind) "I($w): report names its own thread kind ($($r.Fields['thread_kind']), want $($spec.Kind))"
        Assert ($r.Fields['thread'] -match '^\d+$' -and $r.Fields['thread'] -ne "$($r.GuiThread)") "I($w): the crashing thread is not the GUI thread ($($r.Fields['thread']) vs $($r.GuiThread))"
        Assert ($r.Fields['module'] -match 'ghoztty\.exe\+0x[0-9A-F]+$') "I($w): the panic site resolves inside ghoztty.exe ($($r.Fields['module']))"
        Assert $r.DumpOk "I($w): its minidump exists and is a minidump"
        $ll = @(Get-Content $ledgerPath -ErrorAction SilentlyContinue | Where-Object { $_ -match "pid=$($r.Pid) event=crash code=$panicHex" })
        Assert ($ll.Count -eq 1) "I($w): the exit ledger recorded it ($($ll.Count) line(s))"
        Stop-RepoInstances
    }

    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
    Complete-TestBody
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    [void][T1355.Native]::SetErrorMode($prevErrorMode)
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item -Recurse -Force $stateRoot -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and -not $ReleaseSandbox -and (Test-TestBodyComplete)) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard crash-report -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'crash-report' -MinPass 50
