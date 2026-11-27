#!/usr/bin/env bash
# palette-shell-pick.sh - T3737 acceptance (the Linux half of win32's T3751,
# test/win32/palette-shell-pick.ps1): the command palette's "New Tab with
# Shell…", "New Window with Shell…", "Split Right with Shell…" and "Split Down
# with Shell…" rows keep the palette open and swap its list for the installed
# shells (the Settings > Shell list: zsh, bash, fish, nu - whichever PATH
# holds); Escape goes back; picking a shell opens that target on it, in the
# folder a new pane from the current one starts in.
#
# Driven by the debug-only `command-palette` seam (IpcHandlers.
# commandPaletteSeam), whose ops call what typing in the palette, clicking a
# row and pressing Escape call. The pane's shell is read from the process
# `+list` names (/proc/<pid>/exe), its folder from /proc/<pid>/cwd.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\palette-shell-pick.sh
#
# Both session-persistence paths run: on (the default - every pane is hosted
# by ghoztty-agent, which must forward the shell's argv), then off (a plain
# PTY). The default shell is /bin/sh, so a pane that comes up on bash can only
# be the pick.
#
# NEGATIVE=1 backs out of the shell list with Escape instead of picking bash,
# so no pane opens and every <pass>.8 must go red: the check can fail.
#
# Output: one PASS/FAIL line per check, then 'PALETTE SHELL PICK: ALL PASS' or
# 'PALETTE SHELL PICK: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PALETTE SHELL PICK"

log=/tmp/palette-shell-pick-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "P1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

bash_path=$(command -v bash)
[ -n "$bash_path" ] && [ "$(readlink -f /bin/sh)" != "$(readlink -f "$bash_path")" ]
hl_check "P2 bash is installed and /bin/sh is not bash (so a bash pane can only be the pick)" $? "bash=$bash_path sh=$(readlink -f /bin/sh)"

hl_start
hl_check "P3 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
cfg_dir="$XDG_CONFIG_HOME/ghostty"
dev="$cfg_dir/config-debug.ghostty"
mkdir -p "$cfg_dir"
export SHELL=/bin/sh

jget() { printf '%s' "$1" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); d=r.get("data",r); v=eval(sys.argv[1]); print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$2" 2>/dev/null; }

# panes: every terminal leaf as "<window-index> <tab-index> <pid>", one a line.
panes() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for wi, w in enumerate(d["windows"]):
    for ti, t in enumerate(w["tabs"]):
        for l in walk(t["splits"]):
            print(wi, ti, l.get("pid") or 0)
' 2>/dev/null
}
# exe_of <pid>: the program a pane runs (its shell), resolved.
exe_of() { readlink -f "/proc/$1/exe" 2>/dev/null; }
cwd_of() { readlink -f "/proc/$1/cwd" 2>/dev/null; }

