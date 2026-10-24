# PixelOracleAudit (T1281) - find the pixel probes that score an AGGREGATE over
# a whole capture, where the capture holds the subject AND something else.
#
# THE DEFECT (T1115): test-desktop-spike.ps1 asked "does PrintWindow return the
# real window?" by walking every 4th pixel of the WHOLE window, taking the mean
# luminance and the distinct-colour count, and requiring both to be high. The
# terminal surface is dark by design and fills most of the window, so "light
# chrome over a flat, uncomposed client area" scores about the same as "the
# whole window captured" - the two outcomes the assertion existed to tell
# apart. It read green for a month, then flipped red with no behaviour change
# when the chrome shrank relative to the surface. T363 was the same class a day
# earlier (chrome colour scored against a literal rather than the chrome).
#
# The remedy that worked was to score BY REGION, and keep a second region as
# the in-script positive control. An aggregate is not wrong in itself: a mean,
# a count or a colour set over a region that contains only its subject is a
# fine oracle, and so is one whose claim is genuinely about the whole capture
# ("the capture is not blank"). What nothing in the source says is which of the
# two a walk means, so every whole-capture walk that aggregates has to say it:
#
#   * `# pixel-region: <reason>` (or `// pixel-region: <reason>` inside an
#     embedded C# here-string) on the walk's first line or one of the two lines
#     above it, naming why the whole capture is the right region for the claim.
#     A marker with no reason exempts nothing.
#   * or the walk is bounded to a region - a band, a box, a half - in which
#     case it is not a finding at all.
#
# WHAT IS A WHOLE-CAPTURE WALK - text-based, because half of these walks live
# in C# here-strings the PowerShell parser never sees. Two nested `for` loops
# (PowerShell or C#), the outer and the inner each spanning a FULL axis:
#
#   start  a small literal (0-8), or an origin (`$shot.Left`, `.Top`, `.X`,
#          `.Y`, `rect.left`...), optionally plus a small literal;
#   bound  an expression naming a full dimension - `.Width`/`.Height`,
#          `w`/`h`/`W`/`H`, a name ending in `Width`/`Height`/`W`/`H`
#          (`WinW`, `bmpHeight`), or an origin plus one of those - and not
#          narrowed: no `/` or `*`, and nothing subtracted but a literal
#          margin (`$h - 2` is the whole axis; `$h - $bandH` is a region).
#
# and the inner body ACCUMULATES - a `+=`, a `++` (outside the loop headers),
# an `.Add(`, or an indexed write like `$hist[$k] = ...`. A walk that only
# reads (a search that breaks on the first hit, a copy into a buffer) is not
# scored here.
#
# KINDS: `whole-capture` (hard, feeds the ratchet) and `unbalanced` (a walk
# whose braces never close, so its body could not be read - held at zero).

Set-StrictMode -Off

function Get-PixelOracleRelativePath([string]$Path, [string]$Repo) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($Repo).TrimEnd('\') + '\'
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }
    return $Path
}

function Test-PixelOracleExempt($Lines, [int]$LineNumber) {
    foreach ($n in @($LineNumber, ($LineNumber - 1), ($LineNumber - 2))) {
        if ($n -lt 1 -or $n -gt $Lines.Count) { continue }
        if ($Lines[$n - 1] -match '(#|//)\s*pixel-region:\s*\S') { return $true }
    }
    return $false
}

# A full dimension: a `.Width`/`.Height` member, a bare `w`/`h`, or a name
# ending in Width/Height. Not any name ending in h - `$bandH` is a band.
$script:PIXEL_DIM = '(?i)(\.(width|height)\b|^\$?[wh]$|^\$?\w*(width|height)$)'

# The analyzer's own harness carries every shape above as fixture text inside
# here-strings, which this text-based reader treats as code on purpose (the
# T1115 walk lived in a C# here-string). It is the one file the sweep skips.
$script:PIXEL_ORACLE_SELF = 'pixel-oracle-audit.ps1'

function Test-PixelOracleFullStart([string]$Expr) {
    $e = ($Expr -replace '\s+', '')
    if ($e -match '^\d+$') { return ([int]$e -le 8) }
    # origin, optionally + a small literal
    $e = $e -replace '\+\d+$', ''
    $e = $e.Trim('(', ')')
    return ($e -match '(?i)^\$?[\w\.]*\.(left|top|x|y)$' -or $e -match '(?i)^\$?(left|top)$')
}

