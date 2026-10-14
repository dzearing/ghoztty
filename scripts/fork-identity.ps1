<#
.SYNOPSIS
  Re-apply this fork's identity overlay (branding, the `.win32` apprt arms) to a
  tree taken from upstream, and verify that no upstream identity survives.

.DESCRIPTION
  T956, Stage 0 item 2 of docs\design\windows-parity-upstream-pull-plan.md.

  T879 measured the 131-file merge risk set and found that 52 of those files
  carry a fork delta of 10 lines or fewer, and that the delta in that class is
  almost always MECHANICAL: a branding string, an apprt enum arm, or a path or
  binary name carrying the fork identity. None of it is a semantic conflict, so
  none of it should be resolved by hand 52 times - and then again in every later
  merge stage, because the same files keep arriving from upstream.

  This script is that overlay, written down:

    apply   Rewrite a tree so it carries the fork identity. Idempotent by
            construction - every rule's find pattern matches the UPSTREAM form
            only, so a tree that is already overlaid is left byte-identical.
            That is what makes it safe to run on OUR tree as a regression check
            (test\win32\fork-identity.ps1 section B does exactly that).
    check   Report every place a rule's upstream form survives, and exit 1 if
            there is one. This is the verifier the plan asks for: after "take
            theirs" for a U-file, `check` is what says the overlay is complete.
    rules   Print the rule table - name, scope, what it rewrites and why - so
            the plan's prose and the code cannot drift apart.
    coverage
            Ask whether the rule table still accounts for the fork (T1027).
            `check` only looks for the upstream spelling each rule was written
            against, so identity the fork adds later is invisible to it. This
            diffs -Base (the fork point) against -Head, pairs each added line
            carrying fork identity with the upstream line it replaced, replays
            the rules over the upstream line, and reports every pair they do
            not reproduce. Pairs already recorded in
            scripts\fork-identity-coverage.json are reported as KNOWN; a pair
            missing from it exits 1. The ledger only shrinks (-Record).

  WHAT IT DELIBERATELY DOES NOT DO

  The overlay is only the mechanical part. Three classes in the U-file set are
  NOT mechanizable and are left for the human doing the merge; the measurement
  in the acceptance harness names each file they affect rather than pretending
  the number is 52:

  - The CI repository guards (`if: github.repository == 'ghostty-org/ghostty'`)
    are applied SELECTIVELY - 28 guards over 47 jobs in test.yml alone - so a
    rule that added them everywhere would be wrong, not merely coarse.
  - The macOS `Ghostty.SurfaceView` -> `PaneView` refactor is a type rename this
    fork made for its own reasons; it is real work, not identity.
  - Genuine feature deltas that happen to live in a small file (a raised
    comptime branch quota, an added OSC parser, a new config mode).

  A blanket ghostty -> ghoztty rename would also be WRONG and is never done
  here. `xterm-ghostty` is the TERM value and must match terminfo; the
  `GHOSTTY_*` environment variables are a published contract with shells;
  `ghostty-org/ghostty` is upstream's repository; `src/apprt/gtk` and
  `macos/Sources/Ghostty` are directory and module names; `po/*.po` headers are
  gettext metadata regenerated from upstream. Every rule below is narrow, is
  derived from a measured fork delta, and carries the allow-list for the places
  its own pattern legitimately appears unrewritten.

  Acceptance: test\win32\fork-identity.ps1.

.EXAMPLE
  powershell -NoProfile -File scripts\fork-identity.ps1 check
  powershell -NoProfile -File scripts\fork-identity.ps1 apply -Path C:\tmp\upstream-tree
  powershell -NoProfile -File scripts\fork-identity.ps1 apply -DryRun
  powershell -NoProfile -File scripts\fork-identity.ps1 rules
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'apply', 'rules', 'coverage')]
    [string]$Action = 'check',

    # Tree to operate on. Defaults to this repo, which is the regression case:
    # `apply` must be a no-op here and `check` must be clean.
    [string]$Path,

    # Optional subset, tree-relative (forward or back slashes). Everything else
    # in the tree is skipped entirely.
    [string[]]$Files,

    [switch]$DryRun,
    [switch]$Json,
    [switch]$Quiet,

    # coverage only: the two commits whose delta is swept. Base defaults to the
    # fork point the upstream pull plan measures from.
    [string]$Base = '063ac3ecc',
    [string]$Head = 'HEAD',

    # coverage only: the ledger of unaccounted pairs already known when it was
    # recorded. Known pairs are reported and do not fail the run; a pair that
    # is NOT in it does. -Strict fails on known pairs too. Pass -Known '' for
    # no ledger at all.
    [string]$Known,
    [switch]$Strict,

    # coverage only: rewrite the -Known ledger to the pairs still unaccounted.
    # It may only SHRINK - a ledger that exists is never grown, because a new
    # pair is either a rule to write or an $Acknowledged entry with a reason,
    # and a ledger that absorbed it would be a silent acknowledgment. The one
    # exception is the first recording, when there is no ledger yet.
    [switch]$Record
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path -Parent $PSScriptRoot }
$Path = (Resolve-Path -LiteralPath $Path).Path
if (-not $PSBoundParameters.ContainsKey('Known')) { $Known = Join-Path $PSScriptRoot 'fork-identity-coverage.json' }

