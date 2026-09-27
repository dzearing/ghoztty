<#
.SYNOPSIS
    Recognize a torn zig-cache entry in a red lane's log and delete exactly
    that entry, so the lane can be retried once instead of reported as a code
    failure (T494).

.DESCRIPTION
    A half-written cache file (a crash or power blip mid-write) makes the
    compiler choke on garbage: the observed case was a 2036-byte options.zig of
    ZEROS under .zig-cache\c\<hash>\, failing the `none` lane with
    "error: expected type expression, found 'invalid token'" as if the change
    under test were red. The signature is recognizable -- a compile `error:`
    whose FILE LOCATION sits inside a zig cache directory -- because the code
    this repo compiles never lives there; only generated/cached artifacts do.

    A torn entry does not always get NAMED by an `error:` line, which is what
    T973 cost a turn: after the 2026-08-18 reboot a truncated build_options
    `options.zig` under `.zig-cache\c\<hash>\` failed the win32 and agent lanes
    with `error: root source file struct 'options' has no member named
    'app_version'` pointing at intact `src\build\Config.zig`, and named the
    cache only sideways -- on the compiler's `note: struct declared here` line.
    Two more shapes are therefore recognized, both narrower than the
    unconditional error-line rule, because a note only LOCATES a declaration;
    it does not assert that the content there is wrong:

      * a DECLARATION note (`note: struct declared here` and friends) whose
        location is inside a cache entry -- the compiler saying the thing the
        source expected lives in generated content that does not have it;
      * ANY cache-resolving line, error or note, whose file fails an on-disk
        integrity check (missing, empty, zero-filled, or not newline
        terminated -- the shapes a half-written file actually takes).

    Notes that merely pass THROUGH intact generated code (`note: called at
    comptime here`) still heal nothing, so a genuine compile error keeps its
    diagnosis. The cost ceiling is unchanged either way: a wrong heal deletes a
    regenerable entry and the lane fails again on the retry, which the caller
    reports as final.

    Detection and healing are split so the caller (floor-lane.ps1) can decide
    the retry policy and a test can drive the functions against planted logs:

      Get-TornCacheEntry        log -> the cache entry dir(s) blamed, or none
      Get-CacheCorruptionWarning log -> the non-fatal "Invalid timestamp in
                                cache entry ... error.Overflow" lines, which
                                corroborate a torn cache but name no entry
      Test-CacheFileIntact      one cached file -> does it look whole on disk
      Get-TornPackage           global cache -> fetched packages that look
                                half-extracted, asked WITHOUT a failing build
      Invoke-CacheHeal          delete the named entries, loudly
      Invoke-TornCacheRepair    red build log -> detect + corroborate + heal,
                                and say whether a retry is warranted (T998)
      Invoke-ZigBuildHealed     run one zig command, and on a red result that
                                a torn cache explains, heal and re-run ONCE

    The last two exist because the policy used to live in floor-lane.ps1
    alone (T998), so only the four floor lanes ever got the recognize-delete-
    retry treatment. The staging build in launch-upgrade.ps1, the acceptance
    harnesses' own rebuild (test\win32\lib\BuildFresh.ps1, TestClient.ps1) and
    a hand-run build (scripts\zig-build.ps1) hit exactly the same half-written
    entry and reported it as red code. Every build path now calls one of these
    two, so the diagnosis is paid once, here.

    A THIRD shape is a torn FETCHED PACKAGE rather than a torn generated file
    (T1436). On 2026-09-07 every build and all four floor lanes died at once on

      error: failed to check cache: 'D:\zig-global-cache\p\N-V-__8A...\fonts\ttf\JetBrainsMono-Regular.ttf' file_hash FileNotFound

    -- the package directory held two text files and a few macOS AppleDouble
    sidecars, and the `fonts/` tree the message names was simply gone. Nothing
    here saw it: the line carries no `:line:col:`, so the compile-error rule
    above never matched it, and the unit of repair is a directory under `p\`
    whose name is a package hash rather than a hex digest, which
    Resolve-CachePath refused. Both are handled now -- the `failed to check
    cache:` line is parsed on its own terms, and `p\<package-hash>` is a
    recognized entry shape, deleted whole so the next build re-fetches it.

    Safety over eagerness: an entry is only ever named when the path resolves
    to <cache-root>\<single-letter-bucket>\<hash>, and Invoke-CacheHeal
    re-verifies that shape before deleting. A mis-parsed compiler line can
    therefore never aim the delete at source, and a genuine compile error in
    generated-but-correct cache content simply fails again on the retry, which
    the caller reports as final.

    And the delete has to be able to WIN, which it could not until T1499: the
    real torn package on this box held AppleDouble sidecars including a file
    named `._.`, which defeats `Remove-Item -Recurse -Force` outright -- the
    name resolves to the directory itself, the delete reports it missing, and
    the non-empty parent is then refused. The heal printed FAILED, returned 0,
    and every lane re-ran into the same failure until a human deleted it by
    hand with a `\\?\` path. `Remove-TreeHard` (scripts\lib\HardDelete.ps1) is
    that hand-delete as code, and Invoke-CacheHeal names which attempt it took.
#>

. (Join-Path $PSScriptRoot 'HardDelete.ps1')

# Dropped inside a cache entry whose delete could not finish, so the
# half-removed state has a tell of its own (T1499). Without it a partial
# delete is INVISIBLE to the integrity scan: on 2026-09-12 the failed heal had
# already removed the `._fonts` sidecar, which was the only thing
# Get-TornPackage could see, and `build-cache.ps1 check` then called the still
# broken cache clean. The marker dies with the entry the moment a later delete
# succeeds, so it cannot go stale.
function Get-CacheHealFailedMarkerName { return '.ghoztty-heal-failed' }

function Get-TornCacheEntry {
    <#
    .SYNOPSIS
        Cache entries a red lane's log blames for compile errors.
    .OUTPUTS
        One object per distinct entry: Entry (the directory or file to delete),
        File (the corrupt file the compiler named), Reason (which rule fired),
        Line (the log line, as evidence). Empty when the errors point at real
        source, i.e. almost always.
    #>
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$GlobalCacheDir
    )
    if (-not (Test-Path $LogPath)) { return @() }
    $seen = @{}
    $out = @()
    foreach ($line in @(Get-Content $LogPath -ErrorAction SilentlyContinue)) {
        # T1436: a torn FETCHED PACKAGE is reported by the cache layer, not by
        # the compiler, so it carries no `:line:col:` and the rule below never
        # sees it. The quoted path is a file zig expected to find inside a
        # package it had already extracted; the unit of repair is the package.
        # This is unconditional for the same reason `error-in-cache` is: zig
        # only says this about content it owns, and the path still has to
        # resolve INSIDE a cache before anything is named.
        if ($line -match "failed to check cache:\s*'(?<path>[^']+)'\s*(?<field>\S+)\s+(?<why>\S+)") {
            $file = $matches['path'] -replace '/', '\'
            $resolved = Resolve-CachePath -FilePath $file -RepoPath $RepoPath -GlobalCacheDir $GlobalCacheDir
            if (-not $resolved) { continue }
            $key = $resolved.Entry.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $out += [pscustomobject]@{
                Entry  = $resolved.Entry
                File   = $file
                Reason = 'torn-package'
                Line   = $line.Trim()
            }
            continue
        }
        if ($line -notmatch '(?<path>\S[^\s:]*(?::\\[^\s:]*)?):\d+:\d+:\s*(?<kind>error|note):\s*(?<msg>.*)$') { continue }
        $file = $matches['path'] -replace '/', '\'
        $kind = $matches['kind']
        $msg = $matches['msg']
        $resolved = Resolve-CachePath -FilePath $file -RepoPath $RepoPath -GlobalCacheDir $GlobalCacheDir
        if (-not $resolved) { continue }

        # Why this line is allowed to delete something. An `error:` INSIDE a
        # cache stays unconditional (T494): the code this repo compiles never
        # lives there. A `note:` needs more, since a note only points at where
        # something was declared -- either it is a declaration note (the
        # generated content is what the source expected, and does not match),
        # or the named file is demonstrably torn on disk.
        $reason = $null
        if ($kind -eq 'error') {
            $reason = 'error-in-cache'
        }
        elseif (-not (Test-CacheFileIntact -Path $resolved.FullPath)) {
            $reason = 'corrupt-on-disk'
        }
        elseif ($msg -match '^(?:\S+\s+){0,3}declared here\s*$') {
            $reason = 'declared-in-cache'
        }
        if (-not $reason) { continue }

        $key = $resolved.Entry.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $out += [pscustomobject]@{
            Entry  = $resolved.Entry
            File   = $file
            Reason = $reason
            Line   = $line.Trim()
        }
    }
    # Plain return, no comma: callers wrap in @(). A `, $out` here makes an
    # EMPTY result count as one item at an @() call site (the inner array
    # becomes the element), which read as a phantom detection in testing.
    return $out
}

function Test-CacheFileIntact {
    <#
    .SYNOPSIS
        Does a file the compiler named inside a cache entry look whole?
    .DESCRIPTION
        False for the shapes a half-written file actually takes on this box:
        gone, empty, zero-filled (T494's was a 2036-byte options.zig of pure
        NULs), or not newline terminated -- every generated source zig writes
        ends in a newline, so a missing one means the write stopped early.
        TRUE is the safe answer whenever the file cannot be judged (too large
        to be a generated source, unreadable), because it is a $false here
        that licenses a delete.
    #>
    param([Parameter(Mandatory)][string]$Path)
    return ($null -eq (Get-CacheFileDefect -Path $Path))
}

function Get-CacheFileDefect {
    <#
    .SYNOPSIS
        Which torn shape a cached file has, or $null when it looks whole.
    .DESCRIPTION
        The reasoned form of Test-CacheFileIntact (which is defined as "this
        returns $null"), so a sweep can say WHY it deleted something rather
        than only that it did: 'missing', 'empty', 'nul-bytes' or
        'no-trailing-newline'. $null whenever the file cannot be judged.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    try { $info = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $null }
    if ($info.Length -eq 0) { return 'empty' }
    # Generated sources are kilobytes. Anything huge is not something whose
    # bytes we should be judging, so leave it alone.
    if ($info.Length -gt 8MB) { return $null }
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return $null }
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { return 'nul-bytes' }
    if ($bytes[$bytes.Length - 1] -ne 10) { return 'no-trailing-newline' }
    return $null
}

function Get-TornGeneratedEntry {
    <#
    .SYNOPSIS
        Generated-source cache entries (`<cache>\c\<hash>\`) holding a torn
        file, asked of the cache itself rather than of a red build (T999).
    .DESCRIPTION
        Both torn-cache incidents (2026-08-05, 2026-08-18) followed a hard
        reboot: NTFS handed back an options.zig whose tail was zeros or simply
        missing, and nothing looked until a lane went red minutes later with a
        compile error that read as broken code. Get-TornCacheEntry catches that
        AFTER the fact from the build log; this is the same judgement
        (Get-CacheFileDefect) made BEFORE any build, so the first build after a
        reboot starts from a cache somebody has looked at.

        Only the `c` bucket is scanned. It is where zig writes the generated
        SOURCES (build_options' options.zig, both observed tears), every file
        in it is text that ends in a newline, and it is small - a few hundred
        files - so reading all of it costs milliseconds. `o\` holds binaries,
        where NUL bytes are normal, and `p\` has its own smoke alarm
        (Get-TornPackage).

        A file written in the last -MinAgeSeconds is skipped: a torn file left
        by a shutdown is by definition older than the boot that followed it,
        and a file that recent could be one another window's build is writing
        right now. Missing one costs nothing that Get-TornCacheEntry does not
        already cover; a false positive costs regenerating one entry.
    .OUTPUTS
        One object per torn entry: Entry (the hash directory), File, Reason
        ('torn-generated'), Detail (the defect), Line (evidence for
        Invoke-CacheHeal's `blamed by:` line).
    #>
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [int]$MinAgeSeconds = 120,
        [int]$MaxReported = 50
    )
    $out = @()
    $cdir = Join-Path $CacheDir 'c'
    if (-not (Test-Path -LiteralPath $cdir -PathType Container)) { return $out }
    $cutoff = [DateTime]::UtcNow.AddSeconds(-$MinAgeSeconds)
    $dirs = @()
    try { $dirs = @([System.IO.Directory]::EnumerateDirectories($cdir)) } catch { return $out }
    foreach ($d in $dirs) {
        if ((Split-Path -Leaf $d) -notmatch '^[0-9a-fA-F]{16,64}$') { continue }
        $files = @()
        try { $files = @([System.IO.Directory]::EnumerateFiles($d, '*', [System.IO.SearchOption]::AllDirectories)) }
        catch { continue }
        foreach ($f in $files) {
            try { if ([System.IO.File]::GetLastWriteTimeUtc($f) -gt $cutoff) { continue } } catch { continue }
            $defect = Get-CacheFileDefect -Path $f
            if (-not $defect) { continue }
            $out += [pscustomobject]@{
                Entry  = $d
                File   = $f
                Reason = 'torn-generated'
                Detail = $defect
                Line   = "cache scan: $f is $defect"
            }
            break
        }
        if ($out.Count -ge $MaxReported) { break }
    }
    return $out
}

function Test-PackageEntryName {
    <#
    .SYNOPSIS
        Is this directory name a zig PACKAGE hash (the `p\` bucket's entries)?
    .DESCRIPTION
        Two shapes exist, both copied verbatim into build.zig.zon by `zig fetch`:

          libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs
          N-V-__8AAIC5lwAVPJJzxnCAahSvZTIlG-HhtOvnM1uh-66x     (anonymous)

        Both END in a base64url digest of at least 40 characters, and that is
        the discriminator: the last 40 characters of the name must be pure
        base64url ([A-Za-z0-9_-]) with no dot in them, the whole name must
        look like a package hash ([A-Za-z0-9_.-]), and it must contain a
        hyphen, which every one of these does. Splitting on the last hyphen
        instead does NOT work and was the first attempt -- base64url uses `-`
        as a digit, so the anonymous hash above ends `...-66x`.

        Deliberately strict, because the whole point of a shape test is that
        a mis-parsed path cannot aim a recursive delete at something that is
        not regenerable. It rejects the set-aside copies this box makes by
        hand (`<hash>.torn-20260907` puts a dot inside the final 40), scratch
        directories like `tmp`, short names, and anything carrying a path
        separator.
    #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -match '[\\/]') { return $false }
    if ($Name.Length -lt 40) { return $false }
    if ($Name -notmatch '-') { return $false }
    if ($Name -notmatch '^[A-Za-z0-9_.\-]+$') { return $false }
    return ($Name.Substring($Name.Length - 40) -match '^[A-Za-z0-9_\-]{40}$')
}

function Get-TornPackage {
    <#
    .SYNOPSIS
        Fetched packages that look half-extracted, asked of the cache itself.
    .DESCRIPTION
        The other half of T1436: a torn package is SILENT until a build needs
        the file that went missing, so `go-loop-exec claim` reported
        "build cache ok: 1025.8 GB free, 1474 entries" minutes before every
        lane on the box went red. That check counts entries and free space; it
        never asks whether any of them is whole.

        Whole is not cheaply decidable -- the honest answer is re-hashing the
        tree, which is minutes for 1500 packages -- so this asks the two
        questions that are O(one non-recursive listing) per package and that
        the observed tear answers YES to:

          * EMPTY: the package directory exists and holds nothing. An
            extraction that produced no files at all.
          * ORPHAN SIDECAR: a macOS AppleDouble `._<name>` with no companion
            `<name>` beside it. That is exactly what was left on 2026-09-07 --
            `._fonts` survived and the whole `fonts/` tree it describes did
            not -- and a sidecar without its file cannot be a correct
            extraction of any archive. `._.` is exempt: it describes the
            archive's own root, names no sibling, and ships intact in three
            of this box's packages.

        It is a smoke alarm, not a proof: a package torn in a way that leaves
        neither tell reads as fine here and is still caught by
        Get-TornCacheEntry the moment a build trips over it. Missing one costs
        nothing that was not already covered; a false positive would cost a
        re-fetch, which is why both rules describe states that cannot occur in
        a correct extraction.
    .OUTPUTS
        One object per suspect package: Entry (the directory), Reason, Detail.
    #>
    param(
        [Parameter(Mandatory)][string]$GlobalCacheDir,
        # Belt and braces for a cache far larger than this box's: stop after
        # this many suspects rather than building an unbounded report.
        [int]$MaxReported = 20
    )
    $out = @()
    $pdir = Join-Path $GlobalCacheDir 'p'
    if (-not (Test-Path -LiteralPath $pdir -PathType Container)) { return $out }
    $dirs = @()
    try { $dirs = @([System.IO.Directory]::EnumerateDirectories($pdir)) } catch { return $out }
    foreach ($d in $dirs) {
        $name = Split-Path -Leaf $d
        if (-not (Test-PackageEntryName -Name $name)) { continue }
        $names = @()
        try { foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($d)) { $names += (Split-Path -Leaf $e) } }
        catch { continue }
        $marker = Get-CacheHealFailedMarkerName
        if ($names -contains $marker) {
            # A heal already tried and could not finish here (T1499). Nothing
            # else about this directory can be trusted, and the state is
            # otherwise invisible: the partial delete on 2026-09-12 had removed
            # the one sidecar the orphan rule below could see.
            $out += [pscustomobject]@{
                Entry  = $d
                Reason = 'heal-failed'
                Detail = "a previous cache heal could not delete this entry ('$marker' is still here)"
            }
        }
        elseif ($names.Count -eq 0) {
            $out += [pscustomobject]@{ Entry = $d; Reason = 'empty-package'; Detail = 'directory holds no entries' }
        }
        else {
            $have = @{}
            foreach ($n in $names) { $have[$n.ToLowerInvariant()] = $true }
            foreach ($n in $names) {
                if ($n.Length -le 2 -or $n.Substring(0, 2) -ne '._') { continue }
                $companion = $n.Substring(2)
                # `._.` is the sidecar for the archive's own root directory and
                # is present in three intact packages on this box, so it names
                # no missing entry. Measured, not assumed: the first run of this
                # scan over the live cache reported exactly those three.
                if ($companion -eq '.' -or $companion -eq '..') { continue }
                if (-not $have.ContainsKey($companion.ToLowerInvariant())) {
                    $out += [pscustomobject]@{
                        Entry  = $d
                        Reason = 'orphan-sidecar'
                        Detail = "'$n' has no companion '$companion'"
                    }
                    break
                }
            }
        }
        if ($out.Count -ge $MaxReported) { break }
    }
    return $out
}

function Resolve-CachePath {
    <#
    .SYNOPSIS
        The deletable cache entry a named file belongs to, plus its full path.
    .DESCRIPTION
        Zig caches are laid out <root>\<bucket>\<hash>...: bucket is a single
        letter ('c' compiler-generated sources, 'o' outputs, 'z' the ZIR
        store), hash is the entry's hex digest. Two shapes exist and both are
        one unit of deletion:

          <root>\<bucket>\<hash>\<file...>   the hash DIRECTORY is deleted --
              removing only the corrupt file would leave the entry's manifest
              saying the entry is intact;
          <root>\<bucket>\<hash>             the hash FILE is the entry itself
              (the /z ZIR store keeps one file per hash), so it is deleted.

        Bucket-letter and hash are both required, so nothing that is not
        hash-addressed content can ever be named. The `p` bucket (fetched
        dependencies) is hash-addressed too, but by a PACKAGE hash rather than
        a hex digest -- `libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs`
        or the anonymous `N-V-__8AAIC5lwAVPJJzxnCAahSvZTIlG-HhtOvnM1uh-66x`,
        both verbatim from build.zig.zon -- so it gets its own shape test
        (Test-PackageEntryName). Deleting a package directory costs a re-fetch
        and nothing else.
    .OUTPUTS
        @{ Entry; FullPath } or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$GlobalCacheDir
    )
    $full = $FilePath
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path $RepoPath $full }
    try { $full = [System.IO.Path]::GetFullPath($full) } catch { return $null }

    $parts = $full -split '\\'
    $rootIdx = -1
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -ieq '.zig-cache') { $rootIdx = $i; break }
    }
    if ($rootIdx -lt 0 -and $GlobalCacheDir) {
        $gc = $GlobalCacheDir.TrimEnd('\')
        if ($full.Length -gt $gc.Length -and
            $full.Substring(0, $gc.Length + 1) -ieq ($gc + '\')) {
            $rootIdx = ($gc -split '\\').Count - 1
        }
    }
    if ($rootIdx -lt 0) { return $null }

    # Need at least <root>\<bucket>\<hash> below the root.
    if ($parts.Count -lt $rootIdx + 3) { return $null }
    if ($parts[$rootIdx + 1] -notmatch '^[a-z]$') { return $null }
    if ($parts[$rootIdx + 1] -ceq 'p') {
        if (-not (Test-PackageEntryName -Name $parts[$rootIdx + 2])) { return $null }
    }
    elseif ($parts[$rootIdx + 2] -notmatch '^[0-9a-fA-F]{16,64}$') { return $null }
    return [pscustomobject]@{
        Entry    = ($parts[0..($rootIdx + 2)] -join '\')
        FullPath = $full
    }
}

function Resolve-CacheEntryDir {
    <#
    .SYNOPSIS
        The deletable cache entry a corrupt file belongs to, or $null.
    .DESCRIPTION
        The Entry half of Resolve-CachePath, kept as its own name because that
        is what callers outside this file ask for.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$GlobalCacheDir
    )
    $r = Resolve-CachePath -FilePath $FilePath -RepoPath $RepoPath -GlobalCacheDir $GlobalCacheDir
    if (-not $r) { return $null }
    return $r.Entry
}

function Get-CacheCorruptionWarning {
    <#
    .SYNOPSIS
        The non-fatal corruption signature: overflowed cache timestamps.
    .DESCRIPTION
        "Invalid timestamp in cache entry: 999... err=error.Overflow" is the
        same torn cache seen from a lane that survived it. It names no entry,
        so it corroborates a heal decision rather than driving one.
    #>
    param([Parameter(Mandatory)][string]$LogPath)
    if (-not (Test-Path $LogPath)) { return @() }
    return @(Select-String -Path $LogPath -Pattern 'Invalid timestamp in cache entry' `
            -ErrorAction SilentlyContinue | ForEach-Object { $_.Line.Trim() })
}

