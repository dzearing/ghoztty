# T648 acceptance: the feedback composer's offsets with NON-ASCII text in it.
#
# The defect this pins: every pure module behind the composer works in BYTES
# into the pane's UTF-8 buffer, and every edit message works in UTF-16 CODE
# UNITS. Those are the same number only for ASCII -- `e-acute` is 2 bytes and 1
# unit, an emoji is 4 bytes and 2 units -- so a composer holding any
# non-English text handed the control an offset short by the accumulated
# difference. Typing plain English never sees it, which is why it shipped.
#
# What is asserted:
#
#   A. The composer takes non-ASCII typing at all, surrogate pair included.
#      Everything below is a claim about offsets, so the text has to be the
#      text before any of it means anything.
#   B. A pasted image's chip lands EXACTLY at the caret. The caret is parked
#      mid-text, right after a space, so the correct answer carries no leading
#      space -- and the same number read as a byte offset lands inside a
#      multi-byte character, where the byte before is not a space and one would
#      be added. The whole composer text is compared, so the double space is a
#      FAIL. Every arm here compares the WHOLE text for that reason: a
#      substring needle is exactly what let a corrupted `[Imag` pass once.
#   C. The caret ends up past the chip that was just inserted, at the position
#      the insertion computed -- not 4 units past it, which is where a byte
#      offset seeded back into the page as a caret would put it.
#   D. Backspace against a chip that follows non-ASCII text still removes the
#      WHOLE chip. The chip is only a chip if the host's seed named its span
#      in the right UTF-16 units; a span that missed leaves plain text, one
#      Backspace deletes one character, and `[Image #1` is left behind -- text
#      that still looks attached and no longer parses, i.e. a picture silently
#      dropped from the report.
#   E. The report the send publishes carries the non-ASCII body intact.
#
# The quote half of the same bug is asserted in the win32 lane instead
# (`ViewerPane.zig`, the T641 quote block).
#
# ORACLES. This runs on the BACKGROUND test desktop, where CopyFromScreen and
# SendInput are dead (T233). What stands in, and all of it is the real thing:
# the web composer's own document and caret, read over the DevTools protocol
# (lib\WebViewCdp.ps1), the pane's stderr, and the report folder on disk.
#
# T1710: this drives the WEB composer users actually get, not the hidden
# RichEdit fallback. The arithmetic it pins lives on the web surface too: the
# page reports its caret in UTF-16 code units, the host converts it against its
# UTF-8 buffer to decide where a pasted picture's chip goes, and seeds the
# document back with the caret and the chip spans in UTF-16 again. Typing,
# caret placement and Backspace go to the page; pictures go in through the
# page's own paste listener (Send-CdpComposerImage); the send is the Ctrl+Enter
# chord the web surface posts to the band. `-BreakUtf16` runs the same arms
# against GHOZTTY_TEST_BREAK_UTF16=1 (the pre-T648 identity conversion) and
# expects them RED - the proof that the re-pointed arms still have teeth.
#
# THIS FILE IS ASCII ONLY (PowerShell 5.1 reads a BOM-less UTF-8 script as
# ANSI). Every non-ASCII character below is built from its code point.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-feedback-utf16.ps1
param(
    [string]$ExePath,
    [switch]$Interactive,
    [switch]$BreakUtf16
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-fbu16$PID"

# The run PROVES it got the web surface (lib\ComposerSurface.ps1), and drives
# that page over one DevTools port armed before the launch (T1710).
. (Join-Path $PSScriptRoot 'lib\ComposerSurface.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
. (Join-Path $PSScriptRoot 'lib\WebViewCdp.ps1')

# The teeth check: read by the app once, at the first composer's creation.
if ($BreakUtf16) { $env:GHOZTTY_TEST_BREAK_UTF16 = '1' }
else { Remove-Item Env:\GHOZTTY_TEST_BREAK_UTF16 -ErrorAction SilentlyContinue }

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# Text is compared and printed as ESCAPED code points: a console that cannot
# render an emoji would otherwise turn a real difference into an unreadable one,
# and a mismatch nobody can read is a mismatch nobody can fix. Shared with the
# other composer suites since T672.
. (Join-Path $PSScriptRoot 'lib\ShowText.ps1')

Add-Type -AssemblyName System.Drawing

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Park the page's caret, then give its `selectionchange` snapshot the hop to
# the host: a paste inserts at the caret the HOST last heard about.
function Set-Caret($cdp, [int]$At) {
    Set-CdpComposerCaret -Conn $cdp -At $At
    Start-Sleep -Milliseconds 300
}

# Wait for the page's caret to read `$Want`, and return what it last read.
function Wait-Caret($cdp, [int]$Want) {
    $got = -1
    for ($t = 0; $t -lt 30; $t++) {
        $got = Get-CdpComposerCaret $cdp
        if ($got -eq $Want) { break }
        Start-Sleep -Milliseconds 100
    }
    return $got
}

# A chord NATIVE owns, delivered the way the web surface delivers it: the
# controller's accelerator handler posts WM_APP_COMPOSER_CHORD (WM_APP+2) to
# the band, virtual key in wParam and input.Mods bits in lParam (ctrl=2).
$script:ChordMsg = 0x8002
$script:ModCtrl = 2
function Send-ComposerChord($band, [int]$Vk, [int]$Mods = 0) {
    return (Send-TestRawMessage -Window $band -Message $script:ChordMsg `
            -WParam ([IntPtr]$Vk) -LParam ([IntPtr]$Mods))
}

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-OnlyPaneId($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0].id
}

function Get-ViewerHost($appPid) {
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
            return [pscustomobject]@{ Top = [IntPtr]$top.Hwnd; Pane = [IntPtr]$h.Hwnd }
        }
    }
    return $null
}

function Get-ChromeChild($paneHwnd, [string]$Class) {
    $c = @(Get-TestChildWindows -Window $paneHwnd -Class $Class)
    if ($c.Count -lt 1) { return $null }
    return [IntPtr]$c[0].Hwnd
}

function Wait-WorktreeShown($errlog, $paneId) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
            if ($line -match "viewer worktree pane=$([regex]::Escape($paneId)) feedback=(\w+)") {
                if ($Matches[1] -eq 'shown') { return $true }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-FeedbackState($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) open=(\w+) bar_h=(\d+)") {
            $hit = [pscustomobject]@{ Open = ($Matches[1] -eq 'true'); BarH = [int]$Matches[2] }
        }
    }
    return $hit
}

function Wait-FeedbackState($errlog, $paneId, [bool]$Open) {
    for ($t = 0; $t -lt 40; $t++) {
        $s = Get-FeedbackState $errlog $paneId
        if ($s -and $s.Open -eq $Open) { return $s }
        Start-Sleep -Milliseconds 250
    }
    return (Get-FeedbackState $errlog $paneId)
}

function Get-LastImage($errlog, $paneId) {
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer feedback pane=$([regex]::Escape($paneId)) image=#(\d+) bytes=(\d+) live=(\d+)") {
            $hit = [pscustomobject]@{
                Number = [int]$Matches[1]
                Bytes  = [int]$Matches[2]
                Live   = [int]$Matches[3]
            }
        }
    }
    return $hit
}

function Wait-Image($errlog, $paneId, [int]$Number) {
    for ($t = 0; $t -lt 40; $t++) {
        $i = Get-LastImage $errlog $paneId
        if ($i -and $i.Number -eq $Number) { return $i }
        Start-Sleep -Milliseconds 250
    }
    return (Get-LastImage $errlog $paneId)
}

function Invoke-FeedbackButton($view) {
    [void](Send-TestRawMessage -Window $view.Pane -Message 0x8016)
    Start-Sleep -Milliseconds 600
    $nb = Get-ChromeChild $view.Pane 'GhozttyViewerNav'
    if (-not $nb) { return $false }
    $rect = Get-TestWindowRect $nb
    if (-not $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { return $false }
    $scale = $rect.Height / 36.0
    $x = [int]($rect.Right - [Math]::Round(18 * $scale))
    $y = [int]($rect.Top + $rect.Height / 2)
    return (Send-TestMouse -Window $view.Top -Target $nb -X $x -Y $y)
}

function New-TestBitmap([int]$W, [int]$H, [int]$Seed) {
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            $c = [System.Drawing.Color]::FromArgb(
                255,
                ($x * 7 + $Seed) % 256,
                ($y * 11 + $Seed) % 256,
                (($x + $y) * 3 + $Seed) % 256)
            $bmp.SetPixel($x, $y, $c)
        }
    }
    return $bmp
}

# Paste a PNG at the page's caret (-KeepCaret: the caret was parked on
# purpose) and return the exact bytes. The OS clipboard is no route in
# off-desktop; the page's own paste listener is (lib\WebViewCdp.ps1).
function Send-Png($cdp, [int]$W, [int]$H, [int]$Seed) {
    $bmp = New-TestBitmap $W $H $Seed
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $bytes = $ms.ToArray()
    Send-CdpComposerImage -Conn $cdp -Bytes $bytes -KeepCaret
    # The unary comma keeps this a byte[] rather than unrolling it.
    return , $bytes
}

# --- the fixture text --------------------------------------------------------
# `eee<sp><emoji><sp>YZ`, built from code points so this file stays ASCII.
#
#   9 UTF-16 code units:  e e e _ [hi lo] _ Y Z
#  14 UTF-8 bytes:        2 2 2 1  4       1 1 1
#
# The caret goes to unit 4 -- just past the space, right before the emoji --
# and that position is byte 7. The two numbers have to disagree ABOUT THE TEXT
# AROUND THEM for anything to be observable, which is what picking this one
# buys: byte 7 follows a space, so the chip needs no leading space of its own;
# byte 4 (unit 4 read as an offset) lands inside the third `e-acute`, where the
# preceding byte is not a space and one WOULD be added. Most other positions in
# this string happen to have a break on both sides and would agree by accident.
$EA = [char]0x00E9                                  # LATIN SMALL LETTER E WITH ACUTE
$EMOJI = [string][char]::ConvertFromUtf32(0x1F600)  # GRINNING FACE (a surrogate pair)
$seed = ($EA.ToString() * 3) + ' ' + $EMOJI + ' ' + 'YZ'
$caretUnit = 4
$chip = '[Image #1]'

# --- a THROWAWAY working tree, not this repo ---------------------------------
$work = Join-Path $env:TEMP ("ghoztty-fbu16-accept-" + $PID)
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Content -Path (Join-Path $work 'README.md') -Encoding utf8 -Value @(
    '# Throwaway',
    '',
    'a paragraph in the throwaway repo',
    ''
)
& git -C $work init --initial-branch=main *> $null
& git -C $work add -A *> $null
& git -C $work -c user.name='ghoztty test' -c user.email='test@ghoztty' commit -m 'throwaway' *> $null
$workRoot = (& git -C $work rev-parse --show-toplevel 2>$null | Out-String).Trim().Replace('/', '\')
if (-not $workRoot) { Write-Host "SETUP FAIL: could not make a throwaway repo at $work"; exit 1 }
$queueDir = Join-Path $work 'temp\feedback\new'
$viewFile = Join-Path $work 'README.md'

Stop-RepoInstances
$script:cdpPort = Enable-WebViewCdp
$cdp = $null
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-feedback-utf16-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    $r = Invoke-Verb @('+new-window', '--target=u16win', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file in repo> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'u16win')) 'the viewer window exists'
    $paneId = Get-OnlyPaneId 'u16win'
    Assert ($null -ne $paneId) "the viewer window has exactly one pane (id '$paneId')"
    Assert (Wait-WorktreeShown $errlog $paneId) 'the pane resolved a worktree, so it can file a report'

    $view = $null
    for ($t = 0; $t -lt 20; $t++) {
        $view = Get-ViewerHost $appPid
        if ($view) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $view) 'the viewer host window was found'
    if (-not $view) { throw 'no viewer host window' }

    Assert (Invoke-FeedbackButton $view) 'the revealed nav bar took a click at the feedback button'
    $s = Wait-FeedbackState $errlog $paneId $true
    Assert ($s -and $s.Open) "the pane reports the composer OPEN (state '$($s.Open)')"
    Assert (Wait-ComposerSurface $errlog 'web') `
        "...on the web surface users get (got '$(Get-ComposerSurface $errlog)')"

    $fb = $null
    for ($t = 0; $t -lt 20; $t++) {
        $fb = Get-ChromeChild $view.Pane 'GhozttyViewerFeedback'
        if ($fb) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $fb) 'a GhozttyViewerFeedback child window exists'
    if (-not $fb) { throw 'no composer window' }

    try { $cdp = Find-CdpComposer -Port $script:cdpPort } catch { Write-Host "  $($_.Exception.Message)" }
    Assert ($null -ne $cdp) "the composer's page answers on the DevTools port"
    if (-not $cdp) { throw 'no composer page to drive' }

    # --- A. the composer takes non-ASCII typing ------------------------------
    Send-CdpComposerText $cdp $seed
    $typed = (Wait-CdpComposerText $cdp $seed)
    Assert ($typed -ceq $seed) `
        ("the composer holds the typed non-ASCII text, emoji included " +
         "(got '$(Show-Text $typed)', want '$(Show-Text $seed)')")
    Assert ($typed.Length -eq 9) `
        "...which is 9 UTF-16 code units and 14 UTF-8 bytes (got $($typed.Length) units)"
    $at = Wait-Caret $cdp 9
    Assert ($at -eq 9) "...with the page's caret after it, at unit 9 (got $at)"

    # --- B. a chip lands exactly at the caret --------------------------------
    Set-Caret $cdp $caretUnit
    $at = Get-CdpComposerCaret $cdp
    Assert ($at -eq $caretUnit) "the caret is parked at unit $caretUnit, just before the emoji (got $at)"

    $png1 = Send-Png $cdp 40 30 17
    $img = Wait-Image $errlog $paneId 1
    Assert ($img -and $img.Number -eq 1) "the paste is taken as image #1 (got '$($img.Number)')"
    Assert ($img -and $img.Bytes -eq $png1.Length) `
        "...verbatim, byte for byte ($($img.Bytes) vs $($png1.Length))"

    # The correct insertion carries NO leading space -- the caret sits right
    # after one -- and a trailing space, because the emoji follows. An
    # unconverted offset lands inside the third `e-acute`, sees a non-space byte
    # behind it, and adds a second space. The host seeds the result back into
    # the page, so the page's document IS the host's answer.
    $wantB = ($EA.ToString() * 3) + ' ' + $chip + ' ' + $EMOJI + ' ' + 'YZ'
    $afterPaste = (Wait-CdpComposerText $cdp $wantB)
    Assert ($afterPaste -ceq $wantB) `
        ("the chip lands EXACTLY at the caret, with no doubled space " +
         "(got '$(Show-Text $afterPaste)', want '$(Show-Text $wantB)')")

    # --- C. the caret ends past the chip it just inserted --------------------
    # The seed carries the caret back in UTF-16 units; a byte offset handed
    # across would put it 4 units further on.
    $wantCaret = $wantB.IndexOf($chip) + $chip.Length + 1   # past the chip and its trailing space
    $at = Wait-Caret $cdp $wantCaret
    Assert ($at -eq $wantCaret) `
        "the caret is left just past the inserted run, at unit $wantCaret (got $at)"

    # --- D. Backspace takes the WHOLE chip -----------------------------------
    # The caret goes to the chip's closing bracket, which is where a user
    # clicking at the end of a chip puts it.
    $chipEnd = $wantB.IndexOf($chip) + $chip.Length
    $parked = $true
    try { Set-Caret $cdp $chipEnd } catch { $parked = $false; Write-Host "  $($_.Exception.Message)" }
    $at = Get-CdpComposerCaret $cdp
    Assert ($parked -and $at -eq $chipEnd) `
        "the caret is at the chip's closing bracket, unit $chipEnd (got $at)"

    Send-CdpKey $cdp Backspace
    # Compared WHOLE, not by "no `[Image` left": a chip that was only partly
    # deleted leaves `[Imag`, which does not match that needle either while
    # being exactly the corruption this arm exists to catch.
    $wantD = ($EA.ToString() * 3) + '  ' + $EMOJI + ' ' + 'YZ'
    $afterDelete = (Wait-CdpComposerText $cdp $wantD)
    Assert ($afterDelete -ceq $wantD) `
        ("one Backspace removes the WHOLE chip after non-ASCII text, leaving no " +
         "fragment (got '$(Show-Text $afterDelete)', want '$(Show-Text $wantD)')")

    # --- E. the report carries the non-ASCII body ----------------------------
    # A second picture goes in first, so the send has an image to write as well
    # as the words -- the chip numbering is stable, so this one is #2.
    Set-Caret $cdp $afterDelete.Length
    $png2 = Send-Png $cdp 20 12 91
    $img = Wait-Image $errlog $paneId 2
    Assert ($img -and $img.Number -eq 2) "a second paste is #2 (got '$($img.Number)')"
    $wantE = $wantD + ' ' + '[Image #2]'
    $text = (Wait-CdpComposerText $cdp $wantE)
    Assert ($text.StartsWith($wantE)) `
        ("...and its chip follows the text (got '$(Show-Text $text)', want '$(Show-Text $wantE)')")

    # The page reports its snapshot to the host on `input`; give that message
    # its hop before the send reads the host's copy.
    Start-Sleep -Milliseconds 300
    [void](Send-ComposerChord $fb 0x0D $script:ModCtrl)
    $folder = $null
    for ($t = 0; $t -lt 40; $t++) {
        $dirs = @(Get-ChildItem $queueDir -Directory -ErrorAction SilentlyContinue)
        if ($dirs.Count -ge 1) { $folder = $dirs[0].FullName; break }
        Start-Sleep -Milliseconds 250
    }
    Assert ($null -ne $folder) "the send published a report folder into $queueDir"
    if ($folder) {
        $report = Get-Content (Join-Path $folder 'report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($report.body.Contains($EA.ToString() * 3)) `
            "report.json's body carries the accented text (holds '$(Show-Text $report.body)')"
        Assert ($report.body.Contains($EMOJI)) '...and the emoji, unmangled'
        Assert ($report.body -match '!\[Image #2\]\(images/image-2\.png\)') `
            '...and links the surviving picture'
        Assert ($report.body -notmatch 'Image #1') `
            '...with the deleted chip nowhere in it'
        Assert (Test-Path (Join-Path $folder 'images\image-2.png')) 'the folder holds images/image-2.png'
        Assert (-not (Test-Path (Join-Path $folder 'images\image-1.png'))) `
            'the deleted chip left no file behind'
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Close-Cdp $cdp
    Disable-WebViewCdp
    Remove-Item Env:\GHOZTTY_TEST_BREAK_UTF16 -ErrorAction SilentlyContinue
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
