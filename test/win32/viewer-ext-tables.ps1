<#
.SYNOPSIS
    T1581 acceptance - the viewer's extension tables (MIME type and highlight
    language) say the same thing on Mac and Windows.

.DESCRIPTION
    THE DEFECT: viewer_content.mimeType and viewer_content.highlightLanguage
    each carry a doc comment calling their table byte-identical with Mac's
    ViewerView.mimeType(forExtension:) / highlightLanguage(forExtension:), and
    nothing enforced it. T1183 added ten image rows to the Zig table alone on
    2026-09-05; the two platforms served those files differently for ten days,
    until T750 read both files by hand on 2026-09-15.

    This run parses both sides from source (no Swift toolchain needed) and
    holds them together (`lib\ViewerExtTableAudit.ps1` holds the analyzer):

      A. The analyzer against fixtures: Swift `case "a", "b": return "x"`
         rows, `return nil`, `default:`; Zig `.{ "a", "x" }` tuples two to a
         line, comments, the final `return`; every drift kind is reported.

      B. mimeType: Mac and Windows have the same extension set, the same
         value per extension, and the same fallback.

      C. highlightLanguage: the same three checks.

      D. The teeth (T1133): the Swift table as T1183 left it (the ten image
         rows absent) fails B with exactly those ten win-only extensions; a
         changed Zig value, a dropped Zig row and a changed fallback each fail.

      E. The scan is not passing because it recognised nothing: it read the
         tables it exists to judge, at their real sizes.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads two source files, it does not
    # build or run anything.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ViewerExtTableAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function AssertEq([string]$name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red
        $script:fail++
    }
}
function Format-Drift($rows) {
    (@($rows) | ForEach-Object { "$($_.Ext):$($_.Kind)" }) -join ','
}

$swiftPath = Join-Path $Repo 'macos\Sources\Features\Viewer\ViewerView.swift'
$zigPath = Join-Path $Repo 'src\apprt\win32\viewer_content.zig'

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer against fixtures'
# ===========================================================================

$fxSwift = @'
    private static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html"
        // case "old": return "text/old"
        case "png": return "image/png" // trailing comment
        default: return "application/octet-stream"
        }
    }

    private static func lang(forExtension ext: String) -> String? {
        switch ext {
        case "js", "mjs": return "javascript"
        case "zig": return nil
        default: return nil
        }
    }
'@ -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$sm = Get-SwiftExtTable -Func 'mimeType' -Lines $fxSwift
Assert 'A1 the Swift function is found' $sm.Found
AssertEq 'A2 a multi-extension case yields one row per extension; a commented case yields none' 'html=text/html,htm=text/html,png=image/png' ((@($sm.Rows) | ForEach-Object { "$($_.Ext)=$($_.Value)" }) -join ',')
AssertEq 'A3 the Swift default is the fallback' 'application/octet-stream' $sm.Fallback
$sl = Get-SwiftExtTable -Func 'lang' -Lines $fxSwift
AssertEq 'A4 the second function is read on its own, `return nil` reads as <nil>' 'js=javascript,mjs=javascript,zig=<nil>|<nil>' (((@($sl.Rows) | ForEach-Object { "$($_.Ext)=$($_.Value)" }) -join ',') + '|' + $sl.Fallback)
Assert 'A5 an absent Swift function is not found' (-not (Get-SwiftExtTable -Func 'nope' -Lines $fxSwift).Found)

