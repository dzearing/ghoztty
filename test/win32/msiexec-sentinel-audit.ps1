# T3405 meta-check: every acceptance script that runs a REAL msiexec carries
# the T3394 user-install sentinel, and the check that says so has teeth.
#
# Why: on 2026-11-22 a release build inside a test sandbox ran msiexec against
# the shipping product (T3388). Windows Installer state is per-user, not
# per-LOCALAPPDATA, so no sandbox stops a package that carries the shipping
# identity: it reconfigured the user's installed Ghoztty and renamed its agent
# aside. T3394 answered with test\win32\lib\UserInstallSentinel.ps1 - a
# pre-flight that REFUSES a package able to reach the user's product, and a
# before/after snapshot plus an installer-event read that PROVE the user's
# install did not move - and wired it into the two update harnesses. Three more
# harnesses kept running msiexec without it, and nothing would have stopped the
# next installer harness from shipping without it too. This audit is that
# stop.
#
# THE RULE. A top-level script under test\win32\ that runs msiexec - directly
# (`msiexec ...`, `& $msiexec ...`) or through Start-Process / Start-OnTestDesktop
# with msiexec as the program - must
#
#   * dot-source lib\UserInstallSentinel.ps1, and call
#   * Get-PackageUserProductReach   (the refusal, before any install),
#   * Get-UserInstallSnapshot       (before, and again after),
#   * Compare-UserInstallSnapshot   (the diff that proves nothing moved),
#   * Get-UserProductInstallerEvents (the installer's own record).
#
# Detection reads the PowerShell AST, not the text: a comment, an assertion
# label or a fixture string that merely MENTIONS msiexec is not a run of it,
# and a variable assigned a path ending in msiexec.exe is followed to the
# command that runs it. Out of scope, deliberately: test\win32\lib\ (the one
# lib site is ThrowawayProduct.ps1's `msiexec /x` of a throwaway identity, which
# every caller above already brackets with the sentinel) and the app's own
# update applier, whose msiexec runs are the subject of the update harnesses.
#
# Sections:
#
#   A  the detector bites, and only on real runs (synthetic fixtures)
#   B  the live tree: every script that runs msiexec carries the sentinel, and
#      the detector still SEES the installers it is known to cover
#   N  -NegativeControl: the live installers with their sentinel lines
#      stripped must be reported; the inverted assertion scores red
#
# Static scan, no app, no CLI, no msiexec - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\msiexec-sentinel-audit.ps1
#   powershell -NoProfile -File test\win32\msiexec-sentinel-audit.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it only parses files.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

# The calls a script that runs msiexec owes, in the order a reader meets them.
$script:SentinelCalls = @(
    'Get-PackageUserProductReach',
    'Get-UserInstallSnapshot',
    'Compare-UserInstallSnapshot',
    'Get-UserProductInstallerEvents'
)

# The scripts known to run a real msiexec on 2026-11-22. B asserts the detector
# still finds each one, so a detector that went blind (a parser change, a
# rewritten launch helper) cannot pass by finding nothing to check.
$script:KnownInstallers = @(
    'arp-orphan.ps1',
    'install-walkthrough.ps1',
    'msi-upgrade.ps1',
    'update-graceful.ps1',
    'update-real-msi.ps1'
)

function Test-MsiexecName([string]$s) {
    if (-not $s) { return $false }
    return ($s -match '(^|[\\/])msiexec(\.exe)?$')
}

