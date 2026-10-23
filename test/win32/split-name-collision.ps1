# T2184 acceptance: `+split --name=<n>` never silently reuses a different pane
# (the win32 half of main c2057a810).
#
# Before this, a split whose --name was already held by ANY live pane exited 0
# with no output, so an agent asking for `--view=b.html` beside itself was told
# it worked while a pane of that name in another window went on showing
# `a.html`. The contract now, on both platforms:
#
#   - The holder MATCHES the request (a terminal again, or a viewer showing or
#     opened with that --view): no split, exit 0, stdout says it was reused and
#     names the window.
#   - It does NOT match (another --view, a kind mismatch, or the name is a
#     WINDOW's): no split, exit 1, stderr names the pane, its window and what it
#     shows.
#   - A created pane says where it went, on stdout.
#
#   A  +split --name=t1                         created, names the window
#   B  the same again                           reused, "this window", no new pane
#   C  --name=t1 --view=<a>                     conflict: a terminal cannot show it
#   D  --name=v1 --view=<a>                     created, "showing <a>"
#   E  the same again                           reused
#   F  --view=<A, other case and slashes>       reused: a Windows path is one file
#   G  --name=v1 --view=<b>                     conflict naming both files
#   H  --name=v1 (a terminal)                   conflict: a viewer stands there
#   I  --name=<a window's name>                 conflict: a window holds it
#   J  --target=<other window> --name=t1        reused, names the OTHER window
#   K  --target=<nothing>                       fails (exit 1), no pane
#
# Every arm reads exit code, stdout and stderr SEPARATELY (one process each,
# redirected), and counts the panes `+list --json` reports before and after,
# so "no split created" is measured rather than read off the message.
#
# -NegativeControl inverts arm C (asserts the mismatch was accepted) and MUST
# fail: a run that passes with it means arm C cannot see a conflict.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\split-name-collision.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-splitname$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

# One CLI run with stdout, stderr and the exit code kept apart. A Process with
# redirected streams rather than `& $exe 2>&1`: under ErrorActionPreference Stop
# a native stderr line through 2>&1 throws in PS 5.1, and the two streams are
# the very thing under test.
function Invoke-Cli([string[]]$CliArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($CliArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) {
        try { $p.Kill() } catch {}
        return [pscustomobject]@{ Code = -1; Out = ''; Err = 'TIMED OUT'; ErrTail = '' }
    }
    $p.WaitForExit()
    # Err is the server's reason: the FIRST stderr line. `cli/split.zig` follows
    # a refusal with its own generic `+split failed.`, on both platforms.
    $errLines = @($errTask.Result -split "`r?`n" | Where-Object { $_.Trim() })
    $r = [pscustomobject]@{
        Code    = $p.ExitCode
        Out     = $outTask.Result.Trim()
        Err     = if ($errLines.Count) { $errLines[0].Trim() } else { '' }
        ErrTail = if ($errLines.Count -gt 1) { ($errLines[1..($errLines.Count - 1)] -join ' ').Trim() } else { '' }
    }
    Write-Host ("      ghoztty {0} -> exit {1}; out='{2}' err='{3}'" -f ($CliArgs -join ' '), $r.Code, $r.Out, $r.Err)
    return $r
}