# ---------------------------------------------------------------------------
# The rule table.
#
# Each rule: a scope (Include/Exclude globs, tree-relative, '/'-separated), one
# or more Find/Replace pairs, and an Allow list of line-level patterns that
# exempt a line from BOTH rewriting and reporting.
#
# Find patterns are .NET regexes and match the UPSTREAM spelling only. That is
# the idempotence guarantee: nothing a rule writes can be matched by the rule
# that wrote it.
#
# Order matters. surface-uti runs before bundle-id because
# `com.mitchellh.ghosttySurfaceId` contains `com.mitchellh.ghostty`, and the
# generic rule would turn it into `com.dzearing.ghozttySurfaceId` - a string
# that is neither side's.
# ---------------------------------------------------------------------------
$script:Rules = @(
    [pscustomobject]@{
        Name    = 'surface-uti'
        Kind    = 'regex'
        Why     = 'The drag-and-drop UTI for a surface. Not a plain prefix rename, so it runs before bundle-id.'
        Include = @('macos/**')
        Exclude = @()
        Allow   = @()
        Pairs   = @(
            @{ Find = 'com\.mitchellh\.ghosttySurfaceId'; Replace = 'com.dzearing.ghoztty.surfaceId' }
        )
    },
    [pscustomobject]@{
        Name    = 'bundle-id'
        Kind    = 'regex'
        Why     = 'The reverse-DNS app identity: bundle id, GTK icon/app id, systemd unit, gettext domain, desktop file.'
        Include = @('**')
        # po/*.po and the .pot are gettext metadata carrying the upstream
        # package name in their headers; they are regenerated by upstream
        # tooling, not authored here. macos.dmp is a crash-report fixture whose
        # bytes are the test data.
        Exclude = @('po/*.po', 'po/*.pot', 'src/crash/testdata/**')
        # A link TO upstream's repository is a reference, not our identity.
        Allow   = @('github\.com/ghostty-org/ghostty')
        Pairs   = @(
            @{ Find = 'com\.mitchellh\.ghostty'; Replace = 'com.dzearing.ghoztty' }
        )
    },
    [pscustomobject]@{
        Name    = 'logger-subsystem'
        Kind    = 'regex'
        Why     = 'os.Logger subsystems go through Bundle.loggerSubsystem, which has a fork default for the non-bundled case.'
        Include = @('macos/**/*.swift')
        Exclude = @()
        Allow   = @()
        # The bang is load-bearing: `Bundle.main.bundleIdentifier` WITHOUT it
        # (`?? "com.dzearing.ghoztty"`) is the correct fork form and survives.
        Pairs   = @(
            @{ Find = 'Bundle\.main\.bundleIdentifier!'; Replace = 'Bundle.loggerSubsystem' }
        )
    },
    [pscustomobject]@{
        Name    = 'appcast-url'
        Kind    = 'regex'
        Why     = "The Sparkle feed the app updates from. Upstream's feed ships upstream's builds."
        # Swift only: dist/macos/update_appcast_*.py are upstream's release
        # scripts, unrebranded, and pointing them at a fork feed would be a lie.
        Include = @('macos/**/*.swift')
        Exclude = @()
        Allow   = @()
        Pairs   = @(
            @{ Find = 'https://tip\.files\.ghostty\.org/appcast\.xml'; Replace = 'https://dzearing.github.io/ghoztty/appcast-tip.xml' },
            @{ Find = 'https://release\.files\.ghostty\.org/appcast\.xml'; Replace = 'https://dzearing.github.io/ghoztty/appcast.xml' }
        )
    },
    [pscustomobject]@{
        Name    = 'display-name'
        Kind    = 'regex'
        Why     = 'The product name where a user reads it: window titles and UI strings.'
        Include = @('macos/**/*.swift', 'macos/**/*.xib')
        Exclude = @()
        Allow   = @()
        # The emoji is written as regex escapes so this script stays ASCII: a
        # PS 5.1 host that reads a BOM-less UTF-8 script as ANSI would otherwise
        # mangle the surrogate pair, and the rule would silently stop matching.
        # Only the CAPTURED prefix is echoed back, so the replacement is ASCII too.
        # The bare "Ghostty" literal is a separate rule because it is Swift-only:
        # the Xcode module name `customModule="Ghostty"` lives in .xib attributes
        # and must survive, while the window titles in the same .xib files are
        # matched by the emoji pair below.
        Pairs   = @(
            @{ Find = '(\uD83D\uDC7B )Ghostty'; Replace = '${1}Ghoztty' }
        )
    },
    [pscustomobject]@{
        Name    = 'display-name-literal'
        Kind    = 'regex'
        Why     = 'A bare "Ghostty" Swift string literal is a user-visible name; the Xcode module reference is never a string.'
        Include = @('macos/**/*.swift')
        Exclude = @()
        Allow   = @()
        Pairs   = @(
            @{ Find = '"Ghostty"'; Replace = '"Ghoztty"' }
        )
    },
    [pscustomobject]@{
        Name    = 'shell-bin'
        Kind    = 'regex'
        Why     = 'Shell integration invokes the binary by name. GHOSTTY_* variable names and xterm-ghostty stay upstream - they are contracts.'
        Include = @('src/shell-integration/**')
        Exclude = @()
        Allow   = @()
        Pairs   = @(
            # sh/fish/zsh/bash: "$GHOSTTY_BIN_DIR/ghostty"; elvish: $E:GHOSTTY_BIN_DIR/"ghostty"
            @{ Find = '(GHOSTTY_BIN_DIR/"?)ghostty'; Replace = '${1}ghoztty' },
            # nushell builds the path instead of interpolating it.
            @{ Find = '(path join ")ghostty"'; Replace = '${1}ghoztty"' },
            @{ Find = 'ghostty command not available'; Replace = 'ghoztty command not available' }
        )
    },
    [pscustomobject]@{
        Name    = 'cli-name'
        Kind    = 'regex'
        Why     = 'The command name as the core prints it: generated docs, startup log lines, and the XTVERSION report string.'
        Include = @('src/**')
        Exclude = @()
        Allow   = @()
        Pairs   = @(
            # webgen emits `ghostty --help` / `ghostty +list-fonts` command lines.
            @{ Find = '"ghostty (--|\+)'; Replace = '"ghoztty ${1}' },
            @{ Find = 'ghostty version=\{s\}'; Replace = 'ghoztty version={s}' },
            @{ Find = 'ghostty build optimize=\{s\}'; Replace = 'ghoztty build optimize={s}' },
            # The documented/tested shape of the XTVERSION response.
            @{ Find = 'ghostty 1\.2\.3'; Replace = 'ghoztty 1.2.3' }
        )
    },
    [pscustomobject]@{
        Name    = 'apprt-arm'
        Kind    = 'apprt-arm'
        Why     = 'The core switches on build_config.app_runtime; this fork adds a .win32 member, so every exhaustive switch needs an arm for it.'
        Include = @('src/**/*.zig')
        Exclude = @()
        Allow   = @()
        Pairs   = @()
    }
)

