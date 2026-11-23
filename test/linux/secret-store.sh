#!/usr/bin/env bash
# secret-store.sh - T3341 (Linux L12) acceptance: the relay account store on
# Linux keeps the signed-in session in the Secret Service (libsecret) when a
# keyring daemon answers, and in a mode-0600 file when none does (the WSL
# default).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\secret-store.sh
#
# It tests the committed HEAD in ~/ghoztty-l (-Repo clone, the default).
#
# Nothing here touches the person's own keyring or installs a package:
#   * each phase runs on a PRIVATE session bus (its own dbus-daemon), with
#     XDG_DATA_HOME / XDG_RUNTIME_DIR pointed into a scratch dir;
#   * the keyring daemon is gnome-keyring EXTRACTED from its .deb (apt-get
#     download + dpkg-deb -x into /var/tmp, cached), never installed - an
#     installed gnome-keyring would register org.freedesktop.secrets on the
#     user's own session bus and change how every app in the distro stores
#     secrets.
#
# Phases (each is one opt-in unit test in src/remote/relay_account.zig, run
# with -Dtest-filter; the test appends a line to a marker file when it RAN, so
# a skip can never read as a pass):
#   A  absent : libsecret loads, no daemon on the bus -> the account goes to a
#               0600 file, reads back, deletes.
#   B  keyring: gnome-keyring-daemon (secrets component, unlocked) on the bus
#               -> stored in the keyring, no file written, read back, cleared.
#
# Output: 'CHECK <name> PASS|FAIL' lines, then 'SECRET STORE: ALL PASS' or
# 'SECRET STORE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
fails=0
check() { # check <name> <cond-exit-code> [detail]
    if [ "$2" = 0 ]; then echo "CHECK $1 PASS${3:+ - $3}"; else echo "CHECK $1 FAIL${3:+ - $3}"; fails=$((fails+1)); fi
}
bus_pid=""
gk_pid=""
stop_bus() {
    [ -n "$gk_pid" ] && kill "$gk_pid" 2>/dev/null
    [ -n "$bus_pid" ] && kill "$bus_pid" 2>/dev/null
    gk_pid=""; bus_pid=""
}
finish() {
    stop_bus
    if [ $fails = 0 ]; then echo "SECRET STORE: ALL PASS"; exit 0; fi
    echo "SECRET STORE: $fails FAILURE(S)"; exit 1
}

work=$(mktemp -d /tmp/secret-store.XXXXXX)
echo "SECRET STORE at $(git rev-parse --short HEAD 2>/dev/null || echo '?') work=$work"

# libsecret itself is a WebKitGTK dependency, so setup-distro.sh already has it.
[ -e /usr/lib/x86_64-linux-gnu/libsecret-1.so.0 ] || [ -e /usr/lib/libsecret-1.so.0 ]
check libsecret-present $? "libsecret-1.so.0 on the loader path"

# --- the extracted keyring daemon -----------------------------------------
tools=/var/tmp/ghoztty-secret-store-tools
gkd="$tools/root/usr/bin/gnome-keyring-daemon"
if [ ! -x "$gkd" ]; then
    rm -rf "$tools"; mkdir -p "$tools/debs" "$tools/root"
    ( cd "$tools/debs" && apt-get download gnome-keyring libgck-1-0 libgcr-base-3-1 >/dev/null 2>&1 )
    for f in "$tools"/debs/*.deb; do dpkg-deb -x "$f" "$tools/root"; done
fi
[ -x "$gkd" ]
check keyring-daemon-extracted $? "$gkd"
gk_libs="$tools/root/usr/lib/x86_64-linux-gnu"
missing=$(LD_LIBRARY_PATH="$gk_libs" ldd "$gkd" 2>/dev/null | grep -c "not found")
[ "$missing" = 0 ]
check keyring-daemon-links $? "$missing unresolved libraries"

start_bus() { # start_bus <phase>
    local d="$work/$1"
    mkdir -p "$d/data" "$d/run"; chmod 700 "$d/run"
    export XDG_DATA_HOME="$d/data" XDG_RUNTIME_DIR="$d/run"
    local out
    out=$(dbus-daemon --session --fork --nopidfile --print-address=1 --print-pid=1 \
        --address="unix:path=$d/run/bus")
    export DBUS_SESSION_BUS_ADDRESS=$(echo "$out" | sed -n 1p)
    bus_pid=$(echo "$out" | sed -n 2p)
}

run_filter() { # run_filter <phase> <mode> <filter>
    local mark="$work/$1.mark"
    : > "$mark"
    GHOZTTY_TEST_SECRET_SERVICE="$2" GHOZTTY_TEST_SECRET_SERVICE_MARK="$mark" \
        zig build test -Dapp-runtime=none -Doptimize=Debug "-Dtest-filter=$3" \
        > "$work/$1.log" 2>&1
    echo $?
}

# --- phase A: no daemon ----------------------------------------------------
start_bus A
rc=$(run_filter A absent "real store falls back")
check A-test-passed "$rc" "zig build test exit $rc (log $work/A.log)"
grep -q '^ABSENT ' "$work/A.mark"
check A-test-ran $? "$(cat "$work/A.mark")"
leftover=$(find "$XDG_DATA_HOME" -name 'account*.dat' 2>/dev/null | wc -l)
[ "$leftover" = 0 ]
check A-no-credential-left $? "$leftover account file(s) under the scratch data home"
stop_bus

# --- phase B: an unlocked keyring on the bus ---------------------------------
start_bus B
printf 'ghoztty-test' | LD_LIBRARY_PATH="$gk_libs" "$gkd" --unlock --components=secrets \
    --foreground > "$work/B.gkd.log" 2>&1 &
gk_pid=$!
# The daemon owns org.freedesktop.secrets once it is ready.
ready=1
for _ in $(seq 1 50); do
    if dbus-send --session --print-reply --dest=org.freedesktop.DBus / \
        org.freedesktop.DBus.NameHasOwner string:org.freedesktop.secrets 2>/dev/null | grep -q 'boolean true'; then
        ready=0; break
    fi
    sleep 0.1
done
check B-keyring-on-bus $ready "org.freedesktop.secrets owned (daemon log $work/B.gkd.log)"
rc=$(run_filter B 1 "real Secret Service round-trips")
check B-test-passed "$rc" "zig build test exit $rc (log $work/B.log)"
grep -q '^ROUNDTRIP ' "$work/B.mark"
check B-roundtrip-ran $? "$(grep '^ROUNDTRIP' "$work/B.mark")"
grep -q '^CLEAR ' "$work/B.mark"
check B-clear-ran $? "$(grep '^CLEAR' "$work/B.mark")"
stop_bus

if [ $fails != 0 ]; then
    for f in "$work"/A.log "$work"/B.log "$work"/B.gkd.log; do
        [ -s "$f" ] && { echo "--- tail $f"; tail -30 "$f"; }
    done
fi
finish
