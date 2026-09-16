# NeuterAudit (T788) - the sixth of the property-audit family, and the first
# whose subject is Zig source rather than a test script.
#
# WHAT A `*_NEUTERED` FLAG IS. Several win32 drawing modules carry a
# compile-time `const T<id>_NEUTERED = false;`. Flipping it to `true` restores
# the behavior that existed before T<id> landed, so the acceptance script that
# claims to measure T<id> can be RUN against a world where T<id> is absent. It
# is a negative control in source form: the only thing that distinguishes an
# assertion which measures the fix from an assertion which would pass either
# way.
#
# THE DEFECT, found twice by hand:
#
#   * T209 - `glyphCentered()` read its flag, was documented, was unit-tested,
#     and NOTHING on a paint path called it. Flipping the flag changed no
#     pixel, so the control adjudicated nothing. Same shape again in T283 with
#     `icon_button.universalHover()`, which T282 had orphaned by moving its
#     call sites onto `lightsFill(glyph)` and leaving the predicate behind,
#     kept alive only by the test that pinned it.
#
#   * T283 - five of the eight flags then in the tree had no pin, so a flag
#     left `true` by an experiment would have SHIPPED, and would have gone red
#     only in an acceptance script somebody remembered to run.
#
# Both are properties of the tree, not facts about a moment, and a property is
# what an analyzer holds. Hence the three findings:
#
#   * `no-consumer` - the flag is referenced only from `test` blocks and its own
#     declaration, or every production reference sits inside a `fn` that
#     nothing outside a test block calls. The reference graph is one hop -
#     flag -> predicate -> call site - which is exactly what `glyphCentered`
#     and `universalHover` needed and what a plain grep for the flag name
#     cannot answer.
#
#   * `unpinned` - no `testing.expect(!<FLAG>)` anywhere in the module, so
#     nothing in the test lane fails when a neutered build is committed.
#
#   * `no-claim` - the declaration's doc comment names no `.ps1` script. The
#     claim list IS the control's contract (T283 finding 3): a flag whose doc
#     comment does not say which script it turns red cannot be audited by a
#     human either, because there is nothing to run.
#
# SCOPE, stated rather than implied. Only `const <NAME>_NEUTERED` declarations
# at column 0 are judged - that is the shape every one of them has, and a flag
# hidden inside a struct would be a different animal needing a different rule.
# What is deliberately NOT checked is whether flipping the flag turns the named
# script red and NOTHING ELSE; that is the measurement, it costs a rebuild and
# a GUI run per flag, and it is what the `measured` line reports rather than
# enforces (see `Get-NeuterMeasured` below).
#
# EXEMPTION. A stated-intent marker waives a flag:
#
#     // neuter-audit: <reason>
#
# on the declaration line or anywhere in its doc comment. A bare marker with no
# reason waives nothing, the same way the other audits in this family treat one.

Set-StrictMode -Off

function Get-NeuterProductionLine {
    <#
      A source line with its comment stripped, or '' if the whole line is one.
      Crude on purpose: zig has no block comments, and a `//` inside a string
      literal in these modules would at worst make the audit MORE conservative
      (a reference it cannot see is a reference it does not count as live).
    #>
    param([string]$Line)

    if ($null -eq $Line) { return '' }
    $t = $Line.TrimStart()
    if ($t.StartsWith('//')) { return '' }
    $i = $Line.IndexOf('//')
    if ($i -ge 0) { return $Line.Substring(0, $i) }
    return $Line
}

