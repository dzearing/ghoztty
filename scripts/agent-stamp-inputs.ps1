# T784 - does ghoztty-agent's build stamp cover every source file the agent is
# actually compiled from?
#
# The stamp (`YYYYMMDD-<short hash>`, src\build\GhosttyAgent.zig `versionString`)
# is the agent binary's SELF-UPDATE IDENTITY: the app compares the RUNNING
# agent's stamp with the one it ships beside (src\remote\agent_build.zig
# `isStale`, macos LocalAgentManager.agentIsStale) and decides from that whether
# the agent on the box is the build on disk. It is the commit date + short hash
# of the last COMMIT that touched a hand-written list of paths - deliberately
# not HEAD, so a release that does not change the agent does not re-stamp it.
#
# The hazard that hand-written list carries is silent: the agent is compiled
# from more than the list names. `src\remote\agent\*.zig` reaches
# `src\os\main.zig`, `src\terminal\main.zig` and `src\apprt\win32\job_spawn.zig`
# by relative import, so a commit touching any of those changed the agent's
# BYTES while leaving its stamp alone - and both peers then agree that two
# different builds are the same one. `isStale` says current, the upgrade policy
# does nothing, and the delivery freshness gate (T281: staged stamp vs delivered
# stamp) compares two copies of the same wrong answer and passes.
#
# So this script asks the COMPILER what the agent is built from, rather than
# re-deriving it: every `zig build agent` writes a cache manifest listing every
# file the compilation read, and the repo-relative entries in it are exactly the
# agent's tracked inputs. Each one must be covered by a stamp path, or named in
# the exclusions below. Both sides are read out of the tree - the input set from
# the manifest, the path list from GhosttyAgent.zig's own git argv - so this
# script cannot disagree with the build about what is covered.
#
#   powershell -NoProfile -File scripts\agent-stamp-inputs.ps1
#   powershell -NoProfile -File scripts\agent-stamp-inputs.ps1 -Build
#   powershell -NoProfile -File scripts\agent-stamp-inputs.ps1 -Format json
#
# Exit 0 = every compiled input is covered. Exit 1 = uncovered inputs (listed).
# Exit 2 = the script could not answer (no manifest, no recipe).
param(
    [string]$Repo,
    [ValidateSet('text', 'json')]
    [string]$Format = 'text',
    # Run `zig build agent` first, so the manifest is guaranteed to exist and to
    # describe the tree as it stands. Cached, so a few seconds when nothing moved.
    [switch]$Build,
    # Read this manifest instead of discovering the newest one - the acceptance
    # harness points it at synthetic fixtures with a known answer.
    [string]$Manifest,
    # Override the stamp path list (same shape as GhosttyAgent.zig's argv), again
    # so the harness can prove the finding path fires.
    [string[]]$StampPaths
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path $PSScriptRoot -Parent }

# Paths the compilation reads but that CANNOT change the agent binary, with the
# reason. An exclusion is a claim, so it is written down here rather than being
# a silent gap in the path list.
#
#   macos/  - Swift sources wired in as anonymous imports for the macOS apprt
#             (SharedDeps: IPCMessage.swift, ViewerView.swift). They are inputs
#             to the build graph, never compiled into ghoztty-agent, and folding
#             the Mac seat's churn into the agent's identity would re-stamp it
#             for edits that provably cannot reach it.
$script:Exclusions = @(
    @{ Path = 'macos'; Why = 'Swift sources for the macOS apprt; never compiled into the agent' }
)

function Normalize([string]$p) {
    # Repo-relative, forward slashes, no leading ./ - the one spelling every
    # comparison below uses.
    $s = $p -replace '\\', '/'
    $s = $s -replace '^\./', ''
    return $s.TrimEnd('/')
}

# ---------------------------------------------------------------------------
# The stamp path list, read from the build recipe.
# ---------------------------------------------------------------------------

function Get-StampPaths([string]$Recipe) {
    # versionString() runs one `git log ... -- <paths>`; the paths are the string
    # literals after the `"--"` argument, up to the end of the argv array.
    $text = Get-Content -LiteralPath $Recipe -Raw
    $marker = '"--",'
    $i = $text.IndexOf($marker)
    if ($i -lt 0) { return @() }
    $rest = $text.Substring($i + $marker.Length)
    $end = $rest.IndexOf('}')
    if ($end -ge 0) { $rest = $rest.Substring(0, $end) }
    $paths = @()
    foreach ($m in [regex]::Matches($rest, '"([^"]+)"')) {
        $paths += (Normalize $m.Groups[1].Value)
    }
    return $paths
}

