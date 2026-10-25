# T2234 acceptance: a +rearrange can be undone on Windows, the way Mac's
# "Rearrange Layout" undo does it - ctrl+shift+z puts the previous layout back,
# panes the rearrange left out included, and ctrl+shift+y puts the rearranged
# one back again. Only when the undo expires is a left-out pane ended.
#
# Setup (session-persistence off, --undo-timeout=6s; local ConPTY panes):
#   The launch pane P, B split right of it, and C split below - three panes
#   in two splits, whatever the second split's anchor.
#   1. +rearrange to C | P, leaving B out: B leaves +list, its HWND is hidden
#      rather than destroyed, and its shell is still running.
#   2. ctrl+shift+z: the old layout is back - same tree, same ratios, every
#      pane in the rectangle it had - and B is back with the same shell and
#      its --name resolving again.
#   3. ctrl+shift+y puts the rearranged layout back (B parked again, shell
#      alive); ctrl+shift+z restores the old one again.
#   4. A rearrange that leaves nothing out (B and C swapped) undoes too.
#   5. Expiry: rearrange B out again and wait out the timeout - B's HWND is
#      destroyed, its shell has exited, and ctrl+shift+z no longer changes the
#      layout back.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl launches with --undo-timeout=0 (undo disabled) and keeps
# every expectation, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\rearrange-undo.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2234-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
[void](Set-GhozttyTestAgentLineage -Tag 't2234')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2234')

