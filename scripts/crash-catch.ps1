<#
.SYNOPSIS
    Run a program (or a lane's test binary) under cdb and keep the crash: a
    full minidump plus every thread's symbolised stack. T450.

.DESCRIPTION
    Zig's own segfault handler dies in a recursive panic on this box, so a
    crashing test binary leaves nothing but

        Segmentation fault at address 0xffffffffffffffff
        aborting due to recursive panic

    and every investigation into the T443 corruption has started from that.
    Running under a debugger takes the exception on FIRST chance -- before any
    in-process handler -- and walks EVERY thread, which is the point: the
    thread that scribbled over memory is not the thread that trips over it.

    No install and no elevation: the Microsoft Store WinDbg package already on
    this box ships a console cdbX64.exe.

.PARAMETER Lane
    Catch the newest test binary a zig lane built, instead of naming an exe.
    `agent` covers both agent test binaries and tries them in turn.

.PARAMETER Attempts
    Re-run until a crash is caught, up to this many times. The T443 crash lands
    on roughly half of runs, so one clean attempt proves nothing.

.PARAMETER Last
    Do not run anything: read the dump Windows already wrote for this lane's
    test binary the last time it died (T460). That is the crash that actually
    happened, it takes about a second, and it is the ONLY path that works for a
    crash which does not reproduce. -Since bounds how far back to look.

.PARAMETER FromDump
    Same, for a dump named explicitly.

.PARAMETER Status
    Report whether Windows is keeping a dump when a process dies at all, how
    much of each process it keeps, and how to arm it if not.

.PARAMETER ArmFull
    Offer the one-time elevated act that makes Windows keep FULL memory for our
    binaries instead of a mini dump (T808). Mini carries every thread's stack;
    it drops the heap, which is what a corruption crash is made of. The setting
    is a per-exe DumpType=2 under HKLM, so this re-launches itself once through
    UAC when it is not already elevated.

.PARAMETER Disarm
    Remove those per-exe entries again. The global LocalDumps key -- the switch
    that keeps first-crash capture working at all -- is never touched.

.PARAMETER NoElevate
    Never raise a UAC prompt: print the exact reg.exe commands the arm would
    run and exit 2. For an unattended run, and for anyone who would rather see
    what is being written to their machine before it happens.

.OUTPUTS
    A `-- crash stack --` block, and the dump/transcript paths.
    Exit 0 = ran clean, and that is now a POSITIVE observation -- the debuggee
    was watched exiting 0. 1 = a crash was caught and captured. 2 = could not
    run (no cdb, no such exe, nothing built for the lane, no dump to read).
    3 = UNCAUGHT (T478): the program did not exit 0 and no exception was
    captured, so the run is unexplained rather than clean. Exit 3 is the one
    that stops a panicking binary from being reported as healthy.

.EXAMPLE
    powershell -NoProfile -File scripts\crash-catch.ps1 -ArmFull
.EXAMPLE
    powershell -NoProfile -File scripts\crash-catch.ps1 -Lane agent -Last
.EXAMPLE
    powershell -NoProfile -File scripts\crash-catch.ps1 -Lane agent -Attempts 6
.EXAMPLE
    powershell -NoProfile -File scripts\crash-catch.ps1 -Exe .\zig-out\bin\ghoztty.exe -Arguments '+list'
#>
[CmdletBinding()]
param(
    [ValidateSet('none', 'win32', 'agent')][string]$Lane,
    [string]$Exe,
    [string[]]$Arguments = @(),
    [int]$Attempts = 1,
    [int]$TimeoutSeconds = 1200,
    [string]$OutDir,
    [string]$Cdb,
    [switch]$Last,
    [string]$FromDump,
    [switch]$Status,
    [switch]$ArmFull,
    [switch]$Disarm,
    [switch]$NoElevate,
    [int]$SinceHours = 24,
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\CrashCatch.ps1"
. "$PSScriptRoot\lib\CrashDump.ps1"

if ($Status) {
    $armed = Write-WerArmedStatus -ExeNames @('ghostty-test.exe')
    exit $(if ($armed) { 0 } else { 2 })
}

# ------------------------------------- the one-time elevated arm for full dumps

if ($ArmFull -or $Disarm) {
    $what = if ($Disarm) { 'disarm' } else { 'arm' }
    $plan = @(Get-WerArmFullPlan)
    foreach ($item in $plan) {
        Write-Host ('crash-catch: {0,-20} currently {1} dumps' -f $item.ExeName, $item.CurrentTypeName)
    }
    if ($ArmFull -and -not ($plan | Where-Object { $_.Needed })) {
        Write-Host 'crash-catch: full memory is already armed for every target binary; nothing to do.'
        exit 0
    }

    if (-not (Test-IsElevated)) {
        if ($NoElevate) {
            # Say what WOULD be written and stop. A command that cannot do the
            # thing must not report having done it.
            Write-Host 'crash-catch: this needs an administrator (LocalDumps lives under HKLM; HKCU is ignored).'
            Write-Host ('  Run these once from an elevated shell to {0}:' -f $what)
            foreach ($item in $plan) {
                if ($Disarm) {
                    Write-Host ('  reg delete "{0}" /f' -f (ConvertTo-RegCommandPath -Path $item.Key))
                }
                elseif ($item.Needed) {
                    Write-Host ('  ' + $item.Command)
                }
            }
            exit 2
        }
        # The offer: one UAC prompt, and the elevated copy does exactly what the
        # plan above says. -NoElevate on the inner run so a mis-detected
        # elevation state cannot loop.
        Write-Host ('crash-catch: {0}ing full memory dumps needs an administrator -- asking for elevation once.' -f $what)
        $inner = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
            $(if ($Disarm) { '-Disarm' } else { '-ArmFull' }), '-NoElevate')
        try {
            # -PassThru without -Wait, and cache .Handle before waiting: a
            # PS 5.1 process object whose handle was never touched hands back an
            # empty ExitCode, and an empty code reads as success.
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $inner -Verb RunAs -PassThru -ErrorAction Stop
            $null = $p.Handle
            $p.WaitForExit()
        }
        catch {
            Write-Host ('crash-catch: elevation was declined or failed: ' + $_.Exception.Message)
            Write-Host '  Nothing was changed. Re-run with -NoElevate to see the commands and run them yourself.'
            exit 2
        }
        # Judge it on the registry, not on the exit code: the question "is full
        # memory armed now?" has an answer on disk, and that is the one worth
        # printing back to whoever just approved a UAC prompt.
        $after = @(Get-WerArmFullPlan)
        $stillMini = @($after | Where-Object { $_.Needed })
        $done = if ($Disarm) { $stillMini.Count -eq $after.Count } else { $stillMini.Count -eq 0 }
        $null = Write-WerArmedStatus -ExeNames @('ghostty-test.exe')
        if ($done) { exit 0 }
        Write-Host ('crash-catch: the elevated run exited ' + $p.ExitCode + ' and the setting did NOT change -- nothing here assumes it worked.')
        exit 2
    }

    $results = if ($Disarm) { Remove-WerFullDumpArm } else { Set-WerFullDumpArm }
    $failed = 0
    foreach ($r in $results) {
        if (-not $r.Ok) {
            $failed++
            Write-Host ('crash-catch: FAILED {0}: {1}' -f $r.ExeName, $r.Error)
        }
        elseif ($r.Changed) {
            Write-Host ('crash-catch: {0} {1} -> {2}' -f $what, $r.ExeName, $(if ($Disarm) { 'back to the global default' } else { 'full memory' }))
        }
        else {
            Write-Host ('crash-catch: {0} already as asked' -f $r.ExeName)
        }
    }
    if ($failed -gt 0) { exit 2 }
    $null = Write-WerArmedStatus -ExeNames @('ghostty-test.exe')
    exit 0
}

$cdbPath = Get-CdbPath -Override $Cdb
if (-not $cdbPath) {
    Write-Host 'crash-catch: no cdb.exe found.'
    Write-Host '  Looked for the Store WinDbg console debugger at'
    Write-Host ('  ' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe\cdbX64.exe'))
    Write-Host '  and the Windows Kits copy under "Windows Kits\10\Debuggers\x64".'
    Write-Host '  Install WinDbg from the Store, or set $env:GHOZTTY_CDB to a cdb.exe.'
    exit 2
}
Write-Host "crash-catch: cdb = $cdbPath"

# ------------------------------------------- read a crash that already happened

if ($Last -or $FromDump) {
    $dumpPath = $FromDump
    $sym = $null
    if (-not $dumpPath) {
        if (-not $Lane) {
            Write-Host 'crash-catch: -Last needs -Lane <none|win32|agent> (whose binary died?).'
            exit 2
        }
        $resolved = @(Resolve-LaneTestBinary -Lane $Lane -Repo $Repo)
        Write-LaneResolution -Resolution $resolved -Prefix 'crash-catch:'
        $bins = @($resolved | Where-Object { $_.Ok } | ForEach-Object { $_.Path })
        if ($bins.Count -eq 0) {
            Write-Host "crash-catch: no verified test binary for lane '$Lane' -- build the lane, or name the dump with -FromDump."
            exit 2
        }
        $names = @($bins | ForEach-Object { Split-Path -Leaf $_ })
        $found = Find-WerCrashDump -ExeNames $names -Since (Get-Date).AddHours(-$SinceHours) -WaitSeconds 1
        if (-not $found) {
            Write-Host ("crash-catch: no dump for " + ($names -join ', ') + " in the last $SinceHours h.")
            $null = Write-WerArmedStatus -ExeNames $names
            exit 2
        }
        $dumpPath = $found.FullName
        $match = @($bins | Where-Object { (Split-Path -Leaf $_) -eq (($found.Name -replace '\.\d+\.dmp$', '')) })
        if ($match.Count -gt 0) { $sym = Split-Path -Parent $match[0] }
    }
    if (-not (Test-Path -LiteralPath $dumpPath)) {
        Write-Host "crash-catch: no such dump: $dumpPath"
        exit 2
    }

    # WHOSE crash is this? `<exe>.<pid>.dmp` cannot say -- both lanes build a
    # ghostty-test.exe -- but the dump records the module path it was taken of,
    # and that names the cache directory (T855). Reading a win32-lane dump under
    # `-Lane none` would explain a crash that never happened in that program.
    $dumpModule = Get-MinidumpMainModulePath -Path $dumpPath
    if ($dumpModule) {
        Write-Host "crash-catch: the dump was taken of $dumpModule"
        if (Test-Path -LiteralPath $dumpModule) {
            if ($Lane) {
                $v = Get-BinaryLaneVerdict -Path $dumpModule -Lane $Lane
                if ($v.OtherLane) {
                    Write-Host ("crash-catch: REFUSED -- that dump is $($v.Reason).")
                    Write-Host '             Name the lane it belongs to, or drop -Lane to read it unattributed.'
                    exit 2
                }
                if (-not $v.Ok -and $v.Checked) {
                    Write-Host ("crash-catch: NOTE -- the crashed build is $($v.Reason)")
                }
            }
            # Symbols from the build that ACTUALLY died, not from whatever the
            # lane linked most recently: a pdb from a different build turns the
            # stack into confident nonsense.
            $sym = Split-Path -Parent $dumpModule
        }
        elseif ($Lane) {
            Write-Host 'crash-catch: NOTE -- that build is no longer in the cache, so its lane cannot be confirmed'
            Write-Host '             and the symbols below come from the current build of this lane instead.'
        }
    }

    if (-not $sym -and $Lane) {
        $bins = @(Get-LaneTestBinary -Lane $Lane -Repo $Repo)
        if ($bins.Count -gt 0) { $sym = Split-Path -Parent $bins[0] }
    }
    Write-Host "crash-catch: reading $dumpPath (no re-run)"
    $r = Invoke-CrashDumpAnalysis -DumpPath $dumpPath -SymbolPath $sym -OutDir $OutDir -Cdb $Cdb -Repo $Repo
    if (Write-CrashDumpStack -Result $r) { exit 1 }
    exit 2
}

# ------------------------------------------------------------- what to run

$targets = @()
if ($Exe) { $targets = @($Exe) }
elseif ($Lane) {
    # Verified, not newest (T855): the two lanes build the same file name, so
    # "newest" ran the other lane's program and said nothing about it.
    $resolved = @(Resolve-LaneTestBinary -Lane $Lane -Repo $Repo)
    Write-LaneResolution -Resolution $resolved -Prefix "crash-catch: lane $Lane"
    $targets = @($resolved | Where-Object { $_.Ok } | ForEach-Object { $_.Path })
    if ($targets.Count -eq 0) {
        Write-Host "crash-catch: no verified test binary for lane '$Lane' under $Repo\.zig-cache\o -- run the lane once first, or pass -Exe."
        exit 2
    }
}
else {
    Write-Host 'crash-catch: pass -Lane <none|win32|agent> or -Exe <path>.'
    exit 2
}

# ------------------------------------------------------------------- run it

$caught = $null
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host "crash-catch: no such exe: $t"
        exit 2
    }
    $r = Invoke-CrashCatch -Exe $t -Arguments $Arguments -OutDir $OutDir `
        -Attempts $Attempts -TimeoutSeconds $TimeoutSeconds -Cdb $Cdb -Repo $Repo
    if ($r -and $r.Crashed) { $caught = $r; break }
    # NOT $last: PowerShell variable names are case-insensitive, so that would
    # be the -Last switch parameter, and assigning a result object to it throws
    # a transformation error mid-run (caught by crash-stacks.ps1).
    $lastResult = $r
    # An unexplained death stops the sweep for the same reason a caught crash
    # does: it is evidence, and running the next binary would bury it.
    if ($r -and $r.Uncaught) { break }
}

if ($caught) {
    $null = Write-CrashStack -Result $caught
    exit 1
}

$null = Write-CrashStack -Result $lastResult
if ($lastResult -and $lastResult.Uncaught) { exit 3 }
exit 0
