# AcceptanceParallel.ps1 - T1960. Run a set of acceptance scripts (normally the
# guard-due set a turn owes) about four at a time instead of one at a time,
# without any worker's clean-slate reaching another worker's app.
#
# WHY THE SUITE WAS SERIAL (scripts\suite-run.ps1 says it at length): every
# script resolves its app as `<repo>\zig-out\bin\ghoztty.exe`, CleanSlate kills
# by that exact ExecutablePath, and every script clears the same
# %LOCALAPPDATA%\ghoztty\*-debug* files. Two scripts out of one repo kill each
# other's apps mid-assertion.
#
# THE SHAPE THAT MAKES IT SAFE WITHOUT EDITING 300 SCRIPTS: a WORKER ROOT per
# slot that looks exactly like the repo. Every top-level directory is a
# junction back to the real one, every top-level file a hard link, and only
# `zig-out` is the worker's own - a fresh tree of hard links to the real
# build's files, so it costs no copy and no disk. A script started from
# `<worker>\test\win32\x.ps1` computes `$repo` from `$PSScriptRoot` like it
# always has, lands on the worker root, and from there EVERY path it derives -
# the exe it launches, the agent beside it, the prefix its clean-slate kills,
# CleanSlate's "is this under the repo" refusal - names that worker's copy and
# nothing else. Path-exact kills were already the rule (CleanSlate.ps1); this
# just gives each worker different paths to be exact about.
#
# The rest of a worker's isolation is environment, set on the child:
#   LOCALAPPDATA            its own, so the -debug state files are its own
#   GHOZTTY_AGENT_INSTANCE  its own agent lineage (pipe, guard, state dir -
#                           the agent's pipe is per-user, not per-directory)
#   GHOZTTY_PIPE_SUFFIX     its own app pipe (scripts that mint their own still
#                           override it, and that is fine)
#   GHOZTTY_IPC_SOCKET      removed: a test never inherits the caller's pane
#
# WHAT CANNOT GO IN A WORKER is decided from each script's own text (comments
# stripped by the PowerShell tokenizer), in three classes:
#
#   parallel   runs in a worker root, up to -Width at once.
#   main       runs from the REAL repo with the caller's environment, exactly as
#              a turn runs it today, one main script at a time - but beside the
#              workers, which share nothing with it. For scripts that hardcode
#              the unscoped agent state dir, the unscoped layout manifest or the
#              repo's literal path: they would be wrong in a worker, and they are
#              harmless next to one.
#   exclusive  runs with NOTHING else running. Box-global state (the clipboard,
#              HKCU, the installer, box-wide leak counts, process-name kills),
#              builds (a rebuild under the workers' hard links), and every
#              script that declares `# @timing-sensitive` - a wall-clock budget
#              measured beside three other GUI scripts measures them.
#
# A script can always opt out by declaring `# @parallel-unsafe`. And because a
# static reading can be wrong, the runner re-runs any non-green row ALONE at the
# end (the suite-run T1137 rule): red beside the others and green alone is
# reported as PARALLEL-SENSITIVE with the line to add, and the alone verdict is
# the one that counts. Interference makes runs red, never green, so that is the
# direction that needs a second opinion.

#
# WHICH REPO A RUN TESTS (T1993). The scripts spell the repo as the literal
# D:\git\ghoztty - 283 of them in a `-Exe`/`-Repo` parameter default. A second
# loop lane runs from its own worktree (D:\git\ghoztty-b), and there that
# default names LANE A's build. So the literal is a fixed spelling
# ($script:ApRepoLiteral), never "whatever repo the runner is in", and EVERY
# phase - worker, main, exclusive, serial, confirm - passes those parameters
# explicitly, re-rooted at the checkout actually running (the worker root, or
# -Repo). A script whose BODY still resolves the literal (Get-ApPinnedPaths)
# cannot be re-rooted by a parameter: in any checkout other than the literal
# one the runner refuses it, as a red `refused` row, rather than let it grade
# the other lane's build and call that this lane's verdict.

Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'RunVerdict.ps1')

# The repo's path as the acceptance scripts spell it. Fixed: in lane B the
# runner's own repo is D:\git\ghoztty-b, and a literal taken from it would not
# recognise a single script's default (the T1983 finding).
$script:ApRepoLiteral = 'D:\git\ghoztty'

# A line carrying this marker holds the literal as DATA (a fixture string fed
# to a pure function, an expected value), not as a path the script resolves.
$script:ApLiteralFixtureMarker = '@repo-literal-fixture'

