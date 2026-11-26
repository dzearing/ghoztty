#!/usr/bin/env bash
# chooser-account.sh - T3575 (Linux L12b) acceptance for the GTK machine
# chooser's account row: Sign in with Google... runs the real brokered
# sign-in (PKCE + loopback redirect, the code exchanged at the relay), the
# row flips to the email and Sign Out, and Sign Out ends it - plus the one
# Linux-only sentence, said exactly when the sign-in sits in the private
# 0600 file because no keyring runs.
#
#   U1-U3  an unconfigured build (no Google client id) has no Sign In
#          button; the row says so and the hint names the remedy.
#   A1-A12 phase A, a session bus with NO keyring daemon (WSL's default):
#          signed out -> Sign In -> busy -> the browser redirect -> signed
#          in, the account in a 0600 file and the row saying so, the relay's
#          machines listed with the new session; a reopened chooser reads
#          the store; Sign Out revokes the session at the relay and deletes
#          the file; a sign-in the relay refuses says why and stores nothing.
#   K1-K4  phase B, an unlocked gnome-keyring on the bus: the same sign-in
#          lands in the keyring, no file is written, and the row does NOT
#          carry the private-file sentence; Sign Out clears the item.
#
# Run it ONLY through the wrapper (it builds the committed HEAD in the clone):
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\chooser-account.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh)
# and on private session buses; the relay is a python server on loopback and
# the harness plays the browser by GETting the redirect the app logged. The
# keyring daemon is gnome-keyring extracted from its .deb (secret-store.sh's
# recipe), never installed.
#
# NEGATIVE=1 starts a keyring in phase A too, so the sign-in lands there:
# A5 (the 0600 file) and A6 (its sentence) must FAIL.
#
# Output: one PASS/FAIL line per check, then 'CHOOSER ACCOUNT: ALL PASS' or
# 'CHOOSER ACCOUNT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CHOOSER ACCOUNT"

log=/tmp/chooser-account-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "S2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"

# mc [op args]: the seam's reply. q <json> <python expr over d>: one value.
mc() { hl_ipc machine-chooser "$@" 2>&1; }
q() { printf '%s' "$1" | python3 -I -c '
import json, sys
try: d = json.load(sys.stdin).get("data", {})
except Exception: d = {}
try: v = eval(sys.argv[1])
except Exception: v = ""
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))' "$2" 2>/dev/null; }

# ---- the fake relay ---------------------------------------------------------
# POST /oauth/exchange -> a session for me@example.com (or 503 in mode "down")
# POST /oauth/signout  -> 200, logged with its bearer
# GET  anything        -> the device list (bearer logged)
relay_dir="$HL_RUNTIME/relay"; mkdir -p "$relay_dir"
mode="$relay_dir/mode"; reqs="$relay_dir/requests"
echo ok > "$mode"; : > "$reqs"
cat > "$relay_dir/relay.py" <<'PY'
import http.server, json, os, sys, time
d = sys.argv[1]
def note(h, method):
    with open(os.path.join(d, "requests"), "a") as f:
        f.write("%s %s %s\n" % (method, h.path, h.headers.get("Authorization", "")))
def reply(h, code, obj=None):
    body = json.dumps(obj).encode() if obj is not None else b""
    h.send_response(code)
    h.send_header("Content-Type", "application/json")
    h.send_header("Content-Length", str(len(body)))
    h.end_headers()
    h.wfile.write(body)
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        note(self, "GET")
        if self.headers.get("Authorization", "") != "Bearer tok-acct":
            return reply(self, 401, {"error": "unauthorized"})
        reply(self, 200, {"devices": [{"id": "dev-acct", "name": "Workstation", "hostname": "ws", "online": True}]})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        note(self, "POST")
        mode = open(os.path.join(d, "mode")).read().strip()
        if self.path.startswith("/oauth/exchange"):
            if mode == "down":
                return reply(self, 503, {"error": "unavailable"})
            return reply(self, 200, {"session_token": "tok-acct", "expiry": int(time.time()) + 3600, "email": "me@example.com"})
        if self.path.startswith("/oauth/signout"):
            return reply(self, 200, {})
        reply(self, 404, {"error": "not here"})
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$relay_dir/relay.py" "$relay_dir" &
RELAY=$!
hl_wait_for 10 test -s "$relay_dir/port"
port=$(cat "$relay_dir/port")
hl_check "S3 the fake relay is up on loopback" $? "port=$port"

