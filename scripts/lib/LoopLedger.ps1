# LoopLedger.ps1 - the claim ledger every loop lane on this box shares (T1981).
#
# Why it exists: `parity-tasks.ps1` decides which task to hand out (`next
# -Claim`) and which id to mint (`new`) from the task files in ITS OWN worktree.
# That was correct while one loop ran on the box. With two loop LANES (two
# go.md loops, each in its own git worktree - `seat` already means win/mac in
# the tracker, so the parallel loop is a lane) both worktrees answer from their
# own copy of the files, so both pick the same head of the queue, and both mint
# the same next id: on 2026-10-14 ids collided twice (T1937 item 7).
#
# So the facts two lanes must agree on live OUTSIDE every worktree, in one JSON
# file per user:
#
#   %LOCALAPPDATA%\ghoztty\loop-ledger.json      (GHOZTTY_LOOP_LEDGER overrides;
#                                                 GHOZTTY_LOOP_LEDGER=off disables)
#   { "version": 1, "maxId": 1986,
#     "claims": { "T1981": { "lane": "...", "root": "...", "pid": 123,
#                            "at": "<iso>", "touched": "<iso>" },
#                 "T2012": { ..., "closed": "done", "path": "<task file>",
#                            "pushedAt": "<iso>" } } }
#
# A claim carrying `closed` is a RESERVATION (T2033): the lane set the task to
# done/skipped/blocked, and the other lane's worktree still reads it as todo
# until that status has been pushed AND pulled. Releasing at set-status (the
# T1981 shape) handed T2012 to lane A one second after lane B finished it, and
# lane A re-did the whole task. Update-LedgerReservations says how one ends.
#
# Rules this file holds:
#
# - Every read and every read-modify-write happens under ONE named mutex, so a
#   claim is an atomic check-and-set rather than "read, think, write". The
#   mutex name is derived from the ledger path, so a test ledger in %TEMP% never
#   contends with the real one. The wait is bounded and the timeout says what
#   it was waiting for.
# - Writes go to a temp file and are swapped in with File.Replace, so a reader
#   never sees half a ledger.
# - A claim is live while its `touched` is younger than the TTL (60 min,
#   GHOZTTY_LOOP_LEDGER_TTL_MIN overrides). A lane that died stops touching its
#   claim and the claim simply ages out - the ledger has no other notion of
#   liveness, because the process that wrote a claim (`parity-tasks.ps1`) exits
#   a second later. Expired claims are ignored on read and pruned on write.
# - A ledger that cannot be parsed is backed up beside itself and replaced with
#   an empty one, with a warning. It must never wedge the loop: the worst a
#   lost ledger costs is the protection it was giving, which is exactly the
#   state of the world before T1981.
#
# ASCII only and PS 5.1 compatible: dot-sourced by scripts\parity-tasks.ps1
# and by test\win32\parity-tasks-lanes.ps1.

# 60 minutes since T1984. A claim used to be touched only by `note` and
# `set-status`, and a turn can go an hour without either (the harness floor
# alone runs ~50 min), so the T1981 stopgap was 180. Each lane's watchdog now
# touches its lane's claims on every HEALTHY tick (every 5 min), so a live lane
# is refreshed twelve times inside the TTL, and only a lane that is gone - or a
# lane whose supervisor is down, which health reports - ages out. 60 rather
# than the lock's 30 leaves room for a watchdog self-restart and a slow tick. A
# lane that restarts reclaims its OWN task straight away either way.
$script:LedgerDefaultTtlMinutes = 60
$script:LedgerDefaultWaitSeconds = 20

# The ledger file, or $null when the ledger is switched off. `off` is the
# kill switch the acceptance script's negative control uses to prove its
# assertions can go red without the ledger.
function Get-LedgerPath {
    $v = [string]$env:GHOZTTY_LOOP_LEDGER
    if ($v.Trim() -eq 'off') { return $null }
    if ($v.Trim()) { return [System.IO.Path]::GetFullPath($v.Trim()) }
    return (Get-LedgerDefaultPath)
}

function Get-LedgerDefaultPath {
    $base = [string]$env:LOCALAPPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    if (-not $base) { return $null }
    return (Join-Path (Join-Path $base 'ghoztty') 'loop-ledger.json')
}

