# TypeRampAudit.ps1 - the analyzer behind test\win32\type-ramp-audit.ps1 (T1389).
#
# THE RULE: a win32 UI module does not write a font height by hand. Text sizes
# come from `src\apprt\win32\type_ramp.zig` (caption / body / subtitle), and a
# size the ramp does not name is either a defect or a DECLARED exception (the
# allowlist in the harness, each entry with its reason).
#
# Why a sweep: T310 counted seven copies of `px(15, scale)` by grep and T313
# retired them; T583 then found an EIGHTH spelled `const FONT_H: f32 = 15.0`
# that the grep walked straight past, on the banner, for three weeks. A count
# is a one-time grep. This is the count, run every time the code changes.
#
# What counts as a FONT-SIZE SITE (comments, strings and `test` blocks are
# ignored):
#
#   createfont  the first argument of a `CreateFontW(` call - the height - when
#               it carries a numeric literal: `-15`, `@round(13.0 * s)`.
#               A height that arrives through a name (`-l.font_h`,
#               `-type_ramp.body(scale).height`) is not judged here; the name's
#               declaration is, below.
#   decl        a declaration or field initializer whose NAME says it is a font
#               size (`FONT_H`, `FONT_PX`, `font_px`, `font_h`,
#               `title_font_dip`, `subtitle_font_h`, ...) and whose value
#               carries a numeric literal.
#
# Kinds:
#
#   off-ramp    a literal size the ramp does not name. HARD.
#   hand-ramp   a literal that happens to equal a ramp size, written by hand
#               instead of read from `type_ramp`. Informational: the number is
#               right today and wrong the day the ramp moves.
#
# The literals 0 and 1 are arithmetic, not sizes (`@max(1, px(w, s))`), and a
# literal that is a `px()`/`@round` SCALE argument is not a size either - only
# a literal in the size position is judged. An expression that names
# `type_ramp` (or a `*ramp*` binding) is derived from the ramp and is clean.
#
# ASCII only (PS 5.1 reads a BOM-less script as ANSI).

function Get-TypeRampSizes {
    # The ramp's own sizes, read out of type_ramp.zig so the audit cannot drift
    # from the module it enforces. Returns the distinct DIP sizes, ascending.
    param([Parameter(Mandatory)][string]$Repo)
    $path = Join-Path $Repo 'src\apprt\win32\type_ramp.zig'
    $sizes = New-Object System.Collections.Generic.List[double]
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        # `leading_dip` is a line-box step, not a text size.
        $m = [regex]::Match($line, '^\s*pub\s+const\s+(?!leading)[a-z_]+_dip\s*:\s*f32\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*;')
        if ($m.Success) {
            $v = [double]$m.Groups[1].Value
            if (-not $sizes.Contains($v)) { $sizes.Add($v) }
        }
    }
    $arr = $sizes.ToArray()
    [Array]::Sort($arr)
    return $arr
}

function Get-TypeRampHardKinds { return @('off-ramp') }

function Test-TypeRampFontName {
    # Does this identifier name a font SIZE? Deliberately narrow: a name has to
    # say "font" and end in a size unit. `title_h` (a layout row) and
    # `glyph_dip` (an icon box) are not font sizes by name, and widening the
    # net to them buries the signal in layout constants.
    param([string]$Name)
    if (-not $Name) { return $false }
    $n = $Name.ToLowerInvariant()
    return [bool]($n -match '(^|_)font(_[a-z0-9]+)*_(h|px|dip|size|height|pt|em)$' -or
        $n -match '^font_?(h|px|dip|size|height|pt|em)$')
}

function Remove-TypeRampNoise {
    # Strip string literals and line comments from one line of Zig, so a size in
    # a comment or a UI string is never a finding.
    param([string]$Line)
    $s = [regex]::Replace($Line, '"(?:[^"\\]|\\.)*"', '""')
    $s = [regex]::Replace($s, "'(?:[^'\\]|\\.)*'", "''")
    $i = $s.IndexOf('//')
    if ($i -ge 0) { $s = $s.Substring(0, $i) }
    return $s
}

function Get-TypeRampSizeLiterals {
    # The numeric literals in SIZE position in an expression. A literal that is
    # the second argument of `px(`/`dip(`-style scaling is a scale, not a size;
    # a literal multiplied by a scale (`13.0 * s`) is a size. Returns doubles.
    param([string]$Expr)
    $out = New-Object System.Collections.Generic.List[double]
    if ($Expr -match 'type_ramp|ramp\b|ramp\.|_ramp') { return $out.ToArray() }
    # Hex, binary and octal literals are flags, not sizes.
    $clean = [regex]::Replace($Expr, '\b0[xbo][0-9a-fA-F_]+\b', ' ')
    # Literals that are a second-or-later argument of a call are not sizes in
    # the shapes this tree uses (`px(15, scale)` keeps its size first).
    foreach ($m in [regex]::Matches($clean, '(?<![A-Za-z_0-9.])([0-9]+(?:\.[0-9]+)?)(?![A-Za-z_0-9])')) {
        $before = $clean.Substring(0, $m.Index)
        # Count unclosed parens and whether the nearest unclosed one has seen a
        # comma since it opened: if so, this literal is not the first argument.
        $depth = 0; $afterComma = $false; $stack = New-Object System.Collections.Generic.List[bool]
        foreach ($ch in $before.ToCharArray()) {
            if ($ch -eq '(') { $stack.Add($false) }
            elseif ($ch -eq ')') { if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) } }
            elseif ($ch -eq ',') { if ($stack.Count -gt 0) { $stack[$stack.Count - 1] = $true } }
        }
        if ($stack.Count -gt 0 -and $stack[$stack.Count - 1]) { continue }
        $v = [double]$m.Groups[1].Value
        if ($v -eq 0 -or $v -eq 1) { continue }
        $out.Add($v)
    }
    return $out.ToArray()
}

