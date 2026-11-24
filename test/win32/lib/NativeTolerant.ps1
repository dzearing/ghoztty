# NativeTolerant (T2176) - run a native call whose stderr is redirected without
# letting a progress note on stderr end the script.
#
# THE TRAP: under `$ErrorActionPreference = 'Stop'`, Windows PowerShell 5.1
# turns EVERY stderr line of a native call whose stderr is redirected
# (`2>$null`, `2>&1`) into a terminating NativeCommandError. The ghoztty CLI
# prints "Waiting for Ghoztty to answer '...' (the app may still be starting
# up)..." on stderr whenever the app is slow to answer - on its way to
# SUCCEEDING. T1215: soak.ps1's 30-minute run died on exactly that at its
# teardown `+close`, after every assertion had passed, and skipped its cleanup.
# A call with no redirection is not affected: its stderr goes to the console.
#
# USE: wrap the redirected call, and only the call -
#
#     Invoke-Tolerant { & $exe +close --target=x 2>$null | Out-Null }
#     $json = Invoke-Tolerant { & $exe +list --json 2>$null }
#
# The block runs with `Continue` in a child scope, so the caller's `Stop` is
# still in force on the next line, and $LASTEXITCODE (a global) carries the
# call's exit code back. test\win32\native-stderr-audit.ps1 sweeps for an
# unwrapped site and demonstrates this helper against a real stderr line.

Set-StrictMode -Off

function Invoke-Tolerant([scriptblock]$Body) {
    $ErrorActionPreference = 'Continue'
    & $Body
}