function Get-NeuterTopLevelItems {
    <#
      The top-level declarations of a zig-fmt'd file, in order, as
      @{ Kind = 'test'|'fn'|'decl'; Name = <identifier or ''>; Start; End }.

      `End` is the line of the column-0 `}` that closes the item, or the line
      before the next top-level declaration for the single-line `const x = ...;`
      shape. A `test` whose brace never closes in column 0 gets End = -1 so the
      caller can score it rather than silently skipping it.
    #>
    param([string[]]$Lines)

    $items = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        $kind = $null
        $name = ''
        if ($l -match '^test\s*(\"|\{)') {
            $kind = 'test'
            if ($l -match '^test\s+\"([^\"]*)\"') { $name = $Matches[1] }
        }
        elseif ($l -match '^(?:pub\s+)?(?:inline\s+|export\s+|extern\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)') {
            $kind = 'fn'
            $name = $Matches[1]
        }
        elseif ($l -match '^(?:pub\s+)?(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)') {
            $kind = 'decl'
            $name = $Matches[1]
        }
        if (-not $kind) { continue }

        # Where the item ENDS. Two shapes, and getting this wrong is not a
        # cosmetic error: the first draft ended `pub fn applySticky(` at the
        # first line of its body that happened to end in `;`, which put the
        # T249 reference three lines later outside every known item and scored
        # a live flag as `no-consumer`.
        #
        #   * A block opener is a stripped line whose LAST character is `{` -
        #     which is how zig fmt writes every one of them, including the
        #     closing line of a multi-line signature (`) []const i32 {`). Using
        #     "last character" rather than "contains" is what keeps a `"{s}"`
        #     format string out of it. Such an item runs to its column-0 `}`.
        #   * Anything else ends at the first stripped line ending in `;`.
        $end = -1
        $seenOpen = $false
        for ($j = $i; $j -lt $Lines.Count; $j++) {
            $s2 = (Get-NeuterProductionLine $Lines[$j]).TrimEnd()
            if ($seenOpen) {
                if ($Lines[$j] -eq '}' -or $Lines[$j] -match '^\}\s*;\s*$') { $end = $j; break }
            }
            elseif ($s2.EndsWith(';')) { $end = $j; break }
            if ($s2.EndsWith('{')) { $seenOpen = $true; continue }
            # A column-0 declaration reached before either terminator means the
            # scan lost the thread; stop at the line before rather than
            # swallowing the rest of the file.
            if ($j -gt $i -and $Lines[$j] -match '^(?:test\s*[\"\{]|(?:pub\s+)?(?:fn|const|var)\s)') {
                $end = $j - 1; break
            }
        }
        if ($end -lt $i) { $end = $i }
        [void]$items.Add([pscustomobject]@{ Kind = $kind; Name = $name; Start = $i; End = $end })
        if ($end -gt $i) { $i = $end }
    }
    return $items
}

function Get-NeuterItemAt {
    <# The top-level item containing a 0-based line, or $null. #>
    param([object[]]$Items, [int]$Line)

    foreach ($it in @($Items)) {
        $end = if ($it.End -ge 0) { $it.End } else { $it.Start }
        if ($Line -ge $it.Start -and $Line -le $end) { return $it }
    }
    return $null
}

function Get-NeuterDocComment {
    <# The contiguous `///` block immediately above a 0-based line, joined. #>
    param([string[]]$Lines, [int]$Line)

    $out = New-Object System.Collections.ArrayList
    for ($i = $Line - 1; $i -ge 0; $i--) {
        $t = $Lines[$i].TrimStart()
        if ($t.StartsWith('///') -or $t.StartsWith('//')) { [void]$out.Insert(0, $t) }
        else { break }
    }
    return ($out -join "`n")
}

function Test-NeuterWaived {
    <#
      A stated-intent exemption. `// neuter-audit: <reason>` on the declaration
      line or in its doc comment waives the flag; a bare marker with no reason
      waives nothing.
    #>
    param([string]$DeclLine, [string]$Doc)

    foreach ($text in @($DeclLine, $Doc)) {
        if (-not $text) { continue }
        foreach ($m in [regex]::Matches($text, 'neuter-audit:\s*(.*)')) {
            if ($m.Groups[1].Value.Trim().Length -gt 0) { return $true }
        }
    }
    return $false
}

function Get-NeuterMeasured {
    <#
      The optional `Measured <date>` note inside a flag's doc comment, as
      @{ Date = [datetime] or $null; Text = <the sentence> }, or $null when the
      comment carries none.

      REPORTED, NEVER ENFORCED (T788's "consider also"). What it would take to
      enforce is a rebuild and a GUI acceptance run PER FLAG; what it is worth
      as a report is that T283 had to read five task files to learn when each
      control was last actually measured.
    #>
    param([string]$Doc)

    if (-not $Doc) { return $null }
    $m = [regex]::Match($Doc, '(?i)measured\s+(\d{4}-\d{2}-\d{2})')
    if (-not $m.Success) {
        if ($Doc -imatch 'measured') { return [pscustomobject]@{ Date = $null; Text = 'measured (no date)' } }
        return $null
    }
    $d = $null
    try { $d = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $null) } catch { $d = $null }
    return [pscustomobject]@{ Date = $d; Text = $m.Value }
}

function Get-NeuterClaims {
    <# The `.ps1` script names a doc comment mentions, de-duplicated. #>
    param([string]$Doc)

    $out = New-Object System.Collections.ArrayList
    if (-not $Doc) { return $out }
    foreach ($m in [regex]::Matches($Doc, '([A-Za-z0-9_\-\.]+\.ps1)')) {
        $n = $m.Groups[1].Value
        if (-not $out.Contains($n)) { [void]$out.Add($n) }
    }
    return $out
}

$script:NeuterFileCache = @{}

