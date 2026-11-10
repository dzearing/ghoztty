# T154 acceptance: ctrl+v must PASTE when the clipboard holds text, and must
# FALL THROUGH to the pane (as a raw ^V) when it does not.
#
# T156 extends it to shift+insert (sections E/F): the generic non-darwin
# default bound shift+insert to paste_from_selection, which the win32 apprt
# can never satisfy (no selection clipboard), so the chord was swallowed
# outright - no paste, and the pane never saw the key. The Windows mirror
# block now re-binds it to paste_from_clipboard, performable.
#
# T522 extends it to ctrl+insert (sections G/H), the same defect on the COPY
# side: the generic non-darwin default binds it with a plain put(), and
# copy_to_clipboard declines when nothing is selected, so the chord was
# swallowed whole in that case - nothing copied, and the pane never saw the
# key. G is the no-selection fall-through; H is the control that a selection
# still copies.
#
# Why this matters: Claude Code (and other TUIs) read images off the system
# clipboard themselves when they receive ^V. Before T154 the Windows
# ctrl-mirror block bound ctrl+v with a plain put() and no `performable`
# flag, so ghoztty swallowed the chord unconditionally, pasted nothing (no
# CF_UNICODETEXT on an image-only clipboard) and the TUI never saw the key.
#
# Oracle: a tiny PowerShell probe runs INSIDE the pane and blocks on
# [Console]::ReadKey($true), then prints the character code it received.
# That distinguishes the three outcomes precisely:
#   text clipboard  + ctrl+v       -> probe sees the token's FIRST char (paste)
#   image clipboard + ctrl+v       -> probe sees 22 (0x16 = ^V, fall-through)
#   image clipboard + ctrl+shift+v -> probe sees 22 (already performable)
# A swallowed chord shows up as the probe never printing at all.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private ClipDrv driver (T86 GrabForeground + SendInput) is gone; the
# harness supplies the equivalents, and the app is launched ONTO the desktop
# instead of by Start-Process.
#
# The CLIPBOARD is unaffected by the move: it is scoped to the WINDOW STATION,
# and CreateDesktopW makes the test desktop inside this process's own
# WinSta0 - so the fixtures this script sets are the ones the app reads. That
# is also why this script still needs an STA host.
#
# Only touches ghoztty processes running from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\clipboard-paste.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$errlog = Join-Path $env:TEMP 'ghoztty-clipboard-paste-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue

# Isolate the IPC endpoint unconditionally: the app inherits this through
# CreateProcessW and so does every `& $Exe +...` below, so a run can never
# drive whatever instance happens to own the shared pipe.
$env:GHOZTTY_PIPE_SUFFIX = "-clippastetest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- clipboard helpers --------------------------------------------------------
# powershell.exe is STA by default, which System.Windows.Forms.Clipboard
# requires. Bail loudly rather than producing confusing failures if not.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'SETUP FAIL: run under an STA host (powershell.exe, not -MTA)'
    exit 1
}

function Set-TextClipboard([string]$text) {
    for ($t = 0; $t -lt 10; $t++) {
        try {
            [System.Windows.Forms.Clipboard]::Clear()
            if ($text -ne '') { [System.Windows.Forms.Clipboard]::SetText($text) }
            return $true
        } catch { Start-Sleep -Milliseconds 200 }
    }
    return $false
}

function Get-TextClipboard {
    for ($t = 0; $t -lt 10; $t++) {
        try {
            if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return '' }
            return [string][System.Windows.Forms.Clipboard]::GetText()
        } catch { Start-Sleep -Milliseconds 200 }
    }
    return ''
}

# An IMAGE with NO text format at all - this is the screenshot case that
# T154 is about (GetClipboardData(CF_UNICODETEXT) returns null).
function Set-ImageOnlyClipboard {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Red)
    $g.Dispose()
    try {
        for ($t = 0; $t -lt 10; $t++) {
            try {
                [System.Windows.Forms.Clipboard]::Clear()
                [System.Windows.Forms.Clipboard]::SetImage($bmp)
                return $true
            } catch { Start-Sleep -Milliseconds 200 }
        }
    } finally { $bmp.Dispose() }
    return $false
}