# ---------------------------------------------------------------------------
# Scope matching. Globs are tree-relative with '/' separators:
#   **      any number of path segments
#   **/     zero or more leading segments
#   *       within one segment
# ---------------------------------------------------------------------------
function ConvertTo-ScopeRegex {
    param([string]$Glob)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('^')
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '*') {
            if ($i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
                if ($i + 2 -lt $Glob.Length -and $Glob[$i + 2] -eq '/') {
                    [void]$sb.Append('(?:.*/)?'); $i += 3; continue
                }
                [void]$sb.Append('.*'); $i += 2; continue
            }
            [void]$sb.Append('[^/]*'); $i++; continue
        }
        if ($c -eq '?') { [void]$sb.Append('[^/]'); $i++; continue }
        [void]$sb.Append([regex]::Escape([string]$c)); $i++
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}

$script:ScopeCache = @{}
# Fork-only trees, excluded from EVERY rule. Upstream has no `docs/` and no
# `scripts/` at all (`git ls-tree -d 063ac3ecc` lists neither), and
# `test\win32\` is this seat's harness - so no file under them ever arrives
# from upstream, while all three legitimately QUOTE the upstream identity: the
# upstream pull plan documents the rename, and this script states it. A check that
# reports its own rule table is noise, and noise is how a verifier stops being
# read.
$script:GlobalExclude = @('docs/**', 'scripts/**', 'test/win32/**')

