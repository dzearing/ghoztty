# bell-features.ps1 - T1890 acceptance: a bell honours `bell-features`
# `title` and `audio` on Windows, as on Mac.
#
#   1. A BEL in a pane the title is NOT taken from leaves the caption alone:
#      Mac keys the glyph on the focused surface, the one it titles after.
#   2. `title`: a BEL printed in the focused pane puts the bell emoji in front
#      of the window's own caption text (read back with GetWindowText - the
#      text the taskbar and Alt-Tab show), and the app says so in its log.
#   3. A key in the pane is the pane being looked at: the bell clears and the
#      caption is the old title again (Mac clears it on keyDown and focus).
#   4. `audio`: every BEL plays `bell-audio-path` at `bell-audio-volume`,
#      which the app states with the MCI volume it set (0.3 -> 300). The
#      file is a generated SILENT wav, so the run makes no noise. A path that
#      cannot open is logged once, not on every ring.
#
# NOT covered here: the tab label's glyph is painted pixels (the same
# `tabBellPrefix` the caption uses, unit-tested in bell_math.zig); `border`
# is T1919's.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl launches WITHOUT the `title` feature and expects the glyph
# anyway, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\bell-features.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1890-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1890')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Wait-Log([int]$From, [string]$Pattern, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From) |
            Where-Object { $_ -match $Pattern } | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
function Count-Log([int]$From, [string]$Pattern) {
    @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From |
        Where-Object { $_ -match $Pattern }).Count
}

# A half-second 8 kHz mono 16-bit PCM wav of silence.
function New-SilentWav([string]$Path) {
    $rate = 8000; $samples = 4000; $data = $samples * 2
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $data))
    $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([int]16)
    $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]$rate); $w.Write([int]($rate * 2))
    $w.Write([int16]2); $w.Write([int16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]$data)
    $w.Write((New-Object byte[] $data))
    $w.Flush()
    [IO.File]::WriteAllBytes($Path, $ms.ToArray())
}

# The bell glyph as GetWindowText returns it: U+1F514 then a space.
$BellPrefix = [char]::ConvertFromUtf32(0x1F514) + ' '

# One BEL into pane $Target, retried: the first keys can land before the shell
# has a prompt to echo into.
function Ring([int]$From, [string]$Target, [string]$Pattern) {
    for ($try = 0; $try -lt 4; $try++) {
        [void](Invoke-Cli "+send-keys --target=$Target `"[char]7`" Enter")
        $hit = Wait-Log $From $Pattern 2500
        if ($hit) { return $hit }
    }
    return $null
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1890'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $wav = Join-Path $tmp 'silent bell.wav'
    New-SilentWav $wav
    $features = if ($NegativeControl) { 'no-title,audio' } else { 'title,audio' }
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @(
        '--session-persistence=false',
        # Every pane PowerShell, so `[char]7` is a BEL in the first one too.
        '--command=powershell.exe -NoLogo',
        "--bell-features=$features",
        "--bell-audio-path=$wav",
        '--bell-audio-volume=0.3'
    )
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))

    Assert "setup: +split s1 (powershell) exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=s1 --shell=powershell") -eq 0)
    Start-Sleep -Milliseconds 1500
    # The pane the tab is titled after is the FOCUSED one, which here is the
    # first pane: a +split from outside does not move keyboard focus.
    [void](Invoke-Cli "+list --json")
    $focused = $null
    function Find-Focused($node) {
        if ($null -eq $node) { return }
        if ($node.terminal -and $node.terminal.focused) { $script:focusedId = $node.terminal.id }
        Find-Focused $node.left; Find-Focused $node.right
    }
    $script:focusedId = $null
    try {
        $json = Get-Content "$tmp\out.txt" -Raw | ConvertFrom-Json
        Find-Focused $json.data.windows[0].tabs[0].splits
    } catch { "  +list parse failed: $($_.Exception.Message)" }
    $focused = $script:focusedId
    Assert "setup: +list names a focused pane that is not s1 ($focused)" ($focused -and $focused -ne 's1')
    $before = Get-TestWindowText -Window $top
    "  caption before: '$before'"
    Assert "setup: the caption has no bell yet" (-not $before.StartsWith($BellPrefix))

    "== 1: a BEL in a pane the title is NOT taken from leaves the caption alone"
    $mark = Get-LogCount
    $hit = Ring $mark 's1' 'bell audio played'
    Assert "s1 rang (its sound played)" ($null -ne $hit)
    Start-Sleep -Milliseconds 300
    $side = Get-TestWindowText -Window $top
    Assert "the caption is unchanged: '$side'" ($side -eq $before)

    "== 2: a BEL in the focused pane leads the caption with the bell"
    $mark = Get-LogCount
    $hit = Ring $mark $focused 'bell title prefix=true'
    "  $hit"
    Assert "the app re-titled for the bell (log)" ($null -ne $hit)
    Start-Sleep -Milliseconds 300
    $rung = Get-TestWindowText -Window $top
    "  caption rung: '$rung'"
    Assert "the caption is the bell emoji in front of the old title" ($rung -eq ($BellPrefix + $before))

    "== 3: a key in the pane is the pane being looked at: the bell clears"
    $mark = Get-LogCount
    $pane = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible |
        Sort-Object Left, Top) | Select-Object -First 1
    [void](Send-TestControlKey -Control ([IntPtr]$pane.Hwnd) -Key 'Right')
    $clear = Wait-Log $mark 'bell title prefix=false' 4000
    "  $clear"
    Assert "the bell cleared on the key (log)" ($null -ne $clear)
    Start-Sleep -Milliseconds 300
    $after = Get-TestWindowText -Window $top
    "  caption after: '$after'"
    Assert "the caption is back to the old title" ($after -eq $before)

    "== 4: the same bell played the sound file at the configured volume"
    $played = Wait-Log 0 'bell audio played path=.*silent bell\.wav volume=300' 1000
    "  $played"
    Assert "bell-audio-path played at bell-audio-volume 0.3 -> MCI 300 (log)" ($null -ne $played)
    Assert "no MCI failure was logged" ((Count-Log 0 'bell audio: (could not open|play failed)') -eq 0)

    if ($script:failures -gt 0) {
        "  -- app log, bell lines --"
        Get-Content $script:errlog -ErrorAction SilentlyContinue |
            Where-Object { $_ -match 'bell|send.keys|send_keys' } | Select-Object -Last 20 | ForEach-Object { "  | $_" }
    }
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

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard bell-features -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1890' -Path $transcript `
        -Label 'T1890 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
