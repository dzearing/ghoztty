#!/usr/bin/env bash
# package-release.sh - L14b (T3578) acceptance for the RELEASE Linux packages:
#
#   R  package.sh builds a ReleaseFast tarball that carries the release names
#      (app id com.dzearing.ghoztty, x-scheme-handler/ghoztty) and its private
#      libgtk4-layer-shell.so, with a RUNPATH that does not depend on the
#      directory it is started from.
#   I  install.sh installs it WITHOUT --dev into a throwaway HOME, and the
#      installed copy runs from anywhere.
#   S  side by side with a dev (zig-out Debug) build in one private headless
#      Weston and one private session bus: a ghoztty:// link handed to the
#      installed release binary reaches the release app and never the dev
#      build, whose pane of the same name stays untouched; each answers only on
#      its own socket and its own D-Bus name.
#   D  package-deb.sh turns the same tarball into a .deb: /usr layout, Exec
#      lines at /usr/bin/ghoztty, Depends from dpkg-shlibdeps that apt can
#      satisfy here (simulated), a Debug tarball refused; installed with
#      `dpkg --root` into a throwaway root (never this distro's /usr) it runs,
#      and `dpkg -r` takes every file back out.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\package-release.sh
#
# Output: one PASS/FAIL line per check, then 'PACKAGE RELEASE: ALL PASS' or
# 'PACKAGE RELEASE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PACKAGE RELEASE"

work=$(mktemp -d /tmp/ghoztty-pkgrel.XXXXXX)
cleanup_work() {
    # The installed release app and its agent run from $work: reap them first.
    pkill -KILL -f "^$work/" 2>/dev/null
    rm -rf "$work"
}
app_id=com.dzearing.ghoztty
scheme=ghoztty

# --- R: the release tarball --------------------------------------------------

out=$(PKG_OPTIMIZE=ReleaseFast PKG_OUT="$work/out" bash scripts/linux/package.sh 2>&1); rc=$?
tarball=$(echo "$out" | sed -n 's/^PACKAGE OK //p')
[ $rc = 0 ] && [ -f "$tarball" ]
hl_check "R1 package.sh builds a ReleaseFast tarball" $? "rc=$rc $(echo "$out" | tail -3 | tr '\n' ' ')"
[ -f "$tarball" ] || { cleanup_work; hl_finish "$L"; }
case "$tarball" in *ghoztty-linux-*-release-*.tar.gz) true ;; *) false ;; esac
hl_check "R2 the tarball is named for a release build" $? "$tarball"

mkdir -p "$work/unpack" && tar -C "$work/unpack" -xzf "$tarball"
pkg="$work/unpack/ghoztty"
d="$pkg/share/applications/$app_id.desktop"
[ -f "$d" ] && grep -q "^MimeType=x-scheme-handler/$scheme;" "$d" && grep -q '^Name=Ghoztty$' "$d" &&
    [ ! -e "$pkg/share/applications/$app_id-debug.desktop" ] &&
    grep -q '^mode=release$' "$pkg/.package-info"
