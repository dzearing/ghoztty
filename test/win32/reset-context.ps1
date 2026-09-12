# T133 acceptance: the /reset-context helper's composer wipe and its
# verify-or-shout behavior (dzearing-skills plugin, scripts/reset-context.sh).
#
# This is the loop's own continuation mechanism, and it has failed twice by
# silently no-opping (2026-07-28: a stray "nn" in the composer turned the
# submit into the ordinary message "nn/clear", so nothing was cleared and the
# loop stalled). The helper now (a) kills the input line with C-u before
# typing, and (b) reads the pane back to VERIFY both the clear and the
# continuation, shouting into its log AND onto a pane banner when either
# fails. Both are validated here against a pane that models a Claude Code
# composer closely enough to reproduce the original defect:
#
#   proxy-normal   readline input (so C-u is really unix-line-discard, as in
#                  the composer), clears screen+scrollback on the EXACT line
#                  "/clear" and echoes anything else as RC-TEXT[...] - so
#                  "nn/clear" is text and "/clear" is a command, exactly the
#                  distinction the defect fell through.
#   proxy-amnesia  same, but keeps clearing the screen after the clear, so
#                  the continuation lands and then vanishes - a session that
#                  cleared but ate the prompt (the T132-class stall).
#   proxy-clearwedge  a composer that TAKES "/clear" and swallows the CR, so
#                  the pane sits at a full composer that never ran the command
#                  (T1502). It paints the real composer marker, '>' + U+00A0.
#   proxy-working  what a session that ACCEPTS the prompt looks like: no echo
#                  at all, then a spinner repainting for 15s. The only
#                  on-screen evidence of delivery is the paint (T182/T261),
#                  and every line it receives is logged to a file OUTSIDE the
#                  pane so a success verdict can be checked against the truth.
#
# Sections:
#   A  fixed helper + a stray "nn" pre-typed -> the pane receives "/clear"
#        (not "nn/clear"), the log says it verified the clear AND the
#        continuation, and NO banner is set (no false alarm).
#   B  negative control: the same run with the C-u line deleted from the
#        helper -> the pane receives "nn/clear" verbatim (the filed symptom,
#        reproduced) and the continuation is STILL sent (liveness beats
#        cleanliness). It does NOT shout: a "/clear" submitted as ordinary text
#        leaves the composer empty, and the composer is what the clear gate
#        reads. Sections K-M carry the loud half, against the pane that really
#        produces it.
#        Carries a receipt oracle since T483:
#        this section once flaked with the continuation missing from the
#        screen, and only an out-of-band receipt can attribute a recurrence
#        (input never arrived vs the pane lost the echo).
#   C  a session that clears and then swallows the prompt -> the clear
#        verifies, the CONTINUATION check fails loudly, banner set.
#   D  durability: the active plugin cache carries the wipe AND the repaint
#        acceptance, and the source repo copy is byte-identical to it with a
#        bumped plugin version (T130's lesson: a plugin release silently
#        reverted a cache-only fix).
#   E  T182: a pane that ACCEPTED the continuation and is working on it is
#        verified as a success - the repaint is the proof - with no failure
#        in the log and no banner. An out-of-band receipt file proves the
#        continuation really arrived, so the verdict is right and not lucky.
#   F  negative control for E: the same pane driven by a helper copy with the
#        repaint branch cut out shouts FAILED over that same delivery, which
#        is the bug as filed. E only means something because F still fails.
#   G  T562: a composer that takes the text and swallows the CR - the
#        2026-08-07 stall, where the loop sat all night at a full composer
#        while "verified: continuation is on screen" was written over it. The
#        gate must NAME that state and press Enter itself; a receipt file
#        outside the pane proves the prompt really ran.
#   H  negative control for G: the same wedge with the keypress cut out stays
#        wedged and shouts - so G measures the press, not the detection.
#   I  T699: a handoff delivered MINUS ITS FIRST CHARACTER. Every pre-T699
#        check passes over it - the basename probe sits in the middle of the
#        sentence and the pane moves - and only the integrity verdict says
#        CORRUPTED. Both halves are asserted, so the section measures the
#        blindness as well as the cure.
#   J  the same, with a byte dropped from the PATH instead: the basename (and
#        therefore the probe) is untouched, while the fresh session would have
#        nothing to read.
#   K  T1502: a composer that takes "/clear" and swallows the CR that came
#        with it. The gate must find the composer by its MEASURED marker, name
#        the wedge, press Enter, and an out-of-band receipt must show the clear
#        really ran - not merely that the screen looked cleared.
#   L  the same wedge, permanent: three Enters and it is still sitting there,
#        so it is shouted and bannered, and the continuation goes out anyway.
#   M  negative control for K/L: the same pane driven by a helper whose
#        composer marker is a glyph no pane prints - the state of the gate from
#        2026-08-25 to 2026-09-12. It reports "verified: /clear landed" over a
#        session that cleared nothing, which is the defect as filed.
#
# Oracles are the pane's own output (+read), the helper's log
# (/tmp/reset-context-last.log), and the banner in +list --json.
#
# T664: every section that delivers a handoff now also checks it arrived
# WHOLE, not merely that the cont file's basename showed up somewhere. One run
# in five once put `RC-TEXT[ontinue-marker-B]` on section B's screen - a text
# run missing its FIRST character - and a basename needle in the middle of the
# sentence is found either way, so the loss was caught by eye and nothing
# failed. Receipt sections (B/E/F/G) compare the whole sentence byte for byte;
# screen sections (A/B) require it to still begin with "Read ", which is the
# shape that was reported. The same shape is measured on the WIRE, where a
# truncation can be attributed rather than guessed at, by rounds 13-14 of
# test\win32\send-keys-bracketed.ps1. Re-run with GHOZTTY_TEST_T664_BREAK=1 to
# make those five arms go red and nothing else move (their teeth check).
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [string]$HelperPath)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bash)) {
    Write-Host 'SKIP: git-bash not found - the helper is a bash script, nothing to test' -ForegroundColor Yellow
    exit 1
}

