# The machine chooser's HOVER HELP (tracker T1633).
#
# WHAT CHANGED. Mac's chooser puts `.help()` text on nearly every control; the
# win32 chooser had no tooltip at all until T812 gave the CPU meter one, so
# everything else left the user to guess what a control does. The chooser now
# has ONE native comctl32 tooltip carrying Mac's words for every surface that
# exists on Windows:
#
#   painted on the dialog (a track tool the dialog places by hand)
#     - a session card's End button   "End this session (terminates its process)"
#     - the CPU / Name column headers "Sort by cpu" / "Sorted by name, ascending - click to reverse"
#     - the signed-in email + monogram "Signed in as <email>"
#     - a machine row's status dot     "Online" / "Offline" / "Checking status"
#     - a machine row's count capsule  "N active session(s)" (T1745)
#   real child buttons (a subclass tool comctl32 shows itself)
#     - New Window    "Open a new window on <This PC | machine>"
#     - Restore All   "Rebuild this machine's full window layout here"
#     - Activity      "Open Activity Monitor for <machine>"
#     - "..."         "Manage <machine>"
#
# WHAT IS ASSERTED
#   A  setup: a real local agent with two live sessions, a signed-in account (a
#      temp DPAPI store) and one remembered relay machine (a planted cache), so
#      every surface above is on screen
#   B  each painted surface, hovered, derives its tip with Mac's exact words -
#      read from the app's own `chooser help tooltip target=... text=...` line
#   C  each action button, entered, derives its tip - and the words FOLLOW THE
#      SELECTION: New Window names "This PC" on the Local row and the machine on
#      the device row; Activity and "..." name the machine
#   D  the one tooltip control carries a tool per button it explained: a
#      `tooltips_class32` window of this app answers TTM_GETTOOLCOUNT with the
#      track tool plus all four button tools (a TTM_ADDTOOL that silently failed
#      would leave the words derived and nothing to show them)
#   E  NEGATIVE CONTROLS. Leaving a surface for nothing DROPS its tip (scored
#      on order, see below), and a point with no help derives nothing: the card
#      body, and the Local row's status column (the Local row has no dot). Without
#      E, B would pass equally well against a tip that fires anywhere.
#   F  the CPU meter still says T812's words through the generalized plumbing
#      (the full CPU suite is chooser-session-cpu.ps1; this is the smoke check
#      that the shared state machine did not lose it)
#   G  the machine rows' session-count capsule (T1745, Mac's `countBadge`):
#      the Local row records the roster's LISTED count (`chooser row count
#      key=local count=N`, the same number as the detail subtitle), its capsule
#      says "N active sessions", and a session opened with the chooser up moves
#      the count through a PUSHED roster. Negative control: the remembered
#      machine, whose roster never loads, records no count and its row has no
#      capsule to explain.
#
# WHY A LOG LINE IS AN ORACLE. Hover TIMING cannot be observed on the background
# test desktop: no real cursor rests anywhere, so TrackMouseEvent posts a leave
# within a frame of every posted move (T233). The app therefore says what it
# derived at HOVER time, and this script scores the words; the show delay stays
# unobserved. For the same reason a drop is scored on ORDER, not on a count:
# the desktop's own leave drops a painted tip unbidden, so what is asserted is
# that after the pointer left, the last word about that surface is "dropped".
#
# HOW A HOVER IS DRIVEN. A painted surface: a posted WM_MOUSEMOVE at the client
# point (the roster, header and account are painted on the dialog; the status
# dot inside the machine LISTBOX, which is posted to directly). A button: a
# posted WM_SETCURSOR AT THE BUTTON naming itself - the button's DefWindowProc
# forwards it to the dialog, which is exactly the path a real pointer takes, so
# the forwarding is exercised rather than assumed.
#
# Isolation: the IPC endpoint is keyed on $PID, the account store is a temp
# file (GHOSTTY_ACCOUNT_STORE) whose relay is a port nothing listens on, and the
# planted device cache is the DEBUG build's own file, restored on the way out.
# T211/T217: runs on a BACKGROUND desktop and never takes the user's foreground.
#
#   powershell -NoProfile -File test\win32\chooser-help-tooltips.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

