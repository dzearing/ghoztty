# ViewerExtTableAudit.ps1 - the analyzer behind test\win32\viewer-ext-tables.ps1 (T1581).
#
# THE RULE: the viewer answers two questions from a file extension, and Mac and
# Windows must answer them identically:
#
#   * mimeType          - the Content-Type a served resource goes out with
#                         (Mac ViewerView.mimeType(forExtension:), Windows
#                         viewer_content.mimeType).
#   * highlightLanguage - the highlight.js language a source file colorizes as
#                         (Mac ViewerView.highlightLanguage(forExtension:),
#                         Windows viewer_content.highlightLanguage).
#
# Both Zig functions carry a doc comment calling their table byte-identical with
# Mac's. Until this audit nobody enforced it: T1183 added ten image rows to the
# Zig table alone on 2026-09-05 and the drift survived until T750 read both
# files by hand on 2026-09-15.
#
# Each table is reduced to the same shape - an ordered map ext -> value plus
# the fallback the function returns for anything else - so the comparison does
# not care that Swift writes `case "a", "b": return "x"` and Zig writes one
# `.{ "a", "x" }` tuple per extension.
#
# ASCII only (PS 5.1 reads a BOM-less script as ANSI).

function Remove-ExtTableComment {
    # Drop a trailing `//` comment that sits outside a string literal. Both
    # languages use `//`, and a MIME value never contains one.
    param([AllowEmptyString()][string]$Line)
    $inStr = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq '\' -and $inStr) { $i++; continue }
        if ($c -eq '"') { $inStr = -not $inStr; continue }
        if (-not $inStr -and $c -eq '/' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '/') {
            return $Line.Substring(0, $i)
        }
    }
    return $Line
}

function New-ExtTable {
    return [pscustomobject]@{
        Found    = $false
        Rows     = @()      # set from a List when the parse finishes
        Fallback = $null      # string, or '<nil>' for Swift nil / Zig null
        Line     = 0          # 1-based line of the function header
    }
}

function Get-SwiftExtTable {
    # The `switch ext` table of `static func <Func>(forExtension` in Swift.
    # Rows: Ext, Value, Line. A case returning nil records '<nil>'.
    param(
        [Parameter(Mandatory)][string]$Func,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines
    )
    $t = New-ExtTable
    $start = -1
    $hdr = 'static\s+func\s+' + [regex]::Escape($Func) + '\s*\(\s*forExtension\b'
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ((Remove-ExtTableComment $Lines[$i]) -match $hdr) { $start = $i; break }
    }
    if ($start -lt 0) { return $t }
    $t.Found = $true
    $rows = New-Object System.Collections.Generic.List[object]
    $t.Line = $start + 1
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        $s = Remove-ExtTableComment $Lines[$i]
        if ($s -match '^\s*default\s*:\s*return\s+(?:"([^"]*)"|(nil))\s*$') {
            if ($Matches[2]) { $t.Fallback = '<nil>' } else { $t.Fallback = $Matches[1] }
            break
        }
        if ($s -match '^\s*case\s+(.+?)\s*:\s*return\s+(?:"([^"]*)"|(nil))\s*$') {
            $val = if ($Matches[3]) { '<nil>' } else { $Matches[2] }
            foreach ($m in [regex]::Matches($Matches[1], '"([^"]*)"')) {
                $rows.Add([pscustomobject]@{ Ext = $m.Groups[1].Value; Value = $val; Line = $i + 1 })
            }
            continue
        }
        # A `func` header before `default:` means the switch ended without one.
        if ($s -match '^\s*(?:private\s+|public\s+|internal\s+)?(?:static\s+)?func\s') { break }
    }
    $t.Rows = $rows.ToArray()
    return $t
}