function Get-MsiexecRunSites {
    <#
      The lines of $Text that RUN msiexec, as ints. AST-based: every
      CommandAst whose program is msiexec - by name, by a string literal
      naming it, or by a variable an assignment in the same file gave a path
      ending in msiexec.exe - either as the command itself or as the program
      argument of Start-Process / Start-OnTestDesktop.
    #>
    param([string]$Text)
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)

    # Variables that hold msiexec's path: any assignment whose right side
    # mentions msiexec(.exe) as a string constant.
    $vars = @{}
    foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $strs = @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
        foreach ($s in $strs) {
            if (Test-MsiexecName $s.Value) { $vars[$a.Left.VariablePath.UserPath.ToLowerInvariant()] = $true }
        }
    }

    function Test-ProgramElement($el) {
        if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return (Test-MsiexecName $el.Value)
        }
        if ($el -is [System.Management.Automation.Language.VariableExpressionAst]) {
            return $vars.ContainsKey($el.VariablePath.UserPath.ToLowerInvariant())
        }
        if ($el -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            return (Test-MsiexecName $el.Value)
        }
        return $false
    }

    $sites = @()
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $els = $c.CommandElements
        if ($els.Count -eq 0) { continue }
        $head = $els[0]
        if (Test-ProgramElement $head) { $sites += $c.Extent.StartLineNumber; continue }
        $name = $c.GetCommandName()
        if ($name -notin @('Start-Process', 'saps', 'start', 'Start-OnTestDesktop')) { continue }
        # The program: the value of -FilePath / -Exe, else the first positional.
        $prog = $null
        for ($i = 1; $i -lt $els.Count; $i++) {
            $e = $els[$i]
            if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                if ($e.ParameterName -in @('FilePath', 'Exe', 'Path')) {
                    $prog = if ($e.Argument) { $e.Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] } else { $null }
                    break
                }
                # A named parameter that takes a value: skip the value.
                if (-not $e.Argument -and $i + 1 -lt $els.Count -and
                    $els[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst] -and
                    $e.ParameterName -notin @('Wait', 'PassThru', 'NoNewWindow', 'UseNewEnvironment')) { $i++ }
                continue
            }
            $prog = $e
            break
        }
        if ($prog -and (Test-ProgramElement $prog)) { $sites += $c.Extent.StartLineNumber }
    }
    return , @($sites | Sort-Object -Unique)
}

function Get-SentinelGaps {
    <#
      What a script that runs msiexec is missing, as strings. Empty = carries
      the whole sentinel. Read from the AST too, so a commented-out call does
      not count.
    #>
    param([string]$Text)
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
    $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    $gaps = @()
    $loaded = $false
    foreach ($c in $cmds) {
        if ($c.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and
            $c.Extent.Text -match 'UserInstallSentinel\.ps1') { $loaded = $true; break }
    }
    if (-not $loaded) { $gaps += 'never dot-sources lib\UserInstallSentinel.ps1' }
    $called = @{}
    foreach ($c in $cmds) { $n = $c.GetCommandName(); if ($n) { $called[$n] = $true } }
    foreach ($fn in $script:SentinelCalls) {
        if (-not $called.ContainsKey($fn)) { $gaps += "never calls $fn" }
    }
    return , @($gaps)
}

function Invoke-SentinelAudit {
    <# One finding per script that runs msiexec without the whole sentinel. #>
    param([hashtable]$Files)   # name -> text
    $findings = @()
    foreach ($name in @($Files.Keys | Sort-Object)) {
        $sites = Get-MsiexecRunSites -Text $Files[$name]
        if ($sites.Count -eq 0) { continue }
        $gaps = Get-SentinelGaps -Text $Files[$name]
        if ($gaps.Count -gt 0) {
            $findings += "$name (runs msiexec at line $($sites -join ', ')): $($gaps -join '; ')"
        }
    }
    return , @($findings)
}

$wired = @'
. (Join-Path $PSScriptRoot 'lib\UserInstallSentinel.ps1')
$before = Get-UserInstallSnapshot -Dir $d
if (@(Get-PackageUserProductReach -Msi $m).Count) { exit 1 }
try { Start-Process msiexec.exe -ArgumentList @('/i', $m, '/qn') -Wait }
finally {
    $diff = Compare-UserInstallSnapshot -Before $before -After (Get-UserInstallSnapshot -Dir $d)
    $ev = Get-UserProductInstallerEvents -Since $t
}
'@

