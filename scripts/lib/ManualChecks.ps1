# Manual pre-release checks: which ones exist, and whether one is owed (T1451).
#
# THE PROBLEM. Some checks cannot run on this box at all. The IME checklist in
# docs/design/windows-parity-ime-manual.md needs a Microsoft IME installed, and
# this machine deliberately has only en-US (adding one changes the user's
# language bar). T642 wrote the checklist; nothing ever asked anyone to run it,
# and releases are cut by scripts\daily-publish.ps1 with no human step to hang a
# reminder on. A checklist nobody is prompted to run is no checklist.
#
# THE SHAPE. A committed record, docs/design/windows-parity-manual-checks.json,
# holds every run somebody made: which check, which release LINE (Major.Minor,
# the Mac version line every win-v patch walks on), the date and the result. A
# check is OWED for a line until a passing run for that line is recorded. The
# publish names what is owed in its log at the moment a release is cut, and
# `daily-publish.ps1 -Status` names it too - that is the output the morning
# digest already reads - so the prompt lands where a person looks.
#
# NEVER A GATE. An owed check is reported, never refused: the check needs a box
# this loop does not have, so a gate would stop every release forever. The
# line says "deferred" and the publish goes ahead.
#
# Record a run with scripts\manual-check.ps1 record. Functions only; pure except
# Read-ManualCheckFile.

# The checks that exist. Add a row here when another check that only a person
# can run gets a checklist document.
$script:ManualCheckCatalog = @(
    [pscustomobject]@{
        Name  = 'ime'
        Title = 'the IME checklist'
        Doc   = 'docs\design\windows-parity-ime-manual.md'
        Needs = 'a Windows box with a Microsoft IME installed'
    }
)

function Get-ManualCheckCatalog { return $script:ManualCheckCatalog }

function Get-ManualCheckDefaultPath([string]$Repo) {
    return (Join-Path $Repo 'docs\design\windows-parity-manual-checks.json')
}

# '1.37.4', 'v1.37.0', 'win-v1.37.12' or '1.37' -> '1.37'. Anything else -> ''.
function Get-ReleaseLine([string]$Version) {
    if (-not $Version) { return '' }
    $v = $Version.Trim()
    if ($v -like 'win-v*') { $v = $v.Substring(5) } elseif ($v -like 'v*') { $v = $v.Substring(1) }
    if ($v -match '^(\d+)\.(\d+)(\.\d+)?$') { return "$([int]$Matches[1]).$([int]$Matches[2])" }
    return ''
}

# The record file's text -> an array of runs. A missing, empty or unreadable
# file is no runs, which reads as "owed": the safe direction for a reminder.
function ConvertFrom-ManualCheckText([string]$Text) {
    if (-not $Text -or -not $Text.Trim()) { return @() }
    try { $o = $Text | ConvertFrom-Json } catch { return @() }
    $runs = @()
    # ConvertFrom-Json in PS 5.1 hands a JSON array over as ONE object; unroll it.
    foreach ($r in @($o.runs | ForEach-Object { $_ })) {
        if ($null -eq $r) { continue }
        $runs += [pscustomobject]@{
            Check  = [string]$r.check
            Line   = (Get-ReleaseLine ([string]$r.line))
            Date   = [string]$r.date
            Result = ([string]$r.result).ToLowerInvariant()
            Note   = [string]$r.note
        }
    }
    return $runs
}

function Read-ManualCheckFile([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try { $t = [IO.File]::ReadAllText($Path) } catch { return @() }
    return @(ConvertFrom-ManualCheckText $t)
}

# Is $Check owed for $Line? Owed unless a PASS for that exact line is recorded.
# Last is the newest run of that check on that line (pass or fail), or $null.
function Get-ManualCheckVerdict {
    param($Runs = @(), [string]$Check, [string]$Line)
    $mine = @($Runs | Where-Object { $_.Check -eq $Check -and $Line -and $_.Line -eq $Line } |
            Sort-Object -Property Date)
    $pass = @($mine | Where-Object { $_.Result -eq 'pass' })
    $last = if ($mine.Count) { $mine[$mine.Count - 1] } else { $null }
    return [pscustomobject]@{
        Check = $Check
        Line  = $Line
        Owed  = ($pass.Count -eq 0)
        Pass  = $(if ($pass.Count) { $pass[$pass.Count - 1] } else { $null })
        Last  = $last
    }
}

# One log line per catalogued check, for the release line $Version belongs to.
# Every OWED line says it does not block, because the reader is usually a
# publish log and the one wrong conclusion is "the publish was held for this".
function Get-ManualCheckLines {
    param($Runs = @(), [string]$Version)
    $line = Get-ReleaseLine $Version
    $out = @()
    foreach ($c in (Get-ManualCheckCatalog)) {
        $record = "scripts\manual-check.ps1 record -Check $($c.Name) -Result pass"
        if (-not $line) {
            $out += "MANUAL CHECK OWED: $($c.Name) - $($c.Title) ($($c.Doc)); the release line is unknown ('$Version'), so no recorded run can be matched. Deferred - it never blocks a publish."
            continue
        }
        $v = Get-ManualCheckVerdict -Runs $Runs -Check $c.Name -Line $line
        if (-not $v.Owed) {
            $out += "MANUAL CHECK OK: $($c.Name) passed for the $line line on $($v.Pass.Date)."
            continue
        }
        $last = if ($null -eq $v.Last) { 'never run for this line' } else { "last run $($v.Last.Date): $($v.Last.Result.ToUpperInvariant())" }
        $out += "MANUAL CHECK OWED: $($c.Name) - $($c.Title) ($($c.Doc)) has no passing run recorded for the $line line ($last). Deferred - it never blocks a publish. Run it on $($c.Needs), then: $record"
    }
    return $out
}
