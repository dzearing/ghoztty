<#
.SYNOPSIS
    Delete a directory tree that ordinary Windows path resolution cannot
    address, so a cache repair cannot be defeated by a filename (T1499).

.DESCRIPTION
    `Remove-Item -Recurse -Force` is the right first move and it is not
    enough. On 2026-09-12 every floor lane died on a half-extracted zig
    package under `D:\zig-global-cache\p\<hash>` whose macOS AppleDouble
    sidecars included a file literally named `._.`; the cache heal found the
    package, its delete threw

        Could not find file '._.'

    and the tree stayed on disk, so the retry hit the same failure and the box
    stayed red until a human deleted it by hand. The name is the whole
    problem: `.` and `._.`-shaped leaves are normalized as relative path
    segments by the Win32 path parser, so the delete resolves the child to the
    directory it is standing in, reports it missing, and then refuses the
    non-empty parent. Verified on this box: the throw above reproduces on a
    planted `._.` and the extended-path delete below removes the same tree
    whole, nested `._.` entries included.

    `\\?\` paths skip that normalization entirely (they are handed to the
    object manager verbatim), which is why the fallback works. Three attempts,
    in increasing order of rudeness, each reported by name so a repair says
    which one it needed:

      1. `Remove-Item -Recurse -Force` -- the fast, ordinary path, and the one
         that handles read-only content for free.
      2. `[System.IO.Directory]::Delete('\\?\<path>', $true)` -- the fix for
         the AppleDouble shape and for a path over MAX_PATH.
      3. A manual walk over `\\?\` paths that clears ReadOnly/Hidden/System on
         each leaf before deleting it, for a tree whose attributes defeat (2).

    A tree still on disk after all three is REPORTED, never retried silently:
    a partly-removed cache entry is the state callers must be able to see.
#>

function ConvertTo-ExtendedPath {
    <#
    .SYNOPSIS
        The `\\?\`-prefixed form of an absolute path, which Windows hands to
        the object manager without parsing `.`-shaped segments.
    .DESCRIPTION
        Already-prefixed paths are returned unchanged, and a UNC path takes the
        `\\?\UNC\` form rather than a second pair of leading slashes. A
        relative path has no extended form, so it is returned unchanged and the
        caller's ordinary delete keeps whatever behavior it had.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return '\\?\' + $Path
}

function Clear-PathAttribute {
    <#
    .SYNOPSIS
        Drop ReadOnly/Hidden/System from one extended-path leaf, best effort.
    #>
    param([Parameter(Mandatory)][string]$ExtendedPath)
    try {
        $a = [System.IO.File]::GetAttributes($ExtendedPath)
        $mask = [System.IO.FileAttributes]::ReadOnly -bor
                [System.IO.FileAttributes]::Hidden -bor
                [System.IO.FileAttributes]::System
        if ($a -band $mask) {
            [System.IO.File]::SetAttributes($ExtendedPath, ($a -band (-bnot $mask)))
        }
    }
    catch { }
}

function Remove-TreeExtendedWalk {
    <#
    .SYNOPSIS
        Attempt 3: recurse over `\\?\` paths, clearing attributes as we go.
    .DESCRIPTION
        A directory reparse point is deleted as the link it is, never followed:
        following one would take the delete outside the tree it was asked to
        remove.
    #>
    param([Parameter(Mandatory)][string]$ExtendedDir)
    $isDir = $false
    try { $isDir = [System.IO.Directory]::Exists($ExtendedDir) } catch { }
    if (-not $isDir) {
        Clear-PathAttribute -ExtendedPath $ExtendedDir
        [System.IO.File]::Delete($ExtendedDir)
        return
    }
    $reparse = $false
    try {
        $a = [System.IO.File]::GetAttributes($ExtendedDir)
        $reparse = [bool]($a -band [System.IO.FileAttributes]::ReparsePoint)
    }
    catch { }
    if (-not $reparse) {
        foreach ($child in @([System.IO.Directory]::EnumerateFileSystemEntries($ExtendedDir))) {
            Remove-TreeExtendedWalk -ExtendedDir $child
        }
    }
    Clear-PathAttribute -ExtendedPath $ExtendedDir
    [System.IO.Directory]::Delete($ExtendedDir, $false)
}

function Remove-TreeHard {
    <#
    .SYNOPSIS
        Delete a file or directory tree whole, surviving names and attributes
        that defeat `Remove-Item`.
    .OUTPUTS
        Removed  $true when nothing is left on disk
        Method   'remove-item' | 'extended-delete' | 'extended-walk' | 'absent'
        Error    the last failure message, '' when it came off clean
        Attempts one line per attempt that failed, as evidence
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        # Skip attempt 1 so a test can exercise the fallbacks directly.
        [switch]$NoOrdinary
    )
    $attempts = @()
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Removed = $true; Method = 'absent'; Error = ''; Attempts = $attempts }
    }
    $ext = ConvertTo-ExtendedPath -Path $Path
    $last = ''

    if (-not $NoOrdinary) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $Path)) {
                return [pscustomobject]@{ Removed = $true; Method = 'remove-item'; Error = ''; Attempts = $attempts }
            }
            $last = 'Remove-Item reported success but the path is still on disk'
            $attempts += "remove-item: $last"
        }
        catch {
            $last = $_.Exception.Message
            $attempts += "remove-item: $last"
        }
    }

    # Attempt 2: the object-manager path, which never parses `._.` as a
    # relative segment. This is the one that fixes the observed failure.
    try {
        if ([System.IO.Directory]::Exists($ext)) {
            [System.IO.Directory]::Delete($ext, $true)
        }
        else {
            Clear-PathAttribute -ExtendedPath $ext
            [System.IO.File]::Delete($ext)
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            return [pscustomobject]@{ Removed = $true; Method = 'extended-delete'; Error = ''; Attempts = $attempts }
        }
        $last = 'extended delete reported success but the path is still on disk'
        $attempts += "extended-delete: $last"
    }
    catch {
        $last = $_.Exception.Message
        $attempts += "extended-delete: $last"
    }

    # Attempt 3: same paths, but clearing attributes leaf by leaf.
    try {
        Remove-TreeExtendedWalk -ExtendedDir $ext
        if (-not (Test-Path -LiteralPath $Path)) {
            return [pscustomobject]@{ Removed = $true; Method = 'extended-walk'; Error = ''; Attempts = $attempts }
        }
        $last = 'extended walk reported success but the path is still on disk'
        $attempts += "extended-walk: $last"
    }
    catch {
        $last = $_.Exception.Message
        $attempts += "extended-walk: $last"
    }

    return [pscustomobject]@{ Removed = $false; Method = 'failed'; Error = $last; Attempts = $attempts }
}
