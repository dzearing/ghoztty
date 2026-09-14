# window-active-audit acceptance (T730): product code asks "is this window the
# active one" through `window_active`, never by comparing `GetForegroundWindow`
# itself.
#
#   powershell -NoProfile -File test\win32\window-active-audit.ps1
#
# Non-interactive, launches no Ghoztty and touches no user state: the subject is
# SOURCE TEXT, so this reads .zig files and spawns nothing.
#
# isolation: none - a static audit over source text; nothing here launches
# ghoztty or runs a CLI verb (T680 meta-check reads this marker).
#
# Why it exists. T215 replaced every product read of `GetForegroundWindow` with
# `window_active.isActive` / `shouldForwardFocus` fed by `w32.activation()`,
# because there is no foreground window AT ALL on a background desktop - the one
# `lib\TestDesktop.ps1` runs the GUI on, and equally a locked workstation, a UAC
# secure desktop or a disconnected RDP session. A guard written as
# `GetForegroundWindow() == hwnd` does not fail there; it answers "no" forever,
# with no error and no log line. T211 found the first instance only because
# keyboard focus could not move between panes at all.
#
# That makes the rule a TEST-VISIBLE contract with no in-app symptom on the
# desktop a developer is sitting on: the old spelling still compiles, still
# reads correctly, and still passes every interactive check. The rule is written
# down in `src\apprt\win32\window_active.zig`, and a rule that lives only in a
# doc comment is one the next site can miss - which is how the original four
# sites survived. So it is checked here instead.
#
# THE RULE, in the form this file checks:
#
#     A `GetForegroundWindow` or `GetActiveWindow` reference in CODE under
#     `src\apprt\win32\` is a finding, unless the file is one of the two that
#     own the API, or the site carries a `// foreground-audit: <reason>` marker.
#
# Prose does not count: a `//`, `///` or `//!` comment naming either API is a
# mention, and both `window_active.zig` and this very file are full of them. The
# marker is the same state-your-intent convention the `# persistence:`,
# `# exitcode-audit:` and `# body-audit:` markers use, and it must sit on the
# site's own line or within the 10 lines above it, so it names A SITE rather
# than blanketing a file.
#
# The two owning files, and why each is allowed:
#
#   * `win32.zig`        - declares both externs and makes the ONE call to each,
#                          inside `activation()`. That call is the mechanism the
#                          rule routes everything through.
#   * `window_active.zig` - the rule itself. It has no win32 imports at all, so
#                          every reference in it is already prose; it is listed
#                          so a future helper added there is not a finding.
#
# Section A gives the analyzer teeth against fixtures, both directions; section B
# is the sweep over the real tree, which must stay at zero; section C proves the
# SWEEP (not merely the analyzer) goes red on a planted violation and green again
# once the marker is added; section D fails a stale allowlist entry.
param(
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0

function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name$(if ($detail) { " -- $detail" })"; $script:failures++ }
}

# The APIs the rule is about. `SetForegroundWindow` is deliberately NOT here: it
# is an ACTION, not a reading of activation, and flagging it would put the whole
# quick-terminal and window-raise family on the exemption list for no defect.
$script:ForegroundApis = @('GetForegroundWindow', 'GetActiveWindow')

# How far above a site the marker may sit. Wide enough for a real explanation
# (the QuickTerminal one runs to five lines), narrow enough that a marker cannot
# excuse a site added later in the same function.
$script:MarkerReach = 10

# Findings for one file's text: every CODE reference to one of the APIs that is
# not covered by a marker. Line numbers are 1-based, so a finding can be opened.
#
# "Code" is the part of the line before its first `//`. That is a cut rather
# than a parse, and the one thing it gets wrong - an API name inside a string
# literal that also contains `//` - does not occur in this tree and could only
# ever make the sweep miss a site, never invent one.
function Get-WindowActiveFindings {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = $Text -split "`r?`n"
    $pattern = '(' + ($script:ForegroundApis -join '|') + ')'
    $findings = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $cut = $line.IndexOf('//')
        $code = if ($cut -ge 0) { $line.Substring(0, $cut) } else { $line }
        $m = [regex]::Match($code, $pattern)
        if (-not $m.Success) { continue }

        # A marker on this line, or in the window above it, states the intent.
        $from = [Math]::Max(0, $i - $script:MarkerReach)
        $window = $lines[$from..$i]
        if (($window -join "`n") -match '//\s*foreground-audit:') { continue }

        $findings += [pscustomobject]@{
            Line = $i + 1
            Api  = $m.Groups[1].Value
            Text = $line.Trim()
        }
    }
    return , @($findings)
}

