#!/usr/bin/env bash
# settings-live.sh - T3635 (Linux L11g6) acceptance for the GTK Settings
# window's live sections, Mac's AgentStatusSection and RemoteMachinesSection
# (win32 settings_live.zig / settings_remote_view.zig):
#
#   A1-A4  Sessions & Agent reads the running agent - pid, socket, builds -
#          straight from its info file and the shared connection.
#   N1-N3  ...and with no agent it says so WITHOUT starting one.
#   R1-R8  Remote Machines: the account line, the machines a (fake, local)
#          relay lists with their presence dots, the remembered list seeded
#          as "checking" before the fetch answers, and a 401 emptying both.
#   H1-H5  Host Settings...: the chooser's editor, Mac's words, its presets,
#          Save / Cancel / clearing, and the row re-reading the store.
#   U1     an unconfigured build says so and asks the relay nothing.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\settings-live.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh): the agent's state,
# the host defaults, the machine cache and the account store all live under
# its private dirs, and the "relay" is a python http server on loopback.
#
# NEGATIVE=1 makes the relay call every machine offline while R3 still
# expects one online: R3 must FAIL.
#
# Output: one PASS/FAIL line per check, then 'SETTINGS LIVE: ALL PASS' or
# 'SETTINGS LIVE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="SETTINGS LIVE"

log=/tmp/settings-live-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "B1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "B2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
agent_bin="$(dirname "$app")/ghoztty-agent"