$fxZig = @'
pub fn mimeType(ext: []const u8) []const u8 {
    const table = .{
        .{ "html", "text/html" },      .{ "HTM", "text/html" },
        // .{ "old", "text/old" },
        .{ "png", "image/png" },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}

pub fn lang(ext: []const u8) ?[]const u8 {
    const table = .{
        .{ "js", "javascript" }, .{ "mjs", "javascript" },
    };
    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return null;
}
'@ -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$zm = Get-ZigExtTable -Func 'mimeType' -Lines $fxZig
Assert 'A6 the Zig function is found' $zm.Found
AssertEq 'A7 two tuples on a line are both read; a commented tuple is not' 'html,HTM,png' ((@($zm.Rows) | ForEach-Object { $_.Ext }) -join ',')
AssertEq 'A8 the final return is the fallback, not the inline-for return' 'application/octet-stream' $zm.Fallback
$zl = Get-ZigExtTable -Func 'lang' -Lines $fxZig
AssertEq 'A9 `return null` reads as <nil>, and the second function stops at its own brace' '2|<nil>' ("$(@($zl.Rows).Count)|$($zl.Fallback)")

AssertEq 'A10 the matching fixtures show no drift (extensions compare case-insensitively)' 0 @(Get-ExtTableDrift -Mac $sm -Win $zm).Count
# htm dropped (mac-only), gif added (win-only), png changed (value), html
# twice (dup-win), the fallback changed (fallback).
$fxBad = @'
pub fn mimeType(ext: []const u8) []const u8 {
    const table = .{
        .{ "html", "text/html" },      .{ "gif", "image/gif" },
        .{ "png", "image/x-png" },     .{ "html", "text/html" },
    };
    return "text/plain";
}
'@ -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$bm = Get-ZigExtTable -Func 'mimeType' -Lines $fxBad
$drift = @(Get-ExtTableDrift -Mac $sm -Win $bm)
$kinds = (@($drift | ForEach-Object { $_.Kind }) | Sort-Object -Unique) -join ','
AssertEq "A11 every drift kind is reported ($(Format-Drift $drift))" 'dup-win,fallback,mac-only,value,win-only' $kinds
AssertEq 'A12 the mac-only row is the dropped htm' 'htm' (@($drift | Where-Object { $_.Kind -eq 'mac-only' })[0].Ext)

# ===========================================================================
Write-Host ''
Write-Host '== B: mimeType, Mac against Windows'
# ===========================================================================

$swiftLines = [System.IO.File]::ReadAllLines($swiftPath)
$zigLines = [System.IO.File]::ReadAllLines($zigPath)

$macMime = Get-SwiftExtTable -Func 'mimeType' -Lines $swiftLines
$winMime = Get-ZigExtTable -Func 'mimeType' -Lines $zigLines
Assert "B1 Mac ViewerView.mimeType(forExtension:) is found (line $($macMime.Line))" $macMime.Found
Assert "B2 Windows viewer_content.mimeType is found (line $($winMime.Line))" $winMime.Found
$mimeDrift = @(Get-ExtTableDrift -Mac $macMime -Win $winMime)
foreach ($d in $mimeDrift) {
    Write-Host "    $($d.Ext): $($d.Kind) (mac '$($d.Mac)', win '$($d.Win)')" -ForegroundColor Red
}
AssertEq 'B3 the two mimeType tables agree row for row, value for value, and on the fallback' 0 $mimeDrift.Count
AssertEq 'B4 the fallback is application/octet-stream on both' 'application/octet-stream' $winMime.Fallback

# ===========================================================================
Write-Host ''
Write-Host '== C: highlightLanguage, Mac against Windows'
# ===========================================================================

$macLang = Get-SwiftExtTable -Func 'highlightLanguage' -Lines $swiftLines
$winLang = Get-ZigExtTable -Func 'highlightLanguage' -Lines $zigLines
Assert "C1 Mac ViewerView.highlightLanguage(forExtension:) is found (line $($macLang.Line))" $macLang.Found
Assert "C2 Windows viewer_content.highlightLanguage is found (line $($winLang.Line))" $winLang.Found
$langDrift = @(Get-ExtTableDrift -Mac $macLang -Win $winLang)
foreach ($d in $langDrift) {
    Write-Host "    $($d.Ext): $($d.Kind) (mac '$($d.Mac)', win '$($d.Win)')" -ForegroundColor Red
}
AssertEq 'C3 the two highlightLanguage tables agree row for row, value for value, and on the fallback' 0 $langDrift.Count
AssertEq 'C4 the fallback is plain text (nil / null) on both' '<nil>' $winLang.Fallback

# ===========================================================================
Write-Host ''
Write-Host '== D: the teeth'
# ===========================================================================

# The Swift table as T1183 left it: the image rows it added to the Zig side
# only. Drop exactly those case lines from a copy of the real Swift source.
$t1183 = @('apng', 'jpe', 'jfif', 'avif', 'heic', 'heif', 'tif', 'tiff', 'bmp', 'icns')
$t1183Cases = '^\s*case\s+"(apng|jpe|avif|heic|heif|tif|bmp|icns)"'
$oldSwift = @($swiftLines | Where-Object { $_ -notmatch $t1183Cases })
AssertEq 'D0 the planted copy dropped the eight T1183 case lines (ten extensions)' 8 ($swiftLines.Count - $oldSwift.Count)
$old = @(Get-ExtTableDrift -Mac (Get-SwiftExtTable -Func 'mimeType' -Lines $oldSwift) -Win $winMime)
$oldExts = (@($old | Where-Object { $_.Kind -eq 'win-only' } | ForEach-Object { $_.Ext }) | Sort-Object) -join ','
AssertEq "D1 the 2026-09-05 drift fails B with exactly the ten win-only image extensions ($(Format-Drift $old))" (($t1183 | Sort-Object) -join ',') $oldExts
AssertEq 'D2 ...and with nothing else' 10 $old.Count

$valZig = $zigLines | ForEach-Object { $_ -replace '"wasm", "application/wasm"', '"wasm", "application/octet-stream"' }
$v = @(Get-ExtTableDrift -Mac $macMime -Win (Get-ZigExtTable -Func 'mimeType' -Lines $valZig))
AssertEq 'D3 a changed Zig value (wasm served as octet-stream, the streaming-compile refusal T750 named) fails B as value' 'wasm:value' (Format-Drift $v)

$dropZig = $zigLines | ForEach-Object { $_ -replace '\.\{ "scss", "scss" \},', '' }
$dd = @(Get-ExtTableDrift -Mac $macLang -Win (Get-ZigExtTable -Func 'highlightLanguage' -Lines $dropZig))
AssertEq 'D4 a dropped Zig highlight row fails C as mac-only' 'scss:mac-only' (Format-Drift $dd)

$fbSwift = $swiftLines | ForEach-Object { $_ -replace 'default: return "application/octet-stream"', 'default: return "text/plain"' }
$fb = @(Get-ExtTableDrift -Mac (Get-SwiftExtTable -Func 'mimeType' -Lines $fbSwift) -Win $winMime)
AssertEq 'D5 a changed Mac fallback fails B as fallback' '*:fallback' (Format-Drift $fb)

$addSwift = $swiftLines | ForEach-Object { $_ -replace 'case "vb": return "vbnet"', "case `"vb`": return `"vbnet`"`n        case `"ps1`": return `"powershell`"" }
$addSwift = @($addSwift -split "`n")
$ad = @(Get-ExtTableDrift -Mac (Get-SwiftExtTable -Func 'highlightLanguage' -Lines $addSwift) -Win $winLang)
AssertEq 'D6 a row added on Mac alone (the next main intake) fails C as mac-only' 'ps1:mac-only' (Format-Drift $ad)

# ===========================================================================
Write-Host ''
Write-Host '== E: the scan saw what it judges'
# ===========================================================================

Assert "E1 at least 48 mimeType rows read from Mac ($(@($macMime.Rows).Count))" (@($macMime.Rows).Count -ge 48)
Assert "E2 at least 48 mimeType rows read from Windows ($(@($winMime.Rows).Count))" (@($winMime.Rows).Count -ge 48)
Assert "E3 at least 55 highlightLanguage rows read from Mac ($(@($macLang.Rows).Count))" (@($macLang.Rows).Count -ge 55)
Assert "E4 at least 55 highlightLanguage rows read from Windows ($(@($winLang.Rows).Count))" (@($winLang.Rows).Count -ge 55)
foreach ($want in @('html', 'woff2', 'heic', 'wasm', 'vtt')) {
    Assert "E the mimeType scan judged $want on both sides" (
        @($macMime.Rows | Where-Object { $_.Ext -eq $want }).Count -eq 1 -and
        @($winMime.Rows | Where-Object { $_.Ext -eq $want }).Count -eq 1)
}
foreach ($want in @('js', 'cpp', 'zsh', 'plist', 'wasm')) {
    Assert "E the highlightLanguage scan judged $want on both sides" (
        @($macLang.Rows | Where-Object { $_.Ext -eq $want }).Count -eq 1 -and
        @($winLang.Rows | Where-Object { $_.Ext -eq $want }).Count -eq 1)
}

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard viewer-ext-tables -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'VIEWER EXT TABLES' -MinPass 35