# The helper under test: the ACTIVE plugin cache copy by default (what the
# box really runs), overridable with -HelperPath.
$cacheRoot = Join-Path $env:USERPROFILE '.claude\plugins\cache\dzearing-claude-marketplace\dzearing-skills'
$cacheHelper = $null
if (Test-Path $cacheRoot) {
    $cacheHelper = Get-ChildItem $cacheRoot -Directory |
        Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0' } } |
        ForEach-Object { Join-Path $_.FullName 'skills\reset-context\scripts\reset-context.sh' } |
        Where-Object { Test-Path $_ } | Select-Object -Last 1
}
$helper = if ($HelperPath) { $HelperPath } else { $cacheHelper }
if (-not $helper -or -not (Test-Path $helper)) {
    Write-Host 'SKIP: reset-context.sh not found (plugin not installed?)' -ForegroundColor Yellow
    exit 1
}
Write-Host "helper: $helper"

# ---- scratch dir, proxies, and the pre-fix helper copy -------------------
$work = Join-Path $env:TEMP 'ghoztty-rc-test'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
function Write-Sh([string]$path, [string]$text) {
    # LF endings, ASCII, no BOM: a BOM would land in front of the shebang.
    [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"), (New-Object System.Text.ASCIIEncoding))
}
Write-Sh (Join-Path $work 'proxy-normal.sh') @'
#!/bin/bash
# Composer model: readline editing (C-u = unix-line-discard), the EXACT line
# "/clear" is a command that clears screen and scrollback, anything else is
# ordinary text that gets echoed back.
# $1 (optional): a receipt file every SUBMITTED line is appended to - an
# oracle OUTSIDE the pane, so a T483-class miss can be attributed: a line in
# the receipt but not on screen is a display/read-side loss, a line in
# neither never reached the shell at all.
# The prompt carries the REAL composer marker (T1502): '>' followed by U+00A0,
# which is what a live Claude Code composer draws and what the helper's clear
# gate anchors on. Measured with +read against v2.1.266 and v2.1.269 panes on
# 2026-09-12 - exactly one occurrence per 40-line dump, on the composer row,
# while the transcript's echo of an already-run command uses an ordinary
# space. Written with printf rather than as a literal because Write-Sh emits
# ASCII, and a proxy without the marker would exercise the helper's fallback
# instead of the check under test.
R="$1"
RCP="rc>$(printf '\302\240')"
while IFS= read -r -e -p "$RCP" l; do
  [ -n "$R" ] && printf '%s\n' "$l" >> "$R"
  if [ "$l" = "/clear" ]; then printf '\033[2J\033[3J\033[H'; echo "RC-CLEARED"
  else echo "RC-TEXT[$l]"; fi
done
'@
Write-Sh (Join-Path $work 'proxy-amnesia.sh') @'
#!/bin/bash
# Same, but every line AFTER the clear also wipes the screen: a session that
# accepted /clear and then ate whatever was typed into it.
S=0
RCP="rc>$(printf '\302\240')"
while IFS= read -r -e -p "$RCP" l; do
  if [ "$l" = "/clear" ] || [ "$S" = "1" ]; then S=1; printf '\033[2J\033[3J\033[H'
  else echo "RC-TEXT[$l]"; fi
done
'@
Write-Sh (Join-Path $work 'proxy-clearwedge.sh') @'
#!/bin/bash
# T1502: a composer that TAKES "/clear" and SWALLOWS the CR that arrived with
# it. This is the state the clear gate exists to catch, and the state it was
# blind to from 2026-08-25 (when the gate started grepping for a prompt glyph
# no pane prints) until 2026-09-12.
#
# Echo is off and every character is painted by hand behind the same prompt
# marker a real Claude Code composer draws - '>' + U+00A0 - so the pane holding
# an unsubmitted "/clear" is STATIC and looks to +read exactly like the real
# one does.
#
# $1 receipt file: every SUBMITTED line, out of band, so "the clear really ran"
# can be told from "the screen looked like it did".
# $2 how many CRs to swallow after "/clear" (default 1 = one Enter recovers it;
# a large number = permanently wedged, which must be shouted about).
R="${1:-$(dirname "$0")/received.txt}"
SWALLOW="${2:-1}"
NB=$(printf '\302\240')
stty -echo 2>/dev/null
printf 'rc-ready\n'
BUF=''
prompt(){ printf '\r\033[K>%s%s' "$NB" "$BUF"; }
prompt
while IFS= read -r -N1 c; do
  case "$c" in
    $'\r'|$'\n')
      if [ "$BUF" = "/clear" ] && [ "$SWALLOW" -gt 0 ]; then
        SWALLOW=$((SWALLOW - 1)); continue
      fi
      [ -z "$BUF" ] && continue
      printf '%s\n' "$BUF" >> "$R"
      if [ "$BUF" = "/clear" ]; then
        printf '\033[2J\033[3J\033[H'; printf 'RC-CLEARED\n'; BUF=''; prompt; continue
      fi
      BUF=''
      # A submitted continuation makes the pane WORK, the way proxy-working
      # does: otherwise the motion gate below the clear gate would fail this
      # pane for its own reasons and the section could not assert a clean run.
      i=0
      while [ "$i" -lt 15 ]; do i=$((i + 1)); printf '\r  * Working... (%ss)  ' "$i"; sleep 1; done
      printf '\n'; prompt
      ;;
    $'\025') BUF=''; prompt ;;
    *) BUF="$BUF$c"; printf '%s' "$c" ;;
  esac
done
'@
Write-Sh (Join-Path $work 'proxy-working.sh') @'
#!/bin/bash
# The T182 case, modelled on what the real Claude Code TUI does with a prompt
# it ACCEPTS: nothing is echoed back, and the session immediately starts
# working, repainting a spinner. The text a naive verifier searches for is
# destroyed by the very success it is trying to confirm -- so the ONLY on-screen
# evidence of delivery is that the pane is painting.
#
# Echo is off (and the read is a plain one, so no readline echo either),
# which makes that deterministic rather than a race against the repaint.
# Every submitted line is appended to $1: an oracle OUTSIDE the pane, so the
# test can tell "the verifier was right" from "the verifier got lucky".
R="${1:-$(dirname "$0")/received.txt}"
stty -echo 2>/dev/null
printf 'rc-ready\n'
while IFS= read -r l; do
  l="${l%$'\r'}"
  [ -z "$l" ] && continue
  if [ "$l" = "/clear" ]; then printf '\033[2J\033[3J\033[H'; printf 'RC-CLEARED\n'; continue; fi
  printf '%s\n' "$l" >> "$R"
  i=0
  while [ "$i" -lt 15 ]; do i=$((i + 1)); printf '\r  * Working... (%ss)  ' "$i"; sleep 1; done
  printf '\n'
