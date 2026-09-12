# ThreadJoinAudit (T702) - find the Zig test blocks that spawn a thread and can
# return before joining it.
#
# THE DEFECT, measured twice on this box (T693, then T702's own audit):
#
#     const ath = try std.Thread.spawn(.{}, InboundAgentCtx.run, .{&ictx});
#     try conn.start();          // <- any failure here returns, leaking `ath`
#     _ = try conn.waitHandshake();
#     ath.join();
#
# The spawned thread outlives the test body. It is still parked on a read into
# a MockAgent - or an Accepter, or a LinkControl - that this frame's defers are
# about to free, and it then writes its result into stack memory the NEXT test
# owns. So the failure does not report the assertion that failed: it hangs the
# lane, or panics somewhere unrelated with the 0xAAAA.. undefined-memory fill
# in the message. It only fires on a run that was ALREADY red, which is the one
# run whose output had to be readable.
#
# THE RULE, in the form this file checks:
#
#     A thread spawned inside a `test` block onto a LOCAL handle is joined on
#     every path out of that block - either because nothing between the spawn
#     and the join can return, or because a `defer`/`errdefer` in the block
#     joins it.
#
# The guard shape that satisfies it (from T693; it must DISARM, because a
# second join is UB, and it must close the transport first, because the spawned
# thread is parked on a read that nothing else unblocks):
#
#     var ath_joined = false;
#     errdefer if (!ath_joined) {
#         conn.shutdown();
#         ath.join();
#     };
#
# Findings:
#
#   * `unguarded`   - the defect above: a statement that can return sits between
#                     the spawn and the join, and no defer/errdefer joins the
#                     handle.
#   * `never-joined`- the handle is never joined in the block at all. The thread
#                     outlives the test on the SUCCESS path too.
#   * `detached`    - the handle is discarded (`_ = std.Thread.spawn(...)`), so
#                     the block cannot join it even in principle.
#   * `double-join` - a plain `defer <h>.join()` plus an explicit `<h>.join()`
#                     in the body. Both run; the second join is UB.
#   * `field-never-joined` - a spawn stored into a struct field (harness-owned,
#                     e.g. `h.thread = try std.Thread.spawn(...)`) that no
#                     function in the file ever joins.
#
# SCOPE, stated rather than implied. Only spawns lexically inside a top-level
# `test` block are judged, plus the narrow `field-never-joined` case above.
# Production spawns, and spawns in test scaffolding functions, are out: the rule
# is about a handle a TEST STACK FRAME owns, and a scaffolding struct's thread
# is joined by its own teardown, which no regex can follow. `src\apprt\win32`
# interleaves tests with production code, so "after the first test declaration"
# is not a usable proxy for "test code" and is not used as one.
#
# What it deliberately does NOT check: whether the guard closes the transport
# before joining. Which handle unblocks which thread is per-site knowledge - the
# guard at `connection.zig` calls `conn.shutdown()`, the one at `pipe_stream`
# would have to close a listener - and a rule that guessed would either miss the
# real ones or cry about correct ones. The comment above each guard states it.
#
# Exemption, narrow and stated: a `// thread-join-audit: <reason>` comment
# within the 4 lines above or 8 lines below the spawn, the same state-your-
# intent convention the PS suite's `# persistence:` / `# body-audit:` markers
# use. A reason is required; a bare marker does not exempt anything.
#
# This reads the text rather than an AST because there is no Zig parser on this
# box, and the questions it asks are line-shaped: what sits between two lines of
# one block. `zig fmt` is what makes that safe - a top-level declaration closes
# with `}` in column 0 - and `Get-ThreadJoinBlocks` fails loudly rather than
# guessing when a block does not close that way.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

# A statement that can leave the block early. `try` and `catch` are the Zig
# error paths; `return` is the explicit one. `orelse return` is matched by the
# `return` pattern already.
$script:TjaEscapePattern = '(^|[^\w.])(try|return)([^\w]|$)|\bcatch\b'

