# RingSnapshot.ps1 - read an agent ring snapshot the way the agent's loader does.
#
# Since T997 a session's scrollback on disk is a PAIR: `<id>.ring` (the base,
# rewritten whole now and then) and `<id>.ringlog` (a journal of the bytes that
# arrived since, appended by each snapshot pass). A harness that greps the
# `.ring` file alone would miss everything a pass appended - which is most
# passes - and read a working snapshot as a missing one.
#
# Mirrors `ring_snapshot.zig load`: the journal counts only when it is bound to
# this base (same end offset), records are replayed while they continue the
# stream (an already-covered prefix is dropped), and the first torn record or
# gap ends the replay. The per-record CRC is not re-checked here; a harness
# reads files the agent finished writing.
#
# ASCII only (PS 5.1 reads BOM-less scripts as ANSI).

# Every base snapshot file under $root, as FileInfo. Journals are reached
# through their base, so a session is counted once.
function Get-RingSnapshotFiles([string]$root) {
    return , @(Get-ChildItem -Path $root -Filter '*.ring' -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.ring' })
}

# The reassembled snapshot stream for the base at $basePath: base bytes plus
# the journal's continuation. Empty array when the base is missing or unreadable.
function Read-RingSnapshotBytes([string]$basePath) {
    $raw = $null
    try { $raw = [IO.File]::ReadAllBytes($basePath) } catch { return , [byte[]]@() }
    if ($raw.Length -lt 4) { return , [byte[]]@() }
    $magic = [Text.Encoding]::ASCII.GetString($raw, 0, 4)
    if ($magic -eq 'GRS2') { $hdr = 24 } elseif ($magic -eq 'GRS1') { $hdr = 20 } else { return , [byte[]]@() }
    if ($raw.Length -lt $hdr) { return , [byte[]]@() }
    $baseOffset = [BitConverter]::ToUInt64($raw, 4)
    $out = New-Object System.IO.MemoryStream
    $out.Write($raw, $hdr, $raw.Length - $hdr)
    $end = [uint64]($baseOffset + [uint64]($raw.Length - $hdr))

    $j = $null
    try { $j = [IO.File]::ReadAllBytes($basePath + 'log') } catch { return , $out.ToArray() }
    if ($j.Length -lt 16) { return , $out.ToArray() }
    if ([Text.Encoding]::ASCII.GetString($j, 0, 4) -ne 'GRJ1') { return , $out.ToArray() }
    if ([BitConverter]::ToUInt64($j, 4) -ne $end) { return , $out.ToArray() }
    $pos = 16
    while (($j.Length - $pos) -ge 20) {
        $start = [BitConverter]::ToUInt64($j, $pos)
        $len = [BitConverter]::ToUInt32($j, $pos + 8)
        if (($j.Length - $pos - 20) -lt $len) { break }
        if ($start -gt $end) { break }
        $covered = $end - $start
        if ($covered -lt $len) {
            $out.Write($j, $pos + 20 + [int]$covered, [int]($len - $covered))
            $end = [uint64]($start + $len)
        }
        $pos += 20 + [int]$len
    }
    return , $out.ToArray()
}

function Read-RingSnapshotText([string]$basePath) {
    return [Text.Encoding]::ASCII.GetString((Read-RingSnapshotBytes $basePath))
}

# When the snapshot pair for $basePath was last written: the newer of the base
# and its journal. $null when neither exists.
function Get-RingSnapshotWriteTime([string]$basePath) {
    $t = $null
    foreach ($p in @($basePath, ($basePath + 'log'))) {
        if (Test-Path -LiteralPath $p) {
            $m = (Get-Item -LiteralPath $p).LastWriteTime
            if ($null -eq $t -or $m -gt $t) { $t = $m }
        }
    }
    return $t
}
