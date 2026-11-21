# T1804 acceptance: the command palette's "Restart Ghoztty" and "Restart
# Ghoztty and Background Sessions".
#
# WHAT THIS COVERS, end to end through the palette a user types into:
#
#   R1. Restart Ghoztty, persistence ON: no question is asked; the app process
#       exits and a NEW one comes back by itself (the relaunch guard waits for the
#       exit - a copy started earlier would forward to the dying instance and
#       quit). The agent is the SAME process, every session id that was alive is
#       still alive, both named panes are back, a marker printed before the
#       restart is still in a pane's scrollback, and the relaunched app is on the
#       test desktop - never on the user's.
#   R2. Restart Ghoztty and Background Sessions, CANCEL: the confirmation comes
#       up, opens with focus on Cancel (Enter must never end work), and Escape
#       leaves the app, the agent and the sessions exactly as they were.
#   R3. Restart Ghoztty and Background Sessions, CONFIRM: the app's own agent is
#       replaced by a new pid, a STAND-IN agent (a copy of the agent binary on a
#       different path and lineage - the shape of the user's installed release) is
#       untouched with the same pid, and the app comes back.
#   R4. Restart Ghoztty, persistence OFF: it asks before closing shells (the log
#       names prompt=shells_close and the dialog is up); cancelling keeps the app.
#
# WHAT IT DOES NOT COVER. The dialog's wording and the session count in it are
# owner-drawn; they are unit-tested in every lane (src/apprt/win32/app_restart.zig)
# and the count this run produced is read from the app's decision log line.
# Taking the foreground on the user's desktop is never exercised: the whole run
# is on a background desktop, so `AllowSetForegroundWindow` there has nothing to
# grant.
#
# T218 house rules: runs on a BACKGROUND Win32 desktop, never takes the user's
# foreground, and only touches ghoztty processes from this repo's zig-out. The
# stand-in agent is a COPY under this run's temp dir, on its own lineage.
#
#   powershell -NoProfile -File test\win32\app-restart.ps1
param(
    [string]$Exe,
    [string]$AgentExe,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not $AgentExe) { $AgentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe' }

# Isolate the IPC endpoint before any CLI call.
$env:GHOZTTY_PIPE_SUFFIX = "-apprestart$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$root = Join-Path $env:TEMP "ghoztty-app-restart-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

function Stop-TestProcs {
    # Path-exact: only zig-out ghoztty / ghoztty-agent, never the user's release.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}

function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# Every live process whose image is exactly $path.
function Get-PidsAt([string]$path) {
    $want = [IO.Path]::GetFullPath($path)
    return @(Get-CimInstance Win32_Process -Filter "Name='$([IO.Path]::GetFileName($path))'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq $want) } |
        ForEach-Object { [int]$_.ProcessId })
}

# The app pid that is not $old, once one exists (the relaunch).
function Wait-NewAppPid([int]$old, [int]$timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $n = @(Get-PidsAt $Exe | Where-Object { $_ -ne $old })
        if ($n.Count -ge 1) { return $n[0] }
        Start-Sleep -Milliseconds 500
    }
    return 0
}

function Wait-PidGone([int]$procId, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Agent-PidAt([string]$dir) {
    $p = Join-Path (Get-GhozttyAgentStateDir -Root $dir) 'port.json'
    if (-not (Test-Path $p)) { return 0 }
    try { return [int]((Get-Content $p -Raw | ConvertFrom-Json).pid) } catch { return 0 }
}

# T1592 (R5): create a process with ANOTHER process as its parent - the pane's
# shell - so it inherits that parent's job at creation, the way an app typed
# into a pane does. stdout/stderr go to a file: the handles are duplicated INTO
# the parent (a PARENT_PROCESS child inherits from the parent's handle table,
# not ours) and named in a HANDLE_LIST so nothing else of the shell's leaks in.
# The environment is still ours (lpEnvironment null = the CREATOR's).
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class T1592Spawn {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DuplicateHandle(IntPtr srcProc, IntPtr src, IntPtr dstProc, out IntPtr dst, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr retSize);
    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr OpenJobObjectW(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

    public static string LastError = "";

    // JOB_OBJECT_QUERY only: this script never assigns, terminates or holds it.
    public static IntPtr OpenJob(string name) { return OpenJobObjectW(0x0004, false, name); }

    // 1 = in the job, 0 = not, -1 = could not ask.
    public static int InJob(int pid, IntPtr job) {
        IntPtr h = OpenProcess(0x1000 /* QUERY_LIMITED_INFORMATION */, false, pid);
        if (h == IntPtr.Zero) return -1;
        try { bool r; if (!IsProcessInJob(h, job, out r)) return -1; return r ? 1 : 0; }
        finally { CloseHandle(h); }
    }

    public static int SpawnUnder(int parentPid, string exe, string args, string desktop, string outPath) {
        LastError = "";
        // CREATE_PROCESS | DUP_HANDLE | QUERY_LIMITED_INFORMATION
        IntPtr parent = OpenProcess(0x0080 | 0x0040 | 0x1000, false, parentPid);
        if (parent == IntPtr.Zero) { LastError = "OpenProcess(parent) " + Marshal.GetLastWin32Error(); return 0; }
        IntPtr me = GetCurrentProcess();
        IntPtr hOut = CreateFileW(outPath, 0x40000000, 3, IntPtr.Zero, 2, 0x80, IntPtr.Zero);
        IntPtr hNul = CreateFileW("NUL", 0x80000000, 3, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
        IntPtr pOut = IntPtr.Zero, pNul = IntPtr.Zero;
        IntPtr list = IntPtr.Zero, vParent = IntPtr.Zero, vHandles = IntPtr.Zero;
        try {
            if (hOut == new IntPtr(-1) || hNul == new IntPtr(-1)) { LastError = "CreateFileW " + Marshal.GetLastWin32Error(); return 0; }
            // DUPLICATE_SAME_ACCESS, inheritable, in the PARENT's table.
            if (!DuplicateHandle(me, hOut, parent, out pOut, 0, true, 2) ||
                !DuplicateHandle(me, hNul, parent, out pNul, 0, true, 2)) {
                LastError = "DuplicateHandle " + Marshal.GetLastWin32Error(); return 0;
            }
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref size);
            list = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(list, 2, 0, ref size)) { LastError = "InitAttr " + Marshal.GetLastWin32Error(); return 0; }
            vParent = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(vParent, parent);
            if (!UpdateProcThreadAttribute(list, 0, (IntPtr)0x00020000 /* PARENT_PROCESS */, vParent,
                    (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) { LastError = "UpdateAttr(parent) " + Marshal.GetLastWin32Error(); return 0; }
            vHandles = Marshal.AllocHGlobal(IntPtr.Size * 2);
            Marshal.WriteIntPtr(vHandles, 0, pOut);
            Marshal.WriteIntPtr(vHandles, IntPtr.Size, pNul);
            if (!UpdateProcThreadAttribute(list, 0, (IntPtr)0x00020002 /* HANDLE_LIST */, vHandles,
                    (IntPtr)(IntPtr.Size * 2), IntPtr.Zero, IntPtr.Zero)) { LastError = "UpdateAttr(handles) " + Marshal.GetLastWin32Error(); return 0; }
            var si = new STARTUPINFOEX();
            si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
            si.StartupInfo.lpDesktop = desktop;
            si.StartupInfo.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
            si.StartupInfo.hStdInput = pNul;
            si.StartupInfo.hStdOutput = pOut;
            si.StartupInfo.hStdError = pOut;
            si.lpAttributeList = list;
            PROCESS_INFORMATION pi;
            var cmd = new System.Text.StringBuilder("\"" + exe + "\" " + args);
            // EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW (Start-OnTestDesktop's flag)
            if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, true, 0x00080000 | 0x08000000,
                    IntPtr.Zero, null, ref si, out pi)) { LastError = "CreateProcessW " + Marshal.GetLastWin32Error(); return 0; }
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            return pi.dwProcessId;
        } finally {
            IntPtr dummy;
            // DUPLICATE_CLOSE_SOURCE: the copies in the shell's table go again.
            if (pOut != IntPtr.Zero) DuplicateHandle(parent, pOut, IntPtr.Zero, out dummy, 0, false, 1);
            if (pNul != IntPtr.Zero) DuplicateHandle(parent, pNul, IntPtr.Zero, out dummy, 0, false, 1);
            if (list != IntPtr.Zero) { DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); }
            if (vParent != IntPtr.Zero) Marshal.FreeHGlobal(vParent);
            if (vHandles != IntPtr.Zero) Marshal.FreeHGlobal(vHandles);
            if (hOut != new IntPtr(-1) && hOut != IntPtr.Zero) CloseHandle(hOut);
            if (hNul != new IntPtr(-1) && hNul != IntPtr.Zero) CloseHandle(hNul);
            CloseHandle(parent);
        }
    }
}
'@ -ErrorAction SilentlyContinue

function Agent-Pid {
    # The app's agent runs under the ambient lineage (the runner's, or none).
    $p = Join-Path (Get-GhozttyAgentStateDir -Root $root) 'port.json'
    if (-not (Test-Path $p)) { return 0 }
    try { return [int]((Get-Content $p -Raw | ConvertFrom-Json).pid) } catch { return 0 }
}

# Alive session ids from `+sessions --json`, sorted; @() on any failure.
function Alive-Ids {
    $out = (& $Exe +sessions --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return @() }
    try { $rows = $out | ConvertFrom-Json } catch { return @() }
    return @(@($rows) | Where-Object { $_.alive -eq $true } | ForEach-Object { [string]$_.id } | Sort-Object)
}

function Wait-Listed([string]$name, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $out = (& $Exe +list --json 2>$null | Out-String)
        if ($out -and $out -match [regex]::Escape("`"$name`"")) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Read-Has([string]$name, [string]$marker, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $txt = ((& $Exe +read "--name=$name" --lines=200 2>$null | Out-String) -replace '\s', '')
        if ($txt -match [regex]::Escape($marker)) { return $true }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

function Wait-VisiblePalette([int]$appPid, [int]$TimeoutMs = 5000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 200) {
        $vis = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyCommandPalette' | Where-Object { $_.Visible })
        if ($vis.Count -ge 1) { return [IntPtr]$vis[0].Hwnd }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

# Open the palette in $appPid's first window, type $filter, press Enter.
function Invoke-PaletteCommand([int]$appPid, [string]$filter) {
    $win = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 15000
    if ($win -eq [IntPtr]::Zero) { return $false }
    $pane = Get-TestChildWindow -Window $win -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { return $false }
    [void](Focus-TestWindow -Window $win -Child $pane)
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $win -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-VisiblePalette $appPid
        if ($popup -eq [IntPtr]::Zero) { continue }
        $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
        if ($edit -eq [IntPtr]::Zero) { continue }
        if (-not (Send-TestControlText -Control $edit -Text $filter)) { return $false }
        Start-Sleep -Milliseconds 500
        return (Send-TestControlKey -Control $edit -Key Enter)
    }
    return $false
}

function Wait-Dialog([int]$appPid, [int]$timeoutSec = 15) {
    return Wait-TestWindow -ProcessId $appPid -Class 'GhozttyConfirmDialog' -TimeoutMs ($timeoutSec * 1000)
}

function Focused-Text([IntPtr]$dlg) {
    $f = Get-TestFocusedWindow -Window $dlg
    if ($f -eq [IntPtr]::Zero) { return '' }
    return [string](Get-TestControlText -Control $f)
}

# Tab until the focused button reads "Restart", then Enter (agent-upgrade.ps1's
# Confirm-Update: a blind Tab+Enter can land on Cancel and silently measure the
# decline path).
function Confirm-Restart([IntPtr]$dlg) {
    for ($k = 0; $k -lt 4; $k++) {
        if ((Focused-Text $dlg) -like '*Restart*') { break }
        Send-TestControlKey -Control $dlg -Key Tab | Out-Null
        Start-Sleep -Milliseconds 300
    }
    Assert ((Focused-Text $dlg) -like '*Restart*') '  (focus is on Restart before Enter)'
    return (Send-TestControlKey -Control $dlg -Key Enter)
}

function Launch-App([string[]]$launchArgs, [string]$tag) {
    $err = Join-Path $root "app-$tag.err.txt"
    # persistence: per call - R1-R3 launch with it on (the default; persistence IS
    # their subject), R4 passes --session-persistence=false explicitly.
    $a = Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs -StdErr $err
    return @{ Pid = [int]$a.Pid; Err = $err }
}

function Wait-LogLine([string]$file, [string]$pattern, [int]$timeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $hit = Select-String -LiteralPath $file -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($hit) { return $hit.Line }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

Stop-TestProcs
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$relaunched = New-Object System.Collections.ArrayList

try {
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $root) | Out-Null
    $env:LOCALAPPDATA = $root
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

    Write-Host '== setup: a stand-in agent on its own path and lineage'
    $standinDir = Join-Path $root 'standin'
    New-Item -ItemType Directory -Force $standinDir | Out-Null
    $standinExe = Join-Path $standinDir 'ghoztty-agent.exe'
    Copy-Item -LiteralPath $AgentExe -Destination $standinExe -Force
    # T2005: hand the runner's lineage back afterwards rather than dropping it -
    # the app launched next must come up on it, not on the box's default one.
    $runnerLineage = Get-GhozttyAgentLineage
    $env:GHOZTTY_AGENT_INSTANCE = "standin$PID"
    $sa = Start-OnTestDesktop -Exe $standinExe -Arguments @(
        "--listen-pipe=\\.\pipe\ghoztty-agent-standin$PID",
        "--port-file=$standinDir\port.json",
        "--sessions-file=$standinDir\sessions.json") -StdErr (Join-Path $root 'standin.err.txt')
    Restore-GhozttyAgentLineage -Saved $runnerLineage
    $standinPid = [int]$sa.Pid
    Start-Sleep -Seconds 2
    Assert ($null -ne (Get-Process -Id $standinPid -ErrorAction SilentlyContinue)) 'setup: the stand-in agent is running'

    Write-Host '== setup: a persistent app with two named panes and a marker'
    $a = Launch-App @('--title=t1804') 'r1'
    $appPid = $a.Pid
    $win = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($win -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: launch window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'setup: the app is NOT on the interactive desktop'
    & $Exe +split --direction=right --name=t1804b 2>&1 | Out-Null
    Assert (Wait-Listed 't1804b') 'setup: the second named pane exists'
    $marker = 'T1804MARK' + (Get-Random -Maximum 999999)
    # Generated text goes through --keys-file, never the native argv.
    $keys = Join-Path $root 'marker-keys.txt'
    [IO.File]::WriteAllText($keys, "echo $marker")
    & $Exe +send-keys --target=t1804b "--keys-file=$keys" Enter 2>&1 | Out-Null
    Assert (Read-Has 't1804b' $marker) 'setup: the marker is in the pane'
    # The quit flush writes the layout, but give the debounced writer a moment so
    # the split is in it whichever path wins.
    Start-Sleep -Seconds 3
    $agent0 = Agent-Pid
    $ids0 = @(Alive-Ids)
    Assert ($agent0 -gt 0) "setup: the app's agent is running (pid $agent0)"
    Assert ($ids0.Count -ge 2) "setup: at least two live sessions ($($ids0.Count))"

    Write-Host '== R1: Restart Ghoztty keeps every session'
    Assert (Invoke-PaletteCommand $appPid 'Restart Ghoztty') 'R1 chose Restart Ghoztty from the palette'
    Assert ($null -ne (Wait-LogLine $a.Err 'restart requested: kind=app persistence=true .*prompt=none')) 'R1 the app decided to ask nothing'
    Assert ((Get-TestWindow -ProcessId $appPid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) 'R1 no confirmation was shown'
    Assert (Wait-PidGone $appPid) 'R1 the old app process exited'
    $app1 = Wait-NewAppPid $appPid
    Assert ($app1 -gt 0) "R1 a new app process came back by itself (pid $app1)"
    if ($app1 -gt 0) {
        [void]$relaunched.Add($app1)
        Assert ((Wait-TestWindow -ProcessId $app1 -Class 'GhozttyWindow' -TimeoutMs 20000) -ne [IntPtr]::Zero) 'R1 the relaunched app has a window on the test desktop'
        Assert (-not (Test-TestDesktopLeak -ProcessId $app1)) 'R1 the relaunched app is NOT on the interactive desktop'
    }
    Assert (Wait-Listed 't1804b') 'R1 the named pane is back'
    Assert ((Agent-Pid) -eq $agent0) 'R1 the agent is the same process'
    $ids1 = @(Alive-Ids)
    Assert ((($ids0 -join ',') -eq ($ids1 -join ','))) "R1 the same sessions are alive ($($ids1.Count))"
    Assert (Read-Has 't1804b' $marker) 'R1 the marker survived in the scrollback'

    Write-Host '== R2: Restart Ghoztty and Background Sessions, cancelled'
    Assert (Invoke-PaletteCommand $app1 'Background Sessions') 'R2 chose the agent restart from the palette'
    $dlg = Wait-Dialog $app1
    Assert ($dlg -ne [IntPtr]::Zero) 'R2 a confirmation came up'
    if ($dlg -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 400
        Assert ((Focused-Text $dlg) -like '*Cancel*') 'R2 the confirmation opens with focus on Cancel'
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
    }
    Start-Sleep -Seconds 2
    Assert ((Get-TestWindow -ProcessId $app1 -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) 'R2 Escape closed it'
    Assert ($null -ne (Get-Process -Id $app1 -ErrorAction SilentlyContinue)) 'R2 the app is still the same process'
    Assert ((Agent-Pid) -eq $agent0) 'R2 the agent is still the same process'
    Assert (((Alive-Ids) -join ',') -eq ($ids0 -join ',')) 'R2 the sessions are untouched'

    Write-Host '== R3: Restart Ghoztty and Background Sessions, confirmed'
    Assert (Invoke-PaletteCommand $app1 'Background Sessions') 'R3 chose the agent restart from the palette'
    $dlg = Wait-Dialog $app1
    Assert ($dlg -ne [IntPtr]::Zero) 'R3 a confirmation came up'
    if ($dlg -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 400
        [void](Confirm-Restart $dlg)
    }
    Assert (Wait-PidGone $app1) 'R3 the app exited'
    Assert (Wait-PidGone $agent0) "R3 the app's own agent (pid $agent0) was stopped"
    $app2 = Wait-NewAppPid $app1
    Assert ($app2 -gt 0) "R3 a new app process came back (pid $app2)"
    if ($app2 -gt 0) {
        [void]$relaunched.Add($app2)
        Assert ((Wait-TestWindow -ProcessId $app2 -Class 'GhozttyWindow' -TimeoutMs 20000) -ne [IntPtr]::Zero) 'R3 the relaunched app has a window'
        Assert (-not (Test-TestDesktopLeak -ProcessId $app2)) 'R3 the relaunched app is NOT on the interactive desktop'
    }
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and ((Agent-Pid) -eq 0 -or (Agent-Pid) -eq $agent0)) { Start-Sleep -Milliseconds 500 }
    $agent2 = Agent-Pid
    Assert ($agent2 -gt 0 -and $agent2 -ne $agent0) "R3 a fresh agent is running (pid $agent2)"
    Assert ($null -ne (Get-Process -Id $standinPid -ErrorAction SilentlyContinue)) "R3 the stand-in agent is untouched (pid $standinPid)"
    # T3295: the dialog said these sessions END. Under holders (the default) a
    # killed agent leaves every shell running and the next agent re-adopts it,
    # so a new agent pid proves nothing about the sessions. Ask the new agent
    # for the ids that were alive before the restart: none may still be alive.
    # The new agent adopts before it accepts anyone, so its first answer is final.
    $ids3 = @(Alive-Ids)
    $kept = @($ids0 | Where-Object { $ids3 -contains $_ })
    Assert ($kept.Count -eq 0) "R3 none of the $($ids0.Count) sessions alive before the restart is alive after it (still alive: $($kept -join ','))"

    Write-Host '== R4: Restart Ghoztty with persistence OFF asks first'
    Stop-TestProcs
    # A fresh profile: the palette lists RECENT commands first, and R2/R3 just
    # used the agent restart, so in the same profile "Restart Ghoztty" + Enter
    # would pick that row instead (measured: the first run of this arm did).
    $env:LOCALAPPDATA = Join-Path $root 'r4'
    New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
    $b = Launch-App @('--session-persistence=false', '--title=t1804off') 'r4'
    $offPid = $b.Pid
    Assert ((Wait-TestWindow -ProcessId $offPid -Class 'GhozttyWindow' -TimeoutMs 20000) -ne [IntPtr]::Zero) 'R4 setup: the app is up'
    Start-Sleep -Seconds 2
    Assert (Invoke-PaletteCommand $offPid 'Restart Ghoztty') 'R4 chose Restart Ghoztty from the palette'
    Assert ($null -ne (Wait-LogLine $b.Err 'restart requested: kind=app persistence=false .*prompt=shells_close')) 'R4 the app decided to ask about closing shells'
    $dlg = Wait-Dialog $offPid
    Assert ($dlg -ne [IntPtr]::Zero) 'R4 a confirmation came up'
    if ($dlg -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 400
        Assert ((Focused-Text $dlg) -like '*Cancel*') 'R4 it opens with focus on Cancel'
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
    }
    Start-Sleep -Seconds 2
    Assert ($null -ne (Get-Process -Id $offPid -ErrorAction SilentlyContinue)) 'R4 cancelling kept the app'
    Assert ($null -ne (Wait-LogLine $b.Err 'restart cancelled by the user')) 'R4 the cancel was logged'

    # ------------------------------------------------------------------------
    # R5/R6 (T1592): an app launched FROM A PANE, then the agent restart.
    #
    # The T268 shape. A pane's shell lives in a kill-on-close PTY job; an app
    # started from that shell is born in the same job; if killing the agent
    # closes that job's last handle, the teardown kills the app inside its own
    # TerminateProcess call. T675's startup escape normally moves such an app
    # out first; T771's refusal in `LocalAgent.terminateAgent` is the net under
    # it, keyed off `AGENT_OWNS_JOB` ("our job holds a process the agent
    # PARENTED"). Until this arm that refusal had only ever been seen saying
    # "carry on" (agent-upgrade.ps1 J22c).
    #
    # WHO owns the job decides whether the kill is fatal, so it is measured in
    # both of the shapes the agent can run:
    #   R5  GHOZTTY_AGENT_PTY_HOLDER=0 - the in-process ConPTY child (the
    #       pre-T909 default, and today's fallback when a holder will not
    #       start). The AGENT creates the job, parents the shell, and holds the
    #       only handle: the kill IS fatal, and the refusal must fire.
    #   R6  the default since T909 - a per-session HOLDER process (escaped
    #       from the agent's job) creates the job and parents the shell. The
    #       agent's death leaves the job alive, so the kill is NOT fatal, the
    #       refusal must stay quiet, and the app must outlive the kill.
    #
    # How the shape is built: app B is created with the pane's SHELL as its
    # parent process (PROC_THREAD_ATTRIBUTE_PARENT_PROCESS), so Windows puts it
    # in the shell's job at creation - exactly what typing `ghoztty` in the pane
    # does - and the startup escape stays suppressed (BuildMode.ps1 sets
    # GHOZTTY_NO_STARTUP_ESCAPE for every harness launch). This script holds no
    # handle to the job by the time anything destructive runs, so the hazard is
    # the real one and R5 doubles as the negative control: with the refusal
    # removed, B dies inside the call and R5c/R5d go red.
    # ------------------------------------------------------------------------
    $r5SavedLineage = Get-GhozttyAgentLineage
    $r5SavedHolder = $env:GHOZTTY_AGENT_PTY_HOLDER

    # Bring up the shape under its own lineage and profile; returns what the
    # arm's asserts need. A lineage of its own because the job NAME is
    # lineage-keyed: under the box's default lineage another debug agent may
    # already own `...PtyJob-local-debug`, and this run's job then (correctly)
    # falls back to an anonymous one nobody can open (measured: the first run
    # of this arm found the name and no pane shell in it).
    function New-PaneLaunchedApp([string]$tag, [bool]$holder) {
        Stop-TestProcs
        $env:GHOZTTY_AGENT_INSTANCE = "t1592$tag-$PID"
        if ($holder) { Remove-Item Env:\GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
        else { $env:GHOZTTY_AGENT_PTY_HOLDER = '0' }
        $dir = Join-Path $root "r-$tag"
        $env:LOCALAPPDATA = $dir
        New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $dir) | Out-Null
        $r = @{ Agent = 0; Shell = 0; Owner = 0; App = 0; Err = (Join-Path $root "app-$tag-b.err.txt"); Dir = $dir }

        $first = Launch-App @("--title=t1592$tag") "$tag-a"
        Assert ((Wait-TestWindow -ProcessId $first.Pid -Class 'GhozttyWindow' -TimeoutMs 20000) -ne [IntPtr]::Zero) "$tag setup: the first app is up"
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and $r.Agent -eq 0) { $r.Agent = Agent-PidAt $dir; if ($r.Agent -eq 0) { Start-Sleep -Milliseconds 500 } }
        Assert ($r.Agent -gt 0) "$tag setup: its agent is running (pid $($r.Agent))"
        $ids = @()
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and $ids.Count -lt 1) { $ids = @(Alive-Ids); if ($ids.Count -lt 1) { Start-Sleep -Milliseconds 500 } }
        Assert ($ids.Count -ge 1) "$tag setup: a live session ($($ids.Count))"

        # The PTY job, opened by the name its creator gave it
        # (src/remote/pty_job_name.zig) - QUERY access only, closed again before
        # anything destructive runs.
        $lin = if (Test-GhozttyIsolatedBuildMode -Mode (Get-GhozttyBuildMode -Exe $Exe)) { 'local-debug' } else { 'local' }
        $jobName = "Local\GhozttyAgentPtyJob-$lin-$($env:GHOZTTY_AGENT_INSTANCE)"
        $job = [IntPtr]::Zero
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and $job -eq [IntPtr]::Zero) { $job = [T1592Spawn]::OpenJob($jobName); if ($job -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 500 } }
        Assert ($job -ne [IntPtr]::Zero) "$tag setup: the PTY job exists ($jobName)"

        # The pane's shell: a member of that job within two generations of the
        # agent (its child in-process; its grandchild under a holder).
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and $r.Shell -eq 0) {
            $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($r.Agent)" -ErrorAction SilentlyContinue)
            $cands = @($kids)
            foreach ($k in $kids) { $cands += @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($k.ProcessId)" -ErrorAction SilentlyContinue) }
            foreach ($k in $cands) {
                if ($k.Name -in @('conhost.exe', 'OpenConsole.exe', 'ghoztty-agent.exe')) { continue }
                if ([T1592Spawn]::InJob([int]$k.ProcessId, $job) -eq 1) { $r.Shell = [int]$k.ProcessId; $r.Owner = [int]$k.ParentProcessId; break }
            }
            if ($r.Shell -eq 0) { Start-Sleep -Milliseconds 500 }
        }
        if ($r.Shell -eq 0) {
            foreach ($k in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($r.Agent)" -ErrorAction SilentlyContinue)) {
                Write-Host "      agent child: $($k.Name) pid $($k.ProcessId) inJob=$([T1592Spawn]::InJob([int]$k.ProcessId, $job))"
            }
        }
        Assert ($r.Shell -gt 0) "$tag setup: the pane's shell is in the PTY job (pid $($r.Shell), parent $($r.Owner))"

        # The first app goes (its session stays with the agent), so B is the
        # only app on this pipe rather than forwarding to it and exiting.
        Stop-Process -Id $first.Pid -Force -ErrorAction SilentlyContinue
        Assert (Wait-PidGone $first.Pid) "$tag setup: the first app is gone"
        Assert ($r.Shell -gt 0 -and (Agent-PidAt $dir) -eq $r.Agent -and $null -ne (Get-Process -Id $r.Shell -ErrorAction SilentlyContinue)) "$tag setup: ... and the agent and the pane shell are still running"

        # The raw spawn below bypasses Start-OnTestDesktop, so it asks the
        # build-mode question itself: never a release build's endpoints.
        Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
        $desk = if ($Interactive -or $env:GHOZTTY_TEST_INTERACTIVE -eq '1') { $null } else { 'WinSta0\' + $td.Name }
        $cfgHome = Get-TestConfigHomeOverride -Exe $Exe
        if ($cfgHome) { $env:XDG_CONFIG_HOME = $cfgHome }
        try {
            if ($r.Shell -gt 0) { $r.App = [T1592Spawn]::SpawnUnder($r.Shell, $Exe, "--maximize=false --title=t1592$tag-b", $desk, $r.Err) }
        } finally {
            if ($cfgHome) { Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
        }
        if ($r.App -le 0) { Write-Host "      spawn under the shell failed: $([T1592Spawn]::LastError)" }
        else { [void]$relaunched.Add($r.App) }
        Assert ($r.App -gt 0) "$tag setup: app B was created with the pane shell as its parent (pid $($r.App))"
        Assert ($r.App -gt 0 -and [T1592Spawn]::InJob($r.App, $job) -eq 1) "$tag setup: ... so it was BORN in the pane's kill-on-close job"
        # Ours goes now: from here on the job's creator holds its only handle.
        if ($job -ne [IntPtr]::Zero) { [T1592Spawn]::CloseHandle($job) | Out-Null }
        Assert ($r.App -gt 0 -and (Wait-TestWindow -ProcessId $r.App -Class 'GhozttyWindow' -TimeoutMs 20000) -ne [IntPtr]::Zero) "$tag setup: app B has a window on the test desktop"
        Assert ($r.App -gt 0 -and $null -eq (Wait-LogLine $r.Err 'startup escape: respawned' 2)) "$tag setup: ... and did not escape the job at startup (suppressed)"
        Start-Sleep -Seconds 2

        Assert ($r.App -gt 0 -and (Invoke-PaletteCommand $r.App 'Background Sessions')) "$tag chose the agent restart from the palette"
        $d = if ($r.App -gt 0) { Wait-Dialog $r.App } else { [IntPtr]::Zero }
        Assert ($d -ne [IntPtr]::Zero) "$tag a confirmation came up"
        if ($d -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 400
            [void](Confirm-Restart $d)
        }
        # T3294: the preflight measures the job before anything is touched; the
        # kill's own line follows only when the restart goes ahead (R6).
        $r.Facts = Wait-LogLine $r.Err 'agent restart: (preflight job facts|job facts before the kill)' 20
        if ($r.Facts) { Write-Host "      $($r.Facts.Trim())" }
        return $r
    }

    Write-Host '== R5: in-process PTYs - the app launched from a pane REFUSES to stop its executioner'
    $s = New-PaneLaunchedApp 'r5' $false
    Assert ($s.Owner -gt 0 -and $s.Owner -eq $s.Agent) "R5 premise: the AGENT itself parents the pane shell (in-process ConPTY)"
    Assert ($null -ne $s.Facts -and $s.Facts -match 'AGENT_OWNS_JOB=yes') 'R5a the pre-kill line reads AGENT_OWNS_JOB=yes'
    Assert ($null -ne (Wait-LogLine $s.Err "agent restart: REFUSING to terminate pid $($s.Agent) .*holds processes that agent parented" 10)) "R5b the kill was REFUSED, naming the agent's pid ($($s.Agent))"
    # T3294: the refusal is found BEFORE anything changes, and the restart is
    # declined. Before it, restartApp logged the refused kill returning and
    # quit for its relaunch anyway, so the user's confirmed "end my sessions"
    # came back as a relaunch with every session still attached and no word why.
    Assert ($null -ne (Wait-LogLine $s.Err 'restart: NOT restarting - the background agent cannot be stopped' 10)) 'R5c the restart was declined, not carried out over the refused kill'
    Assert ($null -ne $s.Facts -and $null -eq (Wait-LogLine $s.Err "agent restart: pid $($s.Agent) terminate returned" 1)) 'R5d ... and TerminateProcess was never called'
    Assert ($null -ne $s.Facts -and $null -ne (Get-Process -Id $s.Agent -ErrorAction SilentlyContinue)) "R5e the agent is the same live process (pid $($s.Agent))"
    Assert ($null -ne $s.Facts -and $s.Shell -gt 0 -and $null -ne (Get-Process -Id $s.Shell -ErrorAction SilentlyContinue)) "R5f ... and so is the pane's shell (pid $($s.Shell))"
    Assert ($null -ne (Wait-LogLine $s.Err 'restart: told the user it did not happen \(outcome=agent_unstoppable\)' 10)) 'R5g the user is told why nothing was restarted'
    $note = if ($s.App -gt 0) { Wait-Dialog $s.App } else { [IntPtr]::Zero }
    Assert ($note -ne [IntPtr]::Zero) 'R5h ... in a notice on screen'
    Assert ($null -eq (Wait-LogLine $s.Err 'restart: quitting for the relaunch guard' 1) -and $null -eq (Wait-LogLine $s.Err 'agent restart: retiring the shared connection' 1)) 'R5i the app neither quit for a relaunch nor dropped its agent connection'
    $marker = Join-Path $s.Dir 'ghoztty\app-restart-debug.marker'
    Assert (-not (Test-Path $marker)) "R5j no relaunch was armed ($marker absent)"
    if ($note -ne [IntPtr]::Zero) { Send-TestControlKey -Control $note -Key Enter | Out-Null }
    # No relaunch is coming: the app that asked is the one still running.
    $back = if ($s.App -gt 0) { Wait-NewAppPid $s.App 8 } else { 0 }
    if ($back -gt 0) { [void]$relaunched.Add($back) }
    Assert ($s.App -gt 0 -and $back -le 0 -and $null -ne (Get-Process -Id $s.App -ErrorAction SilentlyContinue)) "R5k app B is still the running app (pid $($s.App)), and nothing relaunched"

    Write-Host '== R6: holder-backed PTYs (the default) - the refusal stays quiet and the app outlives the kill'
    $h = New-PaneLaunchedApp 'r6' $true
    Assert ($h.Owner -gt 0 -and $h.Owner -ne $h.Agent) "R6 premise: a HOLDER, not the agent, parents the pane shell (pid $($h.Owner))"
    Assert ($null -ne $h.Facts -and $h.Facts -match 'AGENT_OWNS_JOB=(no|\?)') 'R6a the pre-kill line does NOT read AGENT_OWNS_JOB=yes'
    Assert ($null -ne $h.Facts -and $null -eq (Wait-LogLine $h.Err 'agent restart: REFUSING' 1)) 'R6b nothing was refused'
    Assert ($null -ne (Wait-LogLine $h.Err "agent restart: pid $($h.Agent) terminate returned" 10)) "R6c the agent (pid $($h.Agent)) was terminated"
    # The point of R6: the app was IN the pane's kill-on-close job when the
    # agent died, and lived, because the job's handle is the holder's.
    Assert ($null -ne (Wait-LogLine $h.Err 'restart: background agent stopped=true' 10)) 'R6d the app SURVIVED the kill (it logged the call returning)'
    # T3295: the sessions were ended through the agent before the kill - except the
    # pane this app was started from, whose job holds the app (ending it would end
    # the app halfway through its own restart).
    Assert ($null -ne (Wait-LogLine $h.Err 'agent restart: ended [0-9]+ of [0-9]+ live session\(s\) \([1-9][0-9]* left running because this app runs inside them; confirmed by the agent\)' 10)) 'R6f the sessions were ended before the kill, leaving only the one hosting this app'
    Assert ($h.Owner -gt 0 -and $null -ne (Get-Process -Id $h.Owner -ErrorAction SilentlyContinue)) "R6e ... because the holder that owns the job is still running (pid $($h.Owner))"
    $back = if ($h.App -gt 0) { Wait-NewAppPid $h.App 20 } else { 0 }
    if ($back -gt 0) { [void]$relaunched.Add($back) }
} catch {
    $script:fail++
    Write-Host "FAIL  script terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Stop-TestProcs
    if (Get-Variable -Name r5SavedLineage -ErrorAction SilentlyContinue) {
        Restore-GhozttyAgentLineage -Saved $r5SavedLineage
        if ($null -ne $r5SavedHolder) { $env:GHOZTTY_AGENT_PTY_HOLDER = $r5SavedHolder } else { Remove-Item Env:\GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    }
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin } else { Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # The relaunched apps were started by the guard, not the harness, so they are
    # added to the launched set by hand: they are exactly the processes that
    # could have come up on the user's screen.
    $launched = @(@(Get-TestLaunchedPids) + @($relaunched))
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no app of this run ever became foreground on the interactive desktop'
}

Complete-TestBody

Write-Host ''
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard app-restart -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'APP RESTART'
