# T1827 acceptance: panes stash out of the grid on Windows - +stash/+restore,
# the stash_pane / restore_stashed_pane keybinds, and +list reporting a
# stashed pane (Mac 87afbf6ff / 597a193cc / c6826b79a).
#
# Layout: the first pane P, then `+split right` -> s1, then `+split down` off
# s1 -> s2:   P | (s1 / s2). What it checks, in order:
#
#   1. +stash s2: exit 0, s2's HWND hidden, +list --json marks it
#      "stashed": true, the text tree says [stashed], and s1 takes the whole
#      right column (the collapsed split gives its sibling the full rect).
#   2. The stashed pane is still a live, targetable pane: +send-keys and
#      +read reach it, and it keeps its real slot size while hidden (the
#      c6826b79a fix) instead of being shrunk to some placeholder.
#   3. Idempotence: a second +stash of s2 succeeds and changes nothing.
#   4. Refusals, with Mac's strings: a window target, and the last pane on
#      screen (stash s1, then P -> refused, P still visible).
#   5. +restore s2 / s1: both come back to exactly the slots they left;
#      a second +restore succeeds.
#   6. Keybinds: ctrl+shift+m (the Windows default for stash_pane) stashes
#      the focused pane; a --keybind'd restore_stashed_pane brings it back.
#   7. Closing the last visible pane with others stashed restores the top of
#      the stash instead of leaving an empty tab.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl inverts the step-1 visibility expectation and MUST fail.
#
#   powershell -NoProfile -File test\win32\ipc-stash.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1827-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1827')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# The console twin redirects cleanly (T245); the GUI exe is what launches.
$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { (Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

# Every leaf object in `+list --json`: anything carrying both `id` and `pid`.
function Get-Leaves {
    [void](Invoke-Cli '+list --json')
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$out.Add($o) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($raw | ConvertFrom-Json) } catch { return @() }
    return , $out.ToArray()
}
function Get-Leaf([string]$Name) {
    foreach ($l in (Get-Leaves)) { if ($l.name -eq $Name) { return $l } }
    return $null
}
function Test-Stashed([string]$Name) {
    $l = Get-Leaf $Name
    return ($null -ne $l) -and ($l.PSObject.Properties.Name -contains 'stashed') -and ($l.stashed -eq $true)
}

# The pane HWND behind a +list leaf: ghoztty names each terminal child after
# nothing useful, so match on the leaf order instead - the child set and the
# leaf set are the same panes, and we only ever ask "which HWND is NEW".
function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1827'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    # Nothing may answer on the private endpoint BEFORE we launch.
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--session-persistence=false',
        '--keybind=ctrl+shift+period=restore_stashed_pane'
    )
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))

    $P0 = @(Get-Panes $top)
    Assert "setup: one pane at launch" ($P0.Count -eq 1)
    $hP = $P0[0].Hwnd
    $leaves = Get-Leaves
    $firstId = if ($leaves.Count -ge 1) { $leaves[0].id } else { '' }
    Assert "setup: +list --json answers with the first pane" ($firstId -ne '')

    [void](Invoke-Cli "+split --direction=right --name=s1")
    Start-Sleep -Milliseconds 800
    $h1 = (@(Get-Panes $top) | Where-Object { $_.Hwnd -ne $hP } | Select-Object -First 1).Hwnd
    [void](Invoke-Cli "+split --pane=s1 --direction=down --name=s2")
    Start-Sleep -Milliseconds 800
    $panes = @(Get-Panes $top)
    $h2 = ($panes | Where-Object { $_.Hwnd -ne $hP -and $_.Hwnd -ne $h1 } | Select-Object -First 1).Hwnd
    Assert "setup: three visible panes" (@($panes | Where-Object Visible).Count -eq 3 -and $h1 -and $h2)
    $before1 = $panes | Where-Object { $_.Hwnd -eq $h1 }
    $before2 = $panes | Where-Object { $_.Hwnd -eq $h2 }
    $beforeP = $panes | Where-Object { $_.Hwnd -eq $hP }

    "== 1: +stash takes s2 out of the grid"
    $code = Invoke-Cli "+stash --target=s2"
    Assert "+stash s2 exit 0 ($(Get-CliErr))" ($code -eq 0)
    Start-Sleep -Milliseconds 600
    $panes = @(Get-Panes $top)
    $vis = @($panes | Where-Object Visible)
    $expectVisible = if ($NegativeControl) { 3 } else { 2 }
    if ($NegativeControl) { "  NEGATIVE CONTROL: expecting 3 visible panes - this run MUST fail" }
    Assert "two panes visible, s2 hidden" ($vis.Count -eq $expectVisible -and -not ($vis | Where-Object { $_.Hwnd -eq $h2 }))
    Assert "+list --json marks s2 stashed" (Test-Stashed 's2')
    Assert "+list --json does not mark s1" (-not (Test-Stashed 's1'))
    [void](Invoke-Cli '+list')
    Assert "+list text tree says [stashed]" ((Get-CliOut) -match '\[stashed\]')
    $now1 = $panes | Where-Object { $_.Hwnd -eq $h1 }
    Assert "s1 takes the whole right column ($($before1.Height) -> $($now1.Height), P $($beforeP.Height))" `
        ($now1.Height -gt $before1.Height -and [math]::Abs($now1.Height - $beforeP.Height) -le 4)

    "== 2: a stashed pane is live, targetable, and keeps its slot size"
    $code = Invoke-Cli "+send-keys --target=s2 `"echo t1827-stashed-marker`" --enter"
    Assert "+send-keys reaches the stashed pane ($(Get-CliErr))" ($code -eq 0)
    $seen = $false
    $deadline = (Get-Date).AddSeconds(15)
    do {
        if ((Invoke-Cli "+read --name=s2") -eq 0 -and (Get-CliOut) -match 't1827-stashed-marker') { $seen = $true; break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    Assert "+read reads the stashed pane's output" $seen
    $now2 = $panes | Where-Object { $_.Hwnd -eq $h2 }
    Assert "hidden s2 keeps its real slot size ($($before2.Width)x$($before2.Height) -> $($now2.Width)x$($now2.Height))" `
        ([math]::Abs($now2.Width - $before2.Width) -le 2 -and [math]::Abs($now2.Height - $before2.Height) -le 2)
    # The check above cannot fail on its own - a hidden window keeps whatever
    # size it last had. This one can: grow the window while s2 is stashed,
    # and its hidden HWND must follow the slot the full layout now gives it
    # (and match s1's width, its sibling in that column), not stay frozen.
    [void](Set-TestWindowSize -Window $top -Width 160 -Height 120 -Grow)
    Start-Sleep -Milliseconds 800
    $grown = @(Get-Panes $top)
    $g1 = $grown | Where-Object { $_.Hwnd -eq $h1 }
    $g2 = $grown | Where-Object { $_.Hwnd -eq $h2 }
    Assert "hidden s2 tracks its slot through a window resize ($($now2.Width) -> $($g2.Width), s1 $($g1.Width))" `
        ($g2.Width -gt $now2.Width -and [math]::Abs($g2.Width - $g1.Width) -le 2 -and -not $g2.Visible)
    [void](Set-TestWindowSize -Window $top -Width -160 -Height -120 -Grow)
    Start-Sleep -Milliseconds 800

    "== 3: idempotent"
    $code = Invoke-Cli "+stash --target=s2"
    Assert "second +stash s2 exit 0" ($code -eq 0)
    Assert "still stashed" (Test-Stashed 's2')

    "== 4: refusals"
    [void](Invoke-Cli "+new-window --target=t1827win")
    Start-Sleep -Milliseconds 800
    $code = Invoke-Cli "+stash --target=t1827win"
    Assert "a window target is refused (exit $code)" ($code -ne 0 -and (Get-CliErr) -match "is a window; \+stash takes a pane")
    [void](Invoke-Cli "+close --target=t1827win")
    Start-Sleep -Milliseconds 500
    $code = Invoke-Cli "+stash --target=s1"
    Assert "+stash s1 exit 0" ($code -eq 0)
    $code = Invoke-Cli "+stash --target=$firstId"
    Assert "the last pane on screen is refused (exit $code)" ($code -ne 0 -and (Get-CliErr) -match 'last pane on screen')
    Start-Sleep -Milliseconds 400
    $vis = @(Get-Panes $top | Where-Object Visible)
    Assert "P is still on screen, alone" ($vis.Count -eq 1 -and $vis[0].Hwnd -eq $hP)
    $code = Invoke-Cli "+stash --target=nope-t1827"
    Assert "an unknown target is refused" ($code -ne 0 -and (Get-CliErr) -match 'not found in registry')

    "== 5: +restore puts both back in the slots they left"
    Assert "+restore s1 exit 0" ((Invoke-Cli "+restore --target=s1") -eq 0)
    Assert "+restore s2 exit 0" ((Invoke-Cli "+restore --target=s2") -eq 0)
    Start-Sleep -Milliseconds 600
    $panes = @(Get-Panes $top)
    Assert "three visible panes again" (@($panes | Where-Object Visible).Count -eq 3)
    Assert "nothing reported stashed" (-not (Test-Stashed 's1') -and -not (Test-Stashed 's2'))
    $after1 = $panes | Where-Object { $_.Hwnd -eq $h1 }
    $after2 = $panes | Where-Object { $_.Hwnd -eq $h2 }
    Assert "s1 is back in its slot" ($after1.Top -eq $before1.Top -and $after1.Height -eq $before1.Height -and $after1.Left -eq $before1.Left)
    Assert "s2 is back in its slot" ($after2.Top -eq $before2.Top -and $after2.Height -eq $before2.Height -and $after2.Left -eq $before2.Left)
    Assert "a second +restore succeeds" ((Invoke-Cli "+restore --target=s2") -eq 0)

    "== 6: keybinds"
    Assert "focus s2 for the chord" (Focus-TestWindow -Window $top -Child ([IntPtr]$h2))
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$h2) -Modifiers ctrl,shift -Key M
    Assert "ctrl+shift+m delivered" $r
    $ok = $false
    $deadline = (Get-Date).AddSeconds(5)
    do { if (Test-Stashed 's2') { $ok = $true; break }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $deadline)
    Assert "stash_pane (ctrl+shift+m) stashed the focused pane" $ok
    $focus = Get-TestFocusedWindow -Window $top
    Assert "focus moved off the stashed pane to a visible one" ($focus -and $focus -ne $h2 -and (@(Get-Panes $top | Where-Object { $_.Visible -and $_.Hwnd -eq $focus }).Count -eq 1))
    $r = Send-TestKeys -Window $top -Target ([IntPtr]$focus) -Modifiers ctrl,shift -Key period
    Assert "restore chord delivered" $r
    $ok = $false
    $deadline = (Get-Date).AddSeconds(5)
    do { if (-not (Test-Stashed 's2')) { $ok = $true; break }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $deadline)
    Assert "restore_stashed_pane brought it back" $ok

    "== 7: closing the last visible pane restores the top of the stash"
    [void](Invoke-Cli "+stash --target=s1")
    [void](Invoke-Cli "+stash --target=s2")
    Assert "s1 and s2 stashed" ((Test-Stashed 's1') -and (Test-Stashed 's2'))
    $code = Invoke-Cli "+close --target=$firstId"
    Assert "+close the only visible pane exit 0" ($code -eq 0)
    Start-Sleep -Milliseconds 800
    $vis = @(Get-Panes $top | Where-Object Visible)
    Assert "one pane on screen, not an empty window" ($vis.Count -eq 1)
    Assert "it is the top of the stash (s2), and s1 stays stashed" ($vis.Count -eq 1 -and $vis[0].Hwnd -eq $h2 -and (Test-Stashed 's1') -and -not (Test-Stashed 's2'))

    "== 8: +rearrange keeps an omitted stashed pane stashed, and restores a placed one"
    # State now: s2 on screen, s1 stashed. A layout written from the visible
    # grid naturally omits s1; win32 +rearrange destroys omitted panes, so
    # without the carry this would close a pane the user could not even see.
    [void](Invoke-Cli "+split --pane=s2 --direction=right --name=s3")
    Start-Sleep -Milliseconds 800
    $layout = '{"direction":"horizontal","left":{"pane":"s3"},"right":{"pane":"s2"}}'
    $code = Invoke-Cli ('+rearrange "--layout=' + ($layout -replace '"', '\"') + '"')
    Assert "+rearrange omitting stashed s1 exit 0 ($(Get-CliErr))" ($code -eq 0)
    Start-Sleep -Milliseconds 600
    Assert "s1 survived the rearrange, still stashed" (Test-Stashed 's1')
    Assert "s1 is still a live HWND, hidden" (@(Get-Panes $top | Where-Object { $_.Hwnd -eq $h1 -and -not $_.Visible }).Count -eq 1)
    Assert "two panes on screen (s3, s2)" (@(Get-Panes $top | Where-Object Visible).Count -eq 2)
    $layout = '{"direction":"horizontal","left":{"pane":"s2"},"right":{"pane":"s1"}}'
    $code = Invoke-Cli ('+rearrange "--layout=' + ($layout -replace '"', '\"') + '"')
    Assert "+rearrange placing s1 exit 0 ($(Get-CliErr))" ($code -eq 0)
    Start-Sleep -Milliseconds 600
    Assert "a placed stashed pane comes back on screen" (-not (Test-Stashed 's1') -and @(Get-Panes $top | Where-Object { $_.Hwnd -eq $h1 -and $_.Visible }).Count -eq 1)
    Assert "the omitted visible pane s3 was closed, as before" ($null -eq (Get-Leaf 's3'))

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

# A body that died part-way must not score green on the assertions it made
# before dying (the T271 shape).
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

# A green run stamps the covered files (T783); red, or a negative control,
# leaves the stamp alone so the row stays due.
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard ipc-stash -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1827' -Path $transcript `
        -Label 'T1827 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