# --- the in-pane probe --------------------------------------------------------
# Blocks on ReadKey and prints the raw character code it received. Written
# to TEMP so no quoting has to survive +send-keys.
$probe = Join-Path $env:TEMP 'ghoztty-clip-probe.ps1'
@'
param([string]$Tag)
[Console]::Out.Write("PROBE_READY_" + $Tag + "`r`n")
$k = [Console]::ReadKey($true)
[Console]::Out.Write("PROBE_" + $Tag + "_CHAR=" + [int]$k.KeyChar + "`r`n")
'@ | Set-Content -Path $probe -Encoding ASCII

function Read-Tail([int]$lines = 20) {
    return (& $Exe +read --name=$script:pane --lines=$lines | Out-String)
}

function Wait-Text([string]$pattern, [int]$timeoutSec = 12) {
    for ($t = 0; $t -lt $timeoutSec * 5; $t++) {
        Start-Sleep -Milliseconds 200
        $tail = Read-Tail
        if ($tail -match $pattern) { return $tail }
    }
    return $null
}

# Start the probe and wait until it is actually blocked in ReadKey.
function Start-Probe([string]$tag) {
    & $Exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
    Start-Sleep -Milliseconds 600
    # argv-audit: $probe is a TEMP path built with Join-Path; $tag is a one-letter literal at every caller.
    & $Exe +send-keys --target=$script:pane "powershell -NoProfile -File $probe -Tag $tag" Enter | Out-Null
    $seen = Wait-Text "PROBE_READY_$tag"
    if ($null -eq $seen) { return $false }
    Start-Sleep -Milliseconds 500   # ReadKey is entered right after the print
    return $true
}

# Unblock a probe that never received a key, and get back to a prompt.
function Stop-Probe {
    & $Exe +send-keys --target=$script:pane 'q' | Out-Null
    Start-Sleep -Milliseconds 400
    & $Exe +send-keys --target=$script:pane Enter | Out-Null
    Start-Sleep -Milliseconds 800
}

function Get-AnyLeaf($node) {
    if ($node.type -eq 'leaf') { return $node.terminal }
    return (Get-AnyLeaf $node.left)
}

# --- T2721 fixtures: a fake Claude Code and a private home --------------------
# Sections I-L ask whether a clipboard holding a picture AND its web address
# (a browser's "Copy image") hands ctrl+v to Claude Code. The app decides
# "this pane runs Claude" from a claude.exe under the pane's shell, and
# "Claude's ctrl+v attaches images" from %USERPROFILE%\.claude\keybindings.json.
# So the probe runs from a COPY of powershell.exe named claude.exe, and the app
# is launched with USERPROFILE pointed at a throwaway home - the user's real
# ~/.claude is never read or written.
$script:fakeRoot = Join-Path $env:TEMP "ghoztty-t2721-$PID"
$script:fakeHome = Join-Path $script:fakeRoot 'home'
$script:fakeClaude = Join-Path $script:fakeRoot 'bin\claude.exe'
New-Item -ItemType Directory -Force -Path (Join-Path $script:fakeHome '.claude') | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $script:fakeClaude -Parent) | Out-Null
Copy-Item (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') $script:fakeClaude -Force
$script:keybindings = Join-Path $script:fakeHome '.claude\keybindings.json'
function Set-ClaudeImagePasteBinding([bool]$bound) {
    if ($bound) {
        $json = '{"bindings":[{"context":"Chat","bindings":{"ctrl+v":"chat:imagePaste"}}]}'
        [IO.File]::WriteAllText($script:keybindings, $json)
    } else {
        Remove-Item $script:keybindings -ErrorAction SilentlyContinue
    }
}
Set-ClaudeImagePasteBinding $true

# A picture with a text format beside it: the browser "Copy image" shape when
# the text is an address, the Excel/Word shape when it is real content.
function Set-ImageAndTextClipboard([string]$text) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Blue)
    $g.Dispose()
    try {
        for ($t = 0; $t -lt 10; $t++) {
            try {
                $do = New-Object System.Windows.Forms.DataObject
                $do.SetData([System.Windows.Forms.DataFormats]::Bitmap, $bmp)
                $do.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $text)
                [System.Windows.Forms.Clipboard]::SetDataObject($do, $true)
                return $true
            } catch { Start-Sleep -Milliseconds 200 }
        }
    } finally { $bmp.Dispose() }
    return $false
}

