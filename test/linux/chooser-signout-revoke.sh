#!/usr/bin/env bash
# chooser-signout-revoke.sh - T3676 (Linux L11a-4) acceptance: signing out
# on Linux revokes THIS machine's relay enrollment, says so when it cannot,
# offers "Sign Out Anyway", finishes an armed revocation by itself (network
# back, and at launch), and gives the machine back on the same account's
# sign-in. The Linux half of win32 T1421/T1424/T1425/T1426 and Mac
# RelayAccount.signOut.
#
#   R1     signed in through the chooser with this machine enrolled
#          (relay.env holds a device credential).
#   R2-R5  the relay answers whoami but cannot de-enroll: Sign Out keeps the
#          user SIGNED IN, says why, raises the "Sign Out Anyway" question,
#          and has already recorded the machine's relay name for its return.
#   R6     "Stay Signed In" changes nothing.
#   R7-R9  "Sign Out Anyway": signed out, the revocation armed, and the
#          signed-out row says the machine is still being removed.
#   R10-R11 the relay comes back: the armed revocation lands on its own
#          (POST /v1/agent/deenroll with this machine's credential), the
#          local credential goes, and the row's sentence with it.
#   R12-R13 the same account signs in: the machine is enrolled again under
#          its old name and relay.env holds the new credential.
#   R14-R16 an armed revocation left behind by a run that quit while the
#          relay was down is finished by the next launch.
#
# Run it ONLY through the wrapper (it builds the committed HEAD in the clone):
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\chooser-signout-revoke.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh)
# on a private session bus with no keyring (the account in its 0600 file);
# the relay is a python server on loopback and the harness plays the browser
# by GETting the redirect the app logged.
#
# NEGATIVE=1 makes the relay de-enroll even in its "down" mode, so the first
# sign-out revokes and R2-R5 must FAIL.
#
# Output: one PASS/FAIL line per check, then 'CHOOSER SIGNOUT REVOKE: ALL PASS'
# or 'CHOOSER SIGNOUT REVOKE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CHOOSER SIGNOUT REVOKE"

log=/tmp/chooser-signout-revoke-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "S2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"

mc() { hl_ipc machine-chooser "$@" 2>&1; }
q() { printf '%s' "$1" | python3 -I -c '
import json, sys
try: d = json.load(sys.stdin).get("data", {})
except Exception: d = {}
try: v = eval(sys.argv[1])
except Exception: v = ""
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))' "$2" 2>/dev/null; }

# ---- the fake relay ---------------------------------------------------------
# mode ok:         everything answers.
# mode nodeenroll: whoami answers (this machine is me@example.com's "This Box"),
#                  POST /v1/agent/deenroll is a 503 (NEGATIVE=1: a 204 anyway).
# Device credentials: dev-tok (the seeded one), dev-tok2 (the re-enrolled one).
relay_dir="$HL_RUNTIME/relay"; mkdir -p "$relay_dir"
mode="$relay_dir/mode"; reqs="$relay_dir/requests"
echo ok > "$mode"; : > "$reqs"
cat > "$relay_dir/relay.py" <<'PY'
import http.server, json, os, sys, time
d = sys.argv[1]
negative = os.environ.get("NEGATIVE") == "1"
def note(h, method, extra=""):
    with open(os.path.join(d, "requests"), "a") as f:
        f.write("%s %s %s%s\n" % (method, h.path, h.headers.get("Authorization", ""), extra))
def reply(h, code, obj=None):
    body = json.dumps(obj).encode() if obj is not None else b""
    h.send_response(code)
    h.send_header("Content-Type", "application/json")
    h.send_header("Content-Length", str(len(body)))
    h.end_headers()
    h.wfile.write(body)
