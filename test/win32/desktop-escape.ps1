<#
.SYNOPSIS
    T2203 acceptance - the box-side desktop-escape runner reports a window from
    the repo build that reaches the interactive desktop, by a spelling the
    static audit cannot see, and reports nothing for a script that opens none.

.DESCRIPTION
    Five sections, all against PLANTED scripts in a scratch root under the
    repo's temp\ - never against the real suite, and never against the real app:

      A. Root containment is by whole path segment (`D:\x\ghoztty` does not
         contain `D:\x\ghoztty-b\...`), so a sibling lane's process is never
         attributed to this worktree.

      B. Eligibility. A script declared `@input-desktop-exception` or
         `@user-desktop-launch`, or carrying a launch site the static audit
         sees, is REFUSED and never run; the planted escapee is ELIGIBLE,
         which is the point - the static audit passes it.

      C. The negative control, the reason this harness exists: the escapee
         starts a renamed exe under the scratch root through Invoke-Expression
         of an assembled string, and that process shows a window on this
         desktop. The runner must say ESCAPED and name the window. The window
         is 1x1, off-screen at (-32000,-32000), never activated and never in
         the taskbar, so the user sees nothing and keeps their focus.

      D. The clean control: the SAME exe started the same way with no window
         is CLEAN - the measurement is "a visible window", not "a process".

      E. The CLI (`scripts\desktop-escape-run.ps1`): exit 1 and an escape count
         over the escapee, exit 0 over the clean script, and a refused script
         is listed REFUSED and never started.

.NOTES
    # persistence: launches no Ghoztty GUI - the only process it starts is a
    # renamed copy of powershell.exe that owns one off-screen 1x1 window.

    # isolation: none - nothing here talks to an app or agent endpoint.

    # preflight: none - it launches no app.

    # desktop-launch-audit: the planted scripts are string fixtures written to
    # a scratch root outside test\win32 and deleted in the finally block; the
    # one process they start is a powershell decoy, never the app.

    # foreground-audit: the only window API is SetWindowPos with
    # SWP_NOACTIVATE on a window that this harness's own decoy owns, placed
    # off-screen; no injection, no screen DC, no foreground change.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Suite = Join-Path $Repo 'test\win32'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\DesktopLaunchAudit.ps1')
