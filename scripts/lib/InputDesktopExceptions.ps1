# InputDesktopExceptions (T3839) - which acceptance JOBS may never be started by
# the loop, because they can only run on the user's input desktop.
#
# go.md opens with the rule: the loop never runs an `@input-desktop-exception`
# script (the list in test\win32\lib\TestDesktop.ps1). That rule was prose. On
# 2026-11-26 the per-turn `acceptance-parallel.ps1 due` sweep started
# translucent-window.ps1 anyway, because the runner only honoured a marker a
# script declares in ITS OWN header - and the exception list lives in
# TestDesktop.ps1, not in the scripts it names. It photographed backdrops on
# the user's screen and scored two failures that were the box, not the code.
#
# This file is the one reader both gates share:
#   - scripts\acceptance-parallel.ps1 drops such a job before anything starts
#     and reports it NOT RUN (input-desktop-exception), never red;
#   - scripts\guard-due.ps1 treats a row whose harness is such a job as
#     ADVISORY, so it is reported and never wedges `validate` - it stays owed
#     until a person runs it, which is the only way it can be cleared.
#
# The list is parsed by ForegroundAudit's own parser, so the set the foreground
# audit enforces and the set the runner refuses cannot drift apart.
#
# FLAG-GATED ENTRIES. An entry whose reason starts `(T<id>) -<Flag> only:` (today
# divider-flicker.ps1, whose default run is synthetic and touches no desktop)
# names the one switch that makes the script input-desktop-only. Such a job is
# refused only when its arguments carry that switch.

. (Join-Path $PSScriptRoot '..\..\test\win32\lib\ForegroundAudit.ps1')

# Resolved HERE, at dot-source time: inside a function $PSScriptRoot is not
# reliably this file's directory, and a wrong guess reads as "nothing declared".
$script:InputDesktopListPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\test\win32\lib\TestDesktop.ps1'))

function Get-InputDesktopExceptions {
    <#
    .SYNOPSIS
    The declared input-desktop-only scripts: Name (leaf, e.g. translucent-window.ps1),
    Flag (the gating switch, or '' when every run is input-desktop-only), Reason.
    -Path defaults to this checkout's test\win32\lib\TestDesktop.ps1; -Text takes
    lines instead (fixtures). Lib helpers (`lib\x.ps1`) are not jobs and are left out.
    #>
    param([string]$Path, [string[]]$Text)
    if ($null -eq $Text -and -not $Path) {
        $Path = $script:InputDesktopListPath
    }
    if ($null -eq $Text -and -not (Test-Path -LiteralPath $Path)) { return @() }
    $decl = if ($null -ne $Text) { Get-ForegroundAuditDeclarations -Text $Text } else { Get-ForegroundAuditDeclarations -Path $Path }
    $out = @()
    foreach ($d in @($decl)) {
        if ($d.Malformed -or -not $d.Script -or $d.Script -match '^lib\\') { continue }
        $flag = ''
        if ($d.Reason -match '^\s*\([^)]*\)\s+(?<f>-[A-Za-z][A-Za-z0-9]*)\s+only\b') { $flag = $Matches['f'] }
        $out += [pscustomobject]@{ Name = $d.Script; Flag = $flag; Reason = $d.Reason }
    }
    return $out
}

function Get-InputDesktopExceptionFor {
    <#
    .SYNOPSIS
    The declaration that forbids this job (script path or leaf + its argument
    string), or $null when the loop may run it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string]$RunArgs = '',
        [object[]]$Exceptions
    )
    $leaf = Split-Path -Leaf $Script
    foreach ($e in @($Exceptions)) {
        if (-not $e -or $e.Name -ine $leaf) { continue }
        if (-not $e.Flag) { return $e }
        $tokens = @([string]$RunArgs -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -split ':', 2)[0] })
        if (@($tokens | Where-Object { $_ -ieq $e.Flag }).Count -gt 0) { return $e }
    }
    return $null
}