# The console twin redirects cleanly (T245); the GUI exe is what launches.
$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { (Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Get-ListJson {
    [void](Invoke-Cli '+list --json')
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

# Every leaf object in `+list --json`: anything carrying both `id` and `pid`.
function Get-Leaves {
    $j = Get-ListJson
    if ($null -eq $j) { return @() }
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
    & $walk $j
    return , $out.ToArray()
}
function Get-LeafById([string]$Id) {
    foreach ($l in (Get-Leaves)) { if ($l.id -eq $Id) { return $l } }
    return $null
}
function Get-LeafByName([string]$Name) {
    foreach ($l in (Get-Leaves)) { if ($l.name -eq $Name) { return $l } }
    return $null
}

# The first tab's layout as one string: `h(0.30,<id>,v(0.50,<id>,<id>))`.
# Directions, ratios and pane ids - what an undo has to put back - and nothing
# that moves on its own (titles, states).
function Get-Shape {
    $j = Get-ListJson
    if ($null -eq $j) { return '' }
    $windows = if ($null -ne $j.data) { $j.data.windows } else { $j.windows }
    $w = @($windows) | Select-Object -First 1
    if ($null -eq $w) { return '' }
    $node = @($w.tabs)[0].splits
    $fmt = $null
    $fmt = {
        param($n)
        if ($null -eq $n) { return '?' }
        $names = @($n.PSObject.Properties.Name)
        if ($names -contains 'direction') {
            $d = if ($n.direction -eq 'horizontal') { 'h' } else { 'v' }
            return ('{0}({1:N2},{2},{3})' -f $d, [double]$n.ratio, (& $fmt $n.left), (& $fmt $n.right))
        }
        if ($names -contains 'terminal') { return [string]$n.terminal.id }
        foreach ($p in $n.PSObject.Properties) {
            if ($p.Value -is [System.Management.Automation.PSCustomObject] -and `
                    (@($p.Value.PSObject.Properties.Name) -contains 'id')) { return [string]$p.Value.id }
        }
        return '?'
    }
    return (& $fmt $node)
}

function Test-ProcAlive([int]$ProcId) {
    if ($ProcId -le 0) { return $false }
    return ($null -ne (Get-Process -Id $ProcId -ErrorAction SilentlyContinue))
}
function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Get-Pane($top, $hwnd) { @(Get-Panes $top) | Where-Object { $_.Hwnd -eq $hwnd } | Select-Object -First 1 }
function Get-Rects($top, $hwnds) {
    $r = @{}
    foreach ($h in $hwnds) {
        $p = Get-Pane $top $h
        $r["$h"] = if ($null -ne $p -and $p.Visible) { "$($p.Left),$($p.Top),$($p.Width),$($p.Height)" } else { 'hidden' }
    }
    return $r
}
function Test-SameRects($a, $b) {
    foreach ($k in $a.Keys) { if ($a[$k] -ne $b[$k]) { return $false } }
    return $true
}

# Poll until $Probe answers true (or the deadline passes).
function Wait-Until([scriptblock]$Probe, [int]$Seconds = 6) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (& $Probe) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

# Press a ctrl+shift chord at the pane that has the keyboard.
function Send-Chord($top, $hwnd, [string]$Key) {
    [void](Focus-TestWindow -Window $top -Child ([IntPtr]$hwnd))
    return (Send-TestKeys -Window $top -Target ([IntPtr]$hwnd) -Modifiers ctrl,shift -Key $Key)
}

function Invoke-Rearrange([string]$Layout) {
    # cmd /c re-parses the line: the JSON's quotes are escaped for the exe.
    return (Invoke-Cli ('+rearrange --layout="' + ($Layout -replace '"', '\"') + '"'))
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2234'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    $timeout = if ($NegativeControl) { '0' } else { '6s' }
    if ($NegativeControl) { "  NEGATIVE CONTROL: undo-timeout=0 disables undo - this run MUST fail" }
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false', "--undo-timeout=$timeout")
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))

    $P0 = @(Get-Panes $top)
    Assert "setup: one pane at launch" ($P0.Count -eq 1)
    $hP = $P0[0].Hwnd
    $allLeaves = Get-Leaves
    $leafP = if ($allLeaves.Count -gt 0) { $allLeaves[0] } else { $null }
    $paneP = if ($null -ne $leafP) { $leafP.id } else { '' }

    [void](Invoke-Cli "+split --direction=right --name=rb")
    [void](Wait-Until { $null -ne (Get-LeafByName 'rb') })
    [void](Invoke-Cli "+split --direction=down --name=rc")
    [void](Wait-Until { $null -ne (Get-LeafByName 'rc') })
    $b = Get-LeafByName 'rb'
    $c = Get-LeafByName 'rc'
    $bId = if ($null -ne $b) { $b.id } else { '' }
    $bPid = if ($null -ne $b) { [int]$b.pid } else { 0 }
    $cId = if ($null -ne $c) { $c.id } else { '' }
    Assert "setup: three panes, B's shell live (pid $bPid)" ($paneP -ne '' -and $bId -ne '' -and $cId -ne '' -and (Test-ProcAlive $bPid))
    [void](Wait-Until { @(Get-Panes $top | Where-Object Visible).Count -eq 3 })
    $hwnds = @(Get-Panes $top | ForEach-Object { $_.Hwnd })
    $hB = $null
    foreach ($h in $hwnds) { if ($h -ne $hP) { $hB = $h } }
    Start-Sleep -Milliseconds 500
    $shape0 = Get-Shape
    $rects0 = Get-Rects $top $hwnds
    "  layout before: $shape0"
    Assert "setup: the starting layout has three panes in two splits" (([regex]::Matches($shape0, '[hv]\(').Count -eq 2) -and `
            $shape0.Contains($paneP) -and $shape0.Contains($bId) -and $shape0.Contains($cId))

    $left = "{`"direction`":`"horizontal`",`"ratio`":70,`"left`":{`"pane`":`"$cId`"},`"right`":{`"pane`":`"$paneP`"}}"

    "== 1: a rearrange that leaves B out parks it"
    $code = Invoke-Rearrange $left
    Assert "+rearrange exit 0 ($(Get-CliErr))" ($code -eq 0)
    Assert "B left +list" (Wait-Until { $null -eq (Get-LeafById $bId) })
    $shape1 = Get-Shape
    "  layout after: $shape1"
    Assert "the layout is C | P at 0.70" ($shape1 -eq "h(0.70,$cId,$paneP)")
    $hidden = @(Get-Panes $top | Where-Object { -not $_.Visible })
    Assert "B's HWND still exists, hidden" ($hidden.Count -eq 1)
    if ($hidden.Count -eq 1) { $hB = $hidden[0].Hwnd }
    Assert "B's shell is still running" (Test-ProcAlive $bPid)

    "== 2: ctrl+shift+z puts the previous layout back"
    Assert "ctrl+shift+z delivered" (Send-Chord $top $hP 'Z')
    Assert "B is listed again" (Wait-Until { $null -ne (Get-LeafById $bId) })
    Assert "the layout is back ($(Get-Shape))" (Wait-Until { (Get-Shape) -eq $shape0 })
    $bBack = Get-LeafById $bId
    Assert "same shell pid ($bPid -> $(if ($bBack) { $bBack.pid }))" ($null -ne $bBack -and [int]$bBack.pid -eq $bPid)
    Assert "its --name resolves again" ($null -ne (Get-LeafByName 'rb'))
    Assert "every pane is back in the rectangle it had" (Wait-Until { Test-SameRects $rects0 (Get-Rects $top $hwnds) })

    "== 3: redo puts the rearranged layout back; undo restores again"
    Assert "ctrl+shift+y delivered" (Send-Chord $top $hP 'Y')
    Assert "redo: the layout is C | P again ($(Get-Shape))" (Wait-Until { (Get-Shape) -eq $shape1 })
    Assert "redo: B left +list again, shell alive" ($null -eq (Get-LeafById $bId) -and (Test-ProcAlive $bPid))
    Assert "ctrl+shift+z delivered (after redo)" (Send-Chord $top $hP 'Z')
    Assert "undo after redo: the old layout is back" (Wait-Until { (Get-Shape) -eq $shape0 -and $null -ne (Get-LeafById $bId) })

    "== 4: a rearrange that leaves nothing out undoes too"
    $swap = "{`"direction`":`"horizontal`",`"ratio`":50,`"left`":{`"pane`":`"$paneP`"},`"right`":{`"direction`":`"vertical`",`"ratio`":50,`"left`":{`"pane`":`"$cId`"},`"right`":{`"pane`":`"$bId`"}}}"
    $code = Invoke-Rearrange $swap
    Assert "+rearrange (swap) exit 0 ($(Get-CliErr))" ($code -eq 0)
    Assert "B and C swapped ($(Get-Shape))" (Wait-Until { (Get-Shape) -eq "h(0.50,$paneP,v(0.50,$cId,$bId))" })
    Assert "ctrl+shift+z delivered (swap)" (Send-Chord $top $hP 'Z')
    Assert "the swap is undone" (Wait-Until { (Get-Shape) -eq $shape0 })

    "== 5: expiry ends the left-out pane"
    $code = Invoke-Rearrange $left
    Assert "+rearrange exit 0 (expiry)" ($code -eq 0)
    Assert "B left +list (expiry)" (Wait-Until { $null -eq (Get-LeafById $bId) })
    Assert "B's shell exits once the undo expires" (Wait-Until { -not (Test-ProcAlive $bPid) } 15)
    Assert "B's HWND is destroyed" (Wait-Until { -not (Test-TestWindowExists -Window ([IntPtr]$hB)) } 5)
    [void](Send-Chord $top $hP 'Z')
    Start-Sleep -Milliseconds 1500
    Assert "nothing is left to undo: the layout stays C | P ($(Get-Shape))" ((Get-Shape) -eq "h(0.70,$cId,$paneP)")

    Assert "no crash" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim()))"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 500)
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
        update -Guard rearrange-undo -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2234' -Path $transcript `
        -Label 'T2234 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
