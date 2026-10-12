# T1867 acceptance: a process-tree walk never adopts a stranger through a
# reused parent pid, and the soak scripts' tree-kill never kills one.
#
# THE DEFECT. Windows recycles pids and never rewrites a process's
# ParentProcessId. A walk keyed on the parent pid alone therefore adopts any
# long-lived process whose real parent died before one of OUR processes was
# handed that pid. T1840 found the user's own Spotify inside a floor lane's
# tree that way. soak-daemon.ps1 Stop-Tree and test-binary-soak.ps1
# Stop-SoakProcessTree had the same walk in a KILL path, so the stranger was
# Stop-Process -Force'd. Both now call scripts\lib\ProcessFamily.ps1.
#
# Sections:
#   A  Get-ProcessFamily: a child older than the member it names is not
#      adopted, nor is anything under it; a genuine descendant is.
#      Negative control: the same rows undated DO adopt the stranger.
#   B  A pid reused AFTER the root died: the old root's orphans are still
#      family, the impostor and its children are not.
#   C  Stop-ProcessFamily through its seams: what it would kill. The stranger
#      is spared, the root is never re-killed by a pid somebody else now holds,
#      and an orphan whose parent died in an earlier pass is still reached.
#      Negative control: undated rows -> the stranger IS killed.
#   D  A real tree (powershell -> child) dies through the default seams.
#   E  Wiring: both soak scripts delegate to the library, load it, and carry
#      no pid-only walk of their own.
#   F  The read-only walks (go-loop-pane-probe Find-ClaudeDescendant,
#      PaneIdle Get-DescendantPids, loop-session Resolve-LoopClaudePid)
#      apply the same rule, each with a negative control.
#
# Pure except section D, which starts and kills two hidden processes of its
# own. Opens no window.
#
#   powershell -NoProfile -File test\win32\process-family.ps1
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name $detail"; $script:failures++ }
}

. (Join-Path $Repo 'scripts\lib\ProcessFamily.ps1')

function Row([int]$ProcId, [int]$Parent, $Born, [string]$Name = 'x.exe') {
    return [pscustomobject]@{ ProcessId = $ProcId; ParentProcessId = $Parent; Name = $Name; CreationDate = $Born; CommandLine = '' }
}
function Undate($rows) {
    return @($rows | ForEach-Object { $o = $_.PSObject.Copy(); $o.CreationDate = $null; $o })
}
function Pids($rows) { return @(@($rows) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_.ProcessId } | Sort-Object) }

$now = Get-Date
$spawned = @()

