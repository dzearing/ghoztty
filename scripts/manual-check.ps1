# Record and read the manual pre-release checks (T1451).
#
# Some release checks need hardware or software this box deliberately does not
# have (the IME checklist needs a Microsoft IME installed). They are listed in
# scripts\lib\ManualChecks.ps1, and every run anybody makes is recorded in
# docs\design\windows-parity-manual-checks.json, keyed by the release LINE
# (Major.Minor). A check is owed for a line until a passing run is recorded;
# daily-publish.ps1 names what is owed in its publish log and in -Status, which
# is what the morning digest reads. Owed never blocks a publish.
#
#   powershell -NoProfile -File scripts\manual-check.ps1 status
#   powershell -NoProfile -File scripts\manual-check.ps1 status -Version 1.37.4
#   powershell -NoProfile -File scripts\manual-check.ps1 record -Check ime -Result pass -Note "candidate window over the caret; Escape kept the composer open"
#   powershell -NoProfile -File scripts\manual-check.ps1 record -Check ime -Result fail -Note "T1234: ..." -Version 1.37
#
# `record` writes the file and stops; commit it with the release's task or log
# entry the ordinary way (the commit guard pushes it). A FAIL is recorded too,
# and the check stays owed - the failure itself is a task, filed as usual.
#
# -Version defaults to the newest v* / win-v* release tag in this checkout, which
# is the line the next publish walks on.
#
# Exit: 0 ok (status: nothing owed or something owed - status never fails),
# 1 refused (unknown check, bad result, no line).
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)][ValidateSet('status', 'record')][string]$Command = 'status',
    [string]$Check = '',
    [string]$Result = '',
    [string]$Note = '',
    [string]$Version = '',
    [string]$Repo = '',
    # Test seam: the record file. Empty = the repo's.
    [string]$Path = '',
    # Test seam: the date a record carries. Empty = today.
    [string]$Date = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\ManualChecks.ps1')
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not $Path) { $Path = Get-ManualCheckDefaultPath $Repo }

function Get-NewestReleaseVersion {
    $best = $null; $bestText = ''
    foreach ($t in @(& git -C $Repo tag --list 'v[0-9]*.[0-9]*.[0-9]*' 'win-v[0-9]*.[0-9]*.[0-9]*' 2>$null)) {
        $s = "$t".Trim() -replace '^win-v', '' -replace '^v', ''
        if ($s -notmatch '^(\d+)\.(\d+)\.(\d+)$') { continue }
        $k = [version]"$([int]$Matches[1]).$([int]$Matches[2]).$([int]$Matches[3])"
        if ($null -eq $best -or $k -gt $best) { $best = $k; $bestText = $s }
    }
    return $bestText
}

if (-not $Version) { $Version = Get-NewestReleaseVersion }
$line = Get-ReleaseLine $Version

if ($Command -eq 'status') {
    $runs = @(Read-ManualCheckFile $Path)
    Write-Output "release line: $(if ($line) { $line } else { "unknown ('$Version')" }) (record file: $Path)"
    foreach ($l in (Get-ManualCheckLines -Runs $runs -Version $Version)) { Write-Output $l }
    exit 0
}

# ---- record ----
$names = @((Get-ManualCheckCatalog) | ForEach-Object { $_.Name })
if ($names -notcontains $Check) {
    Write-Output "REFUSED: -Check must be one of: $($names -join ', ') (got '$Check')"
    exit 1
}
$r = $Result.Trim().ToLowerInvariant()
if ($r -ne 'pass' -and $r -ne 'fail') {
    Write-Output "REFUSED: -Result must be pass or fail (got '$Result')"
    exit 1
}
if (-not $line) {
    Write-Output "REFUSED: no release line - pass -Version X.Y[.Z] (got '$Version')"
    exit 1
}
if ($r -eq 'fail' -and -not $Note.Trim()) {
    Write-Output 'REFUSED: a failed run needs -Note naming the task filed for it'
    exit 1
}

$doc = [ordered]@{ runs = @() }
if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $text = [IO.File]::ReadAllText($Path)
    if ($text.Trim()) {
        try { $o = $text | ConvertFrom-Json } catch {
            Write-Output "REFUSED: $Path is not valid JSON; fix it by hand rather than have this overwrite it"
            exit 1
        }
        $doc.runs = @($o.runs | ForEach-Object { $_ })
    }
}
$when = if ($Date) { $Date } else { (Get-Date).ToString('yyyy-MM-dd') }
$doc.runs = @($doc.runs) + @([pscustomobject][ordered]@{
        check  = $Check
        line   = $line
        date   = $when
        result = $r
        note   = $Note.Trim()
    })
$json = $doc | ConvertTo-Json -Depth 5
$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($Path, ($json -replace "`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Output "RECORDED: $Check $($r.ToUpperInvariant()) for the $line line on $when in $Path - commit it."
foreach ($l in (Get-ManualCheckLines -Runs @(Read-ManualCheckFile $Path) -Version $Version)) { Write-Output $l }
exit 0