# The real ledger keeps the plain name; any other path gets a hash suffix, so a
# harness's private ledger has a private lock as well as a private file.
function Get-LedgerMutexName {
    param([string]$Path)
    $default = Get-LedgerDefaultPath
    if ($default -and ([string]::Equals($Path, $default, [StringComparison]::OrdinalIgnoreCase))) {
        return 'Local\GhozttyLoopLedger'
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant()))
    }
    finally { $sha.Dispose() }
    $hex = -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
    return ('Local\GhozttyLoopLedger-' + $hex)
}

function Get-LedgerTtlMinutes {
    $raw = [string]$env:GHOZTTY_LOOP_LEDGER_TTL_MIN
    $d = 0.0
    if ($raw -and [double]::TryParse($raw.Trim(), [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) {
        return $d
    }
    return [double]$script:LedgerDefaultTtlMinutes
}

# Which lane this is. GHOZTTY_LOOP_LANE names it explicitly (the harness runs
# two lanes from one tree that way); otherwise it is the worktree itself - the
# lowercased full path of its git toplevel - which is distinct per worktree by
# construction and needs no configuration to bring a second lane up.
function Get-LedgerLane {
    param([string]$Root)
    $named = [string]$env:GHOZTTY_LOOP_LANE
    if ($named.Trim()) { return $named.Trim() }
    $top = $null
    if ($Root) {
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $top = [string](& git -C $Root rev-parse --show-toplevel 2>$null | Select-Object -Last 1) }
        catch { $top = $null }
        finally { $ErrorActionPreference = $eap }
        if ($LASTEXITCODE -ne 0) { $top = $null }
    }
    if (-not $top) { $top = $Root }
    if (-not $top) { $top = (Get-Location).Path }
    $full = [System.IO.Path]::GetFullPath($top.Trim()).Replace('/', '\').TrimEnd('\')
    return $full.ToLowerInvariant()
}

function Get-LedgerNowIso {
    return (Get-Date).ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-LedgerTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$dt)) {
        return $dt.ToUniversalTime()
    }
    return $null
}

# A claim is live while its heartbeat is younger than the TTL. A claim with no
# readable `touched` is dead: an unparseable timestamp must not pin a task to a
# lane forever.
function Test-LedgerClaimLive {
    param($Claim, $Now = $null)
    if ($null -eq $Claim) { return $false }
    $t = ConvertTo-LedgerTime $Claim.touched
    if ($null -eq $t) { return $false }
    # Untyped on purpose: PowerShell unwraps a [Nullable[datetime]] parameter
    # to a bare [datetime], whose `.Value` is $null - which made every claim
    # read as live, however old.
    $n = if ($null -ne $Now) { ([datetime]$Now).ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
    return (($n - $t).TotalMinutes -lt (Get-LedgerTtlMinutes))
}

function New-EmptyLedger {
    return @{ version = 1; maxId = 0; claims = @{} }
}

# Parse ledger text into the in-memory shape (hashtables, so an update can
# mutate it in place). Returns $null when the text is not a ledger at all.
function ConvertFrom-LedgerText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { $obj = $Text | ConvertFrom-Json } catch { return $null }
    if ($null -eq $obj -or $obj -isnot [psobject] -or $obj -is [string] -or $obj -is [array]) { return $null }
    $names = @($obj.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -notcontains 'claims' -and $names -notcontains 'maxId') { return $null }
    $l = New-EmptyLedger
    $n = 0
    if ($null -ne $obj.maxId -and [int]::TryParse([string]$obj.maxId, [ref]$n)) { $l.maxId = $n }
    elseif ($null -ne $obj.maxId) { return $null }
    if ($null -ne $obj.claims) {
        foreach ($p in $obj.claims.PSObject.Properties) {
            $c = $p.Value
            if ($null -eq $c) { continue }
            $l.claims[$p.Name] = @{
                lane    = [string]$c.lane
                root    = [string]$c.root
                pid     = $c.pid
                at      = [string]$c.at
                touched = [string]$c.touched
            }
            # T2033: a reservation - a task this lane closed and has not
            # pushed yet. Absent on an ordinary claim.
            foreach ($f in @('closed', 'path', 'pushedAt')) {
                $v = $c.PSObject.Properties[$f]
                if ($null -ne $v -and $v.Value) { $l.claims[$p.Name][$f] = [string]$v.Value }
            }
        }
    }
    return $l
}

