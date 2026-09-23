# Viewer contents-card SELECTION EMPHASIS acceptance (T729).
#
# THE CONTRACT, translated from Mac's key-window rule into Windows 11's list
# language (T930). The contents card beside a viewer document marks the section
# you are on. While the viewer's window is the ACTIVE one, that mark is a quiet
# NEUTRAL fill plus a small accent indicator bar at the row's leading edge - the
# chooser's selection (T828), never Mac's solid accent pill. The moment
# activation moves to another window, it drops to a lighter neutral wash with a
# neutral bar. The selection never disappears with the emphasis - the fill and
# the bar are the state, and weight is the emphasis - which is the half a "just
# always paint accent" build and a "just never paint accent" build each get
# wrong in opposite directions.
#
# WHY THIS SCRIPT EXISTS. The gate is `ViewerTOCPanel.isEmphasized()`, which
# T215 rewrote off `GetForegroundWindow` (null for every window on a background
# desktop, so the card painted unemphasized there forever) onto
# `w32.windowIsActive`. That fix is what made the contract measurable HERE at
# all. What has been measured since is one half of it: `chrome-theme.ps1`
# section F pins the viewer window active on purpose and asserts the accent is
# on the card, because its subject is the accent CACHE. Nothing asserts the
# other half, and a build that painted the pill accent unconditionally would
# score green on every assertion that exists today - which is exactly the shape
# the T211 audit warned would be "fixed" by weakening the test.
#
# WHAT IS MEASURED:
#
#   A. with the viewer window ACTIVE, the card carries the user's accent as a
#      narrow indicator BAR (not a filled pill) over the neutral focused wash,
#      and the card's own fill is sampled here so the washes are derived off a
#      measured colour rather than a pasted one;
#   B. with activation moved to a SECOND ghoztty window - the real gesture,
#      rather than deactivating everything - the accent is GONE from the card,
#      the derived unemphasized wash (`color_math.wash(card_fill, 0.10)`, which
#      ColorMath spells `Get-Wash`) IS on it, and that wash is NEUTRAL ink;
#   C. the two fills are two different weights, and activating the viewer
#      again brings the accent bar back - so the row is reading activation live
#      rather than having painted once at open.
#
# THE ORACLES work over a `-Sync` capture of the card. The washes are solid
# rounded fills, so they are exact colour matches. The accent is NOT: it reaches
# the bar through two contrast floors, so its RGB depends on the card it sits on.
# It is found by SHAPE instead (`Find-SaturatedBar`): a solid vertical run of one
# saturated colour, ten or more pixels tall. A plain chroma scan would score the
# font renderer - the labels' subpixel fringes are as saturated as any accent -
# but no fringe is a ten-pixel solid run of one colour.
#
# THE ACCENT IS SET, not read. A box whose accent happens to sit near the
# unemphasized grey would make every assertion here vacuous, and that is not a
# thing to discover from a green run. The user's value is restored in the
# `finally`, the way `chrome-theme.ps1` restores it.
#
#   powershell -NoProfile -File test\win32\viewer-toc-emphasis.ps1
#
# -NegativeControl inverts the four PAIR assertions (A's accent-present, B's
# accent-absent, B's wash-present, C's accent-returns), so a correct build
# fails all four. Anything other than four failures means the pair is not what
# is being measured.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers. Dot-sourced HERE, ahead of any isolation
# setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a test never wants
# the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vtoce$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ColorMath.ps1')
# T930: the selection indicator bar, found by shape (shared with chrome-theme.ps1).
. (Join-Path $PSScriptRoot 'lib\SelectionBar.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass, and the
# guard-stamping child below reads the same state and refuses to write.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# T1127: everything running out of this build's directory is reaped when this
# PowerShell exits, including a detached `--pty-host` holder.
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
# The four pair assertions, and the only ones -NegativeControl inverts.
function Assert-Pair([bool]$cond, [string]$label) {
    if ($NegativeControl) { Assert (-not $cond) "$label (INVERTED)" }
    else { Assert $cond $label }
}

# The two selection weights, by their Zig names (`list_selection.
# selection_wash_focused` / `selection_wash_unfocused`, T930 - the card speaks
# the chooser's selection language). DERIVED from the sampled card fill, never
# pasted as colours: move a weight in the Zig and this script moves with it.
$EMPHASIZED_WASH = 0.16
$UNEMPHASIZED_WASH = 0.10

# A deliberately saturated accent nothing on the card derives by accident, and
# far from any grey the wash could land on.
$TEST_ACCENT = @(0xD0, 0x2B, 0x8A)

# ---------------------------------------------------------------------------
# Accent registry. ABGR DWORD, the encoding `chrome_theme.accentFromDword`
# decodes - the same helpers chrome-theme.ps1 carries, and the same reason for
# the byte round-trip: PS5.1 surfaces a REG_DWORD with the top bit set as a
# value that does not fit Int32, so `[int]` on the way out throws and the
# restore in the `finally` never runs.
# ---------------------------------------------------------------------------
$DWM_KEY = 'HKCU:\Software\Microsoft\Windows\DWM'

function Get-AccentRaw {
    $p = Get-ItemProperty -Path $DWM_KEY -Name AccentColor -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$p.AccentColor), 0)
}
function ConvertTo-AccentDword([int[]]$Rgb) {
    # Assembled as BYTES: PS5.1 parses `0xFF000000` as an Int32, so a shift
    # would throw before it ran. x86 is little-endian, so laying R,G,B,FF down
    # IS the 0xAABBGGRR DWORD.
    $bytes = [byte[]]@($Rgb[0], $Rgb[1], $Rgb[2], 0xFF)
    return [BitConverter]::ToInt32($bytes, 0)
}
function Set-Accent([int[]]$Rgb) {
    Set-ItemProperty -Path $DWM_KEY -Name AccentColor -Value (ConvertTo-AccentDword $Rgb) -Type DWord
}
function Restore-Accent($Raw) {
    if ($null -eq $Raw) {
        Remove-ItemProperty -Path $DWM_KEY -Name AccentColor -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -Path $DWM_KEY -Name AccentColor -Value $Raw -Type DWord
    }
}

