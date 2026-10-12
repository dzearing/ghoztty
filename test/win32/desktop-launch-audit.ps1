<#
.SYNOPSIS
    T1193 acceptance - an acceptance script that starts the Ghoztty app must
    start it through the test-desktop harness, or be declared as a launcher on
    the user's own desktop.

.DESCRIPTION
    Five sections:

      A. The declaration parser (`lib\DesktopLaunchAudit.ps1`) against fixtures:
         a well-formed marker is read, a malformed one is named rather than
         silently dropped, and prose around the markers is ignored.

      B. The detector, both directions. The interesting half is what is NOT a
         finding: `+split`, `+list` and the rest cannot create a process, so an
         invocation of one is not a launch - and reading them as launches would
         push 79 innocent scripts onto the exception list, which is the same rot
         from the other direction.

      C. The quiet-verb list against the CLI itself. The list is a claim about
         `src\cli\ghostty.zig`'s Action enum and about the one switch arm in
         `src\apprt\win32\App.zig` that auto-launches; a verb added upstream and
         not added here would be classified by the fallback (a finding) rather
         than waved through, but a verb REMOVED here silently stops being
         watched. So the enum is read and compared, and a verb the analyzer has
         never heard of fails this script rather than the sweep.

      D. The desktop-owning filter. A script that creates a test desktop still
         counts a BARE launch (`Start-Process $exe` names no desktop no matter
         how many the script created) and does not count a `+new-window` (its
         app is already up, so the CLI creates nothing).

      E. The sweep over `test\win32\*.ps1`: every launch site is declared, and
         every declaration still names a script that launches.

    `-TeethCheck` proves the section-E assertion can fail: it writes four real
    violators into the swept directory - one bare `Start-Process $exe`, one raw
    `& $exe +new-window`, (T1860) a `cmd /c` wrapper called with
    `+new-window`, the shape ipc-relay.ps1 used, and (T1876) a splatted
    `Start-Process @a` whose hashtable holds the exe - all on no list, and
    requires the sweep to find each. Run it after any change to the analyzer.

.NOTES
    # persistence: launches no GUI - this scores scripts, it does not run them.

    # isolation: none - the `+verb` invocations below are fixture text handed
    # to the analyzer as strings; nothing is executed, so there is no endpoint
    # to make private.

    # preflight: none - it launches nothing. The `Start-Process $exe` the
    # launch-preflight scan can see is a string fixture in section B, which is
    # the same reason the two audit markers below are here.

    # desktop-launch-audit: this script's fixtures are string literals holding
    # the very launch sites it detects (`Start-Process $exe`, `& $exe
    # +new-window`), so it NAMES every watched shape without running one. It
    # starts nothing: section E's planted violators are deleted in a finally
    # block.

    # foreground-audit: no injection and no screen DC - the string fixtures
    # above are the only reason a watched name appears at all.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Suite = Join-Path $Repo 'test\win32'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\DesktopLaunchAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'A. the declaration parser'

$fixture = @(
    '# prose that mentions @user-desktop-launch: in passing but is not a marker line because it has no script'
    '# @user-desktop-launch: alpha.ps1 -- (T1) a real reason'
    '#   @user-desktop-launch: beta.ps1 -- indented, still a marker'
    '# @user-desktop-launch: gamma.ps1 no separator so it cannot be read'
    '# nothing to see here'
)
$decl = @(Get-DesktopLaunchAuditDeclarations -Text $fixture)
$good = @($decl | Where-Object { -not $_.Malformed })
$bad = @($decl | Where-Object { $_.Malformed })
Assert 'A1 two well-formed declarations are read' ($good.Count -eq 2)
Assert 'A2 the script name is parsed' (($good | ForEach-Object { $_.Script }) -join ',' -eq 'alpha.ps1,beta.ps1')
Assert 'A3 the reason survives' ($good[0].Reason -eq '(T1) a real reason')
Assert 'A4 an indented marker still counts' ($good[1].Script -eq 'beta.ps1')
Assert 'A5 a separator-less line is MALFORMED, not dropped' ($bad.Count -eq 2)
Assert 'A6 the malformed line is reported by line number' (($bad | ForEach-Object { $_.Line }) -contains 4)

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'B. the detector, both directions'

function Sites([string[]]$Text) { return @(Get-DesktopLaunchAuditSites -Text $Text) }

$s = Sites @('$exe = "x"', '& $Exe +new-window --target=a')
Assert 'B1 a raw +new-window is a launch' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'new-window')

$s = Sites @('Start-Process $Exe -PassThru')
Assert 'B2 a bare Start-Process of the exe is a launch' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'bare-launch')

$s = Sites @('Start-Process $Exe -ArgumentList @(''--session-persistence=false'')')
Assert 'B3 Start-Process with only flags is still a launch' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'bare-launch')