export SHELL=/bin/sh
export GHOSTTY_RELAY_BASE="http://127.0.0.1:$port"
export GHOSTTY_RELAY_TOKEN=
export GHOSTTY_GOOGLE_CLIENT_ID=chooser-account-test.apps.googleusercontent.com
export GHOSTTY_OAUTH_AUTH_ENDPOINT="http://127.0.0.1:$port/authorize"
export GHOZTTY_ENROLL_NO_OPEN=1
export GHOSTTY_HOST_DEFAULTS="$HL_RUNTIME/host-defaults.json"
export XDG_CACHE_HOME="$HL_RUNTIME/cache"

# ---- private session buses (secret-store.sh's shape) ---------------------------
BUS_PID=""
start_bus() { # start_bus <name>
    local d="$HL_RUNTIME/bus-$1" out
    mkdir -p "$d"; chmod 700 "$d"
    out=$(dbus-daemon --session --fork --nopidfile --print-address=1 --print-pid=1 --address="unix:path=$d/bus")
    export DBUS_SESSION_BUS_ADDRESS=$(echo "$out" | sed -n 1p)
    BUS_PID=$(echo "$out" | sed -n 2p)
}
stop_bus() { [ -n "$BUS_PID" ] && kill "$BUS_PID" 2>/dev/null; BUS_PID=""; unset DBUS_SESSION_BUS_ADDRESS; }

stop_app() { if [ -n "${APP:-}" ]; then kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null; APP=""; fi; }
# launch_app <store> [VAR=value...]: (re)start the app on the current bus;
# env(1) applies the assignments and execs the app, so $APP is the app.
launch_app() {
    local store=$1; shift
    stop_app
    rm -f "$(hl_socket)"
    hl_launch APP env GHOSTTY_ACCOUNT_STORE="$store" "$@" "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
    hl_wait_for 30 test -S "$(hl_socket)"
}

