# DipRoundingAudit (T1020) - find the DIP-to-pixel conversions in the harness
# that round the way PowerShell does instead of the way the app does.
#
# THE DEFECT, measured on this box (PS 5.1):
#
#     [Math]::Round(22.5)                                      -> 22   (banker's)
#     [Math]::Round(22.5, [MidpointRounding]::AwayFromZero)    -> 23   (the app)
#     [int]22.5                                                -> 22   (banker's too)
#
# The layout modules' `px()` is `@intFromFloat(@round(dip * scale))`, and Zig's
# `@round` is half-AWAY-from-zero. A script that converts a DIP length with a
# bare `[Math]::Round($dip * $scale)` (or an `[int]` cast, which rounds the same
# way) measures a pixel the app never drew whenever `dip * scale` lands on .5:
# 4 DIP at 112.5%, every DIP = 2 (mod 4) at 125% (18 DIP -> 22.5), every odd DIP
# at 150%. The ChromeGeometry header says the two agree at 125% and 150%; they
# agree for the constants that file happened to use, not in general.
#
# `test\win32\lib\ChromeGeometry.ps1`'s `Get-TestChromeDip` is the one correct
# conversion. T257 found the bare form in tab-strip.ps1 and tab-color.ps1, T314
# found it again in ipc-machine-chooser.ps1, and every hand sweep was scoped to
# a SUBJECT (the tab strip, the chooser) while the defect is scoped to an IDIOM.
# So this sweeps the idiom.
#
# KINDS (hard - each one fails the ratchet):
#
#   bare-round   `[Math]::Round(x)` with ONE argument, where x is scale-shaped
#                (mentions a *scale* / *dpi* variable, or divides by 96).
#                A two-argument Round with a digit count (`Round($dpi/96, 2)`)
#                is display formatting, not a pixel, and is not a finding; any
#                Round that passes MidpointRounding is correct.
#   int-cast     `[int](x)` where x is scale-shaped arithmetic with no rounding
#                call inside it - the cast rounds half-to-even, same defect.
#   shadow       a `function Get-TestChromeDip` defined anywhere but
#                ChromeGeometry.ps1. Held at zero outright.
#
# INFORMATIONAL (never fails) - `private-dip`: a script that defines its own
# DIP conversion (`function Px`, `function *Dip*`, `$px = { param($dip) ... }`)
# instead of calling Get-TestChromeDip. A correct private copy (one that passes
# MidpointRounding, or uses Floor(x + 0.5)) is right today and is the list a
# future hoist starts from; a WRONG one is already a bare-round finding.
#
# EXEMPTION: `# dip-audit: <reason>` on the line or the line above. A marker
# with no reason exempts nothing. Sites in files we would rather not touch are
# allow-listed in test\win32\dip-rounding-audit.ps1 instead, each with a reason.
#
# THE HALF THIS CANNOT CATCH (T314): a script must not re-derive a number the
# module COMPOSES. `chooser_rows.rowMetrics` builds `text_x` as a sum of six
# individually-rounded terms, so rounding the 68 DIP total is wrong at 112.5% at
# ANY rounding mode (79 composed vs 77 half-away vs 76 banker's). No grep tells
# a composed total from a single constant; the rule is: mirror the module's
# terms, round each one, then add.

Set-StrictMode -Off

# A value is scale-shaped when it mentions a scale or DPI variable, or divides
# by 96 (the DIP-per-inch constant). Deliberately variable-based: `$s` and
# friends are too short to tell from anything else, and a site that slips past
# because its variable is called `$k` is a reason to rename the variable.
$script:DIP_SCALE_SHAPE = '(?i)\$(script:|global:|local:)?\w*(scale|dpi)\w*|/\s*96(\.0+)?\b'

function Get-DipRoundingRelativePath([string]$Path, [string]$Repo) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($Repo).TrimEnd('\') + '\'
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }
    return $Path
}

function Test-DipRoundingExempt($Lines, [int]$LineNumber) {
    # LineNumber is 1-based. The marker counts on the line itself or the one
    # above, and only with a reason after the colon.
    foreach ($n in @($LineNumber, ($LineNumber - 1))) {
        if ($n -lt 1 -or $n -gt $Lines.Count) { continue }
        if ($Lines[$n - 1] -match '#\s*dip-audit:\s*\S') { return $true }
    }
    return $false
}

function Test-DipMathType($TypeExpr) {
    if (-not ($TypeExpr -is [System.Management.Automation.Language.TypeExpressionAst])) { return $false }
    $n = $TypeExpr.TypeName.FullName
    return ($n -ieq 'math' -or $n -ieq 'System.Math')
}