function Test-Scope {
    param([string]$Relative, [string[]]$Include, [string[]]$Exclude)
    foreach ($g in $script:GlobalExclude) {
        if (-not $script:ScopeCache.ContainsKey($g)) { $script:ScopeCache[$g] = ConvertTo-ScopeRegex $g }
        if ($Relative -match $script:ScopeCache[$g]) { return $false }
    }
    foreach ($g in @($Exclude)) {
        if (-not $script:ScopeCache.ContainsKey($g)) { $script:ScopeCache[$g] = ConvertTo-ScopeRegex $g }
        if ($Relative -match $script:ScopeCache[$g]) { return $false }
    }
    foreach ($g in @($Include)) {
        if (-not $script:ScopeCache.ContainsKey($g)) { $script:ScopeCache[$g] = ConvertTo-ScopeRegex $g }
        if ($Relative -match $script:ScopeCache[$g]) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# File enumeration. Build outputs and the object store are never subjects; a
# binary file is skipped by content rather than by extension, so a fixture with
# an innocent name cannot be rewritten.
# ---------------------------------------------------------------------------
$script:SkipDirs = @('.git', 'zig-out', 'zig-out-release', 'zig-out-staging', '.zig-cache', 'zig-cache', 'node_modules', 'temp', '.claude')

function Test-BinaryFile {
    param([string]$FullPath)
    try {
        $fs = [System.IO.File]::OpenRead($FullPath)
        try {
            $len = [Math]::Min(8192, $fs.Length)
            if ($len -eq 0) { return $false }
            $buf = New-Object byte[] $len
            [void]$fs.Read($buf, 0, $len)
            foreach ($b in $buf) { if ($b -eq 0) { return $true } }
            return $false
        } finally { $fs.Dispose() }
    } catch { return $true }
}

function Get-SubjectFiles {
    $root = $Path.TrimEnd('\', '/')
    $result = New-Object System.Collections.ArrayList

    if ($Files -and $Files.Count -gt 0) {
        foreach ($f in $Files) {
            $rel = ($f -replace '\\', '/').TrimStart('./')
            $full = Join-Path $root ($rel -replace '/', '\')
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                [void]$result.Add([pscustomobject]@{ Relative = $rel; Full = $full })
            }
        }
        return $result
    }

    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($dir)) {
            $name = Split-Path $entry -Leaf
            if ([System.IO.Directory]::Exists($entry)) {
                if ($script:SkipDirs -contains $name) { continue }
                $stack.Push($entry)
                continue
            }
            $rel = $entry.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
            [void]$result.Add([pscustomobject]@{ Relative = $rel; Full = $entry })
        }
    }
    return $result
}

# ---------------------------------------------------------------------------
# Text I/O that preserves what it did not mean to change: the UTF-8 BOM if the
# file had one, and CRLF/LF exactly as found (lines keep their own trailing
# \r and are rejoined with \n, so nothing normalizes).
# ---------------------------------------------------------------------------
function Read-TextFile {
    param([string]$FullPath)
    $bytes = [System.IO.File]::ReadAllBytes($FullPath)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $start = 0
    if ($bom) { $start = 3 }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
    return [pscustomobject]@{ Text = $text; Bom = $bom }
}

function Write-TextFile {
    param([string]$FullPath, [string]$Text, [bool]$Bom)
    $enc = New-Object System.Text.UTF8Encoding($Bom)
    [System.IO.File]::WriteAllBytes($FullPath, $enc.GetBytes($Text))
}

# EVERY rule match in this script is case-SENSITIVE (-cmatch, and .NET's
# default Replace). PowerShell's `-match` is case-insensitive, which here is not
# a nuance but a bug: `"Ghostty"` would match `"ghostty"` and the display-name
# rule would rewrite `.appendingPathComponent("ghostty")` - the config directory
# name, which is upstream's on purpose. Seen for real on the first run: 7 false
# findings, all of them paths.
function Test-Allowed {
    param([string]$Line, [string[]]$Allow)
    foreach ($a in @($Allow)) { if ($Line -cmatch $a) { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# The apprt arm rule, which is structural rather than textual.
#
# `.none => void,` appears 29 times at the fork point and only 11 of them are
# app-runtime switches - the rest are box-drawing, style and kitty-graphics
# switches that a blanket regex would corrupt. So the block is found first
# (`switch (... app_runtime)`, brace-balanced) and only its arms are touched.
#
# Two further narrowings, both bought by a false positive on the first run:
#
# - A block that ALREADY covers `.win32` (its own arm) or has an `else` arm is
#   finished. src\build\SharedDeps.zig switches on `self.config.app_runtime`
#   with a real `.win32 => { linkSystemLibrary2("opengl32") ... }` arm beside
#   `.none => {}`, and folding those two together would drop the Windows system
#   libraries from every win32 link.
# - Only the "not applicable" arms are widened. `.none => none,` in
#   src\apprt.zig maps the member to a MODULE, and folding .win32 into it would
#   point the win32 build at the none backend - so that shape is reported by
#   `check` and never rewritten by `apply`.
# ---------------------------------------------------------------------------
function Get-ApprtSwitchBlocks {
    param([string[]]$Lines)
    $blocks = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        # `.*` rather than `[^)]*`: src\terminal\mouse.zig switches on
        # `@import("../build_config.zig").app_runtime`, whose own parentheses
        # ended a character-class version of this pattern one file short.
        if ($Lines[$i] -cnotmatch 'switch\s*\(.*app_runtime\s*\)') { continue }
        $depth = 0
        $opened = $false
        for ($j = $i; $j -lt $Lines.Count; $j++) {
            $l = $Lines[$j]
            $depth += ([regex]::Matches($l, '\{')).Count
            $depth -= ([regex]::Matches($l, '\}')).Count
            if (-not $opened -and $depth -gt 0) { $opened = $true }
            if ($opened -and $depth -le 0) {
                [void]$blocks.Add([pscustomobject]@{ Start = $i; End = $j })
                $i = $j
                break
            }
            if ($j -eq $Lines.Count - 1) { [void]$blocks.Add([pscustomobject]@{ Start = $i; End = $j }) }
        }
    }
    return $blocks
}

$script:NoneArmPattern = '^(?<indent>\s*)\.none(?<sp>\s*)=>(?<sp2>\s*)(?<body>void|\{\}),(?<tail>\s*)$'

# A block is already complete if some arm names .win32 or an else catches it.
function Test-BlockCoversWin32 {
    param([string[]]$Lines, [pscustomobject]$Block)
    $body = @()
    for ($k = $Block.Start; $k -le $Block.End; $k++) { $body += $Lines[$k] }
    $joined = ($body -join "`n")
    if ($joined -cmatch '\.win32\b') { return $true }
    if ($joined -cmatch '(?m)^\s*else\s*=>') { return $true }
    return $false
}

function Invoke-ApprtArmApply {
    param([string[]]$Lines)
    $hits = New-Object System.Collections.ArrayList
    foreach ($b in (Get-ApprtSwitchBlocks $Lines)) {
        if (Test-BlockCoversWin32 $Lines $b) { continue }
        for ($k = $b.Start; $k -le $b.End; $k++) {
            $m = [regex]::Match($Lines[$k], $script:NoneArmPattern)
            if (-not $m.Success) { continue }
            $Lines[$k] = ('{0}.none, .win32{1}=>{2}{3},{4}' -f `
                    $m.Groups['indent'].Value, $m.Groups['sp'].Value, $m.Groups['sp2'].Value, `
                    $m.Groups['body'].Value, $m.Groups['tail'].Value)
            [void]$hits.Add($k + 1)
        }
    }
    return [pscustomobject]@{ Lines = $Lines; Hits = $hits }
}

function Get-ApprtArmFindings {
    param([string[]]$Lines)
    $findings = New-Object System.Collections.ArrayList
    foreach ($b in (Get-ApprtSwitchBlocks $Lines)) {
        if (Test-BlockCoversWin32 $Lines $b) { continue }
        $widened = $false
        for ($k = $b.Start; $k -le $b.End; $k++) {
            if ($Lines[$k] -cmatch $script:NoneArmPattern) {
                $widened = $true
                [void]$findings.Add([pscustomobject]@{
                        Line   = $k + 1
                        Text   = $Lines[$k].Trim()
                        Detail = 'app_runtime switch arm does not cover .win32 (apply rewrites this)'
                    })
            }
        }
        # No `.none => void,` to widen and still nothing covering .win32: the
        # arm has to be written by hand (src\apprt.zig maps members to modules).
        if (-not $widened) {
            [void]$findings.Add([pscustomobject]@{
                    Line   = $b.Start + 1
                    Text   = $Lines[$b.Start].Trim()
                    Detail = 'app_runtime switch has no .win32 arm and no else (needs a hand-written arm)'
                })
        }
    }
    return $findings
}

# ---------------------------------------------------------------------------
# Per-file work
# ---------------------------------------------------------------------------
function Invoke-FileApply {
    param([pscustomobject]$File)

    $read = Read-TextFile $File.Full
    $lines = @($read.Text -split "`n")
    $ruleHits = @{}

    foreach ($rule in $script:Rules) {
        if (-not (Test-Scope $File.Relative $rule.Include $rule.Exclude)) { continue }

        if ($rule.Kind -eq 'apprt-arm') {
            $r = Invoke-ApprtArmApply $lines
            $lines = $r.Lines
            if ($r.Hits.Count -gt 0) { $ruleHits[$rule.Name] = $r.Hits.Count }
            continue
        }

        $count = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (Test-Allowed $lines[$i] $rule.Allow) { continue }
            foreach ($pair in $rule.Pairs) {
                $before = $lines[$i]
                if ($before -cnotmatch $pair.Find) { continue }
                $lines[$i] = [regex]::Replace($before, $pair.Find, $pair.Replace)
                if ($lines[$i] -ne $before) { $count++ }
            }
        }
        if ($count -gt 0) { $ruleHits[$rule.Name] = $count }
    }

    $out = ($lines -join "`n")
    $changed = ($out -ne $read.Text)
    if ($changed -and -not $DryRun) { Write-TextFile $File.Full $out ([bool]$read.Bom) }
    return [pscustomobject]@{ Changed = $changed; Rules = $ruleHits }
}

function Invoke-FileCheck {
    param([pscustomobject]$File)

    $read = Read-TextFile $File.Full
    $lines = @($read.Text -split "`n")
    $findings = New-Object System.Collections.ArrayList

    foreach ($rule in $script:Rules) {
        if (-not (Test-Scope $File.Relative $rule.Include $rule.Exclude)) { continue }

        if ($rule.Kind -eq 'apprt-arm') {
            foreach ($f in (Get-ApprtArmFindings $lines)) {
                [void]$findings.Add([pscustomobject]@{
                        File = $File.Relative; Rule = $rule.Name; Line = $f.Line
                        Text = $f.Text; Detail = $f.Detail
                    })
            }
            continue
        }

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (Test-Allowed $lines[$i] $rule.Allow) { continue }
            foreach ($pair in $rule.Pairs) {
                if ($lines[$i] -cnotmatch $pair.Find) { continue }
                [void]$findings.Add([pscustomobject]@{
                        File = $File.Relative; Rule = $rule.Name; Line = $i + 1
                        Text = $lines[$i].Trim(); Detail = ('upstream identity survives ({0})' -f $pair.Find)
                    })
                break
            }
        }
    }
    return $findings
}

# ---------------------------------------------------------------------------
# Coverage (T1027): does the rule table still account for the fork's identity?
#
# Every rule matches the UPSTREAM spelling it was written against, which makes
# `check` blind by construction to identity this fork introduces LATER: a new
# branded URL, a second bundle-id-shaped constant, another apprt switch shape.
# A merge stage would take such a file from upstream whole, `apply` would have
# nothing to say about it, and `check` would be green - the fork's string
# silently gone.
#
# So this re-derives the question from the live delta instead of the rule
# table. It diffs Base..Head over the files upstream also has (modified, never
# added: a file only the fork has never arrives from upstream), pairs each
# added line that carries fork identity with the removed line it replaced, and
# keeps the pairs that are IDENTITY-SHAPED - the line differs from its upstream
# counterpart only by the identity it carries. Each such pair is then replayed:
# the rules in scope for that file are run over the upstream line, and the pair
# is accounted for only if that reproduces the fork line exactly. Whatever is
# left is a string the overlay would lose at the next merge stage.
#
# A pair a human has to carry on purpose is listed in $script:Acknowledged
# with its reason, which is the same contract as a rule's Allow list: narrow,
# named, and visible in the output, never a silent skip.
# ---------------------------------------------------------------------------

# Identity this fork writes, and what it replaced.
$script:ForkToken = '(?i)ghoztty|dzearing'
$script:UpstreamToken = '(?i)ghostty|mitchellh'

# Pairs that no rule mechanizes and that is deliberate. Each entry names the
# file (a scope glob) and a pattern on the FORK line; both must match.
$script:Acknowledged = @()

# Run every in-scope rule over one line, exactly as `apply` would. The apprt
# arm rule is structural in `apply`; at line level it is the same rewrite of a
# `.none => void,` arm, which is all a single diff line can carry.
function Invoke-RulesOnLine {
    param([string]$Relative, [string]$Line)
    $out = $Line
    foreach ($rule in $script:Rules) {
        if (-not (Test-Scope $Relative $rule.Include $rule.Exclude)) { continue }
        if ($rule.Kind -eq 'apprt-arm') {
            $m = [regex]::Match($out, $script:NoneArmPattern)
            if ($m.Success) {
                $out = ('{0}.none, .win32{1}=>{2}{3},{4}' -f `
                        $m.Groups['indent'].Value, $m.Groups['sp'].Value, $m.Groups['sp2'].Value, `
                        $m.Groups['body'].Value, $m.Groups['tail'].Value)
            }
            continue
        }
        if (Test-Allowed $out $rule.Allow) { continue }
        foreach ($pair in $rule.Pairs) {
            if ($out -cmatch $pair.Find) { $out = [regex]::Replace($out, $pair.Find, $pair.Replace) }
        }
    }
    return $out
}

# The fork line with its identity spelled the upstream way. Equality with the
# removed line is the strong form of "this pair differs only by identity".
function ConvertTo-UpstreamForm {
    param([string]$Line)
    $s = $Line -creplace 'ghoztty', 'ghostty' -creplace 'Ghoztty', 'Ghostty' -creplace 'GHOZTTY', 'GHOSTTY'
    $s = $s -creplace 'dzearing', 'mitchellh'
    $s = $s -creplace ', \.win32\b', '' -creplace '\.win32, ', ''
    return $s
}

# Classify a candidate pair. Strong: the fork line IS the upstream line with
# identity substituted. Weak: the two share at least half their text, and the
# part that differs carries fork identity on one side and upstream identity on
# the other - the shape of a re-pointed URL, whose host and path both move.
# Anything else is a feature line that happens to mention the product name.
function Get-PairShape {
    param([string]$Removed, [string]$Added)
    if ((ConvertTo-UpstreamForm $Added) -ceq $Removed) { return 'strong' }
    $p = 0
    $max = [Math]::Min($Removed.Length, $Added.Length)
    while ($p -lt $max -and $Removed[$p] -ceq $Added[$p]) { $p++ }
    $s = 0
    while ($s -lt ($max - $p) -and $Removed[$Removed.Length - 1 - $s] -ceq $Added[$Added.Length - 1 - $s]) { $s++ }
    $longer = [Math]::Max($Removed.Length, $Added.Length)
    if ($longer -eq 0 -or ($p + $s) -lt (0.5 * $longer)) { return $null }
    # Widen the differing region out to whole words. `ghostty.org` and
    # `ghoztty.dev` share `gho` and a common-prefix cut would leave `ztty` in
    # the middle - which names neither side's identity.
    while ($p -gt 0 -and [char]::IsLetterOrDigit($Added[$p - 1])) { $p-- }
    while ($s -gt 0 -and [char]::IsLetterOrDigit($Added[$Added.Length - $s])) { $s-- }
    $midA = $Added.Substring($p, $Added.Length - $p - $s)
    $midR = $Removed.Substring($p, $Removed.Length - $p - $s)
    if ($midA -match $script:ForkToken -and $midR -match $script:UpstreamToken) { return 'weak' }
    return $null
}

function Test-Acknowledged {
    param([string]$Relative, [string]$Added)
    foreach ($a in $script:Acknowledged) {
        if (-not ($Relative -match (ConvertTo-ScopeRegex $a.File))) { continue }
        if ($Added -cmatch $a.Pattern) { return $a }
    }
    return $null
}

# Hunks of `git diff -U0 Base Head`, over files upstream also has.
function Get-DeltaHunks {
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $pathspec = @('.') + @($script:GlobalExclude | ForEach-Object { ":(exclude,glob)$_" })
        $raw = @(& git -C $Path -c core.quotepath=off diff --no-color --no-ext-diff -U0 `
                    --diff-filter=M $Base $Head -- @pathspec 2>$null)
        $code = $LASTEXITCODE
    } finally { [Console]::OutputEncoding = $prevEnc }
    if ($code -ne 0) { throw "git diff $Base $Head failed (exit $code) in $Path" }

    $hunks = New-Object System.Collections.ArrayList
    $file = $null
    $cur = $null
    $inHunk = $false
    foreach ($l in $raw) {
        if ($l.StartsWith('diff --git ')) {
            $m = [regex]::Match($l, '^diff --git a/(.+) b/(.+)$')
            $file = $null
            if ($m.Success) { $file = $m.Groups[2].Value }
            $inHunk = $false
            continue
        }
        if ($l.StartsWith('@@')) {
            $m = [regex]::Match($l, '\+(\d+)')
            $cur = [pscustomobject]@{
                File    = $file
                NewLine = [int]$m.Groups[1].Value
                Removed = New-Object System.Collections.ArrayList
                Added   = New-Object System.Collections.ArrayList
            }
            [void]$hunks.Add($cur)
            $inHunk = $true
            continue
        }
        if (-not $inHunk -or $null -eq $file) { continue }
        if ($l.StartsWith('-')) { [void]$cur.Removed.Add($l.Substring(1).TrimEnd("`r")) }
        elseif ($l.StartsWith('+')) { [void]$cur.Added.Add($l.Substring(1).TrimEnd("`r")) }
    }
    return $hunks
}

# The known ledger is keyed by file and fork-line text, never by line number:
# line numbers move with every unrelated edit above them, and a ledger that
# churned on those would be rewritten on every run and read by nobody.
function Get-PairKey {
    param([pscustomobject]$Pair)
    return ('{0}|{1}' -f $Pair.File, $Pair.Fork)
}

function Read-KnownLedger {
    $set = @{}
    if (-not $Known -or -not (Test-Path -LiteralPath $Known)) { return $null }
    $doc = Get-Content -LiteralPath $Known -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in @($doc.pairs)) { $set[('{0}|{1}' -f $p.file, $p.fork)] = $true }
    return $set
}