DEVICES = ("Bearer dev-tok", "Bearer dev-tok2")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        note(self, "GET")
        auth = self.headers.get("Authorization", "")
        if self.path.startswith("/v1/agent/whoami"):
            if auth in DEVICES:
                return reply(self, 200, {"email": "me@example.com", "device_id": "dev-this", "name": "This Box"})
            return reply(self, 401, {"error": "unauthorized"})
        if auth != "Bearer tok-acct":
            return reply(self, 401, {"error": "unauthorized"})
        reply(self, 200, {"devices": [{"id": "dev-this", "name": "This Box", "hostname": "tb", "online": True}]})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        note(self, "POST", (" " + body) if body else "")
        mode = open(os.path.join(d, "mode")).read().strip()
        if self.path.startswith("/oauth/exchange"):
            return reply(self, 200, {"session_token": "tok-acct", "expiry": int(time.time()) + 3600, "email": "me@example.com"})
        if self.path.startswith("/oauth/signout"):
            return reply(self, 200, {})
        if self.path.startswith("/v1/agent/deenroll"):
            if mode == "nodeenroll" and not negative:
                return reply(self, 503, {"error": "unavailable"})
            return reply(self, 204)
        if self.path.startswith("/v1/client/devices"):
            return reply(self, 201, {"id": "dev-new", "name": "This Box", "token": "dev-tok2"})
        reply(self, 404, {"error": "not here"})
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
NEGATIVE="${NEGATIVE:-}" python3 -I "$relay_dir/relay.py" "$relay_dir" &
RELAY=$!
hl_wait_for 10 test -s "$relay_dir/port"
port=$(cat "$relay_dir/port")
hl_check "S3 the fake relay is up on loopback" $? "port=$port"
base="http://127.0.0.1:$port"

export SHELL=/bin/sh
export GHOSTTY_RELAY_BASE="$base"
export GHOSTTY_RELAY_TOKEN=
export GHOSTTY_GOOGLE_CLIENT_ID=chooser-signout-test.apps.googleusercontent.com
export GHOSTTY_OAUTH_AUTH_ENDPOINT="$base/authorize"
export GHOZTTY_ENROLL_NO_OPEN=1
export GHOSTTY_HOST_DEFAULTS="$HL_RUNTIME/host-defaults.json"
export XDG_CACHE_HOME="$HL_RUNTIME/cache"
# relay.env and the two records beside it (pending-revoke.json,
# suspended-enrollment.json) live here.
cfg="$XDG_CONFIG_HOME/ghoztty"; mkdir -p "$cfg"
relay_env="$cfg/relay.env"
pending="$cfg/pending-revoke.json"
suspended="$cfg/suspended-enrollment.json"
store="$HL_RUNTIME/acct/account.dat"; mkdir -p "$(dirname "$store")"

# A private session bus with no keyring daemon (the WSL default).
bus_dir="$HL_RUNTIME/bus"; mkdir -p "$bus_dir"; chmod 700 "$bus_dir"
bus_out=$(dbus-daemon --session --fork --nopidfile --print-address=1 --print-pid=1 --address="unix:path=$bus_dir/bus")
export DBUS_SESSION_BUS_ADDRESS=$(echo "$bus_out" | sed -n 1p)
BUS_PID=$(echo "$bus_out" | sed -n 2p)

stop_app() { if [ -n "${APP:-}" ]; then kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null; APP=""; fi; }
launch_app() {
    stop_app
    rm -f "$(hl_socket)"
    hl_launch APP env GHOSTTY_ACCOUNT_STORE="$store" "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
    hl_wait_for 30 test -S "$(hl_socket)"
}
play_browser() {
    local url
    url=$(grep -o 'open this URL to sign in: [^ ]*' "$APP_LOG" | tail -1 | sed 's/^open this URL to sign in: //')
    [ -n "$url" ] || return 1
    python3 -I - "$url" <<'PY'
import sys, urllib.parse, urllib.request
u = urllib.parse.urlparse(sys.argv[1])
qs = urllib.parse.parse_qs(u.query)
urllib.request.urlopen(qs["redirect_uri"][0] + "?" + urllib.parse.urlencode({"code": "code-acct", "state": qs["state"][0]}), timeout=10).read()
PY
}
url_count() { local n; n=$(grep -c 'open this URL to sign in:' "$APP_LOG" 2>/dev/null); echo "${n:-0}"; }
urls_over() { [ "$(url_count)" -gt "$1" ]; }
not_busy() { [ "$(q "$(mc)" 'd.get("account_busy")')" = none ]; }
confirm_up() { [ -n "$(q "$(mc)" 'd["account_confirm"]["heading"]')" ]; }
gone() { [ ! -e "$1" ]; }
reqs_line() { tr '\n' '|' < "$reqs"; }
# sign_in: press Sign in with Google..., play the browser, wait it out.
sign_in() {
    local before
    before=$(url_count)
    mc --op=account > /dev/null
    hl_wait_for 15 urls_over "$before" || return 1
    play_browser || return 1
    hl_wait_for 20 not_busy
}
not_revoked_title="Couldn't remove this machine from your account"
still_removing="This machine is still connected to me@example.com — still removing it."

