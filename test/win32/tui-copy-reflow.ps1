# T1799 acceptance: copying text a TUI wrapped itself comes out clean on
# Windows, through EVERY win32 copy route - the margin dropped, the paragraph
# rejoined, code indentation kept, a URL the TUI broke across rows whole.
#
# THE FEATURE. Main d886ba4b5 (`formatter.Options.reflow`, `hard_wrap.zig`)
# undoes the layout a TUI like Claude Code imposes on its own output: it word-
# wraps each paragraph at the pane edge and re-indents every row to its block
# margin, so the grid holds real newlines and real leading spaces. The
# transform is shared core; what this script proves is that each way a
# Windows user copies reaches it, rather than some win32 path dumping the
# selection raw:
#
#   A  ctrl+shift+c           (the cross-platform copy chord)
#   B  ctrl+c with a selection (the Windows Terminal-style chord, T154)
#   C  ctrl+insert            (the classic Windows chord, T522)
#   D  context menu > Copy    (right-click inside the selection)
#   E  copy-on-select         (a second launch, `copy-on-select = clipboard`)
#   F  ctrl-hover over either row of the broken URL shows the WHOLE URL in the
#      link bubble: hover detection crossed the seam (the URL is highlighted
#      and is what a ctrl+click would open - that click is not issued here,
#      because opening a URL launches a browser on the user's desktop)
#   G  `+read` of the same screen is RAW - margin and row breaks intact. This
#      arm is also the oracle's sensitivity control: the reflow assertions are
#      applied to the raw text and must reject it, so a pass above cannot be
#      an assertion that accepts anything.
#
# THE FIXTURE is a stand-in TUI: a powershell probe run as the pane's command.
# It asks the console for its width, wraps a paragraph greedily at that width
# behind a two-column margin (what wrap-ansi does), breaks a URL longer than
# the line at the edge, and indents a code block four columns deeper. It
# writes with virtual-terminal processing ON, as node does: without it conhost
# wraps the cursor the moment a row fills the last column and records that as
# a soft wrap, which is not the shape a real TUI produces. It reports exactly
# what it drew to a JSON file, which is where the expected strings come from.
#
# Runs on the background test desktop (T217/T1241) and asserts at the end that
# no window it launched ever took the user's foreground. The clipboard is one
# per window station, so it cannot be isolated: the user's text is saved first
# and put back at the end.
#
#   powershell -NoProfile -File test\win32\tui-copy-reflow.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

# T351: shared reset/kill helpers; drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# T1511: the shared scorer; arms Complete-TestBody / Write-TestVerdict.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:failures = 0
$script:passes = 0
$script:skipped = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

Add-Type -AssemblyName System.Windows.Forms
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    'SETUP FAIL: run under an STA host (powershell.exe, not -MTA)'
    exit 1
}

$root = Join-Path $env:TEMP "ghoztty-tui-copy-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$probe = Join-Path $root 'tui.ps1'

# ---- the stand-in TUI ------------------------------------------------------
@'
param([string]$Out)
Add-Type -Namespace T1799Probe -Name Con -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
"@
$h = [T1799Probe.Con]::GetStdHandle(-11)
$m = [uint32]0
[void][T1799Probe.Con]::GetConsoleMode($h, [ref]$m)
# ENABLE_VIRTUAL_TERMINAL_PROCESSING: deferred end-of-line wrap, like node.
$vt = [T1799Probe.Con]::SetConsoleMode($h, ($m -bor 4))
# Let the pane reach its final size before measuring it.
Start-Sleep -Milliseconds 1500
$cols = [Console]::WindowWidth
$rows = [Console]::WindowHeight
$margin = '  '
$width = $cols - $margin.Length

