# printclient-audit acceptance (T940): every win32 window class that paints
# itself can also paint itself into somebody else's DC.
#
#   powershell -NoProfile -File test\win32\printclient-audit.ps1
#
# Non-interactive, launches no Ghoztty and touches no user state: the subject is
# SOURCE TEXT, so this reads .zig files and spawns nothing.
#
# isolation: none - a static audit over source text; nothing here launches
# ghoztty or runs a CLI verb (T680 meta-check reads this marker).
#
# Why it exists. `Get-TestWindowPixels` captures through
# `PrintWindow(PW_RENDERFULLCONTENT)`, which asks DWM for an ASYNCHRONOUS copy
# of the window's composited surface and returns before the copy has finished.
# T835 measured what that does to an assertion: three back-to-back captures of
# ONE UNCHANGED window read the end of the same table row at 1062, 1283 and
# 1179 px, and a P0 investigation went looking for that in the layout code. The
# cure is `-Sync` - `PrintWindow` with no flags, so the window paints the frame
# itself, synchronously - and it works only on a window whose WndProc answers
# `WM_PRINTCLIENT`.
#
# That makes the handler a TEST-VISIBLE contract with no in-app symptom: delete
# one and the app looks fine while every pixel assertion over that window goes
# back to measuring noise. Nothing at compile time notices, and nothing at run
# time notices either - which is how 65 probes across 34 scripts stayed on the
# torn capture for months (T843). So it is checked here instead: a class that
# handles WM_PAINT and not WM_PRINTCLIENT is a finding, and an exemption has to
# be written down with its reason.
#
# Section A gives the analyzer teeth against fixtures; section B is the sweep
# that must stay at zero. Section C (T944) is the call-site half: no probe in
# test\win32 takes the torn capture without `-Sync` or a stated `-TornReason`.
# Section D (T1406) defends the paint probe: no WM_PRINTCLIENT path may count a
# paint, and every probe surface must be counted from a WM_PAINT arm.
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

# A window class "paints itself" if its WndProc has a `w32.WM_PAINT =>` arm, and
# "can pose" if it has a `w32.WM_PRINTCLIENT =>` arm. Matched on the switch arm
# rather than on any mention of the constant, so a comment naming WM_PRINTCLIENT
# - and this file is full of prose that does - never counts as a handler.
function Get-PrintClientFindings {
    param([Parameter(Mandatory = $true)][string]$Text)
    $paints = [regex]::Matches($Text, '(?m)^\s*w32\.WM_PAINT\s*=>').Count
    $prints = [regex]::Matches($Text, '(?m)^\s*w32\.WM_PRINTCLIENT\s*=>').Count
    if ($paints -gt 0 -and $prints -eq 0) { return , @('paints but cannot pose') }
    return , @()
}

# The classes that are exempt, and why. An exemption lives here rather than in
# a comment in the source, so adding one is a visible edit to the audit.
#
# App.zig owns the TERMINAL SURFACE, whose pixels come from the renderer, not
# from GDI - `Get-TestWindowPixels` already refuses to capture it at all
# (T214: PrintWindow returns a flat fill for it off the input desktop, so an
# assertion over that capture passes against nothing). A WM_PRINTCLIENT handler
# there would produce exactly the blank frame the refusal exists to prevent.
#
# WindowPresenter.zig (T2614) is the same case one level up: the window
# presenter's pixels are the GL compose of every terminal pane, swapped by its
# own thread. Its WM_PAINT only validates and asks for a compose; a GDI pose of
# it would be the same blank frame.
$exempt = @{
    'App.zig' = 'the terminal surface is renderer-drawn; Get-TestWindowPixels refuses to capture it (T214)'
    'WindowPresenter.zig' = 'the window presenter is GL-composed by its own thread; WM_PAINT only validates (T2614)'
}

# ============================================================================
"== A: the analyzer catches the shape it exists for, and only that shape"
# ============================================================================

