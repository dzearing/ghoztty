# Fake Ghoztty IPC pipe server for validating the CLI client (task T03).
#
# Binds the same named pipe a real instance would own, accepts ONE
# connection, prints the framed JSON request it receives, and replies with
# a canned framed response. Run it in one shell, then in another:
#
#   $env:GHOZTTY_PIPE_SUFFIX = '-fake-<pid it printed>'
#   .\ghoztty.exe +list
#   .\ghoztty.exe +close --target=x
#
# The pipe it binds:
#   (no switch)  -> \\.\pipe\ghoztty-fake-<pid>-<username>  (private, T1119)
#   -Suffix <s>  -> \\.\pipe\ghoztty<s>-<username>
#   -DebugPipe   -> \\.\pipe\ghoztty-debug-<username>       (a Debug exe's own)
# A name already bound fails with a SETUP sentence and exit 3.
#
# Framing (both directions): 4-byte big-endian length + UTF-8 JSON.
#
# verdict-audit: a helper process, not an acceptance script. It asserts nothing
# and has no verdict to report, so it prints no ALL PASS and scores no exit code
# (T221). Do not give it one - an invented verdict would be a green line about a
# script that never checked anything.

# -Wedge (T755) is the state a bounded client has to be measured against: a
# peer that CONNECTS and reads the request and then never answers. That is not
# a hypothetical - the real server marshals every request to its GUI thread and
# waits on it with no timeout, so a busy or wedged GUI thread looks exactly
# like this from the client side. Before T755 the client blocked on it forever
# (measured at 34 minutes on 2026-08-11).
#
# -Suffix names the pipe explicitly, so an acceptance script can bind a PRIVATE
# endpoint and point the CLI at it with $GHOZTTY_PIPE_SUFFIX instead of taking
# the name a real instance (the user's, or the build under test) would use.
param(
    [switch]$DebugPipe,
    [switch]$Wedge,
    [string]$Suffix,
    [string]$Response = '{"success":true,"data":{"windows":[]}}'
)

# isolation: none - this is the SERVER half: it binds a pipe and answers, and
# never dials one; the +verbs above are usage examples for the shell that runs
# the client. Callers isolate via -Suffix (T680 meta-check reads this marker).

$ErrorActionPreference = 'Stop'

# T1119: with neither switch the name used to be the RELEASE endpoint,
# ghoztty-<user> - the pipe the user's installed Ghoztty owns. Run bare it
# collided with their live terminal ("All pipe instances are busy", the T1094
# sweep's crash), and on a box where that terminal was closed it would have
# squatted on it, answering their CLI with a canned reply. A bare run now binds
# a private per-process name; the real endpoints are reachable only by asking
# for them (-DebugPipe, or -Suffix '' for the release name).
$sfx = if ($PSBoundParameters.ContainsKey('Suffix')) { $Suffix }
       elseif ($DebugPipe) { '-debug' }
       else { "-fake-$PID" }
$name = "ghoztty$sfx-$env:USERNAME"
try {
    $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
        $name,
        [System.IO.Pipes.PipeDirection]::InOut,
        1  # maxNumberOfServerInstances
    )
} catch {
    # The raw .NET text names neither the pipe nor what to do about it. Who
    # holds it is not asked: finding out means connecting as a client, and the
    # holder may be the user's live terminal.
    $who = if ($sfx -eq '') { "the release endpoint - normally the user's installed Ghoztty" }
           elseif ($sfx -eq '-debug') { 'the debug endpoint - normally a running zig-out Debug build' }
           else { 'another process already bound this exact name' }
    $why = $_.Exception.Message
    if ($_.Exception.InnerException) { $why = $_.Exception.InnerException.Message }
    $why = $why.Trim().TrimEnd('.')
    [Console]::Error.WriteLine("SETUP: cannot bind \\.\pipe\$name ($who): $why. Pass a private -Suffix instead of a real endpoint.")
    exit 3
}

Write-Host "listening on \\.\pipe\$name (one request, then exit)"
$pipe.WaitForConnection()

function Read-Exact([System.IO.Pipes.NamedPipeServerStream]$stream, [int]$count) {
    $buf = New-Object byte[] $count
    $off = 0
    while ($off -lt $count) {
        $n = $stream.Read($buf, $off, $count - $off)
        if ($n -eq 0) { throw "pipe closed after $off/$count bytes" }
        $off += $n
    }
    return $buf
}

$lenBuf = Read-Exact $pipe 4
if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($lenBuf) }
$len = [BitConverter]::ToUInt32($lenBuf, 0)
if ($len -eq 0 -or $len -gt 1MB) { throw "implausible request length: $len" }

$body = Read-Exact $pipe ([int]$len)
$json = [Text.Encoding]::UTF8.GetString($body)
Write-Host "request ($len bytes): $json"

if ($Wedge) {
    # Hold the connection open and answer nothing, until the caller kills us.
    # The client is the subject here; this process only has to keep existing.
    Write-Host "WEDGED: holding the connection open, sending no response"
    while ($true) { Start-Sleep -Seconds 3600 }
}

$respBytes = [Text.Encoding]::UTF8.GetBytes($Response)
$rlen = [BitConverter]::GetBytes([uint32]$respBytes.Length)
if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($rlen) }
$pipe.Write($rlen, 0, 4)
$pipe.Write($respBytes, 0, $respBytes.Length)
$pipe.Flush()
$pipe.WaitForPipeDrain()
$pipe.Disconnect()
$pipe.Dispose()

Write-Host "responded with: $Response"
Write-Host "OK"