$s = Sites @('& $Exe --config-file=$cfg')
Assert 'B4 invoking the exe with a flag is a bare launch' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'bare-launch')

$s = Sites @('& "D:\zig-out\bin\ghoztty.exe" +new-window')
Assert 'B5 a literal exe path is recognised' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'new-window')

# The load-bearing negatives.
$s = Sites @('& $Exe +split --target=a --direction=right')
Assert 'B6 +split is NOT a launch (it cannot create a process)' (@($s).Count -eq 0)

$s = Sites @('& $Exe +list --json', '& $Exe +close --target=a', '& $Exe +send-keys --target=a x')
Assert 'B7 the quiet verbs are not launches' (@($s).Count -eq 0)

$s = Sites @('Start-OnTestDesktop -Exe $Exe -Arguments @(''--session-persistence=false'')',
             'Invoke-OnTestDesktop -Exe $Exe -Arguments @(''+new-window'')')
Assert 'B8 the harness entry points are never findings' (@($s).Count -eq 0)

$s = Sites @('# Start-Process $Exe is what this used to do', '#   & $Exe +new-window')
Assert 'B9 a comment about a launch is not a launch' (@($s).Count -eq 0)

$s = Sites @('$exeText = "ghoztty.exe"', 'Write-Host "run & $exeText +new-window"')
Assert 'B10 a string about the exe is not an invocation' (@($s).Count -eq 0)

$s = Sites @('& $Exe @verbArgs')
Assert 'B11 a splatted argv is UNKNOWN, not silently clean' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'unknown')

$s = Sites @('& $Exe +teleport --target=a')
Assert 'B12 a verb the analyzer has never heard of is a finding' (@($s).Count -eq 1)

$s = Sites @('& $Exe +new-window', '& $Exe +list', 'Start-Process $Exe')
Assert 'B13 line numbers point at the site' (@($s | ForEach-Object { $_.Line }) -join ',' -eq '1,3')

# T1860: the cmd.exe shapes - the invocation is a STRING cmd re-parses, which
# is how ipc-relay.ps1 auto-launched onto the user's desktop with this audit
# green.
$s = Sites @('cmd /c "`"$Exe`" +new-window --name=a > nul 2>&1"')
Assert 'B14 cmd /c of +new-window is a launch' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'new-window')

$s = Sites @('cmd /c "`"$Exe`" +send-keys --target=a x > nul"', 'cmd /c mklink /J a b',
             'Start-Process -FilePath cmd.exe -ArgumentList @(''/c'', ''ping -n 60 127.0.0.1 > nul'')')
Assert 'B15 cmd /c of a quiet verb, or of no ghoztty at all, is not a launch' (@($s).Count -eq 0)

$s = Sites @('Start-Process -FilePath cmd.exe -ArgumentList "/c `"`"$Exe`" > `"$o`" 2>&1`""')
Assert 'B16 Start-Process cmd.exe of the bare exe is a launch' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'bare-launch')

$wrap = @(
    'function Run-Cli($argsLine, $out) {'
    '    Start-Process -FilePath cmd.exe -PassThru -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""'
    '}'
    'Run-Cli ''+sessions'' a.txt'
    'Run-Cli ''+new-window --target=x'' b.txt'
    'Run-Cli -argsLine ''+list'' -out c.txt'
)
$s = Sites $wrap
Assert 'B17 a cmd wrapper is scored at the CALL that passes +new-window' (
    @($s).Count -eq 1 -and @($s)[0].Kind -eq 'new-window' -and @($s)[0].Line -eq 5)

$s = Sites @('function Inv([string]$a) { cmd /c "`"$Exe`" $a" }', 'Inv "$($row.verb) --x"')
Assert 'B18 a wrapper called with a runtime-built argv is UNKNOWN' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'unknown')

$s = Sites @('cmd /c "`"$Exe`" $loose > nul"')
Assert 'B19 a cmd line whose argv is a non-parameter variable is UNKNOWN' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'unknown')

$s = Sites @('Write-Host "cmd /c `"$Exe`" +new-window is what this used to do"')
Assert 'B20 prose ABOUT a cmd launch is not one' (@($s).Count -eq 0)

# T1876: the splatted shape - the exe lives in a hashtable, so the command line
# names no program. layout-blob-cross-lineage.ps1's Start-App, in shape.
$splat = @(
    'function Start-App($title, $log) {'
    '    $a = @{'
    '        FilePath    = $Exe'
    '        WindowStyle = ''Minimized'''
    '        ArgumentList = @("--title=$title", ''--window-width=100'')'
    '    }'
    '    if ($log) { $a[''RedirectStandardError''] = $log }'
    '    Start-Process @a | Out-Null'
    '}'
)
$s = Sites $splat
Assert 'B21 a splatted Start-Process of the exe is a launch, at the call' (
    @($s).Count -eq 1 -and @($s)[0].Kind -eq 'bare-launch' -and @($s)[0].Line -eq 8)

