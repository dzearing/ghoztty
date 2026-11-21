# LogSinkAudit.ps1 - T1679. No harness spells the app's log sink by name.
#
# WHY THIS EXISTS. The Windows app appends to %LOCALAPPDATA%\ghoztty\<sink>,
# and the sink's NAME follows the build mode (src\os\log_rotate.zig
# `live_name`): a Debug build writes `ghoztty-debug.log` (T1508), everything
# else `ghoztty.log`. A Debug build is what an acceptance script launches. So a
# harness that spells `ghoztty.log` while driving one reads a file nobody
# writes - an empty string - and every `-notmatch` over it passes for free.
# T901's first draft of a section did exactly that and scored green on nothing;
# it was caught only because a sibling assertion failed for an unrelated
# reason.
#
# THE RULE. A test\win32 script gets the sink from
#     Get-GhozttyAppLogPath -Exe $exe [-LocalAppData $sandbox]   (BuildMode.ps1)
# which reads the mode off the exe under test. A script whose SUBJECT really is
# one named sink (log-append.ps1 measures both; a release-gated arm; a fixture
# that only needs a file to exist) declares it once, anywhere in the file:
#     # @log-sink-literal - <why spelling the name is right here>
# A marker with no reason does not count. Comment lines are not code and are
# never findings. log-append.ps1 section L runs this over the tree and proves
# it can fail against a planted fixture.

$script:LogSinkLiteralPattern = 'ghoztty\\?\.log'
$script:LogSinkMarkerPattern = '(?m)^\s*#\s*@log-sink-literal\s*-\s*\S'

function Find-LogSinkLiteralLines {
    <#
    .SYNOPSIS
    Pure: the 1-based line numbers of CODE lines in $Text that spell a sink name.
    #>
    param([AllowEmptyString()][string]$Text)
    $hits = New-Object System.Collections.Generic.List[int]
    if (-not $Text) { return }
    $lines = $Text -split "`r?`n"
    $inBlock = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        $t = $l.TrimStart()
        if ($inBlock) {
            if ($t -match '#>') { $inBlock = $false }
            continue
        }
        if ($t.StartsWith('<#')) {
            if ($t -notmatch '#>') { $inBlock = $true }
            continue
        }
        if ($t.StartsWith('#')) { continue }
        if ($l -match $script:LogSinkLiteralPattern) { $hits.Add($i + 1) }
    }
    # Unrolled on purpose: callers wrap in @(), and `return ,` of an EMPTY
    # array counts as 1 there (the PS5.1 trap).
    return $hits.ToArray()
}

function Test-LogSinkLiteralDeclared {
    <# Pure: does $Text carry a `@log-sink-literal - <reason>` marker? #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $false }
    return [bool]($Text -match $script:LogSinkMarkerPattern)
}

function Get-LogSinkAuditFindings {
    <#
    .SYNOPSIS
    Every test\win32 script under $Root that spells a sink name in code without
    declaring why. One object per offending file: Path (repo-relative), Lines.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $base = Join-Path $Root 'test\win32'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -Filter '*.ps1' -File)) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        $hits = @(Find-LogSinkLiteralLines -Text $text)
        if ($hits.Count -eq 0) { continue }
        if (Test-LogSinkLiteralDeclared -Text $text) { continue }
        $rel = $f.FullName.Substring($Root.TrimEnd('\').Length + 1)
        $out.Add([pscustomobject]@{ Path = $rel; Lines = $hits })
    }
    return $out.ToArray()
}
