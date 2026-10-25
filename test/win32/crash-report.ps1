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
panics on the GUI thread. In a Debug build a Zig panic ends in a breakpoint
exception (0x80000003), and Zig's own segfault handler does not claim that
code, so it reaches the unhandled-exception filter exactly the way an access
violation does in a shipping (ReleaseFast) build, which has no such handler.

Sections:
  A. a live app has written no report, and has not loaded dbghelp.dll - the
     dump library is loaded at crash time, so startup pays nothing for it
  B. the crash: the process exits with the exception code itself, so Windows
     and T527's postmortem still read the real reason
  C. the text report names the code, the address and its module, the pid and
     the GUI thread that crashed, and points at the dump
  D. the minidump exists and is a minidump
  E. the exit ledger still got its `crash` line - the two filters chain
     rather than the newer one hiding the older
  F. `ghoztty +crash-report` lists both files

Isolation: XDG_STATE_HOME points the crash directory at a throwaway folder,
so neither the user's crash dir nor their installed app is touched; the IPC
pipe gets a private suffix; the app runs on the background test desktop. The
error mode is set to suppress the Windows "stopped working" box, which a
child inherits, so the deliberate crash raises no UI anywhere.
#>
param(
    [string]$ExePath,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-t1355crash$PID"
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

# 0x80000003 written as a decimal: PS5.1 reads a hex literal with the high bit
# set as a NEGATIVE Int32, which then never equals the uint32 exit code.
$breakpoint = [uint32]2147483651
$ledgerPath = Join-Path $env:LOCALAPPDATA 'ghoztty\exit-log-debug.txt'

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
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
    Assert ($code -eq $breakpoint) ("B: the process exit code is the exception code (0x{0:X8}), not a code the filter made up" -f $code)

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
        foreach ($line in (Get-Content $txt.FullName)) {
            if ($line -match '^([a-z]+)=(.*)$') { $fields[$Matches[1]] = $Matches[2] }
        }
        Write-Host ("      report: " + ((Get-Content $txt.FullName) -join ' | '))
    }
    Assert ($fields['code'] -like '0x80000003 (breakpoint)') "C: report names the exception code ($($fields['code']))"
    Assert ($fields['pid'] -eq "$appPid") "C: report names the pid ($($fields['pid']))"
    Assert ($fields['thread'] -eq "$guiThread") "C: report names the crashing thread - the GUI thread $guiThread ($($fields['thread']))"
    Assert ($fields['address'] -match '^0x[0-9A-F]+$' -and $fields['address'] -ne '0x0') "C: report names a faulting address ($($fields['address']))"
    Assert ($fields['module'] -match 'ghoztty\.exe\+0x[0-9A-F]+$') "C: the address resolves to a module offset inside ghoztty.exe ($($fields['module']))"
    Assert ($fields['mode'] -eq 'Debug' -and $fields['build']) "C: report names the build ($($fields['build']) $($fields['mode']))"

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
        Where-Object { $_ -match "pid=$appPid event=crash code=0x80000003" })
    Assert ($ledgerLine.Count -eq 1) "E: the exit ledger recorded the crash too - the filters chain ($($ledgerLine.Count) line(s))"

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

    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
    Complete-TestBody
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    [void][T1355.Native]::SetErrorMode($prevErrorMode)
    Remove-Item -Recurse -Force $stateRoot -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and (Test-TestBodyComplete)) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard crash-report -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'crash-report' -MinPass 18