# The probe, run as the fake claude.exe so the app sees Claude under the shell.
function Start-ClaudeProbe([string]$tag) {
    & $Exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
    Start-Sleep -Milliseconds 600
    # Bare and unquoted, like Start-Probe's line, so it runs the same in cmd
    # and in PowerShell; TEMP paths on this box carry no spaces.
    # argv-audit: both paths are TEMP paths built with Join-Path; $tag is a one-letter literal at every caller.
    & $Exe +send-keys --target=$script:pane "$script:fakeClaude -NoProfile -File $probe -Tag $tag" Enter | Out-Null
    $seen = Wait-Text "PROBE_READY_$tag"
    if ($null -eq $seen) { return $false }
    Start-Sleep -Milliseconds 500
    return $true
}

# One ctrl+v into a running probe; the character code it read, or -1.
function Invoke-ProbeCtrlV([string]$tag) {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key V
    Assert $sent "${tag}: ctrl+v injected"
    $tail = Wait-Text "PROBE_${tag}_CHAR=(\d+)" 10
    if ($tail -match "PROBE_${tag}_CHAR=(\d+)") { return [int]$Matches[1] }
    return -1
}

# --- Setup: fresh debug instance on the test desktop -------------------------
# --session-persistence=false so a restore cannot hand back a previous run's
# window (the T131 lesson), and so the surviving agent cannot replay a layout
# manifest over what this run asserts (the batch-2 lesson).
[void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {

$script:realProfile = $env:USERPROFILE
$env:USERPROFILE = $script:fakeHome
try {
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
} finally { $env:USERPROFILE = $script:realProfile }
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

$lj = $null
for ($t = 0; $t -lt 25 -and $null -eq $lj; $t++) {
    $lj = & $Exe +list --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $lj -or @($lj.data.windows).Count -eq 0) { $lj = $null; Start-Sleep -Milliseconds 300 }
}
if ($null -eq $lj) { Write-Host 'SETUP FAIL: no window in +list'; exit 1 }
$win0 = $lj.data.windows[0]
$script:pane = (Get-AnyLeaf $win0.tabs[0].splits).name
if ([string]::IsNullOrEmpty($script:pane)) { Write-Host 'SETUP FAIL: no pane name'; exit 1 }
# The window id in +list --json IS the decimal HWND (IpcHandlers.zig formats
# @intFromPtr(hwnd)), so this ties the pane NAME the IPC verbs use to the
# HWND the chords go to - rather than trusting they found the same window.
Assert ([int64]$win0.id -eq [int64]$top) '+list window id is the HWND the harness found'
Assert ((Get-TestWindowClass -Window $top) -eq 'GhozttyWindow') 'that HWND really is a GhozttyWindow'
Write-Host "pane=$script:pane top=$top"

# The surface the app itself considers active. GhozttyWindow hands WM_KEYDOWN
# to DefWindowProc and only forwards FOCUS to the active pane, so a posted
# chord aimed at the window is silently dropped (batch-3 lesson).
Focus-TestWindow -Window $top | Out-Null
Start-Sleep -Milliseconds 500
$surface = [IntPtr](Get-TestFocusedWindow -Window $top)
Assert ((Get-TestWindowClass -Window $surface) -eq 'GhozttyTerminal') 'window forwarded focus to a terminal surface'

# --- Positive control: typed text must echo ----------------------------------
& $Exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
Start-Sleep -Milliseconds 600
$sent = Send-TestText -Window $top -Target $surface -Text 'clipctl'
if (-not $sent) { Write-Host 'SKIP ALL: harness could not post keys'; exit 0 }
$tail = Wait-Text 'clipctl' 8
if ($null -eq $tail) {
    Write-Host 'SKIP ALL: positive control failed - injected keys never reached the pane'
    exit 0
}
Assert $true 'positive control: typed keys reach the pane'
& $Exe +send-keys --target=$script:pane C-c | Out-Null
Start-Sleep -Milliseconds 600

# --- Harness sanity: the clipboard fixtures are what we claim -----------------
Assert (Set-TextClipboard 'ZQTOKEN') 'harness: text clipboard set'
Assert ([System.Windows.Forms.Clipboard]::ContainsText()) 'harness: text clipboard reports text'
Assert (Set-ImageOnlyClipboard) 'harness: image clipboard set'
Assert ([System.Windows.Forms.Clipboard]::ContainsImage()) 'harness: image clipboard reports an image'
Assert (-not [System.Windows.Forms.Clipboard]::ContainsText()) 'harness: image clipboard has NO text format'

# --- A: text clipboard + ctrl+v -> pastes (probe sees the token, not ^V) ------
Set-TextClipboard 'ZQTOKEN' | Out-Null
if (-not (Start-Probe 'A')) {
    Assert $false 'A: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key V
    Assert $sent 'A: ctrl+v injected'
    $tail = Wait-Text 'PROBE_A_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_A_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert ($code -eq 90) "A: ctrl+v with text on the clipboard pastes (probe char=$code, want 90 'Z')"
    Assert ($code -ne 22) 'A: ctrl+v does NOT leak a stray ^V when the paste succeeds'
    Stop-Probe
}

# --- B: image-only clipboard + ctrl+v -> falls through as ^V ------------------
# THE T154 CASE. Pre-fix this fails with code=-1: ghoztty swallows the chord.
Set-ImageOnlyClipboard | Out-Null
if (-not (Start-Probe 'B')) {
    Assert $false 'B: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key V
    Assert $sent 'B: ctrl+v injected'
    $tail = Wait-Text 'PROBE_B_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_B_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    # -NegativeControl inverts the load-bearing claim of the whole script -
    # that an image-only clipboard lets ctrl+v through as ^V. The run MUST
    # fail here, which is what proves the assertion discriminates.
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting ctrl+v is SWALLOWED on an image-only clipboard - this run MUST fail'
        Assert ($code -eq -1) "B (inverted): ctrl+v is swallowed with an image-only clipboard (probe char=$code, want none)"
    } else {
        Assert ($code -eq 22) "B: ctrl+v with an image-only clipboard reaches the pane as ^V (probe char=$code, want 22)"
    }
    Stop-Probe
}