$vocab = 'copied text from a terminal program should read as one line again once it leaves the pane and the margin the program drew should not come along with it'.Split(' ')
$words = New-Object System.Collections.Generic.List[string]
$len = 0
$i = 0
while ($len -lt (3 * $width + 10)) {
    $w = $vocab[$i % $vocab.Count]; $i++
    $words.Add($w); $len += $w.Length + 1
}
$para = ($words -join ' ')
$paraRows = New-Object System.Collections.Generic.List[string]
$line = ''
foreach ($w in $words) {
    if ($line.Length -eq 0) { $line = $w }
    elseif ($line.Length + 1 + $w.Length -le $width) { $line += ' ' + $w }
    else { $paraRows.Add($line); $line = $w }
}
if ($line.Length -gt 0) { $paraRows.Add($line) }

$url = 'https://example.com/ghoztty/t1799'
$n = 0
while ($url.Length -lt ($width + 17)) { $n++; $url += "/reflow-seam-$n" }
$urlRows = @($url.Substring(0, $width), $url.Substring($width))

$code = @('fn main() {', '    let x = 1;', '}')

$screen = New-Object System.Collections.Generic.List[string]
foreach ($r in $paraRows) { $screen.Add($margin + $r) }
$screen.Add('')
$urlRow = $screen.Count
foreach ($r in $urlRows) { $screen.Add($margin + $r) }
$screen.Add('')
foreach ($c in $code) { $screen.Add($margin + '    ' + $c) }

$e = [char]27
[Console]::Out.Write("$e[H$e[2J$e[3J" + ($screen -join "`r`n"))
[Console]::Out.Flush()

$o = [ordered]@{
    vt = $vt; cols = $cols; rows = $rows; margin = $margin.Length
    para = $para; paraRows = @($paraRows); url = $url; urlRows = $urlRows
    urlRow = $urlRow; code = $code; screen = @($screen)
}
[IO.File]::WriteAllText($Out, ($o | ConvertTo-Json -Depth 4))
Start-Sleep -Seconds 900
'@ | Set-Content -Path $probe -Encoding ASCII

# ---- helpers ---------------------------------------------------------------
function Get-ClipText {
    for ($t = 0; $t -lt 20; $t++) {
        try { return [System.Windows.Forms.Clipboard]::GetText() } catch { Start-Sleep -Milliseconds 30 }
    }
    return $null
}
function Set-ClipText([string]$text) {
    for ($t = 0; $t -lt 12; $t++) {
        try {
            if ($text -eq '') { [System.Windows.Forms.Clipboard]::Clear() }
            else { [System.Windows.Forms.Clipboard]::SetText($text) }
            return $true
        } catch { Start-Sleep -Milliseconds 40 }
    }
    return $false
}
# The clipboard after a copy, or $null if it still holds $sentinel.
function Wait-ClipChange([string]$sentinel, [int]$timeoutMs = 6000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $c = Get-ClipText
        if ($null -ne $c -and $c -ne $sentinel) { return $c }
        Start-Sleep -Milliseconds 100
    }
    return $null
}
function Get-Lines([string]$text) {
    if ($null -eq $text) { return @() }
    return @(($text -replace "`r`n", "`n") -split "`n" | ForEach-Object { $_.TrimEnd() })
}

# The reflow verdict on a piece of copied text, one named check per property,
# so a failure says WHICH property the route lost.
function Test-Reflowed([string]$text, $fx) {
    $lines = @(Get-Lines $text)
    $codeBlock = @($fx.code | ForEach-Object { '    ' + $_ })
    $codeAt = -1
    for ($k = 0; $k -le $lines.Count - $codeBlock.Count; $k++) {
        $hit = $true
        for ($j = 0; $j -lt $codeBlock.Count; $j++) {
            if ($lines[$k + $j] -cne $codeBlock[$j]) { $hit = $false; break }
        }
        if ($hit) { $codeAt = $k; break }
    }
    [pscustomobject]@{
        Paragraph = ($lines -ccontains $fx.para)
        Url       = ($lines -ccontains $fx.url)
        Code      = ($codeAt -ge 0)
        NoMargin  = (@($lines | Where-Object { $_ -match '^  \S' }).Count -eq 0)
    }
}
function Assert-Reflowed([string]$label, [string]$text, $fx) {
    $v = Test-Reflowed $text $fx
    Assert "$label the wrapped paragraph comes back as ONE line with no margin" $v.Paragraph
    Assert "$label the URL broken across rows comes back whole" $v.Url
    Assert "$label the code block keeps its own indentation (4 columns past the margin)" $v.Code
    Assert "$label no line keeps the TUI's 2-column margin" $v.NoMargin
    if (-not ($v.Paragraph -and $v.Url -and $v.Code -and $v.NoMargin)) {
        "      (clipboard, $(@(Get-Lines $text).Count) lines:)"
        Get-Lines $text | Select-Object -First 16 | ForEach-Object { "      | $_" }
    }
}

