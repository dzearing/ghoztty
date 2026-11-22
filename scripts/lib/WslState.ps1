# WslState.ps1 - ask about WSL WITHOUT starting it (T1751).
#
# CLAUDE.md: "Never start WSL unasked - nothing in the Windows floor, sweeps or
# go-loop may boot it." The old gate in the Windows acceptance scripts was
# `wsl.exe -e /bin/true`, which is exactly a boot: on an idle box it starts the
# WSL2 VM, and a WSL2 VM has already taken this box to 28 GB of RAM once.
#
# `wsl.exe -l -v` asks the WSL service for the distro table and never starts a
# distro or the VM, so a Windows script may call it freely. A script whose arm
# needs a live distro runs that arm only when the DEFAULT distro (the one
# `wsl.exe` with no `-d` reaches, which is what `--shell=wsl.exe` opens) is
# already Running, and SKIPs it otherwise, naming why.
#
#   . scripts\lib\WslState.ps1
#   $w = Get-WslDefaultDistroState     # Name, State ('Running'/'Stopped'/...), or $null
#   if (Test-WslDefaultDistroRunning) { ... }

function Get-WslDefaultDistroState {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $null }
    $prev = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try {
        $out = @(& wsl.exe -l -v 2>$null)
    } catch {
        return $null
    } finally {
        $env:WSL_UTF8 = $prev
    }
    foreach ($line in $out) {
        # Strip the NULs an older wsl.exe still emits as UTF-16 when WSL_UTF8
        # is not honoured, then look for the default row: "* Ubuntu  Running  2".
        $l = (([string]$line) -replace "`0", '').Trim()
        if ($l -match '^\*\s+(\S+)\s+(\S+)') {
            return [pscustomobject]@{ Name = $Matches[1]; State = $Matches[2] }
        }
    }
    return $null
}

function Test-WslDefaultDistroRunning {
    $s = Get-WslDefaultDistroState
    return ($null -ne $s -and $s.State -eq 'Running')
}

# The SKIP reason for an arm gated on the above, so every caller says the same
# thing and the reason names the rule rather than looking like a missing tool.
function Get-WslSkipReason {
    $s = Get-WslDefaultDistroState
    if ($null -eq $s) { return 'no default WSL distro on this box' }
    return ("default WSL distro '{0}' is {1}, and Windows scripts never start WSL (CLAUDE.md); start it yourself to run this arm" -f $s.Name, $s.State)
}
