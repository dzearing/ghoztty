# FloorFixture.ps1 - T1285. The P1-P3 floor's fixture is a CHECKED
# precondition, and a floor that cannot reach the app says so ONCE.
#
# THE DEFECT THIS EXISTS TO PREVENT, measured 2026-09-02. `ipc-p2.ps1` scored
#
#     P2 ACCEPTANCE: 16 FAILURE(S) (2 assertions passed)
#
# and every one of those sixteen lines was a claim about the product: +split is
# broken, +send-keys is broken, +rename is broken. None of it was true. What had
# happened was that the app under test stopped answering IPC - the CLI's own
# 5-second "Waiting for Ghoztty to answer ..." notice is in the transcript - so
# every verb after the fixture was addressed to a window that was never built.
# The run before it and the run after it were ALL PASS.
#
# The floor could not tell those apart because the fixture threw its own answer
# away:
#
#     [void](Ghoz @('+new-window', '--target=p2ide'))
#     [void](Wait-ListMatch '\[target: p2ide\]')
#
# An exit code nobody reads is not a check, and a run that keeps asserting
# against a fixture that never came up manufactures failures that point at
# innocent code. That is what "the floor cries wolf" means in practice, and it
# is a harness defect rather than a product one: CLAUDE.md names P1-P3 as the
# bar for every change, so a red nobody can act on is worse than no red at all.
#
# THE SHAPE THIS FILE IMPOSES
#
#   $r = Need-Ghoz 'the p2ide fixture window' @('+new-window', '--target=p2ide')
#
# On success it is `Invoke-OnTestDesktop` and nothing else. On a nonzero exit, a
# harness timeout, or a CLI that said it GAVE UP, it prints ONE `FAIL SETUP:`
# block naming the verb, the exit code, how long it took and what the CLI itself
# said on each stream, scores one failure, and throws `$script:FloorSetupFail`
# so the body stops there instead of cascading.
#
# A call that was merely SLOW - the CLI's 5-second still-waiting notice, then a
# clean exit 0 - is a PASS with a note, not a failure (T894). See
# `$script:FloorSlowPattern` below for why those two sentences are not one
# signal.
#
# Wrap the body with `Invoke-FloorBody { ... }`, which swallows exactly that
# sentinel and lets every other error keep its own trace.
#
# Not a retry. A retry would paper over the same unreachable app and hand back a
# green run; this converts an unreachable app from sixteen wrong answers into
# one right one.

Set-StrictMode -Off

$script:FloorSetupFail = 'GHOZTTY-FLOOR-SETUP-FAIL'

# The two sentences `src/os/ipc_timeout.zig` prints, and the reason they are
# NOT the same signal (T894).
#
# `writeTimeout` is the CLI GIVING UP: the bound ran out and the verb did not
# happen. That is a failure however the exit code reads.
$script:FloorGaveUpPattern = 'Timed out after .* trying to'
#
# `writeNotice` is the CLI saying it is STILL WAITING, printed at 5s while the
# wait continues to the full 30s bound. A cold auto-launch is over 5s BY DESIGN
# - `ipc_timeout.auto_launch_ms` is 30s precisely because the first launch of a
# freshly built exe pays for the loader, Defender scanning it, config parsing
# and a session restore - so this notice on a call that then succeeded means
# "slow box", not "broken app". Until T894 this file scored it as a setup
# FAILURE, which is how the floor's first run after `floor-lane.ps1 -Lane all`
# went red on a healthy build and passed on the warm re-run: the very
# cry-wolf shape the rest of this file exists to remove, moved one layer down.
$script:FloorSlowPattern = 'Waiting for Ghoztty to answer'

# The evidence is PARKED, not printed, and `Invoke-FloorBody` prints it on the
# way out. A helper called as `[void](Need ...)` has its output stream
# discarded by the caller, so a FAIL line written here would vanish exactly
# when it is needed - which is how the first cut of this file scored a red run
# with nothing in the transcript saying why.
$script:FloorSetupEvidence = @()

# Slow-but-healthy calls are parked the same way and printed by
# `Invoke-FloorBody` on EVERY exit, green runs included. A run that only got
# there because the cold-start budget absorbed a 12-second launch should say so
# - otherwise the fix in this file turns a visible red into an invisible one,
# and the next box that is slow for a REAL reason looks exactly like a fast one.
$script:FloorSetupNotes = @()