# T351: the shared reset/kill helpers. Dot-sourced HERE, ahead of any isolation
# setup, because it drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Security
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

$env:GHOZTTY_PIPE_SUFFIX = "-t1633$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')

$WM_MOUSEMOVE = 0x0200
$WM_SETCURSOR = 0x0020
$HTCLIENT = 1
$LB_GETCOUNT = 0x018B
$LB_GETITEMHEIGHT = 0x01A1
$TTM_GETTOOLCOUNT = 0x040D   # WM_USER + 13

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t1633-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$errlog = Join-Path $tmp 'stderr.log'

# --- the signed-in account --------------------------------------------------
# A DPAPI blob in the current (T93) store shape, so the chooser opens ALREADY
# signed in: the email + monogram are on screen, and the account's token lets
# the chooser seed its list from the cache below. The relay is a port drawn
# free a moment ago and never bound (T694), so every fetch is refused at once
# and nothing here ever reaches a real relay.
$Email = 'e2e@example.com'
$DeadRelayPort = Get-FreePort
$AccountStore = Join-Path $tmp 'account.dat'
function Write-AccountStore {
    $exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
    $json = '{"session_token":"sess-t1633","expiry":' + $exp +
        ',"email":"' + $Email + '","relay_base":"http://127.0.0.1:' + $DeadRelayPort + '"}'
    $enc = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($json), $null, 'CurrentUser')
    [IO.File]::WriteAllBytes($AccountStore, $enc)
}

# --- the remembered machine -------------------------------------------------
# The DEBUG build's device cache, keyed on this account. A refused fetch keeps
# a remembered list (T711), and a remembered row is drawn "checking" until a
# live answer lands - so the status dot's words are known in advance.
$MachineName = 'Helpbox'
$cacheDir = Join-Path $env:LOCALAPPDATA 'ghoztty'
$cachePath = Join-Path $cacheDir 'machines-debug.json'
$cacheBackup = Join-Path $tmp 'machines-debug.json.bak'
$hadCache = Test-Path $cachePath
if ($hadCache) { Copy-Item $cachePath $cacheBackup -Force }

function Write-DeviceCache {
    New-Item -ItemType Directory -Force $cacheDir | Out-Null
    $seed = '{"account":"' + $Email + '","devices":[' +
        '{"id":"t1633-a","name":"' + $MachineName + '","hostname":"helpbox.local"}]}'
    Set-Content -Path $cachePath -Value $seed -Encoding ascii
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

function Count-LogLines($pattern) {
    if (-not (Test-Path $errlog)) { return 0 }
    return @(Select-String -Path $errlog -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

function Wait-LogCount($pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Count-LogLines $pattern) -ge $want) { return $true }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $false
}

# The line number of the last log line matching $pattern, or 0.
function Get-LastLineNo($pattern) {
    if (-not (Test-Path $errlog)) { return 0 }
    $m = @(Select-String -Path $errlog -Pattern $pattern -ErrorAction SilentlyContinue)
    if ($m.Count -eq 0) { return 0 }
    return $m[-1].LineNumber
}

# The text of the NEWEST help line for $target (a regex over the `target=`
# token run, e.g. 'end-session row=0'), waiting for one newer than line
# $afterLine. $null when none arrives.
function Wait-HelpText($target, $afterLine, $timeoutMs = 8000) {
    $pattern = "chooser help tooltip target=$target text=(.*)$"
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $errlog) {
            # UTF-8 explicitly: the active column's words carry an em dash.
            $m = @(Select-String -Path $errlog -Pattern $pattern -Encoding UTF8 -ErrorAction SilentlyContinue)
            if ($m.Count -gt 0 -and $m[-1].LineNumber -gt $afterLine) {
                if ($m[-1].Line -match $pattern) { return $Matches[1] }
            }
        }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $null
}

