#!/usr/bin/env bash
# prompt-redraw.sh - T3630 acceptance for the prompt half of terminal resize
# pacing on the GTK debug app (docs/reference/terminal-resize.md; Linux
# L11f): a window resize at a bash prompt (Ghostty shell integration, OSC 133
# marks) is applied at once, and the prompt the resize clears for the shell
# to redraw is NEVER shown blank - the renderer holds the last frame
# (`Terminal.flags.awaiting_prompt_redraw`) until bash has redrawn it.
#
# WHY GTK NEEDS ITS OWN PROOF. The hold lives in the shared renderer's
# updateFrame, but on GTK the GtkGLArea presents its own framebuffer and GTK
# re-renders it on every allocation change (glareaRender -> drawFrame) whether
# or not the renderer thread updated the cells. So whether a held frame shows
# the old prompt, or a blank buffer at the new size, is GTK's to answer.
#
# THE PROMPT is a bash PS1 drawn on a 24-bit green background (0,200,0), so a
# frame "shows the prompt" when it has green pixels in it. Frames come from
# the app's OWN render through the debug-only capture-pane seam (each capture
# snapshots the GLArea as GTK would composite it now); the window is resized
# through the debug-only window-size seam (gtk_window_set_default_size, as an
# edge drag would) - the headless Weston has neither a capture nor a seat.
#
# THE LOG ORACLE is the app's debug log, as test/win32/prompt-reflow.ps1 reads
# it on Windows: `resize pace=<now|after_redraw|debounce>` per resize, and
# `prompt redraw released by=redraw|cap` per held frame - by=cap means the
# 250 ms cap drew the cleared prompt, blank.
#
# SECTIONS
#   P1-P3  the shell is up, at a marked prompt, the prompt is green on screen
#   P4-P8  a 16-step window-resize storm at the prompt: every resize decided
#          now/after_redraw (never debounce - the marks arrived), the window
#          really changed size, every captured frame shows the prompt, no
#          held frame was released by the cap, and at least one by the redraw
#          (so "no cap" is not vacuous)
#   P9     the prompt is still there afterwards (+read)
#   C1-C2  CONTROL, every run: with bash STOPPED (SIGSTOP) one resize clears
#          the prompt and nothing redraws it - the cap releases it, and the
#          captured frame has NO green. The oracle can see a blank prompt.
#
# NEGATIVE=1 stops bash for the storm too, and MUST fail P6-P8.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\prompt-redraw.sh
#
# Output: one PASS/FAIL line per check, then 'PROMPT REDRAW: ALL PASS' or
# 'PROMPT REDRAW: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PROMPT REDRAW"

log=/tmp/prompt-redraw-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "P0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "P0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
printf 'window-width = 100\nwindow-height = 30\nshell-integration = bash\n' > "$cfg_dir/config.ghostty"

# bash with a green prompt; it writes its pid so the control can stop it.
# It is the pane's DEFAULT shell ($SHELL), not an `-e` command: an explicit
# command reaches the agent as OPEN.command, run under the default shell,
# and the injected integration lands on that outer shell instead (T3758).
# So the prompt lives in a private $HOME/.bashrc, which Ghostty's injected
# ghostty.bash sources as an interactive bash would.
home="$HL_RUNTIME/home"; mkdir -p "$home"
pidfile="$HL_RUNTIME/bash.pid"
: > "$pidfile"
cat > "$home/.bashrc" <<RC
HISTFILE=/dev/null
echo \$\$ > $pidfile
PS1='\[\e[48;2;0;200;0m\] READY-PROMPT \[\e[0m\] \$ '
RC

hl_launch APP env SHELL=/bin/bash HOME="$home" "$app" --gtk-single-instance=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "P1 the app serves its socket" $?
hl_wait_for 20 test -s "$pidfile"
bash_pid=$(cat "$pidfile" 2>/dev/null)
pane=$(hl_first_pane "$app")
hl_wait_for 20 sh -c "env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID '$app' +read --name='$pane' --lines=5 2>/dev/null | grep -q READY-PROMPT"
hl_check "P2 bash is up at its prompt (pid $bash_pid, pane $pane)" $? "$(cli +read --name="$pane" --lines=5 2>&1 | tr '\n' '|')"

cli +send-keys --target="$pane" 'echo output-above-the-prompt' Enter > /dev/null 2>&1
hl_wait_for 10 sh -c "env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID '$app' +read --name='$pane' --lines=5 2>/dev/null | grep -q '^output-above-the-prompt'"