function Invoke-CacheHeal {
    <#
    .SYNOPSIS
        Delete the torn cache entries, loudly. Returns how many were removed.
    .DESCRIPTION
        Every action prints as a `CACHE HEAL` line naming the entry, the rule
        that fired and the compiler line that blamed it, so a heal can never
        silently hide what happened. The tail-shape re-verification is belt and
        braces on top of Resolve-CachePath: this function refuses anything that
        does not end in \<bucket-letter>\<hex-hash> under a *cache* path.
    #>
    param([Parameter(Mandatory)]$Entries)
    $healed = 0
    foreach ($e in @($Entries)) {
        $dir = [string]$e.Entry
        # <cache>\<bucket>\<hex-hash> for generated content, or
        # <cache>\p\<package-hash> for a fetched dependency (T1436) -- the
        # package name is shape-tested rather than pattern-matched inline, so
        # the two callers cannot drift apart on what a package looks like.
        $shapeOk = $dir -match '(?i)cache[^\\]*\\[a-z]\\[0-9a-f]{16,64}$'
        if (-not $shapeOk -and $dir -match '(?i)cache[^\\]*\\p\\(?<pkg>[^\\]+)$') {
            $shapeOk = Test-PackageEntryName -Name $matches['pkg']
        }
        if (-not $shapeOk) {
            Write-Host "CACHE HEAL REFUSED: '$dir' is not <cache>\<bucket>\<hash>"
            continue
        }
        if (-not (Test-Path $dir)) {
            Write-Host "CACHE HEAL SKIP: $dir is already gone"
            continue
        }
        $why = if ($e.PSObject.Properties['Reason'] -and $e.Reason) { $e.Reason } else { 'error-in-cache' }
        Write-Host "CACHE HEAL: deleting torn cache entry $dir"
        Write-Host "  rule: $why"
        Write-Host "  blamed by: $($e.Line)"
        # Remove-TreeHard, not Remove-Item: a torn package can hold a name
        # (`._.`) that the ordinary delete cannot address at all, and a heal
        # that cannot delete is a heal that does not exist (T1499).
        $r = Remove-TreeHard -Path $dir
        if ($r.Removed) {
            if ($r.Method -ne 'remove-item') {
                Write-Host "  took the $($r.Method) path: $(@($r.Attempts) -join '; ')"
            }
            $healed++
        }
        else {
            Write-Host "  CACHE HEAL FAILED to delete: $($r.Error)"
            foreach ($a in @($r.Attempts)) { Write-Host "    tried $a" }
            Set-CacheHealFailedMarker -Entry $dir
        }
    }
    return $healed
}