$s = Sites @('$p = @{ FilePath = $Exe; ArgumentList = @(''+new-window'', ''--target=a'') }', 'Start-Process @p')
Assert 'B22 a splat whose ArgumentList starts +new-window is a +new-window' (
    @($s).Count -eq 1 -and @($s)[0].Kind -eq 'new-window')

$s = Sites @('$p = @{ FilePath = $Exe; ArgumentList = @(''+list'', ''--json'') }', 'Start-Process @p')
Assert 'B23 a splat of a quiet verb is not a launch' (@($s).Count -eq 0)

$s = Sites @('$p = @{ FilePath = ''notepad.exe'' }', '$p[''FilePath''] = $Exe', 'Start-Process @p')
Assert 'B24 an index write to FilePath is followed' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'bare-launch')

$s = Sites @('$p = @{ FilePath = $AgentHost; ArgumentList = @(''x'') }', 'Start-Process @p',
             'Start-Process @fromCaller')
Assert 'B25 a splat of another program, or of a table built elsewhere, is not a finding' (@($s).Count -eq 0)

$s = Sites @('function Other { $p = @{ FilePath = $Exe } }', 'function Go { Start-Process @p }')
Assert 'B26 a table assigned in ANOTHER function is not this call''s table' (@($s).Count -eq 0)

$s = Sites @('$p = @{ FilePath = ''cmd.exe''; ArgumentList = "/c `"`"$Exe`" +new-window`"" }', 'Start-Process @p')
Assert 'B27 a splatted cmd.exe of +new-window is a launch' (@($s).Count -eq 1 -and @($s)[0].Kind -eq 'new-window')

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'C. the quiet-verb list against the CLI'

$cli = Join-Path $Repo 'src\cli\ghostty.zig'
$verbs = @()
if (Test-Path -LiteralPath $cli) {
    $src = Get-Content -Raw -LiteralPath $cli
    $m = [regex]::Match($src, 'pub const Action = enum \{(?<body>[\s\S]*?)\n\};')
    if ($m.Success) {
        foreach ($line in ($m.Groups['body'].Value -split "`n")) {
            $t = $line.Trim()
            if ($t -match '^@"(?<v>[a-z0-9-]+)",$') { $verbs += $Matches['v'] }
            elseif ($t -match '^(?<v>[a-z0-9_]+),$') { $verbs += ($Matches['v'] -replace '_', '-') }
        }
    }
}
Assert "C1 the Action enum was read ($($verbs.Count) verbs)" ($verbs.Count -ge 20)
$known = @(Get-DesktopLaunchAuditQuietVerbs) + @(Get-DesktopLaunchAuditLaunchVerb)
$unseen = @($verbs | Where-Object { $known -notcontains ('+' + $_) })
Assert "C2 every CLI verb is classified (unclassified: $($unseen -join ','))" ($unseen.Count -eq 0)
$ghost = @(@(Get-DesktopLaunchAuditQuietVerbs) | Where-Object { $verbs -notcontains ($_ -replace '^\+', '') })
Assert "C3 the quiet list names no verb the CLI dropped (ghosts: $($ghost -join ','))" ($ghost.Count -eq 0)
Assert 'C4 the launch verb is +new-window' ((Get-DesktopLaunchAuditLaunchVerb) -eq '+new-window')

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'D. the desktop-owning filter'

$owning = @('$td = New-TestDesktop', 'Start-Process $Exe', '& $Exe +new-window', '& $Exe @args')
$kept = @(Select-DesktopLaunchAuditSites -Text $owning -Sites (Sites $owning))
Assert 'D1 a desktop-owning script still counts its bare launch' (
    $kept.Count -eq 1 -and $kept[0].Kind -eq 'bare-launch')

$owningNoBare = @('$td = New-TestDesktop', '& $Exe +new-window')
$kept = @(Select-DesktopLaunchAuditSites -Text $owningNoBare -Sites (Sites $owningNoBare))
Assert 'D2 a desktop-owning script does not count +new-window' ($kept.Count -eq 0)

$noDesktop = @('& $Exe +new-window')
$kept = @(Select-DesktopLaunchAuditSites -Text $noDesktop -Sites (Sites $noDesktop))
Assert 'D3 a script with NO desktop counts every site' ($kept.Count -eq 1)

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E. the sweep over test\win32'