function Test-UnderAny([string]$File, [string[]]$Paths) {
    foreach ($p in $Paths) {
        if ($p -eq '') { continue }
        if ($File -eq $p) { return $true }
        if ($File.StartsWith($p + '/')) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# The compiled input set, read from the build cache manifest.
# ---------------------------------------------------------------------------

# A manifest line is `<size> <inode> <mtime> <hash> <prefix> <path>`; the path is
# either repo-relative or absolute, and entries from the zig lib / the global
# package cache resolve to neither. Keeping only paths that exist in the repo is
# what sorts them out without hard-coding prefix numbering.
function Get-ManifestInputs([string]$RepoRoot, [string]$ManifestPath) {
    $prefix = (Normalize $RepoRoot) + '/'
    $out = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $ManifestPath | Select-Object -Skip 1)) {
        $parts = $line -split ' ', 6
        if ($parts.Count -lt 6) { continue }
        $p = Normalize $parts[5]
        if ($p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $p = $p.Substring($prefix.Length)
        } elseif ($p -match '^[A-Za-z]:/') {
            continue  # absolute, but not ours
        }
        if ($p -eq '') { continue }
        $full = Join-Path $RepoRoot ($p -replace '/', '\')
        if (Test-Path -LiteralPath $full -PathType Leaf) { $out[$p] = $true }
    }
    return @($out.Keys)
}

# The newest manifest that names the agent's own entry point. `zig build agent`
# and `zig build test-agent` both produce one; either answers this question,
# since a test build's extra inputs are a superset of the exe's.
function Find-Manifest([string]$RepoRoot) {
    $dir = Join-Path $RepoRoot '.zig-cache\h'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $hit = Get-ChildItem -LiteralPath $dir -Filter *.txt -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Where-Object { Select-String -Path $_.FullName -SimpleMatch 'remote\agent\main.zig' -Quiet } |
        Select-Object -First 1
    if (-not $hit) { return $null }
    return $hit.FullName
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

if ($Build) {
    if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
        # Same trap as every other build on this box: a cache on another drive
        # makes zig 0.15.2 assert instead of explaining itself.
        $env:ZIG_GLOBAL_CACHE_DIR = ((Split-Path $Repo -Qualifier) + '\zig-global-cache')
    }
    Push-Location $Repo
    try { & zig build agent -Dapp-runtime=win32 -Doptimize=Debug 2>&1 | Out-Null } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) {
        Write-Output "ERROR: zig build agent failed (exit $LASTEXITCODE); cannot enumerate inputs"
        exit 2
    }
}

if (-not $Manifest) { $Manifest = Find-Manifest $Repo }
if (-not $Manifest -or -not (Test-Path -LiteralPath $Manifest)) {
    Write-Output "ERROR: no agent build manifest under .zig-cache\h - run with -Build, or run: zig build agent -Dapp-runtime=win32 -Doptimize=Debug"
    exit 2
}

if (-not $StampPaths) {
    $recipe = Join-Path $Repo 'src\build\GhosttyAgent.zig'
    if (-not (Test-Path -LiteralPath $recipe)) {
        Write-Output "ERROR: build recipe not found: src/build/GhosttyAgent.zig"
        exit 2
    }
    $StampPaths = Get-StampPaths $recipe
    if ($StampPaths.Count -eq 0) {
        Write-Output "ERROR: no stamp paths parsed out of src/build/GhosttyAgent.zig"
        exit 2
    }
}
# Accept a ';'-separated list in one element as well as a real array: powershell
# -File hands every argument through as a single string, so a caller in another
# process cannot pass a multi-value array any other way.
$StampPaths = @($StampPaths | ForEach-Object { $_ -split '[;,]' } | Where-Object { $_ } | ForEach-Object { Normalize $_ })
$excluded = @($script:Exclusions | ForEach-Object { Normalize $_.Path })

$inputs = @(Get-ManifestInputs $Repo $Manifest)
if ($inputs.Count -eq 0) {
    Write-Output "ERROR: manifest names no repo files: $Manifest"
    exit 2
}

$uncovered = @(
    $inputs |
        Where-Object { -not (Test-UnderAny $_ $StampPaths) } |
        Where-Object { -not (Test-UnderAny $_ $excluded) } |
        Sort-Object
)

if ($Format -eq 'json') {
    [pscustomobject]@{
        manifest   = (Normalize $Manifest)
        stampPaths = $StampPaths
        exclusions = @($script:Exclusions | ForEach-Object { [pscustomobject]@{ path = (Normalize $_.Path); why = $_.Why } })
        inputs     = @($inputs | Sort-Object)
        uncovered  = $uncovered
    } | ConvertTo-Json -Depth 4
    exit ([int]($uncovered.Count -gt 0))
}

Write-Output "agent stamp inputs: compiled-inputs=$($inputs.Count) stamp-paths=$($StampPaths.Count)"
Write-Output "  manifest: $(Normalize $Manifest)"
foreach ($p in $StampPaths) { Write-Output "  covers   $p" }
foreach ($e in $script:Exclusions) { Write-Output "  excludes $(Normalize $e.Path) - $($e.Why)" }
if ($uncovered.Count -eq 0) {
    Write-Output "OK: all $($inputs.Count) compiled input(s) are covered by the stamp path list."
    exit 0
}
Write-Output "UNCOVERED: $($uncovered.Count) compiled input(s) the stamp does not follow:"
foreach ($f in $uncovered) { Write-Output "  $f" }
Write-Output ""
Write-Output "Each of these can change the agent binary without changing its build stamp,"
Write-Output "so the app reads a genuinely different agent as the one it ships beside."
Write-Output "Fix by adding the path to versionString()'s git argv in src\build\GhosttyAgent.zig,"
Write-Output "or - if it provably cannot reach the agent binary - to this script's exclusions,"
Write-Output "with the reason."
exit 1
