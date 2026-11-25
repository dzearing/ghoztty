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

      E. The sweep over `test\win32\*.ps1` and `test\win32\lib\*.ps1` (T1598):
         every launch site is declared, and every declaration still names a
         script that launches.

      F. The `lib\` scope (T1598): helpers are swept and keyed by path, a
         declaration may name one, and a `# desktop-launch-helper:` marker with
         a reason exempts a helper under `lib\` only - stale when it launches
         nothing. (Lettered F to keep A-E's ids stable.)

    `-TeethCheck` proves the section-E assertion can fail: it writes four real
    violators into the swept directory - one bare `Start-Process $exe`, one raw
    `& $exe +new-window`, (T1860) a `cmd /c` wrapper called with
    `+new-window`, the shape ipc-relay.ps1 used, and (T1876) a splatted
    `Start-Process @a` whose hashtable holds the exe, and (T1267) a script's
    own CreateProcessW called as a static method plus a renamed copy of the
    exe, and (T2204) a camelCase `$testExe` launch - all on no list, and
    requires the sweep to find each. Run it after
    any change to the analyzer.

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

# T1597: a header holding exactly ONE line. A one-element [string[]] used to
# unroll to a bare string through the parser's `if`, so $lines[0] was a
# character and this parsed as zero declarations - the case no multi-line
# fixture above can reach.
$one = @(Get-DesktopLaunchAuditDeclarations -Text @('# @user-desktop-launch: solo.ps1 -- (T1597) the only one'))
Assert 'A7 a single-line header yields its one declaration' ($one.Count -eq 1 -and $one[0].Script -eq 'solo.ps1' -and -not $one[0].Malformed)
Assert 'A8 a single-line exemption marker is still read' ((Test-DesktopLaunchAuditExempt -Text @('# desktop-launch-audit: fixture')) -eq $true)

# T1598: a helper is declared by its path under the root.
$libDecl = @(Get-DesktopLaunchAuditDeclarations -Text @(
    '# @user-desktop-launch: lib\Helper.ps1 -- (T1) a helper declared by path'
    '# @user-desktop-launch: lib/Slash.ps1 -- (T1) forward slash normalised'))
Assert 'A9 a lib\ declaration parses and keys by its path' (
    @($libDecl | Where-Object { -not $_.Malformed }).Count -eq 2 -and
    (($libDecl | ForEach-Object { $_.Script }) -join ',') -eq 'lib\Helper.ps1,lib\Slash.ps1')

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

# T1267: cli-launch-cwd.ps1 before T1240 had FOUR launch sites and this audit
# saw one. Its four arms, verbatim in shape - every one must be reported.
$t1240 = @(
    '[string]$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe'''
    '[string]$Com = ''D:\git\ghoztty\zig-out\bin\ghoztty.com'''
    '$a = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `'
    '    -ArgumentList "/c `"cd /d `"$workDir`" && `"$Com`" --session-persistence=false`""'
    '$b = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru -WorkingDirectory $workDir'
    '$c = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `'
    '    -ArgumentList "/c `"cd /d `"$workDir`" && `"$Exe`" --session-persistence=false`""'
    '$pidD = [T506Spawn]::StartDetached($Exe, ''--session-persistence=false'', $workDir)'
)
$s = Sites $t1240
Assert "B28 all four pre-T1240 cli-launch-cwd arms are launches (got lines $(@($s | ForEach-Object { $_.Line }) -join ','))" (
    (@($s | ForEach-Object { $_.Line }) -join ',') -eq '3,5,6,8')

$s = Sites @('& $Com --session-persistence=false', '& "D:\x\ghoztty.com" +new-window', '& $relCom +list')
Assert 'B29 the .com twin is the app: by variable, by literal, and quiet verbs still quiet' (
    @($s).Count -eq 2 -and @($s)[1].Kind -eq 'new-window')

# update-apply.ps1 copied the exe to $applier and launched the copy.
$s = Sites @('$applier = Join-Path $work ''ghoztty-updater.exe''', 'Copy-Item $exe $applier -Force',
             'Start-Process -FilePath $applier')