$planted = @()
try {
    if ($TeethCheck) {
        $v1 = Join-Path $Suite 'zz-desktop-launch-teeth-bare.ps1'
        $v2 = Join-Path $Suite 'zz-desktop-launch-teeth-verb.ps1'
        Set-Content -LiteralPath $v1 -Encoding UTF8 -Value @(
            '$Exe = "D:\git\ghoztty\zig-out\bin\ghoztty.exe"'
            'Start-Process $Exe -ArgumentList @("--session-persistence=false")'
        )
        Set-Content -LiteralPath $v2 -Encoding UTF8 -Value @(
            '$Exe = "D:\git\ghoztty\zig-out\bin\ghoztty.exe"'
            '& $Exe +new-window --target=teeth'
        )
        # T1860: ipc-relay.ps1's Run-Cli as it stood before T1837, verbatim
        # in shape - the launch that put four windows on the user's desktop.
        $v3 = Join-Path $Suite 'zz-desktop-launch-teeth-cmd.ps1'
        Set-Content -LiteralPath $v3 -Encoding UTF8 -Value @(
            '$Exe = "D:\git\ghoztty\zig-out\bin\ghoztty.exe"'
            'function Run-Cli($argsLine, $outfile) {'
            '    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `'
            '        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$env:TEMP\$outfile`" 2>&1`""'
            '}'
            'Run-Cli ''+new-window --target=teeth'' out.txt'
        )
        # T1876: layout-blob-cross-lineage.ps1's Start-App before its
        # migration - the exe inside a splatted hashtable.
        $v4 = Join-Path $Suite 'zz-desktop-launch-teeth-splat.ps1'
        Set-Content -LiteralPath $v4 -Encoding UTF8 -Value @(
            '$Exe = "D:\git\ghoztty\zig-out\bin\ghoztty.exe"'
            'function Start-App($title) {'
            '    $a = @{ FilePath = $Exe; WindowStyle = ''Minimized''; ArgumentList = @("--title=$title") }'
            '    Start-Process @a | Out-Null'
            '}'
            'Start-App teeth'
        )
        $planted = @($v1, $v2, $v3, $v4)
    }

    $findings = @(Get-DesktopLaunchAuditSweep $Suite)
    $hard = @(Get-DesktopLaunchAuditHardKinds)
    $bad = @($findings | Where-Object { $hard -contains $_.Kind })

    if ($TeethCheck) {
        $names = @($bad | ForEach-Object { Split-Path $_.Path -Leaf })
        Assert 'E0a the planted bare launch is found' ($names -contains 'zz-desktop-launch-teeth-bare.ps1')
        Assert 'E0b the planted +new-window is found' ($names -contains 'zz-desktop-launch-teeth-verb.ps1')
        Assert 'E0c the planted cmd /c wrapper launch is found' ($names -contains 'zz-desktop-launch-teeth-cmd.ps1')
        Assert 'E0d the planted splatted Start-Process is found' ($names -contains 'zz-desktop-launch-teeth-splat.ps1')
        $bad = @($bad | Where-Object { (Split-Path $_.Path -Leaf) -notlike 'zz-desktop-launch-teeth-*' })
    }

    foreach ($f in $bad) {
        Write-Host ("    {0}:{1} [{2}] {3}" -f (Split-Path $f.Path -Leaf), $f.Line, $f.Kind, $f.Detail)
    }
    $undeclared = @($bad | Where-Object { $_.Kind -eq 'undeclared' })
    $stale = @($bad | Where-Object { $_.Kind -eq 'stale-declaration' })
    $malformed = @($bad | Where-Object { $_.Kind -eq 'malformed-declaration' })
    Assert "E1 no undeclared launch site ($($undeclared.Count))" ($undeclared.Count -eq 0)
    Assert "E2 no stale declaration ($($stale.Count))" ($stale.Count -eq 0)
    Assert "E3 every declaration parses ($($malformed.Count))" ($malformed.Count -eq 0)

    # The list is a ratchet, not a resting place: say how far it still has to
    # burn down, so a reader sees the number move.
    $decl = @(Get-DesktopLaunchAuditDeclarations -Path (Join-Path $Suite 'lib\TestDesktop.ps1')) |
        Where-Object { -not $_.Malformed }
    $pending = @($decl | Where-Object { $_.Reason -match 'pending migration' })
    Write-Host ("  NOTE {0} scripts declared, {1} of them pending migration" -f @($decl).Count, $pending.Count)
} catch {
    # An unwind here must not reach a green verdict: the sweep is the section
    # that scores the suite, so failing to finish it IS a failure (T1039).
    Assert "E0 the sweep ran to completion ($_)" $false
} finally {
    foreach ($p in $planted) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files, and never a teeth check -
# that run deliberately plants three violators, so its result says nothing about
# the suite as it stands. After Complete-TestBody, which is what the stamp gate
# reads to tell a finished run from one that unwound.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard desktop-launch -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

exit (Write-TestVerdict -Label 'DESKTOP LAUNCH AUDIT' -Pass $script:pass -Fail $script:fail).Code
