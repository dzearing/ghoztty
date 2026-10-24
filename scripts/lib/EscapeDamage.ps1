# EscapeDamage.ps1 - what a backslash escape interpreted on the way into a
# file looks like, shared by the commit-time scanner
# (scripts\control-char-scan.ps1, T1231) and the write-time hook
# (scripts\hooks\deny-escape-damage.ps1, T1263) so the two can never disagree
# about what counts.
#
# The writer, found in T1263: the tool-call channel itself. A Claude Code Edit
# or Write whose JSON arguments carry a Windows path with ONE backslash has
# that backslash decoded as an escape before the tool ever sees the text -
# `zig-out\bin` arrives as `zig-out<0x08>in`, `test\win32\agent-x.ps1` as
# `test\win32<0x07>gent-x.ps1`, `scripts\floor-lane.ps1` as
# `scripts<0x0c>loor-lane.ps1`. The session transcripts show the decoded byte
# already sitting in the tool INPUT, beside correctly doubled backslashes in the
# same string, so no script on this box is involved and none can be fixed.
#
# The same decode turns `\r` into a carriage return and `\t` into a tab
# (`test\win32\translucent-window.stamp.json` arrives as
# `test\win32<TAB>ranslucent-window.stamp.json`). Those two are legitimate
# characters on their own, so they count only in the shape the decode leaves:
#   lone-cr      a CR that is not the first half of a CRLF
#   tab-in-path  a tab glued between path segments - right after `\segment`
#                with a letter following, or right before `segment\`
# `\n` decodes to a line break, which no byte-level check can tell from a
# real one; it is the one member of the family left to review.
#
# Dot-source it; it defines functions and $EscapeDamage* variables only.

# Extensions whose files are prose or code, and therefore have no business
# holding a control character. Keep this tight: every extension added here is a
# promise that no legitimate file of that kind carries one. The extensionless
# libghostty fuzz corpora are out of scope by construction.
$EscapeDamageExtensions = @(
    '.md', '.ps1', '.psm1', '.psd1', '.zig', '.json', '.sh', '.bash',
    '.yml', '.yaml', '.txt', '.bat', '.cmd', '.toml', '.css', '.js', '.html',
    '.swift', '.c', '.h', '.py'
)

# Below 0x20 except tab, LF and CR, plus DEL: a text file never holds these.
$EscapeDamageBadChars = [char[]](@(0..8) + @(11, 12) + @(14..31) + @(127) | ForEach-Object { [char]$_ })

$EscapeDamagePattern = [regex]('\r(?!\n)' +
    '|(?<=\\[A-Za-z0-9_.\-]{1,64})\t(?=[A-Za-z])' +
    '|(?<=[A-Za-z0-9_\-])\t(?=[a-z][A-Za-z0-9_.\-]{0,63}\\[A-Za-z0-9_])')

function Test-EscapeDamageExtension([string]$Path) {
    if (-not $Path) { return $false }
    return ($EscapeDamageExtensions -contains [System.IO.Path]::GetExtension($Path).ToLowerInvariant())
}

# Every finding in $Text as { Index; Line; Col; Code; Kind }, in text order.
# The common case (no hit) is one native IndexOfAny pass plus one regex pass.
function Find-EscapeDamage([string]$Text) {
    $hits = New-Object System.Collections.Generic.List[object]
    if (-not $Text) { return ,$hits }

    $i = $Text.IndexOfAny($EscapeDamageBadChars)
    while ($i -ge 0) {
        $hits.Add([pscustomobject]@{ Index = $i; Kind = 'control' })
        $i = if ($i + 1 -lt $Text.Length) { $Text.IndexOfAny($EscapeDamageBadChars, $i + 1) } else { -1 }
    }
    foreach ($m in $EscapeDamagePattern.Matches($Text)) {
        $kind = if ($m.Value -eq "`r") { 'lone-cr' } else { 'tab-in-path' }
        $hits.Add([pscustomobject]@{ Index = $m.Index; Kind = $kind })
    }
    if ($hits.Count -eq 0) { return ,$hits }

    $sorted = @($hits | Sort-Object Index)
    $out = New-Object System.Collections.Generic.List[object]
    $line = 1; $lineStart = 0; $pos = 0
    foreach ($h in $sorted) {
        while ($pos -lt $h.Index) {
            if ($Text[$pos] -eq "`n") { $line++; $lineStart = $pos + 1 }
            $pos++
        }
        $out.Add([pscustomobject]@{
            Index = $h.Index
            Line  = $line
            Col   = $h.Index - $lineStart + 1
            Code  = '0x{0:x2}' -f [int]$Text[$h.Index]
            Kind  = $h.Kind
        })
    }
    return ,$out
}

# The finding's surroundings with the invisible byte made visible, for a
# message a reader can act on without opening the file.
function Format-EscapeDamageContext([string]$Text, [int]$Index, [int]$Radius = 24) {
    $start = [Math]::Max(0, $Index - $Radius)
    $end = [Math]::Min($Text.Length, $Index + $Radius + 1)
    $sb = New-Object System.Text.StringBuilder
    for ($k = $start; $k -lt $end; $k++) {
        $c = $Text[$k]
        if ($c -eq "`n") { [void]$sb.Append(' ') }
        elseif ([int]$c -lt 32 -or [int]$c -eq 127) { [void]$sb.Append(('<0x{0:x2}>' -f [int]$c)) }
        else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}