# --- C: image-only clipboard + ctrl+shift+v -> already falls through ----------
# The shared cross-platform binding has always carried performable=true; this
# is the control that proves the diagnosis is about the FLAG, not the chord.
Set-ImageOnlyClipboard | Out-Null
if (-not (Start-Probe 'C')) {
    Assert $false 'C: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl,shift -Key V
    Assert $sent 'C: ctrl+shift+v injected'
    $tail = Wait-Text 'PROBE_C_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_C_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert ($code -eq 22) "C: ctrl+shift+v with an image-only clipboard reaches the pane as ^V (probe char=$code, want 22)"
    Stop-Probe
}

# --- D: text clipboard + ctrl+v at a normal prompt still pastes the text ------
# Section A proves the FIRST character; this proves the whole string lands on
# the input line (i.e. the paste path itself is untouched by the flag).
Set-TextClipboard 'ZQ_FULL_PASTE_TOKEN' | Out-Null
& $Exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
Start-Sleep -Milliseconds 800
$sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key V
Assert $sent 'D: ctrl+v injected'
$tail = Wait-Text 'ZQ_FULL_PASTE_TOKEN' 10
Assert ($null -ne $tail) 'D: ctrl+v pastes the full clipboard text onto the input line'
& $Exe +send-keys --target=$script:pane C-c | Out-Null
Start-Sleep -Milliseconds 500