function Get-NeuterProductionText {
    <#
      One file's PRODUCTION text: every line with its comment stripped and
      every top-level `test` block removed, joined back into a single string
      with the declaration line kept at its own index via a parallel line map.

      Cached on path + mtime + length, which is what makes `-TeethCheck`
      affordable: it sweeps the tree seven times, and without the cache six of
      those re-parse 866 unchanged files to learn nothing. Re-parsing only what
      a wound actually touched took that run from over ten minutes to under
      two.
    #>
    param([string]$Path)

    $fi = [System.IO.FileInfo]::new($Path)
    $key = '{0}|{1}|{2}' -f $Path, $fi.LastWriteTimeUtc.Ticks, $fi.Length
    if ($script:NeuterFileCache.ContainsKey($key)) { return $script:NeuterFileCache[$key] }

    $lines = [System.IO.File]::ReadAllLines($Path)
    $items = Get-NeuterTopLevelItems $lines
    $inTest = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($it in @($items)) {
        if ($it.Kind -ne 'test') { continue }
        $end = if ($it.End -ge 0) { $it.End } else { $it.Start }
        for ($k = $it.Start; $k -le $end; $k++) { [void]$inTest.Add($k) }
    }
    $sb = New-Object System.Text.StringBuilder
    $map = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($inTest.Contains($i)) { continue }
        $t = Get-NeuterProductionLine $lines[$i]
        if ($t.Trim().Length -eq 0) { continue }
        [void]$map.Add([pscustomobject]@{ Line = $i; Text = $t })
        [void]$sb.AppendLine($t)
    }
    $row = [pscustomobject]@{ Text = $sb.ToString(); Rows = $map }
    $script:NeuterFileCache[$key] = $row
    return $row
}

function Get-NeuterProductionIndex {
    <#
      For a source root: @{ '<full path>' = <the Get-NeuterProductionText row> }
      for every `.zig` under it. Cheap on a second call over an unchanged tree.
      `-Fresh` is accepted for symmetry with the other sweeps in this family;
      the mtime-keyed cache makes it a no-op rather than a cost.
    #>
    param([string]$Root, [switch]$Fresh)

    $key = (Resolve-Path -LiteralPath $Root).Path
    $index = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $key -Filter *.zig -File -Recurse)) {
        $index[$f.FullName] = Get-NeuterProductionText $f.FullName
    }
    return $index
}

function Test-NeuterSymbolLive {
    <#
      Is `$Name` referenced from production code somewhere under the indexed
      root, other than at its own declaration site (`$DeclPath` line
      `$DeclLine`)?

      This is the one hop that makes the audit worth having. `universalHover`
      was referenced from production code NOWHERE - only from the test that
      pinned it - and a grep for its FLAG could not see that, because the flag
      was referenced from inside the predicate perfectly legitimately.
    #>
    param(
        [string]$Name,
        [hashtable]$Index,
        [string]$DeclPath,
        [int]$DeclLine
    )

    $rx = [regex]("\b" + [regex]::Escape($Name) + "\b")
    foreach ($path in $Index.Keys) {
        $entry = $Index[$path]
        # The whole-file test first: it answers "no" for the ~860 files that
        # never heard of this identifier without walking a single row.
        if (-not $rx.IsMatch($entry.Text)) { continue }
        foreach ($row in $entry.Rows) {
            if ($path -eq $DeclPath -and $row.Line -eq $DeclLine) { continue }
            if ($rx.IsMatch($row.Text)) { return $true }
        }
    }
    return $false
}

function Get-NeuterDeclarations {
    <# Every column-0 `const <NAME>_NEUTERED` in a file. #>
    param([string[]]$Lines)

    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^(?:pub\s+)?const\s+([A-Za-z0-9_]*_NEUTERED)\s*(?::[^=]+)?=') {
            [void]$out.Add([pscustomobject]@{ Name = $Matches[1]; Line = $i })
        }
    }
    return $out
}