Assert 'B30 a COPY of the exe under another name is the app' (@($s).Count -eq 1 -and @($s)[0].Line -eq 3)

$s = Sites @('$sandboxExe = Join-Path $installDir ''ghoztty.exe''', '$x = $sandboxExe', '& $x +new-window')
Assert 'B31 a Join-Path to ghoztty.exe, and an alias of that alias, are the app' (
    @($s).Count -eq 1 -and @($s)[0].Kind -eq 'new-window')

# The load-bearing negatives of the widening.
$s = Sites @('$fakeExe = Join-Path $d ''ghoztty.exe''',
             'Copy-Item (Join-Path $env:SystemRoot ''System32\cmd.exe'') $fakeExe -Force',
             'Start-Process -FilePath $fakeExe -ArgumentList ''/c'', ''ping -n 9 127.0.0.1''',
             'Copy-Item $Com "$tmp\ghoztty.com" -Force', 'Copy-Item "$env:SystemRoot\System32\cmd.exe" "$tmp\ghoztty.exe" -Force',
             '& "$tmp\ghoztty.com" /c copy NUL $marker')
Assert 'B32 a decoy (another program copied under our name), and a twin beside one, are not the app' (@($s).Count -eq 0)

$s = Sites @('$agentExe = Join-Path $bin ''ghoztty-agent.exe''', 'Start-Process $agentExe',
             'Start-Process -FilePath "$tmp\ghoztty-relay-e2e.exe" -PassThru', '$ver = & $Exe +version', 'Start-Process $ver')
Assert 'B33 the agent, a relay binary, and the OUTPUT of the exe are not the app' (@($s).Count -eq 0)

$s = Sites @('[Diagnostics.Process]::Start($Exe, ''+new-window'')', '[Diagnostics.Process]::Start($Exe, ''+list'')',
             '[IO.File]::Exists($Exe)', '[Diagnostics.FileVersionInfo]::GetVersionInfo($Exe)')
Assert 'B34 a static spawn is classified by its argv; a static non-spawn is not a launch' (
    @($s).Count -eq 1 -and @($s)[0].Kind -eq 'new-window')

# A script's own CreateProcessW that fills STARTUPINFO.lpDesktop names the
# test desktop - directly, or one call down (test-desktop-spike.ps1's Run).
$csharp = @(
    'Add-Type @"'
    'public static class S {'
    '  public static int StartOnDesk(string exe, string a, string desk) { var si = new STARTUPINFO(); si.lpDesktop = desk; return 1; }'
    '  public static void Run(string exe, string desk) { Body(exe, desk); }'
    '  static void Body(string exe, string desk) { var si = new STARTUPINFO(); si.lpDesktop = "WinSta0\\" + desk; }'
    '  public static int Start(string exe, string a) { return 1; }'
    '}'
    '"@'
    '[S]::StartOnDesk($Exe, ''--x'', $d)'
    '[S]::Run($Exe, ''ghoztty-spike'')'
    '[S]::Start($Exe, ''--x'')'
)
$s = Sites $csharp
Assert 'B35 a spawn method that sets lpDesktop (directly or one call down) is routed; one that does not is a launch' (
    @($s).Count -eq 1 -and @($s)[0].Line -eq 11)

$wrapSp = @(
    'function Invoke-BoundedCli { param([string[]]$CliArgs, [int]$CapMs)'
    '    $p = Start-Process $Com -ArgumentList $CliArgs -PassThru -WindowStyle Hidden }'
    'Invoke-BoundedCli -CliArgs @(''+list'', ''--json'') -CapMs 1'
    'Invoke-BoundedCli -CliArgs @(''+new-window'') -CapMs 1'
)
$s = Sites $wrapSp
Assert 'B36 a Start-Process wrapper is scored at the CALL that passes +new-window' (
    @($s).Count -eq 1 -and @($s)[0].Line -eq 4)