shots="$HL_RUNTIME/shots"; mkdir -p "$shots"
# green <png>: the fraction of the frame that is the prompt's green.
green() { hl_png_stats "$1" 0 200 0 2>/dev/null | sed -n 's/.*match=\([0-9.]*\).*/\1/p'; }
has_green() { python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1] or 0) > 0.0005 else 1)' "${1:-0}"; }
# shot <file>: the pane's next composited frame. Straight after a resize GTK
# has not re-allocated the pane yet and the snapshot has nothing to draw
# ("produced no frame"), so poll - the first frame that comes back is the one
# the resize put on screen.
shot() {
    local _
    for _ in $(seq 1 40); do
        hl_screenshot "$pane" "$1" --width=400 > /dev/null 2>&1 && return 0
        sleep 0.01
    done
    return 1
}
ws() { hl_ipc window-size "--target=$pane" "$@"; }
wwidth() { printf '%s' "$1" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("width", 0))' 2>/dev/null; }
log_after() { tail -n +"$(( $1 + 1 ))" "$APP_LOG"; }

sleep 0.5
shot "$shots/before.png"
g=$(green "$shots/before.png")
has_green "$g"
hl_check "P3 the prompt is on screen before any resize (green=$g)" $?

# ---- the storm -------------------------------------------------------------
[ "${NEGATIVE:-0}" = 1 ] && [ -n "$bash_pid" ] && kill -STOP "$bash_pid"
mark=$(wc -l < "$APP_LOG")
w_before=$(wwidth "$(ws)")
widths=""
STEPS=16
for i in $(seq 1 $STEPS); do
    if [ $((i % 2)) = 1 ]; then size="$((700 + i * 10))x$((420 + i * 4))"; else size="$((900 - i * 10))x$((520 - i * 4))"; fi
    widths="$widths $(wwidth "$(ws "--size=$size")")"
    shot "$shots/storm-$i.png"
done
sleep 0.6
[ "${NEGATIVE:-0}" = 1 ] && [ -n "$bash_pid" ] && kill -CONT "$bash_pid"
sleep 0.4
storm=$(log_after "$mark")
paces=$(printf '%s\n' "$storm" | grep -o 'resize pace=[a-z_]*' | sed 's/resize pace=//' | sort | uniq -c | tr '\n' ' ')
n_pace=$(printf '%s\n' "$storm" | grep -c 'resize pace=')
n_deb=$(printf '%s\n' "$storm" | grep -c 'resize pace=debounce')
n_cap=$(printf '%s\n' "$storm" | grep -c 'prompt redraw released by=cap')
n_redraw=$(printf '%s\n' "$storm" | grep -c 'prompt redraw released by=redraw')
distinct=$(printf '%s\n' $w_before $widths | sort -u | wc -l | tr -d ' ')

[ "$n_pace" -ge 4 ] && [ "$n_deb" = 0 ]
hl_check "P4 every resize at the prompt was decided now/after_redraw, never debounce ($paces)" $? "$(printf '%s\n' "$storm" | grep -m4 'resize pace=' | tr '\n' '|')"
[ "$distinct" -ge 4 ]
hl_check "P5 the window really changed size ($distinct distinct widths:$widths)" $?

blank=""
for i in $(seq 1 $STEPS); do
    g=$(green "$shots/storm-$i.png")
    has_green "$g" || blank="$blank $i(green=${g:-none})"
done
[ -z "$blank" ]
hl_check "P6 every frame captured during the storm shows the prompt ($STEPS frames)" $? "blank frames:$blank"
[ "$n_cap" = 0 ]
hl_check "P7 no held frame was released by the cap (by=cap: $n_cap)" $? "$(printf '%s\n' "$storm" | grep -m3 'released by=' | tr '\n' '|')"
[ "$n_redraw" -ge 1 ]
hl_check "P8 bash's redraw released the held frame ($n_redraw by=redraw)" $?

cli +read --name="$pane" --lines=30 2>/dev/null | grep -q 'READY-PROMPT'
hl_check "P9 the prompt is still on screen afterwards (+read)" $? "$(cli +read --name="$pane" --lines=6 2>&1 | tr '\n' '|')"

# ---- control: nothing redraws the prompt -----------------------------------
if [ -n "$bash_pid" ]; then
    sleep 0.5
    mark=$(wc -l < "$APP_LOG")
    kill -STOP "$bash_pid"
    ws "--size=760x470" > /dev/null
    sleep 0.8
    shot "$shots/control.png"
    gc=$(green "$shots/control.png")
    kill -CONT "$bash_pid"
    ctl=$(log_after "$mark")
    printf '%s\n' "$ctl" | grep -q 'prompt redraw released by=cap'
    hl_check "C1 CONTROL: with bash stopped the cap released the cleared prompt" $? "$(printf '%s\n' "$ctl" | grep -m4 'resize pace=\|released by=' | tr '\n' '|')"
    ! has_green "$gc"
    hl_check "C2 CONTROL: and that frame shows NO prompt (green=$gc) - the oracle can see a blank one" $?
else
    hl_check "C1 CONTROL: bash wrote its pid" 1
fi

rm -f "$pidfile"
hl_finish "$L"