function Test-PixelOracleFullBound([string]$Expr) {
    $e = ($Expr -replace '\s+', '')
    $e = $e.TrimEnd(')') -replace '^\(+', ''
    if ($e -match '[/\*%]') { return $false }
    # a literal margin may be subtracted; a variable may not
    if ($e -match '-(?!\d+$)') { return $false }
    $e = $e -replace '-\d+$', ''
    # origin + dimension, or a dimension alone
    $terms = @($e -split '\+')
    $dims = @($terms | Where-Object { $_ -match $script:PIXEL_DIM })
    if ($dims.Count -ne 1) { return $false }
    foreach ($t in $terms) {
        if ($t -match $script:PIXEL_DIM) { continue }
        if ($t -match '^\d+$') { continue }
        if ($t -match '(?i)^\$?[\w\.]*\.(left|top|x|y)$' -or $t -match '(?i)^\$?(left|top)$') { continue }
        return $false
    }
    return $true
}

# The text the walk detector reads: same length and line breaks as the source,
# with string literals and comments blanked to spaces, so a brace or a `for`
# inside either cannot be mistaken for code and every offset still maps back
# to its line.
function ConvertTo-PixelOracleCode([string[]]$Lines) {
    # one pass over the whole text: whichever of a string or a comment starts
    # first wins, so a `#` inside a string is not read as a comment
    return [regex]::Replace(($Lines -join "`n"), '"[^"\n]*"|''[^''\n]*''|(?m)(?:^|(?<=[ \t]))(?:#|//)[^\n]*', {
            param($m)
            $v = $m.Value
            if ($v[0] -eq '"' -or $v[0] -eq "'") { return [string]$v[0] + (' ' * ($v.Length - 2)) + [string]$v[0] }
            return (' ' * $v.Length)
        })
}

function Get-PixelOracleLineOf([string]$Code, [int]$Pos) {
    return ($Code.Substring(0, $Pos) -split "`n").Count
}

# Index of the bracket closing the one at $Open, or -1.
function Get-PixelOracleClose([string]$Code, [int]$Open, [char]$O, [char]$C) {
    $depth = 0
    for ($p = $Open; $p -lt $Code.Length; $p++) {
        $ch = $Code[$p]
        if ($ch -eq $O) { $depth++ }
        elseif ($ch -eq $C) { $depth--; if ($depth -eq 0) { return $p } }
    }
    return -1
}

# Every `for (init; cond; step)` header in the code: its offsets, the loop
# variable, the start and bound expressions, and where its body begins/ends.
# A body is a `{...}` block or, brace-less, one statement - which may itself be
# another `for`, the C# one-line nest `for (...) for (...) Paint(...);`.
function Get-PixelOracleLoops([string]$Code) {
    $loops = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Code, '\bfor\s*\(')) {
        $open = $m.Index + $m.Length - 1
        $close = Get-PixelOracleClose $Code $open '(' ')'
        if ($close -lt 0) { continue }
        $parts = $Code.Substring($open + 1, $close - $open - 1) -split ';'
        if ($parts.Count -ne 3) { continue }
        $init = [regex]::Match($parts[0], '^\s*(?:int\s+|var\s+|\[int\]\s*)?\$?(?<v>\w+)\s*=\s*(?<start>.+?)\s*$')
        $cond = [regex]::Match($parts[1], '^\s*\$?\w+\s*(?:-lt|-le|<=|<)\s*(?<bound>.+?)\s*$')
        if (-not ($init.Success -and $cond.Success)) { continue }
        [void]$loops.Add([pscustomobject]@{
            At        = $m.Index
            HeadEnd   = $close
            Var       = $init.Groups['v'].Value
            Start     = $init.Groups['start'].Value
            Bound     = $cond.Groups['bound'].Value
            BodyStart = -1
            BodyEnd   = -1
        })
    }
    return , $loops.ToArray()
}

# Where a loop's body begins and ends, computed on demand (a body scan is the
# expensive part, and only full-axis loops need one). A brace-less body that is
# itself a `for` ends where that loop's body does.
function Set-PixelOracleBody([string]$Code, $Loop, [hashtable]$ByAt) {
    if ($Loop.BodyStart -ge 0) { return }
    $p = $Loop.HeadEnd + 1
    while ($p -lt $Code.Length -and [char]::IsWhiteSpace($Code[$p])) { $p++ }
    if ($p -ge $Code.Length) { return }
    $Loop.BodyStart = $p
    if ($Code[$p] -eq '{') {
        $Loop.BodyEnd = Get-PixelOracleClose $Code $p '{' '}'
    } elseif ($ByAt.ContainsKey($p)) {
        $nested = $ByAt[$p]
        Set-PixelOracleBody $Code $nested $ByAt
        $Loop.BodyEnd = $nested.BodyEnd
    } else {
        $Loop.BodyEnd = $Code.IndexOf(';', $p)
    }
}