# T1598: lib\FrameLabDriver.ps1's Invoke-FrameLabCli, in shape - the argv is a
# SPLATTED parameter, so the wrapper is scored at its calls. Both caller shapes
# it uses: an array expression, and a parenthesised array concatenation.
$wrapSplat = @(
    'function Invoke-Cli {'
    '    param([Parameter(Mandatory = $true)][string]$Exe, [Parameter(Mandatory = $true)][string[]]$Arguments)'
    '    $out = & $Exe @Arguments 2>&1 | Out-String }'
    'Invoke-Cli $live.Exe (@(''+split'', "--target=$from", ''-e'') + (Get-Rest $s))'
    'Invoke-Cli $live.Exe @(''+rearrange'', "--target=$id")'
)
$s = Sites $wrapSplat
Assert 'B37 a splatted-parameter wrapper whose calls pass quiet verbs is not a launch' (@($s).Count -eq 0)

$s = Sites ($wrapSplat + @('Invoke-Cli -Exe $e -Arguments @(''+new-window'', ''--name=x'')', 'Invoke-Cli $e $built'))
Assert 'B38 the same wrapper is scored at a call passing +new-window, and at one passing a runtime argv' (
    @($s).Count -eq 2 -and @($s)[0].Kind -eq 'new-window' -and @($s)[0].Line -eq 6 -and
    @($s)[1].Kind -eq 'unknown' -and @($s)[1].Line -eq 7)

# T2204: the camelCase suffix. update-real-msi.ps1 launched `$testExe` on the
# user's desktop three times while the lowercase-only name rule read it as some
# other variable. Its value came from no literal this file could see.
$s = Sites @('param([string]$testExe)', 'Start-Process -FilePath $testExe',
             '& $AppExe +new-window', '& $GhozttyExePath --x', '& $relCom +new-window')
Assert "B39 a camelCase ...Exe / ...ExePath / ...Com name is the app (got $(@($s).Count))" (@($s).Count -eq 4)

$s = Sites @('Start-Process $execute', '& $income +new-window', '$exeVersionText = 1', 'Start-Process $exeVersionText',
             'Start-Process $agentExe', '& $AgentExePath --x', 'Start-Process $leakEXE')
Assert "B40 words that merely end in exe/com, and the agent, are not the app (got $(@($s).Count))" (@($s).Count -eq 0)

$s = Sites @('$sleepExe = Join-Path $env:SystemRoot ''System32\timeout.exe''', 'Start-Process $sleepExe',
             '$leakExe = "$env:TEMP\leak.exe"', 'Start-Process $leakExe',
             '$daemonExe = Join-Path $bin ''ghoztty-agent.exe''', 'Start-Process $daemonExe',
             '$appExe = Join-Path $bin ''ghoztty.exe''', 'Start-Process $appExe')
Assert "B41 a camelCase name filled with another program is a decoy; one filled with ours is not (got lines $(@($s | ForEach-Object { $_.Line }) -join ','))" (
    (@($s | ForEach-Object { $_.Line }) -join ',') -eq '8')

# The three shapes the first widened sweep tripped on (12 false sites): a
# parameter default naming another program (agent-pipe.ps1's $ClientExe), a
# Get-Command result (stderr-capture-audit.ps1's $gitExe), and a COPY of a
# foreign ...Exe that the alias pass must not read as a copy of ours
# (crash-first-chance.ps1's $avExe -> $laneCrasher).
$s = Sites @('param([string]$ClientExe = ''D:\x\remote-test-client.exe'', [string]$ToolExe = (Join-Path $PSScriptRoot ''..\tool.exe''))',
             '$ClientExe = Resolve-RemoteTestClient -ClientExe $ClientExe',
             'Start-Process $ClientExe', 'cmd /c "`"$ClientExe`" --pipe=$p"', 'Start-Process $ToolExe',
             '$git = Get-Command git', '$gitExe = $git.Source', '& $gitExe --nosuchflag',
             '$avExe = Join-Path $w ''avthread.exe''', '$crasher = Join-Path $w ''t.exe''', 'Copy-Item $avExe $crasher', 'Start-Process $crasher')
Assert "B42 a foreign parameter default, a Get-Command result, and a copy of a foreign ...Exe are not the app (got lines $(@($s | ForEach-Object { $_.Line }) -join ','))" (@($s).Count -eq 0)

