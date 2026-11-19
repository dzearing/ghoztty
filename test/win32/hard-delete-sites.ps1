<#
.SYNOPSIS
  Acceptance test for T1500: every script that deletes a tree whose contents
  came from somewhere else uses the hard delete a filename cannot defeat.

.DESCRIPTION
  T1499 found that `Remove-Item -Recurse -Force` cannot delete a directory
  holding a file named `._.` (a macOS AppleDouble sidecar) and gave the cache
  heal `Remove-TreeHard` (scripts\lib\HardDelete.ps1). T1500 swept the other
  recursive deletes under scripts\ and moved the ones over FOREIGN content -
  a downloaded or extracted release, a wiped zig cache full of fetched
  packages, an install folder the user unpacked - onto it. The per-site
  verdicts are in docs\design\windows-parity-tasks\T1500.md.

  Arm A  the hazard is real on this box (positive control) and the hard
         delete survives it, under StrictMode Latest (two converted scripts
         run strict).
  Arm B  the GetNewClosure capture the cleanup screen uses still reaches the
         hard delete, and still throws when it cannot.
  Arm C  wiring: each converted script parses, dot-sources HardDelete.ps1,
         and calls Remove-TreeHard.
  Arm D  the audit: a script under scripts\ that handles foreign content
         (extracts an archive, downloads a release, wipes a zig cache) carries
         no bare recursive Remove-Item unless the line is marked
         `# own-tree:` with a reason. D0 is the negative control: the same
         scan over a planted offender must flag it.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.
  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $RepoRoot 'scripts\lib\HardDelete.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

# `Set-Content` cannot create `._.` (it strips the trailing dot), so the
# fixture is written through a `\\?\` path, as in floor-lane-cache-heal.ps1.
function New-HazardFile {
    param([string]$Dir, [string]$Name)
    [System.IO.File]::WriteAllText((ConvertTo-ExtendedPath -Path (Join-Path $Dir $Name)), 'x')
}
function New-HazardTree {
    param([string]$Root)
    $nest = Join-Path $Root 'Ghoztty\share'
    New-Item -ItemType Directory -Force -Path $nest | Out-Null
    New-HazardFile -Dir $Root -Name '._.'
    New-HazardFile -Dir $nest -Name '._.'
    New-HazardFile -Dir $nest -Name 'ok.txt'
    return $Root
}