$bad = @(
    '    switch (msg) {',
    '        w32.WM_PAINT => {',
    '            var ps: w32.PAINTSTRUCT = undefined;',
    '            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;',
    '            defer _ = w32.EndPaint(hwnd, &ps);',
    '            self.paint(hdc);',
    '            return 0;',
    '        },',
    '    }'
) -join "`n"
Assert 'A1 a class that paints and cannot pose is a finding' `
((Get-PrintClientFindings -Text $bad).Count -eq 1)

# Built by hand rather than by patching $bad with `-replace`: in PS 5.1
# `-replace` binds tighter than `-join`, so `$s -replace 'x', @(...) -join "`n"`
# hands the operator the ARRAY (flattened with spaces) and joins afterwards.
# The first draft of this file did exactly that, and it collapsed a multi-line
# fixture onto one line - where the arm no longer starts a line, the analyzer
# saw no WM_PAINT at all, and the assertion failed for a reason that had nothing
# to do with what it was testing.
$goodArm = @(
    '        w32.WM_PRINTCLIENT => {',
    '            if (wparam == 0) return 0;',
    '            self.paint(@ptrFromInt(wparam));',
    '            return 0;',
    '        },'
) -join "`n"
$good = $bad -replace '(?m)^    \}$', ($goodArm + "`n" + '    }')
Assert 'A2 adding the handler clears the finding' `
((Get-PrintClientFindings -Text $good).Count -eq 0) $good

# The trap this analyzer would otherwise fall into: this very file, and several
# of the source files it judges, discuss WM_PRINTCLIENT in prose. A mention is
# not a handler, and scoring it as one would make the sweep permanently green.
$commented = $bad -replace '(?m)^(        w32\.WM_PAINT)', ('        // WM_PRINTCLIENT would go here one day.' + "`n" + '$1')
Assert 'A3 a COMMENT naming WM_PRINTCLIENT is not a handler' `
((Get-PrintClientFindings -Text $commented).Count -eq 1) $commented

# A file with no WndProc at all is not a finding - most of src/apprt/win32 is
# not a window class, and an audit that flagged them all would be ignored.
Assert 'A4 a file that never paints is not a finding' `
((Get-PrintClientFindings -Text 'pub fn helper() void {}').Count -eq 0)

# ============================================================================
"== B: the sweep -- every painting class in src/apprt/win32 can pose"
# ============================================================================

$srcDir = Join-Path $Repo 'src\apprt\win32'
Assert 'B0 the source directory is where this expects it' (Test-Path -LiteralPath $srcDir) $srcDir

$painters = @()
$offenders = @()
$exemptSeen = @()
if (Test-Path -LiteralPath $srcDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $srcDir -Filter '*.zig' -Recurse)) {
        $text = Get-Content -LiteralPath $f.FullName -Raw
        if (-not $text) { continue }
        if ([regex]::Matches($text, '(?m)^\s*w32\.WM_PAINT\s*=>').Count -eq 0) { continue }
        $painters += $f.Name
        if ((Get-PrintClientFindings -Text $text).Count -eq 0) { continue }
        if ($exempt.ContainsKey($f.Name)) { $exemptSeen += $f.Name; continue }
        $offenders += $f.Name
    }
}

# A sweep that finds nothing to sweep is not a green result, it is a broken
# path - the failure mode every audit in this suite has to rule out first.
Assert "B1 the sweep found the window classes ($($painters.Count) paint)" ($painters.Count -ge 8) `
    ($painters -join ', ')
Assert 'B2 no class paints itself without being able to pose' ($offenders.Count -eq 0) `
    ("still on the torn capture: " + ($offenders -join ', '))