# --- E: text clipboard + shift+insert -> pastes (T156) ------------------------
# Windows Terminal / conhost parity chord. Pre-fix this fails with code=-1:
# the paste_from_selection binding can never perform on win32 and the chord
# was swallowed whole.
Set-TextClipboard 'ZQTOKEN' | Out-Null
if (-not (Start-Probe 'E')) {
    Assert $false 'E: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers shift -Key insert
    Assert $sent 'E: shift+insert injected'
    $tail = Wait-Text 'PROBE_E_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_E_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert ($code -eq 90) "E: shift+insert with text on the clipboard pastes (probe char=$code, want 90 'Z')"
    Stop-Probe
}

# --- F: image-only clipboard + shift+insert -> reaches the pane (T156) --------
# With nothing to paste the performable binding must decline, letting the
# chord fall through to the pane as a keystroke (however ConPTY renders it -
# what matters is that the probe's ReadKey RETURNS, which a swallowed chord
# never causes).
Set-ImageOnlyClipboard | Out-Null
if (-not (Start-Probe 'F')) {
    Assert $false 'F: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers shift -Key insert
    Assert $sent 'F: shift+insert injected'
    $tail = Wait-Text 'PROBE_F_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_F_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert ($code -ne -1) "F: shift+insert with an image-only clipboard reaches the pane instead of being swallowed (probe char=$code)"
    Stop-Probe
}

# --- G: no selection + ctrl+insert -> reaches the pane (T522) -----------------
# The classic Windows copy chord. The generic non-darwin default binds it with
# a plain put(), and copy_to_clipboard declines when there is no selection - so
# pre-fix the chord was swallowed whole and the probe never printed at all
# (code=-1). Performable makes it fall through instead.
Set-TextClipboard 'ZQ_G_UNTOUCHED' | Out-Null
if (-not (Start-Probe 'G')) {
    Assert $false 'G: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key insert
    Assert $sent 'G: ctrl+insert injected'
    $tail = Wait-Text 'PROBE_G_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_G_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert ($code -ne -1) "G: ctrl+insert with NO selection reaches the pane instead of being swallowed (probe char=$code)"
    Assert ((Get-TextClipboard) -eq 'ZQ_G_UNTOUCHED') 'G: a declined ctrl+insert leaves the clipboard alone'
    Stop-Probe
}

# --- H: with a selection + ctrl+insert -> still copies (T522) -----------------
# The other half of performable: when the action CAN perform, the chord is
# consumed and the selection lands on the clipboard. ctrl+shift+a is
# select_all, so the copied text contains the token echoed just above it.
Set-TextClipboard 'ZQ_H_UNTOUCHED' | Out-Null
& $Exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
Start-Sleep -Milliseconds 800
& $Exe +send-keys --target=$script:pane 'echo ZQ_COPY_TOKEN' Enter | Out-Null
$tail = Wait-Text 'ZQ_COPY_TOKEN' 10
Assert ($null -ne $tail) 'H: the token is on screen before the copy'
$sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl,shift -Key A
Assert $sent 'H: ctrl+shift+a (select all) injected'
Start-Sleep -Milliseconds 600
$sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key insert
Assert $sent 'H: ctrl+insert injected'
$copied = ''
for ($t = 0; $t -lt 25; $t++) {
    Start-Sleep -Milliseconds 200
    $copied = Get-TextClipboard
    if ($copied -match 'ZQ_COPY_TOKEN') { break }
}
Assert ($copied -match 'ZQ_COPY_TOKEN') "H: ctrl+insert with a selection copies it to the clipboard (clipboard=$($copied.Length) chars)"