# ---- R1: signed in, this machine enrolled ------------------------------------
printf 'RELAY_BASE=%s\nDEVICE_TOKEN=dev-tok\n' "$base" > "$relay_env"; chmod 600 "$relay_env"
launch_app
hl_check "S4 the app serves its socket" $? "$(tail -20 "$APP_LOG" 2>/dev/null | tr '\n' ' ')"
mc --op=open > /dev/null
sign_in
out=$(mc)
[ "$(q "$out" 'd["account"]')" = "Signed in as me@example.com" ] && grep -q '^DEVICE_TOKEN=dev-tok$' "$relay_env"
hl_check "R1 signed in through the chooser, with this machine enrolled (relay.env holds dev-tok)" $? "out=$out env=$(tr '\n' ' ' < "$relay_env")"

# ---- R2-R5: the relay cannot de-enroll ----------------------------------------
echo nodeenroll > "$mode"
: > "$reqs"
mc --op=account > /dev/null
hl_wait_for 20 not_busy
hl_wait_for 5 confirm_up
out=$(mc)
[ "$(q "$out" 'd["account"]')" = "Signed in as me@example.com" ] && [ -f "$store" ] && grep -q '^DEVICE_TOKEN=dev-tok$' "$relay_env" \
  && [ "$(q "$out" 'd["account_message"]')" = "Couldn't remove this machine from your account, so you're still signed in." ]
hl_check "R2 a sign-out the relay cannot complete keeps the user signed in and says why" $? "out=$out"
grep -q '^GET /v1/agent/whoami Bearer dev-tok$' "$reqs" && grep -q '^POST /v1/agent/deenroll Bearer dev-tok$' "$reqs" \
  && ! grep -q '^POST /oauth/signout' "$reqs"
hl_check "R3 it asked whose machine this is, tried the de-enroll with the machine's own credential, and did NOT end the session" $? "reqs=$(reqs_line)"
[ "$(q "$out" 'd["account_confirm"]["heading"]')" = "$not_revoked_title" ] \
  && case "$(q "$out" 'd["account_confirm"]["body"]')" in *"sign out anyway"*) true ;; *) false ;; esac
hl_check "R4 the Sign Out Anyway question is up, in win32's words" $? "confirm=$(q "$out" 'd["account_confirm"]')"
[ "$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get("machine_name",""), r.get("owner_email",""))' "$suspended" 2>/dev/null)" = "This Box me@example.com" ]
hl_check "R5 the machine's relay name and owner were recorded before the de-enroll, for its return" $? "suspended=$(cat "$suspended" 2>&1)"

: > "$reqs"
did=$(q "$(mc --op=account-confirm --value=stay)" 'd["did"]')
sleep 1
out=$(mc)
# The directory poll keeps GETting the device list; only a sign-out or a
# de-enroll would be the question's doing.
[ "$did" = true ] && [ "$(q "$out" 'd["account_confirm"]')" = "" ] && [ "$(q "$out" 'd["account_confirm_answer"]')" = stay ] \
  && [ "$(q "$out" 'd["account"]')" = "Signed in as me@example.com" ] && [ -f "$store" ] \
  && ! grep -q '^POST /v1/agent/deenroll\|^POST /oauth/signout' "$reqs"
hl_check "R6 Stay Signed In closes the question and changes nothing" $? "out=$out reqs=$(reqs_line)"