function Add-FloorSlowNote {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string[]]$GhozArgs,
        [int]$Ms
    )
    $script:FloorSetupNotes += @(
        "  NOTE SLOW SETUP: $What answered after ${Ms}ms"
        "    verb:   ghoztty $($GhozArgs -join ' ')"
        "    the CLI printed its still-waiting notice and then succeeded; this is a cold start, not a failure"
    )
}

function Add-FloorCallEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string[]]$GhozArgs,
        [Parameter(Mandatory = $true)]$Result,
        [int]$Ms
    )
    $lines = @(
        "  FAIL SETUP: $What"
        "    verb:   ghoztty $($GhozArgs -join ' ')"
    )
    $timedOut = if ($Result.TimedOut) { ' (harness timeout)' } else { '' }
    $lines += "    exit:   $($Result.ExitCode)$timedOut after ${Ms}ms"
    $streams = [ordered]@{ stdout = "$($Result.StdOut)"; stderr = "$($Result.StdErr)" }
    foreach ($name in $streams.Keys) {
        $text = ($streams[$name] -replace "`r?`n", ' | ').Trim()
        if ($text) { $lines += "    ${name}: $text" }
    }
    $script:FloorSetupEvidence = $lines
}

<#
Run a CLI call the rest of the script cannot continue without.

Returns the result on success. On failure it prints the evidence above, scores
ONE failure into $script:failures, and throws the sentinel.
#>
function Need-Ghoz {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string[]]$GhozArgs,
        [Parameter(Mandatory = $true)][string]$Exe
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs
    $ms = [int]$sw.ElapsedMilliseconds
    $said = "$($r.StdErr)$($r.StdOut)"
    $gaveUp = ($said -match $script:FloorGaveUpPattern)
    if ($r.ExitCode -ne 0 -or $r.TimedOut -or $gaveUp) {
        $why = if ($gaveUp) {
            "$What - the app under test stopped answering IPC"
        } else { $What }
        Add-FloorCallEvidence -What $why -GhozArgs $GhozArgs -Result $r -Ms $ms
        $script:failures++
        throw $script:FloorSetupFail
    }
    # T894: it worked. If it was slow enough that the CLI said so, that is
    # evidence about the BOX, recorded and carried on from.
    if ($said -match $script:FloorSlowPattern) {
        Add-FloorSlowNote -What $What -GhozArgs $GhozArgs -Ms $ms
    }
    return $r
}

<#
Parse a machine-readable answer the rest of the script cannot continue without.

Same contract as Need-Ghoz. This exists because the alternative is worse than a
cascade: `$json.data.windows | Where-Object ...` over a `$null` answer yields
`$null`, and the next line's `$p1ide.tabs[0]` fails with `Cannot index into a
null array` - an error that is neither a PASS nor a FAIL, so the assertions it
kills are not scored at all and the verdict under-counts. That is the exact
shape T894 was filed against.
#>
function Need-Parsed {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string[]]$GhozArgs,
        [Parameter(Mandatory = $true)]$Result,
        [AllowNull()]$Parsed
    )
    if ($null -ne $Parsed) { return }
    Add-FloorCallEvidence -What "$What could not be parsed" `
        -GhozArgs $GhozArgs -Result $Result -Ms 0
    $script:failures++
    throw $script:FloorSetupFail
}

<#
Assert a fixture is VISIBLE, from a `+list` text this run already polled for.
Same contract as Need-Ghoz: one evidence block, one failure, then stop.
#>
function Need-Listed {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [AllowNull()][AllowEmptyString()][string]$ListText
    )
    if ("$ListText" -match $Pattern) { return }
    $seen = ("$ListText" -replace "`r?`n", ' | ').Trim()
    $script:FloorSetupEvidence = @(
        "  FAIL SETUP: $What never appeared in +list"
        "    waited for: $Pattern"
        "    +list said: $(if ($seen) { $seen } else { '(nothing)' })"
    )
    $script:failures++
    throw $script:FloorSetupFail
}

<#
Run the acceptance body, swallowing ONLY the setup sentinel. Anything else is
re-thrown with its original error, so a real bug in a script still surfaces.
#>
function Invoke-FloorBody {
    param([Parameter(Mandatory = $true)][scriptblock]$Body)
    try { & $Body }
    catch {
        if ("$_" -ne $script:FloorSetupFail) { throw }
        $script:FloorSetupEvidence
        "  (run stopped after the setup failure above; the remaining assertions would have measured a fixture that does not exist)"
    }
    finally {
        # T894: on EVERY exit, including a green one - a cold start the budget
        # absorbed is the thing this run most needs to be able to say afterwards.
        $script:FloorSetupNotes
    }
}