function Get-ThreadJoinBlocks {
    <#
      Top-level `test` blocks in a zig-fmt'd file, as
      @{ Start = <0-based line of `test "..." {`>; End = <0-based `}`> }.
      A test whose closing brace is not in column 0 is reported as a block with
      End = -1, so the caller can score it rather than silently skipping it.
    #>
    param([string[]]$Lines)

    $blocks = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^test\s*(\"|\{)') { continue }
        $end = -1
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            if ($Lines[$j] -eq '}') { $end = $j; break }
            # Another top-level declaration before a column-0 `}` means this
            # block never closed the way zig fmt closes one.
            if ($Lines[$j] -match '^(test\s|(pub )?fn |(pub )?const )') { break }
        }
        [void]$blocks.Add([pscustomobject]@{ Start = $i; End = $end })
        if ($end -ge 0) { $i = $end }
    }
    return $blocks
}

function Get-TjaHandle {
    <#
      The handle a spawn line binds, as @{ Name = <text to match joins on>;
      Kind = 'local' | 'array' | 'field' | 'detached' | 'unparsed' }.
    #>
    param([string]$Line)

    # const t = try std.Thread.spawn(...)   /  var os_thread = try std.Thread.spawn(
    if ($Line -match '^\s*(?:const|var)\s+([A-Za-z_]\w*)\s*(?::[^=]*)?=\s*(?:try\s+)?std\.Thread\.spawn') {
        return [pscustomobject]@{ Name = $Matches[1]; Kind = 'local' }
    }
    # threads[i] = try std.Thread.spawn(...)  /  t.* = try std.Thread.spawn(...)
    if ($Line -match '^\s*([A-Za-z_]\w*)\s*(?:\[[^\]]*\]|\.\*)\s*=\s*(?:try\s+)?std\.Thread\.spawn') {
        return [pscustomobject]@{ Name = $Matches[1]; Kind = 'array' }
    }
    # self.thread = try std.Thread.spawn(...)
    if ($Line -match '^\s*[A-Za-z_]\w*\.([A-Za-z_]\w*)\s*=\s*(?:try\s+)?std\.Thread\.spawn') {
        return [pscustomobject]@{ Name = $Matches[1]; Kind = 'field' }
    }
    # _ = std.Thread.spawn(...) catch ...
    if ($Line -match '^\s*_\s*=\s*(?:try\s+)?std\.Thread\.spawn') {
        return [pscustomobject]@{ Name = '_'; Kind = 'detached' }
    }
    return [pscustomobject]@{ Name = ''; Kind = 'unparsed' }
}

function Test-TjaWaived {
    param([string[]]$Lines, [int]$Index)

    $from = [Math]::Max(0, $Index - 4)
    $to = [Math]::Min($Lines.Count - 1, $Index + 8)
    for ($i = $from; $i -le $to; $i++) {
        # A reason is required: the marker alone waives nothing.
        if ($Lines[$i] -match '//\s*thread-join-audit:\s*\S+') { return $true }
    }
    return $false
}

function Get-TjaJoinLines {
    <#
      Lines in $Lines[$From..$To] that join $Name, as
      @{ Index = <0-based>; Deferred = $true when the join is reached through a
      defer/errdefer rather than by falling into it }.
      A join inside a defer body spans lines, so the scan carries the deferred
      state forward until the block closes at the defer's own indent.
    #>
    param([string[]]$Lines, [int]$From, [int]$To, [string]$Name)

    $out = New-Object System.Collections.ArrayList
    $deferIndent = -1
    $rx = '\b' + [regex]::Escape($Name) + '\b'
    for ($i = $From; $i -le $To; $i++) {
        $line = $Lines[$i]
        $bare = $line -replace '^\s*', ''
        $indent = $line.Length - $bare.Length

        if ($deferIndent -ge 0 -and $bare.Length -gt 0 -and $indent -le $deferIndent -and $bare -notmatch '^\}') {
            $deferIndent = -1
        }
        $isDefer = $bare -match '^(errdefer|defer)\b'
        if ($isDefer) {
            # A one-line `defer x.join();` opens nothing.
            if ($bare -match '\{\s*$' -or $bare -notmatch ';\s*$') { $deferIndent = $indent }
        }

        if ($bare -match 'join\(\)' -and $line -match $rx) {
            [void]$out.Add([pscustomobject]@{
                Index    = $i
                Deferred = ($isDefer -or $deferIndent -ge 0)
                Plain    = ($isDefer -and $bare -match '^defer\b') -or ($deferIndent -ge 0 -and $Lines[$i] -ne $null -and (Get-TjaOpenerIsPlainDefer -Lines $Lines -From $From -Upto $i))
            })
        }
    }
    return $out
}