# The files allowed to reference the APIs without a per-site marker, and why.
# An entry here is a visible edit to the audit, which is the point: the list is
# two files long and is not meant to grow.
$exempt = @{
    'win32.zig'        = 'declares both externs and makes the one call to each, inside activation()'
    'window_active.zig' = 'is the rule; it has no win32 imports, so every reference in it is prose'
}

# The sweep, factored out so section C can point it at a planted tree.
function Invoke-WindowActiveSweep {
    param([Parameter(Mandatory = $true)][string]$Dir)

    $scanned = @()
    $offenders = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Dir -Filter '*.zig' -Recurse)) {
        $text = Get-Content -LiteralPath $f.FullName -Raw
        if (-not $text) { continue }
        $scanned += $f.Name
        if ($exempt.ContainsKey($f.Name)) { continue }
        foreach ($find in (Get-WindowActiveFindings -Text $text)) {
            $offenders += [pscustomobject]@{
                File = $f.Name; Line = $find.Line; Api = $find.Api; Text = $find.Text
            }
        }
    }
    return [pscustomobject]@{ Scanned = @($scanned); Offenders = @($offenders) }
}

# ============================================================================
"== A: the analyzer catches the shape it exists for, and only that shape"
# ============================================================================

$bare = @(
    'fn ownerWindow(self: *App) ?*Window {',
    '    const fg = w32.GetForegroundWindow();',
    '    for (self.windows.items) |win| {',
    '        if (win.hwnd) |wh| if (wh == fg) return win;',
    '    }',
    '    return null;',
    '}'
) -join "`n"
$found = Get-WindowActiveFindings -Text $bare
Assert 'A1 a bare GetForegroundWindow comparison is a finding' ($found.Count -eq 1) `
    ("found " + $found.Count)
Assert 'A2 the finding names the line and the api' `
    ($found.Count -eq 1 -and $found[0].Line -eq 2 -and $found[0].Api -eq 'GetForegroundWindow') `
    ($found | ForEach-Object { "$($_.Line):$($_.Api)" })

# GetActiveWindow is the same defect wearing the other name: T215's rule routes
# BOTH through activation(), because a site that reaches for the thread-scoped
# one directly has still bypassed the decision.
$active = '    if (w32.GetActiveWindow() != parent_hwnd) return;'
Assert 'A3 a bare GetActiveWindow comparison is a finding too' `
    ((Get-WindowActiveFindings -Text $active).Count -eq 1)

# The trap that would otherwise make this sweep permanently green: the module
# that DOCUMENTS the rule names the API in every other sentence, and so does
# this file. A mention is not a call.
$prose = @(
    '//! The obvious way to ask is `GetForegroundWindow`, and every site that',
    '//! used to ask it that way was silently always-false.',
    '/// `GetActiveWindow()` on the GUI thread. Queue-scoped.',
    '    // T215: not GetForegroundWindow() == hwnd; see window_active.zig.',
    '    const act = w32.activation();'
) -join "`n"
Assert 'A4 a comment naming either api is not a call' `
    ((Get-WindowActiveFindings -Text $prose).Count -eq 0) `
    ((Get-WindowActiveFindings -Text $prose) | ForEach-Object { "$($_.Line): $($_.Text)" })

# A trailing comment on a real call line does not excuse the call: the cut takes
# the code half, and the code half still has the call in it.
$trailing = '    const fg = w32.GetForegroundWindow(); // harmless, surely'
Assert 'A5 a trailing comment does not hide the call on the same line' `
    ((Get-WindowActiveFindings -Text $trailing).Count -eq 1)

# The exemption, both halves: a marked site is clear, and the marker reaches
# only as far as it is allowed to.
$marked = @(
    '    // foreground-audit: this BECOMES the foreground window, it does not',
    '    // ask whether one of ours already is.',
    '    const fg = w32.GetForegroundWindow();'
) -join "`n"
Assert 'A6 a marked site is not a finding' `
    ((Get-WindowActiveFindings -Text $marked).Count -eq 0)

$farAway = @(
    '    // foreground-audit: the site this was written for.',
    '    const fg = w32.GetForegroundWindow();'
) -join "`n"
$filler = @('    _ = fg;') * ($script:MarkerReach + 1)
$farAway = $farAway + "`n" + ($filler -join "`n") + "`n" +
    '    const later = w32.GetForegroundWindow();'
