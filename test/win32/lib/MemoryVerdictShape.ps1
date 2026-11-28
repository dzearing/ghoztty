# MemoryVerdictShape.ps1 (T2673) - which memory-harness runs may stamp a guard.
#
# A memory guard asks one question: does THIS checkout's debug build, measured
# the default way, stay inside budget? A run that measured something else - a
# release exe under the sandbox, a narrowed shape, a longer warm-up, a census
# attach - answers a different question, and a green from it must not stamp.
# On 2026-11-03 two `-ReleaseSandbox -Report` runs against a ReleaseFast
# -ExePath stamped window-close-memory green (and cleared its ack) while the
# default verdict at the same code was red.
#
# Each function returns the list of reasons a run is diagnostic; an empty list
# means the run has the verdict shape and may stamp. The caller prints
# `NOT STAMPED (diagnostic run: <reasons>)` so the refusal is visible.

# $true when -ExePath is unset or names this checkout's own zig-out debug exe.
function Test-RepoDefaultExe([string]$Repo, [string]$ExePath) {
    if (-not $ExePath) { return $true }
    $want = [IO.Path]::GetFullPath((Join-Path $Repo 'zig-out\bin\ghoztty.exe'))
    try { $got = [IO.Path]::GetFullPath($ExePath) } catch { return $false }
    return [string]::Equals($want, $got, [StringComparison]::OrdinalIgnoreCase)
}

# Reasons a window-close-memory run is diagnostic. Defaults mirror the
# harness's param block (Shape full, Cycles 10, Warmup 2, MaxWarmup 10).
function Get-WindowCloseMemoryDiagnosticReason {
    param(
        [string]$Repo, [string]$ExePath, [string]$Shape = 'full', [int]$Cycles = 10,
        [int]$Warmup = 2, [int]$MaxWarmup = 10, [string[]]$AppArgs = @(),
        [switch]$Resize, [switch]$CloseSplitFirst, [switch]$Report, [switch]$HeapCensus,
        [string[]]$HeapCensusCommands = @(), [switch]$HeapCensusRegions,
        [switch]$ReleaseSandbox, [switch]$NegativeControl
    )
    $r = New-Object System.Collections.Generic.List[string]
    if (-not (Test-RepoDefaultExe $Repo $ExePath)) { $r.Add("-ExePath $ExePath is not this checkout's zig-out") }
    if ($ReleaseSandbox) { $r.Add('-ReleaseSandbox') }
    if ($Shape -ne 'full') { $r.Add("-Shape $Shape") }
    if ($Cycles -lt 10) { $r.Add("-Cycles $Cycles") }
    if ($Warmup -ne 2) { $r.Add("-Warmup $Warmup") }
    if ($MaxWarmup -ne 10) { $r.Add("-MaxWarmup $MaxWarmup") }
    if (@($AppArgs | Where-Object { $_ }).Count -gt 0) { $r.Add('-AppArgs') }
    if ($Resize) { $r.Add('-Resize') }
    if ($CloseSplitFirst) { $r.Add('-CloseSplitFirst') }
    if ($Report) { $r.Add('-Report') }
    if ($HeapCensus) { $r.Add('-HeapCensus') }
    if (@($HeapCensusCommands | Where-Object { $_ }).Count -gt 0) { $r.Add('-HeapCensusCommands') }
    if ($HeapCensusRegions) { $r.Add('-HeapCensusRegions') }
    if ($NegativeControl) { $r.Add('-NegativeControl') }
    # No leading comma: callers wrap the call in @(), which re-collects a
    # one-reason unroll correctly, whereas `return ,` on an EMPTY array counts
    # as 1 at an @() call site and would refuse every verdict-shape stamp.
    return $r.ToArray()
}