function Invoke-TornCacheRepair {
    <#
    .SYNOPSIS
        A red build's log -> heal whatever torn cache entry it blames, and say
        whether one retry is warranted. Returns the number of entries blamed.
    .DESCRIPTION
        The whole T494 decision in one call, so no build path re-implements it
        (T998). Zero means the log blames no cache entry: the failure is the
        code's, and the caller must report it as such without a retry. Anything
        above zero means a retry is warranted even when the delete itself was a
        SKIP (another process healed the entry first) or FAILED (the retry then
        fails again and its verdict is final, which is the cost ceiling T494
        set). The caller owns the "at most once" rule; this function is
        stateless.
    #>
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$GlobalCacheDir,
        # Who is healing, for the one summary line: 'LANE win32', 'staging build'.
        [string]$Label = 'build'
    )
    $torn = @(Get-TornCacheEntry -LogPath $LogPath -RepoPath $RepoPath -GlobalCacheDir $GlobalCacheDir)
    if ($torn.Count -eq 0) { return 0 }
    $warn = @(Get-CacheCorruptionWarning -LogPath $LogPath)
    if ($warn.Count -gt 0) {
        Write-Host "CACHE HEAL corroboration: $($warn.Count) invalid-timestamp warning(s) in the same log"
    }
    $removed = Invoke-CacheHeal -Entries $torn
    Write-Host "$Label healed $removed torn cache entr(y/ies); re-running once (a second FAIL is final)"
    return $torn.Count
}

