# DesktopEscape (T2203) - ask the BOX, not the source: run an acceptance script
# and watch the user's own desktop for a window from the repo build.
#
# `lib\DesktopLaunchAudit.ps1` reads source, and its header is right that no
# textual rule can be complete: a launch spelled through Invoke-Expression, a
# ProcessStartInfo built field by field or a splat assembled at runtime is a
# launch no reading of the text can see. The measurement that cannot be
# defeated by spelling is what the box itself says while the script runs:
#
#     is there a process whose image lives under this worktree, whose name is
#     ghoztty*, that owns a VISIBLE top-level window on the desktop this
#     runner is sitting on (the interactive one)?
#
# EnumWindows enumerates the CALLING THREAD's desktop, so a window the harness
# put on a background test desktop is invisible to this poll by construction -
# exactly the isolation the harness promises - and a window that escaped onto
# the user's desktop is not.
#
# THE CONSTRAINT THIS FILE IS BUILT AROUND: the user is usually at the machine.
# A script that DOES pull a window is what this would catch, by doing it. So the
# runner only ever runs a script the static sweeps already pass - not declared
# `@input-desktop-exception` (ForegroundAudit), not declared
# `@user-desktop-launch` (DesktopLaunchAudit), and with no undeclared static
# launch site - and it is a deliberate opt-in run (`scripts\desktop-escape-run.ps1`),
# never part of the per-turn floor. What it can find is the residue the static
# reading missed, which is the whole point of asking the box.
#
# Nothing here dot-sources lib\TestDesktop.ps1: the poll needs one EnumWindows
# call, and a runner that loaded the harness it is auditing would share its
# state with the thing under test.

$script:DesktopEscapeTypeLoaded = $false

function Initialize-DesktopEscapeType {
    if ($script:DesktopEscapeTypeLoaded) { return }
    if (-not ('GhozttyDesktopEscape' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class GhozttyDesktopEscape {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);

    // One line per visible top-level window owned by any of $pids, on THIS
    // thread's desktop: "pid|hwnd|class|title".
    public static string[] VisibleWindows(int[] pids) {
        var want = new HashSet<uint>();
        foreach (int p in pids) want.Add((uint)p);
        var outp = new List<string>();
        if (want.Count == 0) return outp.ToArray();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (want.Contains(p) && IsWindowVisible(h)) {
                var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
                var c = new StringBuilder(256); GetClassNameW(h, c, 256);
                outp.Add(p + "|" + h.ToInt64().ToString("X") + "|" + c + "|" + t);
            }
            return true;
        }, IntPtr.Zero);
        return outp.ToArray();
    }
}
'@
    }
    $script:DesktopEscapeTypeLoaded = $true
}