# The extracted keyring daemon (secret-store.sh's recipe; never installed).
tools=/var/tmp/ghoztty-secret-store-tools
gkd="$tools/root/usr/bin/gnome-keyring-daemon"
if [ ! -x "$gkd" ]; then
    rm -rf "$tools"; mkdir -p "$tools/debs" "$tools/root"
    ( cd "$tools/debs" && apt-get download gnome-keyring libgck-1-0 libgcr-base-3-1 >/dev/null 2>&1 )
    for f in "$tools"/debs/*.deb; do dpkg-deb -x "$f" "$tools/root"; done
fi
gk_libs="$tools/root/usr/lib/x86_64-linux-gnu"
GKD=""
# start_keyring <check label>: an unlocked keyring on the current bus.
start_keyring() {
    printf 'ghoztty-test' | LD_LIBRARY_PATH="$gk_libs" "$gkd" --unlock --components=secrets --foreground \
        > "$HL_RUNTIME/gkd-$1.log" 2>&1 &
    GKD=$!
    local ready=1
    for _ in $(seq 1 50); do
        if dbus-send --session --print-reply --dest=org.freedesktop.DBus / \
            org.freedesktop.DBus.NameHasOwner string:org.freedesktop.secrets 2>/dev/null | grep -q 'boolean true'; then
            ready=0; break
        fi
        sleep 0.1
    done
    return $ready
}
stop_keyring() { [ -n "$GKD" ] && kill "$GKD" 2>/dev/null; GKD=""; }

# play_browser: answer the newest sign-in URL in the app log the way Google's
# consent screen would - GET its redirect_uri with a code and its state.
play_browser() {
    local url
    url=$(grep -o 'open this URL to sign in: [^ ]*' "$APP_LOG" | tail -1 | sed 's/^open this URL to sign in: //')
    [ -n "$url" ] || return 1
    python3 -I - "$url" <<'PY'
import sys, urllib.parse, urllib.request
u = urllib.parse.urlparse(sys.argv[1])
qs = urllib.parse.parse_qs(u.query)
red = qs["redirect_uri"][0]
state = qs["state"][0]
urllib.request.urlopen(red + "?" + urllib.parse.urlencode({"code": "code-acct", "state": state}), timeout=10).read()
PY
}
url_count() { local n; n=$(grep -c 'open this URL to sign in:' "$APP_LOG" 2>/dev/null); echo "${n:-0}"; }
urls_over() { [ "$(url_count)" -gt "$1" ]; }
not_busy() { [ "$(q "$(mc)" 'd.get("account_busy")')" = none ]; }
lists_device() { [ "$(q "$(mc)" '[m["id"] for m in d["machines"] if m["id"]=="dev-acct"][0]')" = dev-acct ]; }
mode_of() { stat -c %a "$1" 2>/dev/null; }

# ---- U: an unconfigured build -------------------------------------------------
start_bus U
launch_app "$HL_RUNTIME/acct-u.dat" GHOZTTY_RELAY_NO_CLIENT_ID=1
hl_check "S4 the app serves its socket" $? "$(tail -20 "$APP_LOG" 2>/dev/null | tr '\n' ' ')"
mc --op=open > /dev/null
out=$(mc)
[ "$(q "$out" 'd["account_button"]')" = "" ] && [ "$(q "$out" 'd["account"]')" = "Google sign-in isn't set up in this build" ]
hl_check "U1 no client id: no Sign In button, and the row says sign-in isn't set up" $? "out=$out"
case "$(q "$out" 'd["account_tooltip"]')" in *GHOSTTY_GOOGLE_CLIENT_ID*relay-oidc-setup.md*) r=0 ;; *) r=1 ;; esac
hl_check "U2 the hover names the remedy (the client id and the setup doc)" $r "tooltip=$(q "$out" 'd["account_tooltip"]')"
out=$(mc --op=account)
[ "$(q "$out" 'd["did"]')" = false ] && [ "$(q "$out" 'd["account_busy"]')" = none ] && [ "$(url_count)" = 0 ]
hl_check "U3 there is nothing to press: no flow starts" $? "out=$out urls=$(url_count)"
stop_app
stop_bus

# ---- A: no keyring daemon - the private file -------------------------------------
start_bus A
# NEGATIVE=1: a keyring IS running, so the account lands there and A5/A6
# (the file and its sentence) must fail.
[ "${NEGATIVE:-}" = 1 ] && start_keyring negative
store="$HL_RUNTIME/acct-a/account.dat"; mkdir -p "$(dirname "$store")"
launch_app "$store"
mc --op=open > /dev/null
out=$(mc)
[ "$(q "$out" 'd["account_button"]')" = "Sign in with Google…" ] && [ "$(q "$out" 'd["account_visible"]')" = false ] \
  && [ "$(q "$out" 'd["account_store_note"]')" = "" ] && [ "$(q "$out" 'len(d["machines"])')" = 1 ]
hl_check "A1 signed out: Mac's row is the Sign in with Google… button alone, and only Local is listed" $? "out=$out"

out=$(mc --op=account)
[ "$(q "$out" 'd["did"]')" = true ] && [ "$(q "$out" 'd["account_busy"]')" = sign_in ] \
  && [ "$(q "$out" 'd["account_button"]')" = "Signing in…" ] && [ "$(q "$out" 'd["account_button_sensitive"]')" = false ] \
  && [ "$(q "$out" 'd["account"]')" = "Finish signing in in your browser…" ]
hl_check "A2 Sign In: the row waits on the browser and cannot be pressed twice" $? "out=$out"
hl_wait_for 15 urls_over 0
hl_check "A3 the app logged the Google sign-in URL (the browser it would open)" $? "urls=$(url_count)"

play_browser
hl_wait_for 20 not_busy
out=$(mc)
[ "$(q "$out" 'd["account"]')" = "Signed in as me@example.com" ] && [ "$(q "$out" 'd["account_button"]')" = "Sign Out" ] \
  && [ "$(q "$out" 'd["account_button_sensitive"]')" = true ] && grep -q '^POST /oauth/exchange' "$reqs"
hl_check "A4 the redirect lands: the code is exchanged at the relay and the row reads the email over Sign Out" $? "out=$out reqs=$(tr '\n' '|' < "$reqs")"
[ -f "$store" ] && [ "$(mode_of "$store")" = 600 ]
hl_check "A5 with no keyring the account is in the store file, mode 0600" $? "store=$(ls -l "$store" 2>&1)"
note=$(q "$out" 'd["account_store_note"]')
[ "$note" = "No keyring is running, so your sign-in is kept in a private file only you can read ($store)." ]
hl_check "A6 the row says the sign-in is kept in a private file because no keyring runs, and names it" $? "note=$note"
hl_wait_for 15 lists_device
r=$?
grep -q '^GET .* Bearer tok-acct$' "$reqs"
hl_check "A7 the relay's machines are listed with the new session" $(( r | $? )) "out=$(mc) reqs=$(tr '\n' '|' < "$reqs")"

mc --op=close > /dev/null
mc --op=open > /dev/null
out=$(mc)
[ "$(q "$out" 'd["account"]')" = "Signed in as me@example.com" ] && [ -n "$(q "$out" 'd["account_store_note"]')" ]
hl_check "A8 a reopened chooser reads the store: still signed in, still says where" $? "out=$out"

mc --op=account > /dev/null
hl_wait_for 20 not_busy
out=$(mc)
grep -q '^POST /oauth/signout Bearer tok-acct$' "$reqs"
r=$?
[ $r = 0 ] && [ ! -e "$store" ] && [ "$(q "$out" 'd["account_button"]')" = "Sign in with Google…" ]
hl_check "A9 Sign Out revokes the session at the relay, deletes the file, and offers Sign In again" $? "out=$out store=$(ls -l "$store" 2>&1)"
[ "$(q "$out" 'd["account_message"]')" = "Signed out." ] && [ "$(q "$out" 'd["account_store_note"]')" = "" ] \
  && [ "$(q "$out" 'len(d["machines"])')" = 1 ]
hl_check "A10 it says 'Signed out.', drops the private-file line and the account's machines" $? "out=$out"

echo down > "$mode"
before=$(url_count)
mc --op=account > /dev/null
hl_wait_for 15 urls_over "$before"
play_browser
hl_wait_for 20 not_busy
out=$(mc)
msg=$(q "$out" 'd["account_message"]')
[ -n "$msg" ] && [ "$msg" != "Signed out." ] && [ "$(q "$out" 'd["account_button"]')" = "Sign in with Google…" ] && [ ! -e "$store" ]
hl_check "A11 a sign-in the relay refuses says why, stays signed out and stores nothing" $? "msg=$msg out=$out"
echo ok > "$mode"
grep -q 'machine chooser: sign_in failed' "$APP_LOG"
hl_check "A12 ...and the failure is in the log" $? "$(grep 'machine chooser' "$APP_LOG" | tail -3 | tr '\n' ' ')"
mc --op=close > /dev/null
stop_app
stop_keyring
stop_bus

# ---- B: an unlocked keyring - no file, no file sentence ---------------------------
start_bus B
start_keyring B
hl_check "K1 an unlocked gnome-keyring owns org.freedesktop.secrets on the private bus" $? "$(tail -5 "$HL_RUNTIME/gkd-B.log" 2>/dev/null | tr '\n' ' ')"
storeb="$HL_RUNTIME/acct-b/account.dat"; mkdir -p "$(dirname "$storeb")"
launch_app "$storeb"
mc --op=open > /dev/null
before=$(url_count)
mc --op=account > /dev/null
hl_wait_for 15 urls_over "$before"
play_browser
hl_wait_for 20 not_busy
out=$(mc)
[ "$(q "$out" 'd["account"]')" = "Signed in as me@example.com" ] && [ ! -e "$storeb" ]
hl_check "K2 with a keyring the sign-in lands there: signed in, and no file written" $? "out=$out file=$(ls -l "$storeb" 2>&1)"
[ "$(q "$out" 'd["account_store_note"]')" = "" ]
hl_check "K3 ...and the row does not carry the private-file sentence" $? "note=$(q "$out" 'd["account_store_note"]')"
mc --op=account > /dev/null
hl_wait_for 20 not_busy
mc --op=close > /dev/null
mc --op=open > /dev/null
out=$(mc)
[ "$(q "$out" 'd["account_button"]')" = "Sign in with Google…" ] && [ ! -e "$storeb" ]
hl_check "K4 Sign Out clears the keyring item: a reopened chooser is signed out" $? "out=$out"
stop_app
stop_keyring
stop_bus

kill "$RELAY" 2>/dev/null
hl_finish "$L"
