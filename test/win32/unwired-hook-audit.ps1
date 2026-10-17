<#
.SYNOPSIS
    T1034 acceptance - a hook whose doc comment names its caller has one, and
    every WM_APP_* window message has both a handler and a sender.

.DESCRIPTION
    T1031 found `Surface.signalFrameDrawn` documented as "called by the
    renderer thread after SwapBuffers" with no caller anywhere: the
    synchronous-present wait it fed sat on an event nobody set and expired
    on its 16 ms timeout from the day it was written. It compiled, every test
    passed, and the feature did not exist. That is a class, and nothing was
    looking for the next member of it. This script is what looks.

    Three sections:

      A. The analyzer (`lib\UnwiredHookAudit.ps1`) against fixtures, both
         directions: a documented hook with no caller, one whose only caller
         is a test block, one whose only "caller" is a comment, a field
         documented "set by" that nothing sets, a message with no handler
         and a message with no sender are each reported; a called hook, a
         hook reached only through a string, an undocumented dead fn, a
         message sent through `attach(hwnd, MSG)` and a message posted only
         by a test script resolve quietly.

      B. The sweep over the real `src\apprt\win32` and `src\remote`. Zero
         findings, AND floors on what was seen - an analyzer whose pattern
         silently matched nothing would otherwise pass forever - AND the
         original case: `signalFrameDrawn` must be among the hooks held to
         their word, with a caller.

      C. `-TeethCheck` - the negative control. Plants the T1031 shape (a
         documented "called by the renderer thread" fn nobody calls, and a
         handled message nobody posts) into a real file under
         src\apprt\win32, requires section B's sweep to go RED naming both,
         then removes it.

    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.

.NOTES
    # persistence: launches no GUI and no ghoztty - this reads Zig source. No
    # IPC endpoint, no user state.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\UnwiredHookAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red
        $script:fail++
    }
}

$enc = New-Object Text.UTF8Encoding $false

# --- A: the analyzer against fixtures ---------------------------------------
Write-Host 'A. analyzer fixtures'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "ghoztty-t1034-$PID"
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'src\apprt\win32') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'src\renderer') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'test\win32') | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $tmp 'src\apprt\win32\Hooks.zig'), @'
pub const WM_APP_HANDLED_ONLY: u32 = w32.WM_APP + 1;
pub const WM_APP_SENT_ONLY: u32 = w32.WM_APP + 2;
pub const WM_APP_ATTACHED: u32 = w32.WM_APP + 3;
pub const WM_APP_TEST_POSTED: u32 = w32.WM_APP + 4;
pub const WM_APP_WIRED: u32 = w32.WM_APP + 5;

const Hooks = struct {
    /// Signalled by the renderer thread once the frame is up.
    frame_event: ?HANDLE = null,
};

/// Called by the renderer thread after SwapBuffers.
pub fn neverCalled(self: *Surface) void {
    _ = self;
}

/// Called by the IO thread when output arrives.
pub fn onlyATestCalls() void {}

/// Invoked from the GUI thread on resize.
pub fn onlyACommentNames() void {}

/// Called by `Window.onSize` on every resize.
pub fn wired() void {}

/// Called from the dispatch table by name.
pub fn reachedByString() void {}

/// Dead too, but its comment makes no claim about who reaches it.
pub fn undocumentedDead() void {}

fn wndProc(msg: u32) void {
    switch (msg) {
        WM_APP_HANDLED_ONLY => {},
        WM_APP_ATTACHED, WM_APP_TEST_POSTED => {},
        WM_APP_WIRED => {},
        else => {},
    }
}

fn post(hwnd: HWND) void {
    _ = PostMessageW(hwnd, WM_APP_SENT_ONLY, 0, 0);
    _ = PostMessageW(hwnd, WM_APP_WIRED, 0, 0);
    probe.attach(hwnd, WM_APP_ATTACHED);
    // onlyACommentNames() is called from here, in a comment only.
}