$s = Sites @('param([string]$AppExe = ''D:\x\zig-out\bin\ghoztty.exe'')', 'Start-Process $AppExe',
             '$mixedExe = Join-Path $d ''cmd.exe''', '$mixedExe = Join-Path $d ''ghoztty.exe''', 'Start-Process $mixedExe')
Assert "B43 a parameter default naming ours is the app, and so is a name given ours anywhere (got lines $(@($s | ForEach-Object { $_.Line }) -join ','))" (
    (@($s | ForEach-Object { $_.Line }) -join ',') -eq '2,5')

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
Write-Host 'F. the lib\ scope and the helper marker (T1598)'

$fx = Join-Path $env:TEMP "ghoztty-t1598-dla-$PID"
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $fx 'lib') | Out-Null
    $fxHarness = Join-Path $fx 'lib\TestDesktop.ps1'
    Set-Content -LiteralPath $fxHarness -Encoding ASCII -Value @(
        '# @user-desktop-launch: lib\Declared.ps1 -- (T1) declared by path'
        '# @user-desktop-launch: lib\Gone.ps1 -- (T1) names a helper that does not exist')
    Set-Content -LiteralPath (Join-Path $fx 'lib\Launcher.ps1') -Encoding ASCII -Value @(
        'function Start-Thing { Start-Process $Exe }')
    Set-Content -LiteralPath (Join-Path $fx 'lib\Declared.ps1') -Encoding ASCII -Value @(
        'function Start-Thing { Start-Process $Exe }')
    Set-Content -LiteralPath (Join-Path $fx 'lib\Marked.ps1') -Encoding ASCII -Value @(
        '# desktop-launch-helper: (T1) starts the app where the caller is, by design'
        'function Start-Thing { Start-Process $Exe }')
    Set-Content -LiteralPath (Join-Path $fx 'lib\StaleMark.ps1') -Encoding ASCII -Value @(
        '# desktop-launch-helper: (T1) used to launch'
        'function Get-Thing { & $Exe +list }')
    Set-Content -LiteralPath (Join-Path $fx 'lib\BareMark.ps1') -Encoding ASCII -Value @(
        '# desktop-launch-helper:'
        'function Start-Thing { Start-Process $Exe }')
    Set-Content -LiteralPath (Join-Path $fx 'top-marked.ps1') -Encoding ASCII -Value @(
        '# desktop-launch-helper: (T1) a marker outside lib\ means nothing'
        'Start-Process $Exe')

    $scope = @(Get-DesktopLaunchAuditScope -Root $fx)
    Assert "F1 the scope reads lib\ as well as the top level ($($scope.Count) files)" ($scope.Count -eq 7)
    Assert 'F2 a helper is keyed by its lib\ path; a top-level script by its leaf' (
        (Get-DesktopLaunchAuditKey -Path (Join-Path $fx 'lib\Marked.ps1') -Root $fx) -eq 'lib\Marked.ps1' -and
        (Get-DesktopLaunchAuditKey -Path (Join-Path $fx 'top-marked.ps1') -Root $fx) -eq 'top-marked.ps1')

    $ff = @(Get-DesktopLaunchAuditFindings -Root $fx)
    function FKeys([string]$Kind) {
        return (@($ff | Where-Object { $_.Kind -eq $Kind } |
            ForEach-Object { Get-DesktopLaunchAuditKey -Path $_.Path -Root $fx } | Sort-Object) -join ',')
    }
    $undecl = FKeys 'undeclared'
    Assert "F3 an undeclared launching helper, a reasonless marker and a top-level marker are findings ($undecl)" (
        $undecl -eq 'lib\BareMark.ps1,lib\Launcher.ps1,top-marked.ps1')
    Assert 'F4 a helper declared by path and a helper carrying a reasoned marker are not' (
        $undecl -notmatch 'Declared|lib\\Marked')
    $staleM = FKeys 'stale-helper-marker'
    Assert "F5 a marker on a helper that launches nothing is a stale marker ($staleM)" ($staleM -eq 'lib\StaleMark.ps1')
    $staleD = @($ff | Where-Object { $_.Kind -eq 'stale-declaration' } | ForEach-Object { $_.Detail })
    Assert 'F6 a lib\ declaration naming a missing helper is stale' (
        $staleD.Count -eq 1 -and $staleD[0] -match 'lib\\Gone\.ps1')
    Assert 'F7 the stale marker is a hard kind' ((Get-DesktopLaunchAuditHardKinds) -contains 'stale-helper-marker')
    $oneMark = Get-DesktopLaunchAuditHelperMarker -Text @('# desktop-launch-helper: (T1597) the only line')
    Assert 'F9 a single-line helper marker is still read (the T1597 unroll)' (
        $null -ne $oneMark -and $oneMark.Line -eq 1 -and $oneMark.Reason -eq '(T1597) the only line')
} catch {
    # An unwind must not skip the rest of F and still reach a green verdict
    # (T1039): failing to finish the fixtures IS a failure.
    Assert "F0 the lib\ scope fixtures ran to completion ($_)" $false
} finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# And against the real suite: a scope regression is silent by construction -
# the findings stay at zero and nothing says fewer files were read.
$realScope = @(Get-DesktopLaunchAuditScope -Root $Suite)
$realLib = @($realScope | Where-Object { (Get-DesktopLaunchAuditKey -Path $_ -Root $Suite) -like 'lib\*' })
Assert "F8 the real sweep reads lib\ ($($realLib.Count) helper(s))" ($realLib.Count -ge 50)

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
        # T1267: cli-launch-cwd.ps1's arm D before T1240 - the script's own
        # CreateProcessW, with no lpDesktop - and update-apply.ps1's renamed
        # copy of the exe, the two spellings the sweep could not see.
        $v5 = Join-Path $Suite 'zz-desktop-launch-teeth-static.ps1'
        Set-Content -LiteralPath $v5 -Encoding UTF8 -Value @(
            '$Exe = "D:\git\ghoztty\zig-out\bin\ghoztty.exe"'
            'Add-Type @"'
            'public static class TeethSpawn { public static int StartDetached(string exe, string args, string cwd) { return 0; } }'
            '"@'
            '$pidD = [TeethSpawn]::StartDetached($Exe, ''--session-persistence=false'', $env:TEMP)'
        )
        $v6 = Join-Path $Suite 'zz-desktop-launch-teeth-copy.ps1'
        Set-Content -LiteralPath $v6 -Encoding UTF8 -Value @(
            '$exe = "D:\git\ghoztty\zig-out\bin\ghoztty.exe"'
            '$applier = Join-Path $env:TEMP ''ghoztty-updater.exe'''
            'Copy-Item $exe $applier -Force'
            'Start-Process -FilePath $applier -ArgumentList ''--apply-update'''
        )
        # T1598: a launching HELPER, which the top-level-only sweep never read.
        $v7 = Join-Path $Suite 'lib\zz-desktop-launch-teeth-helper.ps1'
        Set-Content -LiteralPath $v7 -Encoding UTF8 -Value @(
            'function Start-TeethApp { Start-Process -FilePath $Exe -ArgumentList ''--session-persistence=false'' }'
        )
        # T2204: update-real-msi.ps1's shape - a camelCase exe name whose value
        # no literal in the file gives away.
        $v8 = Join-Path $Suite 'zz-desktop-launch-teeth-camel.ps1'
        Set-Content -LiteralPath $v8 -Encoding UTF8 -Value @(
            'param([string]$testExe)'
            'Start-Process -FilePath $testExe'
        )
        $planted = @($v1, $v2, $v3, $v4, $v5, $v6, $v7, $v8)
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
        Assert 'E0e the planted static-method CreateProcessW spawn is found' ($names -contains 'zz-desktop-launch-teeth-static.ps1')
        Assert 'E0f the planted renamed copy of the exe is found' ($names -contains 'zz-desktop-launch-teeth-copy.ps1')
        Assert 'E0g the planted launching lib\ helper is found' ($names -contains 'zz-desktop-launch-teeth-helper.ps1')
        Assert 'E0h the planted camelCase $testExe launch is found' ($names -contains 'zz-desktop-launch-teeth-camel.ps1')
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