# After the pointer left $target: wait until the last "dropped" line for it is
# newer than the last hover line for it.
function Wait-HelpDropped($target, $timeoutMs = 8000) {
    $dropAt = 0
    $hoverAt = 0
    $waited = 0
    while ($waited -lt $timeoutMs) {
        $dropAt = Get-LastLineNo "chooser help tooltip dropped target=$target$"
        $hoverAt = Get-LastLineNo "chooser help tooltip target=$target text="
        if ($hoverAt -gt 0 -and $dropAt -gt $hoverAt) { return $true }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    Write-Host "    (drop at line $dropAt, last hover at line $hoverAt)"
    return $false
}

function Pack-Point([int]$x, [int]$y) {
    return [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF))
}

# Park the pointer over a client point of $window by POSTING the WM_MOUSEMOVE a
# real pointer would produce (the only way to hover on the background desktop).
function Move-Pointer([IntPtr]$window, [int]$x, [int]$y) {
    [void](Send-TestRawMessage -Window $window -Message $WM_MOUSEMOVE -LParam (Pack-Point $x $y))
    Start-Sleep -Milliseconds 300
}

# Enter a real child control: WM_SETCURSOR at the control, naming itself. Its
# DefWindowProc forwards the message to the dialog - the real pointer's path.
function Enter-Control($ctl) {
    $h = [IntPtr]$ctl.Hwnd
    $lp = [IntPtr](($WM_MOUSEMOVE -shl 16) -bor $HTCLIENT)
    [void](Send-TestRawMessage -Window $h -Message $WM_SETCURSOR -WParam $h -LParam $lp)
    Start-Sleep -Milliseconds 300
}

# Move onto the dialog's own surface as far as WM_SETCURSOR is concerned: the
# dialog names ITSELF, which is what arrives when the pointer leaves a child.
function Leave-ToDialog([IntPtr]$chooser) {
    $lp = [IntPtr](($WM_MOUSEMOVE -shl 16) -bor $HTCLIENT)
    [void](Send-TestRawMessage -Window $chooser -Message $WM_SETCURSOR -WParam $chooser -LParam $lp)
    Start-Sleep -Milliseconds 300
}

# Hover a painted surface or a control and assert the derived words.
function Test-HelpHover($label, $target, $expected, [scriptblock]$hover) {
    $before = Get-LastLineNo 'chooser (help|cpu) tooltip'
    & $hover
    $got = Wait-HelpText $target $before
    Assert ($null -ne $got) "$label derives a tooltip (target=$target)"
    Assert ($got -ceq $expected) "$label says Mac's words (want '$expected', got '$got')"
}

Write-Host 'T1633 machine chooser hover help'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
$savedStore = $env:GHOSTTY_ACCOUNT_STORE
$savedBase = $env:GHOSTTY_RELAY_BASE
New-TestDesktop | Out-Null