done
'@
Write-Sh (Join-Path $work 'proxy-swallow.sh') @'
#!/bin/bash
# The T562 wedge, modelled: a composer that TAKES the continuation, DISPLAYS
# it, and swallows the CR that arrived with it. That is exactly what the loop
# pane looked like on 2026-08-07 -- freshly cleared session, prompt intact in
# the composer, never submitted -- and the cure the user applied by hand was a
# single standalone Enter, which this proxy accepts. Before the clear it
# behaves normally, so the helper's /clear path is unaffected.
#
# Echo is off and every character is painted by hand, so the pane holding an
# unsubmitted prompt is STATIC: motion is what distinguishes it from a session
# that took the prompt, which is the whole point of the gate under test.
# Submitted lines are appended to $1 -- an oracle OUTSIDE the pane, so
# "recovered" can be told apart from "looked recovered".
R="${1:-$(dirname "$0")/received.txt}"
stty -echo 2>/dev/null
printf 'rc-ready\n'
BUF=''
CLEARED=0
SWALLOWED=0
while IFS= read -r -N1 c; do
  case "$c" in
    $'\r'|$'\n')
      if [ "$CLEARED" = 0 ]; then
        if [ "$BUF" = "/clear" ]; then printf '\033[2J\033[3J\033[H'; printf 'RC-CLEARED\n'; CLEARED=1; fi
        BUF=''
      elif [ -n "$BUF" ] && [ "$SWALLOWED" = 0 ]; then
        SWALLOWED=1
      elif [ -n "$BUF" ]; then
        printf '%s\n' "$BUF" >> "$R"
        BUF=''; SWALLOWED=0
        i=0
        while [ "$i" -lt 15 ]; do i=$((i + 1)); printf '\r  * Working... (%ss)  ' "$i"; sleep 1; done
        printf '\n'
      fi
      ;;
    $'\025') BUF=''; printf '\r\033[K' ;;
    *) BUF="$BUF$c"; printf '%s' "$c" ;;
  esac
done
'@