function Wait-Fixture([string]$json) {
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $json) {
            try { return (Get-Content $json -Raw | ConvertFrom-Json) } catch { }
        }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Start-Gui([string]$label, [string[]]$extraArgs) {
    # A previous launch is killed on purpose here; say so, or the harness's
    # postmortem reports that kill as a crash at teardown.
    foreach ($r in (Get-TestLaunchRecords)) { $r.Killed = $true }
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)
    $json = Join-Path $root "fixture-$label.json"
    Remove-Item $json -ErrorAction SilentlyContinue
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $probe -Out $json"
    $argList = @('--config-default-files=false', '--session-persistence=false', "--command=$cmd") + $extraArgs
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $argList
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { throw "($label) top window not found" }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { throw "($label) terminal pane not found" }
    Assert "($label) the window is NOT enumerable on the interactive desktop" `
        (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    [void](Focus-TestWindow -Window $top -Child $pane)
    $fx = Wait-Fixture $json
    if ($null -eq $fx) { throw "($label) the stand-in TUI never reported its fixture" }
    $listJson = & $Exe +list --json | Out-String
    $paneName = $null
    if ($listJson -match '"name"\s*:\s*"([^"]+)"') { $paneName = $Matches[1] }
    # The fixture is drawn when its last row reads back from the pane.
    $lastRow = $fx.screen[$fx.screen.Count - 1].Trim()
    $drawn = $false
    for ($t = 0; $t -lt 40 -and -not $drawn; $t++) {
        Start-Sleep -Milliseconds 250
        $raw = (& $Exe +read --name=$paneName --lines=60 2>$null | Out-String)
        if ($raw -match [regex]::Escape($lastRow)) { $drawn = $true }
    }
    Assert "($label) the stand-in TUI drew its fixture ($($fx.cols) cols, VT mode=$($fx.vt))" $drawn
    if (-not $drawn) { throw "($label) fixture never appeared in the pane" }
    [pscustomobject]@{ App = $app; Pid = [int]$app.Pid; Top = $top; Pane = $pane; PaneName = $paneName; Fx = $fx }
}

# Screen point of a cell, from the pane's client rect and the console size the
# TUI measured. Padding makes this approximate; the cells probed sit near the
# top-left, where the error is a fraction of a cell.
function Get-CellPoint($g, [int]$col, [int]$row) {
    $r = Get-TestWindowRect -Window $g.Pane -Client
    $cw = ($r.Right - $r.Left) / [double]$g.Fx.cols
    $ch = ($r.Bottom - $r.Top) / [double]$g.Fx.rows
    return @([int]($r.Left + ($col + 0.5) * $cw), [int]($r.Top + ($row + 0.5) * $ch))
}

function Select-All($g) {
    [void](Send-TestKeys -Window $g.Top -Target $g.Pane -Modifiers ctrl, shift -Key A)
    Start-Sleep -Milliseconds 400
}

# Copy through one route: sentinel the clipboard, select all, fire the route,
# read back what landed.
function Copy-Via($g, [string]$sentinel, [scriptblock]$route) {
    [void](Set-ClipText $sentinel)
    Select-All $g
    # The route's own assertion lines go to the host: anything it emitted on
    # the pipeline would otherwise become part of this function's return.
    & $route | ForEach-Object { Write-Host $_ }
    return (Wait-ClipChange $sentinel)
}

# ============================================================================
'== setup'
# ============================================================================
Assert 'ghoztty.exe exists in zig-out' (Test-Path $Exe)
Assert-GhozttyIsolatedBuild -Exe $Exe
[void](Set-GhozttyTestIsolation -Tag 'tuicopy')
[void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)
Assert-GhozttyPrivateEndpoint -Exe $Exe

$savedClip = Get-ClipText
Start-TestForegroundWatch
$td = New-TestDesktop
$script:launched = @()

try {
    $g = Start-Gui 'routes' @()
    Assert-GhozttyIsolated -Exe $Exe
    $fx = $g.Fx
    Assert "the fixture really is hard-wrapped: $($fx.paraRows.Count) paragraph rows, URL over 2 rows" `
        ($fx.paraRows.Count -ge 3 -and $fx.urlRows.Count -eq 2)

    # ========================================================================
    '== A: ctrl+shift+c'
    # ========================================================================
    $clip = Copy-Via $g 't1799-sentinel-A' {
        [void](Send-TestKeys -Window $g.Top -Target $g.Pane -Modifiers ctrl, shift -Key C)
    }
    Assert 'A: ctrl+shift+c copied something' ($null -ne $clip)
    Assert-Reflowed 'A:' $clip $fx

    # ========================================================================
    '== B: ctrl+c with a selection'
    # ========================================================================
    $clip = Copy-Via $g 't1799-sentinel-B' {
        [void](Send-TestKeys -Window $g.Top -Target $g.Pane -Modifiers ctrl -Key C)
    }
    Assert 'B: ctrl+c with a selection copied something' ($null -ne $clip)
    Assert-Reflowed 'B:' $clip $fx

    # ========================================================================
    '== C: ctrl+insert'
    # ========================================================================
    $clip = Copy-Via $g 't1799-sentinel-C' {
        [void](Send-TestKeys -Window $g.Top -Target $g.Pane -Modifiers ctrl -Key insert)
    }
    Assert 'C: ctrl+insert copied something' ($null -ne $clip)
    Assert-Reflowed 'C:' $clip $fx

    # ========================================================================
    '== D: context menu > Copy'
    # ========================================================================
    # Right-click INSIDE the selection keeps it (a click outside would select
    # the clicked word instead). Copy is the menu's first item: Down, Enter.
    $clip = Copy-Via $g 't1799-sentinel-D' {
        $pt = Get-CellPoint $g 4 0
        [void](Send-TestMouse -Window $g.Top -Target $g.Pane -X $pt[0] -Y $pt[1] -Button right -Action down)
        $menu = Wait-TestPopupMenu -ProcessId $g.Pid -TimeoutMs 3000
        Assert 'D: right-click opened the context menu' ($menu -ne [IntPtr]::Zero)
        if ($menu -ne [IntPtr]::Zero) {
            [void](Send-TestControlKey -Control $g.Pane -Key down)
            Start-Sleep -Milliseconds 150
            [void](Send-TestControlKey -Control $g.Pane -Key enter)
        }
        [void](Send-TestMouse -Window $g.Top -Target $g.Pane -X $pt[0] -Y $pt[1] -Button right -Action up)
    }
    Assert 'D: the menu Copy copied something' ($null -ne $clip)
    Assert-Reflowed 'D:' $clip $fx
    [void](Invoke-TestMessage -Window $g.Pane -Message 0x001F) # WM_CANCELMODE, in case

    # ========================================================================
    '== F: ctrl-hover over the broken URL shows it whole'
    # ========================================================================
    # Clear the selection first (a plain click), so the hover is about links.
    $pt = Get-CellPoint $g ($fx.cols - 2) ($fx.rows - 2)
    [void](Send-TestMouse -Window $g.Top -Target $g.Pane -X $pt[0] -Y $pt[1] -Button left -Action click)
    Start-Sleep -Milliseconds 300
    foreach ($arm in @(@{ Name = 'F1 (first URL row)'; Row = $fx.urlRow }, @{ Name = 'F2 (continuation row)'; Row = $fx.urlRow + 1 })) {
        $pt = Get-CellPoint $g ($fx.margin + 4) $arm.Row
        [void](Send-TestMouse -Window $g.Top -Target $g.Pane -X $pt[0] -Y $pt[1] -Action move -Modifiers ctrl)
        $bubbleText = $null
        for ($t = 0; $t -lt 20 -and $null -eq $bubbleText; $t++) {
            Start-Sleep -Milliseconds 150
            $b = @(Get-TestWindows -ProcessId $g.Pid -Class '*' | Where-Object { $_.Class -eq 'Static' -and $_.Visible })
            foreach ($w in $b) {
                $s = Get-TestControlText -Control ([IntPtr]$w.Hwnd)
                if ($s -match '^https?://') { $bubbleText = $s }
            }
        }
        Assert "$($arm.Name): ctrl-hover shows a link bubble" ($null -ne $bubbleText)
        Assert "$($arm.Name): the bubble names the WHOLE URL, across the TUI's row break (got $($bubbleText.Length) of $($fx.url.Length) chars)" `
            ($bubbleText -ceq $fx.url)
        # Move off the link so the next arm starts from no hover.
        $pt = Get-CellPoint $g ($fx.cols - 2) ($fx.rows - 2)
        [void](Send-TestMouse -Window $g.Top -Target $g.Pane -X $pt[0] -Y $pt[1] -Action move)
        Start-Sleep -Milliseconds 300
    }

    # ========================================================================
    '== G: +read stays raw (and the reflow oracle rejects raw text)'
    # ========================================================================
    $raw = (& $Exe +read "--name=$($g.PaneName)" --lines=60 2>$null | Out-String)
    $rawLines = @(Get-Lines $raw)
    Assert 'G1 +read keeps the TUI margin on the first paragraph row' ($rawLines -ccontains ('  ' + $fx.paraRows[0]))
    Assert 'G2 +read keeps the TUI row break inside the paragraph' ($rawLines -ccontains ('  ' + $fx.paraRows[1]))
    Assert 'G3 +read keeps the URL split across its two rows' `
        (($rawLines -ccontains ('  ' + $fx.urlRows[0])) -and ($rawLines -ccontains ('  ' + $fx.urlRows[1])))
    if (-not ($rawLines -ccontains ('  ' + $fx.paraRows[1]))) {
        "      (+read, $($rawLines.Count) lines:)"
        $rawLines | Select-Object -First 14 | ForEach-Object { "      |$_|" }
    }
    $v = Test-Reflowed $raw $fx
    Assert 'G4 the reflow oracle REJECTS the raw text (paragraph, URL and margin checks all fail)' `
        ((-not $v.Paragraph) -and (-not $v.Url) -and (-not $v.NoMargin))

    $script:launched += @(Get-TestLaunchedPids)

    # ========================================================================
    '== E: copy-on-select'
    # ========================================================================
    # Its own launch: with copy-on-select on, every selection above would have
    # written the clipboard before the route under test did.
    $g2 = Start-Gui 'copyonselect' @('--copy-on-select=clipboard')
    [void](Set-ClipText 't1799-sentinel-E')
    Select-All $g2
    $clip = Wait-ClipChange 't1799-sentinel-E'
    Assert 'E: selecting copied something (copy-on-select = clipboard)' ($null -ne $clip)
    Assert-Reflowed 'E:' $clip $g2.Fx

    Assert 'no crash at end of run' (-not ($g2.App.Process -and $g2.App.Process.HasExited))
    # The last statement of the body: a throw above unwinds past it, and the
    # verdict below then cannot read green (lib\TestScore.ps1).
    Complete-TestBody
} finally {
    $script:launched += @(Get-TestLaunchedPids)
    Remove-TestDesktop | Out-Null
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)
    if ($null -ne $savedClip -and $savedClip -ne '') { [void](Set-ClipText $savedClip) }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Assert 'the foreground watcher actually sampled (negative control)' ($fgSeen.Count -gt 0)
$leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
Assert 'no test-desktop app ever became foreground on the interactive desktop' ($leaked.Count -eq 0)

if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard tui-copy-reflow -Repo $repo 2>&1 | ForEach-Object { "  $($_.ToString())" }
}

Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped ([int]$script:skipped)
