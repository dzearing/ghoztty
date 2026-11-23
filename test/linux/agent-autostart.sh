#!/usr/bin/env bash
# agent-autostart.sh - T3398 (Linux L8c) acceptance: once session persistence
# engages, the GTK app writes the login entry that starts ghoztty-agent
# without the app - a systemd --user unit (plus its default.target.wants
# enable link) when the user's systemd answers on
# $XDG_RUNTIME_DIR/systemd/private, else an XDG autostart .desktop entry -
# and the command in that entry really does bring the agent back, on the
# same state dir the app finds. The gates hold: a debug build writes nothing
# by default, `gate` refuses a binary inside a source checkout, `off` writes
# nothing, and only one backend's entry exists at a time.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\agent-autostart.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh)
# whose private XDG_CONFIG_HOME and XDG_RUNTIME_DIR take every write. The
# user's systemd is never asked anything: the app never runs systemctl, and
# the "systemd is reachable" state is the marker file the app looks for,
# made under the harness's private runtime dir.
#
# Output: one PASS/FAIL line per check, then 'AGENT AUTOSTART: ALL PASS' or
# 'AGENT AUTOSTART: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="AGENT AUTOSTART"

real_cfg="${HOME}/.config"
real_unit="$real_cfg/systemd/user/ghoztty-agent-debug.service"
real_desk="$real_cfg/autostart/ghoztty-agent-debug.desktop"
real_before="$( [ -e "$real_unit" ] && echo U)$( [ -e "$real_desk" ] && echo D)"

log=/tmp/agent-autostart-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "A1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "A2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
agent_bin="$(dirname "$app")/ghoztty-agent"
state="$XDG_CONFIG_HOME/ghoztty/local-agent-debug"
unit="$XDG_CONFIG_HOME/systemd/user/ghoztty-agent-debug.service"
wants="$XDG_CONFIG_HOME/systemd/user/default.target.wants/ghoztty-agent-debug.service"
desk="$XDG_CONFIG_HOME/autostart/ghoztty-agent-debug.desktop"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
export SHELL=/bin/sh
n=0

# run_app <mode or ""> : launch the app with GHOZTTY_AGENT_AUTOSTART=<mode>
# (unset for ""), wait until its first agent-hosted pane runs, leave it up.
run_app() {
    n=$((n + 1))
    local m="$HL_RUNTIME/pane$n" s="$HL_RUNTIME/pane$n.sh"
    printf '#!/bin/sh\necho $$ > %s\nsleep 120\n' "$m" > "$s"; chmod +x "$s"
    if [ -n "$1" ]; then
        hl_launch APP env GHOZTTY_AGENT_AUTOSTART="$1" "$app" --gtk-single-instance=false -e "$s"
    else
        hl_launch APP env -u GHOZTTY_AGENT_AUTOSTART "$app" --gtk-single-instance=false -e "$s"
    fi
    hl_wait_for 30 test -s "$m"
}
# Each launch starts from no saved layout: what this test asks is when the
# login entry is written, not what a relaunch restores (session-restore.sh),
# and a restored launch loses its own -e command today (T3594).
stop_app() {
    kill -TERM "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
    rm -f "$XDG_CONFIG_HOME"/ghoztty/session-layout*.json
}
no_entries() { [ ! -e "$unit" ] && [ ! -L "$wants" ] && [ ! -e "$desk" ]; }
listing() { (cd "$XDG_CONFIG_HOME" && find systemd autostart 2>/dev/null | tr '\n' ' '); }

# agent_up_from <expected exe>: port.json names a live process running it.
agent_up_from() {
    local p
    p=$(hl_agent_pid) || return 1
    [ "$(readlink "/proc/$p/exe")" = "$1" ]
}

# ---- 1. the gates: default debug, gate in a checkout, off -------------------
run_app ""
hl_check "A3 a default debug launch runs an agent-hosted pane" $?
sleep 1
no_entries
hl_check "A4 ...and writes no login entry (a debug build never does on its own)" $? "$(listing)"
stop_app

