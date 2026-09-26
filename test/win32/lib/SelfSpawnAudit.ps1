<#
.SYNOPSIS
    T980 analyzer - every place the Zig source resolves ITS OWN executable
    path must be either routed through `src\os\self_exe.zig` or registered as
    a read.

.DESCRIPTION
    Inside a zig TEST binary, `std.fs.selfExePath` names the test runner, so a
    site that launches "our own exe" launches a detached copy of the test
    suite instead of the product (T933: 40+ minutes of dead time per floor
    run). `self_exe.productExePath*` refuse in a test build; nothing forced a
    NEW site to use them. This analyzer is that force.

    A site is a call to `std.fs.selfExePath`, `selfExePathAlloc`,
    `selfExeDirPath` or `selfExeDirPathAlloc` anywhere under `src\`, outside
    `src\os\self_exe.zig` (the one module allowed to make the raw call). Each
    site is keyed by file and ENCLOSING function (`fn name` or `test "name"`),
    so the registry does not churn when lines move.

    Findings:
      unregistered   - a site no registry entry names. Either it launches the
                       path (route it through self_exe.productExePath*) or it
                       only reads it (register it with use=read and a why).
      read-but-spawns - a site registered as a read whose enclosing function
                       also contains a process-launch primitive. Reads and
                       launches in one body are exactly how a "read" drifts
                       into a spawn; register it spawn-ok with a reason, or
                       split the function.
      stale          - a registry entry that names no live site. A registry
                       that only grows stops describing the code.

    Pure text analysis; launches nothing.
#>

$script:SelfSpawnCallPattern = 'std\.fs\.selfExe(Dir)?Path(Alloc)?\s*\('
$script:SelfSpawnFnPattern = '^\s*(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+(\w+)\s*\(|^\s*test\s+"((?:[^"\\]|\\.)*)"'
$script:SelfSpawnLaunchPattern = 'CreateProcessW\s*\(|spawnEscapingJob\s*\(|Child\.init\s*\(|Child\.run\s*\(|\.spawn\s*\(|\.spawnAndWait\s*\(|ShellExecute(Ex)?W\s*\('

function Get-SelfSpawnFiles([string]$Root) {
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.zig' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]\.zig-cache[\\/]' })
}

# The code part of a line: everything before a `//` comment. Zig has no block
# comments, and a `//` inside a string literal on the same line as a site is
# rare enough that a false quiet there is the cheaper error.
function Get-SelfSpawnCode([string]$Line) {
    $i = $Line.IndexOf('//')
    if ($i -ge 0) { return $Line.Substring(0, $i) }
    return $Line
}

function Get-SelfSpawnSites {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$SrcRel = 'src'
    )
    $root = Join-Path $Repo $SrcRel
    $sites = New-Object System.Collections.Generic.List[object]
    foreach ($f in (Get-SelfSpawnFiles $root)) {
        $rel = $f.FullName.Substring($Repo.Length).TrimStart('\', '/') -replace '/', '\'
        if ($rel -ieq 'src\os\self_exe.zig') { continue }
        $lines = [IO.File]::ReadAllLines($f.FullName)
        # Function extents first, so each site knows its body.
        $starts = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $m = [regex]::Match($lines[$i], $script:SelfSpawnFnPattern)
            if ($m.Success) {
                $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { "test `"$($m.Groups[2].Value)`"" }
                $starts.Add([pscustomobject]@{ Line = $i; Name = $name }) | Out-Null
            }
        }
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $code = Get-SelfSpawnCode $lines[$i]
            if ($code -notmatch $script:SelfSpawnCallPattern) { continue }
            $fnName = '<top level>'
            $bodyStart = 0
            $bodyEnd = $lines.Length - 1
            for ($k = $starts.Count - 1; $k -ge 0; $k--) {
                if ($starts[$k].Line -le $i) {
                    $fnName = $starts[$k].Name
                    $bodyStart = $starts[$k].Line
                    if ($k + 1 -lt $starts.Count) { $bodyEnd = $starts[$k + 1].Line - 1 }
                    break
                }
            }
            $launches = $false
            for ($j = $bodyStart; $j -le $bodyEnd; $j++) {
                if ((Get-SelfSpawnCode $lines[$j]) -match $script:SelfSpawnLaunchPattern) { $launches = $true; break }
            }
            $sites.Add([pscustomobject]@{
                File     = $rel
                Fn       = $fnName
                Line     = $i + 1
                Text     = $lines[$i].Trim()
                Launches = $launches
            }) | Out-Null
        }
    }
    return ,$sites.ToArray()
}

function Read-SelfSpawnRegistry([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }
    $raw = [IO.File]::ReadAllText($Path)
    $parsed = $raw | ConvertFrom-Json
    return ,@($parsed.entries)
}

function Get-SelfSpawnFindings {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$RegistryPath,
        [string]$SrcRel = 'src'
    )
    $sites = Get-SelfSpawnSites -Repo $Repo -SrcRel $SrcRel
    $entries = Read-SelfSpawnRegistry $RegistryPath
    $findings = New-Object System.Collections.Generic.List[object]
    $used = @{}
    foreach ($s in $sites) {
        $match = $null
        foreach ($e in $entries) {
            if (($e.file -replace '/', '\') -ieq $s.File -and $e.fn -ceq $s.Fn) { $match = $e; break }
        }
        if (-not $match) {
            $findings.Add([pscustomobject]@{
                Kind = 'unregistered'; File = $s.File; Line = $s.Line; Fn = $s.Fn
                Detail = "$($s.Text) -- launches it? use internal_os.self_exe.productExePath*; only reads it? register use=read in the self-spawn registry"
            }) | Out-Null
            continue
        }
        $used["$($match.file)::$($match.fn)"] = $true
        if ($match.use -eq 'read' -and $s.Launches) {
            $findings.Add([pscustomobject]@{
                Kind = 'read-but-spawns'; File = $s.File; Line = $s.Line; Fn = $s.Fn
                Detail = "registered as a read, but $($s.Fn) also launches a process -- register spawn-ok with a reason, or split the function"
            }) | Out-Null
        }
        if ($match.use -notin @('read', 'spawn-ok') -or -not $match.why) {
            $findings.Add([pscustomobject]@{
                Kind = 'bad-entry'; File = $s.File; Line = $s.Line; Fn = $s.Fn
                Detail = "registry entry needs use=read|spawn-ok and a non-empty why"
            }) | Out-Null
        }
    }
    foreach ($e in $entries) {
        if (-not $used.ContainsKey("$($e.file)::$($e.fn)")) {
            $findings.Add([pscustomobject]@{
                Kind = 'stale'; File = ($e.file -replace '/', '\'); Line = 0; Fn = $e.fn
                Detail = 'registry entry names no live site -- remove it'
            }) | Out-Null
        }
    }
    return ,$findings.ToArray()
}