function Invoke-ZigBuildHealed {
    <#
    .SYNOPSIS
        Run one zig command from $RepoPath; if it fails on a torn cache entry,
        heal it and run the command exactly once more.
    .DESCRIPTION
        For the build paths that are not floor lanes (T998): the acceptance
        harnesses' rebuild, the remote test client, and scripts\zig-build.ps1.
        The launch-upgrade staging build keeps its own cmd.exe redirection and
        calls Invoke-TornCacheRepair directly, for the reason its comment gives.

        Output is captured as strings (never ErrorRecords -- the `2>&1` formatter
        is host-dependent, lib\StderrCaptureAudit) and, with -Stream, echoed as
        it arrives so a long build is not silent. A red first run's output is
        written to a log file because that is the shape the detector reads; the
        path is returned so a caller can point at the evidence.

        -ZigExe exists for the acceptance harness, which drives the heal end to
        end with a stand-in that fails while a planted torn entry exists.
    .OUTPUTS
        ExitCode (the FINAL run's), Output (the final run's, as one string),
        Healed (bool: a heal fired and the command was re-run), FirstLog (the red
        first run's log when a heal fired, else $null).
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$GlobalCacheDir,
        [string]$ZigExe = 'zig',
        [string]$Label = 'build',
        [switch]$Stream
    )
    $ErrorActionPreference = 'Continue'
    if (-not $GlobalCacheDir) { $GlobalCacheDir = $env:ZIG_GLOBAL_CACHE_DIR }

    $runOnce = {
        $lines = New-Object System.Collections.Generic.List[string]
        $code = 1
        Push-Location -LiteralPath $RepoPath
        try {
            & $ZigExe @Arguments 2>&1 | ForEach-Object {
                $s = $_.ToString()
                if ($Stream) { Write-Host $s }
                $lines.Add($s)
            }
            $code = $LASTEXITCODE
        }
        catch {
            $lines.Add("could not run ${ZigExe}: $($_.Exception.Message)")
            $code = 1
        }
        finally { Pop-Location }
        if ($null -eq $code) { $code = 1 }
        return [pscustomobject]@{ ExitCode = [int]$code; Lines = $lines.ToArray() }
    }

    $r = & $runOnce
    $result = [pscustomobject]@{
        ExitCode = $r.ExitCode
        Output   = ($r.Lines -join "`r`n")
        Healed   = $false
        FirstLog = $null
    }
    if ($r.ExitCode -eq 0) { return $result }

    $log = Join-Path ([System.IO.Path]::GetTempPath()) ("zig-build-heal-{0}-{1}.log" -f $PID, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    try { [System.IO.File]::WriteAllLines($log, [string[]]$r.Lines) } catch { return $result }
    $blamed = Invoke-TornCacheRepair -LogPath $log -RepoPath $RepoPath -GlobalCacheDir $GlobalCacheDir -Label $Label
    if ($blamed -eq 0) {
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        return $result
    }
    $r2 = & $runOnce
    $result.ExitCode = $r2.ExitCode
    $result.Output = ($r2.Lines -join "`r`n")
    $result.Healed = $true
    $result.FirstLog = $log
    return $result
}

function Set-CacheHealFailedMarker {
    <#
    .SYNOPSIS
        Leave a tell inside a cache entry whose delete could not finish.
    .DESCRIPTION
        Best effort and deliberately quiet on failure: this runs in the arm of
        a heal that has already failed, and a marker that cannot be written
        must not turn into a second error on top of the first. The value is
        for the NEXT reader -- Get-TornPackage reports the marker, so a
        half-removed package is named by `build-cache.ps1 check` instead of
        counting as a healthy entry.
    #>
    param([Parameter(Mandatory)][string]$Entry)
    try {
        if (-not [System.IO.Directory]::Exists((ConvertTo-ExtendedPath -Path $Entry))) { return }
        $p = ConvertTo-ExtendedPath -Path (Join-Path $Entry (Get-CacheHealFailedMarkerName))
        $when = (Get-Date).ToString('s')
        [System.IO.File]::WriteAllText($p, "cache heal could not delete this entry at $when`r`n")
    }
    catch { }
}