function Get-TypeRampFirstArg {
    # The text of the first top-level argument of the call whose '(' is at
    # $Start in $Text (joined lines). Returns $null when the call never closes.
    param([string]$Text, [int]$Start)
    $depth = 0
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '(') { $depth++ ; if ($depth -eq 1) { $begin = $i + 1 } }
        elseif ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { return $Text.Substring($begin, $i - $begin) }
        }
        elseif ($ch -eq ',' -and $depth -eq 1) { return $Text.Substring($begin, $i - $begin) }
    }
    return $null
}

function Get-TypeRampFindings {
    # Findings for one file. -Text supplies the lines directly (fixtures).
    # -IncludeClean also returns the sites that were judged and passed
    # (Kind 'ok'), so a harness can prove the scan SAW them.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Text,
        [double[]]$Ramp = @(12, 14, 20),
        [switch]$IncludeClean
    )
    if (-not $Text) { $Text = [System.IO.File]::ReadAllLines($Path) }
    $results = New-Object System.Collections.Generic.List[object]

    # Pass 1: a cleaned copy with test blocks blanked, one entry per line.
    $clean = New-Object 'string[]' $Text.Count
    $inTest = $false; $depth = 0
    for ($i = 0; $i -lt $Text.Count; $i++) {
        $s = Remove-TypeRampNoise $Text[$i]
        if (-not $inTest -and $Text[$i] -match '^\s*test\b') { $inTest = $true; $depth = 0 }
        if ($inTest) {
            $depth += ([regex]::Matches($s, '\{')).Count - ([regex]::Matches($s, '\}')).Count
            $clean[$i] = ''
            if ($depth -le 0 -and $s -match '\}') { $inTest = $false }
            continue
        }
        $clean[$i] = $s
    }

    $judge = {
        param($lineNo, $site, $name, $expr)
        $expr = ($expr -replace '\s+', ' ').Trim()
        $lits = @(Get-TypeRampSizeLiterals $expr)
        if ($lits.Count -eq 0) {
            if ($IncludeClean) {
                $results.Add([pscustomobject]@{ Path = $Path; Line = $lineNo; Site = $site; Name = $name
                        Kind = 'ok'; Detail = $expr; Values = '' })
            }
            return
        }
        $off = @($lits | Where-Object { $Ramp -notcontains $_ })
        $kind = if ($off.Count -gt 0) { 'off-ramp' } else { 'hand-ramp' }
        $results.Add([pscustomobject]@{ Path = $Path; Line = $lineNo; Site = $site; Name = $name
                Kind = $kind; Detail = $expr; Values = (($lits | ForEach-Object { [string]$_ }) -join ',') })
    }

    for ($i = 0; $i -lt $clean.Count; $i++) {
        $s = $clean[$i]
        if (-not $s) { continue }

        # createfont: join up to 6 lines so a multi-line call's first argument
        # is in reach.
        foreach ($m in [regex]::Matches($s, '\bCreateFontW\s*\(')) {
            if ($s -match '\bfn\s+CreateFontW\b') { continue }
            $joined = ($clean[$i..([Math]::Min($i + 6, $clean.Count - 1))] -join "`n")
            $arg = Get-TypeRampFirstArg -Text $joined -Start ($m.Index + $m.Length - 1)
            if ($null -ne $arg) { & $judge ($i + 1) 'createfont' 'CreateFontW' $arg }
        }

        # decl: `const NAME[: T] = expr;`, `var ...`, `NAME: T = expr,` (a
        # field default) and `.NAME = expr` (a struct-literal field).
        foreach ($m in [regex]::Matches($s,
                '(?:\b(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[^=]+?)?=(?![=>])|(?:^|[\s{,(])\.?([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[A-Za-z0-9_?*\[\]]+\s*)?=(?![=>]))\s*([^;]*)')) {
            $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            if (-not (Test-TypeRampFontName $name)) { continue }
            # Stop the expression at the next top-level field separator.
            $expr = $m.Groups[3].Value
            $d = 0; $cut = $expr.Length
            for ($k = 0; $k -lt $expr.Length; $k++) {
                $ch = $expr[$k]
                if ($ch -eq '(' -or $ch -eq '[' -or $ch -eq '{') { $d++ }
                elseif ($ch -eq ')' -or $ch -eq ']' -or $ch -eq '}') { if ($d -eq 0) { $cut = $k; break }; $d-- }
                elseif ($ch -eq ',' -and $d -eq 0) { $cut = $k; break }
            }
            $expr = $expr.Substring(0, $cut)
            if (-not $expr.Trim()) { continue }
            & $judge ($i + 1) 'decl' $name $expr
        }
    }
    return $results.ToArray()
}

function Get-TypeRampSweep {
    # Every .zig file directly under $Root (the win32 frontend is flat).
    param([Parameter(Mandatory)][string]$Root, [double[]]$Ramp = @(12, 14, 20), [switch]$IncludeClean)
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Filter '*.zig' -File | Sort-Object Name)) {
        foreach ($x in @(Get-TypeRampFindings -Path $f.FullName -Ramp $Ramp -IncludeClean:$IncludeClean)) {
            $all.Add($x)
        }
    }
    return $all.ToArray()
}