run_app gate
sleep 1
no_entries
hl_check "A5 GHOZTTY_AGENT_AUTOSTART=gate refuses a binary inside a source checkout" $? "$(listing)"
grep -q 'no login entry written from a source checkout' "$APP_LOG"
hl_check "A6 ...and says why in the log" $? "$(grep -m2 'autostart' "$APP_LOG" | tr '\n' ' ')"
stop_app

run_app off
sleep 1
no_entries
hl_check "A7 GHOZTTY_AGENT_AUTOSTART=off writes nothing" $? "$(listing)"
stop_app

# ---- 2. no user systemd: the XDG autostart entry ---------------------------
[ ! -e "$XDG_RUNTIME_DIR/systemd/private" ]
hl_check "A8 the harness runtime dir has no user systemd socket" $?
run_app force
hl_wait_for 10 test -s "$desk"
hl_check "A9 force with no user systemd writes $desk" $? "$(listing)"
[ ! -e "$unit" ] && [ ! -L "$wants" ]
hl_check "A10 ...and no systemd unit" $? "$(listing)"
grep -q 'XDG autostart entry refreshed' "$APP_LOG"
hl_check "A11 the app logs which entry it refreshed" $? "$(grep -m2 'autostart' "$APP_LOG" | tr '\n' ' ')"
if command -v desktop-file-validate > /dev/null 2>&1; then
    out=$(desktop-file-validate "$desk" 2>&1)
    [ -z "$out" ]
    hl_check "A12 desktop-file-validate accepts the entry" $? "$out"
else
    hl_check "A12 desktop-file-validate is installed (scripts/linux/setup-distro.sh)" 1
fi
grep -q '^NoDisplay=true$' "$desk" && grep -q '^Exec=/usr/bin/env "GHOSTTY_AGENT_LOCK=' "$desk"
hl_check "A13 the entry is hidden and runs the agent through /usr/bin/env with its lock" $? "$(grep '^Exec=' "$desk")"
stop_app

# The desktop Exec, run the way a session manager would: string-unescape the
# value, then split it with the spec's (shell-like) quoting.
desktop_argv() {
    python3 - "$1" <<'PY'
import shlex, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("Exec="):
        v = line[len("Exec="):].rstrip("\n")
        out, i = [], 0
        while i < len(v):   # the desktop "string" escapes come off first
            if v[i] == "\\" and i + 1 < len(v):
                out.append({"\\": "\\", "s": " ", "n": "\n", "t": "\t", "r": "\r"}.get(v[i + 1], "\\" + v[i + 1])); i += 2
            else:
                out.append(v[i]); i += 1
        v = "".join(out).replace("%%", "%")
        print("\0".join(shlex.split(v)), end="")
        break
PY
}

hl_stop_agent
for _ in $(seq 1 50); do [ -z "$(hl_agent_pid)" ] && break; sleep 0.2; done
[ -z "$(hl_agent_pid)" ]
hl_check "A14 the app's agent is stopped (a reboot, as far as the entry knows)" $?
mapfile -d '' argv < <(desktop_argv "$desk")
[ "${argv[0]:-}" = /usr/bin/env ] && [ "${#argv[@]}" -ge 5 ]
hl_check "A15 the Exec line parses into /usr/bin/env + env + agent argv" $? "n=${#argv[@]} ${argv[*]:-}"
(cd / && setsid "${argv[@]}" < /dev/null > "$HL_RUNTIME/xdg-agent.log" 2>&1 &)
hl_wait_for 10 agent_up_from "$agent_bin"
hl_check "A16 running the entry's Exec starts $agent_bin on the app's state dir" $? "$(cat "$state/port.json" 2>/dev/null) $(tail -2 "$HL_RUNTIME/xdg-agent.log" | tr '\n' ' ')"
xdg_agent=$(hl_agent_pid)
tr '\0' '\n' < "/proc/${xdg_agent:-0}/environ" 2>/dev/null | grep -qx "GHOSTTY_AGENT_LOCK=$state/agent.lock"
hl_check "A17 ...with the app's lock path in its environment" $?
run_app ""
hl_check "A18 a later app launch runs its pane" $? "$(grep -v -e '^debug' -e color_change "$APP_LOG" | tail -8 | tr '\n' '|')"
[ "$(hl_agent_pid)" = "$xdg_agent" ]
hl_check "A19 ...on the agent the login entry started (no second spawn)" $? "entry=$xdg_agent now=$(hl_agent_pid)"
stop_app
hl_stop_agent