# Read the file. With -Recover (the locked write path) an unparseable ledger is
# backed up beside itself before being treated as empty, so the evidence of
# whatever broke it survives the write that replaces it.
function Read-LedgerFile {
    param([string]$Path, [switch]$Recover)
    if (-not (Test-Path -LiteralPath $Path)) { return (New-EmptyLedger) }
    $text = $null
    for ($i = 0; $i -lt 5; $i++) {
        try { $text = [System.IO.File]::ReadAllText($Path); break }
        catch { Start-Sleep -Milliseconds 50 }
    }
    if ($null -eq $text) {
        Write-Warning ("LEDGER UNREADABLE: {0} could not be opened; treating it as empty for this call (T1981)." -f $Path)
        return (New-EmptyLedger)
    }
    $l = ConvertFrom-LedgerText -Text $text
    if ($null -ne $l) { return $l }
    if ($Recover) {
        $backup = '{0}.corrupt-{1}' -f $Path, (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
        try { Copy-Item -LiteralPath $Path -Destination $backup -Force -ErrorAction Stop }
        catch { $backup = '(backup failed: ' + $_.Exception.Message + ')' }
        Write-Warning ("LEDGER RECOVERED: {0} was not a readable ledger; backed it up to {1} and started fresh. Claims held by other lanes are forgotten until they are re-made (T1981)." -f $Path, $backup)
    }
    else {
        Write-Warning ("LEDGER UNREADABLE: {0} is not a readable ledger; treating it as empty (the next write backs it up and starts fresh) (T1981)." -f $Path)
    }
    return (New-EmptyLedger)
}

function Write-LedgerFile {
    param([string]$Path, [hashtable]$Ledger)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Ordered on the way out, so the file reads the same way twice and a human
    # diffing two snapshots sees what moved rather than hash-table churn.
    $claims = [ordered]@{}
    foreach ($k in @($Ledger.claims.Keys | Sort-Object { [int]([regex]::Match($_, '\d+').Value) }, { $_ })) {
        $c = $Ledger.claims[$k]
        $o = [ordered]@{ lane = $c.lane; root = $c.root; pid = $c.pid; at = $c.at; touched = $c.touched }
        foreach ($f in @('closed', 'path', 'pushedAt')) { if ($c[$f]) { $o[$f] = $c[$f] } }
        $claims[$k] = $o
    }
    $doc = [ordered]@{ version = 1; maxId = [int]$Ledger.maxId; claims = $claims }
    $json = ConvertTo-Json -InputObject $doc -Depth 6
    $tmp = '{0}.tmp-{1}' -f $Path, $PID
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    $lastErr = $null
    for ($i = 0; $i -lt 10; $i++) {
        try {
            # [NullString]: a bare $null reaches a .NET string parameter as ""
            # in PS 5.1, which Replace rejects as "not of a legal form".
            if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
            else { [System.IO.File]::Move($tmp, $Path) }
            return
        }
        catch { $lastErr = $_; Start-Sleep -Milliseconds 50 }
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    throw ("LoopLedger: could not replace {0}: {1}" -f $Path, $lastErr.Exception.Message)
}

function Remove-ExpiredLedgerClaims {
    param([hashtable]$Ledger)
    $now = (Get-Date).ToUniversalTime()
    foreach ($k in @($Ledger.claims.Keys)) {
        if (-not (Test-LedgerClaimLive -Claim $Ledger.claims[$k] -Now $now)) { $Ledger.claims.Remove($k) }
    }
}

# Run $Body while holding the ledger's mutex. With -Write, $Body receives the
# ledger (expired claims already pruned), may mutate it, and the result is
# written back atomically before the lock is released. Returns $Body's output.
function Invoke-LedgerLocked {
    param([Parameter(Mandatory = $true)][scriptblock]$Body, [string]$LedgerPath, [switch]$Write)
    if (-not $LedgerPath) { $LedgerPath = Get-LedgerPath }
    if (-not $LedgerPath) { throw 'LoopLedger: the ledger is off (GHOZTTY_LOOP_LEDGER=off).' }
    $waitSec = $script:LedgerDefaultWaitSeconds
    $w = 0
    if ($env:GHOZTTY_LOOP_LEDGER_WAIT_SEC -and [int]::TryParse([string]$env:GHOZTTY_LOOP_LEDGER_WAIT_SEC, [ref]$w) -and $w -gt 0) { $waitSec = $w }
    $mutexName = Get-LedgerMutexName -Path $LedgerPath
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $held = $false
    try {
        try { $held = $mutex.WaitOne([TimeSpan]::FromSeconds($waitSec)) }
        catch {
            # An abandoned mutex means the previous holder died mid-update. The
            # write is temp-file-then-replace, so the file itself is whole; the
            # lock is ours now.
            $ex = $_.Exception
            while ($ex -and $ex -isnot [System.Threading.AbandonedMutexException]) { $ex = $ex.InnerException }
            if ($ex) { $held = $true } else { throw }
        }
        if (-not $held) {
            throw ("LoopLedger: waited {0}s for mutex {1} guarding {2} and never got it - another parity-tasks process is holding the ledger. Nothing was claimed or written; retry (T1981)." -f $waitSec, $mutexName, $LedgerPath)
        }
        $ledger = Read-LedgerFile -Path $LedgerPath -Recover:$Write
        if ($Write) { Remove-ExpiredLedgerClaims -Ledger $ledger }
        $result = & $Body $ledger
        if ($Write) { Write-LedgerFile -Path $LedgerPath -Ledger $ledger }
        return $result
    }
    finally {
        if ($held) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

# The read-modify-write entry point. $Update gets the ledger hashtable.
function Invoke-LedgerUpdate {
    param([Parameter(Mandatory = $true)][scriptblock]$Update, [string]$LedgerPath)
    return (Invoke-LedgerLocked -Body $Update -LedgerPath $LedgerPath -Write)
}

# A consistent snapshot (taken under the lock, so never half a write). Expired
# claims are left in for a reader that wants to show them; use
# Test-LedgerClaimLive to tell.
function Read-Ledger {
    param([string]$LedgerPath)
    return (Invoke-LedgerLocked -Body { param($l) $l } -LedgerPath $LedgerPath)
}

# Every LIVE claim held by a lane other than $Lane, as id -> claim. What `next`
# consults to skip work somebody else is on.
function Get-LedgerOtherLaneClaims {
    param([string]$Lane, [string]$LedgerPath)
    $l = Read-Ledger -LedgerPath $LedgerPath
    $out = @{}
    $now = (Get-Date).ToUniversalTime()
    foreach ($k in @($l.claims.Keys)) {
        $c = $l.claims[$k]
        if ($c.lane -ne $Lane -and (Test-LedgerClaimLive -Claim $c -Now $now)) { $out[$k] = $c }
    }
    return $out
}

# The holder claim when ANOTHER live lane holds $Id, else $null.
function Test-ClaimHeldByOtherLane {
    param([string]$Id, [string]$Lane, [string]$LedgerPath)
    $held = Get-LedgerOtherLaneClaims -Lane $Lane -LedgerPath $LedgerPath
    if ($held.ContainsKey($Id)) { return $held[$Id] }
    return $null
}

# Atomic check-and-set. Claimed=$true when $Lane now holds $Id (fresh, or a
# re-claim that refreshes its heartbeat); Claimed=$false with the Holder when
# another live lane has it - the caller lost the race and must pick again.
function Set-LedgerClaim {
    param([string]$Id, [string]$Lane, [string]$Root, [string]$LedgerPath)
    $now = Get-LedgerNowIso
    $procId = $PID
    $upd = {
        param($l)
        $c = $l.claims[$Id]
        if ($null -ne $c -and $c.lane -ne $Lane) {
            return [pscustomobject]@{ Claimed = $false; Holder = $c }
        }
        $at = if ($null -ne $c -and $c.at) { $c.at } else { $now }
        $l.claims[$Id] = @{ lane = $Lane; root = $Root; pid = $procId; at = $at; touched = $now }
        return [pscustomobject]@{ Claimed = $true; Holder = $null }
    }.GetNewClosure()
    return (Invoke-LedgerUpdate -Update $upd -LedgerPath $LedgerPath)
}

# Drop $Lane's claim on $Id. Result: 'cleared' | 'absent' | 'other' (another
# live lane holds it, which is left alone - only the holder releases a claim).
function Clear-LedgerClaim {
    param([string]$Id, [string]$Lane, [string]$LedgerPath)
    $upd = {
        param($l)
        $c = $l.claims[$Id]
        if ($null -eq $c) { return [pscustomobject]@{ Result = 'absent'; Holder = $null } }
        if ($c.lane -ne $Lane) { return [pscustomobject]@{ Result = 'other'; Holder = $c } }
        $l.claims.Remove($Id)
        return [pscustomobject]@{ Result = 'cleared'; Holder = $null }
    }.GetNewClosure()
    return (Invoke-LedgerUpdate -Update $upd -LedgerPath $LedgerPath)
}

# Heartbeat: refresh `touched` on $Id when $Lane holds it. $true if it did.
function Update-LedgerClaimTouch {
    param([string]$Id, [string]$Lane, [string]$LedgerPath)
    $now = Get-LedgerNowIso
    $upd = {
        param($l)
        $c = $l.claims[$Id]
        if ($null -eq $c -or $c.lane -ne $Lane) { return $false }
        $c.touched = $now
        return $true
    }.GetNewClosure()
    return [bool](Invoke-LedgerUpdate -Update $upd -LedgerPath $LedgerPath)
}

# Hand out the next task number: one past the higher of the ledger's
# high-water mark and the caller's on-disk max, recorded before the lock is
# released. Two lanes whose files both stop at T1986 therefore get 1987 and
# 1988, never 1987 twice.
function Reserve-LedgerId {
    param([int]$DiskMax, [string]$LedgerPath)
    $upd = {
        param($l)
        $n = [math]::Max([int]$l.maxId, $DiskMax) + 1
        $l.maxId = $n
        return $n
    }.GetNewClosure()
    return [int](Invoke-LedgerUpdate -Update $upd -LedgerPath $LedgerPath)
}

# Raise the high-water mark to at least $N (an id that was minted some other
# way, e.g. the CreateNew retry stepping past a file that already existed).
function Set-LedgerMaxIdAtLeast {
    param([int]$N, [string]$LedgerPath)
    $upd = {
        param($l)
        if ([int]$l.maxId -lt $N) { $l.maxId = $N }
        return [int]$l.maxId
    }.GetNewClosure()
    return [int](Invoke-LedgerUpdate -Update $upd -LedgerPath $LedgerPath)
}

# --- reservations (T2033) -------------------------------------------------------

# True for a status that takes a task out of the queue: anything but todo and
# in-progress. `todo` is an abandonment and releases outright.
function Test-LedgerClosedStatus {
    param([string]$Status)
    $s = ([string]$Status).Trim().Trim('"')
    if (-not $s) { return $false }
    return ($s -notmatch '^(todo|in-progress)')
}

# The `status:` value in a task file's text, or $null.
function Get-LedgerStatusFromText {
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '(?m)^status:\s*"?([^"\r\n]*)"?\s*$')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.Trim()
}

# Turn $Lane's claim on $Id into a reservation that keeps the task away from
# every other lane until the close has reached them. Result: 'reserved', or
# 'other' when another live lane holds it (left alone: only the holder closes).
# A close with no claim at all (expired, or never claimed) still reserves.
function Set-LedgerReservation {
    param([string]$Id, [string]$Lane, [string]$Root, [string]$Status, [string]$Path, [string]$LedgerPath)
    $now = Get-LedgerNowIso
    $procId = $PID
    $upd = {
        param($l)
        $c = $l.claims[$Id]
        if ($null -ne $c -and $c.lane -ne $Lane) {
            return [pscustomobject]@{ Result = 'other'; Holder = $c }
        }
        $at = if ($null -ne $c -and $c.at) { $c.at } else { $now }
        $l.claims[$Id] = @{ lane = $Lane; root = $Root; pid = $procId; at = $at; touched = $now
            closed = $Status; path = $Path }
        return [pscustomobject]@{ Result = 'reserved'; Holder = $null }
    }.GetNewClosure()
    return (Invoke-LedgerUpdate -Update $upd -LedgerPath $LedgerPath)
}

# Has the finishing lane's close reached its upstream? Reads the task file at
# `@{u}` in the worktree that holds it - which that lane's own push advances -
# and never fetches. 'pushed' (upstream shows a closed status), 'unpushed'
# (upstream shows it open, or does not have the file yet), or 'unknown' (no
# such worktree, not a git tree, no upstream configured).
function Get-LedgerReservationPushState {
    param($Claim)
    $path = [string]$Claim.path
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 'unknown' }
    $dir = Split-Path -Parent $path
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $top = [string](& git -C $dir rev-parse --show-toplevel 2>$null | Select-Object -Last 1)
        if ($LASTEXITCODE -ne 0 -or -not $top) { return 'unknown' }
        $null = & git -C $top rev-parse --verify --quiet '@{u}' 2>$null
        if ($LASTEXITCODE -ne 0) { return 'unknown' }
        $topFull = [System.IO.Path]::GetFullPath($top.Trim()).TrimEnd('\') + '\'
        $full = [System.IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith($topFull, [StringComparison]::OrdinalIgnoreCase)) { return 'unknown' }
        $rel = $full.Substring($topFull.Length).Replace('\', '/')
        $text = (& git -C $top show ('@{u}:' + $rel) 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { return 'unpushed' }
        if (Test-LedgerClosedStatus (Get-LedgerStatusFromText $text)) { return 'pushed' }
        return 'unpushed'
    }
    catch { return 'unknown' }
    finally { $ErrorActionPreference = $eap }
}

# The upkeep `next` runs before it reads the claims. For each live reservation:
#
# - $Lane is NOT the finisher and its own copy of the task ($ViewDir) already
#   reads closed -> this lane has caught up; the reservation is removed.
# - the close is still unpushed -> its heartbeat is refreshed: the work exists
#   and has not left the box, so the other lane must keep off it however long
#   that takes (nothing else touches a closed task - the watchdog only touches
#   in-progress ones).
# - the close is pushed -> `pushedAt` is stamped once, and the reservation is
#   removed a TTL later even if no other lane ever reads it, so nothing is left
#   stuck. A lane that has pulled clears it at once by the first rule.
# - unknown (the finishing worktree is gone) -> left to age out on its TTL.
#
# The git reads happen OUTSIDE the ledger lock; the write re-checks that the
# entry is the one that was read. Returns one line per notable action.
function Update-LedgerReservations {
    param([string]$Lane, [string]$ViewDir, [string]$LedgerPath)
    $l = Read-Ledger -LedgerPath $LedgerPath
    $now = (Get-Date).ToUniversalTime()
    $plan = @()
    foreach ($k in @($l.claims.Keys)) {
        $c = $l.claims[$k]
        if (-not $c.closed -or -not (Test-LedgerClaimLive -Claim $c -Now $now)) { continue }
        if ($c.lane -ne $Lane -and $ViewDir) {
            $mine = Join-Path $ViewDir ($k + '.md')
            if (Test-Path -LiteralPath $mine) {
                $st = Get-LedgerStatusFromText ([System.IO.File]::ReadAllText($mine))
                if (Test-LedgerClosedStatus $st) { $plan += @{ Id = $k; Act = 'caught-up'; At = $c.at }; continue }
            }
        }
        $ps = Get-LedgerReservationPushState -Claim $c
        if ($ps -eq 'unpushed') { $plan += @{ Id = $k; Act = 'refresh'; At = $c.at } }
        elseif ($ps -eq 'pushed') {
            $pa = ConvertTo-LedgerTime $c.pushedAt
            if ($null -eq $pa) { $plan += @{ Id = $k; Act = 'pushed'; At = $c.at } }
            elseif (($now - $pa).TotalMinutes -ge (Get-LedgerTtlMinutes)) { $plan += @{ Id = $k; Act = 'expired'; At = $c.at } }
        }
    }
    if ($plan.Count -eq 0) { return @() }
    $stamp = Get-LedgerNowIso
    $upd = {
        param($ld)
        $out = @()
        foreach ($p in $plan) {
            $c = $ld.claims[$p.Id]
            if ($null -eq $c -or -not $c.closed -or $c.at -ne $p.At) { continue }
            switch ($p.Act) {
                'caught-up' { $ld.claims.Remove($p.Id); $out += ('{0} reservation cleared: this lane already reads it {1}' -f $p.Id, $c.closed) }
                'expired'   { $ld.claims.Remove($p.Id); $out += ('{0} reservation cleared: pushed more than a TTL ago' -f $p.Id) }
                'refresh'   { $c.touched = $stamp }
                'pushed'    { $c.pushedAt = $stamp; $out += ('{0} reservation: the close is on the upstream; held until the other lane reads it' -f $p.Id) }
            }
        }
        return $out
    }.GetNewClosure()
    return @(Invoke-LedgerUpdate -Update $upd -LedgerPath $LedgerPath)
}