$Sandbox = Join-Path $env:TEMP ("hard-delete-sites-{0}" -f $PID)
New-Item -ItemType Directory -Force -Path $Sandbox | Out-Null
try {
    # ------------------------------------------------------------- arm A ----
    $a = New-HazardTree -Root (Join-Path $Sandbox 'a-control')
    $err = ''
    try { Remove-Item -LiteralPath $a -Recurse -Force -ErrorAction Stop } catch { $err = $_.Exception.Message }
    Check 'A1 positive control: Remove-Item cannot delete a tree holding ._.' `
        (Test-Path -LiteralPath $a) "it was deleted ($err) - the fixture no longer reproduces the hazard"

    # A script file, not -Command: native argv passing strips the quotes.
    $strictPs = Join-Path $Sandbox 'a-strict.ps1'
    Set-Content -LiteralPath $strictPs -Encoding ASCII -Value @(
        'param([string]$Lib, [string]$Target)',
        'Set-StrictMode -Version Latest',
        '$ErrorActionPreference = ''Stop''',
        '. $Lib',
        '$r = Remove-TreeHard -Path $Target',
        'Write-Output ("removed={0} method={1}" -f $r.Removed, $r.Method)'
    )
    $strictOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $strictPs `
        -Lib (Join-Path $RepoRoot 'scripts\lib\HardDelete.ps1') -Target $a 2>&1 |
        ForEach-Object { "$_" } | Out-String
    Check 'A2 Remove-TreeHard removes the ._. tree under StrictMode Latest' `
        (-not (Test-Path -LiteralPath $a) -and $strictOut -match 'removed=True') $strictOut.Trim()

    # ------------------------------------------------------------- arm B ----
    # The cleanup screen's shape: a function captured as a value, invoked from
    # a GetNewClosure() block that cannot see script functions by name.
    $b = New-HazardTree -Root (Join-Path $Sandbox 'b-closure')
    $hard = ${function:Remove-TreeHard}
    $d = $b
    $rm = {
        $r = & $hard -Path $d
        if (-not $r.Removed) { throw "could not remove ${d}: $($r.Error)" }
    }.GetNewClosure()
    $threw = ''
    try { & $rm } catch { $threw = $_.Exception.Message }
    Check 'B1 the captured hard delete removes a ._. install folder from a closure' `
        (-not (Test-Path -LiteralPath $b) -and -not $threw) $threw

    # Negative: a delete that cannot finish must throw, not report success.
    # A file held open with no sharing cannot be deleted by any attempt.
    $bl = Join-Path $Sandbox 'b-locked'
    New-Item -ItemType Directory -Force -Path $bl | Out-Null
    $held = [System.IO.File]::Open((Join-Path $bl 'held.bin'), 'Create', 'ReadWrite', 'None')
    try {
        $d = $bl
        $rm2 = {
            $r = & $hard -Path $d
            if (-not $r.Removed) { throw "could not remove ${d}: $($r.Error)" }
        }.GetNewClosure()
        $threw = ''
        try { & $rm2 } catch { $threw = $_.Exception.Message }
        Check 'B2 the closure still throws when the folder cannot be removed' `
            ($threw -match 'could not remove') "no throw while a file was held open"
    } finally { $held.Dispose() }

    # ------------------------------------------------------------- arm C ----
    $converted = @(
        'scripts\deliver-windows-build.ps1',
        'scripts\verify-release-assets.ps1',
        'scripts\verify-release-clean.ps1',
        'scripts\test-binary-soak.ps1',
        'scripts\ghoztty-cleanup.ps1'
    )
    foreach ($rel in $converted) {
        $p = Join-Path $RepoRoot $rel
        $tokens = $null; $perr = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$perr)
        $text = Get-Content -LiteralPath $p -Raw
        $ok = (@($perr).Count -eq 0) -and ($text -match 'lib\\HardDelete\.ps1') -and ($text -match 'Remove-TreeHard')
        Check "C $rel parses, dot-sources HardDelete.ps1 and calls Remove-TreeHard" $ok `
            ("parse errors={0}" -f @($perr).Count)
    }

    # ------------------------------------------------------------- arm D ----
    # A file "handles foreign content" when it extracts an archive, downloads a
    # release, or wipes a zig cache. In such a file every recursive
    # Remove-Item must be the hard delete or carry an `# own-tree:` reason.
    $foreignRx = 'ExtractToDirectory|Expand-Archive|gh release download|WipeCache|zig-global-cache'
    function Get-BareSites {
        param([string]$Path)
        $text = Get-Content -LiteralPath $Path -Raw
        if ($text -notmatch $foreignRx) { return @() }
        # The parser, not a line regex: a doc comment that QUOTES the bare
        # delete (CacheHeal.ps1 explains the hazard that way) is not a site.
        # A delete inside a string that becomes a generated script is not
        # seen either; test-binary-soak's worker body is checked by arm C.
        $tokens = $null; $perr = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$perr)
        $lines = Get-Content -LiteralPath $Path
        $hits = @()
        $cmds = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in $cmds) {
            $name = $c.GetCommandName()
            if ($name -notin @('Remove-Item', 'rm', 'del', 'rd', 'rmdir', 'ri', 'erase')) { continue }
            $recurse = @($c.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                'recurse'.StartsWith($_.ParameterName.ToLowerInvariant()) -and $_.ParameterName.Length -ge 1 })
            if ($recurse.Count -eq 0) { continue }
            $ln = $c.Extent.StartLineNumber
            if ($lines[$ln - 1] -match '#\s*own-tree:') { continue }
            $hits += ("{0}:{1}" -f $Path, $ln)
        }
        # Plain return: the caller wraps in @(), so an empty result counts 0
        # and a one-element result stays a string (never `return ,`, which
        # nests and makes every count read 1).
        return $hits
    }

    $plant = Join-Path $Sandbox 'd-offender.ps1'
    Set-Content -LiteralPath $plant -Encoding ASCII -Value @(
        '[IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)',
        'Remove-Item -LiteralPath $x -Recurse -Force',
        'Remove-Item -LiteralPath $y -Recurse -Force   # own-tree: written by this script',
        '<# a comment quoting Remove-Item -Recurse -Force is not a site #>',
        'Remove-Item -LiteralPath $z -Force'
    )
    $planted = @(Get-BareSites -Path $plant)
    Check 'D0 negative control: the scan flags a bare delete in a file that extracts an archive (and only it)' `
        ($planted.Count -eq 1 -and $planted[0] -match ':2$') ("flagged: " + ($planted -join ', '))

    $files = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.Name -ne 'HardDelete.ps1' }
    $offenders = @()
    $scanned = 0
    foreach ($f in $files) {
        $hits = @(Get-BareSites -Path $f.FullName)
        if ((Get-Content -LiteralPath $f.FullName -Raw) -match $foreignRx) { $scanned++ }
        $offenders += $hits
    }
    Check ("D1 no script handling foreign content keeps a bare recursive delete ({0} such scripts scanned)" -f $scanned) `
        ($offenders.Count -eq 0 -and $scanned -ge 3) (($offenders | ForEach-Object { $_.Replace($RepoRoot + '\', '') }) -join '; ')

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    if (Test-Path -LiteralPath $Sandbox) { Remove-TreeHard -Path $Sandbox | Out-Null }
}

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard hard-delete-sites -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