jget() { printf '%s' "$1" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1]); print(json.dumps(v, ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$2" 2>/dev/null; }
st() { hl_ipc settings "$@"; }
lv() { jget "$(st --op=state)" "d['live']$1"; }

# ---- the fake relay: GET /v1/client/devices, answer chosen by a file -------
relay_dir="$HL_RUNTIME/relay"; mkdir -p "$relay_dir"
mode="$relay_dir/mode"; reqs="$relay_dir/requests"
echo ok > "$mode"; : > "$reqs"
cat > "$relay_dir/relay.py" <<'PY'
import http.server, json, os, sys, time
d = sys.argv[1]
neg = os.environ.get("NEGATIVE") == "1"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(os.path.join(d, "requests"), "a") as f:
            f.write("%s %s\n" % (self.path, self.headers.get("Authorization", "")))
        mode = open(os.path.join(d, "mode")).read().strip()
        if mode == "slow":
            time.sleep(4)
        if mode == "401":
            self.send_response(401); self.end_headers(); return
        body = json.dumps({"devices": [
            {"id": "dev-on", "name": "Workstation", "hostname": "ws", "online": not neg},
            {"id": "dev-off", "name": "Laptop", "online": False},
        ]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
NEGATIVE="${NEGATIVE:-}" python3 -I "$relay_dir/relay.py" "$relay_dir" &
RELAY=$!   # killed before hl_finish (hl_start owns the EXIT trap)
hl_wait_for 10 test -s "$relay_dir/port"
port=$(cat "$relay_dir/port")

export SHELL=/bin/sh
export GHOSTTY_RELAY_BASE="http://127.0.0.1:$port"
export GHOSTTY_RELAY_TOKEN=tok-settings-live
export GHOSTTY_ACCOUNT_STORE="$HL_RUNTIME/account-none.dat"   # nobody signed in: the env token is the account
export GHOSTTY_HOST_DEFAULTS="$HL_RUNTIME/host-defaults.json"
export XDG_CACHE_HOME="$HL_RUNTIME/cache"
cache="$XDG_CACHE_HOME/ghoztty/machines-debug.json"
hd="$GHOSTTY_HOST_DEFAULTS"
state="$XDG_CONFIG_HOME/ghoztty/local-agent-debug"

hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_wait_for 30 hl_agent_pid > /dev/null
agent=$(hl_agent_pid)
st --op=action > /dev/null

# ---- Sessions & Agent, with the app's agent running --------------------
o=$(st --op=state --page=session)
a_pid=$(jget "$o" 'd["live"]["agent"]["pid"]')
[ "$(jget "$o" 'd["live"]["agent"]["running"]')" = true ] && [ -n "$agent" ] && [ "$a_pid" = "$agent" ] \
  && [ "$(jget "$o" 'd["live"]["agent"]["drawn"]["status"]')" = "Running · pid $agent" ] \
  && [ "$(jget "$o" 'd["live"]["agent"]["drawn"]["dot"]')" = green ]
hl_check "A1 Status reads the live agent from its info file: 'Running · pid $agent', green dot" $? "$(jget "$o" 'd["live"]["agent"]')"
sock=$(jget "$o" 'd["live"]["agent"]["drawn"]["socket"]')
# (pgrep's pattern is N3's, so this is also N3's positive control.)
[ "$sock" = "$state/agent.sock" ] && [ -S "$sock" ] && pgrep -f "ghoztty-agent.*$XDG_CONFIG_HOME/ghoztty/local-agent" | grep -qx "$agent"
hl_check "A2 Socket names the agent's own socket" $? "drawn=$sock procs=$(pgrep -af "ghoztty-agent.*$XDG_CONFIG_HOME" | tr '\n' ' ')"
rb=$(jget "$o" 'd["live"]["agent"]["drawn"]["running_build"]')
[ -n "$rb" ] && [ "$rb" != null ] && [ "$rb" = "$(jget "$o" 'd["live"]["agent"]["running_build"]')" ]
hl_check "A3 Running build is the build the shared connection shook hands with" $? "running_build=$rb"
want_bb=$("$agent_bin" --version 2>/dev/null | head -1 | awk '{print $NF}')
bb=$(jget "$o" 'd["live"]["agent"]["drawn"]["bundled"]')
titles=$(jget "$o" '",".join(d["live"]["agent"]["drawn"]["titles"])')
{ [ "$bb" = null ] || [ -n "$bb" ]; } && [ "$titles" = "Status,Running build,This app’s agent,Socket" ] \
  && [ "$(jget "$o" 'd["live"]["agent"]["caption"]')" = "The agent keeps your shells alive when the app quits or restarts." ] \
  && [ "$(jget "$o" '[g["drawn"] for g in d["groups"] if g["title"]=="Agent"][0]')" = Agent ]
hl_check "A4 the Agent group draws Mac's four rows and caption (This app's agent only once probed: $bb; --version says $want_bb)" $? "titles=$titles"

# ---- Remote Machines: the account and the relay's machines ---------------
# The first answer is held back 4 s, so R2 sees the page before it lands.
echo slow > "$mode"
o=$(st --op=state --page=remote)
[ "$(jget "$o" 'd["visible_page"]')" = remote ] \
  && [ "$(jget "$o" 'd["live"]["remote"]["account"]')" = signed_in ] \
  && [ "$(jget "$o" 'd["live"]["remote"]["drawn"]["title"]')" = "Signed in as your account" ] \
  && [ "$(jget "$o" 'd["live"]["remote"]["drawn"]["caption"]')" = "Machines enrolled in your account appear below." ]
hl_check "R1 the account row: 'Signed in as your account' (an env token has no email) and Mac's caption" $? "$(jget "$o" 'd["live"]["remote"]["drawn"]')"
[ "$(jget "$o" 'd["live"]["remote"]["rows_drawn"]')" = 0 ] && [ "$(jget "$o" 'd["live"]["remote"]["fetching"]')" = true ] && [ ! -e "$cache" ]
hl_check "R2 nothing remembered yet: no rows while the fetch is out (and no cache file); the window answered at once" $? "rows=$(jget "$o" 'd["live"]["remote"]["rows_drawn"]') fetching=$(jget "$o" 'd["live"]["remote"]["fetching"]') cache=$(ls "$cache" 2>&1)"
echo ok > "$mode"
fetched() { [ "$(lv '["remote"]["fetched"]')" = true ]; }
hl_wait_for 15 fetched
o=$(st --op=state)
m() { jget "$o" "d['live']['remote']['machines']$1"; }
[ "$(m '[0]["drawn"]["title"]')" = Workstation ] && [ "$(m '[0]["drawn"]["dot"]')" = online ] \
  && [ "$(m '[0]["drawn"]["caption"]')" = "online · folder: remote default · shell: remote default" ] \
  && [ "$(m '[1]["drawn"]["title"]')" = Laptop ] && [ "$(m '[1]["drawn"]["dot"]')" = offline ] \
  && [ "$(m '[1]["drawn"]["caption"]')" = "offline · folder: remote default · shell: remote default" ] \
  && [ "$(m '[0]["drawn"]["button"]')" = "Host Settings…" ]
hl_check "R3 the relay's machines: Workstation online (green), Laptop offline (grey), Mac's captions, Host Settings…" $? "$(m '')"
grep -q '^/v1/client/devices Bearer tok-settings-live$' "$reqs"
hl_check "R4 the fetch asked the relay for the device list with the account's bearer" $? "$(cat "$reqs")"
[ -s "$cache" ] && grep -q '"dev-on"' "$cache" && grep -q '"dev-off"' "$cache"
hl_check "R5 the answer is remembered in \$XDG_CACHE_HOME/ghoztty/machines-debug.json" $? "$(cat "$cache" 2>/dev/null)"

# A second showing seeds from the cache at once, before a slow relay answers.
echo slow > "$mode"
n_req=$(wc -l < "$reqs")
st --op=state --page=session > /dev/null
o=$(st --op=state --page=remote)
[ "$(jget "$o" 'd["live"]["remote"]["rows_drawn"]')" = 2 ] && [ "$(m '[0]["drawn"]["dot"]')" = checking ] \
  && [ "$(m '[0]["drawn"]["caption"]')" = "checking… · folder: remote default · shell: remote default" ] \
  && [ "$(jget "$o" 'd["live"]["remote"]["fetching"]')" = true ]
hl_check "R6 shown again: the remembered rows appear at once as 'checking…' (amber) while the fetch is out" $? "$(m '')"
hl_wait_for 15 fetched
o=$(st --op=state)
[ "$(m '[0]["drawn"]["dot"]')" = online ] && [ "$(wc -l < "$reqs")" -gt "$n_req" ]
hl_check "R7 ...and the slow answer then confirms Workstation online" $? "$(m '[0]["drawn"]')"
echo ok > "$mode"

# ---- Host Settings... ------------------------------------------------------
o=$(st --op=host_settings --value=dev-on)
o=$(st --op=state)
hd_get() { jget "$o" "d['live']['host_dialog']$1"; }
[ "$(hd_get '["id"]')" = dev-on ] && [ "$(hd_get '["title"]')" = "Host Settings for “Workstation”" ] \
  && [ "$(hd_get '["body"]')" = "Defaults for new terminals on this machine. Both are values on the remote machine (e.g. wsl.exe or C:\\dev on a Windows host). Leave a field empty to use the remote's own default." ] \
  && [ "$(hd_get '["working_directory"]')" = "" ] && [ "$(hd_get '["shell"]')" = "" ]
hl_check "H1 Host Settings… opens the chooser's editor: Mac's title and body, both fields empty (remote default)" $? "$(hd_get '')"
st --op=host-settings-fill --key=working_directory --value=/srv/work > /dev/null
st --op=host-settings-preset --index=4 > /dev/null
o=$(st --op=state)
[ "$(hd_get '["shell"]')" = /bin/bash ]
hl_check "H2 the shell field's presets are Mac's list (the 5th is /bin/bash)" $? "shell=$(hd_get '["shell"]')"
st --op=host-settings-answer --value=save > /dev/null
o=$(st --op=state)
# hd_entry <key>: that machine's stored entry as JSON (null when absent).
hd_entry() { python3 -I -c 'import json,sys; h=[e for e in json.load(open(sys.argv[1])).get("hosts",[]) if e.get("key")==sys.argv[2]]; print(json.dumps(h[0] if h else None, sort_keys=True))' "$hd" "$1" 2>/dev/null || echo null; }
[ "$(hd_get '')" = null ] && [ "$(hd_entry dev-on)" = '{"key": "dev-on", "shell": "/bin/bash", "working_directory": "/srv/work"}' ] \
  && [ "$(m '[0]["drawn"]["caption"]')" = "online · folder: /srv/work · shell: /bin/bash" ]
hl_check "H3 Save writes the host defaults keyed by device id, and the row re-reads them" $? "entry=$(hd_entry dev-on) caption=$(m '[0]["drawn"]["caption"]')"
before=$(cat "$hd")
st --op=host_settings --value=dev-on > /dev/null
o=$(st --op=state)
pre_wd=$(hd_get '["working_directory"]')
st --op=host-settings-fill --key=working_directory --value=/elsewhere > /dev/null
st --op=host-settings-answer --value=cancel > /dev/null
o=$(st --op=state)
[ "$pre_wd" = /srv/work ] && [ "$(cat "$hd")" = "$before" ] && [ "$(m '[0]["drawn"]["caption"]')" = "online · folder: /srv/work · shell: /bin/bash" ] \
  && [ "$(jget "$o" 'd["live"]["host_last_answer"]')" = cancel ]
hl_check "H4 reopened, it shows the saved values; Cancel writes nothing" $? "pre=$pre_wd file=$(cat "$hd")"
st --op=host_settings --value=dev-on > /dev/null
st --op=host-settings-fill --key=working_directory --value= > /dev/null
st --op=host-settings-fill --key=shell --value='  ' > /dev/null
st --op=host-settings-answer --value=save > /dev/null
o=$(st --op=state)
[ "$(hd_entry dev-on)" = null ] && [ "$(m '[0]["drawn"]["caption"]')" = "online · folder: remote default · shell: remote default" ]
hl_check "H5 saving both fields empty clears the machine's defaults (back to remote default)" $? "file=$(cat "$hd" 2>/dev/null)"

# ---- a 401 empties the list and forgets the cache -------------------------
echo 401 > "$mode"
st --op=state --page=session > /dev/null
st --op=state --page=remote > /dev/null
hl_wait_for 15 fetched
o=$(st --op=state)
[ "$(jget "$o" 'd["live"]["remote"]["rows_drawn"]')" = 0 ] && [ ! -e "$cache" ]
hl_check "R8 a 401 from the relay empties the rows and deletes the remembered list" $? "rows=$(jget "$o" 'd["live"]["remote"]["rows_drawn"]') cache=$(ls "$cache" 2>&1)"

# ---- no agent: Settings never starts one; an unconfigured build ------------
# The app first, so its in-place recovery cannot start a fresh agent.
kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
hl_stop_agent
mkdir -p "$XDG_CONFIG_HOME/ghostty"
printf 'session-persistence = false\n' >> "$XDG_CONFIG_HOME/ghostty/config-debug.ghostty"
n_req=$(wc -l < "$reqs")
rm -f "$(hl_socket)"
GHOZTTY_RELAY_NO_CLIENT_ID=1 GHOSTTY_RELAY_TOKEN= hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
st --op=action > /dev/null
o=$(st --op=state --page=session)
[ "$(jget "$o" 'd["live"]["agent"]["running"]')" = false ] \
  && [ "$(jget "$o" 'd["live"]["agent"]["drawn"]["status"]')" = "Not running — it starts with the first terminal" ] \
  && [ "$(jget "$o" 'd["live"]["agent"]["drawn"]["dot"]')" = grey ] \
  && [ "$(jget "$o" 'd["live"]["agent"]["drawn"]["running_build"]')" = null ]
hl_check "N1 with no agent: 'Not running — it starts with the first terminal', grey dot, no Running build" $? "$(jget "$o" 'd["live"]["agent"]["drawn"]')"
[ "$(jget "$o" 'd["live"]["agent"]["drawn"]["socket"]')" = "$state/agent.sock" ]
hl_check "N2 Socket still names where the agent will listen (Mac's line)" $? "$(jget "$o" 'd["live"]["agent"]["drawn"]["socket"]')"
sleep 1
st --op=state --page=updates > /dev/null; st --op=state --page=session > /dev/null; sleep 1
# Only an agent of THIS harness counts (its state dir is under our private
# XDG_CONFIG_HOME); the distro may run others.
! hl_agent_pid > /dev/null && ! pgrep -f "ghoztty-agent.*$XDG_CONFIG_HOME/ghoztty/local-agent" > /dev/null
hl_check "N3 showing the page twice started no agent" $? "agent=$(hl_agent_pid) procs=$(pgrep -af "ghoztty-agent.*$XDG_CONFIG_HOME" | tr '\n' ' ')"
o=$(st --op=state --page=remote)
[ "$(jget "$o" 'd["live"]["remote"]["account"]')" = unconfigured ] \
  && [ "$(jget "$o" 'd["live"]["remote"]["drawn"]["title"]')" = "Not signed in" ] \
  && [ "$(jget "$o" 'd["live"]["remote"]["drawn"]["caption"]')" = "Remote machines aren’t set up in this build of Ghoztty." ] \
  && [ "$(jget "$o" 'd["live"]["remote"]["rows_drawn"]')" = 0 ] && [ "$(jget "$o" 'd["live"]["remote"]["fetching"]')" = false ]
r=$?
sleep 1
[ $r = 0 ] && [ "$(wc -l < "$reqs")" = "$n_req" ]
hl_check "U1 an unconfigured build: 'Not signed in', Mac's not-set-up caption, no rows, and no relay request" $? "$(jget "$o" 'd["live"]["remote"]') reqs=$(wc -l < "$reqs")/$n_req"

kill "$RELAY" 2>/dev/null
hl_finish "$L"