try {
    # -----------------------------------------------------------------------
    "== A: the detector bites, and only on real runs"
    # -----------------------------------------------------------------------
    $runShapes = [ordered]@{
        'A1 Start-Process msiexec.exe'          = "Start-Process msiexec.exe -ArgumentList @('/i', `$m, '/qn') -Wait"
        'A2 Start-Process -FilePath a variable' = "`$x = Join-Path `$env:SystemRoot 'System32\msiexec.exe'`n`$p = Start-Process -FilePath `$x -ArgumentList '/i' -Wait -PassThru"
        'A3 call operator on msiexec'           = "& msiexec /i `$m /qn"
        'A4 Start-OnTestDesktop -Exe'           = "`$msiexec = Join-Path `$env:SystemRoot 'System32\msiexec.exe'`n`$run = Start-OnTestDesktop -Exe `$msiexec -Arguments @('/i', `$m)"
        'A5 bare msiexec command'               = "msiexec.exe /x `$code /qn"
    }
    foreach ($k in $runShapes.Keys) {
        $f = Invoke-SentinelAudit -Files @{ 'fixture.ps1' = $runShapes[$k] }
        Assert "$k is a run, and unwired it is reported" ($f.Count -eq 1) "(findings: $($f.Count))"
    }

    $mentions = @(
        "# msiexec /i the package, then read it back",
        "Assert 'B1 msiexec installed it (exit 0)' `$true",
        "`$p = Start-Process notepad.exe -ArgumentList 'msiexec.exe'",
        "`$lines = @('    `$p = Start-Process msiexec.exe -ArgumentList `$a -Wait -PassThru')",
        "<# Start-Process msiexec.exe -ArgumentList '/i' #>"
    )
    $i = 0
    foreach ($m in $mentions) {
        $i++
        $s = Get-MsiexecRunSites -Text $m
        Assert "A6.$i a mention that is not a run is not a site" ($s.Count -eq 0) "(sites: $($s -join ','); text: $m)"
    }

    $f = Invoke-SentinelAudit -Files @{ 'wired.ps1' = $wired }
    Assert 'A7 a script carrying the whole sentinel is clean' ($f.Count -eq 0) "($($f -join ' | '))"
    Assert 'A7b ...and the detector does see its run' ((Get-MsiexecRunSites -Text $wired).Count -eq 1)

    foreach ($fn in @('UserInstallSentinel') + $script:SentinelCalls) {
        $broken = if ($fn -eq 'UserInstallSentinel') {
            $wired -replace "(?m)^\. \(Join-Path.*UserInstallSentinel.*$", '# (loader removed)'
        } else {
            $wired -replace [regex]::Escape($fn), "# $fn"
        }
        $f = Invoke-SentinelAudit -Files @{ 'broken.ps1' = $broken }
        $want = if ($fn -eq 'UserInstallSentinel') { 'never dot-sources' } else { "never calls $fn" }
        Assert "A8 dropping $fn is reported by name" ($f.Count -eq 1 -and $f[0] -match [regex]::Escape($want)) "($($f -join ' | '))"
    }

    # -----------------------------------------------------------------------
    "== B: the live tree"
    # -----------------------------------------------------------------------
    $dir = Join-Path $Repo 'test\win32'
    $files = @{}
    foreach ($p in @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File)) {
        if ($p.Name -eq 'msiexec-sentinel-audit.ps1') { continue }
        $files[$p.Name] = [IO.File]::ReadAllText($p.FullName)
    }
    Assert 'B0 the tree was read' ($files.Count -gt 100) "($($files.Count) scripts)"

    $siteFiles = @($files.Keys | Where-Object { (Get-MsiexecRunSites -Text $files[$_]).Count -gt 0 } | Sort-Object)
    "  scripts that run msiexec: $($siteFiles -join ', ')"
    foreach ($k in $script:KnownInstallers) {
        Assert "B1 the detector still sees $k run msiexec" ($siteFiles -contains $k)
    }

    $findings = Invoke-SentinelAudit -Files $files
    foreach ($x in $findings) { "    UNGUARDED $x" }
    Assert 'B2 every script that runs msiexec carries the user-install sentinel' ($findings.Count -eq 0) `
        "($($findings.Count) unguarded)"

    if ($NegativeControl) {
        # -------------------------------------------------------------------
        "== N: NEGATIVE CONTROL - the installers with their sentinel stripped"
        # -------------------------------------------------------------------
        $stripped = @{}
        foreach ($k in $siteFiles) {
            $t = $files[$k]
            foreach ($fn in $script:SentinelCalls) { $t = $t -replace [regex]::Escape($fn), "Removed-$fn" }
            $stripped[$k] = $t
        }
        $nf = Invoke-SentinelAudit -Files $stripped
        Assert 'N1 stripped installers go unreported (inverted)' ($nf.Count -eq 0) `
            "($($nf.Count) reported, and $($siteFiles.Count) is the healthy answer)"
    }
    Complete-TestBody
}
catch {
    # Scored in place (not through Assert) so body-complete-audit reads the
    # arm as scoring a failure: its rule is textual by design.
    "  FAIL the run finished its sections (threw: $($_.Exception.Message))"
    $script:failures++
    $_.ScriptStackTrace
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