foreach ($name in $exemptSeen) { "  NOTE exempt: $name -- $($exempt[$name])" }
# An exemption for a file that no longer paints (or no longer exists) is stale
# and would silently excuse a future regression in a file of the same name.
foreach ($name in $exempt.Keys) {
    Assert "B3 the exemption for $name is still live" ($painters -contains $name) `
        'listed as exempt but no longer handles WM_PAINT'
}

"  NOTE painting classes: $($painters -join ', ')"

# ============================================================================
"== C: the call sites -- no probe takes the torn capture without saying why (T944)"
# ============================================================================
# B proves every class we own CAN pose. C is the other half: every probe
# ASKS it to. A `Get-TestWindowPixels` call must carry `-Sync`, or
# `-TornReason '<why>'` for a window that is not ours to change. The function
# refuses the bare call at run time too; this catches it in a script nobody
# has run yet, which is how 65 probes stayed torn unremarked (T843).
#
# A call is `Get-TestWindowPixels -Window` outside a comment - matched that
# narrowly because this suite's prose names the function constantly, and
# backtick continuations are joined so a wrapped call is judged whole.
function Get-TornCallFindings {
    param([Parameter(Mandatory = $true)][string]$Text)
    $found = @()
    $inBlock = $false
    $joined = ''
    $n = 0
    foreach ($raw in ($Text -split "`r?`n")) {
        $n++
        $line = $raw
        if ($inBlock) {
            if ($line -match '#>') { $inBlock = $false; $line = $line.Substring($line.IndexOf('#>') + 2) } else { continue }
        }
        if ($line -match '<#') {
            $pre = $line.Substring(0, $line.IndexOf('<#'))
            if ($line.Substring($line.IndexOf('<#')) -notmatch '#>') { $inBlock = $true }
            $line = $pre
        }
        if ($line -match '^\s*#') { continue }
        if ($line -match '`\s*$') { $joined += ($line -replace '`\s*$', ' '); continue }
        $stmt = $joined + $line
        $joined = ''
        if ($stmt -notmatch 'Get-TestWindowPixels\s+-Window\b') { continue }
        if ($stmt -match '\s-Sync\b' -or $stmt -match '\s-TornReason\s+\S') { continue }
        # A call whose whole point is to be REFUSED carries this marker on its
        # own line, so the demonstration of the refusal is not itself a finding.
        if ($stmt -match '#\s*torn-refusal-fixture\b') { continue }
        $found += "line ${n}: $($stmt.Trim())"
    }
    return , $found
}

Assert 'C1 a bare call is a finding' `
((Get-TornCallFindings -Text '    $shot = Get-TestWindowPixels -Window $h').Count -eq 1)
Assert 'C2 -Sync clears it' `
((Get-TornCallFindings -Text '    $shot = Get-TestWindowPixels -Window $h -Sync').Count -eq 0)
Assert 'C3 -TornReason clears it' `
((Get-TornCallFindings -Text "    `$shot = Get-TestWindowPixels -Window `$m -TornReason 'user32 menu'").Count -eq 0)
Assert 'C4 prose naming the function is not a call' `
((Get-TornCallFindings -Text (@('# Get-TestWindowPixels -Window $h is torn', '<#', 'Get-TestWindowPixels -Window $x', '#>') -join "`n")).Count -eq 0)
Assert 'C5 a wrapped call is judged whole, flag on the continuation line' `
((Get-TornCallFindings -Text (@('$s = Get-TestWindowPixels -Window $h `', '    -Sync') -join "`n")).Count -eq 0)
Assert 'C6 a wrapped call with no flag is still a finding' `
((Get-TornCallFindings -Text (@('$s = Get-TestWindowPixels -Window $h `', '    -AllowUniform') -join "`n")).Count -eq 1)
Assert 'C6b the refusal-fixture marker excuses a deliberately bare call' `
((Get-TornCallFindings -Text '    try { Get-TestWindowPixels -Window $h } catch {}  # torn-refusal-fixture').Count -eq 0)
Assert 'C6c ...and only the call on its own line' `
((Get-TornCallFindings -Text (@('# torn-refusal-fixture', '$s = Get-TestWindowPixels -Window $h') -join "`n")).Count -eq 1)

$testDir = Join-Path $Repo 'test\win32'
$calls = 0
$torn = @()
$tornBare = @()
foreach ($f in (Get-ChildItem -LiteralPath $testDir -Filter '*.ps1' -Recurse)) {
    # This file's own fixtures above are calls by construction.
    if ($f.FullName -eq $PSCommandPath) { continue }
    $text = Get-Content -LiteralPath $f.FullName -Raw
    if (-not $text) { continue }
    $rel = $f.FullName.Substring($testDir.Length + 1)
    $calls += [regex]::Matches($text, 'Get-TestWindowPixels\s+-Window\b').Count
    foreach ($m in [regex]::Matches($text, 'Get-TestWindowPixels\s+-Window[^\r\n]*-TornReason')) { $torn += $rel }
    foreach ($x in (Get-TornCallFindings -Text $text)) { $tornBare += "$rel $x" }
}
Assert "C7 the sweep found the probes ($calls call sites)" ($calls -ge 50) "$calls"
Assert 'C8 every torn capture names its reason at the call site' ($tornBare.Count -eq 0) `
    ($tornBare -join ' | ')
"  NOTE torn by declaration: $($torn.Count) call site(s) in $((@($torn | Sort-Object -Unique)) -join ', ')"

# ============================================================================
"== D: the paint probe counts the app's own paints, never the camera's (T1406)"
# ============================================================================
# `src\apprt\win32\paint_probe.zig` counts a repaint from `WM_PAINT` and
# deliberately NOT from `WM_PRINTCLIENT`. That asymmetry is the whole oracle
# behind chrome-theme.ps1 section G (T1405): a paint the harness asked for must
# not read as the app repainting itself. Put `paint_probe.record` on a
# `WM_PRINTCLIENT` path - directly, or through a helper both arms share - and
# every G assertion goes permanently green with no symptom anywhere.
#
# So two halves, judged over the source text of the whole frontend:
#   NEGATIVE - no WM_PRINTCLIENT arm reaches a record call, at any depth.
#   POSITIVE - every declared `Surface` is recorded from a WM_PAINT arm, so a
#              probe that quietly stops counting is caught here and not only by
#              a red G1/G2 that nobody is looking at.
#
# "Reaches" is by function NAME, transitively, across every file: a function
# records if its body calls `<alias>.record(` or calls (by name) a function that
# records. Name-based reach over-approximates - two files' `paint` would be
# conflated - which can only produce a false finding, never a missed one; a
# finding is read, not obeyed. Comments and string literals are stripped first,
# because the very arms this judges carry prose about `paint_probe.record`.
# Arms are matched as switch arms, including the combined form
# `w32.WM_PAINT, w32.WM_PRINTCLIENT => {`, which is the likeliest way the
# asymmetry would be lost in a tidy-up.

# One regex pass: strings become "", char literals ' ', comments and Zig
# multiline-string lines vanish. Braces inside any of them would otherwise
# unbalance the body matcher (format strings are full of `{d}`).
$script:zigStrip = [regex]'"(?:\\.|[^"\\\n])*"|''(?:\\.|[^''\\\n])+''|//[^\n]*|\\\\[^\n]*'
function Get-ZigStripped([string]$Text) {
    return $script:zigStrip.Replace($Text, {
        param($m)
        $v = $m.Value
        if ($v.StartsWith('"')) { return '""' }
        if ($v.StartsWith("'")) { return "' '" }
        return ''
    })
}

# A balanced `{...}` starting exactly at an index (.NET balancing groups, so
# a 20k-line file is matched at regex speed rather than char by char in PS).
$script:braceBlock = [regex]'\G\{(?>[^{}]+|\{(?<d>)|\}(?<-d>))*(?(d)(?!))\}'

function Get-BlockAt([string]$Text, [int]$Open) {
    $m = $script:braceBlock.Match($Text, $Open)
    if ($m.Success) { return $m.Value }
    return $null
}

# Every `fn name(...) ... {body}` in stripped text. Declarations with no body
# (`extern fn ...;`) end at a `;` before any `{` and are skipped.
function Get-ZigFunctions([string]$Clean) {
    $out = @()
    foreach ($m in [regex]::Matches($Clean, '(?m)^[ \t]*(?:pub[ \t]+)?(?:export[ \t]+|inline[ \t]+)?fn[ \t]+(\w+)[ \t]*\(')) {
        $i = $m.Index + $m.Length
        $depth = 1
        while ($i -lt $Clean.Length -and $depth -gt 0) {
            $c = $Clean[$i]
            if ($c -eq '(') { $depth++ } elseif ($c -eq ')') { $depth-- }
            $i++
        }
        $brace = $Clean.IndexOf('{', $i)
        $semi = $Clean.IndexOf(';', $i)
        if ($brace -lt 0 -or ($semi -ge 0 -and $semi -lt $brace)) { continue }
        $body = Get-BlockAt $Clean $brace
        if ($null -ne $body) { $out += [pscustomobject]@{ Name = $m.Groups[1].Value; Body = $body } }
    }
    return , $out
}

# Every switch arm whose label list names `w32.<Msg>`. The body is a balanced
# block, or the rest of the line for a single-expression arm.
function Get-MessageArms([string]$Clean, [string]$Msg) {
    $out = @()
    foreach ($m in [regex]::Matches($Clean, '(?m)^[ \t]*((?:w32\.WM_\w+[ \t]*,[ \t]*)*w32\.WM_\w+)[ \t]*=>[ \t]*')) {
        $labels = $m.Groups[1].Value -split '[ \t]*,[ \t]*'
        if ($labels -notcontains "w32.$Msg") { continue }
        $at = $m.Index + $m.Length
        if ($at -lt $Clean.Length -and $Clean[$at] -eq '{') {
            $body = Get-BlockAt $Clean $at
        } else {
            $eol = $Clean.IndexOf("`n", $at)
            if ($eol -lt 0) { $eol = $Clean.Length }
            $body = $Clean.Substring($at, $eol - $at)
        }
        if ($null -ne $body) { $out += [pscustomobject]@{ Labels = ($labels -join ', '); Body = $body } }
    }
    return , $out
}

# The judgement. $Files: @(@{ Name; Text }). $Surfaces: the enum members the
# probe declares. Returns finding strings; empty means the asymmetry holds.
function Get-PaintProbeFindings {
    param(
        [Parameter(Mandatory = $true)][object[]]$Files,
        [Parameter(Mandatory = $true)][string[]]$Surfaces
    )
    $findings = @()
    $units = @()
    foreach ($f in $Files) {
        $aliases = @([regex]::Matches($f.Text, 'const\s+(\w+)\s*=\s*@import\(\s*"paint_probe\.zig"\s*\)') |
            ForEach-Object { $_.Groups[1].Value })
        $clean = Get-ZigStripped $f.Text
        $units += [pscustomobject]@{
            Name      = $f.Name
            Aliases   = $aliases
            Functions = (Get-ZigFunctions $clean)
            Paint     = (Get-MessageArms $clean 'WM_PAINT')
            Print     = (Get-MessageArms $clean 'WM_PRINTCLIENT')
        }
    }

    # Names of functions that transitively reach a record call whose argument
    # matches $ArgPattern ('[^)]*' = any surface).
    function Get-Reachers([string]$ArgPattern) {
        $set = @{}
        $changed = $true
        while ($changed) {
            $changed = $false
            $callRe = $null
            if ($set.Count -gt 0) {
                $callRe = [regex]('\b(?:' + (($set.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s*\(')
            }
            foreach ($u in $units) {
                $seedRe = $null
                if ($u.Aliases.Count -gt 0) {
                    $seedRe = [regex]('\b(?:' + (($u.Aliases | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\.record\s*\(\s*' + $ArgPattern + '\)')
                }
                foreach ($fn in $u.Functions) {
                    if ($set.ContainsKey($fn.Name)) { continue }
                    if (($seedRe -and $seedRe.IsMatch($fn.Body)) -or ($callRe -and $callRe.IsMatch($fn.Body))) {
                        $set[$fn.Name] = $u.Name
                        $changed = $true
                    }
                }
            }
        }
        return $set
    }

    function Test-ArmReaches($Unit, [string]$Body, [hashtable]$Reach, [string]$ArgPattern) {
        if ($Unit.Aliases.Count -gt 0) {
            $seedRe = '\b(?:' + (($Unit.Aliases | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\.record\s*\(\s*' + $ArgPattern + '\)'
            if ($Body -match $seedRe) { return 'a direct record call' }
        }
        foreach ($name in $Reach.Keys) {
            if ($Body -match ('\b' + [regex]::Escape($name) + '\s*\(')) { return "$name() in $($Reach[$name])" }
        }
        return $null
    }

    $any = Get-Reachers '[^)]*'
    foreach ($u in $units) {
        foreach ($arm in $u.Print) {
            $via = Test-ArmReaches $u $arm.Body $any '[^)]*'
            if ($via) { $findings += "$($u.Name): the ``$($arm.Labels)`` arm counts a paint through $via - the camera would read as a repaint" }
        }
    }
    foreach ($s in $Surfaces) {
        $arg = '\.' + [regex]::Escape($s) + '\s*'
        $reach = Get-Reachers $arg
        $fromPaint = $false
        foreach ($u in $units) {
            foreach ($arm in $u.Paint) {
                if (Test-ArmReaches $u $arm.Body $reach $arg) { $fromPaint = $true; break }
            }
            if ($fromPaint) { break }
        }
        if (-not $fromPaint) { $findings += "surface .$s is never recorded from a WM_PAINT arm - its counter cannot advance" }
    }
    return , $findings
}

# --- D fixtures: the analyzer has teeth (T1133) ----------------------------
$probeImport = 'const paint_probe = @import("paint_probe.zig");'
function New-ProcFixture([string]$PaintArm, [string]$PrintArm, [string]$Extra = '') {
    return (@(
            $probeImport,
            $Extra,
            'fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) isize {',
            '    switch (msg) {',
            $PaintArm,
            $PrintArm,
            '        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),',
            '    }',
            '}'
        ) -join "`n")
}
$paintOk = @(
    '        w32.WM_PAINT => {',
    '            // counted here, never in WM_PRINTCLIENT: paint_probe.record(.window) is the rule',
    '            paint_probe.record(.window);',
    '            self.paint(hdc);',
    '            return 0;',
    '        },'
) -join "`n"
$printOk = @(
    '        w32.WM_PRINTCLIENT => {',
    '            // deliberately NOT paint_probe.record(.window) - this is the camera',
    '            log.debug("printing {d} {s}", .{ 1, "}" });',
    '            self.paint(@ptrFromInt(wparam));',
    '            return 0;',
    '        },'
) -join "`n"
$printDirect = $printOk -replace 'self\.paint\(@ptrFromInt', 'paint_probe.record(.window);
            self.paint(@ptrFromInt'
$helper = @(
    'fn paintShared(self: *Self, dc: w32.HDC) void {',
    '    paint_probe.record(.window);',
    '    self.paint(dc);',
    '}'
) -join "`n"
$printViaHelper = $printOk -replace 'self\.paint\(', 'self.paintShared('
$combined = @(
    '        w32.WM_PAINT, w32.WM_PRINTCLIENT => {',
    '            paint_probe.record(.window);',
    '            return 0;',
    '        },'
) -join "`n"

$fxGood = New-ProcFixture $paintOk $printOk
$fxD1 = Get-PaintProbeFindings -Files @(@{ Name = 'good.zig'; Text = $fxGood }) -Surfaces @('window')
Assert 'D1 the shape as it stands is clean (comments and a "}" in a string do not count)' ($fxD1.Count -eq 0) ($fxD1 -join ' | ')

$fxD2 = Get-PaintProbeFindings -Files @(@{ Name = 'bad.zig'; Text = (New-ProcFixture $paintOk $printDirect) }) -Surfaces @('window')
Assert 'D2 a WM_PRINTCLIENT arm that records directly is a finding' `
(@($fxD2 | Where-Object { $_ -match 'WM_PRINTCLIENT. arm counts a paint through a direct record call' }).Count -eq 1) ($fxD2 -join ' | ')

$fxD3 = Get-PaintProbeFindings -Files @(@{ Name = 'bad.zig'; Text = (New-ProcFixture $paintOk $printViaHelper $helper) }) -Surfaces @('window')
Assert 'D3 ...and so is one that reaches it through a shared helper' `
(@($fxD3 | Where-Object { $_ -match 'paintShared\(\)' }).Count -eq 1) ($fxD3 -join ' | ')

# The helper in one file, the arm in another: reach is across the frontend.
$fxD4 = Get-PaintProbeFindings -Files @(
    @{ Name = 'helper.zig'; Text = ($probeImport + "`n" + $helper) },
    @{ Name = 'proc.zig'; Text = (New-ProcFixture '        w32.WM_PAINT => { self.paintShared(dc); return 0; },' ($printOk -replace 'self\.paint\(', 'other.paintShared(')) }
) -Surfaces @('window')
Assert 'D4 ...and so is one that reaches it through another file' `
(@($fxD4 | Where-Object { $_ -match 'paintShared\(\) in helper\.zig' }).Count -eq 1) ($fxD4 -join ' | ')

$fxD5 = Get-PaintProbeFindings -Files @(@{ Name = 'bad.zig'; Text = (New-ProcFixture $combined '') }) -Surfaces @('window')
Assert 'D5 a combined WM_PAINT, WM_PRINTCLIENT arm is a finding' `
(@($fxD5 | Where-Object { $_ -match 'WM_PAINT, w32\.WM_PRINTCLIENT' }).Count -eq 1) ($fxD5 -join ' | ')

$fxD6 = Get-PaintProbeFindings -Files @(@{ Name = 'good.zig'; Text = $fxGood }) -Surfaces @('window', 'viewer_toc')
Assert 'D6 POSITIVE: a declared surface nobody records is a finding' `
(@($fxD6 | Where-Object { $_ -match '\.viewer_toc is never recorded' }).Count -eq 1 -and $fxD6.Count -eq 1) ($fxD6 -join ' | ')

# Recorded, but only by the camera: both halves must speak.
$fxD7 = Get-PaintProbeFindings -Files @(@{ Name = 'bad.zig'; Text = (New-ProcFixture '        w32.WM_PAINT => { return 0; },' $printDirect) }) -Surfaces @('window')
Assert 'D7 POSITIVE: a surface recorded only from WM_PRINTCLIENT is not counted as recorded' `
(@($fxD7 | Where-Object { $_ -match '\.window is never recorded' }).Count -eq 1) ($fxD7 -join ' | ')

# A record that names the wrong file's alias is not a record of the probe.
$fxD8 = Get-PaintProbeFindings -Files @(@{ Name = 'noimport.zig'; Text = ((New-ProcFixture $paintOk $printDirect) -replace [regex]::Escape($probeImport), '') }) -Surfaces @('window')
Assert 'D8 a file that does not import the probe cannot record it' `
(@($fxD8 | Where-Object { $_ -match 'counts a paint' }).Count -eq 0) ($fxD8 -join ' | ')

# --- D sweep: the real frontend --------------------------------------------
$probePath = Join-Path $srcDir 'paint_probe.zig'
Assert 'D9 paint_probe.zig is where this expects it' (Test-Path -LiteralPath $probePath) $probePath
$surfaces = @()
if (Test-Path -LiteralPath $probePath) {
    $probeClean = Get-ZigStripped (Get-Content -LiteralPath $probePath -Raw)
    $enumAt = $probeClean.IndexOf('pub const Surface = enum')
    if ($enumAt -ge 0) {
        $enumBody = Get-BlockAt $probeClean ($probeClean.IndexOf('{', $enumAt))
        if ($enumBody) {
            $surfaces = @([regex]::Matches($enumBody, '(?m)^\s*(\w+)\s*,') | ForEach-Object { $_.Groups[1].Value })
        }
    }
}
Assert "D10 the probe's surfaces were read ($($surfaces -join ', '))" ($surfaces.Count -ge 2) "$($surfaces.Count)"

$realFiles = @()
if (Test-Path -LiteralPath $srcDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $srcDir -Filter '*.zig' -Recurse)) {
        $t = Get-Content -LiteralPath $f.FullName -Raw
        if ($t) { $realFiles += @{ Name = $f.Name; Text = $t } }
    }
}
$importers = @($realFiles | Where-Object { $_.Text -match '@import\(\s*"paint_probe\.zig"\s*\)' } | ForEach-Object { $_.Name })
Assert "D11 the sweep found the probe's callers ($($importers -join ', '))" ($importers.Count -ge 2) "$($importers.Count)"
if ($surfaces.Count -gt 0 -and $realFiles.Count -gt 0) {
    $realD = Get-PaintProbeFindings -Files $realFiles -Surfaces $surfaces
    Assert 'D12 no WM_PRINTCLIENT path counts a paint, and every surface is counted from WM_PAINT' `
    ($realD.Count -eq 0) ($realD -join ' | ')
}

# --- stamp (T783 / T478) ---------------------------------------------------
# Only a CLEAN run stamps; a red one must stay due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard printclient-audit -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