function Get-ZigExtTable {
    # The `const table = .{ ... };` of `pub fn <Func>(ext` in Zig, plus the
    # function's final `return`. Rows: Ext, Value, Line.
    param(
        [Parameter(Mandatory)][string]$Func,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines
    )
    $t = New-ExtTable
    $start = -1
    $hdr = '^\s*(?:pub\s+)?fn\s+' + [regex]::Escape($Func) + '\s*\('
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ((Remove-ExtTableComment $Lines[$i]) -match $hdr) { $start = $i; break }
    }
    if ($start -lt 0) { return $t }
    $t.Found = $true
    $rows = New-Object System.Collections.Generic.List[object]
    $t.Line = $start + 1
    $inTable = $false
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        $s = Remove-ExtTableComment $Lines[$i]
        if (-not $inTable -and $s -match '^\s*const\s+table\s*=\s*\.\{') { $inTable = $true }
        if ($inTable) {
            foreach ($m in [regex]::Matches($s, '\.\{\s*"([^"]*)"\s*,\s*"([^"]*)"\s*\}')) {
                $rows.Add([pscustomobject]@{ Ext = $m.Groups[1].Value; Value = $m.Groups[2].Value; Line = $i + 1 })
            }
            if ($s -match '^\s*\}\s*;') { $inTable = $false }
            continue
        }
        if ($s -match '^\s*return\s+(?:"([^"]*)"|(null))\s*;') {
            if ($Matches[2]) { $t.Fallback = '<nil>' } else { $t.Fallback = $Matches[1] }
        }
        if ($s -match '^\}') { break }   # the function's closing brace (column 0)
    }
    $t.Rows = $rows.ToArray()
    return $t
}

function Get-ExtTableDrift {
    # Compare two tables. Returns one row per disagreement:
    #   Kind = 'mac-only' | 'win-only' | 'value' | 'fallback' | 'dup-mac' | 'dup-win'
    # Ext compares case-insensitively (the Zig lookup is eqlIgnoreCase, the Mac
    # caller lowercases first); values compare byte-exactly.
    param(
        [Parameter(Mandatory)]$Mac,
        [Parameter(Mandatory)]$Win
    )
    $out = New-Object System.Collections.Generic.List[object]
    $macMap = @{}; $winMap = @{}
    foreach ($r in $Mac.Rows) {
        $k = $r.Ext.ToLowerInvariant()
        if ($macMap.ContainsKey($k)) { $out.Add([pscustomobject]@{ Kind = 'dup-mac'; Ext = $k; Mac = $r.Value; Win = $null }) }
        else { $macMap[$k] = $r.Value }
    }
    foreach ($r in $Win.Rows) {
        $k = $r.Ext.ToLowerInvariant()
        if ($winMap.ContainsKey($k)) { $out.Add([pscustomobject]@{ Kind = 'dup-win'; Ext = $k; Mac = $null; Win = $r.Value }) }
        else { $winMap[$k] = $r.Value }
    }
    foreach ($r in $Mac.Rows) {
        $k = $r.Ext.ToLowerInvariant()
        if (-not $winMap.ContainsKey($k)) {
            if (@($out | Where-Object { $_.Kind -eq 'mac-only' -and $_.Ext -eq $k }).Count -eq 0) {
                $out.Add([pscustomobject]@{ Kind = 'mac-only'; Ext = $k; Mac = $macMap[$k]; Win = $null })
            }
        } elseif ($winMap[$k] -cne $macMap[$k]) {
            if (@($out | Where-Object { $_.Kind -eq 'value' -and $_.Ext -eq $k }).Count -eq 0) {
                $out.Add([pscustomobject]@{ Kind = 'value'; Ext = $k; Mac = $macMap[$k]; Win = $winMap[$k] })
            }
        }
    }
    foreach ($r in $Win.Rows) {
        $k = $r.Ext.ToLowerInvariant()
        if (-not $macMap.ContainsKey($k)) {
            if (@($out | Where-Object { $_.Kind -eq 'win-only' -and $_.Ext -eq $k }).Count -eq 0) {
                $out.Add([pscustomobject]@{ Kind = 'win-only'; Ext = $k; Mac = $null; Win = $winMap[$k] })
            }
        }
    }
    if ($Mac.Fallback -cne $Win.Fallback) {
        $out.Add([pscustomobject]@{ Kind = 'fallback'; Ext = '*'; Mac = $Mac.Fallback; Win = $Win.Fallback })
    }
    # Not `return ,` - an empty array returned that way counts as one element
    # at an @() call site, which would be a phantom drift row.
    return $out.ToArray()
}