# ---- R7-R9: Sign Out Anyway ----------------------------------------------------
mc --op=account > /dev/null
hl_wait_for 20 not_busy
hl_wait_for 5 confirm_up
r=$?
mc --op=account-confirm --value=anyway > /dev/null
hl_wait_for 20 not_busy
out=$(mc)
[ $r = 0 ] && [ ! -e "$store" ] && grep -q '^POST /oauth/signout Bearer tok-acct$' "$reqs" \
  && [ "$(q "$out" 'd["account_message"]')" = "Signed out. This machine is still connected — Ghoztty will remove it when the relay answers." ]
hl_check "R7 Sign Out Anyway signs out (store gone, session revoked) and says the machine is still connected" $? "out=$out reqs=$(reqs_line)"
[ -f "$pending" ] && grep -q 'dev-tok' "$pending"
hl_check "R8 the revocation is ARMED, not abandoned (pending-revoke.json names dev-tok)" $? "pending=$(cat "$pending" 2>&1)"
[ "$(q "$out" 'd["account"]')" = "$still_removing" ] && [ "$(q "$out" 'd["account_visible"]')" = true ] \
  && [ "$(q "$out" 'd["account_button"]')" = "Sign in with Google…" ]
hl_check "R9 the signed-out row says the machine is still being removed, over Sign in with Google…" $? "out=$out"

# ---- R10-R11: the relay comes back ---------------------------------------------
echo ok > "$mode"
hl_wait_for 45 gone "$pending"
r=$?
grep -q '^POST /v1/agent/deenroll Bearer dev-tok$' "$reqs" && ! grep -q '^DEVICE_TOKEN=' "$relay_env" 2>/dev/null
hl_check "R10 the armed revocation lands by itself once the relay answers, and the local credential goes" $(( r | $? )) "pending=$(cat "$pending" 2>&1) env=$(tr '\n' ' ' < "$relay_env" 2>&1) reqs=$(reqs_line)"
row_clear() { [ "$(q "$(mc)" 'd["account"]')" != "$still_removing" ]; }
hl_wait_for 15 row_clear
hl_check "R11 ...and the row's 'still removing it' sentence goes with it" $? "out=$(mc)"

# ---- R12-R13: the same account signs back in -------------------------------------
: > "$reqs"
sign_in
out=$(mc)
grep -q '^POST /v1/client/devices Bearer tok-acct .*This Box' "$reqs"
hl_check "R12 the same account's sign-in enrolls this machine again under its old name" $? "reqs=$(reqs_line)"
[ "$(q "$out" 'd["account"]')" = "Signed in as me@example.com" ] && grep -q '^DEVICE_TOKEN=dev-tok2$' "$relay_env" && [ ! -e "$suspended" ]
hl_check "R13 ...relay.env holds the new credential and the suspension record is spent" $? "out=$out env=$(tr '\n' ' ' < "$relay_env" 2>&1) suspended=$(cat "$suspended" 2>&1)"

# ---- R14-R16: an armed revocation is finished at launch -----------------------------
echo nodeenroll > "$mode"
mc --op=account > /dev/null
hl_wait_for 20 not_busy
hl_wait_for 5 confirm_up
mc --op=account-confirm --value=anyway > /dev/null
hl_wait_for 20 not_busy
[ ! -e "$store" ] && [ -f "$pending" ] && grep -q 'dev-tok2' "$pending"
hl_check "R14 a second Sign Out Anyway arms the revocation for dev-tok2" $? "pending=$(cat "$pending" 2>&1)"
stop_app
echo ok > "$mode"
: > "$reqs"
[ -f "$pending" ]
hl_check "R15 the app quit with the revocation still owed" $? "pending=$(cat "$pending" 2>&1)"
launch_app
hl_wait_for 20 gone "$pending"
r=$?
grep -q '^POST /v1/agent/deenroll Bearer dev-tok2$' "$reqs" && grep -q 'pending revocation completed' "$APP_LOG"
hl_check "R16 the next launch finishes it: de-enrolled with dev-tok2, the record gone, said in the app's log" $(( r | $? )) "reqs=$(reqs_line) log=$(grep -i 'revocation' "$APP_LOG" | tail -3 | tr '\n' ' ')"

stop_app
kill "$BUS_PID" 2>/dev/null
kill "$RELAY" 2>/dev/null
hl_finish "$L"