function Get-TjaOpenerIsPlainDefer {
    # Walk back to the defer/errdefer that opened the block this join sits in.
    param([string[]]$Lines, [int]$From, [int]$Upto)
    for ($i = $Upto; $i -ge $From; $i--) {
        if ($Lines[$i] -match '^\s*(errdefer)\b') { return $false }
        if ($Lines[$i] -match '^\s*(defer)\b') { return $true }
    }
    return $false
}

function Get-ThreadJoinFindings {
    param([string]$Path)

    $findings = New-Object System.Collections.ArrayList
    $raw = Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
    if ($null -eq $raw) { return $findings }
    $lines = @($raw)
    if ($lines.Count -eq 0) { return $findings }

    $rel = $Path

    # --- spawns inside top-level test blocks -----------------------------------
    foreach ($b in @(Get-ThreadJoinBlocks -Lines $lines)) {
        if ($b.End -lt 0) {
            # Only worth reporting when the unparsed block actually spawns.
            $spawns = 0
            for ($i = $b.Start; $i -lt [Math]::Min($lines.Count, $b.Start + 400); $i++) {
                if ($lines[$i] -match 'std\.Thread\.spawn') { $spawns++ }
            }
            if ($spawns -gt 0) {
                [void]$findings.Add([pscustomobject]@{
                    Path = $rel; Line = $b.Start + 1; Kind = 'unparsed-block'; Handle = ''
                    Detail = 'a test block that spawns threads and does not close with `}` in column 0: nothing can be claimed about it'
                })
            }
            continue
        }

        for ($i = $b.Start; $i -le $b.End; $i++) {
            if ($lines[$i] -notmatch 'std\.Thread\.spawn') { continue }
            if (Test-TjaWaived -Lines $lines -Index $i) { continue }

            $h = Get-TjaHandle -Line $lines[$i]
            if ($h.Kind -eq 'field') { continue }   # harness-owned; judged below
            if ($h.Kind -eq 'unparsed') {
                [void]$findings.Add([pscustomobject]@{
                    Path = $rel; Line = $i + 1; Kind = 'unparsed'; Handle = ''
                    Detail = 'a spawn whose handle this audit cannot name: bind it to a local, or state the reason with `// thread-join-audit: <reason>`'
                })
                continue
            }
            if ($h.Kind -eq 'detached') {
                [void]$findings.Add([pscustomobject]@{
                    Path = $rel; Line = $i + 1; Kind = 'detached'; Handle = '_'
                    Detail = 'a test discards its thread handle, so the thread outlives the test body on every path'
                })
                continue
            }

            $joins = @(Get-TjaJoinLines -Lines $lines -From $i -To $b.End -Name $h.Name)
            if ($joins.Count -eq 0) {
                [void]$findings.Add([pscustomobject]@{
                    Path = $rel; Line = $i + 1; Kind = 'never-joined'; Handle = $h.Name
                    Detail = "the handle '$($h.Name)' is never joined in this test block"
                })
                continue
            }

            $deferred = @($joins | Where-Object { $_.Deferred })
            $inline = @($joins | Where-Object { -not $_.Deferred })

            # A PLAIN `defer h.join()` plus an inline join runs the join twice.
            if ($inline.Count -gt 0 -and @($deferred | Where-Object { $_.Plain }).Count -gt 0) {
                [void]$findings.Add([pscustomobject]@{
                    Path = $rel; Line = $i + 1; Kind = 'double-join'; Handle = $h.Name
                    Detail = "a plain defer of $($h.Name).join() and an explicit join both run; the second join is undefined behavior - disarm the guard with a flag and use errdefer"
                })
                continue
            }

            if ($deferred.Count -gt 0) { continue }   # guarded on every path

            # No guard: the join is only reached by falling into it, so nothing
            # between the spawn and that join may return.
            $first = ($inline | Sort-Object Index)[0].Index
            $escape = $null
            for ($k = $i + 1; $k -lt $first; $k++) {
                $bare = ($lines[$k] -replace '^\s*', '')
                if ($bare -match '^//') { continue }
                if ($bare -match $script:TjaEscapePattern) { $escape = $k; break }
            }
            if ($null -ne $escape) {
                [void]$findings.Add([pscustomobject]@{
                    Path = $rel; Line = $i + 1; Kind = 'unguarded'; Handle = $h.Name
                    Detail = "line $($escape + 1) can return between the spawn and $($h.Name).join() on line $($first + 1); add a disarming errdefer that joins it"
                })
            }
        }
    }

    # --- spawns stored into a struct field -------------------------------------
    # Narrow rule: the field has to be joined SOMEWHERE in the file. Which
    # teardown runs it is the scaffolding's business; that nothing ever joins it
    # is a defect no matter whose business it is.
    #
    # A correct teardown often CLAIMS the field into a local first and joins
    # that - `Connection.shutdown` does, and it has to, because it may not hold
    # `state_mutex` across the join - so joining a local that was read out of
    # the field counts. Without that, the one shape that gets the locking right
    # would be the only shape this rule reported.
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch 'std\.Thread\.spawn') { continue }
        $h = Get-TjaHandle -Line $lines[$i]
        if ($h.Kind -ne 'field') { continue }
        if (Test-TjaWaived -Lines $lines -Index $i) { continue }
        $names = New-Object System.Collections.ArrayList
        [void]$names.Add($h.Name)
        $claim = '^\s*(?:const|var)\s+([A-Za-z_]\w*)\s*=\s*[A-Za-z_][\w\.]*\.' + [regex]::Escape($h.Name) + '\s*;'
        # `if (self.thread) |t| t.join();` - the optional-payload capture is the
        # idiomatic claim, and it is the one every teardown in this repo uses.
        $capture = 'if\s*\(\s*[A-Za-z_][\w\.]*\.' + [regex]::Escape($h.Name) + '\s*\)\s*\|\s*\*?([A-Za-z_]\w*)\s*\|'
        foreach ($l in $lines) {
            if ($l -match $claim) { [void]$names.Add($Matches[1]) }
            elseif ($l -match $capture) { [void]$names.Add($Matches[1]) }
        }
        $joined = $false
        foreach ($n in $names) {
            $rx = '\b' + [regex]::Escape($n) + '\b[^\n]*join\(\)|join\(\)[^\n]*\b' + [regex]::Escape($n) + '\b'
            foreach ($l in $lines) { if ($l -match $rx) { $joined = $true; break } }
            if ($joined) { break }
        }
        if (-not $joined) {
            [void]$findings.Add([pscustomobject]@{
                Path = $rel; Line = $i + 1; Kind = 'field-never-joined'; Handle = $h.Name
                Detail = "a thread spawned into the .$($h.Name) field that no function in this file joins"
            })
        }
    }

    return $findings
}

# Every kind here is the defect; there is no reported-but-not-enforced kind.
# What holds the not-yet-fixed files is the BASELINE, not a softer kind list -
# a count per file that may only ever go down. See the harness.
function Get-ThreadJoinHardKinds {
    return @('unguarded', 'never-joined', 'detached', 'double-join', 'field-never-joined', 'unparsed', 'unparsed-block')
}

function Get-ThreadJoinSweep {
    <# Every .zig file under $Root, recursively. #>
    param([string]$Root)

    $all = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Filter *.zig -File -Recurse)) {
        foreach ($x in @(Get-ThreadJoinFindings -Path $f.FullName)) { [void]$all.Add($x) }
    }
    return $all
}

function Get-ThreadJoinRelativePath {
    param([string]$Path, [string]$Repo)
    $p = $Path
    if ($p.StartsWith($Repo, [StringComparison]::OrdinalIgnoreCase)) {
        $p = $p.Substring($Repo.Length).TrimStart('\', '/')
    }
    return ($p -replace '/', '\')
}