# Is $Path at or under one of $Roots? Case-insensitive, whole path segments
# (`D:\git\ghoztty` does not contain `D:\git\ghoztty-b\...`).
function Test-DesktopEscapeUnderRoot {
    param([string]$Path, [string[]]$Roots)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($r in @($Roots)) {
        if ([string]::IsNullOrEmpty($r)) { continue }
        try { $root = [System.IO.Path]::GetFullPath($r).TrimEnd('\') } catch { continue }
        if ($full.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# The repo-build processes alive right now: name ghoztty*, image under a root.
# Returns @{ Pid; Path; Name }. A process whose image cannot be read (another
# user's, or gone between the list and the read) is not ours and is skipped.
function Get-DesktopEscapeCandidates {
    param([string[]]$Roots, [string]$NamePattern = 'ghoztty*')
    $out = New-Object System.Collections.ArrayList
    foreach ($p in @([System.Diagnostics.Process]::GetProcesses())) {
        if ($p.ProcessName -notlike $NamePattern) { continue }
        $path = $null
        try { $path = $p.MainModule.FileName } catch { $path = $null }
        if (-not $path) { continue }
        if (-not (Test-DesktopEscapeUnderRoot -Path $path -Roots $Roots)) { continue }
        [void]$out.Add([pscustomobject]@{ Pid = $p.Id; Path = $path; Name = $p.ProcessName })
    }
    return $out
}

# One sample: every visible window on this desktop owned by a candidate.
# Returns @{ Pid; Path; Hwnd; Class; Title }.
function Get-DesktopEscapeSample {
    param([string[]]$Roots, [string]$NamePattern = 'ghoztty*')
    Initialize-DesktopEscapeType
    $cands = @(Get-DesktopEscapeCandidates -Roots $Roots -NamePattern $NamePattern)
    if ($cands.Count -eq 0) { return @() }
    $byPid = @{}
    foreach ($c in $cands) { $byPid[[int]$c.Pid] = $c }
    $pids = [int[]]@($cands | ForEach-Object { [int]$_.Pid })
    $out = New-Object System.Collections.ArrayList
    foreach ($line in @([GhozttyDesktopEscape]::VisibleWindows($pids))) {
        $f = $line -split '\|', 4
        $c = $byPid[[int]$f[0]]
        [void]$out.Add([pscustomobject]@{
            Pid = [int]$f[0]; Path = $c.Path; Hwnd = $f[1]; Class = $f[2]; Title = $f[3] })
    }
    return $out
}

# ---------------------------------------------------------------------------
# Eligibility: the runner never runs a script that the static sweeps say will
# reach the user's desktop. Returns @{ Eligible; Reason }.
#   declared-input-desktop   `@input-desktop-exception` in lib\TestDesktop.ps1
#   declared-user-desktop    `@user-desktop-launch` in lib\TestDesktop.ps1
#   static-launch-site       DesktopLaunchAudit finds an undeclared launch
# -Declared* override the lists (self-test); otherwise they are read from the
# harness under -Suite.
# ---------------------------------------------------------------------------
function Get-DesktopEscapeDeclaredSets {
    param([string]$Suite)
    $harness = Join-Path $Suite 'lib\TestDesktop.ps1'
    $inp = @(); $user = @()
    if (Test-Path -LiteralPath $harness) {
        foreach ($l in @(Get-Content -LiteralPath $harness)) {
            if ($l -match '@input-desktop-exception:\s*(?<s>(?:lib[\\/])?[A-Za-z0-9._\-]+\.ps1)\s+--') { $inp += ($Matches['s'] -replace '/', '\') }
            if ($l -match '@user-desktop-launch:\s*(?<s>(?:lib[\\/])?[A-Za-z0-9._\-]+\.ps1)\s+--') { $user += ($Matches['s'] -replace '/', '\') }
        }
    }
    return [pscustomobject]@{ Input = @($inp); User = @($user) }
}

function Get-DesktopEscapeEligibility {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Suite,
        $Declared
    )
    $leaf = Split-Path $Path -Leaf
    if ($null -eq $Declared) { $Declared = Get-DesktopEscapeDeclaredSets -Suite $Suite }
    if (@($Declared.Input) -contains $leaf) {
        return [pscustomobject]@{ Eligible = $false; Reason = 'declared-input-desktop' }
    }
    if (@($Declared.User) -contains $leaf) {
        return [pscustomobject]@{ Eligible = $false; Reason = 'declared-user-desktop' }
    }
    if (-not (Get-Command Get-DesktopLaunchAuditSites -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'DesktopLaunchAudit.ps1')
    }
    $sites = @(Get-DesktopLaunchAuditSites -Path $Path)
    if ($sites.Count -gt 0) { $sites = @(Select-DesktopLaunchAuditSites -Path $Path -Sites $sites) }
    if ($sites.Count -gt 0) {
        $first = @($sites | Sort-Object Line)[0]
        return [pscustomobject]@{ Eligible = $false; Reason = "static-launch-site (line $($first.Line): $($first.What))" }
    }
    return [pscustomobject]@{ Eligible = $true; Reason = '' }
}

# ---------------------------------------------------------------------------
# Run one script and watch. Returns
#   @{ Script; Verdict (CLEAN|ESCAPED|TIMEOUT); ExitCode; Seconds; Samples;
#      Escapes = @(@{ Pid; Path; Hwnd; Class; Title; FirstSeen }); Log }
# The script runs in a child powershell (`& <script> *> <LogPath>`, passed
# -EncodedCommand); the poll runs here, on this thread's desktop, every -PollMs.
# A TIMEOUT kills the child (and only the child: what it launched is its own
# cleanup's job, and killing by tree is the PID-reuse trap).
# ---------------------------------------------------------------------------
function Invoke-DesktopEscapeRun {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string[]]$Roots,
        [string]$LogPath,
        [string[]]$ScriptArgs = @(),
        [int]$TimeoutSeconds = 1800,
        [int]$PollMs = 200,
        [string]$NamePattern = 'ghoztty*',
        [string]$PowerShellExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    )
    Initialize-DesktopEscapeType
    if (-not $LogPath) { $LogPath = Join-Path $env:TEMP ("desktop-escape-{0}-{1}.log" -f (Split-Path $Script -Leaf), $PID) }
    # The child redirects its own streams (`*>`), so this process holds no pipe
    # to drain and the poll below is the only thing it does while it waits.
    # Encoded, so no path or argument is ever re-tokenized on the way through.
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $cmd = '& ' + (& $q $Script)
    foreach ($a in @($ScriptArgs)) { $cmd += ' ' + (& $q $a) }
    $cmd += ' *> ' + (& $q $LogPath) + '; exit $LASTEXITCODE'
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PowerShellExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $enc
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = Split-Path $Script -Parent
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $started = Get-Date
    [void]$proc.Start()
    $null = $proc.Handle   # cached, so ExitCode survives the child's exit

    $escapes = @{}
    $samples = 0
    $timedOut = $false
    while ($true) {
        $samples++
        foreach ($w in @(Get-DesktopEscapeSample -Roots $Roots -NamePattern $NamePattern)) {
            $key = "$($w.Pid)|$($w.Hwnd)"
            if (-not $escapes.ContainsKey($key)) {
                $w | Add-Member -NotePropertyName FirstSeen -NotePropertyValue ([math]::Round(((Get-Date) - $started).TotalSeconds, 1))
                $escapes[$key] = $w
            }
        }
        if ($proc.HasExited) { break }
        if (((Get-Date) - $started).TotalSeconds -gt $TimeoutSeconds) {
            $timedOut = $true
            try { $proc.Kill() } catch { }
            break
        }
        Start-Sleep -Milliseconds $PollMs
    }
    try { $proc.WaitForExit(5000) | Out-Null } catch { }
    # One last look: a window raised in the script's final instant.
    foreach ($w in @(Get-DesktopEscapeSample -Roots $Roots -NamePattern $NamePattern)) {
        $key = "$($w.Pid)|$($w.Hwnd)"
        if (-not $escapes.ContainsKey($key)) {
            $w | Add-Member -NotePropertyName FirstSeen -NotePropertyValue ([math]::Round(((Get-Date) - $started).TotalSeconds, 1))
            $escapes[$key] = $w
        }
    }
    $exit = $null
    try { $exit = $proc.ExitCode } catch { $exit = $null }
    $list = @($escapes.Values | Sort-Object FirstSeen)
    $verdict = if ($list.Count -gt 0) { 'ESCAPED' } elseif ($timedOut) { 'TIMEOUT' } else { 'CLEAN' }
    return [pscustomobject]@{
        Script   = $Script
        Verdict  = $verdict
        ExitCode = $exit
        Seconds  = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        Samples  = $samples
        Escapes  = $list
        Log      = $LogPath
    }
}

# One human line per result, plus one indented line per escaped window.
function Format-DesktopEscapeResult {
    param($Result)
    $leaf = Split-Path $Result.Script -Leaf
    $lines = @("{0,-8} {1}  ({2}s, {3} samples, exit {4}, log {5})" -f $Result.Verdict, $leaf, $Result.Seconds, $Result.Samples, $Result.ExitCode, $Result.Log)
    foreach ($w in @($Result.Escapes)) {
        $lines += ("           window at +{0}s: pid {1} hwnd {2} class '{3}' title '{4}' image {5}" -f $w.FirstSeen, $w.Pid, $w.Hwnd, $w.Class, $w.Title, $w.Path)
    }
    return $lines
}