. (Join-Path $PSScriptRoot 'lib\DesktopEscape.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

$scratch = Join-Path $Repo ("temp\desktop-escape-{0}" -f $PID)
$bin = Join-Path $scratch 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
$decoy = Join-Path $bin 'ghoztty-nc.exe'

try {
    Copy-Item -LiteralPath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Destination $decoy -Force

    # The window the decoy shows: off-screen, 1x1, no taskbar button, shown
    # with SWP_NOACTIVATE so the user's foreground never moves.
    $winScript = Join-Path $bin 'window.ps1'
    @'
param([int]$Seconds = 4, [switch]$NoWindow)
if ($NoWindow) { Start-Sleep -Seconds $Seconds; exit 0 }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class NcWin {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
}
"@
$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle = 'None'
$f.ShowInTaskbar = $false
$f.StartPosition = 'Manual'
$f.Text = 'T2203 negative control'
$h = $f.Handle
# HWND_BOTTOM, SWP_NOACTIVATE (0x10) | SWP_SHOWWINDOW (0x40)
[void][NcWin]::SetWindowPos($h, [IntPtr]1, -32000, -32000, 1, 1, 0x50)
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
$f.Dispose()
exit 0
'@ | Set-Content -LiteralPath $winScript -Encoding ascii

    # The escapee: the launch is an assembled string handed to
    # Invoke-Expression, which no reading of the text can resolve.
    $escapee = Join-Path $scratch 'planted-escapee.ps1'
    @'
$x = Join-Path $PSScriptRoot 'bin\ghoztty-nc.exe'
$w = Join-Path $PSScriptRoot 'bin\window.ps1'
$verb = 'Start' + '-' + 'Process'
Invoke-Expression ("$verb -FilePath '$x' -WindowStyle Hidden -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$w'")
exit 0
'@ | Set-Content -LiteralPath $escapee -Encoding ascii

    $quiet = Join-Path $scratch 'planted-quiet.ps1'
    @'
$x = Join-Path $PSScriptRoot 'bin\ghoztty-nc.exe'
$w = Join-Path $PSScriptRoot 'bin\window.ps1'
$verb = 'Start' + '-' + 'Process'
Invoke-Expression ("$verb -FilePath '$x' -WindowStyle Hidden -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$w','-NoWindow'")
exit 0
'@ | Set-Content -LiteralPath $quiet -Encoding ascii

    $static = Join-Path $scratch 'planted-static.ps1'
    @'
$Exe = 'C:\nowhere\ghoztty.exe'
Start-Process $Exe -PassThru
'@ | Set-Content -LiteralPath $static -Encoding ascii

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'A. root containment'
    Assert 'A1 a file under the root is contained' (Test-DesktopEscapeUnderRoot -Path 'D:\x\ghoztty\zig-out\bin\ghoztty.exe' -Roots @('D:\x\ghoztty'))
    Assert 'A2 a sibling worktree is NOT contained' (-not (Test-DesktopEscapeUnderRoot -Path 'D:\x\ghoztty-b\zig-out\bin\ghoztty.exe' -Roots @('D:\x\ghoztty')))
    Assert 'A3 case does not matter' (Test-DesktopEscapeUnderRoot -Path 'd:\X\GHOZTTY\a.exe' -Roots @('D:\x\ghoztty\'))
    Assert 'A4 an empty path is not contained' (-not (Test-DesktopEscapeUnderRoot -Path '' -Roots @('D:\x')))

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'B. eligibility'
    $decl = [pscustomobject]@{ Input = @('planted-quiet.ps1'); User = @('planted-other.ps1') }
    $none = [pscustomobject]@{ Input = @(); User = @() }
    $e = Get-DesktopEscapeEligibility -Path $quiet -Declared $decl
    Assert 'B1 an @input-desktop-exception script is refused' (-not $e.Eligible -and $e.Reason -eq 'declared-input-desktop')
    $e = Get-DesktopEscapeEligibility -Path (Join-Path $scratch 'planted-other.ps1') -Declared $decl
    Assert 'B2 an @user-desktop-launch script is refused' (-not $e.Eligible -and $e.Reason -eq 'declared-user-desktop')
    $e = Get-DesktopEscapeEligibility -Path $static -Declared $none
    Assert 'B3 a static launch site is refused' (-not $e.Eligible -and $e.Reason -like 'static-launch-site*')
    $e = Get-DesktopEscapeEligibility -Path $escapee -Declared $none
    Assert 'B4 the planted escapee PASSES the static audit (the gap this closes)' ($e.Eligible)
    $real = Get-DesktopEscapeDeclaredSets -Suite $Suite
    Assert 'B5 the real declaration lists are read from the harness' (@($real.Input).Count -ge 5 -and (@($real.Input) -contains 'frame-lab.ps1'))

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'C. negative control: an escape the static audit cannot see'
    $r = Invoke-DesktopEscapeRun -Script $escapee -Roots @($scratch) -TimeoutSeconds 120 -LogPath (Join-Path $scratch 'escapee.log')
    foreach ($l in @(Format-DesktopEscapeResult -Result $r)) { Write-Host "    $l" }
    Assert 'C1 the runner says ESCAPED' ($r.Verdict -eq 'ESCAPED')
    $w = @($r.Escapes | Where-Object { $_.Title -eq 'T2203 negative control' })
    Assert 'C2 it names the window by title' ($w.Count -ge 1)
    Assert 'C3 it names the image under the root' ($w.Count -ge 1 -and $w[0].Path -ieq $decoy)
    Assert 'C4 the script itself ran to completion (exit 0)' ($r.ExitCode -eq 0)
    Assert 'C5 more than one sample was taken' ($r.Samples -gt 1)

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'D. clean control: the same process, no window'
    $r = Invoke-DesktopEscapeRun -Script $quiet -Roots @($scratch) -TimeoutSeconds 120 -LogPath (Join-Path $scratch 'quiet.log')
    foreach ($l in @(Format-DesktopEscapeResult -Result $r)) { Write-Host "    $l" }
    Assert 'D1 the runner says CLEAN' ($r.Verdict -eq 'CLEAN')
    Assert 'D2 no window is reported' (@($r.Escapes).Count -eq 0)
    Assert 'D3 the script ran (exit 0, several samples)' ($r.ExitCode -eq 0 -and $r.Samples -gt 1)

    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host 'E. the CLI'
    $cli = Join-Path $Repo 'scripts\desktop-escape-run.ps1'
    $ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $out = @(& $ps -NoProfile -ExecutionPolicy Bypass -File $cli -Scripts $escapee -Roots $scratch -Suite $Suite -TimeoutSeconds 120 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    Assert 'E1 an escape exits 1' ($code -eq 1)
    Assert 'E2 the summary counts it' (@($out | Where-Object { $_ -match '^DESKTOP ESCAPE: 1 escaped of 1 run' }).Count -eq 1)
    $out = @(& $ps -NoProfile -ExecutionPolicy Bypass -File $cli -Scripts "$quiet,$static" -Roots $scratch -Suite $Suite -TimeoutSeconds 120 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    Assert 'E3 a clean run exits 0' ($code -eq 0)
    Assert 'E4 the static-launch script is REFUSED, not run' (@($out | Where-Object { $_ -match '^REFUSED\s+planted-static\.ps1\s+\(static-launch-site' }).Count -eq 1)
    Assert 'E5 the summary says 0 of 1 run, 1 refused' (@($out | Where-Object { $_ -match '^DESKTOP ESCAPE: 0 escaped of 1 run \(1 refused\)' }).Count -eq 1)
    $out = @(& $ps -NoProfile -ExecutionPolicy Bypass -File $cli -All -List -Suite $Suite 2>&1 | ForEach-Object { "$_" })
    Assert 'E6 -List over the suite refuses the declared input-desktop scripts' (@($out | Where-Object { $_ -match '^REFUSED\s+frame-lab\.ps1\s+\(declared-input-desktop\)' }).Count -eq 1)
    Assert 'E7 -List prints a count line and runs nothing' (@($out | Where-Object { $_ -match '^DESKTOP ESCAPE LIST: \d+ eligible, \d+ refused' }).Count -eq 1)
} catch {
    # An unwind must not reach a green verdict (T1039).
    Assert "X0 the run reached its end ($_)" $false
} finally {
    Get-Process -Name 'ghoztty-nc' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.MainModule.FileName -ieq $decoy } catch { $false }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783): only a clean green run records the covered files ---------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard desktop-escape -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

exit (Write-TestVerdict -Label 'DESKTOP ESCAPE' -Pass $script:pass -Fail $script:fail).Code