function To-Unix([string]$p) { (& $bash -lc "cygpath -u '$($p -replace "'", "''")'").Trim() }
$helperU = To-Unix $helper
$prefixU = To-Unix (Join-Path $work 'reset-context-prefix.sh')
# Negative control built with sed, not PowerShell: the helper carries UTF-8
# comments and a backslash-sensitive sed expression, and rewriting it through
# PowerShell would mangle both.
& $bash -lc "sed '/--when-idle C-u/d' '$helperU' > '$prefixU'" | Out-Null
$prefixWin = Join-Path $work 'reset-context-prefix.sh'
if ((Get-Content $prefixWin | Select-String -SimpleMatch '--when-idle C-u')) {
    Write-Host 'SETUP FAIL: pre-fix copy still has the C-u line'; exit 1
}
# Second negative control (T182): the helper with the T261 repaint branch cut
# out, i.e. the version that only ever believed an echoed prompt. Section F
# runs it against the SAME pane section E passes on, so the run proves the fix
# is load-bearing rather than merely present. The sed program goes in a file:
# it matches "$cur"/"$prev", which PowerShell would expand inside a "..." arg.
Write-Sh (Join-Path $work 'drop-repaint.sed') @'
/verdict="pane is repainting/d
'@
$norepaintWin = Join-Path $work 'reset-context-norepaint.sh'
$sedU = To-Unix (Join-Path $work 'drop-repaint.sed')
$norepaintU = To-Unix $norepaintWin
& $bash -lc "sed -f '$sedU' '$helperU' > '$norepaintU'" | Out-Null
$nrText = Get-Content $norepaintWin -Raw
# Match the ASSIGNMENT, not the phrase: the helper's comments explain the
# repaint branch too, so a bare 'pane is repainting' is true of a copy that
# no longer has it.
if ($nrText -match 'verdict="pane is repainting') {
    Write-Host 'SETUP FAIL: pre-T261 copy still has the repaint branch'; exit 1
}
if ($nrText -notmatch 'handoff is on screen') {
    Write-Host 'SETUP FAIL: pre-T261 copy lost the echoed-prompt branch too'; exit 1
}
# Third negative control (T562): the helper with the submission GATE's keypress
# cut out - it still notices the wedge, it just never presses Enter. Section H
# runs it against the same pane section G recovers, so G proves the press is
# load-bearing rather than merely present.
Write-Sh (Join-Path $work 'drop-submit.sed') @'
/pressing Enter (attempt/,+1d
'@
$noretryWin = Join-Path $work 'reset-context-noretry.sh'
$dropSubmitU = To-Unix (Join-Path $work 'drop-submit.sed')
$noretryU = To-Unix $noretryWin
& $bash -lc "sed -f '$dropSubmitU' '$helperU' > '$noretryU'" | Out-Null
$nsText = Get-Content $noretryWin -Raw
if ($nsText -match 'pressing Enter \(attempt') {
    Write-Host 'SETUP FAIL: pre-T562 copy still presses Enter'; exit 1
}
if ($nsText -notmatch 'TYPED BUT NOT SUBMITTED') {
    Write-Host 'SETUP FAIL: pre-T562 copy lost the wedge verdict too'; exit 1
}
# Fourth negative control (T1502): the helper with its MEASURED composer marker
# swapped for a glyph the pane never prints - which is what the gate really
# looked for between 2026-08-25 and 2026-09-12, and why it reported
# "verified: /clear landed" over panes that had cleared nothing. The whole
# marker block (and the fallback that now backs it) is replaced by the original
# four-line function, so section M measures the SIGNATURE rather than the
# plumbing around it. The sentinel is ASCII on purpose: Write-Sh emits ASCII,
# and U+276F itself would not survive the file.
Write-Sh (Join-Path $work 'drop-marker.sed') @'
/^NBSP=/,/^attempt=0$/c\
composer_holds_clear(){\
  ghoztty +read --name="$P" --lines=40 2>/dev/null \\\
    | grep '^ZZ-A-GLYPH-NO-PANE-EVER-PRINTS' | tail -1 | grep -qF "/clear"\
}\
attempt=0
'@
$blindWin = Join-Path $work 'reset-context-blind.sh'
$dropMarkerU = To-Unix (Join-Path $work 'drop-marker.sed')
$blindU = To-Unix $blindWin
& $bash -lc "sed -f '$dropMarkerU' '$helperU' > '$blindU'" | Out-Null
$blText = Get-Content $blindWin -Raw
if ($blText -match '(?m)^NBSP=') {
    Write-Host 'SETUP FAIL: pre-T1502 copy still carries the measured marker'; exit 1
}
if ($blText -notmatch 'ZZ-A-GLYPH-NO-PANE-EVER-PRINTS') {
    Write-Host 'SETUP FAIL: pre-T1502 copy did not get the blind glyph'; exit 1
}
if ($blText -notmatch 'is still in the composer after') {
    Write-Host 'SETUP FAIL: pre-T1502 copy lost the clear verdict too'; exit 1
}
$logWin = Join-Path (& $bash -lc 'cygpath -w /tmp' | ForEach-Object { $_.Trim() }) 'reset-context-last.log'

# ---- instance ------------------------------------------------------------
function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}
# The helper calls bare `ghoztty`, so zig-out goes FIRST on PATH, and the
# inherited GHOZTTY_IPC_SOCKET is cleared: this session's pane bakes the
# RELEASE app's socket, and a helper that picked it up would type /clear into
# the user's own window instead of the test instance.
$env:PATH = (Join-Path $repo 'zig-out\bin') + ';' + $env:PATH
$env:GHOZTTY_IPC_SOCKET = ''

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}
function All-Leaves {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return @() }
    $out = @()
    foreach ($w in ($json | ConvertFrom-Json).data.windows) {
        foreach ($t in $w.tabs) { $out += @(Get-Leaves $t.splits | ForEach-Object { $_ | Add-Member -NotePropertyName winTarget -NotePropertyValue $w.target -PassThru -Force }) }
    }
    return $out
}
function Pane-Of([string]$winTarget) {
    foreach ($l in All-Leaves) { if ($l.winTarget -eq $winTarget) { return $l.id } }
    return $null
}
function Banner-Of([string]$paneId) {
    foreach ($l in All-Leaves) { if ($l.id -eq $paneId) { return $l.banner } }
    return $null
}
function Tail([string]$paneId, [int]$lines = 40) {
    # A pane that exists in +list can still be a moment away from readable
    # (the window is up before its terminal attaches), and in PS 5.1 a native
    # command's stderr is an ErrorRecord that would terminate the run under
    # $ErrorActionPreference='Stop'. Poll, don't die.
    # An EMPTY read is always transient here (every proxy pane at least shows
    # its "rc>" prompt), and a swallowed one would read exactly like a product
    # verdict - "the text never arrived" - so retry before believing it.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = ''
    for ($t = 0; $t -lt 15 -and -not $out; $t++) {
        try { $out = (& $exe +read --name=$paneId --lines=$lines 2>$null | Out-String) } catch { $out = '' }
        if (-not $out) { Start-Sleep -Milliseconds 200 }
    }
    $ErrorActionPreference = $old
    if (-not $out) { return '' }
    return $out
}
function Wait-Tail([string]$paneId, [string]$needle, [int]$secs = 10) {
    for ($t = 0; $t -lt ($secs * 5); $t++) {
        if ((Tail $paneId).Contains($needle)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
function New-ProxyWindow([string]$target, [string]$proxy, [string]$proxyArg = '', [string]$ready = 'rc>', [string]$proxyArg2 = '') {
    $u = To-Unix (Join-Path $work $proxy)
    $cmd = if ($proxyArg2) { "bash $u '$proxyArg' '$proxyArg2'" }
           elseif ($proxyArg) { "bash $u '$proxyArg'" }
           else { "bash $u" }
    # T1241: through the test desktop. `+new-window` is the one verb that
    # auto-launches, and the window it opens lands on the desktop of whoever
    # ran the CLI - so on the user's screen, every time this helper was called.
    [void](Invoke-OnTestDesktop -Exe $exe `
        -Arguments @('+new-window', "--target=$target", "--shell=$bash", "--command=$cmd"))
    $pane = $null
    for ($t = 0; $t -lt 40 -and -not $pane; $t++) { $pane = Pane-Of $target; if (-not $pane) { Start-Sleep -Milliseconds 250 } }
    if (-not $pane) { Write-Host "SETUP FAIL: no pane for $target"; exit 1 }
    if (-not (Wait-Tail $pane $ready 15)) { Write-Host "SETUP FAIL: proxy prompt never appeared in $target"; exit 1 }
    return $pane
}
function Run-Helper([string]$script, [string]$paneId, [string]$contText, [string]$break = '') {
    $cont = Join-Path $work ("cont-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    [IO.File]::WriteAllText($cont, $contText + "`n", (New-Object System.Text.ASCIIEncoding))
    $su = To-Unix $script
    $cu = To-Unix $cont
    # T699: $break ('lead' / 'path') tells the helper to CORRUPT the handoff it
    # types, which is the negative control for its integrity verdict. Empty in
    # every other section, and nothing outside this harness ever sets it.
    $envp = if ($break) { "GHOZTTY_TEST_T699_BREAK=$break " } else { '' }
    & $bash -lc "${envp}bash '$su' '$paneId' '$cu'" | Out-Null
    # The helper hands the continuation over BY REFERENCE - the pane only ever
    # receives "Read <path> - it contains your instructions...", never the prose
    # - so the cont file's basename, not the marker inside it, is what any
    # oracle looking at the pane can check.
    # The exact sentence the helper types, rebuilt here from the same pieces it
    # builds it from (T664). The basename probe alone cannot see a TRUNCATED
    # handoff: one run in five once showed section B's pane receiving a text run
    # with its first character gone, and a needle in the middle of the sentence
    # is found either way. Sections with an out-of-band receipt compare the
    # WHOLE sentence against this; screen sections check that it still begins
    # with "Read ", which is the shape that was reported.
    $mixed = (& $bash -lc "cygpath -m '$($cont -replace "'", "''")'").Trim()
    $sentence = "Read $mixed - it contains your instructions for this session. Follow them."
    # Teeth check, on demand: with GHOZTTY_TEST_T664_BREAK=1 the arms below
    # expect the sentence MINUS its first character - the exact loss they exist
    # to catch - so every T664 arm goes red against a healthy delivery and
    # nothing else moves. An arm that cannot be made to fail is decoration.
    if ($env:GHOZTTY_TEST_T664_BREAK -eq '1') { $sentence = $sentence.Substring(1) }
    return @{
        log      = (Get-Content $logWin -Raw -ErrorAction SilentlyContinue)
        cont     = $cont
        probe    = (Split-Path $cont -Leaf)
        sentence = $sentence
    }
}

Kill-RepoInstances

# T441: this run's own IPC endpoint, before any `& $exe` call. This script
# drives a helper that TYPES `/clear` and a continuation into a pane — pointed
# at the user's installed release by an inherited `$GHOZTTY_IPC_SOCKET` it
# would clear a live Claude session.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
# T1241: the GUI and every +new-window below run on the background test desktop.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
[void](Set-GhozttyTestIsolation -Tag 'resetctx')
Assert-GhozttyPrivateEndpoint -Exe $exe

$td = New-TestDesktop
$app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
$proc = $app.Process
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; Remove-TestDesktop | Out-Null; exit 1 }
Assert-GhozttyIsolated -Exe $exe

try {
    # --- A. fixed helper wipes the composer, verifies both sends ----------
    $p1 = New-ProxyWindow 'rc1' 'proxy-normal.sh'
    & $exe +send-keys --target=$p1 'nn' | Out-Null   # the stray characters
    Start-Sleep -Milliseconds 800
    $r = Run-Helper $helper $p1 'continue-marker-A'
    $t1 = Tail $p1
    Assert ($t1.Contains('RC-CLEARED')) 'A1 pane ran the bare /clear command (stray input was wiped)'
    Assert (-not $t1.Contains('RC-TEXT[nn/clear]')) 'A2 no "nn/clear" arrived as ordinary text'
    Assert ($r.log -match 'cleared input line rc=0') 'A3 log records the composer wipe'
    Assert ($r.log -match 'verified: /clear landed') 'A4 log records the VERIFIED clear'
    Assert (Wait-Tail $p1 "RC-TEXT[Read " 10) 'A5 the handoff sentence was typed into the fresh session'
    Assert (Wait-Tail $p1 $r.probe 10) 'A5b naming the cont file the session must read'
    Assert ($r.log -match 'verified: handoff is on screen') 'A6 log records the VERIFIED continuation'
    # T699: the integrity verdict, on a pane that SOFT-WRAPS the ~110-character
    # sentence - so this is also the measurement that the check survives a real
    # wrapped delivery rather than assuming the line comes back whole.
    Assert ($r.log -match 'verified: the handoff arrived INTACT') 'A6b and that it arrived WHOLE, path and all (T699)'
    Assert ($r.log -notmatch 'RESET-CONTEXT FAILED') 'A7 no failure shouted on the happy path'
    $b1 = Banner-Of $p1
    Assert ([string]::IsNullOrEmpty($b1)) "A8 no banner set on the happy path (got '$b1')"
    # Deliberately NOT deleted: the fresh session reads it after the helper has
    # already exited, so cleaning up here would race the reader.
    Assert (Test-Path $r.cont) 'A9 the cont file survives for the session to read'

    # --- B. negative control: the C-u line deleted ------------------------
    # This section carries a receipt oracle (T483): it flaked 1-in-3 on
    # 2026-08-05 with the continuation missing from the screen, and a screen
    # read alone cannot say whether the bytes never reached the shell or the
    # pane lost the echo. T664 then measured the write path byte-exact (315
    # deliveries, zero losses) and the 08-09/08-10 send-keys overhaul
    # (T604/T661/T428 framing) replaced the delivery this section flaked on;
    # if it ever recurs, the receipt is what tells the two apart.
    $recvB = Join-Path $work 'received-B.txt'
    $p2 = New-ProxyWindow 'rc2' 'proxy-normal.sh' (To-Unix $recvB)
    & $exe +send-keys --target=$p2 'nn' | Out-Null
    Start-Sleep -Milliseconds 800
    $r = Run-Helper $prefixWin $p2 'continue-marker-B'
    $t2 = Tail $p2
    Assert ($t2.Contains('RC-TEXT[nn/clear]')) 'B1 pre-fix: "nn/clear" arrives as ordinary text (filed symptom)'
    Assert (-not $t2.Contains('RC-CLEARED')) 'B2 pre-fix: the session was never cleared'
    # The receipt must be proven LIVE in every run, or its silence at a future
    # B7 failure would read as "input lost" over a receipt that never worked.
    $gotB = [string](Get-Content $recvB -Raw -ErrorAction SilentlyContinue)
    Assert ((($gotB -split "`r?`n") -contains 'nn/clear')) 'B2b receipt oracle is live (the failed clear was recorded out-of-band)'
    # B3-B6 USED to live here: the helper shouted RESET-CONTEXT FAILED over this
    # very pane, named the clear as the failing step, carried the pane tail as
    # evidence, and bannered it. They were REMOVED on 2026-09-12 (T699's run)
    # because the helper no longer has that contract, not because they were
    # noisy. The 2026-08-25 change replaced the whole-screen `grep "/clear"` -
    # which cried wolf on every healthy run, since Claude Code echoes the
    # command it just ran into the fresh transcript - with a check on the
    # COMPOSER, and a submitted-as-ordinary-text "/clear" leaves the composer
    # empty, so this shape is invisible to it by design.
    #
    # What was NOT by design, and is why nothing replaced them in the same
    # breath: that composer check greped for a prompt glyph a real Claude Code
    # pane never prints (zero occurrences in a 400-line +read, measured
    # 2026-09-12), so it reported `verified: /clear landed` unconditionally -
    # including over this pane, which B2 has just proved was never cleared.
    # T1502 measured the marker a live composer really draws ('>' + U+00A0) and
    # put the loud arms where the state that produces them actually lives:
    # sections K (a recoverable wedge), L (a permanent one, shouted and
    # bannered) and M (the blind gate, still calling it a clean clear). This
    # section stays quiet, and now on purpose rather than by accident.
    #
    # The C-u wipe itself is still proven load-bearing by B1/B2 above: without
    # it the filed symptom reproduces exactly.
    # Seen to fail intermittently (T483). The shared helper log is overwritten
    # by the sections after this one, so print the evidence AT the failure or
    # it is gone by the time anyone reads the run.
    $b7 = Wait-Tail $p2 $r.probe 10
    if (-not $b7) {
        Write-Host '      B7 diag: helper log ->' -ForegroundColor Yellow
        ($r.log -split "`r?`n") | Where-Object { $_ -match 'continuation|send-keys|typed' } | ForEach-Object { Write-Host "        $_" }
        Write-Host ('      B7 diag: pane tail -> ' + ((Tail $p2) -replace "`r?`n", ' | ')) -ForegroundColor Yellow
        # The attribution line (T483): sentence in the receipt = the shell got
        # and submitted it, so the loss is display/read-side; absent = the
        # bytes never made it through (or were typed and never submitted -
        # then the pane tail above shows them sitting in the composer).
        Write-Host ('      B7 diag: receipt -> ' + ((Get-Content $recvB -Raw -ErrorAction SilentlyContinue) -replace "`r?`n", ' | ')) -ForegroundColor Yellow
    }
    Assert $b7 'B7 continuation still sent despite the failure'
    # T664: the section that flaked. A lost leading character left the basename
    # intact, so B7 passed over `RC-TEXT[ead C:/...]` and the loss was noticed
    # only by eye. The sentence's own first word is the assertion that sees it.
    # The screen wraps a ~110-character sentence, so this checks where the line
    # STARTS rather than comparing the whole of it: the echo must open with the
    # sentence's own first word, which a dropped leading byte destroys.
    Assert ((Tail $p2).Contains('RC-TEXT[' + $r.sentence.Substring(0, 5))) `
        'B7b the handoff arrived whole, not missing its first character'
    # The receipt holds the submitted LINE, so B gets the same byte-for-byte
    # equality arm the receipt sections have - `Contains` on the screen can
    # never see a dropped leading byte (T664), but the receipt can.
    $gotB = ''
    for ($t = 0; $t -lt 25 -and -not (($gotB -split "`r?`n") -contains $r.sentence); $t++) {
        $gotB = [string](Get-Content $recvB -Raw -ErrorAction SilentlyContinue); Start-Sleep -Milliseconds 200
    }
    Assert ((($gotB -split "`r?`n") -contains $r.sentence)) 'B7c and the receipt holds it byte for byte (T664)'

    # --- C. cleared, then the prompt was eaten ----------------------------
    $p3 = New-ProxyWindow 'rc3' 'proxy-amnesia.sh'
    $r = Run-Helper $helper $p3 'continue-marker-C'
    Assert ($r.log -match 'verified: /clear landed') 'C1 the clear itself verified'
    # A silent, unchanging pane is the ONLY thing that still fails: no echo of
    # the prompt and no repaint. The wording moved with T261, so match the
    # thing the verdict is about, not the sentence it used to be phrased in.
    Assert ($r.log -match 'never echoed the handoff and did not repaint') 'C2 the missing continuation is caught'
    Assert ($r.log -match 'RESET-CONTEXT FAILED') 'C3 and shouted'
    $b3 = Banner-Of $p3
    Assert ($b3 -and $b3 -match 'reset-context FAILED') "C4 banner tells the user (got '$b3')"

    # --- E. the prompt was ACCEPTED and the session is working (T182) ------
    # The case that used to false-FAIL on every good reset: submitting empties
    # the composer, so the text the check searched for is gone within a second
    # and the pane shows a working session instead. Nothing is broken here, so
    # nothing may be shouted.
    $recvE = Join-Path $work 'received-E.txt'
    $p4 = New-ProxyWindow 'rc4' 'proxy-working.sh' (To-Unix $recvE) 'rc-ready'
    $r = Run-Helper $helper $p4 'continue-marker-E'
    Assert ($r.log -match 'verified: /clear landed') 'E1 the clear verified against a non-echoing pane'
    Assert (Wait-Tail $p4 'Working...' 10) 'E2 the pane is visibly working on the continuation'
    # The out-of-band oracle: the continuation really did arrive, so a success
    # verdict here is CORRECT rather than lucky.
    # [string] because the receipt file does not exist until the pane writes it,
    # and a $null from Get-Content would make the NEXT .Contains() throw.
    $gotE = ''
    for ($t = 0; $t -lt 25 -and -not $gotE.Contains($r.probe); $t++) {
        $gotE = [string](Get-Content $recvE -Raw -ErrorAction SilentlyContinue); Start-Sleep -Milliseconds 200
    }
    Assert ($gotE -and $gotE.Contains($r.probe)) 'E3 the pane really received the handoff'
    # T664: the receipt is the submitted line itself, so compare it as a whole
    # LINE - `Contains` cannot see a dropped leading byte, because the truncated
    # sentence is still a substring of the intact one.
    Assert ((($gotE -split "`r?`n") -contains $r.sentence)) 'E3b every byte of the handoff arrived, not just the file name'
    Assert ($r.log -match 'verified: pane is repainting') 'E4 delivery verified by the repaint, not by the vanished echo'
    Assert ($r.log -notmatch 'RESET-CONTEXT FAILED') 'E5 no failure shouted over a session that is answering'
    $b4 = Banner-Of $p4
    Assert ([string]::IsNullOrEmpty($b4)) "E6 no recover-by-hand banner painted over it (got '$b4')"

    # --- F. negative control: the same pane, minus the T261 repaint branch --
    # Proves E is load-bearing: cut the branch out and this exact success is
    # reported as a failure again, which is the bug T182 was filed for.
    $recvF = Join-Path $work 'received-F.txt'
    $p5 = New-ProxyWindow 'rc5' 'proxy-working.sh' (To-Unix $recvF) 'rc-ready'
    $r = Run-Helper $norepaintWin $p5 'continue-marker-F'
    $gotF = ''
    for ($t = 0; $t -lt 25 -and -not $gotF.Contains($r.probe); $t++) {
        $gotF = [string](Get-Content $recvF -Raw -ErrorAction SilentlyContinue); Start-Sleep -Milliseconds 200
    }
    Assert ($gotF -and $gotF.Contains($r.probe)) 'F1 pre-T261: the continuation arrived just the same'
    Assert ((($gotF -split "`r?`n") -contains $r.sentence)) 'F1b and arrived whole, byte for byte (T664)'
    Assert ($r.log -match 'RESET-CONTEXT FAILED') 'F2 pre-T261: a delivered continuation is called a failure (the filed bug)'
    $b5 = Banner-Of $p5
    Assert ($b5 -and $b5 -match 'reset-context FAILED') "F3 pre-T261: and banners it at the user (got '$b5')"

    # --- G. T562: the composer swallowed the submit -----------------------
    # The filed defect: the text arrives, the Enter does not submit it, and the
    # pane sits at a full composer looking - to the old verifier - exactly like
    # a prompt that had just been echoed. "On screen" was called success and
    # the loop was dead until morning. Now the still pane gets an Enter of its
    # own, which is what the user pressed by hand to recover.
    $recvG = Join-Path $work 'received-G.txt'
    $p6 = New-ProxyWindow 'rc6' 'proxy-swallow.sh' (To-Unix $recvG) 'rc-ready'
    $r = Run-Helper $helper $p6 'continue-marker-G'
    Assert ($r.log -match 'UNSUBMITTED: the handoff is on screen') 'G1 the wedge is NAMED, not mistaken for success'
    Assert ($r.log -match 'pressing Enter \(attempt 1/3\)') 'G2 the gate presses Enter itself'
    $gotG = ''
    for ($t = 0; $t -lt 40 -and -not $gotG.Contains($r.probe); $t++) {
        $gotG = [string](Get-Content $recvG -Raw -ErrorAction SilentlyContinue); Start-Sleep -Milliseconds 250
    }
    Assert ($gotG -and $gotG.Contains($r.probe)) 'G3 the handoff really was submitted (out-of-band receipt)'
    Assert ((($gotG -split "`r?`n") -contains $r.sentence)) 'G3b and arrived whole, byte for byte (T664)'
    Assert ($r.log -match 'verified: handoff is on screen and the pane is moving') 'G4 verified as SUBMITTED, not merely typed'
    Assert ($r.log -notmatch 'RESET-CONTEXT FAILED') 'G5 no failure shouted over a recovered wedge'
    $b6 = Banner-Of $p6
    Assert ([string]::IsNullOrEmpty($b6)) "G6 no banner over a recovered wedge (got '$b6')"

    # --- H. negative control: the same wedge, minus the keypress ----------
    $recvH = Join-Path $work 'received-H.txt'
    $p7 = New-ProxyWindow 'rc7' 'proxy-swallow.sh' (To-Unix $recvH) 'rc-ready'
    $r = Run-Helper $noretryWin $p7 'continue-marker-H'
    Assert ($r.log -match 'RESET-CONTEXT FAILED') 'H1 without the press the wedge is still a failure'
    Assert ($r.log -match 'TYPED BUT NOT SUBMITTED') 'H2 and the log names what went wrong'
    Assert ($r.log -notmatch 'verified: handoff is on screen') 'H3 a full composer is never reported as verified (the filed bug)'
    $gotH = [string](Get-Content $recvH -Raw -ErrorAction SilentlyContinue)
    Assert (-not ($gotH -and $gotH.Contains($r.probe))) 'H4 the handoff never reached the session'

    # --- I. T699: a handoff that lost its FIRST character ------------------
    # The 2026-08-10 loss, reproduced on demand. Everything the helper checked
    # before T699 still passes over it - the basename is in the MIDDLE of the
    # sentence, so the probe finds it, and the pane moves - which is exactly
    # why it went unnoticed. The integrity verdict is the only thing that sees
    # it, and this section asserts both halves: the old gate says "fine", the
    # new one says CORRUPTED.
    $p8 = New-ProxyWindow 'rc8' 'proxy-normal.sh'
    $r = Run-Helper $helper $p8 'continue-marker-I' 'lead'
    Assert (Wait-Tail $p8 $r.probe 10) 'I1 the basename still reached the screen (the old probe is satisfied)'
    Assert ($r.log -match 'verified: handoff is on screen') 'I2 and the motion gate still calls it delivered - the blindness, reproduced'
    Assert ($r.log -match 'CORRUPTED') 'I3 the integrity verdict NAMES the loss'
    Assert ($r.log -match 'RESET-CONTEXT FAILED') 'I4 and shouts it into the log'
    $b8 = Banner-Of $p8
    Assert ($b8 -and $b8 -match 'reset-context FAILED') "I5 banner tells the user (got '$b8')"
    Assert ($r.log -notmatch 'verified: the handoff arrived INTACT') 'I6 nothing claims the handoff was whole'

    # --- J. T699: a handoff whose PATH lost a byte -------------------------
    # The expensive half: the prose surviving a lost byte still gets read, a
    # path that lost one does not exist, so the fresh session reads nothing and
    # the loop stalls with no explanation. The basename is untouched here, so
    # again every pre-T699 check passes.
    $p9 = New-ProxyWindow 'rc9' 'proxy-normal.sh'
    $r = Run-Helper $helper $p9 'continue-marker-J' 'path'
    Assert (Wait-Tail $p9 $r.probe 10) 'J1 the basename is intact, so the old probe is satisfied'
    Assert ($r.log -match 'CORRUPTED') 'J2 the integrity verdict catches the broken PATH'
    Assert ($r.log -match 'RESET-CONTEXT FAILED') 'J3 and shouts it into the log'
    $b9 = Banner-Of $p9
    Assert ($b9 -and $b9 -match 'reset-context FAILED') "J4 banner tells the user (got '$b9')"

    # --- K. T1502: the composer swallowed the /clear, one Enter recovers it -
    # The clear gate's own T562: "/clear" is typed, the CR that came with it is
    # eaten, and the pane sits at a full composer. From 2026-08-25 the gate
    # grepped for a prompt glyph no Claude Code pane prints, so it saw an empty
    # composer here and wrote "verified" over a session that had cleared
    # nothing. The marker it anchors on now was measured in live panes; this
    # section is the demonstration that it can see this state at all.
    $recvK = Join-Path $work 'received-K.txt'
    $p10 = New-ProxyWindow 'rc10' 'proxy-clearwedge.sh' (To-Unix $recvK) 'rc-ready'
    $r = Run-Helper $helper $p10 'continue-marker-K'
    Assert ($r.log -match "clear check: reading the composer") 'K1 the gate found the composer by its measured marker'
    Assert ($r.log -match 'UNSUBMITTED: /clear is in the composer') 'K2 the wedge is NAMED, not reported as a clean clear'
    Assert ($r.log -match 'pressing Enter \(attempt 1/3\)') 'K3 the gate presses Enter itself'
    $gotK = ''
    for ($t = 0; $t -lt 40 -and -not (($gotK -split "`r?`n") -contains '/clear'); $t++) {
        $gotK = [string](Get-Content $recvK -Raw -ErrorAction SilentlyContinue); Start-Sleep -Milliseconds 250
    }
    Assert ((($gotK -split "`r?`n") -contains '/clear')) 'K4 the clear really RAN (out-of-band receipt), not merely looked cleared'
    Assert ($r.log -match 'verified: /clear landed') 'K5 and the recovered clear verifies'
    Assert ($r.log -notmatch 'RESET-CONTEXT FAILED') 'K6 no failure shouted over a recovered wedge'
    $b10 = Banner-Of $p10
    Assert ([string]::IsNullOrEmpty($b10)) "K7 no banner over a recovered wedge (got '$b10')"

    # --- L. T1502: a composer that will NEVER submit the /clear ------------
    # Three Enters and it is still sitting there. That is the state the loop
    # cannot recover from by itself, so it must be shouted at the user rather
    # than written off - the arms section B lost on 2026-09-12 are this shape,
    # against the pane that actually produces it.
    $recvL = Join-Path $work 'received-L.txt'
    $p11 = New-ProxyWindow 'rc11' 'proxy-clearwedge.sh' (To-Unix $recvL) 'rc-ready' '99'
    $r = Run-Helper $helper $p11 'continue-marker-L'
    Assert ($r.log -match 'pressing Enter \(attempt 3/3\)') 'L1 the gate spends its whole Enter budget'
    Assert ($r.log -match "still in the composer after 3 Enter press\(es\)") 'L2 and NAMES the /clear that never ran'
    Assert ($r.log -match 'RESET-CONTEXT FAILED') 'L3 and shouts it into the log'
    Assert ($r.log -notmatch 'verified: /clear landed') 'L4 nothing claims the clear landed'
    $gotL = [string](Get-Content $recvL -Raw -ErrorAction SilentlyContinue)
    Assert (-not (($gotL -split "`r?`n") -contains '/clear')) 'L5 the receipt agrees: the clear never ran'
    $b11 = Banner-Of $p11
    Assert ($b11 -and $b11 -match 'reset-context FAILED') "L6 banner tells the user (got '$b11')"
    # Liveness still beats cleanliness: an uncleared context is survivable, a
    # continuation that never arrives is not.
    Assert (Wait-Tail $p11 'Working...' 20) 'L7 the continuation is sent anyway'

    # --- M. negative control for K/L: the pre-T1502 blind gate -------------
    # The same permanently wedged pane, driven by a helper whose composer
    # marker is a glyph no pane prints. It must report success - that is the
    # filed defect, reproduced - which is what makes K and L measurements of
    # the signature rather than of the machinery around it.
    $recvM = Join-Path $work 'received-M.txt'
    $p12 = New-ProxyWindow 'rc12' 'proxy-clearwedge.sh' (To-Unix $recvM) 'rc-ready' '99'
    $r = Run-Helper $blindWin $p12 'continue-marker-M'
    Assert ($r.log -match 'verified: /clear landed') 'M1 pre-T1502: a wedged composer is called a clean clear (the filed bug)'
    Assert ($r.log -notmatch 'UNSUBMITTED: /clear is in the composer') 'M2 pre-T1502: the wedge is never even noticed'
    $gotM = [string](Get-Content $recvM -Raw -ErrorAction SilentlyContinue)
    Assert (-not (($gotM -split "`r?`n") -contains '/clear')) 'M3 while the receipt shows the clear never ran'

    # --- D. durability of the fix (T130's lesson) -------------------------
    $cached = Get-Content $cacheHelper -Raw
    Assert ($cached -match '--when-idle C-u') 'D1 the ACTIVE plugin cache carries the composer wipe'
    Assert ($cached -match 'RESET-CONTEXT FAILED') 'D2 the ACTIVE plugin cache carries the loud verification'
    Assert ($cached -match 'verdict="pane is repainting') 'D5 the ACTIVE plugin cache accepts a repainting pane as delivery (T182)'
    Assert ($cached -notmatch 'continuation text never appeared') 'D6 and no longer carries the one-shot check that cried wolf'
    Assert ($cached -match 'pressing Enter \(attempt') 'D7 the ACTIVE plugin cache carries the submission gate (T562)'
    Assert ($cached -match 'it contains your instructions for this session') `
        'D8 the ACTIVE plugin cache hands the continuation over by reference, never typing the prose'
    Assert ($cached -match 'arrived INTACT') 'D9 the ACTIVE plugin cache carries the integrity verdict (T699)'
    Assert ($cached -match '(?m)^NBSP=') 'D10 the ACTIVE plugin cache anchors the clear gate on the measured composer marker (T1502)'
    Assert ($cached -notmatch [char]0x276F) 'D11 and no longer greps for the glyph no pane prints'
    $srcRepo = 'D:\git\dzearing-claude-marketplace'
    $srcHelper = Join-Path $srcRepo 'skills\reset-context\scripts\reset-context.sh'
    if (Test-Path $srcHelper) {
        $a = [IO.File]::ReadAllBytes($cacheHelper)
        $b = [IO.File]::ReadAllBytes($srcHelper)
        $same = ($a.Length -eq $b.Length)
        if ($same) { for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $same = $false; break } } }
        Assert $same 'D3 source repo copy is byte-identical to the cache (no cache-only fix)'
        $v = (Get-Content (Join-Path $srcRepo '.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version
        Assert ([version]$v -ge [version]'0.11.0') "D4 source plugin version bumped to carry it (got $v)"
    } else {
        Write-Host 'SKIP  D3/D4: dzearing-claude-marketplace not cloned on this box' -ForegroundColor Yellow
        $script:skipped++
    }
} finally {
    foreach ($w in @('rc1', 'rc2', 'rc3', 'rc4', 'rc5', 'rc6', 'rc7', 'rc8', 'rc9', 'rc10', 'rc11', 'rc12')) { & $exe +close --target=$w 2>$null | Out-Null }
    Start-Sleep -Milliseconds 500
    Kill-RepoInstances
    Remove-TestDesktop | Out-Null
}

# --- stamp (T783) ---------------------------------------------------------
# A green run RECORDS the content of every file it covers, so
# scripts\guard-due.ps1 can answer "has anything run this harness against the
# code as it now stands?". Stamped only on a CLEAN sweep: a run with skipped
# sections proved less than the whole harness claims. A red run leaves the
# stamp alone on purpose - red must stay due.
if ($script:fail -eq 0 -and -not $script:skipped) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard reset-context -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass$(if ($script:skipped) { ", $script:skipped SKIPPED" }))" -ForegroundColor Green; exit 0 }
Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red
exit 1
