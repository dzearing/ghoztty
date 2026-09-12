<#
The sweep behind T694: no acceptance script may go back to guessing a TCP port.

`lib\FreePort.ps1` is the remedy - draw the port, assert it free, print it. This
is the thing that keeps the remedy from rotting: a copy-paste of an old script,
or a new fixture written from memory, reintroduces a fixed number in one line
and nothing would otherwise notice until two scripts collided on a Tuesday.

THREE SHAPES ARE VIOLATIONS, on any line that is not a comment:

  pinned-default     [int]$RelayPort = 47911
                     a param default nobody passes, so it IS the port.

  literal-assignment $ppPort = 47163
                     the same guess, one scope in.

  literal-endpoint   "http://127.0.0.1:47999/"
                     a number baked into an address. Even an endpoint the run
                     deliberately never binds ("nothing is listening here")
                     belongs to `Get-FreePort`, which at least VERIFIED the
                     port was free; a guessed one may quietly have an owner.

A port of 0 is the whole point and is never a violation. Values outside
1024-65535 are not ports (a sha, an HRESULT, a timeout in ms), so they are
ignored rather than guessed at.

    Get-FixedPortViolations -Path test\win32\ipc-relay.ps1
      -> @{ File; Line; Kind; Text }  (empty when the file is clean)

Acceptance: `test\win32\fixed-ports.ps1` - section B drives this analyzer over
fixtures in both directions, section C runs it over every acceptance script.
#>

function Get-FixedPortViolations {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    $out = @()
    if (-not (Test-Path $Path)) { return $out }
    # @() because Get-Content on a ONE-LINE file returns a bare string, and
    # indexing a string hands back a [char] - which has no .Trim().
    $lines = @(Get-Content -LiteralPath $Path)
    $inBlockComment = $false
    $inHereString = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $t = $raw.Trim()

        # Here-strings hold FIXTURE text - a synthesized script an audit scores
        # without ever running it (`persistence-flag.ps1` writes one that names
        # 127.0.0.1:7777). Nothing in there binds anything on this box.
        if ($inHereString) {
            if ($t -match "^[`"']@") { $inHereString = $false }
            continue
        }
        if ($raw -match "@[`"']\s*$") { $inHereString = $true; continue }

        # Block comments (<# ... #>) carry the doc prose, which names ports on
        # purpose - this file does it a dozen lines above.
        if ($inBlockComment) {
            if ($t -match '#>') { $inBlockComment = $false }
            continue
        }
        if ($t -match '^<#') {
            if ($t -notmatch '#>') { $inBlockComment = $true }
            continue
        }
        if ($t.StartsWith('#')) { continue }

        # Each shape's captures are pulled into locals BEFORE anything else runs
        # a -match: in PowerShell every -match rewrites $matches, so reading
        # $matches[2] after a `$matches[1] -match 'port'` test reads the WRONG
        # match. (The T217 trap's cousin, and just as quiet.)
        $kind = $null
        if ($raw -match '\[int\]\s*\$([A-Za-z_]\w*)\s*=\s*(\d+)') {
            $name = $matches[1]; $num = $matches[2]
            if ($name -match 'port' -and (Test-IsPortNumber $num)) { $kind = 'pinned-default' }
        }
        if (-not $kind -and $raw -match '^\s*\$(?:script:|global:)?([A-Za-z_]\w*)\s*=\s*(\d+)\s*(?:#.*)?$') {
            $name = $matches[1]; $num = $matches[2]
            if ($name -match 'port' -and (Test-IsPortNumber $num)) { $kind = 'literal-assignment' }
        }
        if (-not $kind -and $raw -match '(?:127\.0\.0\.1|localhost):(\d+)') {
            $num = $matches[1]
            if (Test-IsPortNumber $num) { $kind = 'literal-endpoint' }
        }

        if ($kind) {
            $out += [pscustomobject]@{
                File = $Path
                Line = $i + 1
                Kind = $kind
                Text = $t
            }
        }
    }
    # Plain `return $out`, never `return ,$out`: the comma form hands an `@()`
    # call site ONE element that IS the array - which on the first run here read
    # as "1 violation" for an empty result and for a three-violation one alike.
    # Callers wrap in @() and get 0, 1 or n.
    return $out
}

# 1024-65535 is a port. Anything else on a line that looked port-shaped is a
# timeout, an HRESULT, or a digit run inside a sha - not our business.
function Test-IsPortNumber($value) {
    $n = 0
    if (-not [int]::TryParse([string]$value, [ref]$n)) { return $false }
    return ($n -ge 1024 -and $n -le 65535)
}