function Count-LeafNodes($node) {
    if ($null -eq $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    return (Count-LeafNodes $node.left) + (Count-LeafNodes $node.right)
}

# Every window the app reports, as @{ Target; Panes }.
function Get-Layout {
    $r = Invoke-Cli @('+list', '--json')
    if ($r.Code -ne 0 -or -not $r.Out) { return @() }
    try { $data = ($r.Out | ConvertFrom-Json).data } catch { return @() }
    @($data.windows | ForEach-Object {
        $n = 0
        foreach ($t in @($_.tabs)) { $n += Count-LeafNodes $t.splits }
        [pscustomobject]@{ Target = [string]$_.target; Panes = $n }
    })
}
function Total-Panes { $n = 0; foreach ($w in @(Get-Layout)) { $n += $w.Panes }; return $n }

$work = Join-Path $env:TEMP "ghoztty-split-name-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$fileA = Join-Path $work 'a-doc.md'
$fileB = Join-Path $work 'b-doc.md'
Set-Content -Path $fileA -Value '# A' -Encoding ASCII
Set-Content -Path $fileB -Value '# B' -Encoding ASCII
# The same file as A, spelled the way a person might type it: other case,
# forward slashes. One file on Windows, so it must be a match.
$fileAOther = $fileA.ToUpperInvariant().Replace('\', '/')

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:appPid = 0

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: arm C asserts the mismatch was ACCEPTED - this run MUST fail'
    }

    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    $script:appPid = $app.Pid
    $w1 = [int64](Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow')
    if ($w1 -eq 0) { Write-Host 'SETUP FAIL: first window not found'; exit 1 }
    Start-Sleep -Seconds 2
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    $layout = @(Get-Layout)
    if ($layout.Count -ne 1) { Write-Host "SETUP FAIL: expected one window, +list reports $($layout.Count)"; exit 1 }
    $win1 = $layout[0].Target
    if (-not $win1) { Write-Host 'SETUP FAIL: the first window reports no target name'; exit 1 }
    # Every split below names its window, so caller anchoring (whatever pane
    # ran this script) can never pick the anchor.
    $T1 = "--target=$win1"

    # ---- A: created, and says where ----------------------------------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', $T1, '--name=t1')
    Assert ($r.Code -eq 0) "A: a new named split exits 0 (exit $($r.Code))"
    Assert ($r.Out -eq "created pane 't1' in window '$win1'") "A: stdout says where it went ('$($r.Out)')"
    Start-Sleep -Milliseconds 800
    Assert ((Total-Panes) -eq $before + 1) "A: one pane was added ($before -> $(Total-Panes))"

    # ---- B: the same split again is reused -----------------------------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', $T1, '--name=t1')
    Assert ($r.Code -eq 0) "B: re-running the split exits 0 (exit $($r.Code))"
    Assert ($r.Out -eq "pane 't1' already exists in this window ('$win1'); reused it, no split created") "B: stdout says it was reused ('$($r.Out)')"
    Assert ((Total-Panes) -eq $before) "B: no pane was added ($before -> $(Total-Panes))"

    # ---- C: a view asked of a terminal is a conflict ------------------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', $T1, '--name=t1', "--view=$fileA")
    if ($NegativeControl) {
        Assert ($r.Code -eq 0) 'C: the mismatch was accepted (negative control)'
    } else {
        Assert ($r.Code -eq 1) "C: asking a terminal's name for a view fails (exit $($r.Code))"
        Assert ($r.Err -like "pane 't1' already exists in this window ('$win1') as a terminal pane, so it cannot show *. Use another --name, or close it first: ghoztty +close --target=t1") "C: stderr names the pane, its window and the remedy"
        Assert (-not $r.Out) "C: nothing on stdout ('$($r.Out)')"
    }
    Assert ((Total-Panes) -eq $before) "C: no pane was added ($before -> $(Total-Panes))"

    # ---- D: a named viewer is created ----------------------------------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', $T1, '--name=v1', "--view=$fileA")
    Assert ($r.Code -eq 0) "D: a named viewer split exits 0 (exit $($r.Code))"
    Assert ($r.Out -like "created pane 'v1' in window '$win1', showing *a-doc.md") "D: stdout says where it went and what it shows ('$($r.Out)')"
    Start-Sleep -Seconds 2   # a viewer's WebView2 comes up asynchronously
    Assert ((Total-Panes) -eq $before + 1) "D: one pane was added ($before -> $(Total-Panes))"

    # ---- E: the same viewer again is reused ----------------------------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', $T1, '--name=v1', "--view=$fileA")
    Assert ($r.Code -eq 0) "E: re-running the viewer split exits 0 (exit $($r.Code))"
    Assert ($r.Out -like "pane 'v1' already exists in this window ('$win1'), showing *a-doc.md; reused it, no split created") "E: stdout says it was reused ('$($r.Out)')"
    Assert ((Total-Panes) -eq $before) "E: no pane was added ($before -> $(Total-Panes))"

    # ---- F: the same file spelled differently is still a match ---------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', $T1, '--name=v1', "--view=$fileAOther")
    Assert ($r.Code -eq 0) "F: the same file in another case and slash style is reused (exit $($r.Code))"
    Assert ($r.Out -like "*reused it, no split created") "F: stdout says it was reused ('$($r.Out)')"
    Assert ((Total-Panes) -eq $before) "F: no pane was added ($before -> $(Total-Panes))"

    # ---- G: another file is a conflict naming both ---------------------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', $T1, '--name=v1', "--view=$fileB")
    Assert ($r.Code -eq 1) "G: asking a viewer's name for another file fails (exit $($r.Code))"
    Assert ($r.Err -like "pane 'v1' already exists in this window ('$win1'), showing *a-doc.md, not *b-doc.md. Use another --name*") "G: stderr names what it shows and what was asked"
    Assert ((Total-Panes) -eq $before) "G: no pane was added ($before -> $(Total-Panes))"

    # ---- H: a terminal asked of a viewer is a conflict ----------------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', $T1, '--name=v1')
    Assert ($r.Code -eq 1) "H: asking a viewer's name for a terminal fails (exit $($r.Code))"
    Assert ($r.Err -like "pane 'v1' already exists in this window ('$win1') as a viewer pane showing *a-doc.md, not a terminal.*") "H: stderr says a viewer stands there"
    Assert ((Total-Panes) -eq $before) "H: no pane was added ($before -> $(Total-Panes))"

    # ---- I: a window's name is never a pane's --------------------------------
    $r = Invoke-Cli @('+new-window', '--target=snc-w2')
    if ($r.Code -ne 0) { Write-Host 'SETUP FAIL: the second window did not open'; exit 1 }
    for ($i = 0; $i -lt 30 -and @(Get-Layout).Count -lt 2; $i++) { Start-Sleep -Milliseconds 300 }
    $before = Total-Panes
    $r = Invoke-Cli @('+split', $T1, '--name=snc-w2')
    Assert ($r.Code -eq 1) "I: naming a split after a window fails (exit $($r.Code))"
    Assert ($r.Err -eq "'snc-w2' is already the name of a window, so no pane can take it. Use another --name.") "I: stderr says a window holds the name ('$($r.Err)')"
    Assert ($r.ErrTail -eq '+split failed.') "I: nothing but the CLI's own failure line follows it ('$($r.ErrTail)')"
    Assert ((Total-Panes) -eq $before) "I: no pane was added ($before -> $(Total-Panes))"

    # ---- J: reused from another window, and the reply says which -------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', '--target=snc-w2', '--name=t1')
    Assert ($r.Code -eq 0) "J: re-running from another window exits 0 (exit $($r.Code))"
    Assert ($r.Out -eq "pane 't1' already exists in window '$win1', not the window this split was for; reused it, no split created") "J: stdout names the OTHER window ('$($r.Out)')"
    Assert ((Total-Panes) -eq $before) "J: no pane was added ($before -> $(Total-Panes))"

    # ---- K: a --target that names nothing fails ------------------------------
    $before = Total-Panes
    $r = Invoke-Cli @('+split', '--target=snc-nothing-here', '--name=k1')
    Assert ($r.Code -eq 1) "K: a --target naming nothing fails (exit $($r.Code))"
    Assert ($r.Err -like "*snc-nothing-here*not found*") "K: stderr names the missing target ('$($r.Err)')"
    Assert ((Total-Panes) -eq $before) "K: no pane was added ($before -> $(Total-Panes))"

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    $launched += $script:GhozttyTestDesktopPids
    Complete-TestBody  # T1039: the last statement of the body
} finally {
    if ($script:appPid) { Stop-Process -Id $script:appPid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard split-name-collision -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'split-name-collision' -MinPass 30