function Get-Chroma([int[]]$c) {
    return (($c | Measure-Object -Maximum).Maximum - ($c | Measure-Object -Minimum).Minimum)
}

# Does a bar colour read as the TEST accent's hue (red dominant, green least:
# #d02b8a), whatever lightness the contrast floors moved it to?
function Test-AccentHue([int[]]$c) {
    return ($c[0] -gt $c[2] -and $c[2] -gt $c[1] -and ($c[0] - $c[1]) -ge 48)
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

# Does this capture of the card hold the exact colour $Rgb anywhere?
function Test-CardHasColor($Shot, [int[]]$Rgb) {
    for ($y = 0; $y -lt $Shot.Height; $y++) {
        for ($x = 0; $x -lt $Shot.Width; $x++) {
            $c = $Shot.Bitmap.GetPixel($x, $y)
            if ($c.R -eq $Rgb[0] -and $c.G -eq $Rgb[1] -and $c.B -eq $Rgb[2]) { return $true }
        }
    }
    return $false
}

$originalAccent = Get-AccentRaw
[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$launched = @()
$td = $null
$app = $null

try {
    # Set before the GUI launches: `system_colors` caches the accent on first
    # read, so a value written afterwards would need a colorization broadcast
    # to land - which is chrome-theme.ps1's subject, not this script's.
    Set-Accent $TEST_ACCENT

    $td = New-TestDesktop -Interactive:$Interactive
    $errlog = Join-Path $env:TEMP "ghoztty-viewer-toc-emphasis-stderr-$PID.log"
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $launched += $script:GhozttyTestDesktopPids
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # A viewer whose pane is the whole window, on a document with headings so
    # the card has rows to select at all.
    $r = Invoke-Verb @('+new-window', '--target=tocemph',
        "--view=$(Join-Path $repo 'README.md')", "--working-directory=$repo")
    Assert ($r.Code -eq 0) "+new-window --view opened the viewer (exit $($r.Code))"
    Start-Sleep -Seconds 5

    $vtop = [IntPtr]::Zero
    foreach ($t in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
        if (@(Get-TestChildWindows -Window ([IntPtr]$t.Hwnd) -Class 'GhozttyViewer').Count -ge 1) {
            $vtop = [IntPtr]$t.Hwnd
        }
    }
    Assert ($vtop -ne [IntPtr]::Zero) 'the viewer window is up'
    if ($vtop -eq [IntPtr]::Zero) { Write-Host 'ABORT: no viewer window to score'; exit 1 }

    # Wide enough that `viewer_toc_layout.mode` picks `gutter`: the compact
    # layout hides the card behind the nav bar's contents button, and a card
    # nobody can see cannot be photographed.
    Set-TestWindowSize -Window $vtop -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Seconds 2

    $toc = [IntPtr]::Zero
    foreach ($v in @(Get-TestChildWindows -Window $vtop -Class 'GhozttyViewer')) {
        foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$v.Hwnd) -Class 'GhozttyViewerTOC')) {
            $toc = [IntPtr]$c.Hwnd
        }
    }
    Assert ($toc -ne [IntPtr]::Zero -and (Test-TestWindowVisible -Window $toc)) `
        'the contents card is a visible CHILD window (gutter layout)'
    if ($toc -eq [IntPtr]::Zero) { Write-Host 'ABORT: no contents card to score'; exit 1 }

    # A second window of our own, to move activation ONTO in section B. A
    # plain terminal window rather than a foreign one: what the contract is
    # about is which of OUR windows is key, and a foreign window would also
    # deactivate the app as a whole, which is a weaker question.
    $r = Invoke-Verb @('+new-window', '--target=tocother')
    Assert ($r.Code -eq 0) "+new-window opened a second window to activate (exit $($r.Code))"
    Start-Sleep -Seconds 2
    $other = [IntPtr]::Zero
    foreach ($t in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
        if ([IntPtr]$t.Hwnd -eq $vtop) { continue }
        if (@(Get-TestChildWindows -Window ([IntPtr]$t.Hwnd) -Class 'GhozttyViewer').Count -ge 1) { continue }
        $other = [IntPtr]$t.Hwnd
    }
    Assert ($other -ne [IntPtr]::Zero) 'the second (non-viewer) window is up'
    if ($other -eq [IntPtr]::Zero) { Write-Host 'ABORT: nothing to move activation to'; exit 1 }

    # =======================================================================
    # A. ACTIVE: neutral fill + accent indicator bar (T930)
    # =======================================================================
    Write-Host ''
    Write-Host 'A. with the viewer window active, the selected row is a neutral fill with an accent bar'
    Set-TestActiveWindow -Window $vtop | Out-Null
    Start-Sleep -Milliseconds 800
    Assert ((Get-TestActiveWindow -Window $vtop) -eq $vtop) `
        'A the viewer window is the ACTIVE window (the state this section measures)'

    $cardFill = $null
    $shotA = Get-TestWindowPixels -Window $toc -Sync
    try {
        $distinct = Get-TestDistinctColors -Shot $shotA
        Assert ($distinct -ge 8) "A the card capture holds real content ($distinct distinct colours)"
        # The card's own fill, MEASURED: it is derived from the document
        # background the page posts up, so pasting it here would be pinning a
        # number the app is free to move.
        $box = Measure-Box $shotA $shotA.Left $shotA.Top ($shotA.Left + $shotA.Width) `
            ($shotA.Top + $shotA.Height) 2
        Assert ($null -ne $box) 'A the card fill was sampled (the derivation below stands on it)'
        if ($box) {
            $cardFill = $box.Mode
            Write-Host "      card fill = $(Format-Rgb $cardFill) ($($box.ModeN) px, $($box.Distinct) distinct)"
        }
        # T930: the accent is a small BAR at the row's leading edge, not the
        # row's fill. The pair assertion is that the bar is there, in the
        # accent's hue; the plain one beside it is the defect T930 retired - a
        # solid accent pill is a saturated run as wide as the row.
        $barA = Find-SaturatedBar $shotA
        if ($barA) { Write-Host "      accent bar = $(Format-Rgb $barA.Rgb) ($($barA.HRun) px wide, $($barA.VRun) px tall)" }
        Assert-Pair ($null -ne $barA -and (Test-AccentHue $barA.Rgb)) `
            "A the selected row carries an indicator bar in the accent's hue (set $(Format-Rgb $TEST_ACCENT))"
        if ($barA) {
            Assert ($barA.HRun -le 12 -and $barA.VRun -gt $barA.HRun) `
                "A that accent mark is a narrow bar, not a filled pill ($($barA.HRun) px wide, $($barA.VRun) px tall)"
        }
        if ($cardFill) {
            $washA = Get-Wash $cardFill $EMPHASIZED_WASH
            Assert (Test-CardHasColor $shotA $washA) `
                "A the row's fill is the NEUTRAL focused wash $(Format-Rgb $washA), not an accent tint"
        }
    } finally { Close-TestWindowPixels -Shot $shotA }

    # =======================================================================
    # B. ACTIVATION ELSEWHERE: the lighter wash and a neutral bar
    # =======================================================================
    Write-Host ''
    Write-Host 'B. with activation on another window, the row drops to the lighter wash and no accent is left'
    Set-TestActiveWindow -Window $other | Out-Null
    Start-Sleep -Milliseconds 1200
    Assert ((Get-TestActiveWindow -Window $vtop) -eq $other) `
        'B activation moved to the other window (the state this section measures)'

    $wash = $null
    if ($cardFill) {
        $wash = Get-Wash $cardFill $UNEMPHASIZED_WASH
        Write-Host "      derived unemphasized wash = $(Format-Rgb $wash) (wash of the card fill at $UNEMPHASIZED_WASH)"
    }
    $shotB = Get-TestWindowPixels -Window $toc -Sync
    try {
        Assert ((Get-TestDistinctColors -Shot $shotB) -ge 8) `
            'B the card is still painting real content (positive control for the two assertions below)'
        $barB = Find-SaturatedBar $shotB
        if ($barB) { Write-Host "      saturated bar still present = $(Format-Rgb $barB.Rgb)" }
        Assert-Pair ($null -eq $barB -or -not (Test-AccentHue $barB.Rgb)) `
            'B the accent indicator is GONE from the card'
        # The selection did not vanish with its emphasis: the pill is still
        # drawn, in the lighter wash. This is the assertion a "never paint accent"
        # build passes and a "paint nothing" build does not.
        if ($wash) {
            Assert-Pair (Test-CardHasColor $shotB $wash) `
                "B the selected row is still marked, in the unemphasized wash $(Format-Rgb $wash)"
            Assert ((Get-Chroma $wash) -le 12) `
                "B that wash is NEUTRAL ink, not a second accent ($(Format-Rgb $wash), chroma $(Get-Chroma $wash))"
        }
    } finally { Close-TestWindowPixels -Shot $shotB }

    # =======================================================================
    # C. THE PAIR IS TWO STATES
    # =======================================================================
    Write-Host ''
    Write-Host 'C. the two treatments are genuinely two, and activation is read live'
    if ($cardFill -and $wash) {
        # A build that collapsed the two would pass every assertion above one
        # weight at a time.
        $washOn = Get-Wash $cardFill $EMPHASIZED_WASH
        Assert ((Get-ChannelDistance $wash $washOn) -ge 3) `
            "C the emphasized and unemphasized fills are different weights ($(Format-Rgb $washOn) vs $(Format-Rgb $wash))"
        # And the wash is a step off the card, not the card itself - otherwise
        # B's "still marked" assertion would be satisfied by the background.
        Assert ((Get-ChannelDistance $wash $cardFill) -ge 3) `
            "C the wash is a visible step off the card fill ($(Format-Rgb $wash) vs $(Format-Rgb $cardFill))"
    }

    Set-TestActiveWindow -Window $vtop | Out-Null
    Start-Sleep -Milliseconds 1200
    Assert ((Get-TestActiveWindow -Window $vtop) -eq $vtop) 'C activation came back to the viewer window'
    $shotC = Get-TestWindowPixels -Window $toc -Sync
    try {
        $barC = Find-SaturatedBar $shotC
        Assert-Pair ($null -ne $barC -and (Test-AccentHue $barC.Rgb)) `
            'C the accent bar is back on the card - the row reads activation live, it did not paint once at open'
    } finally { Close-TestWindowPixels -Shot $shotC }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI survived the whole run'
} catch {
    # T1511: the foreground-leak checks below are part of this run too, so this
    # try cannot END in `Complete-TestBody`. It SCORES its own throw instead.
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Restore-Accent $originalAccent
    if ($td) { Remove-TestDesktop }
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due. A negative-control run is red by construction, so it
# never stamps.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-toc-emphasis -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'viewer-toc-emphasis' -MinPass 12