run_pass() { # run_pass <label> <session-persistence>
    local tag=$1 persist=$2 wd o pane before after newpid target title shown
    wd="$HL_RUNTIME/wd-$tag"; mkdir -p "$wd"
    printf 'session-persistence = %s\nwindow-inherit-working-directory = true\n' "$persist" > "$dev"
    hl_launch APP "$app" --gtk-single-instance=false --working-directory="$wd"
    hl_wait_for 30 test -S "$(hl_socket)"
    hl_check "$tag.1 the app serves its socket (session-persistence=$persist)" $?
    pane=""; for _ in $(seq 1 50); do pane=$(hl_first_pane "$app"); [ -n "$pane" ] && break; sleep 0.2; done
    pal() { hl_ipc command-palette --target="$pane" "$@"; }

    # ---- the rows, the second step, Escape -----------------------------------
    o=$(pal --op=open --query='with shell')
    four() { o=$(pal); [ "$(jget "$o" 'd["pending"]')" = false ] && [ "$(jget "$o" 'sorted(r["title"] for r in d["rows"])')" = '["New Tab with Shell…", "New Window with Shell…", "Split Down with Shell…", "Split Right with Shell…"]' ]; }
    hl_wait_for 5 four
    hl_check "$tag.2 'with shell' finds the four rows, each keyed *_with_shell" $? "rows=$(jget "$o" '[(r["title"], r["action_key"]) for r in d["rows"]]')"

    o=$(pal --op=run --title='New Tab with Shell…')
    [ "$(jget "$o" 'd["open"]')" = true ] && [ "$(jget "$o" 'd["shell_step"]')" = new_tab_with_shell ]
    hl_check "$tag.3 choosing a row keeps the palette open on its shell list" $? "open=$(jget "$o" 'd["open"]') step=$(jget "$o" 'd["shell_step"]')"
    shells() { o=$(pal); [ "$(jget "$o" 'd["pending"]')" = false ] && [ "$(jget "$o" 'any(r["title"]=="bash" and r["action_key"].endswith("/bash") for r in d["rows"])')" = true ]; }
    hl_wait_for 5 shells
    hl_check "$tag.4 the list is the installed shells: a bash row with its path, and no commands" $? "rows=$(jget "$o" '[(r["title"], r["action_key"]) for r in d["rows"]]')"
    [ "$(jget "$o" 'all(r["action_key"].startswith("/") for r in d["rows"])')" = true ]
    hl_check "$tag.5 every row in it is a shell path (no command rows leak in)" $? "rows=$(jget "$o" '[r["action_key"] for r in d["rows"]]')"

    o=$(pal --op=escape)
    [ "$(jget "$o" 'd["open"]')" = true ] && [ "$(jget "$o" 'd["shell_step"]')" = null ] && [ "$(jget "$o" 'len(d["rows"]) > 10')" = true ]
    hl_check "$tag.6 Escape goes back to the commands, the palette still open" $? "open=$(jget "$o" 'd["open"]') step=$(jget "$o" 'd["shell_step"]') rows=$(jget "$o" 'len(d["rows"])')"
    o=$(pal --op=escape)
    closed() { o=$(pal); [ "$(jget "$o" 'd["open"]')" = false ]; }
    hl_wait_for 5 closed
    hl_check "$tag.7 a second Escape closes it" $? "$o"

    # ---- each target, on bash -------------------------------------------------
    for target in "New Tab with Shell…" "New Window with Shell…" "Split Right with Shell…" "Split Down with Shell…"; do
        [ "$persist" = false ] && [ "$target" != "New Tab with Shell…" ] && continue
        before=$(panes)
        o=$(pal --op=open --query='with shell')
        hl_wait_for 5 four
        o=$(pal --op=run --title="$target")
        hl_wait_for 5 shells
        if [ "${NEGATIVE:-0}" = 1 ]; then o=$(pal --op=escape); o=$(pal --op=escape); else o=$(pal --op=run --title=bash); fi
        hl_wait_for 5 closed
        grown() { after=$(panes); [ "$(printf '%s\n' "$after" | grep -c .)" -gt "$(printf '%s\n' "$before" | grep -c .)" ]; }
        hl_wait_for 15 grown
        newpid=$(comm -13 <(printf '%s\n' "$before" | awk '{print $3}' | sort) <(printf '%s\n' "$after" | awk '{print $3}' | sort) | head -1)
        hl_wait_for 10 sh -c "[ \"\$(readlink -f /proc/$newpid/exe 2>/dev/null)\" = \"$(readlink -f "$bash_path")\" ]"
        hl_check "$tag.8 $target -> bash opens a new pane running bash" $? "new pid=$newpid exe=$(exe_of "$newpid") panes: $(printf '%s' "$before" | tr '\n' ';') -> $(printf '%s' "$after" | tr '\n' ';')"
        # Where it landed: a tab is a new (window,tab) pair in window 0, a
        # window a new window index, a split a second pane in an existing tab.
        shape=$(printf '%s\n' "$after" | awk -v p="$newpid" '$3==p {print $1, $2}')
        case "$target" in
            New\ Tab*) want="0 $(printf '%s\n' "$before" | awk '$1==0 {print $2}' | sort -n | tail -1 | awk '{print $1+1}')" ;;
            New\ Window*) want="$(printf '%s\n' "$before" | awk '{print $1}' | sort -n | tail -1 | awk '{print $1+1}') 0" ;;
            *) want=split ;;
        esac
        if [ "$want" = split ]; then
            [ "$(printf '%s\n' "$after" | awk -v s="$shape" '($1" "$2)==s' | grep -c .)" -ge 2 ]
        else
            [ "$shape" = "$want" ]
        fi
        hl_check "$tag.9 $target lands where it says (window tab = $shape)" $? "want=$want"
        [ "$(cwd_of "$newpid")" = "$(readlink -f "$wd")" ]
        hl_check "$tag.10 $target starts in the current pane's folder" $? "cwd=$(cwd_of "$newpid") want=$wd"
    done

    # The palette's log line names the target and the shell (T3737).
    grep -q 'command palette: new_tab on shell .*bash' "$APP_LOG"
    hl_check "$tag.11 the app log names the pick" $?
    kill "$APP" 2>/dev/null; hl_wait_for 10 sh -c "! kill -0 $APP 2>/dev/null"
    rm -f "$(hl_socket)"
}

# Plain PTYs first: a pass with the agent leaves sessions a later launch
# would restore.
run_pass B false
run_pass A true
hl_stop_agent

hl_finish "$L"
