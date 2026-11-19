# T1501 meta-check: no acceptance script plants a fixture under a filename
# Windows quietly creates as something else.
#
# THE DEFECT THIS CLOSES. `Set-Content -Path (Join-Path $d '._.')` succeeds and
# leaves a file named `._` - Win32 strips the trailing dot and says nothing.
# T1436's torn-package fixtures were written that way: they reproduced the real
# package directory "exactly" apart from the one name (`._.`) that defeats the
# delete, so every arm stayed green while the real heal could not delete the
# real package and four floor lanes went red (T1499, fixed locally by writing
# through a `\\?\` path). This is the general guard: a sweep over test\win32\
# for a fixture name that cannot be created verbatim - a trailing dot or space,
# or a reserved device name - at a call that creates or names a path.
#
# Sections:
#
#   A  the trap is real on this box, and the rule describes it: the ordinary
#      write plants a different name, the extended write plants the real one,
#      and the rule calls each segment shape the way Windows treats it
#   B  the scanner bites - on the T1436 shape itself, on direct writes of each
#      hazard - and stays quiet on the remedy, the pragma and plain prose
#   C  the live suite is clean, and the scan really covered it
#   D  the check is wired into the harness floor, which is what runs it
#
# Static apart from section A's two writes into its own temp dir: no app, no
# CLI, no zig build - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\fixture-name-audit.ps1
#   powershell -NoProfile -File test\win32\fixture-name-audit.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it reads files and
# writes fixtures under temp\.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\FixtureNames.ps1')
. (Join-Path $Repo 'scripts\lib\HardDelete.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

function Write-Fixture([string]$Path, [string[]]$Lines) {
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"))
}

function Get-Scan([string]$Path) { return @(Get-FixtureNameFindings $Path) }

$fixtureDir = Join-Path $Repo ("temp\fixture-name-audit-{0}" -f $PID)
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

try {
    # -----------------------------------------------------------------------
    "== A: the trap is real, and the rule describes it"
    # -----------------------------------------------------------------------
    # Ground truth first: without it the rule below could be describing a
    # Windows that does not exist, and section B would be scoring a fiction.
    $plantDir = Join-Path $fixtureDir 'plant'
    New-Item -ItemType Directory -Force -Path $plantDir | Out-Null
    $trap = '._.'
    Set-Content -Path (Join-Path $plantDir $trap) -Value 'x'   # fixture-name-ok: section A demonstrates the trap on purpose
    $names = @(Get-ChildItem -LiteralPath $plantDir -Force | ForEach-Object { $_.Name })
    Assert 'A1 GROUND TRUTH: Set-Content of ._. plants ._ instead' (
        $names.Count -eq 1 -and $names[0] -eq '._') "(got: $($names -join ', '))"

    $extDir = Join-Path $fixtureDir 'extended'
    New-Item -ItemType Directory -Force -Path $extDir | Out-Null
    [System.IO.File]::WriteAllText((ConvertTo-ExtendedPath -Path (Join-Path $extDir $trap)), 'x')
    $names = @([System.IO.Directory]::GetFiles((ConvertTo-ExtendedPath -Path $extDir)) | ForEach-Object { Split-Path -Leaf $_ })
    Assert 'A2 GROUND TRUTH: the same write through \\?\ plants ._. verbatim' (
        $names.Count -eq 1 -and $names[0] -eq '._.') "(got: $($names -join ', '))"

    foreach ($case in @(
            @{ V = '._.'; Bad = $true; Why = 'trailing dot' }
            @{ V = 'trail '; Bad = $true; Why = 'trailing space' }
            @{ V = 'sub.\file.txt'; Bad = $true; Why = 'trailing dot' }
            @{ V = 'CON'; Bad = $true; Why = 'reserved device' }
            @{ V = 'nul.txt'; Bad = $true; Why = 'reserved device' }
            @{ V = 'C:\x\COM1'; Bad = $true; Why = 'reserved device' }
            @{ V = 'LPT9.log'; Bad = $true; Why = 'reserved device' }
            @{ V = '$dir\name.'; Bad = $true; Why = 'trailing dot' }
            @{ V = '._'; Bad = $false }
            @{ V = 'a.b'; Bad = $false }
            @{ V = '.\x\..\y.txt'; Bad = $false }
            @{ V = 'console.log'; Bad = $false }
            @{ V = 'COM10'; Bad = $false }
            @{ V = '*.'; Bad = $false }
            @{ V = '$dir\$name'; Bad = $false }
            @{ V = '\\?\D:\x\._.'; Bad = $false }
        )) {
        $h = Get-FixtureLiteralHazard $case.V
        if ($case.Bad) {
            Assert "A3 '$($case.V)' is a hazard ($($case.Why))" ($h -and $h.Hazard -match $case.Why) "(got: $(if ($h) { $h.Hazard } else { 'none' }))"
        }
        else {
            Assert "A4 '$($case.V)' is not a hazard" (-not $h) "(got: $(if ($h) { $h.Hazard }))"
        }
    }

    # -----------------------------------------------------------------------
    ""
    "== B: the scanner bites, and only on a real one"
    # -----------------------------------------------------------------------
    # The T1436 fixture as it shipped: a helper that writes the ordinary way,
    # fed the names from a foreach. The hazard is two hops from the write.
    $t1436 = Join-Path $fixtureDir 't1436.ps1'
    Write-Fixture $t1436 @(
        'function New-CacheFile {',
        '    param([string]$Dir, [string]$Name, [string]$Content = ''x'')',
        '    Set-Content -Path (Join-Path $Dir $Name) -Value $Content',
        '}',
        'foreach ($f in ''._.'', ''._fonts'', ''AUTHORS.txt'') {',
        '    New-CacheFile -Dir $d -Name $f',
        '}',
        'New-CacheFile $d ''trail.''',
        'New-CacheFile -Dir $d -Name ''OFL.txt'' -Content ''the end.'''
    )
    $r = @(Get-Scan $t1436)
    $lits = @($r | ForEach-Object { $_.Literal })
    Assert 'B1 the T1436 shape is caught through the foreach and the helper' ($lits -contains '._.') "(got: $($lits -join ', '))"
    Assert 'B2 ...at the line the name is written on' (@($r | Where-Object { $_.Literal -eq '._.' -and $_.Line -eq 5 }).Count -eq 1) "($(@($r | ForEach-Object { "$($_.Literal)@$($_.Line)" }) -join ', '))"
    Assert 'B3 ...naming the write that takes it' (@($r | Where-Object { $_.Literal -eq '._.' -and $_.SiteText -match 'Join-Path' }).Count -ge 1)
    Assert 'B4 a positional helper argument is followed too' ($lits -contains 'trail.') "(got: $($lits -join ', '))"
    Assert 'B5 ...and nothing else in that file is reported (content is not a name)' (
        @($lits | Where-Object { $_ -ne '._.' -and $_ -ne 'trail.' }).Count -eq 0) "(got: $($lits -join ', '))"

    $direct = Join-Path $fixtureDir 'direct.ps1'
    Write-Fixture $direct @(
        'New-Item -ItemType File -Path (Join-Path $d ''dot.'') | Out-Null',
        '[System.IO.File]::WriteAllText("$d\space ", ''x'')',
        '''x'' > "$d\NUL.txt"',
        'Out-File -FilePath "$d\CON" -InputObject x',
        '$p = Join-Path $d ''assigned.''',
        'Set-Content -LiteralPath $p -Value x',
        'Copy-Item $src -Destination "$d\copy."'
    )
    $r = @(Get-Scan $direct)
    foreach ($want in @(@{ L = 1; N = 'New-Item + Join-Path' }, @{ L = 2; N = '[IO.File]::WriteAllText' },
            @{ L = 3; N = 'a > redirection' }, @{ L = 4; N = 'Out-File -FilePath' },
            @{ L = 5; N = 'a variable assigned the name' }, @{ L = 7; N = 'Copy-Item -Destination' })) {
        Assert "B6 $($want.N) is a finding" (@($r | Where-Object { $_.Line -eq $want.L }).Count -ge 1) `
            "($(@($r | ForEach-Object { "$($_.Literal)@$($_.Line)" }) -join ', '))"
    }

    # The shapes that look like the defect and are not. A sweep that reported
    # these would be switched off within a week.
    $clean = Join-Path $fixtureDir 'clean.ps1'
    Write-Fixture $clean @(
        '. (Join-Path $Repo ''scripts\lib\HardDelete.ps1'')',
        'function New-CacheFile {',
        '    param([string]$Dir, [string]$Name)',
        '    [System.IO.File]::WriteAllText((ConvertTo-ExtendedPath -Path (Join-Path $Dir $Name)), ''x'')',
        '}',
        'foreach ($f in ''._.'', ''AUTHORS.txt'') { New-CacheFile -Dir $d -Name $f }',
        '[System.IO.File]::WriteAllText(''\\?\D:\x\._.'', ''x'')',
        'Set-Content -Path (Join-Path $d ''on-purpose.'') -Value x   # fixture-name-ok: the test is about the strip',
        'Set-Content -Path $p -Value ''the end.''',
        'Write-Output ''Done.''',
        '"  PASS it ended."',
        '$note = ''a sentence ending in a dot.''',
        'Write-Host $note',
        'Get-ChildItem -Path (Join-Path $d ''*.'')',
        'Join-Path $d ''console.log''',
        'cmd /c "dir > NUL"'
    )
    $r = @(Get-Scan $clean)
    Assert 'B7 the remedy, \\?\, the pragma, content, prose and wildcards are all clean' ($r.Count -eq 0) `
        "($(@($r | ForEach-Object { "$($_.Literal)@$($_.Line)" }) -join ', '))"

    # -----------------------------------------------------------------------
    ""
    "== C: the live suite is clean"
    # -----------------------------------------------------------------------
    $files = @(Get-FixtureScanFiles $Repo)
    $live = @()
    foreach ($f in $files) { $live += @(Get-Scan $f) }
    Assert 'C1 no script under test\win32 plants a name Windows rewrites' ($live.Count -eq 0) (
        ($live | Select-Object -First 8 | ForEach-Object {
            "{0}:{1}:{2} [{3}] {4} <- line {5}" -f $_.Path.Substring($Repo.Length + 1), $_.Line, $_.Col, $_.Literal, $_.Hazard, $_.SiteLine
        }) -join ' / ')
    # A clean sweep that enumerated a handful of files is a broken enumeration
    # reporting success. The suite is 600-odd scripts.
    Assert 'C2 the sweep covered the suite, not a corner' ($files.Count -gt 500) "($($files.Count) files)"
    $heal = @($files | Where-Object { $_ -like '*\floor-lane-cache-heal.ps1' })
    Assert 'C3 the T1436 harness itself was in the sweep' ($heal.Count -eq 1)
    if ($heal.Count -eq 1) {
        # ...and it is clean because its ._. goes through the remedy, not
        # because the scan never saw the name: strip the remedy from a copy
        # and the very same literal must come back as a finding.
        $txt = [System.IO.File]::ReadAllText($heal[0])
        Assert 'C4 its ._. is written through ConvertTo-ExtendedPath' ($txt -match 'WriteAllText\(\(ConvertTo-ExtendedPath')
        $unfixed = Join-Path $fixtureDir 'heal-unfixed.ps1'
        [System.IO.File]::WriteAllText($unfixed, ($txt -replace 'WriteAllText\(\(ConvertTo-ExtendedPath -Path (\(Join-Path \$Dir \$Name\))\)', 'WriteAllText($1'))
        $r = @(Get-Scan $unfixed)
        Assert 'C5 with the remedy stripped, the same harness is a finding at its ._.' (
            @($r | Where-Object { $_.Literal -eq '._.' }).Count -ge 1) "($(@($r | ForEach-Object { $_.Literal }) -join ', '))"
    }

    # -----------------------------------------------------------------------
    ""
    "== D: the check is wired into the floor that runs it"
    # -----------------------------------------------------------------------
    . (Join-Path $Repo 'scripts\lib\HarnessFloor.ps1')
    $names = @(Get-HarnessFloorAudits | ForEach-Object { [string]$_.Name })
    Assert 'D1 fixture-name-audit.ps1 is a member of the harness floor' `
        ($names -contains 'fixture-name-audit.ps1') "(set: $($names.Count) rows)"
    Assert 'D2 it is not listed as a pending exception' `
        (-not (Get-HarnessFloorPending).ContainsKey('fixture-name-audit.ps1'))

    # -----------------------------------------------------------------------
    # Negative control: the sweep must go RED against a REAL tracked file, not
    # only against section B's fixtures. Plant the T1436 shape in a live lib
    # script and assert - INVERTED - that the suite stays clean. A working
    # sweep fails that, so a healthy repo scores exactly 1 FAILURE here.
    # -----------------------------------------------------------------------
    if ($NegativeControl) {
        ""
        "NEGATIVE CONTROL: asserting a planted ._. goes unreported - a working sweep MUST fail this"
        $probe = Join-Path $PSScriptRoot 'lib\VtText.ps1'
        $original = [System.IO.File]::ReadAllBytes($probe)
        $hits = @()
        try {
            $line = 'function Get-Planted { Set-Content -Path (Join-Path $env:TEMP ''._.'') -Value x }'
            [System.IO.File]::WriteAllBytes($probe, $original + [System.Text.Encoding]::UTF8.GetBytes("`r`n" + $line + "`r`n"))
            foreach ($f in @(Get-FixtureScanFiles $Repo)) { $hits += @(Get-Scan $f) }
        } finally {
            [System.IO.File]::WriteAllBytes($probe, $original)
        }
        Assert 'N1 a planted ._. goes unreported (inverted)' ($hits.Count -eq 0) "($($hits.Count) finding(s), and 1 is the healthy answer)"
        $restored = [System.IO.File]::ReadAllBytes($probe)
        Assert 'N2 the probe file is restored byte for byte' `
            (@(Compare-Object $original $restored -SyncWindow 0).Count -eq 0)
    }
}
catch {
    # T1511: score the throw rather than unwinding past it to a green verdict.
    Assert 'the run finished its sections' $false "(threw: $($_.Exception.Message))"
    $_.ScriptStackTrace
}
finally {
    if (Test-Path -LiteralPath $fixtureDir) { [void](Remove-TreeHard -Path $fixtureDir) }
}

Complete-TestBody

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
