# RadiusTableAudit.ps1 - the analyzer behind test\win32\radius-table-audit.ps1 (T1399).
#
# THE RULE: docs\design\win32-design-system.md section 3.1 is the corner-radius
# scale, and each of its rows names - in a Source column - the constants in
# src\apprt\win32\ that draw at that radius. The table and the code are checked
# against each other in both directions:
#
#   * every named constant exists and holds the row's value, and
#   * every corner-radius constant in the win32 tree is named by some row (or
#     declared as an exception by the harness, with its reason).
#
# Why: the table said 8 DIP for the banner and TOC cards while every card on
# screen drew at 14 (Mac's GlassCard.cornerRadius), and nothing noticed for two
# months, because the table was prose nobody executed.
#
# What counts as a CORNER-RADIUS DECLARATION: a `const` (pub or not) whose name
# carries radius/RADIUS/corner/CORNER and whose value is a bare numeric literal,
# outside comments, strings and `test` blocks. Names that are blur or glow
# radii, ellipse factors or vtable slots are not corners and are skipped:
# glow / shadow / blur / sheen / rim / blade / slot_.
#
# ASCII only (PS 5.1 reads a BOM-less script as ANSI).

. (Join-Path $PSScriptRoot 'TypeRampAudit.ps1')   # Remove-TypeRampNoise

$script:RadiusDeclPattern = '^\s*(?:pub\s+)?const\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[a-z0-9]+)?\s*=\s*(-?[0-9]+(?:\.[0-9]+)?)\s*;'
$script:RadiusNamePattern = '(?i)(radius|corner)'
$script:RadiusSkipPattern = '(?i)(glow|shadow|blur|sheen|rim|blade|slot_)'

function Get-RadiusTable {
    # The rows of section 3.1's table. Each: Value (DIP, 0 for full bleed),
    # Label (the Applies-to text), Refs (backticked module.Name tokens in the
    # Source column), Line (1-based).
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    $rows = New-Object System.Collections.Generic.List[object]
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^###\s+3\.1\s+Corner radius') { $start = $i; break }
    }
    if ($start -lt 0) { return @() }
    $inTable = $false
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l -match '^#') { break }
        if ($l -match '^\s*\|') {
            $inTable = $true
            $cells = @($l.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            if ($cells.Count -lt 2) { continue }
            $v = $null
            if ($cells[0] -match '^\*\*([0-9]+(?:\.[0-9]+)?)(?:\s*DIP)?\*\*$') { $v = [double]$Matches[1] }
            if ($null -eq $v) { continue }   # header or separator
            $refs = @()
            if ($cells.Count -ge 3) {
                $refs = @([regex]::Matches($cells[2], '`([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*)`') |
                        ForEach-Object { $_.Groups[1].Value })
            }
            $rows.Add([pscustomobject]@{ Value = $v; Label = $cells[1]; Refs = $refs; Line = $i + 1 })
        } elseif ($inTable) {
            break
        }
    }
    return $rows.ToArray()
}

function Get-RadiusDecls {
    # Corner-radius declarations in one .zig file. -Text supplies the lines
    # directly (fixtures); -Module names the file's module (its basename).
    param(
        [Parameter(Mandatory)][string]$Module,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Text
    )
    $out = New-Object System.Collections.Generic.List[object]
    $inTest = $false; $depth = 0
    for ($i = 0; $i -lt $Text.Count; $i++) {
        $s = Remove-TypeRampNoise $Text[$i]
        if (-not $inTest -and $Text[$i] -match '^\s*test\b') { $inTest = $true; $depth = 0 }
        if ($inTest) {
            $depth += ([regex]::Matches($s, '\{')).Count - ([regex]::Matches($s, '\}')).Count
            if ($depth -le 0 -and $s -match '\}') { $inTest = $false }
            continue
        }
        if ($s -notmatch $script:RadiusDeclPattern) { continue }
        $name = $Matches[1]; $value = [double]$Matches[2]
        if ($name -notmatch $script:RadiusNamePattern) { continue }
        if ($name -match $script:RadiusSkipPattern) { continue }
        $out.Add([pscustomobject]@{ Module = $Module; Name = $name; Ref = "$Module.$name"
                Value = $value; Line = $i + 1 })
    }
    return $out.ToArray()
}

function Get-RadiusSweep {
    # Every .zig file directly under $Root (the win32 frontend is flat).
    param([Parameter(Mandatory)][string]$Root)
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Filter '*.zig' -File | Sort-Object Name)) {
        $text = [System.IO.File]::ReadAllLines($f.FullName)
        foreach ($d in @(Get-RadiusDecls -Module $f.BaseName -Text $text)) { $all.Add($d) }
    }
    return $all.ToArray()
}

function Get-RadiusMismatches {
    # The table-to-code direction: one finding per Source ref that does not
    # resolve to exactly one declaration holding the row's value.
    #   missing     no corner-radius declaration by that name in that module
    #   ambiguous   more than one (the ref cannot say which)
    #   value       found, at a different value than the row's
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Decls)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        foreach ($ref in $r.Refs) {
            $hits = @($Decls | Where-Object { $_.Ref -ceq $ref })
            if ($hits.Count -eq 0) {
                $out.Add([pscustomobject]@{ Ref = $ref; Kind = 'missing'; Row = $r.Value; Actual = $null })
            } elseif ($hits.Count -gt 1) {
                $out.Add([pscustomobject]@{ Ref = $ref; Kind = 'ambiguous'; Row = $r.Value; Actual = $hits.Count })
            } elseif ($hits[0].Value -ne $r.Value) {
                $out.Add([pscustomobject]@{ Ref = $ref; Kind = 'value'; Row = $r.Value; Actual = $hits[0].Value })
            }
        }
    }
    return $out.ToArray()
}

function Get-RadiusUnnamed {
    # The code-to-table direction: declarations no row names.
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Decls)
    $named = @($Rows | ForEach-Object { $_.Refs } | Where-Object { $_ })
    return @($Decls | Where-Object { $named -cnotcontains $_.Ref })
}