try {
    # --- A: the fixture ----------------------------------------------------
    Write-Host ''
    Write-Host '1. a signed-in account, a remembered machine, two live local sessions'
    [void](Reset-GhozttyTestState -Exe $Exe -SettleMs 500)
    Reset-AgentState
    Write-AccountStore
    Write-DeviceCache
    $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DeadRelayPort"

    # Persistence ON: the panes must be agent-backed so the roster has sessions.
    $app = Start-OnTestDesktop -Exe $Exe `
        -Arguments @('--window-width=100', '--window-height=30', '--session-persistence=true') `
        -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'the GUI died at launch' -Skipped $script:skipped
    }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no GhozttyWindow' -Skipped $script:skipped }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'

    # A second live session, so the roster has two cards and Restore All shows.
    & $Exe +split --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 3

    $chooser = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
            $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        if ($chooser -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert ($chooser -ne [IntPtr]::Zero) 'A ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no chooser window' -Skipped $script:skipped }

    Assert (Wait-LogCount 'chooser roster: loaded [2-9] session' 1 10000) 'A the roster loaded two sessions from the local agent'
    Assert (Wait-LogCount 'seeded 1 machine\(s\) from cache' 1 4000) 'A the remembered machine was seeded into the list'
    $list = Get-ChooserList -Chooser $chooser
    $listH = if ($list) { [IntPtr]$list.Hwnd } else { [IntPtr]::Zero }
    $rows = if ($list) { [int](Invoke-TestMessage -Window $listH -Message $LB_GETCOUNT) } else { -1 }
    Assert ($rows -eq 2) "A the list is Local + the remembered machine (rows=$rows)"
    Assert ((Get-ChooserAccountStatusText -Chooser $chooser) -eq $Email) 'A the account row shows the signed-in email'

    # The persisted sort order decides what the headers say (T602).
    $sortKey = 'name'; $sortDir = 'asc'
    $sl = @(Select-String -Path $errlog -Pattern 'chooser roster: sort loaded key=(\w+) dir=(\w+)' -ErrorAction SilentlyContinue)
    if ($sl.Count -gt 0 -and $sl[-1].Line -match 'key=(\w+) dir=(\w+)') { $sortKey = $Matches[1]; $sortDir = $Matches[2] }
    Assert ($sl.Count -gt 0) "A the persisted sort order is known (key=$sortKey dir=$sortDir)"

    $scale = (Get-TestWindowDpi -Window $chooser) / 96.0
    $geo = Get-TestChooserRosterGeometry -Scale $scale
    $client = Get-TestWindowRect -Window $chooser -Client

    # --- B: the painted surfaces -------------------------------------------
    Write-Host ''
    Write-Host '2. every painted surface explains itself'
    Test-HelpHover 'B the first card''s End button' 'end-session row=0' `
        'End this session (terminates its process)' { Move-Pointer $chooser $geo.KillX $geo.KillY }
    # Off the button onto the card's padding: dropped, and the card itself
    # derives no tip at all (E).
    $beforeCard = Get-LastLineNo 'chooser help tooltip target='
    Move-Pointer $chooser $geo.CardX $geo.CardY
    Assert (Wait-HelpDropped 'end-session row=0') 'E moving off the End button drops its tooltip'
    Start-Sleep -Seconds 1
    Assert ((Get-LastLineNo 'chooser help tooltip target=') -eq $beforeCard) `
        'E the card body itself derives no tooltip'

    function Get-SortWords($key) {
        if ($sortKey -ne $key) { return "Sort by $key" }
        $d = if ($sortDir -eq 'asc') { 'ascending' } else { 'descending' }
        return "Sorted by $key, $d " + [string][char]0x2014 + ' click to reverse'
    }
    # The log is UTF-8 and Wait-HelpText reads it as such, so the em dash in
    # the active column's words compares as one character.
    Test-HelpHover 'B the CPU column header' 'sort-header key=cpu' (Get-SortWords 'cpu') `
        { Move-Pointer $chooser $geo.CpuHeaderX $geo.HeaderY }
    Test-HelpHover 'B the Name column header' 'sort-header key=name' (Get-SortWords 'name') `
        { Move-Pointer $chooser $geo.NameHeaderX $geo.HeaderY }
    Move-Pointer $chooser $geo.CardX $geo.CardY
    Assert (Wait-HelpDropped 'sort-header key=name') 'E moving off a header drops its tooltip'

    # The account: the email STATIC's own rect, in client coordinates, and the
    # monogram one gap to its right (chooser_layout.accountRow).
    $status = Get-ChooserStatic -Chooser $chooser -Edge top
    if ($status) {
        $ex = [int](($status.Left + $status.Right) / 2) - $client.Left
        $ey = [int](($status.Top + $status.Bottom) / 2) - $client.Top
        Test-HelpHover 'B the signed-in email' 'account' "Signed in as $Email" { Move-Pointer $chooser $ex $ey }
        Move-Pointer $chooser $geo.CardX $geo.CardY
        Assert (Wait-HelpDropped 'account') 'E moving off the account drops its tooltip'
        $ax = $status.Right - $client.Left + (Get-TestChromeDip 8 $scale) + (Get-TestChromeDip 16 $scale)
        Test-HelpHover 'B the account monogram' 'account' "Signed in as $Email" { Move-Pointer $chooser $ax $ey }
        Move-Pointer $chooser $geo.CardX $geo.CardY
    } else {
        Assert $false 'B the account status STATIC is found'
    }

    # The machine row's status dot, inside the LISTBOX (row 1 = the remembered
    # machine; row 0 = Local, which has no dot).
    $rowH = [int](Invoke-TestMessage -Window $listH -Message $LB_GETITEMHEIGHT)
    $dotX = (Get-TestChromeDip 4 $scale) + (Get-TestChromeDip 8 $scale) + [int][Math]::Floor((Get-TestChromeDip 12 $scale) / 2)
    Assert ($rowH -gt 0) "B the machine list reports its row height ($rowH)"
    $beforeLocal = Get-LastLineNo 'chooser help tooltip target=machine-status'
    Move-Pointer $listH $dotX ([int]($rowH / 2))
    Start-Sleep -Seconds 1
    Assert ((Get-LastLineNo 'chooser help tooltip target=machine-status') -eq $beforeLocal) `
        'E the Local row''s status column derives no tooltip (it has no dot)'
    Test-HelpHover 'B the remembered machine''s status dot' 'machine-status row=1' 'Checking status' `
        { Move-Pointer $listH $dotX ($rowH + [int]($rowH / 2)) }
    # Onto the same row's title: the list keeps the pointer, the dot's tip goes.
    Move-Pointer $listH ([int]($dotX * 5)) ($rowH + [int]($rowH / 2))
    Assert (Wait-HelpDropped 'machine-status row=1') 'E moving off the status dot drops its tooltip'

    # --- G: the machine rows' session-count capsule (T1745) -----------------
    # Mac's `countBadge`: each machine row carries its loaded session count in a
    # capsule at the trailing edge, the SAME number the detail subtitle shows.
    # The rows are owner-drawn, so the count is read from the app's own
    # `chooser row count key=... count=N` line and held against the roster's
    # `listing N session(s)` line from the same adoption.
    Write-Host ''
    Write-Host '2b. each machine row carries its session count (T1745)'
    $countPat = 'chooser row count key=local count=(\d+)'
    Assert (Wait-LogCount $countPat 1 10000) 'G the Local row recorded a session count'
    $localCount = -1
    $cl = @(Select-String -Path $errlog -Pattern $countPat -ErrorAction SilentlyContinue)
    if ($cl.Count -gt 0 -and $cl[-1].Line -match $countPat) { $localCount = [int]$Matches[1] }
    $listed = -1
    $ll = @(Select-String -Path $errlog -Pattern 'chooser roster: listing (\d+) session' -ErrorAction SilentlyContinue)
    if ($ll.Count -gt 0 -and $ll[-1].Line -match 'listing (\d+) session') { $listed = [int]$Matches[1] }
    Assert ($localCount -ge 2) "G the Local row's count is the two live sessions ($localCount)"
    Assert ($localCount -eq $listed) "G the capsule's count is the roster's listed count (capsule=$localCount listed=$listed)"

    # The capsule's hit box: it ends `text_pad_right` (8 DIP) in from the row's
    # right edge and is at least one caption chip (16 DIP) wide, so 12 DIP in
    # is inside it at every scale.
    $listClient = Get-TestWindowRect -Window $listH -Client
    $capX = $listClient.Width - (Get-TestChromeDip 8 $scale) - (Get-TestChromeDip 4 $scale)
    $sWord = if ($localCount -eq 1) { 'session' } else { 'sessions' }
    Test-HelpHover 'G the Local row''s count capsule' 'session-count row=0' "$localCount active $sWord" `
        { Move-Pointer $listH $capX ([int]($rowH / 2)) }
    Move-Pointer $listH ([int]($dotX * 5)) ([int]($rowH / 2))
    Assert (Wait-HelpDropped 'session-count row=0') 'E moving off the count capsule drops its tooltip'

    # NEGATIVE CONTROL: the remembered machine's roster has never loaded (its
    # relay refuses every dial), so its row has no count and no capsule - the
    # same point on its row derives nothing, and no count was ever recorded.
    $beforeCap = Get-LastLineNo 'chooser help tooltip target=session-count'
    Move-Pointer $listH $capX ($rowH + [int]($rowH / 2))
    Start-Sleep -Seconds 1
    Assert ((Get-LastLineNo 'chooser help tooltip target=session-count') -eq $beforeCap) `
        'E a machine whose roster never loaded has no capsule to explain'
    Assert ((Count-LogLines 'chooser row count key=t1633-a count=') -eq 0) `
        'E no count was recorded for the never-loaded machine'
    Move-Pointer $listH ([int]($dotX * 5)) ([int]($rowH / 2))

    # --- F: the CPU meter still speaks through the shared plumbing ----------
    Write-Host ''
    Write-Host '3. the CPU meter (T812) still explains itself'
    [void](Wait-LogCount 'chooser cpu: frame rows=' 1 10000)
    $cpuBefore = Get-LastLineNo 'chooser cpu tooltip row=\d+ text='
    Move-Pointer $chooser ($geo.MeterLeft + [int](($geo.MeterRight - $geo.MeterLeft) / 2)) $geo.CardY
    $cpuOk = $false
    $waited = 0
    while ($waited -lt 8000) {
        if ((Get-LastLineNo 'chooser cpu tooltip row=\d+ text=\d+% CPU across') -gt $cpuBefore) { $cpuOk = $true; break }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    Assert $cpuOk 'F hovering a meter still derives T812''s words on T812''s line'
    Move-Pointer $chooser $geo.CardX $geo.CardY
    $cpuDrop = $false
    $waited = 0
    while ($waited -lt 8000) {
        if ((Get-LastLineNo 'chooser cpu tooltip dropped') -gt (Get-LastLineNo 'chooser cpu tooltip row=')) { $cpuDrop = $true; break }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    Assert $cpuDrop 'F moving off the meter still logs T812''s drop line'

    # --- C: the action buttons, on the Local row ----------------------------
    Write-Host ''
    Write-Host '4. the action buttons explain themselves, in the selection''s words'
    $primary = Get-ChooserPrimaryButton -Chooser $chooser
    $restore = Get-ChooserRestoreAllButton -Chooser $chooser
    Assert ($primary -and $primary.Visible) 'C New Window is on screen'
    Assert ($restore -and $restore.Visible) 'C Restore All is on screen (two live sessions)'
    if ($primary) {
        Test-HelpHover 'C New Window on the Local row' 'new-window' 'Open a new window on This PC' { Enter-Control $primary }
        Leave-ToDialog $chooser
        Assert (Wait-HelpDropped 'new-window') 'E moving off New Window drops its tooltip'
    }
    if ($restore) {
        Test-HelpHover 'C Restore All' 'restore-all' 'Rebuild this machine''s full window layout here' { Enter-Control $restore }
        Leave-ToDialog $chooser
        Assert (Wait-HelpDropped 'restore-all') 'E moving off Restore All drops its tooltip'
    }

    # --- C: onto the remembered machine --------------------------------------
    [void](Send-TestControlKey -Control $chooser -Key Down)
    Start-Sleep -Milliseconds 600
    $activity = Get-ChooserActivityButton -Chooser $chooser
    $menu = Get-ChooserMenuButton -Chooser $chooser
    $primary = Get-ChooserPrimaryButton -Chooser $chooser
    Assert ($activity -and $activity.Visible) 'C Activity is on screen for the remembered machine'
    Assert ($menu -and $menu.Visible) 'C the management button is on screen for the remembered machine'
    if ($primary) {
        Test-HelpHover 'C New Window follows the selection' 'new-window' "Open a new window on $MachineName" { Enter-Control $primary }
        Leave-ToDialog $chooser
    }
    if ($activity) {
        Test-HelpHover 'C Activity' 'activity' "Open Activity Monitor for $MachineName" { Enter-Control $activity }
        Leave-ToDialog $chooser
    }
    if ($menu) {
        Test-HelpHover 'C the management button' 'manage' "Manage $MachineName" { Enter-Control $menu }
        Leave-ToDialog $chooser
        Assert (Wait-HelpDropped 'manage') 'E moving off the management button drops its tooltip'
    }

    # --- D: one tooltip control, a tool per button --------------------------
    Write-Host ''
    Write-Host '5. one native tooltip carries every button''s tool'
    $tips = @(Get-TestWindows -ProcessId $app.Pid -Class 'tooltips_class32' -AllowHidden)
    $counts = @($tips | ForEach-Object { [int](Invoke-TestMessage -Window ([IntPtr]$_.Hwnd) -Message $TTM_GETTOOLCOUNT) })
    $best = 0
    foreach ($c in $counts) { if ($c -gt $best) { $best = $c } }
    Assert ($tips.Count -ge 1) "D the app owns a native tooltip control ($($tips.Count) found)"
    # The track tool the painted surfaces share, plus New Window, Restore All,
    # Activity and the management button.
    Assert ($best -eq 5) "D the chooser's tooltip carries the track tool + four button tools (tool counts: $($counts -join ','))"

    # --- G: the count follows a PUSHED roster (T1745) ------------------------
    # Back onto the Local row, then open one more session elsewhere with the
    # chooser still up: the agent pushes the new roster (T710), and the Local
    # row's capsule must move with it without anybody re-selecting anything.
    Write-Host ''
    Write-Host '6. the Local row''s count follows a roster push (T1745)'
    [void](Send-TestControlKey -Control $chooser -Key Up)
    Start-Sleep -Milliseconds 1500
    $pushedBefore = Count-LogLines 'chooser roster: loaded \d+ session\(s\) target=local device=- pushed=1'
    $countLineBefore = Get-LastLineNo 'chooser row count key=local count='
    & $Exe +split --direction=down 2>$null | Out-Null
    $want = $localCount + 1
    $moved = -1
    $waited = 0
    while ($waited -lt 15000) {
        $m = @(Select-String -Path $errlog -Pattern $countPat -ErrorAction SilentlyContinue)
        if ($m.Count -gt 0 -and $m[-1].LineNumber -gt $countLineBefore -and $m[-1].Line -match $countPat) {
            $moved = [int]$Matches[1]
            if ($moved -eq $want) { break }
        }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    Assert ($moved -eq $want) "G the Local row's count moved with the new session (want $want, got $moved)"
    Assert ((Count-LogLines 'chooser roster: loaded \d+ session\(s\) target=local device=- pushed=1') -gt $pushedBefore) `
        'G the new count arrived on a PUSHED roster'
    $want2 = "$want active sessions"
    Test-HelpHover 'G the capsule''s words follow the pushed count' 'session-count row=0' $want2 `
        { Move-Pointer $listH $capX ([int]($rowH / 2)) }
    Move-Pointer $listH ([int]($dotX * 5)) ([int]($rowH / 2))

    Assert (Test-TestWindowResponsive -Window $chooser) 'the chooser still answers after the whole drive'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the app survived the whole drive'
    Assert (-not (Select-String -Path $errlog -Pattern 'panic:' -Quiet)) 'no panic reached the app log'

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
    if ($hadCache) { Copy-Item $cacheBackup $cachePath -Force }
    else { Remove-Item $cachePath -Force -ErrorAction SilentlyContinue }
    if ($null -eq $savedStore) { Remove-Item Env:\GHOSTTY_ACCOUNT_STORE -ErrorAction SilentlyContinue }
    else { $env:GHOSTTY_ACCOUNT_STORE = $savedStore }
    if ($null -eq $savedBase) { Remove-Item Env:\GHOSTTY_RELAY_BASE -ErrorAction SilentlyContinue }
    else { $env:GHOSTTY_RELAY_BASE = $savedBase }
}

# --- stamp (T783) -------------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can answer
# "has anyone run this harness against the code as it now stands?". A tooltip
# that stopped appearing leaves nothing on screen to notice, so nothing else on
# the box would go red over it.
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-help-tooltips -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -MinPass 30
