<#
A TCP port the OS just handed out, not a number somebody guessed (T694).

THE TRAP. An acceptance script that binds a fixed port has two ways to fail
that both read as a PRODUCT bug rather than a harness one:

  1. Its own previous run is still letting go of the number. The listener is
     gone but the socket is in TIME_WAIT, so a bind fails - or worse, a
     `TcpClient.Connect` "succeeds" against a socket that will never answer,
     and the section that follows produces no assertions at all.
  2. Two DIFFERENT scripts guessed the same number. Before this file,
     `chooser-menu.ps1` and `ipc-machine-chooser.ps1` both wanted 47931,
     `host-settings.ps1` and `chooser-sessions-remote.ps1` both wanted
     47941/47942, and three scripts wanted 47913 - so "these two cannot run
     near each other" was a standing constraint nobody had written down.

T171 solved it once, inside `relay-account.ps1`. This is that solution, shared,
so no script has to guess again.

THE ANSWER. Draw the port, assert it is free, say which one you drew:

    . (Join-Path $PSScriptRoot 'lib\FreePort.ps1')

    param([int]$RelayPort = 0)          # 0 = draw one; a caller may still pin
    $RelayPort = Resolve-TestPort -Name 'relay' -Port $RelayPort

`Resolve-TestPort` draws an ephemeral port when it is given 0, re-draws if the
one it drew went busy between the draw and the check, and THROWS when a port a
caller pinned by hand is already in use - because that is an operator error and
a silent fallback would hide it. It prints `  PORT relay = 51423` either way, so
a run that later fails against a port can be traced to the number it drew.

`Get-FreePort` and `Test-PortFree` are the pieces underneath, for a caller that
needs a port it deliberately never binds (a "nothing is listening here" endpoint
is a DRAWN port, which was verified free, rather than a guessed one that may not
be).

Acceptance: `test\win32\fixed-ports.ps1` (sections A and B), whose section C
also sweeps every acceptance script for a port that went back to being guessed.
#>

# A port nobody holds: bind an ephemeral one and let it go. A port that WAS free
# a moment ago beats a guessed number.
function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = $l.LocalEndpoint.Port
    $l.Stop()
    return $p
}

# Is this port bindable RIGHT NOW? Asserted before each listener starts, so a
# port that is still held fails loudly here instead of turning into a fake relay
# that never came up and a section that mysteriously produces no assertions.
function Test-PortFree([int]$port) {
    try {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $l.Start(); $l.Stop()
        return $true
    } catch { return $false }
}

# Draw (or check) the port this run will use, and say which one it is.
#   -Port 0          draw an ephemeral port, re-drawing if it goes busy
#   -Port <n>        use the caller's number, and THROW if it is already held
function Resolve-TestPort {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Port = 0,
        [int]$Attempts = 8
    )
    if ($Port -ne 0) {
        if (-not (Test-PortFree $Port)) {
            throw "port $Port (pinned for '$Name') is already in use - pass 0 to draw one"
        }
        Write-Host "  PORT $Name = $Port (pinned)"
        return $Port
    }
    for ($i = 0; $i -lt $Attempts; $i++) {
        $p = Get-FreePort
        if (Test-PortFree $p) {
            Write-Host "  PORT $Name = $p"
            return $p
        }
    }
    throw "could not draw a free port for '$Name' in $Attempts attempts"
}