function Test-ApUnderLiteral {
    # True when $Value is the literal or a path below it - and NOT a sibling
    # that merely shares the prefix (D:\git\ghoztty-b starts with D:\git\ghoztty).
    param([string]$Value, [string]$Literal)
    if (-not $Value -or -not $Value.StartsWith($Literal, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return ($Value.Length -eq $Literal.Length -or $Value[$Literal.Length] -eq '\')
}

function Test-ApSamePath {
    param([string]$A, [string]$B)
    try {
        $x = [IO.Path]::GetFullPath($A).TrimEnd('\')
        $y = [IO.Path]::GetFullPath($B).TrimEnd('\')
        return [string]::Equals($x, $y, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

# --------------------------------------------------------------- classifying

# Declarations a script makes about itself. The two desktop markers are the
# TestDesktop.ps1 exceptions: such a script should not be in an unattended run
# at all, but if it is, it is not going to be in one beside anything.
$script:ApExclusiveMarkers = @('timing-sensitive', 'parallel-unsafe', 'input-desktop-exception', 'user-desktop-launch')

# Code (not comments) that pins a script to EXCLUSIVE. Ordered: the first match
# is the reason printed first. Regexes, case-insensitive.
$script:ApExclusivePatterns = [ordered]@{
    'zig\s+build'                                  = 'builds (CPU, and a rebuild under the workers'' hard-linked zig-out)'
    'taskkill'                                     = 'taskkill (tree/name kills reach past its own worker)'
    'Stop-Process\s+-Name|Get-Process\s+(-Name\s+)?[''"]?ghoztty' = 'finds ghoztty by process NAME'
    'msiexec'                                      = 'drives the installer'
    'Programs\\Ghoztty'                            = 'touches an installed Ghoztty'
    'Clipboard'                                    = 'uses the box-global clipboard'
    'HKCU:'                                        = 'writes the shared HKCU registry'
    'Get-Leaked'                                   = 'counts leaks box-wide (would count the other workers)'
    'zig-out-'                                     = 'uses a build dir outside the worker mirror'
    'suite-run\.ps1|acceptance-parallel\.ps1'      = 'runs other harnesses itself'
}

# Code that pins a script to MAIN (the real repo, one at a time).
$script:ApMainPatterns = [ordered]@{
    'local-agent-debug'                                                   = 'hardcodes the unscoped agent state dir (a worker runs its own lineage)'
    'session-layout-debug'                                                = 'hardcodes the unscoped layout manifest'
    'Remove-Item\s+Env:\\?GHOZTTY_AGENT_INSTANCE|\$env:GHOZTTY_AGENT_INSTANCE\s*=\s*(\$null|''''|"")' = 'drops the agent lineage the worker gave it'
}

function Get-ApCodeText {
    <#
    .SYNOPSIS
    The script's text with every comment blanked out and the extents in -Blank
    removed, plus its parse - so patterns are matched against code only.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $text = $ast.Extent.Text
    $chars = $text.ToCharArray()
    $base = $ast.Extent.StartOffset
    foreach ($t in $tokens) {
        if ($t.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
        for ($i = $t.Extent.StartOffset - $base; $i -lt ($t.Extent.EndOffset - $base); $i++) {
            if ($chars[$i] -ne "`n" -and $chars[$i] -ne "`r") { $chars[$i] = ' ' }
        }
    }
    return [pscustomobject]@{ Ast = $ast; Chars = $chars; Base = $base }
}

function Get-AcceptanceScriptClass {
    <#
    .SYNOPSIS
    Classify one acceptance script: parallel, main or exclusive, with reasons,
    and the parameters a worker must inject.

    .DESCRIPTION
    -RepoLiteral is the real repo's path as scripts spell it (D:\git\ghoztty on
    this box). A PARAMETER whose default starts with it - `[string]$Exe =
    'D:\git\ghoztty\zig-out\bin\ghoztty.exe'` is 280 scripts' idiom - is not a
    reason to refuse the worker: the runner passes that parameter explicitly,
    re-rooted at the worker (Inject). The `if (-not (Test-Path $exe)) { $exe =
    '<repo>\zig-out\...' }` fallback is ignored for the same reason (it fires
    only when the injected path is missing). Any OTHER literal repo path pins the
    script to main.

    -RepoLiteral defaults to the fixed spelling ($script:ApRepoLiteral), never
    to the repo the caller runs from (T1993). Pinned lists the places the BODY
    resolves a path under the literal (Get-ApPinnedPaths): no parameter can
    re-root those, so the runner refuses such a script in any other checkout.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RepoLiteral = $script:ApRepoLiteral
    )
    $raw = [IO.File]::ReadAllText($Path)
    $parsed = Get-ApCodeText -Path $Path
    $chars = $parsed.Chars
    $inject = [ordered]@{}
    $skip = @()

    $pb = $parsed.Ast.ParamBlock
    if ($pb) {
        foreach ($p in $pb.Parameters) {
            $dv = $p.DefaultValue
            if (-not ($dv -is [System.Management.Automation.Language.StringConstantExpressionAst])) { continue }
            $v = [string]$dv.Value
            if (-not (Test-ApUnderLiteral -Value $v -Literal $RepoLiteral)) { continue }
            $rest = $v.Substring($RepoLiteral.Length).TrimStart('\')
            $inject[$p.Name.VariablePath.UserPath] = $rest
            $skip += $dv.Extent
            for ($i = $dv.Extent.StartOffset - $parsed.Base; $i -lt ($dv.Extent.EndOffset - $parsed.Base); $i++) { $chars[$i] = ' ' }
        }
    }
    $code = -join $chars
    $lit = [regex]::Escape($RepoLiteral)
    $fallback = "(?i)if\s*\(\s*-not\s*\(\s*Test-Path\s+\`$\w+\s*\)\s*\)\s*\{\s*\`$\w+\s*=\s*'$lit\\zig-out\\[^']*'\s*\}"
    $code = [regex]::Replace($code, $fallback, ' ')
    $pinned = @(Get-ApPinnedPaths -Parsed $parsed -Literal $RepoLiteral -Skip $skip -Fallback $fallback)

    $exclusive = @()
    foreach ($m in $script:ApExclusiveMarkers) {
        if ($raw -match "(?m)^[ \t]*#[ \t]*@$([regex]::Escape($m))\b") { $exclusive += "declares # @$m" }
    }
    foreach ($k in $script:ApExclusivePatterns.Keys) {
        if ($code -match "(?i)$k") { $exclusive += $script:ApExclusivePatterns[$k] }
    }
    $main = @()
    foreach ($k in $script:ApMainPatterns.Keys) {
        if ($code -match "(?i)$k") { $main += $script:ApMainPatterns[$k] }
    }
    if ($code -match "(?i)$lit(?![\w.-])") { $main += "spells the repo's literal path ($RepoLiteral) outside an injectable parameter" }

    $class = if ($exclusive.Count -gt 0) { 'exclusive' } elseif ($main.Count -gt 0) { 'main' } else { 'parallel' }
    return [pscustomobject]@{
        Path    = $Path
        Name    = (Split-Path -Leaf $Path)
        Class   = $class
        Reasons = @($exclusive + $main)
        Inject  = $inject
        Pinned  = $pinned
    }
}

function Get-ApPinnedPaths {
    <#
    .SYNOPSIS
    Every string in a script's code that RESOLVES a path under the repo literal
    outside an injectable parameter default - "line N: <value>" each (T1993).

    .DESCRIPTION
    A string counts when it is the literal or begins with `<literal>\` and is
    path-shaped (no second colon, no newline, no < > | "). That is the line
    between `$repo = 'D:\git\ghoztty'` (a path the script will open) and
    "D:\git\ghoztty\src\main.zig:9:1: error" or "PS D:\git\ghoztty> " (text a
    test feeds a parser). Excluded: the injectable parameter defaults (-Skip),
    the Test-Path fallback (it fires only when the injected path is missing, and
    the run's preflight refuses a missing exe), comments (the AST has none), and
    any line marked `# @repo-literal-fixture` - the literal as data handed to a
    pure function.
    #>
    param(
        [Parameter(Mandatory = $true)]$Parsed,
        [Parameter(Mandatory = $true)][string]$Literal,
        [object[]]$Skip = @(),
        [string]$Fallback
    )
    $lines = $Parsed.Ast.Extent.Text -split "`n"
    $lineBase = $Parsed.Ast.Extent.StartLineNumber
    $found = @()
    $nodes = $Parsed.Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)
    foreach ($n in $nodes) {
        $v = [string]$n.Value
        if (-not (Test-ApUnderLiteral -Value $v -Literal $Literal)) { continue }
        if ($v -match '[\r\n<>|"]' -or $v.IndexOf(':', 2) -ge 0) { continue }
        $inSkip = $false
        foreach ($s in $Skip) {
            if ($n.Extent.StartOffset -ge $s.StartOffset -and $n.Extent.EndOffset -le $s.EndOffset) { $inSkip = $true; break }
        }
        if ($inSkip) { continue }
        $ln = $n.Extent.StartLineNumber
        $lineText = [string]$lines[$ln - $lineBase]
        if ($lineText -match "#.*$([regex]::Escape($script:ApLiteralFixtureMarker))") { continue }
        if ($Fallback -and $lineText -match $Fallback) { continue }
        $found += "line ${ln}: $v"
    }
    return @($found | Select-Object -Unique)
}

# -------------------------------------------------------------- worker roots

if (-not ('ApNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ApNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateHardLinkW(string newName, string existing, IntPtr sa);
}
'@
}

function Get-AcceptanceWorkerBase {
    <#
    .SYNOPSIS
    Where the worker roots live: a sibling of the repo, `.<repo>-par`. Outside
    the repo so no search, audit or `git status` walks into a junction loop;
    on the repo's VOLUME because a hard link cannot cross one.
    #>
    param([Parameter(Mandatory = $true)][string]$Repo)
    $parent = Split-Path -Parent $Repo
    return (Join-Path $parent ('.' + (Split-Path -Leaf $Repo) + '-par'))
}

function Test-ApReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Remove-ApJunction {
    <#
    .SYNOPSIS
    Remove a junction and NOTHING it points at. `cmd /c rmdir` without /s
    removes the link itself; PowerShell 5.1's `Remove-Item -Recurse` on a
    junction follows it and empties the TARGET, which here is the real repo.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-ApReparsePoint $Path)) { throw "Remove-ApJunction refuses '$Path': not a junction" }
    cmd /d /c "rmdir `"$Path`"" | Out-Null
    if (Test-Path -LiteralPath $Path) { throw "Remove-ApJunction: '$Path' is still there" }
}

function Remove-ApLinkTree {
    <#
    .SYNOPSIS
    Delete a worker's zig-out: a real directory of hard links. Refuses if any
    DIRECTORY under it is a reparse point (a junction or directory symlink),
    because a recursive delete would follow it out of the worker. A FILE
    symlink is fine - deleting it removes the link, never its target - and the
    real zig-out has two (lib\libghostty-vt*.dylib).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-ApReparsePoint $Path) { throw "Remove-ApLinkTree refuses '$Path': it is a reparse point" }
    $rp = @(Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
    if ($rp.Count -gt 0) { throw "Remove-ApLinkTree refuses '$Path': it contains reparse point $($rp[0].FullName)" }
    [IO.Directory]::Delete($Path, $true)
}

function New-ApLinkTree {
    <#
    .SYNOPSIS
    Mirror -Source into -Dest as real directories holding hard links to every
    file. Returns the number of files linked.
    #>
    param([string]$Source, [string]$Dest)
    New-Item -ItemType Directory -Force $Dest | Out-Null
    $n = 0
    $srcLen = $Source.TrimEnd('\').Length
    foreach ($d in (Get-ChildItem -LiteralPath $Source -Recurse -Directory -Force)) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "New-ApLinkTree: '$($d.FullName)' is a directory link; refusing to mirror through it" }
        New-Item -ItemType Directory -Force (Join-Path $Dest $d.FullName.Substring($srcLen + 1)) | Out-Null
    }
    foreach ($f in (Get-ChildItem -LiteralPath $Source -Recurse -File -Force)) {
        $to = Join-Path $Dest $f.FullName.Substring($srcLen + 1)
        if (-not [ApNative]::CreateHardLinkW($to, $f.FullName, [IntPtr]::Zero)) {
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "New-ApLinkTree: CreateHardLink '$to' -> '$($f.FullName)' failed ($err)"
        }
        $n++
    }
    return $n
}

function Sync-AcceptanceWorkerRoot {
    <#
    .SYNOPSIS
    Make -Root a mirror of -Repo: a junction per top-level directory, a hard
    link per top-level file, and its own zig-out of hard links to the real one.

    .DESCRIPTION
    Called at the start of every run, because a top-level file replaced by an
    editor (write-new-then-rename) leaves an old hard link pointing at the old
    contents, and the build it links must be THIS run's build. Every other
    `zig-out*` directory is left out on purpose: a script that wants one is
    exclusive and never runs here.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Root
    )
    New-Item -ItemType Directory -Force $Root | Out-Null
    $want = @{}
    foreach ($e in (Get-ChildItem -LiteralPath $Repo -Force)) {
        if ($e.Name -like 'zig-out*') { continue }
        $want[$e.Name] = $true
        $dst = Join-Path $Root $e.Name
        if ($e.PSIsContainer) {
            if (Test-Path -LiteralPath $dst) {
                if (-not (Test-ApReparsePoint $dst)) { throw "Sync-AcceptanceWorkerRoot: '$dst' is a real directory, expected a junction" }
                $target = @((Get-Item -LiteralPath $dst -Force).Target)[0]
                if ($target -and ([string]$target).TrimEnd('\') -ieq $e.FullName.TrimEnd('\')) { continue }
                Remove-ApJunction $dst
            }
            cmd /d /c "mklink /J `"$dst`" `"$($e.FullName)`"" | Out-Null
            if (-not (Test-ApReparsePoint $dst)) { throw "Sync-AcceptanceWorkerRoot: junction '$dst' was not created" }
        } else {
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
            if (-not [ApNative]::CreateHardLinkW($dst, $e.FullName, [IntPtr]::Zero)) {
                throw "Sync-AcceptanceWorkerRoot: hard link '$dst' failed ($([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
            }
        }
    }
    # Entries the repo no longer has.
    foreach ($e in (Get-ChildItem -LiteralPath $Root -Force)) {
        if ($e.Name -eq 'zig-out' -or $want.ContainsKey($e.Name)) { continue }
        if (Test-ApReparsePoint $e.FullName) { Remove-ApJunction $e.FullName }
        elseif (-not $e.PSIsContainer) { Remove-Item -LiteralPath $e.FullName -Force }
    }
    $zo = Join-Path $Root 'zig-out'
    Remove-ApLinkTree $zo
    $linked = 0
    $srcZo = Join-Path $Repo 'zig-out'
    if (Test-Path -LiteralPath $srcZo) { $linked = New-ApLinkTree -Source $srcZo -Dest $zo }
    return $linked
}

function Remove-AcceptanceWorkerRoot {
    <#
    .SYNOPSIS
    Tear a worker root down without touching what it mirrors: every junction
    is unlinked first (never followed), then its own zig-out, then the now
    link-free directory itself.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    if (Test-ApReparsePoint $Root) { throw "Remove-AcceptanceWorkerRoot refuses '$Root': it is itself a reparse point" }
    foreach ($e in (Get-ChildItem -LiteralPath $Root -Force)) {
        if (Test-ApReparsePoint $e.FullName) { Remove-ApJunction $e.FullName }
    }
    Remove-ApLinkTree (Join-Path $Root 'zig-out')
    Remove-ApLinkTree $Root
}

function Get-AcceptanceWorkerEnv {
    <#
    .SYNOPSIS
    The environment one worker's children run under (see the file header).
    The lineage stays within the agent's 24-character cap (agent_lineage.zig).
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][string]$LocalAppData,
        [int]$RunnerPid = $PID
    )
    return [ordered]@{
        LOCALAPPDATA              = $LocalAppData
        GHOZTTY_AGENT_INSTANCE    = "apw$Index-$RunnerPid"
        GHOZTTY_PIPE_SUFFIX       = "-apw$Index-$RunnerPid"
        GHOZTTY_ACCEPTANCE_WORKER = [string]$Index
    }
}

function Stop-ApWorkerProcess {
    <#
    .SYNOPSIS
    Kill whatever is still running out of one worker's zig-out (path prefix of
    THAT worker only). Returns the count. The suite-run leak sweep, scoped.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $prefix = (Join-Path $Root 'zig-out').TrimEnd('\') + '\'
    $n = 0
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        $n++
    }
    if ($n -gt 0) { Start-Sleep -Milliseconds 400 }
    return $n
}

# ------------------------------------------------------------------ running

function Start-ApJob {
    <#
    .SYNOPSIS
    Start one script as `powershell -NoProfile -File`, stdout and stderr to
    files, stdin from NUL, with -Env applied on top of this process's
    environment and -Unset removed from it. Returns the job record.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ArgList = @(),
        [Parameter(Mandatory = $true)][string]$LogBase,
        [System.Collections.IDictionary]$Env = @{},
        [string[]]$Unset = @(),
        [string]$WorkingDirectory
    )
    $out = "$LogBase.log"; $err = "$LogBase.err.log"
    $quoted = @($ArgList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'cmd.exe'
    $psi.Arguments = "/d /s /c `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $quoted < NUL > `"$out`" 2> `"$err`"`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($k in $Unset) { if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) } }
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $null = $p.Handle   # cache it, or ExitCode reads empty after exit (PS Start-Process trap)
    return [pscustomobject]@{ Process = $p; Out = $out; Err = $err; Started = Get-Date }
}

function Split-ApArgs {
    param([string]$Text)
    if (-not $Text) { return @() }
    return @([regex]::Matches($Text, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })
}

function Invoke-AcceptanceRun {
    <#
    .SYNOPSIS
    Run -Jobs (objects with Script = path relative to the repo, Args = string)
    and return one result row per job, in completion order, plus the timeline.

    .DESCRIPTION
    -Width 1 is the SERIAL baseline: every script from the real repo, in the
    given order, with the caller's environment - exactly how a turn runs its due
    list by hand today. -Width N > 1: main and parallel scripts share N slots
    (at most one main at a time, parallel ones each in their slot's worker
    root), then every exclusive script runs with nothing beside it, then every
    non-green row is re-run alone (-NoConfirm skips that).

    -FailFast (T1961) stops STARTING scripts at the first red: whatever is
    already running finishes and is scored, nothing else is launched (no more
    pool jobs, no exclusive ones), and the red is still confirmed alone. The
    jobs that never ran are simply absent from the result rows - the caller
    names them by Seq.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][object[]]$Jobs,
        [int]$Width = 4,
        [Parameter(Mandatory = $true)][string]$LogDir,
        [int]$TimeoutSec = 1800,
        [string]$RepoLiteral,
        [switch]$NoConfirm,
        [switch]$FailFast,
        [scriptblock]$OnResult = { param($r) }
    )
    if (-not $RepoLiteral) { $RepoLiteral = $script:ApRepoLiteral }
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    # T1993: a checkout that is not the literal one (lane B's worktree) cannot
    # run a script whose body resolves the literal - it would grade lane A.
    $foreign = -not (Test-ApSamePath $Repo $RepoLiteral)

    $queue = New-Object System.Collections.ArrayList
    $refusedItems = @()
    $i = 0
    foreach ($j in $Jobs) {
        $abs = Join-Path $Repo $j.Script
        $cls = Get-AcceptanceScriptClass -Path $abs -RepoLiteral $RepoLiteral
        $declared = Get-ScriptTimeout -Text ([IO.File]::ReadAllText($abs))
        $item = [pscustomobject]@{
            Seq = $i; Script = $j.Script; Args = [string]$j.Args; Name = $cls.Name
            Class = $(if ($Width -le 1) { 'serial' } else { $cls.Class })
            StaticClass = $cls.Class; Reasons = $cls.Reasons; Inject = $cls.Inject
            Timeout = $(if ($declared -gt 0) { $declared } else { $TimeoutSec })
        }
        if ($foreign -and @($cls.Pinned).Count -gt 0) {
            $item | Add-Member -NotePropertyName Pinned -NotePropertyValue @($cls.Pinned)
            $refusedItems += $item
        } else {
            [void]$queue.Add($item)
        }
        $i++
    }

    $workers = @{}
    if ($Width -gt 1 -and @($queue | Where-Object { $_.Class -eq 'parallel' }).Count -gt 0) {
        $base = Get-AcceptanceWorkerBase -Repo $Repo
        $slotsNeeded = [Math]::Min($Width, @($queue | Where-Object { $_.Class -eq 'parallel' }).Count)
        for ($w = 1; $w -le $slotsNeeded; $w++) {
            $root = Join-Path $base "w$w"
            [void](Stop-ApWorkerProcess -Root $root)
            $linked = Sync-AcceptanceWorkerRoot -Repo $Repo -Root $root
            $local = Join-Path $base "w$w-local"
            if (Test-Path -LiteralPath $local) {
                if (Test-ApReparsePoint $local) { throw "worker LOCALAPPDATA '$local' is a reparse point" }
                [IO.Directory]::Delete($local, $true)
            }
            New-Item -ItemType Directory -Force (Join-Path $local 'ghoztty') | Out-Null
            $workers[$w] = [pscustomobject]@{ Root = $root; Env = (Get-AcceptanceWorkerEnv -Index $w -LocalAppData $local); Linked = $linked }
        }
    }

    $results = New-Object System.Collections.ArrayList
    $stopped = $false
    foreach ($item in $refusedItems) {
        $now = Get-Date
        $row = [pscustomobject]@{
            Seq = $item.Seq; Name = $item.Name; Script = $item.Script; Args = $item.Args
            Class = $item.Class; Slot = 0; Phase = 'refused'; Kind = 'refused'
            Line = "REFUSED in $Repo - its body resolves $RepoLiteral (another checkout's build), which no parameter can re-root: $(@($item.Pinned)[0])$(if (@($item.Pinned).Count -gt 1) { " (+$(@($item.Pinned).Count - 1) more)" })"
            ExitCode = -1; Started = $now; Ended = $now; Log = $null
        }
        & $OnResult $row | Out-Host
        [void]$results.Add($row)
        if ($FailFast) { $stopped = $true }
    }
    # T1993: the injected parameters go to EVERY phase, re-rooted at whichever
    # checkout the child runs in. Before this only a pooled worker got them, so
    # in lane B a main/exclusive/serial/confirm run took its param default and
    # launched lane A's exe. A parameter the job's own arguments already name is
    # left to them.
    $addInject = {
        param($item, [string]$root, [object[]]$argList)
        $out = @($argList)
        foreach ($k in $item.Inject.Keys) {
            if (@($out | Where-Object { $_ -is [string] -and $_ -ieq "-$k" }).Count -gt 0) { continue }
            $out += "-$k"
            $out += $(if ($item.Inject[$k]) { Join-Path $root $item.Inject[$k] } else { $root })
        }
        return $out
    }
    $runOne = {
        param($item, $slot, $phase)
        $suffix = $(if ($phase -eq 'confirm') { '.alone' } else { '' })
        $logBase = Join-Path $LogDir ("{0:D2}-{1}{2}" -f $item.Seq, [IO.Path]::GetFileNameWithoutExtension($item.Name), $suffix)
        $argList = @(Split-ApArgs $item.Args)
        if ($phase -eq 'pool' -and $item.Class -eq 'parallel') {
            $wk = $workers[$slot]
            $argList = @(& $addInject $item $wk.Root $argList)
            $job = Start-ApJob -ScriptPath (Join-Path $wk.Root $item.Script) -ArgList $argList -LogBase $logBase `
                -Env $wk.Env -Unset @('GHOZTTY_IPC_SOCKET') -WorkingDirectory $wk.Root
        } else {
            $argList = @(& $addInject $item $Repo $argList)
            $job = Start-ApJob -ScriptPath (Join-Path $Repo $item.Script) -ArgList $argList -LogBase $logBase -WorkingDirectory $Repo
        }
        $job | Add-Member -NotePropertyName Item -NotePropertyValue $item
        $job | Add-Member -NotePropertyName Slot -NotePropertyValue $slot
        $job | Add-Member -NotePropertyName Phase -NotePropertyValue $phase
        return $job
    }
    $finish = {
        param($job, [bool]$timedOut)
        if ($timedOut) {
            & taskkill.exe /T /F /PID $job.Process.Id *> $null
            try { $job.Process.WaitForExit(10000) | Out-Null } catch {}
        }
        $code = -1
        try { $code = [int]$job.Process.ExitCode } catch {}
        $v = Get-RunVerdict -ExitCode $code -LogPath $job.Out -TimedOut $timedOut -AltLogPath $job.Err
        if ($job.Item.Class -eq 'parallel' -and $job.Phase -eq 'pool') { [void](Stop-ApWorkerProcess -Root $workers[$job.Slot].Root) }
        $row = [pscustomobject]@{
            Seq = $job.Item.Seq; Name = $job.Item.Name; Script = $job.Item.Script; Args = $job.Item.Args
            Class = $job.Item.Class; Slot = $job.Slot; Phase = $job.Phase
            Kind = $v.Kind; Line = $v.Line; ExitCode = $code
            Started = $job.Started; Ended = (Get-Date); Log = $job.Out
        }
        & $OnResult $row | Out-Host
        return $row
    }
    $waitAll = {
        param($running)
        # Poll every running job; return the ones that finished or timed out.
        foreach ($j in @($running)) {
            $over = ((Get-Date) - $j.Started).TotalSeconds -gt $j.Item.Timeout
            if ($j.Process.HasExited -or $over) {
                [pscustomobject]@{ Job = $j; TimedOut = [bool]($over -and -not $j.Process.HasExited) }
            }
        }
    }

    $isRed = { param($row) $row.Kind -notin @('pass', 'skip') }
    if ($Width -le 1) {
        foreach ($item in $queue) {
            if ($stopped) { break }
            $job = & $runOne $item 0 'pool'
            while (-not $job.Process.HasExited -and ((Get-Date) - $job.Started).TotalSeconds -le $item.Timeout) { Start-Sleep -Milliseconds 250 }
            $row = & $finish $job (-not $job.Process.HasExited)
            [void]$results.Add($row)
            if ($FailFast -and (& $isRed $row)) { $stopped = $true }
        }
    } else {
        # Pool: parallel + main. Main first in the queue so the one-at-a-time
        # lane starts early; parallel fill the rest.
        $pending = New-Object System.Collections.ArrayList
        foreach ($q in @($queue | Where-Object { $_.Class -eq 'main' })) { [void]$pending.Add($q) }
        foreach ($q in @($queue | Where-Object { $_.Class -eq 'parallel' })) { [void]$pending.Add($q) }
        if ($stopped) { $pending.Clear() }  # -FailFast over a refused row
        $running = New-Object System.Collections.ArrayList
        while ($pending.Count -gt 0 -or $running.Count -gt 0) {
            foreach ($pair in @(& $waitAll $running)) {
                $row = & $finish $pair.Job $pair.TimedOut
                [void]$results.Add($row)
                [void]$running.Remove($pair.Job)
                if ($FailFast -and (& $isRed $row)) { $stopped = $true; $pending.Clear() }
            }
            while ($running.Count -lt $Width -and $pending.Count -gt 0) {
                $mainBusy = @($running | Where-Object { $_.Item.Class -eq 'main' }).Count -gt 0
                $next = $null
                foreach ($p in $pending) {
                    if ($p.Class -eq 'main' -and $mainBusy) { continue }
                    $next = $p; break
                }
                if (-not $next) { break }
                $slot = 0
                if ($next.Class -eq 'parallel') {
                    $busy = @($running | Where-Object { $_.Item.Class -eq 'parallel' } | ForEach-Object { $_.Slot })
                    $slot = @($workers.Keys | Sort-Object | Where-Object { $busy -notcontains $_ })[0]
                    if (-not $slot) { break }
                }
                [void]$pending.Remove($next)
                [void]$running.Add((& $runOne $next $slot 'pool'))
            }
            Start-Sleep -Milliseconds 250
        }
        foreach ($item in @($queue | Where-Object { $_.Class -eq 'exclusive' })) {
            if ($stopped) { break }
            $job = & $runOne $item 0 'pool'
            while (-not $job.Process.HasExited -and ((Get-Date) - $job.Started).TotalSeconds -le $item.Timeout) { Start-Sleep -Milliseconds 250 }
            $row = & $finish $job (-not $job.Process.HasExited)
            [void]$results.Add($row)
            if ($FailFast -and (& $isRed $row)) { $stopped = $true }
        }
        if (-not $NoConfirm) {
            foreach ($r in @($results | Where-Object { $_.Phase -eq 'pool' -and $_.Class -ne 'exclusive' -and $_.Kind -notin @('pass', 'skip') })) {
                $item = @($queue | Where-Object { $_.Seq -eq $r.Seq })[0]
                $job = & $runOne $item 0 'confirm'
                while (-not $job.Process.HasExited -and ((Get-Date) - $job.Started).TotalSeconds -le $item.Timeout) { Start-Sleep -Milliseconds 250 }
                [void]$results.Add((& $finish $job (-not $job.Process.HasExited)))
            }
        }
    }
    return @($results)
}

function Get-AcceptanceDueJobs {
    <#
    .SYNOPSIS
    The job list for `due`: every blocking DUE row of `guard-due.ps1 check
    -Json`, one job per distinct script + run arguments.

    .DESCRIPTION
    PS 5.1's ConvertFrom-Json hands a JSON array down the pipeline as ONE
    object, so `@(... | ConvertFrom-Json)` is a one-element list holding the
    whole array - and a loop over it sees one row whose `.Kind` is an array of
    every kind. The first cut of this runner did exactly that and answered
    "nothing is due" over 13 due rows. The ForEach-Object unrolls it.

    ORDER (T1961): the most specific harness first - fewest covered files, ties
    in guard order. A row covering three files of one feature is the changed
    feature's own acceptance; a row covering 400 is an audit that any edit
    makes due. With -FailFast that puts the red most likely to be THIS turn's
    in front, before the sweeps that would only repeat it.
    #>
    param([Parameter(Mandatory = $true)][string]$GuardJson)
    $states = @($GuardJson | ConvertFrom-Json | ForEach-Object { $_ })
    $seen = @{}
    $jobs = @()
    foreach ($s in $states) {
        if ($s.Kind -ne 'due' -or $s.Advisory) { continue }
        $key = "$($s.Script)|$($s.RunArgs)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $jobs += [pscustomobject]@{ Script = [string]$s.Script; Args = [string]$s.RunArgs; Files = @($s.Files).Count; Order = $jobs.Count }
    }
    return @($jobs | Sort-Object Files, Order | Select-Object Script, Args)
}

function Get-AcceptanceFinal {
    <#
    .SYNOPSIS
    One verdict per job: the confirm (alone) run when there was one, else the
    pool run. Marks a row PARALLEL-SENSITIVE when it went red beside others
    and green alone.
    #>
    param([object[]]$Results)
    $out = @()
    foreach ($g in @($Results | Group-Object Seq)) {
        $pool = @($g.Group | Where-Object { $_.Phase -in @('pool', 'refused') })[0]
        $alone = @($g.Group | Where-Object { $_.Phase -eq 'confirm' })[0]
        $final = if ($alone) { $alone } else { $pool }
        $sensitive = [bool]($alone -and $pool.Kind -notin @('pass', 'skip') -and $alone.Kind -in @('pass', 'skip'))
        $out += [pscustomobject]@{
            Seq = $pool.Seq; Name = $pool.Name; Script = $pool.Script; Class = $pool.Class
            Kind = $final.Kind; Line = $final.Line; PoolKind = $pool.Kind
            AloneKind = $(if ($alone) { $alone.Kind } else { '' }); ParallelSensitive = $sensitive
        }
    }
    return @($out | Sort-Object Seq)
}

function Test-AcceptanceOverlap {
    <#
    .SYNOPSIS
    The timeline audit: every pair of pool/confirm rows whose run intervals
    overlap and at least one of which had to run alone (exclusive, or a confirm
    re-run), plus more than one main at a time. Empty = the schedule held.
    #>
    param([object[]]$Results)
    $bad = @()
    $rows = @($Results | Where-Object { $_.Phase -ne 'refused' })  # never ran
    for ($a = 0; $a -lt $rows.Count; $a++) {
        for ($b = $a + 1; $b -lt $rows.Count; $b++) {
            $x = $rows[$a]; $y = $rows[$b]
            if (-not ($x.Started -lt $y.Ended -and $y.Started -lt $x.Ended)) { continue }
            $xAlone = ($x.Class -in @('exclusive', 'serial')) -or $x.Phase -eq 'confirm'
            $yAlone = ($y.Class -in @('exclusive', 'serial')) -or $y.Phase -eq 'confirm'
            if ($xAlone -or $yAlone) { $bad += "$($x.Name) [$($x.Class)/$($x.Phase)] overlapped $($y.Name) [$($y.Class)/$($y.Phase)]"; continue }
            if ($x.Class -eq 'main' -and $y.Class -eq 'main') { $bad += "two main scripts at once: $($x.Name) and $($y.Name)" }
            if ($x.Class -eq 'parallel' -and $y.Class -eq 'parallel' -and $x.Slot -eq $y.Slot) { $bad += "one worker slot ran two scripts at once: $($x.Name) and $($y.Name) (w$($x.Slot))" }
        }
    }
    return @($bad)
}