# --- I: image + its address, Claude Code running -> ^V reaches Claude (T2721) -
# THE T2721 CASE. Pre-fix the probe reads 104 ('h' of the pasted URL): Ghoztty
# found text on the clipboard and pasted it, so Claude never saw the key.
$url = 'https://example.com/cat.png'
Assert (Set-ImageAndTextClipboard $url) 'I: harness: image + address clipboard set'
Assert ([System.Windows.Forms.Clipboard]::ContainsImage() -and
    [System.Windows.Forms.Clipboard]::ContainsText()) 'I: harness: the clipboard reports BOTH an image and text'
if (-not (Start-ClaudeProbe 'I')) {
    Assert $false 'I: claude probe became ready'
} else {
    $code = Invoke-ProbeCtrlV 'I'
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the address is PASTED into Claude - this run MUST fail'
        Assert ($code -eq 104) "I (inverted): ctrl+v pastes the address into Claude (probe char=$code, want 104)"
    } else {
        Assert ($code -eq 22) "I: image + address, Claude running: ctrl+v reaches Claude as ^V (probe char=$code, want 22)"
    }
    Stop-Probe
}

# --- J: the same clipboard at a plain shell probe -> the address pastes -------
# Every program other than Claude owns its own ^V (the T2694 constraint).
Set-ImageAndTextClipboard $url | Out-Null
if (-not (Start-Probe 'J')) {
    Assert $false 'J: probe became ready'
} else {
    $code = Invoke-ProbeCtrlV 'J'
    Assert ($code -eq 104) "J: image + address, no Claude: ctrl+v pastes the address (probe char=$code, want 104 'h')"
    Stop-Probe
}

# --- K: image + REAL text (an Excel copy), Claude running -> the text pastes ---
# Office publishes a rendered picture beside the cells; the user wants cells.
# One row only: a newline would raise the unsafe-paste confirmation, which is
# not what this section is about (the rule treats a tab like a newline).
Set-ImageAndTextClipboard "Qty`tPrice`t3`t4.50" | Out-Null
if (-not (Start-ClaudeProbe 'K')) {
    Assert $false 'K: claude probe became ready'
} else {
    $code = Invoke-ProbeCtrlV 'K'
    Assert ($code -eq 81) "K: image + spreadsheet text, Claude running: ctrl+v pastes the text (probe char=$code, want 81 'Q')"
    Stop-Probe
}

# --- L: Claude running but its ctrl+v is NOT image paste -> the address pastes -
# A ^V Claude has nothing bound to would swallow the paste the user has today.
Set-ClaudeImagePasteBinding $false
Set-ImageAndTextClipboard $url | Out-Null
if (-not (Start-ClaudeProbe 'L')) {
    Assert $false 'L: claude probe became ready'
} else {
    $code = Invoke-ProbeCtrlV 'L'
    Assert ($code -eq 104) "L: no chat:imagePaste binding: ctrl+v pastes the address (probe char=$code, want 104 'h')"
    Stop-Probe
}
Set-ClaudeImagePasteBinding $true

Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash at end of run'

# The last statement of the body (T993): the stamp below is written only for a
# run that got all the way here, so a throw that unwinds the try cannot fall
# through to a green verdict and mark the paste path as proven.
$script:bodyDone = $true
} finally {
    # Read the launched pids BEFORE cleanup: Remove-TestDesktop empties the
    # live pid list as it kills, and an emptied list makes the leak assertion
    # below vacuous (the batch-3 lesson).
    $script:launched = @(Get-TestLaunchedPids)
    Set-TextClipboard '' | Out-Null
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
    Remove-Item $probe -ErrorAction SilentlyContinue
    Remove-Item $script:fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

if (-not $script:bodyDone) { Assert $false 'the run reached the end of its body (it unwound early)' }

# A clean green run stamps the covered files (T783/T993) so scripts\guard-due.ps1
# can answer "has this harness been run against the paste code as it now
# stands?". Only a green, finished run stamps, so a red one stays due.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard clipboard-paste -Repo $repo 2>&1 | ForEach-Object { "  $($_.ToString())" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)"; exit 0 }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