function Write-KnownLedger {
    param([object[]]$Open)
    $seen = @{}
    $rows = New-Object System.Collections.ArrayList
    foreach ($p in ($Open | Sort-Object File, Fork)) {
        $k = Get-PairKey $p
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        [void]$rows.Add([ordered]@{ file = $p.File; upstream = $p.Upstream; fork = $p.Fork })
    }
    $doc = [ordered]@{
        note  = 'T1027. Identity pairs in the fork delta that no fork-identity rule reproduces and nobody has acknowledged, as of the recording. `scripts\fork-identity.ps1 coverage` reports these as KNOWN and fails only on a pair missing from here. The ledger only shrinks (coverage -Record): close a pair by writing the rule, or acknowledge it in the script with a reason - never by adding it here.'
        base  = $Base
        pairs = $rows
    }
    $json = ($doc | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Known, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return $rows.Count
}

function Invoke-Coverage {
    $pairs = New-Object System.Collections.ArrayList
    foreach ($h in (Get-DeltaHunks)) {
        if ($h.Removed.Count -eq 0) { continue }
        $used = @{}
        for ($ai = 0; $ai -lt $h.Added.Count; $ai++) {
            $a = $h.Added[$ai]
            if ($a -notmatch $script:ForkToken -and $a -cnotmatch '\.win32\b') { continue }

            # Strong partner first; otherwise the weak partner sharing the most
            # text. A removed line is consumed once, so two fork lines cannot
            # both claim the same upstream line.
            $best = -1; $bestShape = $null
            for ($ri = 0; $ri -lt $h.Removed.Count; $ri++) {
                if ($used.ContainsKey($ri)) { continue }
                $shape = Get-PairShape $h.Removed[$ri] $a
                if ($shape -eq 'strong') { $best = $ri; $bestShape = $shape; break }
                if ($shape -eq 'weak' -and $best -lt 0) { $best = $ri; $bestShape = $shape }
            }
            if ($best -lt 0) { continue }
            $used[$best] = $true
            $r = $h.Removed[$best]

            $replayed = Invoke-RulesOnLine $h.File $r
            $verdict = 'unaccounted'
            $why = $null
            if ($replayed -ceq $a) { $verdict = 'covered' }
            else {
                $ack = Test-Acknowledged $h.File $a
                if ($ack) { $verdict = 'acknowledged'; $why = $ack.Why }
            }
            [void]$pairs.Add([pscustomobject]@{
                    File     = $h.File
                    Line     = $h.NewLine + $ai
                    Shape    = $bestShape
                    Verdict  = $verdict
                    Upstream = $r.Trim()
                    Fork     = $a.Trim()
                    Replayed = $replayed.Trim()
                    Why      = $why
                })
        }
    }
    return $pairs
}

# ---------------------------------------------------------------------------

function Write-Line { param([string]$M) if (-not $Quiet) { Write-Host $M } }

$subjects = @()
if ($Action -ne 'coverage') { $subjects = @(Get-SubjectFiles) }

switch ($Action) {

    'coverage' {
        $pairs = @(Invoke-Coverage)
        $ledger = Read-KnownLedger
        foreach ($p in $pairs) {
            if ($p.Verdict -eq 'unaccounted' -and $null -ne $ledger -and $ledger.ContainsKey((Get-PairKey $p))) {
                $p.Verdict = 'known'
            }
        }
        $new = @($pairs | Where-Object { $_.Verdict -eq 'unaccounted' })
        $knownPairs = @($pairs | Where-Object { $_.Verdict -eq 'known' })
        $acked = @($pairs | Where-Object { $_.Verdict -eq 'acknowledged' })
        $covered = @($pairs | Where-Object { $_.Verdict -eq 'covered' })
        $failing = $new.Count
        if ($Strict) { $failing += $knownPairs.Count }

        # A ledger entry no live pair matches any more was closed by a rule (or
        # its line left the delta); -Record is how that progress is banked.
        $stale = 0
        if ($null -ne $ledger) {
            $live = @{}
            foreach ($p in $knownPairs) { $live[(Get-PairKey $p)] = $true }
            $stale = @($ledger.Keys | Where-Object { -not $live.ContainsKey($_) }).Count
        }

        $recorded = $null
        if ($Record) {
            if ($null -ne $ledger -and $new.Count -gt 0) {
                Write-Line ("FORK-IDENTITY COVERAGE: -Record REFUSED - {0} pair(s) are not in the ledger, and it only shrinks." -f $new.Count)
                Write-Line '  write a rule for them, or acknowledge them in scripts\fork-identity.ps1 with a reason'
                exit 1
            }
            $recorded = Write-KnownLedger (@($new) + @($knownPairs))
            # Only reachable with new pairs on the FIRST recording; what was
            # just written down is known from here on, in this run too.
            foreach ($p in $new) { $p.Verdict = 'known' }
            $knownPairs = @($pairs | Where-Object { $_.Verdict -eq 'known' })
            $new = @()
            $stale = 0
            $failing = 0
            if ($Strict) { $failing = $knownPairs.Count }
        }

        if ($Json) {
            [pscustomobject]@{
                action       = 'coverage'
                path         = $Path
                base         = $Base
                head         = $Head
                ledger       = $Known
                pairs        = $pairs.Count
                covered      = $covered.Count
                acknowledged = $acked.Count
                known        = $knownPairs.Count
                stale        = $stale
                unaccounted  = $new.Count
                findings     = @($new)
                knownPairs   = @($knownPairs)
            } | ConvertTo-Json -Depth 5
            if ($failing -gt 0) { exit 1 }
            exit 0
        }

        Write-Line ''
        $show = @($new)
        if ($Strict) { $show += $knownPairs }
        foreach ($x in $show) {
            Write-Line ("  {0}:{1}  [{2}, {3}] no rule reproduces this fork identity" -f $x.File, $x.Line, $x.Shape, $x.Verdict)
            Write-Line ("      upstream: {0}" -f $x.Upstream)
            Write-Line ("      fork:     {0}" -f $x.Fork)
            if ($x.Replayed -cne $x.Upstream) { Write-Line ("      rules give: {0}" -f $x.Replayed) }
        }
        $summary = ('{0} identity pair(s) in {1}..{2}: {3} reproduced by a rule, {4} acknowledged, {5} known' -f `
                $pairs.Count, $Base, $Head, $covered.Count, $acked.Count, $knownPairs.Count)
        if ($knownPairs.Count -gt 0 -and -not $Strict) {
            Write-Line ("  {0} known pair(s) in {1} file(s) are still unaccounted (the ledger, {2}); -Strict lists them" -f `
                    $knownPairs.Count, @($knownPairs | Group-Object File).Count, $Known)
        }
        if ($stale -gt 0) { Write-Line ("  {0} ledger entr(ies) no longer occur - bank that with: coverage -Record" -f $stale) }
        if ($null -ne $recorded) { Write-Line ("  ledger recorded: {0} pair(s) -> {1}" -f $recorded, $Known) }
        if ($failing -eq 0) {
            Write-Line ("FORK-IDENTITY COVERAGE: CLEAN - {0}" -f $summary)
            exit 0
        }
        Write-Line ("FORK-IDENTITY COVERAGE: {0} unaccounted in {1} file(s) - {2}" -f `
                $failing, @($show | Group-Object File).Count, $summary)
        Write-Line '  each one is identity the overlay would drop at the next merge stage:'
        Write-Line '  add or widen a rule in scripts\fork-identity.ps1, or acknowledge it there with a reason'
        exit 1
    }

    'rules' {
        if ($Json) {
            $script:Rules | Select-Object Name, Kind, Why, Include, Exclude, Allow, `
            @{ n = 'Patterns'; e = { @($_.Pairs | ForEach-Object { $_.Find }) } } | ConvertTo-Json -Depth 5
            exit 0
        }
        Write-Line ''
        Write-Line 'fork-identity overlay rules'
        foreach ($r in $script:Rules) {
            Write-Line ''
            Write-Line ("  {0}  [{1}]" -f $r.Name, $r.Kind)
            Write-Line ("    why:     {0}" -f $r.Why)
            Write-Line ("    scope:   {0}" -f ($r.Include -join ', '))
            if ($r.Exclude.Count -gt 0) { Write-Line ("    except:  {0}" -f ($r.Exclude -join ', ')) }
            if ($r.Allow.Count -gt 0) { Write-Line ("    allowed: {0}" -f ($r.Allow -join ', ')) }
            foreach ($p in $r.Pairs) { Write-Line ("    rewrite: {0}  ->  {1}" -f $p.Find, $p.Replace) }
        }
        Write-Line ''
        Write-Line ("  {0} rules over {1} files in {2}" -f $script:Rules.Count, $subjects.Count, $Path)
        exit 0
    }

    'apply' {
        $changedFiles = New-Object System.Collections.ArrayList
        $totals = @{}
        foreach ($f in $subjects) {
            if (Test-BinaryFile $f.Full) { continue }
            $anyScope = $false
            foreach ($r in $script:Rules) {
                if (Test-Scope $f.Relative $r.Include $r.Exclude) { $anyScope = $true; break }
            }
            if (-not $anyScope) { continue }

            $res = Invoke-FileApply $f
            if (-not $res.Changed) { continue }
            [void]$changedFiles.Add([pscustomobject]@{ File = $f.Relative; Rules = $res.Rules })
            foreach ($k in $res.Rules.Keys) {
                if (-not $totals.ContainsKey($k)) { $totals[$k] = 0 }
                $totals[$k] += $res.Rules[$k]
            }
        }

        if ($Json) {
            [pscustomobject]@{
                action  = 'apply'
                path    = $Path
                dryRun  = [bool]$DryRun
                files   = @($changedFiles | ForEach-Object { $_.File })
                changed = $changedFiles.Count
                rules   = $totals
            } | ConvertTo-Json -Depth 5
            exit 0
        }

        $verb = 'rewrote'
        if ($DryRun) { $verb = 'would rewrite' }
        Write-Line ''
        foreach ($c in $changedFiles) {
            $detail = @($c.Rules.Keys | Sort-Object | ForEach-Object { "$_ x$($c.Rules[$_])" }) -join ', '
            Write-Line ("  {0}  ({1})" -f $c.File, $detail)
        }
        if ($changedFiles.Count -eq 0) {
            Write-Line ("FORK-IDENTITY: no change - {0} already carries the fork identity" -f $Path)
        } else {
            $ruleSummary = @($totals.Keys | Sort-Object | ForEach-Object { "$_ x$($totals[$_])" }) -join ', '
            Write-Line ("FORK-IDENTITY: {0} {1} file(s) [{2}]" -f $verb, $changedFiles.Count, $ruleSummary)
        }
        exit 0
    }

    'check' {
        $all = New-Object System.Collections.ArrayList
        foreach ($f in $subjects) {
            if (Test-BinaryFile $f.Full) { continue }
            $anyScope = $false
            foreach ($r in $script:Rules) {
                if (Test-Scope $f.Relative $r.Include $r.Exclude) { $anyScope = $true; break }
            }
            if (-not $anyScope) { continue }
            foreach ($x in (Invoke-FileCheck $f)) { [void]$all.Add($x) }
        }

        if ($Json) {
            [pscustomobject]@{
                action   = 'check'
                path     = $Path
                findings = @($all)
                count    = $all.Count
            } | ConvertTo-Json -Depth 5
            if ($all.Count -gt 0) { exit 1 }
            exit 0
        }

        Write-Line ''
        foreach ($x in $all) {
            Write-Line ("  {0}:{1}  [{2}] {3}" -f $x.File, $x.Line, $x.Rule, $x.Detail)
            Write-Line ("      {0}" -f $x.Text)
        }
        if ($all.Count -eq 0) {
            Write-Line ("FORK-IDENTITY CHECK: CLEAN - no upstream identity survives in {0}" -f $Path)
            exit 0
        }
        $byRule = @($all | Group-Object Rule | Sort-Object Name | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
        Write-Line ("FORK-IDENTITY CHECK: {0} finding(s) in {1} file(s) [{2}]" -f `
                $all.Count, @($all | Group-Object File).Count, $byRule)
        Write-Line '  run:  powershell -NoProfile -File scripts\fork-identity.ps1 apply'
        exit 1
    }
}