try {
    # ------------------------------------------------------------------ A
    Write-Host 'A  Get-ProcessFamily'
    # Root 26328 born 5 min ago. 41000 is its child, 41500 a grandchild.
    # 39000 names 26328 but was born 8 days ago (its real parent held the pid
    # then); 42000 is 39000's own child.
    $synth = @(
        (Row 26328 1 $now.AddMinutes(-5) 'zig.exe'),
        (Row 41000 26328 $now.AddMinutes(-4) 'test.exe'),
        (Row 41500 41000 $now.AddMinutes(-3) 'test.exe'),
        (Row 39000 26328 $now.AddDays(-8) 'Spotify.exe'),
        (Row 42000 39000 $now.AddDays(-8).AddSeconds(2) 'Spotify.exe')
    )
    $fam = Pids (Get-ProcessFamily -RootPid 26328 -Snapshot $synth)
    Assert 'A1 a child older than the parent it names is not family' (-not ($fam -contains 39000)) "fam=$($fam -join ',')"
    Assert "A2 nor is the stranger's own child" (-not ($fam -contains 42000)) "fam=$($fam -join ',')"
    Assert 'A3 the genuine child and grandchild are, and the root is not listed' `
    (($fam -join ',') -eq '41000,41500') "fam=$($fam -join ',')"
    $loose = Pids (Get-ProcessFamily -RootPid 26328 -Snapshot (Undate $synth))
    Assert 'A4 negative control: undated rows fall back to the pid-only walk and adopt the stranger' `
    (($loose -contains 39000) -and ($loose -contains 42000)) "fam=$($loose -join ',')"
    $none = @(Get-ProcessFamily -RootPid 26328 -Snapshot @())
    Assert 'A5 an empty snapshot is an empty family, not one phantom' ($none.Count -eq 0) "count=$($none.Count)"

    # ------------------------------------------------------------------ B
    Write-Host 'B  a pid reused after the root died'
    $t0 = $now.AddMinutes(-10)
    $reuse = @(
        (Row 41000 26328 $now.AddMinutes(-9) 'test.exe'),       # the dead root's orphan
        (Row 26328 700 $now.AddMinutes(-2) 'impostor.exe'),      # now holds the root's pid
        (Row 43000 26328 $now.AddMinutes(-1) 'impostor-kid.exe') # the impostor's child
    )
    $known = @{ 26328 = $t0 }
    $fam = Pids (Get-ProcessFamily -RootPid 26328 -Snapshot $reuse -Known $known)
    Assert "B1 the dead root's orphan is still family" ($fam -contains 41000) "fam=$($fam -join ',')"
    Assert "B2 the impostor's child is not" (-not ($fam -contains 43000)) "fam=$($fam -join ',')"
    Assert 'B3 the impostor itself is not' (-not ($fam -contains 26328)) "fam=$($fam -join ',')"
    $loose = Pids (Get-ProcessFamily -RootPid 26328 -Snapshot (Undate $reuse) -Known @{ 26328 = $null })
    Assert "B4 negative control: undated, the impostor's child is adopted" ($loose -contains 43000) "fam=$($loose -join ',')"

    # ------------------------------------------------------------------ C
    Write-Host 'C  Stop-ProcessFamily through its seams'
    # A mutable process table: Kill removes the row, Snapshot reads what is left.
    function New-Table($rows) {
        $t = New-Object System.Collections.ArrayList
        foreach ($r in $rows) { $null = $t.Add($r) }
        return , $t
    }
    $table = New-Table $synth
    $killLog = New-Object System.Collections.ArrayList
    $snapFn = { @($table) }.GetNewClosure()
    $killFn = {
        param([int]$KillPid)
        $null = $killLog.Add($KillPid)
        foreach ($r in @($table)) { if ([int]$r.ProcessId -eq $KillPid) { $table.Remove($r) } }
    }.GetNewClosure()
    $ret = @(Stop-ProcessFamily -Id 26328 -Snapshot $snapFn -Kill $killFn -PauseMs 0)
    $k = @($killLog | Sort-Object -Unique)
    Assert 'C1 the root, its child and grandchild are killed' `
    (($k -contains 26328) -and ($k -contains 41000) -and ($k -contains 41500)) "killed=$($k -join ',')"
    Assert 'C2 the stranger and its child are NOT killed' `
    (-not ($k -contains 39000) -and -not ($k -contains 42000)) "killed=$($k -join ',')"
    Assert 'C3 the return value names what was killed' `
    ((@($ret | Sort-Object -Unique) -join ',') -eq ($k -join ',')) "ret=$($ret -join ',') log=$($k -join ',')"

    $table = New-Table (Undate $synth)
    $killLog = New-Object System.Collections.ArrayList
    $snapFn = { @($table) }.GetNewClosure()
    $killFn = {
        param([int]$KillPid)
        $null = $killLog.Add($KillPid)
        foreach ($r in @($table)) { if ([int]$r.ProcessId -eq $KillPid) { $table.Remove($r) } }
    }.GetNewClosure()
    $null = Stop-ProcessFamily -Id 26328 -Snapshot $snapFn -Kill $killFn -PauseMs 0
    Assert 'C4 negative control: undated rows -> the stranger IS killed (the seam measures the guard)' `
    (@($killLog) -contains 39000) "killed=$(@($killLog) -join ',')"

    # The root's pid is handed to an impostor the moment it dies.
    $table = New-Table @((Row 26328 1 $t0 'zig.exe'), (Row 41000 26328 $now.AddMinutes(-9) 'test.exe'))
    $killLog = New-Object System.Collections.ArrayList
    $impostor = Row 26328 700 $now.AddMinutes(-1) 'impostor.exe'
    $snapFn = { @($table) }.GetNewClosure()
    $killFn = {
        param([int]$KillPid)
        $null = $killLog.Add($KillPid)
        foreach ($r in @($table)) { if ([int]$r.ProcessId -eq $KillPid) { $table.Remove($r) } }
        if ($KillPid -eq 26328 -and @($killLog | Where-Object { $_ -eq 26328 }).Count -eq 1) { $null = $table.Add($impostor) }
    }.GetNewClosure()
    $null = Stop-ProcessFamily -Id 26328 -Snapshot $snapFn -Kill $killFn -PauseMs 0
    $rootKills = @($killLog | Where-Object { $_ -eq 26328 }).Count
    Assert 'C5 a pid reused after the root died is never killed again' ($rootKills -eq 1) "root kills=$rootKills log=$(@($killLog) -join ',')"
    Assert "C6 ...while the dead root's orphan still is" (@($killLog) -contains 41000) "log=$(@($killLog) -join ',')"

    # A root whose kill failed is the same process next pass: killed again.
    $table = New-Table @((Row 26328 1 $t0 'zig.exe'))
    $killLog = New-Object System.Collections.ArrayList
    $snapFn = { @($table) }.GetNewClosure()
    $killFn = {
        param([int]$KillPid)
        $null = $killLog.Add($KillPid)
        if (@($killLog).Count -ge 2) { foreach ($r in @($table)) { $table.Remove($r) } }
    }.GetNewClosure()
    $null = Stop-ProcessFamily -Id 26328 -Snapshot $snapFn -Kill $killFn -PauseMs 0
    Assert 'C7 a root that survived its kill (same birth) is killed again' `
    (@($killLog | Where-Object { $_ -eq 26328 }).Count -eq 2) "log=$(@($killLog) -join ',')"

    # An orphan that first shows up AFTER its parent died in an earlier pass.
    $calls = @{ n = 0 }
    $rootRow = Row 26328 1 $t0
    $child = Row 41000 26328 $now.AddMinutes(-9) 'test.exe'
    $grand = Row 41500 41000 $now.AddMinutes(-8) 'test.exe'
    $killLog = New-Object System.Collections.ArrayList
    $snapFn = {
        $calls.n++
        if ($calls.n -le 2) { return @($rootRow, $child) }
        return @($grand)    # the child is dead now; its own child names it
    }.GetNewClosure()
    $killFn = { param([int]$KillPid) $null = $killLog.Add($KillPid) }.GetNewClosure()
    $null = Stop-ProcessFamily -Id 26328 -Snapshot $snapFn -Kill $killFn -PauseMs 0
    Assert 'C8 an orphan of a member killed in an earlier pass is still reached' `
    (@($killLog) -contains 41500) "log=$(@($killLog) -join ',')"

    # ------------------------------------------------------------------ D
    Write-Host 'D  a real tree through the default seams'
    $marker = "t1867-family-$PID"
    $inner = "Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-Command','Start-Sleep 120 # $marker-child'; Start-Sleep 120 # $marker-root"
    $root = Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru `
        -ArgumentList @('-NoProfile', '-Command', "`"$inner`"")
    $spawned += $root.Id
    $childPid = 0
    for ($i = 0; $i -lt 40 -and $childPid -eq 0; $i++) {
        Start-Sleep -Milliseconds 250
        $c = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($root.Id)" -ErrorAction SilentlyContinue |
            Where-Object { ([string]$_.CommandLine) -like "*$marker-child*" })
        if ($c.Count -gt 0) { $childPid = [int]$c[0].ProcessId }
    }
    Assert 'D1 the real tree came up (root + child)' ($childPid -gt 0) "root=$($root.Id)"
    if ($childPid -gt 0) {
        $spawned += $childPid
        $null = Stop-ProcessFamily -Id $root.Id
        Start-Sleep -Milliseconds 300
        Assert 'D2 the root is dead' (-not (Get-Process -Id $root.Id -ErrorAction SilentlyContinue))
        Assert 'D3 the child is dead' (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue))
        Assert 'D4 this harness is still alive (never kills $PID)' ($null -ne (Get-Process -Id $PID -ErrorAction SilentlyContinue))
    }

    # ------------------------------------------------------------------ E
    Write-Host 'E  wiring'
    # The commands a function invokes, from the AST (comments do not count).
    function Get-FnCommands([string]$Text) {
        if (-not $Text) { return @() }
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }
    function Get-FnText([string]$Path, [string]$Name) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $fn = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
                }, $true))
        if ($fn.Count -ne 1) { return '' }
        return $fn[0].Extent.Text
    }
    foreach ($w in @(
            @{ File = 'scripts\soak-daemon.ps1'; Fn = 'Stop-Tree' },
            @{ File = 'scripts\test-binary-soak.ps1'; Fn = 'Stop-SoakProcessTree' })) {
        $path = Join-Path $Repo $w.File
        $text = Get-FnText $path $w.Fn
        $src = Get-Content -LiteralPath $path -Raw
        Assert "E $($w.File) $($w.Fn) delegates to Stop-ProcessFamily" ($text -match 'Stop-ProcessFamily') "fn found=$([bool]$text)"
        $cmds = @(Get-FnCommands $text)
        Assert "E $($w.File) has no family walk or kill of its own" `
        (-not ($cmds -contains 'Get-CimInstance') -and -not ($cmds -contains 'Stop-Process')) "commands=$($cmds -join ',')"
        Assert "E $($w.File) loads lib\ProcessFamily.ps1" ($src -match '\.\s.*lib\\ProcessFamily\.ps1') ''
    }

    # ------------------------------------------------------------------ F
    Write-Host 'F  the read-only walks'
    $probe = Get-FnText (Join-Path $Repo 'scripts\go-loop-pane-probe.ps1') 'Find-ClaudeDescendant'
    Assert 'F1 Find-ClaudeDescendant could be lifted' ([bool]$probe)
    if ($probe) {
        . ([scriptblock]::Create($probe))
        $shellRows = @(
            (Row 5000 1 $now.AddMinutes(-30) 'pwsh.exe'),
            (Row 5100 5000 $now.AddDays(-2) 'claude.exe')    # another pane's, older than this shell
        )
        Assert "F2 an older claude naming the shell's pid is not this pane's" `
        ((Find-ClaudeDescendant -ShellPid 5000 -Procs $shellRows) -eq 0)
        Assert 'F3 negative control: undated, the stranger is found' `
        ((Find-ClaudeDescendant -ShellPid 5000 -Procs (Undate $shellRows)) -eq 5100)
        $own = $shellRows + @((Row 5200 5000 $now.AddMinutes(-20) 'claude.exe'))
        Assert "F4 the pane's own claude is still found" ((Find-ClaudeDescendant -ShellPid 5000 -Procs $own) -eq 5200)
    }

    # The two that read CIM themselves are lifted into a scope where a function
    # named Get-CimInstance (which outranks the cmdlet) serves synthetic rows.
    $script:FakeRows = @()
    function Get-CimInstance {
        param([string]$ClassName, [string]$Filter, $ErrorAction)
        if ($Filter -match 'ProcessId=(\d+)') {
            $want = [int]$matches[1]
            return @($script:FakeRows | Where-Object { [int]$_.ProcessId -eq $want })
        }
        return @($script:FakeRows)
    }
    $idle = Get-FnText (Join-Path $Repo 'test\win32\lib\PaneIdle.ps1') 'Get-DescendantPids'
    Assert 'F5 Get-DescendantPids could be lifted' ([bool]$idle)
    if ($idle) {
        . ([scriptblock]::Create($idle))
        $script:FakeRows = $shellRows
        Assert 'F6 an idle shell does not read busy through a stranger' (@(Get-DescendantPids 5000).Count -eq 0)
        $script:FakeRows = Undate $shellRows
        Assert 'F7 negative control: undated, the stranger is counted' (@(Get-DescendantPids 5000).Count -eq 1)
    }
    $sess = Get-FnText (Join-Path $Repo 'scripts\loop-session.ps1') 'Resolve-LoopClaudePid'
    Assert 'F8 Resolve-LoopClaudePid could be lifted' ([bool]$sess)
    if ($sess) {
        . ([scriptblock]::Create($sess))
        $savedClaude = $env:CLAUDE_PID
        Remove-Item Env:CLAUDE_PID -ErrorAction SilentlyContinue
        try {
            # This process (born now) -> 6000, whose pid a YOUNGER claude holds:
            # our real parent died and somebody else's session got its pid.
            $script:FakeRows = @(
                (Row $PID 6000 $now 'powershell.exe'),
                (Row 6000 1 $now.AddSeconds(30) 'claude.exe')
            )
            Assert "F9 a younger claude at a dead ancestor's pid is not ours" ((Resolve-LoopClaudePid) -eq 0)
            $script:FakeRows = Undate $script:FakeRows
            Assert 'F10 negative control: undated, it is taken' ((Resolve-LoopClaudePid) -eq 6000)
            $script:FakeRows = @(
                (Row $PID 6000 $now 'powershell.exe'),
                (Row 6000 1 $now.AddHours(-1) 'claude.exe')
            )
            Assert 'F11 a genuine (older) claude ancestor is still found' ((Resolve-LoopClaudePid) -eq 6000)
        } finally {
            if ($null -ne $savedClaude) { $env:CLAUDE_PID = $savedClaude }
        }
    }
    Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue

    Complete-TestBody
} finally {
    foreach ($s in $spawned) { try { Stop-Process -Id $s -Force -ErrorAction SilentlyContinue } catch { } }
}

# --- stamp (T783) ---------------------------------------------------------
if ($script:failures -eq 0 -and (Test-TestBodyComplete)) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard process-family -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