test "a test is not the caller a doc comment promises" {
    onlyATestCalls();
}
'@, $enc)
    [IO.File]::WriteAllText((Join-Path $tmp 'src\renderer\caller.zig'), @'
fn resize() void {
    win.wired();
    @field(hooks, "reachedByString")();
}
'@, $enc)
    [IO.File]::WriteAllText((Join-Path $tmp 'test\win32\fixture.ps1'), @'
$WM_APP_TEST_POSTED = 0x8000 + 4
'@, $enc)

    $r = Get-UnwiredHookFindings -Repo $tmp
    $f = $r.Findings
    $kinds = ($f | ForEach-Object { "$($_.Kind):$($_.Name)" }) -join ', '
    $has = { param($k, $n) @($f | Where-Object { $_.Kind -eq $k -and $_.Name -eq $n }).Count -eq 1 }

    Assert 'A1 a documented hook with no caller is reported' (& $has 'no-caller' 'neverCalled') $kinds
    Assert 'A2 a hook only a test block calls is reported' (& $has 'no-caller' 'onlyATestCalls') $kinds
    Assert 'A3 a hook only a comment names is reported' (& $has 'no-caller' 'onlyACommentNames') $kinds
    Assert 'A4 a field documented "signalled by" that nothing touches is reported' (& $has 'no-caller' 'frame_event') $kinds
    Assert 'A5 a message with no handler is reported' (& $has 'no-handler' 'WM_APP_SENT_ONLY') $kinds
    Assert 'A6 a handled message nothing sends is reported' (& $has 'no-sender' 'WM_APP_HANDLED_ONLY') $kinds
    Assert 'A7 the quiet direction: called, string-reached, undocumented, attached and test-posted raise nothing else' (
        $f.Count -eq 6) $kinds
    Assert 'A8 the census saw every documented hook, the undocumented one excluded' (
        $r.Hooks.Count -eq 6 -and @($r.Hooks | Where-Object { $_.Name -eq 'undocumentedDead' }).Count -eq 0) (
        ($r.Hooks | ForEach-Object { $_.Name }) -join ', ')
    Assert 'A9 every message definition was seen' ($r.Messages.Count -eq 5) "saw $($r.Messages.Count)"
} catch {
    Write-Host "  FAIL A0 the fixture section threw -- $_" -ForegroundColor Red
    $script:fail++
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# --- B: the sweep over the real tree ----------------------------------------
Write-Host 'B. sweep over src\apprt\win32 and src\remote'
$live = Get-UnwiredHookFindings -Repo $Repo
# 234 documented hooks and 54 messages on 2026-10-17. Floors well under those
# still catch the failure they exist for: a pattern edit that matches nothing.
Assert 'B1 the sweep sees the real documented hooks (floor: 150)' ($live.Hooks.Count -ge 150) "saw $($live.Hooks.Count)"
Assert 'B2 the sweep sees the real window messages (floor: 40)' ($live.Messages.Count -ge 40) "saw $($live.Messages.Count)"
$sfd = @($live.Hooks | Where-Object { $_.Name -eq 'signalFrameDrawn' })
Assert 'B3 the original case is held to its word: signalFrameDrawn is audited and has a caller' (
    $sfd.Count -eq 1 -and $sfd[0].Refs -ge 1) "seen=$($sfd.Count) refs=$(if ($sfd.Count) { $sfd[0].Refs })"
foreach ($x in $live.Findings) { Write-Host "    $($x.Kind) $($x.File):$($x.Line) [$($x.Name)] $($x.Detail)" -ForegroundColor Yellow }
Assert 'B4 no documented hook without a caller, no message without both ends' ($live.Findings.Count -eq 0) "$($live.Findings.Count) finding(s)"

# --- C: teeth ---------------------------------------------------------------
if ($TeethCheck) {
    Write-Host 'C. teeth check'
    $planted = Join-Path $Repo 'src\apprt\win32\zz-t1034-teeth-fixture.zig'
    try {
        [IO.File]::WriteAllText($planted, @'
// A synthesized violator (T1034 teeth check). Delete this file if a teeth run
// left it behind; nothing imports it.
pub const WM_APP_ZZ_T1034_TEETH: u32 = 0x8000 + 999;

/// Called by the renderer thread after SwapBuffers (T1031's shape).
pub fn zzT1034TeethNeverCalled() void {}

fn zzT1034TeethProc(msg: u32) void {
    switch (msg) {
        WM_APP_ZZ_T1034_TEETH => {},
        else => {},
    }
}
'@, $enc)
        $teeth = @((Get-UnwiredHookFindings -Repo $Repo).Findings |
            Where-Object { $_.File -like '*zz-t1034-teeth-fixture.zig' })
        $tk = ($teeth | ForEach-Object { "$($_.Kind):$($_.Name)" }) -join ', '
        Assert 'C1 the sweep goes red on a planted documented-but-uncalled hook' (
            @($teeth | Where-Object { $_.Kind -eq 'no-caller' -and $_.Name -eq 'zzT1034TeethNeverCalled' }).Count -eq 1) $tk
        Assert 'C2 and on a planted handled-but-never-sent message, with the remedy' (
            @($teeth | Where-Object { $_.Kind -eq 'no-sender' -and $_.Detail -match 'handler is dead' }).Count -eq 1) $tk
    } finally {
        Remove-Item -LiteralPath $planted -Force -ErrorAction SilentlyContinue
    }
    Assert 'C3 the planted violator is removed again' (-not (Test-Path -LiteralPath $planted))
}

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files, and never a teeth check -
# that run deliberately plants a violator.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard unwired-hook -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'UNWIRED-HOOK AUDIT' -MinPass 13