function Get-NeuterFindings {
    <#
      The three findings for one file. `$Index` is a production index over the
      whole source root (see Get-NeuterProductionIndex); without one, the
      no-consumer hop is answered from this file alone, which is right for a
      fixture and wrong for the tree.
    #>
    param(
        [string]$Path,
        [string[]]$Lines,
        [hashtable]$Index
    )

    if (-not $Lines) { $Lines = [System.IO.File]::ReadAllLines($Path) }
    if (-not $Index) { $Index = @{ $Path = @() } }

    $items = Get-NeuterTopLevelItems $Lines
    $decls = Get-NeuterDeclarations $Lines
    $findings = New-Object System.Collections.ArrayList

    foreach ($d in @($decls)) {
        $doc = Get-NeuterDocComment $Lines $d.Line
        if (Test-NeuterWaived -DeclLine $Lines[$d.Line] -Doc $doc) { continue }

        $rx = [regex]("\b" + [regex]::Escape($d.Name) + "\b")
        $prodRefItems = New-Object System.Collections.ArrayList
        $pinned = $false
        $pinRx = [regex]("(?:std\.)?testing\.expect\(\s*!\s*" + [regex]::Escape($d.Name) + "\s*\)")

        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($i -eq $d.Line) { continue }
            $text = Get-NeuterProductionLine $Lines[$i]
            if (-not $rx.IsMatch($text)) { continue }
            $owner = Get-NeuterItemAt -Items $items -Line $i
            if ($owner -and $owner.Kind -eq 'test') {
                if ($pinRx.IsMatch($text)) { $pinned = $true }
                continue
            }
            if ($owner) { [void]$prodRefItems.Add($owner) }
        }

        # no-consumer: no production reference at all, or every production
        # reference sits in a `fn` nothing outside a test block calls.
        $live = $false
        $orphans = New-Object System.Collections.ArrayList
        foreach ($owner in @($prodRefItems)) {
            if ($owner.Kind -ne 'fn') { $live = $true; break }
            if (Test-NeuterSymbolLive -Name $owner.Name -Index $Index -DeclPath $Path -DeclLine $owner.Start) {
                $live = $true; break
            }
            if (-not $orphans.Contains($owner.Name)) { [void]$orphans.Add($owner.Name) }
        }
        if (-not $live) {
            $detail = if (@($prodRefItems).Count -eq 0) {
                'referenced only from test blocks'
            } else {
                'only consumer(s) ' + (@($orphans) -join ', ') + ' are called from nothing but tests'
            }
            [void]$findings.Add([pscustomobject]@{
                    Path = $Path; Line = $d.Line + 1; Flag = $d.Name; Kind = 'no-consumer'; Detail = $detail
                })
        }

        if (-not $pinned) {
            [void]$findings.Add([pscustomobject]@{
                    Path = $Path; Line = $d.Line + 1; Flag = $d.Name; Kind = 'unpinned'
                    Detail = "no testing.expect(!$($d.Name)) in this module - a neutered build would ship"
                })
        }

        $claims = @(Get-NeuterClaims $doc)
        if ($claims.Count -eq 0) {
            [void]$findings.Add([pscustomobject]@{
                    Path = $Path; Line = $d.Line + 1; Flag = $d.Name; Kind = 'no-claim'
                    Detail = 'doc comment names no .ps1 script, so there is nothing to run against a flipped flag'
                })
        }
    }
    return $findings
}

function Get-NeuterKinds { return @('no-consumer', 'unpinned', 'no-claim') }

function Get-NeuterSweep {
    <# Every `*_NEUTERED` finding under a source root. #>
    param([string]$Root, [switch]$Fresh)

    $index = Get-NeuterProductionIndex -Root $Root -Fresh:$Fresh
    $all = New-Object System.Collections.ArrayList
    foreach ($path in ($index.Keys | Sort-Object)) {
        if ($index[$path].Text -notlike '*_NEUTERED*') { continue }
        $lines = [System.IO.File]::ReadAllLines($path)
        foreach ($f in @(Get-NeuterFindings -Path $path -Lines $lines -Index $index)) { [void]$all.Add($f) }
    }
    return $all
}

function Get-NeuterInventory {
    <#
      Every flag under a root with its claims and its `Measured` note, for the
      report section. This is the answer T283 had to assemble by reading five
      task files.
    #>
    param([string]$Root, [switch]$Fresh)

    $index = Get-NeuterProductionIndex -Root $Root -Fresh:$Fresh
    $out = New-Object System.Collections.ArrayList
    foreach ($path in ($index.Keys | Sort-Object)) {
        if ($index[$path].Text -notlike '*_NEUTERED*') { continue }
        $lines = [System.IO.File]::ReadAllLines($path)
        foreach ($d in @(Get-NeuterDeclarations $lines)) {
            $doc = Get-NeuterDocComment $lines $d.Line
            [void]$out.Add([pscustomobject]@{
                    Path     = $path
                    Line     = $d.Line + 1
                    Flag     = $d.Name
                    Claims   = @(Get-NeuterClaims $doc)
                    Measured = Get-NeuterMeasured $doc
                    Waived   = (Test-NeuterWaived -DeclLine $lines[$d.Line] -Doc $doc)
                })
        }
    }
    return $out
}

function Get-NeuterRelativePath {
    param([string]$Path, [string]$Repo)
    $p = $Path
    if ($p.StartsWith($Repo, [StringComparison]::OrdinalIgnoreCase)) {
        $p = $p.Substring($Repo.Length).TrimStart('\', '/')
    }
    return ($p -replace '/', '\')
}