function Get-PixelOracleFindings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Text
    )
    $lines = @($Text)
    $out = New-Object System.Collections.ArrayList
    # cheap pre-filter: no loop header, or no axis-sized bound, means no walk
    $raw = $lines -join "`n"
    if ($raw -notmatch '\bfor\s*\(' -or $raw -notmatch '(?i)(width|height|<\s*\$?[wh]\b|-l[te]\s+\$[wh]\b)') { return , $out.ToArray() }
    $code = ConvertTo-PixelOracleCode $lines

    $loops = Get-PixelOracleLoops $code
    $full = @($loops | Where-Object { (Test-PixelOracleFullStart $_.Start) -and (Test-PixelOracleFullBound $_.Bound) })
    $byAt = @{}
    foreach ($l in $loops) { $byAt[$l.At] = $l }
    foreach ($l in $full) { Set-PixelOracleBody $code $l $byAt }
    $claimed = @{}
    foreach ($o in $full) {
        if ($claimed.ContainsKey($o.At)) { continue }
        $line = Get-PixelOracleLineOf $code $o.At
        if ($o.BodyEnd -lt 0) {
            [void]$out.Add([pscustomobject]@{ Path = $Path; Line = $line; Kind = 'unbalanced'; Detail = 'a full-axis loop whose body never closes' })
            continue
        }
        $inner = @($full | Where-Object { $_.At -gt $o.HeadEnd -and $_.At -le $o.BodyEnd } | Select-Object -First 1)
        if ($inner.Count -eq 0) { continue }
        $inl = $inner[0]
        $claimed[$inl.At] = $true
        if ($inl.BodyEnd -lt 0) { continue }
        # the inner body, with every loop header in it blanked so a step's own
        # `++` is not read as an accumulation
        $body = $code.Substring($inl.BodyStart, $inl.BodyEnd - $inl.BodyStart + 1)
        foreach ($h in @($loops | Where-Object { $_.At -ge $inl.BodyStart -and $_.HeadEnd -le $inl.BodyEnd })) {
            $off = $h.At - $inl.BodyStart
            $len = $h.HeadEnd - $h.At + 1
            $body = $body.Substring(0, $off) + (' ' * $len) + $body.Substring($off + $len)
        }
        $acc = $null
        $m = [regex]::Match($body, '[^\n;{}]*(\+=|\+\+|\.Add\()[^\n;{}]*')
        if ($m.Success) { $acc = $m.Value.Trim() }
        if ($null -eq $acc) {
            foreach ($w in [regex]::Matches($body, '[^\n;{}]*\$?\w+\[(?<ix>[^\]]+)\]\s*=(?!=)[^\n;{}]*')) {
                # a write indexed by BOTH loop variables is a copy into a
                # buffer, not an accumulation
                $ix = $w.Groups['ix'].Value
                $vo = '\b' + [regex]::Escape($o.Var) + '\b'
                $vi = '\b' + [regex]::Escape($inl.Var) + '\b'
                if ($ix -match $vo -and $ix -match $vi) { continue }
                $acc = $w.Value.Trim(); break
            }
        }
        if ($null -eq $acc) { continue }
        if (Test-PixelOracleExempt $lines $line) { continue }
        [void]$out.Add([pscustomobject]@{
            Path   = $Path
            Line   = $line
            Kind   = 'whole-capture'
            Detail = "for $($o.Var) < $($o.Bound.Trim()) / for $($inl.Var) < $($inl.Bound.Trim()), accumulates: $acc"
        })
    }
    return , $out.ToArray()
}

function Get-PixelOracleSweep {
    param([Parameter(Mandatory = $true)][string[]]$Roots)
    $all = New-Object System.Collections.ArrayList
    foreach ($r in $Roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $r -Filter *.ps1 -File -Recurse)) {
            if ($file.Name -eq $script:PIXEL_ORACLE_SELF) { continue }
            $text = @(Get-Content -LiteralPath $file.FullName)
            foreach ($x in (Get-PixelOracleFindings -Path $file.FullName -Text $text)) { [void]$all.Add($x) }
        }
    }
    return , $all.ToArray()
}

# The ratchet comparison, as a function so the teeth can feed it a sweep with a
# planted file in it and require it to score red.
function Compare-PixelOracleBaseline {
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