# ---- 3. a user systemd: the unit and its enable link -----------------------
mkdir -p "$XDG_RUNTIME_DIR/systemd" && : > "$XDG_RUNTIME_DIR/systemd/private"
run_app force
hl_wait_for 10 test -s "$unit"
hl_check "A20 force with a user systemd writes $unit" $? "$(listing)"
[ "$(readlink "$wants")" = "$unit" ]
hl_check "A21 ...enabled by default.target.wants -> the unit (what systemctl --user enable makes)" $? "$(readlink "$wants" 2>/dev/null)"
[ ! -e "$desk" ]
hl_check "A22 ...and the XDG entry is gone (one login entry at a time)" $? "$(listing)"
grep -qx 'Restart=on-failure' "$unit" && grep -qx 'RestartPreventExitStatus=183' "$unit" && grep -qx 'WantedBy=default.target' "$unit"
hl_check "A23 the unit restarts a crash, not a lost single-instance lock, and starts at login" $?
grep -qx "StandardOutput=append:$state/agent.log" "$unit"
hl_check "A24 the unit appends the agent's output to the agent.log the spawn uses" $? "$(grep '^Standard' "$unit" | tr '\n' ' ')"
if command -v systemd-analyze > /dev/null 2>&1; then
    out=$(systemd-analyze verify "$unit" 2>&1 | grep -v -e 'Failed to connect' -e 'bus' )
    ! printf '%s' "$out" | grep -qi "$(basename "$unit")"
    hl_check "A25 systemd-analyze verify has no complaint about the unit" $? "$out"
else
    hl_check "A25 systemd-analyze is installed" 1
fi
grep -q 'systemd user unit refreshed' "$APP_LOG"
hl_check "A26 the app logs the unit refresh" $? "$(grep -m2 'autostart' "$APP_LOG" | tr '\n' ' ')"
stop_app

# ExecStart + Environment=, run the way systemd would.
unit_cmd() {
    python3 - "$1" <<'PY'
import shlex, sys
env, argv = [], []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("Environment="):
        env += [s.replace("%%", "%") for s in shlex.split(line[len("Environment="):])]
    elif line.startswith("ExecStart="):
        argv = [s.replace("%%", "%").replace("$$", "$") for s in shlex.split(line[len("ExecStart="):])]
print("\0".join(["/usr/bin/env"] + env + argv), end="")
PY
}
hl_stop_agent
mapfile -d '' uargv < <(unit_cmd "$unit")
[ "${uargv[0]:-}" = /usr/bin/env ] && [ "${#uargv[@]}" -ge 5 ]
hl_check "A27 the unit's ExecStart and Environment parse" $? "${uargv[*]:-}"
(cd / && setsid "${uargv[@]}" < /dev/null >> "$state/agent.log" 2>&1 &)
hl_wait_for 10 agent_up_from "$agent_bin"
hl_check "A28 running the unit's command starts the agent on the app's state dir" $? "$(cat "$state/port.json" 2>/dev/null)"
cli +sessions > /dev/null 2>&1
hl_check "A29 +sessions reaches it with no app running" $? "$(cli +sessions 2>&1 | head -2 | tr '\n' ' ')"
hl_stop_agent

# ---- 4. systemd goes away: back to the XDG entry, the unit is removed -------
rm -f "$XDG_RUNTIME_DIR/systemd/private"
run_app force
hl_wait_for 10 test -s "$desk"
hl_check "A30 with the user systemd gone the XDG entry comes back" $? "$(listing)"
[ ! -e "$unit" ] && [ ! -L "$wants" ]
hl_check "A31 ...and the unit and its enable link are removed" $? "$(listing)"
stop_app

# ---- 5. nothing reached the real config dir --------------------------------
real_after="$( [ -e "$real_unit" ] && echo U)$( [ -e "$real_desk" ] && echo D)"
[ "$real_before" = "$real_after" ]
hl_check "A32 nothing was written under the real $real_cfg" $? "before=[$real_before] after=[$real_after]"

hl_finish "$L"