function Get-DipRoundingFindings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        # The file's lines. Passed rather than read so fixtures and the teeth
        # can analyze text that is not on disk.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][AllowEmptyString()][string[]]$Text
    )
    $lines = @($Text)
    $src = $lines -join "`n"
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
    $out = New-Object System.Collections.ArrayList
    if (@($errors).Count -gt 0) {
        [void]$out.Add([pscustomobject]@{ Path = $Path; Line = $errors[0].Extent.StartLineNumber; Kind = 'parse-error'; Detail = $errors[0].Message })
        return , $out.ToArray()
    }
    $isHome = ([System.IO.Path]::GetFileName($Path) -ieq 'ChromeGeometry.ps1')

    # --- bare-round -------------------------------------------------------
    $calls = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $n.Static -and (Test-DipMathType $n.Expression) -and
            $n.Member.Extent.Text -ieq 'Round'
        }, $true)
    foreach ($c in $calls) {
        $cargs = @($c.Arguments)
        if ($cargs.Count -eq 0) { continue }
        if ($c.Extent.Text -match '(?i)MidpointRounding') { continue }
        if ($cargs.Count -ge 2) { continue }   # Round(x, digits): formatting, not a pixel
        $arg = $cargs[0].Extent.Text
        if ($arg -notmatch $script:DIP_SCALE_SHAPE) { continue }
        $ln = $c.Extent.StartLineNumber
        if (Test-DipRoundingExempt $lines $ln) { continue }
        [void]$out.Add([pscustomobject]@{ Path = $Path; Line = $ln; Kind = 'bare-round'; Detail = $c.Extent.Text })
    }

    # --- int-cast ---------------------------------------------------------
    $casts = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and
            ($n.Type.TypeName.FullName -ieq 'int' -or $n.Type.TypeName.FullName -ieq 'int32' -or
                $n.Type.TypeName.FullName -ieq 'System.Int32')
        }, $true)
    foreach ($c in $casts) {
        $child = $c.Child
        if (-not ($child -is [System.Management.Automation.Language.ParenExpressionAst])) { continue }
        $inner = $child.Pipeline.Extent.Text
        if ($inner -notmatch '[*/]') { continue }             # no arithmetic, no rounding
        if ($inner -notmatch $script:DIP_SCALE_SHAPE) { continue }
        if ($inner -match '(?i)::(Round|Floor|Ceiling|Truncate)\s*\(') { continue }   # rounded already
        $ln = $c.Extent.StartLineNumber
        if (Test-DipRoundingExempt $lines $ln) { continue }
        [void]$out.Add([pscustomobject]@{ Path = $Path; Line = $ln; Kind = 'int-cast'; Detail = $c.Extent.Text })
    }

    # --- shadow / private-dip ---------------------------------------------
    $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($f in $fns) {
        if ($isHome) { continue }
        $name = $f.Name
        if ($name -ieq 'Get-TestChromeDip') {
            [void]$out.Add([pscustomobject]@{ Path = $Path; Line = $f.Extent.StartLineNumber; Kind = 'shadow'; Detail = "function $name" })
            continue
        }
        if ($name -imatch '^(Px|Dip|.*-?Dip(ToPx|Px)?|.*ToPx)$') {
            $body = $f.Body.Extent.Text
            if ($body -match 'Get-TestChromeDip') { continue }
            [void]$out.Add([pscustomobject]@{ Path = $Path; Line = $f.Extent.StartLineNumber; Kind = 'private-dip'; Detail = "function $name" })
        }
    }
    $assigns = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -imatch '^\$(script:)?px$' -and
            $n.Right.Extent.Text -match '^\s*\{'
        }, $true)
    foreach ($a in $assigns) {
        if ($isHome) { continue }
        if ($a.Right.Extent.Text -match 'Get-TestChromeDip') { continue }
        [void]$out.Add([pscustomobject]@{ Path = $Path; Line = $a.Extent.StartLineNumber; Kind = 'private-dip'; Detail = '$px = { ... }' })
    }

    return , $out.ToArray()
}

# The kinds that count against the ratchet. private-dip is a list, not a defect.
function Get-DipRoundingHardKinds { return @('bare-round', 'int-cast', 'shadow', 'parse-error') }

function Get-DipRoundingSweep {
    param([Parameter(Mandatory = $true)][string[]]$Roots)
    $all = New-Object System.Collections.ArrayList
    foreach ($r in $Roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $r -Filter *.ps1 -File -Recurse)) {
            $text = @(Get-Content -LiteralPath $file.FullName)
            foreach ($x in (Get-DipRoundingFindings -Path $file.FullName -Text $text)) { [void]$all.Add($x) }
        }
    }
    return , $all.ToArray()
}

# The ratchet comparison, as a function so the teeth can feed it a sweep with a
# planted file in it and require it to score red.
function Compare-DipRoundingBaseline {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Current,
        [Parameter(Mandatory = $true)][hashtable]$Baseline
    )
    $regressed = New-Object System.Collections.ArrayList
    $improved = New-Object System.Collections.ArrayList
    foreach ($k in ($Current.Keys | Sort-Object)) {
        $was = 0
        if ($Baseline.ContainsKey($k)) { $was = $Baseline[$k] }
        if ($Current[$k] -gt $was) { [void]$regressed.Add("$k ($was -> $($Current[$k]))") }
        elseif ($Current[$k] -lt $was) { [void]$improved.Add("$k ($was -> $($Current[$k]))") }
    }
    foreach ($k in ($Baseline.Keys | Sort-Object)) {
        if (-not $Current.ContainsKey($k) -and $Baseline[$k] -gt 0) {
            [void]$improved.Add("$k ($($Baseline[$k]) -> 0)")
        }
    }
    return [pscustomobject]@{ Regressed = $regressed.ToArray(); Improved = $improved.ToArray() }
}
