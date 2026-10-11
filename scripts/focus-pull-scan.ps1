# Report shell pickers left on the user's desktop (T1823).
#
# When something ShellExecutes a file whose type has no open verb, Windows
# answers with OpenWith.exe - the "How do you want to open this file?" picker -
# started by DCOM on the INTERACTIVE desktop, whichever desktop the caller ran
# on, and it takes the foreground and keeps it until somebody dismisses it.
# Twice on 2026-10-10/11 the caller was an agent running the banner hook's .sh
# from PowerShell, and the pickers sat over the user's screen for hours while
# every turn went on as if nothing had happened; one of them made T1820's
# foreground assertion fail for a reason no test could name.
#
# `go-loop-exec.ps1 claim` calls this every turn. It REPORTS and never refuses:
# a picker is the user's to dismiss (it is their screen), and the remedy is
# finding the caller, which is a task. Silent when there is nothing to say.
#
#   powershell -NoProfile -File scripts\focus-pull-scan.ps1
#
# -ProcessJson replaces the live process list with a JSON array of
# { ProcessId, CreationDate, CommandLine } so the acceptance harness
# (test\win32\focus-pull-scan.ps1) can construct the state without putting a
# real picker on anybody's screen.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$ProcessJson = ''
)

$ErrorActionPreference = 'Continue'

function Get-PickerProcesses {
    if ($ProcessJson) {
        # Assign first: PS 5.1's ConvertFrom-Json emits a JSON array as ONE
        # pipeline object, so @(... | ConvertFrom-Json) is a 1-element array.
        try { $parsed = $ProcessJson | ConvertFrom-Json; return @($parsed) } catch { return @() }
    }
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='OpenWith.exe'" -ErrorAction Stop |
            ForEach-Object {
                [pscustomobject]@{
                    ProcessId    = $_.ProcessId
                    CreationDate = if ($_.CreationDate) { $_.CreationDate.ToString('yyyy-MM-dd HH:mm:ss') } else { '?' }
                    CommandLine  = $_.CommandLine
                }
            })
    } catch {
        return @()
    }
}

$pickers = @(Get-PickerProcesses | Where-Object { $_ -and $_.ProcessId })
if ($pickers.Count -eq 0) { exit 0 }

$list = ($pickers | ForEach-Object { "pid $($_.ProcessId) since $($_.CreationDate)" }) -join ', '
"FOCUS PULL: $($pickers.Count) 'How do you want to open this file?' picker(s) on the user's desktop ($list)."
'    Something ShellExecuted a file with no handler - a .sh run from PowerShell is the known caller (T1823).'
'    Match the start time against the turn that ran then; the picker is the user''s to dismiss.'
exit 0