$found = Get-WindowActiveFindings -Text $farAway
Assert 'A7 the marker does not blanket the rest of the file' ($found.Count -eq 1) `
    ("found " + $found.Count + ": " + (($found | ForEach-Object { $_.Text }) -join ' | '))

Assert 'A8 a file that never asks is not a finding' `
    ((Get-WindowActiveFindings -Text 'pub fn helper() void {}').Count -eq 0)

# ============================================================================
"== B: the sweep -- src\apprt\win32 asks through window_active"
# ============================================================================

$srcDir = Join-Path $Repo 'src\apprt\win32'
Assert 'B0 the source directory is where this expects it' (Test-Path -LiteralPath $srcDir) $srcDir

$sweep = $null
if (Test-Path -LiteralPath $srcDir) { $sweep = Invoke-WindowActiveSweep -Dir $srcDir }

# A sweep that finds nothing to sweep is not a green result, it is a broken
# path - the failure mode every audit in this suite has to rule out first.
Assert "B1 the sweep read the win32 sources ($(if ($sweep) { $sweep.Scanned.Count } else { 0 }) files)" `
    ($null -ne $sweep -and $sweep.Scanned.Count -ge 30)

Assert 'B2 no product site compares the foreground window itself' `
    ($null -ne $sweep -and $sweep.Offenders.Count -eq 0) `
    (($sweep.Offenders | ForEach-Object { "$($_.File):$($_.Line) $($_.Text)" }) -join ' | ')

# The marked sites, named in the output: an exemption nobody reads is an
# exemption nobody revisits.
if ($null -ne $sweep) {
    foreach ($f in (Get-ChildItem -LiteralPath $srcDir -Filter '*.zig' -Recurse)) {
        $text = Get-Content -LiteralPath $f.FullName -Raw
        if (-not $text) { continue }
        foreach ($m in [regex]::Matches($text, '//\s*foreground-audit:\s*(.+)')) {
            "  NOTE marked site: $($f.Name) -- $($m.Groups[1].Value.Trim())"
        }
    }
}

# ============================================================================
"== C: the sweep itself goes red on a planted violation (teeth)"
# ============================================================================

$plantDir = Join-Path ([System.IO.Path]::GetTempPath()) ("window-active-audit-" + [guid]::NewGuid().ToString('n'))
try {
    New-Item -ItemType Directory -Path $plantDir -Force | Out-Null
    $plant = Join-Path $plantDir 'Planted.zig'
    $violation = @(
        'pub fn isMine(self: *Window) bool {',
        '    return w32.GetForegroundWindow() == self.hwnd;',
        '}'
    ) -join "`n"
    Set-Content -LiteralPath $plant -Value $violation -Encoding ASCII

    $red = Invoke-WindowActiveSweep -Dir $plantDir
    Assert 'C1 a planted bare comparison is found by the sweep' ($red.Offenders.Count -eq 1) `
        (($red.Offenders | ForEach-Object { "$($_.File):$($_.Line)" }) -join ' | ')
    Assert 'C2 the finding names the planted file' `
        ($red.Offenders.Count -eq 1 -and $red.Offenders[0].File -eq 'Planted.zig')

    $marker = '    // foreground-audit: planted by test\win32\window-active-audit.ps1 section C.'
    Set-Content -LiteralPath $plant -Encoding ASCII -Value (@(
        'pub fn isMine(self: *Window) bool {',
        $marker,
        '    return w32.GetForegroundWindow() == self.hwnd;',
        '}'
    ) -join "`n")
    $green = Invoke-WindowActiveSweep -Dir $plantDir
    Assert 'C3 the same site with a marker is clear' ($green.Offenders.Count -eq 0) `
        (($green.Offenders | ForEach-Object { "$($_.File):$($_.Line)" }) -join ' | ')
} finally {
    if (Test-Path -LiteralPath $plantDir) {
        Remove-Item -LiteralPath $plantDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
"== D: the allowlist is still live"
# ============================================================================

# An allowlisted file that no longer references the APIs (renamed, deleted, or
# cleaned up) would silently excuse a future regression in a file of that name.
foreach ($name in $exempt.Keys) {
    $path = Join-Path $srcDir $name
    $text = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw } else { '' }
    $pattern = '(' + ($script:ForegroundApis -join '|') + ')'
    Assert "D1 the allowlist entry for $name is still live" ($text -match $pattern) `
        "listed as owning the api but no longer names it"
    "  NOTE allowlisted: $name -- $($exempt[$name])"
}

# --- stamp (T783 / T478) ---------------------------------------------------
# Only a CLEAN run stamps; a red one must stay due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard window-active-audit -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
