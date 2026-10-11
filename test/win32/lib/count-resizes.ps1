# T1835 fixture: count the resizes that actually reach a console program.
#
# This is the Windows half of Mac's `aDragDoesNotStormTheProgramWithResizes`,
# whose child is a python SIGWINCH counter. A console program on Windows has no
# SIGWINCH: when the terminal calls ResizePseudoConsole, conhost resizes the
# screen buffer and - for a program that asked with ENABLE_WINDOW_INPUT - puts
# one WINDOW_BUFFER_SIZE_EVENT into its input queue. That event is what a
# full-screen TUI (Claude Code, vim, an editor) repaints on, so it is the thing
# to count: not the app's own idea of how often it resized.
#
# Writes "<count> <cols>x<rows>" to -Out after every event (and "0 <size>" at
# start), so the driver reads both how many resizes arrived and the LAST size
# that did - the final size must always land, debounce or not.
#
# ASCII only (PS 5.1 reads a BOM-less script as ANSI).
param([Parameter(Mandatory = $true)][string]$Out)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class T1835Console {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr h, uint mode);

    [StructLayout(LayoutKind.Explicit, Size = 20)]
    public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        // WINDOW_BUFFER_SIZE_RECORD.dwSize (COORD) sits at offset 4.
        [FieldOffset(4)] public short X;
        [FieldOffset(6)] public short Y;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ReadConsoleInputW(IntPtr h, [Out] INPUT_RECORD[] buf, uint len, out uint read);
}
'@

$STD_INPUT_HANDLE = -10
$ENABLE_WINDOW_INPUT = 0x0008
$WINDOW_BUFFER_SIZE_EVENT = 4

$hIn = [T1835Console]::GetStdHandle($STD_INPUT_HANDLE)
$mode = [uint32]0
[void][T1835Console]::GetConsoleMode($hIn, [ref]$mode)
# Window input on; line/echo/processed input off so keystrokes are records too
# and nothing is echoed over the pane.
[void][T1835Console]::SetConsoleMode($hIn, [uint32]$ENABLE_WINDOW_INPUT)

# The driver polls this file; a read that lands mid-write is a sharing
# violation here, and dying on it would read as "no more resizes arrived".
function Write-Count([string]$text) {
    for ($t = 0; $t -lt 20; $t++) {
        try { [System.IO.File]::WriteAllText($Out, $text); return } catch { Start-Sleep -Milliseconds 10 }
    }
}

$count = 0
$size = "$([Console]::WindowWidth)x$([Console]::WindowHeight)"
Write-Count "0 $size"
Write-Host "T1835 resize counter: writing to $Out"

$buf = New-Object 'T1835Console+INPUT_RECORD[]' 64
while ($true) {
    $read = [uint32]0
    if (-not [T1835Console]::ReadConsoleInputW($hIn, $buf, 64, [ref]$read)) { break }
    $changed = $false
    for ($i = 0; $i -lt $read; $i++) {
        if ($buf[$i].EventType -eq $WINDOW_BUFFER_SIZE_EVENT) {
            $count++
            $size = "$($buf[$i].X)x$($buf[$i].Y)"
            $changed = $true
        }
    }
    if ($changed) { Write-Count "$count $size" }
}
