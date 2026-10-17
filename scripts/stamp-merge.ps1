# git merge driver for guard stamps (tracker T2027) - keeps the newer stamp.
#
# Registered by `scripts\git-commit-guard.ps1 install` (which go-loop-exec's
# claim re-runs every turn) as merge.ghoztty-stamp, and selected for
# test/win32/*.stamp.json by .gitattributes. Git calls it as
#
#     stamp-merge.ps1 <base> <ours> <theirs>
#
# and reads the result from <ours>. The rule and why it is safe are in
# scripts\lib\StampMerge.ps1. A side that is not a readable stamp falls back to
# git's own three-way text merge, so an undecidable file is still an honest
# conflict with markers in it - never a silent pick.
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Base,
    [Parameter(Mandatory = $true, Position = 1)][string]$Ours,
    [Parameter(Mandatory = $true, Position = 2)][string]$Theirs
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\StampMerge.ps1')

function Read-Side([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $p).Path, [System.Text.Encoding]::UTF8)
}

$oursText = Read-Side $Ours
$theirsText = Read-Side $Theirs
$pick = Select-NewerStamp $oursText $theirsText

if ($pick -eq 'ours') { exit 0 }
if ($pick -eq 'theirs') {
    # Bytes, not text: the committed stamp is LF/no-BOM and must stay that way.
    [System.IO.File]::WriteAllBytes((Resolve-Path -LiteralPath $Ours).Path,
        [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Theirs).Path))
    exit 0
}

& git merge-file -L ours -L base -L theirs $Ours $Base $Theirs 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { exit 0 }
exit 1
