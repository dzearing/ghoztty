# WslLease.ps1 - the record that THIS lane booted the WSL VM and kept it up
# (T3721).
#
# scripts\linux\wsl-run.ps1 leaves WSL as it found it: a call that finds the VM
# idle shuts it down afterwards. `-KeepRunning` skips that so a turn can run
# several steps without a boot each, and before this file nothing remembered
# who had booted the VM: the next plain call saw a VM already running, read it
# as somebody else's, and left it alone - and the user's vmIdleTimeout=-1 then
# held its memory forever. Ubuntu is also the user's own distro, so a bare
# --terminate could kill their sessions; the lease is what makes giving the
# memory back safe.
#
# The lease is one JSON file per worktree (temp\wsl-run\lease.json):
#   distro   the distro the call ran in
#   bootId   /proc/sys/kernel/random/boot_id of the VM it booted - the VM's
#            identity; a VM restarted since is a different VM, not ours
#   lane     the loop lane that took it
#   pid      the wsl-run process that wrote it
#   takenAt  ISO time
#
# `wsl-run.ps1 -Release` gives it back; `-LeaseStatus` reports it. go-loop-exec
# claim and parity-tasks validate print Get-WslLeaseReport, so a lease left
# held at a turn boundary is said out loud. Reading the lease never calls
# wsl.exe, so a Windows lane may ask freely.
#
# $env:GHOZTTY_WSL_LEASE_FILE moves the file (the acceptance script's seam).
# ASCII only, PS 5.1.

function Get-WslLeasePath([string]$Repo) {
    if ($env:GHOZTTY_WSL_LEASE_FILE) { return [string]$env:GHOZTTY_WSL_LEASE_FILE }
    return (Join-Path $Repo 'temp\wsl-run\lease.json')
}

function Read-WslLease([string]$Repo) {
    $p = Get-WslLeasePath $Repo
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $o = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
    } catch {
        # A torn or hand-mangled file still says "somebody kept the VM up";
        # report it as held with what we cannot read, never as no lease.
        return [pscustomobject]@{ distro = '?'; bootId = ''; lane = '?'; pid = 0; takenAt = ''; corrupt = $true }
    }
    if ($null -eq $o) { return $null }
    return $o
}

function Write-WslLease([string]$Repo, [string]$Distro, [string]$BootId, [string]$Lane) {
    $p = Get-WslLeasePath $Repo
    $dir = Split-Path -Parent $p
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $json = [pscustomobject]@{
        distro  = $Distro
        bootId  = $BootId
        lane    = $Lane
        pid     = $PID
        takenAt = (Get-Date).ToString('o')
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-WslLease([string]$Repo) {
    $p = Get-WslLeasePath $Repo
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

# One line, or $null when no lease is held. The label is the claim's and
# validate's: informational, never a refusal (test\win32\gate-negatives.ps1).
function Get-WslLeaseReport([string]$Repo) {
    $l = Read-WslLease $Repo
    if ($null -eq $l) { return $null }
    $age = ''
    $t = [datetime]::MinValue
    if ($l.takenAt -and [datetime]::TryParse([string]$l.takenAt, [ref]$t)) {
        $mins = [int]((Get-Date) - $t).TotalMinutes
        if ($mins -ge 120) { $age = (' {0}h ago' -f [int]($mins / 60)) } else { $age = (' {0}m ago' -f $mins) }
    }
    return ("WSL LEASE HELD: lane {0} booted the {1} VM and kept it up (since {2}{3}) - when its Linux steps are done, give the memory back with: powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Release (T3721)" -f $l.lane, $l.distro, $l.takenAt, $age)
}