hl_check "R3 it carries the release app id, Name and x-scheme-handler/$scheme" $? "$(ls "$pkg/share/applications" 2>&1 | tr '\n' ' ') $(grep -h -E '^(Name|MimeType)=' "$d" 2>&1 | tr '\n' ' ')"
out=$(desktop-file-validate "$d" 2>&1)
hl_check "R4 desktop-file-validate accepts the release entry" $? "$out"
rp=$(readelf -d "$pkg/bin/ghoztty" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')
[ "$rp" = '$ORIGIN/../lib/ghoztty' ] && [ -f "$pkg/lib/ghoztty/libgtk4-layer-shell.so" ]
hl_check "R5 bin/ghoztty finds its private libgtk4-layer-shell.so through \$ORIGIN, not .zig-cache" $? "runpath=$rp lib=$(ls "$pkg/lib/ghoztty" 2>&1)"
[ ! -e "$pkg/include" ] && [ -z "$(ls "$pkg/lib" | grep -v '^ghoztty$')" ] && [ ! -e "$pkg/share/pkgconfig" ]
hl_check "R6 the build's developer artifacts (include/, libghostty-vt, pkg-config) are left out" $? "lib=$(ls "$pkg/lib" | tr '\n' ' ') $(ls -d "$pkg/include" "$pkg/share/pkgconfig" 2>&1 | tr '\n' ' ')"
out=$(cd / && "$pkg/bin/ghoztty" +version 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'build mode *: \.ReleaseFast'
hl_check "R7 the unpacked binary runs from / and is a ReleaseFast build" $? "rc=$rc $(echo "$out" | grep -E 'error|build mode' | head -2 | tr '\n' ' ')"

# --- I: install it, no --dev ---------------------------------------------------

home="$work/home"
mkdir -p "$home"
out=$(env -i PATH="$PATH" HOME="$home" "$pkg/install.sh" 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | tail -1 | grep -q "^INSTALL OK $app_id "
hl_check "I1 install.sh installs a release package without --dev" $? "rc=$rc out=$out"
rbin="$home/.local/opt/ghoztty/bin/ghoztty"
out=$(env -i PATH="$PATH" HOME="$home" XDG_DATA_DIRS="$home/.local/share:/usr/share" xdg-mime query default "x-scheme-handler/$scheme" 2>&1)
[ "$out" = "$app_id.desktop" ] && grep -q "^Exec=$rbin --gtk-single-instance=true %u$" "$home/.local/share/applications/$app_id.desktop"
hl_check "I2 the installed release entry is the $scheme:// handler and runs the installed binary" $? "out=$out"
out=$(cd / && "$home/.local/bin/ghoztty" +version 2>&1); rc=$?
[ $rc = 0 ]
hl_check "I3 the installed binary runs from / through ~/.local/bin" $? "rc=$rc $(echo "$out" | head -2 | tr '\n' ' ')"

# --- S: side by side with a dev build -----------------------------------------

log=/tmp/package-release-debug-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 the dev (Debug) build builds" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || { cleanup_work; hl_finish "$L"; }

hl_start
hl_check "S2 a private headless Weston is up" $?
trap 'hl_stop; cleanup_work' EXIT
dev=$(hl_ghoztty) || { cleanup_work; hl_finish "$L"; }
dsock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
rsock="$XDG_RUNTIME_DIR/ghostty-$(id -u).sock"

export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/test-bus"
hl_launch BUS dbus-daemon --session --nofork --nopidfile --address="$DBUS_SESSION_BUS_ADDRESS"
hl_wait_for 10 test -S "$XDG_RUNTIME_DIR/test-bus"
hl_check "S3 a private session bus is up" $?
export SHELL=/bin/sh GHOZTTY_URL_SCHEME_QUIET=1
unset GHOZTTY_IPC_SOCKET GHOZTTY_PANE_ID

# list <bin>: window|pane:focused,... for every window the app at <bin> shows.
list() {
    "$1" +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    leaves = [l for t in w["tabs"] for l in walk(t["splits"])]
    print("%s|%s" % (w.get("target") or "", ",".join("%s:%d" % (l.get("name", ""), int(bool(l.get("focused")))) for l in leaves)))
' 2>/dev/null
}
focused() { list "$1" | awk -F'|' -v w="$2" '$1 == w { print $2 }' | tr ',' '\n' | grep -q "^$3:1$"; }
leaves() { list "$1" | awk -F'|' -v w="$2" '$1 == w { print $2 }' | tr ',' '\n' | grep -c .; }
two_leaves() { [ "$(leaves "$1" "$2")" = 2 ]; }
owner() {
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner "$1" 2>&1 | grep -q true
}

# The dev build: window dw, its first pane focused, a second pane named "fa".
hl_launch DEV "$dev" --gtk-single-instance=true
hl_wait_for 30 test -S "$dsock"
hl_check "S4 the dev build serves the debug socket" $?
"$dev" +new-window --target=dw > /dev/null 2>&1
"$dev" +split --target=dw --name=fa > /dev/null 2>&1
hl_wait_for 10 two_leaves "$dev" dw
"$dev" +new-window --target=dw > /dev/null 2>&1     # idempotent: focuses dw
sleep 1
dev_before=$(list "$dev" | tr '\n' ' ')
! focused "$dev" dw fa && [ "$(leaves "$dev" dw)" = 2 ]
hl_check "S5 dev window dw holds pane fa, which does not have the focus" $? "$dev_before"

# A release link to "fa" while only the dev build runs: nothing release-side
# answers, so it is a miss - the dev build's "fa" is not its to focus.
out=$(timeout 20 "$rbin" --gtk-single-instance=true "$scheme://focus/fa" 2>&1); rc=$?
sleep 1
[ $rc = 1 ] && ! focused "$dev" dw fa && [ ! -S "$rsock" ]
hl_check "S6 with only the dev build up, '$scheme://focus/fa' through the release binary exits 1 and leaves the dev pane alone" $? "rc=$rc out=$(echo "$out" | tail -2 | tr '\n' ' ') dev=$(list "$dev" | tr '\n' ' ')"
owner "$app_id-debug" && ! owner "$app_id"
hl_check "S7 the dev build owns only $app_id-debug on the bus, never $app_id" $?

# Now the installed release app beside it, from its own HOME.
hl_launch REL env HOME="$home" "$rbin" --gtk-single-instance=true
hl_wait_for 30 test -S "$rsock"
hl_check "S8 the installed release app serves the release socket" $? "$(tail -3 "$REL_LOG" | tr '\n' ' ')"
"$rbin" +new-window --target=rw > /dev/null 2>&1
"$rbin" +split --target=rw --name=rb > /dev/null 2>&1
hl_wait_for 10 two_leaves "$rbin" rw
"$rbin" +new-window --target=rw > /dev/null 2>&1
sleep 1
! focused "$rbin" rw rb && ! list "$rbin" | grep -q '^dw|' && ! list "$dev" | grep -q '^rw|'
hl_check "S9 release window rw holds pane rb; neither app lists the other's window" $? "rel=$(list "$rbin" | tr '\n' ' ') dev=$(list "$dev" | tr '\n' ' ')"
owner "$app_id"
hl_check "S10 the release app owns $app_id on the bus" $?

out=$(timeout 20 "$rbin" --gtk-single-instance=true "$scheme://focus/rb" 2>&1); rc=$?
hl_wait_for 10 focused "$rbin" rw rb
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ]
hl_check "S11 '$scheme://focus/rb' through the release binary exits 0 and focuses the release pane" $? "rc=$rc out=$out rel=$(list "$rbin" | tr '\n' ' ')"

out=$(timeout 20 "$rbin" --gtk-single-instance=true "$scheme://focus/fa" 2>&1); rc=$?
sleep 1
[ $rc = 1 ] && ! focused "$dev" dw fa
hl_check "S12 with both up, '$scheme://focus/fa' (a dev-only name) is still a miss and the dev pane keeps no focus" $? "rc=$rc dev=$(list "$dev" | tr '\n' ' ')"

out=$(gdbus call --session --dest "$app_id" --object-path /com/dzearing/ghoztty \
    --method org.freedesktop.Application.Open "['$scheme://focus/rb']" "{}" 2>&1); rc=$?
[ $rc = 0 ] && focused "$rbin" rw rb && [ "$(list "$dev" | tr '\n' ' ')" = "$dev_before" ]
hl_check "S13 D-Bus Open on $app_id lands in the release app; the dev build's layout and focus are as they were" $? "rc=$rc out=$out dev_before=$dev_before dev_now=$(list "$dev" | tr '\n' ' ')"

grep -q "panic\|reached unreachable" "$DEV_LOG" "$REL_LOG"
[ $? != 0 ] && kill -0 "$DEV" 2>/dev/null && kill -0 "$REL" 2>/dev/null
hl_check "S14 neither app panicked, and both are still running" $? "$(grep -h -m3 'panic\|unreachable' "$DEV_LOG" "$REL_LOG")"
hl_stop

# --- D: the .deb -----------------------------------------------------------------

out=$(PKG_OUT="$work/deb" bash scripts/linux/package-deb.sh "$tarball" 2>&1); rc=$?
deb=$(echo "$out" | sed -n 's/^DEB OK //p')
[ $rc = 0 ] && [ -f "$deb" ]
hl_check "D1 package-deb.sh builds a .deb from the release tarball" $? "rc=$rc $(echo "$out" | tail -4 | tr '\n' ' ')"
[ -f "$deb" ] || { cleanup_work; hl_finish "$L"; }

ctl=$(dpkg-deb -f "$deb" Package Version Architecture Depends 2>&1)
dep=$(dpkg-deb -f "$deb" Depends)
echo "$ctl" | grep -q '^Package: ghoztty$' && echo "$ctl" | grep -q "^Architecture: $(dpkg --print-architecture)$" &&
    echo "$dep" | grep -q 'libgtk-4-1' && echo "$dep" | grep -q 'libadwaita-1-0' &&
    echo "$dep" | grep -q 'libwebkitgtk-6.0-4' && echo "$dep" | grep -q 'libc6' &&
    dpkg --compare-versions "$(dpkg-deb -f "$deb" Version)" gt 1.4.0
hl_check "D2 its control names ghoztty, this arch, and Depends on GTK4, libadwaita, WebKitGTK 6 and libc" $? "$(echo "$ctl" | tr '\n' ' ')"

c="$work/contents"
dpkg-deb -c "$deb" | awk '{print $6}' | sed 's#^\./#/#' > "$c"
grep -qx /usr/bin/ghoztty "$c" && grep -qx /usr/bin/ghoztty-agent "$c" &&
    grep -qx /usr/lib/ghoztty/libgtk4-layer-shell.so "$c" &&
    grep -qx "/usr/share/applications/$app_id.desktop" "$c" &&
    ! grep -Eq '^/(opt|home|root|tmp)|/install\.sh$|/\.package-info$|/include/' "$c"
hl_check "D3 it installs under /usr only: bin, lib/ghoztty, share - no install.sh, no build metadata" $? "$(grep -E '^/(opt|home|root|tmp)|install\.sh|package-info|include/' "$c" | head -5 | tr '\n' ' ')"

x="$work/deb-x"
dpkg-deb -x "$deb" "$x"
grep -q '^Exec=/usr/bin/ghoztty --gtk-single-instance=true %u$' "$x/usr/share/applications/$app_id.desktop" &&
    grep -q '^TryExec=/usr/bin/ghoztty$' "$x/usr/share/applications/$app_id.desktop" &&
    grep -q '^Exec=/usr/bin/ghoztty ' "$x/usr/share/dbus-1/services/$app_id.service" &&
    grep -q '^ExecStart=/usr/bin/ghoztty ' "$x/usr/share/systemd/user/app-$app_id.service" &&
    desktop-file-validate "$x/usr/share/applications/$app_id.desktop" > /dev/null 2>&1
hl_check "D4 the entry, D-Bus service and systemd unit run /usr/bin/ghoztty, and the entry validates" $? "$(grep -h -E '^(Try)?Exec(Start)?=' "$x/usr/share/applications/$app_id.desktop" "$x/usr/share/dbus-1/services/$app_id.service" "$x/usr/share/systemd/user/app-$app_id.service" 2>&1 | tr '\n' ' ')"
[ -z "$(dpkg-deb -c "$deb" | awk '$2 != "root/root"')" ]
hl_check "D5 every file is owned root/root" $? "$(dpkg-deb -c "$deb" | awk '$2 != "root/root"' | head -3)"

clash=$(while read -r f; do [ -f "$x$f" ] && printf '%s\n' "$f"; done < "$c" | xargs -r dpkg -S 2>/dev/null | grep -v '^ghoztty:')
[ -z "$clash" ]
hl_check "D6 no file in it is already owned by a package installed here" $? "$clash"
out=$(apt-get install --simulate "$deb" 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q '^Inst ghoztty '
hl_check "D7 apt can satisfy it on this distro (simulated - nothing is installed)" $? "rc=$rc $(echo "$out" | tail -3 | tr '\n' ' ')"

# A throwaway dpkg root: its own database, so this distro's is never touched.
r="$work/droot"
mkdir -p "$r/var/lib/dpkg/updates" "$r/var/lib/dpkg/info" "$r/var/lib/dpkg/triggers"
: > "$r/var/lib/dpkg/status"; : > "$r/var/lib/dpkg/available"
out=$(dpkg --root="$r" --force-script-chrootless --force-depends --force-not-root -i "$deb" 2>&1); rc=$?
st=$(dpkg-query --admindir="$r/var/lib/dpkg" -W -f='${Status}' ghoztty 2>&1)
[ $rc = 0 ] && [ "$st" = "install ok installed" ] && [ -x "$r/usr/bin/ghoztty" ]
hl_check "D8 dpkg installs it into a throwaway root" $? "rc=$rc status=$st $(echo "$out" | tail -3 | tr '\n' ' ')"
out=$(cd / && "$r/usr/bin/ghoztty" +version 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'build mode *: \.ReleaseFast'
hl_check "D9 the dpkg-installed binary runs (it finds /usr/lib/ghoztty through \$ORIGIN)" $? "rc=$rc $(echo "$out" | head -2 | tr '\n' ' ')"
update-desktop-database "$r/usr/share/applications" 2> /dev/null
grep -q "^x-scheme-handler/$scheme=.*$app_id.desktop" "$r/usr/share/applications/mimeinfo.cache"
hl_check "D10 once the desktop-database trigger runs, the system-wide cache maps $scheme:// to it" $? "$(cat "$r/usr/share/applications/mimeinfo.cache" 2>&1 | head -4 | tr '\n' ' ')"
rm -f "$r/usr/share/applications/mimeinfo.cache"
out=$(dpkg --root="$r" --force-script-chrootless --force-not-root -r ghoztty 2>&1); rc=$?
left=$(cd "$r" && find usr -type f 2>/dev/null | head -5)
[ $rc = 0 ] && [ -z "$left" ]
hl_check "D11 dpkg -r removes every file it installed" $? "rc=$rc left=$left $(echo "$out" | tail -2 | tr '\n' ' ')"

dbg=$(PKG_OPTIMIZE=Debug PKG_OUT="$work/dbg" bash scripts/linux/package.sh 2>&1 | sed -n 's/^PACKAGE OK //p')
out=$(PKG_OUT="$work/dbg" bash scripts/linux/package-deb.sh "$dbg" 2>&1); rc=$?
[ -n "$dbg" ] && [ $rc = 3 ] && echo "$out" | grep -q '^DEB REFUSED' && [ -z "$(ls "$work/dbg"/*.deb 2>/dev/null)" ]
hl_check "D12 a Debug tarball is refused (exit 3) and makes no .deb" $? "dbg=$dbg rc=$rc out=$out"

cleanup_work
trap - EXIT
hl_finish "$L"
