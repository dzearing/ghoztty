#!/usr/bin/env bash
# package-appimage.sh - L14c (T3658) acceptance for the Linux AppImage:
#
#   B  package-appimage.sh turns a package.sh tarball into an AppImage: the
#      AppDir's entry, icon and AppRun; WebKit's helpers inside it and the
#      bundled libwebkitgtk's compiled helper path rewritten to the AppRun
#      link; nothing from the excludelist bundled; every bundled ELF finds its
#      libraries through an $ORIGIN RUNPATH, and inside the image `ldd`
#      resolves nothing outside it but the excluded set.
#   H  with the host's GTK 4, libadwaita, WebKitGTK and JavaScriptCore hidden
#      (bind-mounted over with /dev/null in a private mount namespace, and
#      WebKit's helper directory emptied - a control proves the unpacked
#      tarball cannot start there), the AppImage, mounted through FUSE,
#      renders a markdown viewer and a website: its web and network processes
#      are the AppImage's, under WebKit's own bubblewrap sandbox.
#   E  a pane's shell gets the environment the launch had: none of AppRun's
#      bundled-library variables or the AppImage runtime's, and a variable
#      AppRun overrode comes back with its original value.
#   L  the /tmp link AppRun manages is used only when it is this user's
#      symlink: a directory, or a symlink someone else owns, stops the launch;
#      a CLI verb never repoints it.
#   X  `APPIMAGE_EXTRACT_AND_RUN=1` (no FUSE) runs it too.
#   R  a release tarball becomes a release AppImage (ReleaseFast, the release
#      app id); with the host's libraries hidden it opens a viewer pane that a
#      CLI verb run through the same AppImage asked for; a Debug tarball is
#      refused without APPIMAGE_DEV=1.
#
# Run it ONLY through the wrapper, from this box (about 8 minutes: a debug
# and a release build):
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\package-appimage.sh
#
# Output: one PASS/FAIL line per check, then 'PACKAGE APPIMAGE: ALL PASS' or
# 'PACKAGE APPIMAGE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PACKAGE APPIMAGE"

arch=$(uname -m)
LIB=/usr/lib/$arch-linux-gnu
ORIG_WEBKIT=$LIB/webkitgtk-6.0
LINK=/tmp/.ghoztty-appimage-webkit
work=$(mktemp -d /tmp/ghoztty-appimage.XXXXXX)
cleanup_work() {
    pkill -KILL -f '\.mount_Ghoz.*/usr/bin/ghoztty' 2>/dev/null
    pkill -KILL -f "^$work/" 2>/dev/null
    rm -rf "$work" /tmp/appimage_extracted_* 2>/dev/null
    rm -rf "$LINK"
}
trap 'cleanup_work; hl_stop' EXIT
rm -rf "$LINK"

# hidden <cmd...>: run <cmd> where the host's GTK 4 / libadwaita / WebKitGTK /
# JavaScriptCore libraries are /dev/null and WebKit's helper dir is empty.
masked=$(ls "$LIB"/libwebkitgtk-6.0.so.4.* "$LIB"/libjavascriptcoregtk-6.0.so.1.* "$LIB"/libgtk-4.so.1.* "$LIB"/libadwaita-1.so.0.* 2>/dev/null | tr '\n' ' ')
hidden() {
    unshare --mount --propagation private bash -c '
        for f in '"$masked"'; do mount --bind /dev/null "$f" || exit 97; done
        mount -t tmpfs none '"$ORIG_WEBKIT"' || exit 97
        exec "$@"' hidden "$@"
}
excluded_list=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' scripts/linux/appimage/excludelist)

# --- B: build a (debug, for its probes) AppImage and look inside ------------

out=$(PKG_OPTIMIZE=Debug PKG_OUT="$work/tar" bash scripts/linux/package.sh 2>&1); rc=$?
dtar=$(echo "$out" | sed -n 's/^PACKAGE OK //p')
[ $rc = 0 ] && [ -f "$dtar" ]
hl_check "B0 package.sh builds a Debug tarball" $? "rc=$rc $(echo "$out" | tail -2 | tr '\n' ' ')"
[ -f "$dtar" ] || hl_finish "$L"

out=$(PKG_OUT="$work/out" bash scripts/linux/package-appimage.sh "$dtar" 2>&1); rc=$?
[ $rc = 3 ] && echo "$out" | tail -1 | grep -q 'built from a release one'
hl_check "B1 a Debug tarball is refused without APPIMAGE_DEV=1 (exit 3)" $? "rc=$rc $(echo "$out" | tail -1)"

out=$(APPIMAGE_DEV=1 PKG_OUT="$work/out" bash scripts/linux/package-appimage.sh "$dtar" 2>&1); rc=$?
img=$(echo "$out" | sed -n 's/^APPIMAGE OK //p')
[ $rc = 0 ] && [ -x "$img" ] && case "$img" in *-debug-"$arch".AppImage) true ;; *) false ;; esac
hl_check "B2 package-appimage.sh builds an executable AppImage (APPIMAGE_DEV=1)" $? "rc=$rc $(echo "$out" | tail -3 | tr '\n' ' ')"
[ -x "$img" ] || hl_finish "$L"

ex="$work/extract"
mkdir -p "$ex" && (cd "$ex" && "$img" --appimage-extract > /dev/null 2>&1)
ad="$ex/squashfs-root"
d=$(ls "$ad"/*.desktop 2>/dev/null | head -1)
[ -x "$ad/AppRun" ] && [ -f "$d" ] && grep -q '^Exec=ghoztty ' "$d" && ! grep -qE '^(DBusActivatable|TryExec)=' "$d" &&
    [ -e "$ad/.DirIcon" ] && [ -f "$ad/$(sed -n 's/^Icon=//p' "$d").png" ] && desktop-file-validate "$d" > /dev/null 2>&1
hl_check "B3 the AppDir root carries AppRun, a valid entry running 'ghoztty' (no TryExec/DBusActivatable) and its icon" $? "$(ls -a "$ad" | tr '\n' ' ') $(grep -E '^(Exec|Icon|TryExec|DBusActivatable)=' "$d" 2>&1 | tr '\n' ' ')"

wl="$ad/usr/lib/libwebkitgtk-6.0.so.4"
[ -x "$ad/usr/lib/webkitgtk-6.0/WebKitWebProcess" ] && [ -x "$ad/usr/lib/webkitgtk-6.0/WebKitNetworkProcess" ] &&
    [ -f "$ad/usr/lib/webkitgtk-6.0/injected-bundle/libwebkitgtkinjectedbundle.so" ] &&
    ! grep -qaF "$ORIG_WEBKIT" "$wl" && [ "$(grep -caF "$LINK" "$wl")" -ge 1 ] && grep -qF "link='$LINK'" "$ad/AppRun"
hl_check "B4 WebKit's helpers are in the AppDir and libwebkitgtk names the AppRun link, never $ORIG_WEBKIT" $? "$(ls "$ad/usr/lib/webkitgtk-6.0" 2>&1 | tr '\n' ' ') orig=$(grep -caF "$ORIG_WEBKIT" "$wl") link=$(grep -caF "$LINK" "$wl")"

bad=""
for n in $excluded_list; do [ -e "$ad/usr/lib/$n" ] && bad="$bad $n"; done
[ -z "$bad" ] && [ -f "$ad/usr/lib/libgtk-4.so.1" ] && [ -f "$ad/usr/lib/libadwaita-1.so.0" ] && [ -f "$ad/usr/lib/libjavascriptcoregtk-6.0.so.1" ]
hl_check "B5 GTK 4, libadwaita and JavaScriptCore are bundled, nothing on the excludelist is" $? "bundled-but-excluded:$bad"

norp="" leak=""
while IFS= read -r f; do
    [ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
    readelf -d "$f" 2>/dev/null | grep -q '(NEEDED)' || continue
    rp=$(readelf -d "$f" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')
    case "$rp" in '$ORIGIN'*) ;; *) norp="$norp ${f#$ad/}($rp)" ;; esac
    # Its OWN dependencies: bundled, or the host's by the excludelist. (What
    # an excluded host library needs in turn is the host's business.)
    for name in $(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
        [ -e "$ad/usr/lib/$name" ] || [ -e "$ad/usr/lib/ghoztty/$name" ] && continue
        echo "$excluded_list" | grep -qxF "$name" || leak="$leak ${f#$ad/}:$name"
    done
    ldd "$f" 2>/dev/null | grep -q 'not found' && leak="$leak ${f#$ad/}:(ldd: not found)"
done < <(find "$ad/usr" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \))
[ -z "$norp" ]
hl_check "B6 every bundled ELF has an \$ORIGIN RUNPATH" $? "${norp:0:600}"
[ -z "$leak" ]
hl_check "B7 every bundled ELF's own dependencies are bundled or on the excludelist, and ldd finds them all" $? "${leak:0:800}"

# --- H: with the host's libraries hidden ------------------------------------

hl_start
hl_check "H0 a private headless Weston is up" $?

fx="$HL_RUNTIME/fx"
mkdir -p "$fx/site"
printf '# AppImage Heading\n\nSome **bold** text.\n' > "$fx/doc.md"
printf '<!DOCTYPE html><html><body><h1>Site Up</h1></body></html>\n' > "$fx/site/index.html"
port=$((20000 + $$ % 20000))
(cd "$fx/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) > "$HL_RUNTIME/http.log" 2>&1 &
HL_PIDS="$HL_PIDS $!"
hl_wait_for 10 sh -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null

mkdir -p "$work/unpack" && tar -C "$work/unpack" -xzf "$dtar"
out=$(cd / && hidden "$work/unpack/ghoztty/bin/ghoztty" +version 2>&1); rc=$?
[ $rc != 0 ] && [ $rc != 97 ] && echo "$out" | grep -qE 'libwebkitgtk-6.0|libgtk-4|libadwaita|file too short|cannot open shared object'
hl_check "H1 control: the unpacked tarball cannot start with the host's libraries hidden" $? "rc=$rc $(echo "$out" | head -2 | tr '\n' ' ')"

out=$(cd / && hidden "$img" +version 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'build mode *: \.Debug'
hl_check "H2 the AppImage runs from / through FUSE with them hidden (+version)" $? "rc=$rc $(echo "$out" | grep -iE 'error|fuse|build mode' | head -3 | tr '\n' ' ')"

# view <var> <location> <probe> [env...]: one viewer in a fresh AppImage app.
n=0
view() {
    local var=$1 loc=$2 probe=$3; shift 3
    n=$((n + 1))
    local dump="$HL_RUNTIME/dump$n" penv="$HL_RUNTIME/pane-env$n"
    hl_launch "$var" hidden env "$@" GHOZTTY_TEST_VIEWER="$loc" GHOZTTY_TEST_VIEWER_PROBE="$probe" \
        GHOZTTY_TEST_VIEWER_DUMP="$dump" "$img" --gtk-single-instance=false --session-persistence=false \
        -e /bin/sh -c "env > $penv.tmp && mv $penv.tmp $penv; sleep 120"
    hl_wait_for 90 test -s "$dump"
    printf -v "${var}_OUT" '%s' "$(cat "$dump" 2>/dev/null)"
    hl_wait_for 20 test -s "$penv"
    printf -v "${var}_ENV" '%s' "$penv"
    # The processes WebKit spawned, while they are up.
    local procs="" p exe
    for p in $(pgrep -f 'WebKit(Web|Network)Process'); do
        exe=$(readlink "/proc/$p/exe" 2>/dev/null)
        procs="$procs $(basename "$exe")@$(dirname "$exe")"
    done
    printf -v "${var}_PROCS" '%s' "$procs"
    printf -v "${var}_BWRAP" '%s' "$(pgrep -x bwrap | wc -l)"
    local app_pid maps
    app_pid=$(pgrep -f '\.mount_Ghoz.*/usr/bin/ghoztty' | head -1)
    maps=$(grep -m1 'libwebkitgtk-6.0' "/proc/$app_pid/maps" 2>/dev/null | awk '{print $6}')
    printf -v "${var}_MAP" '%s' "$maps"
    printf -v "${var}_APPENV" '%s' "$(tr '\0' '\n' < "/proc/$app_pid/environ" 2>/dev/null | grep -E '^(LD_LIBRARY_PATH|GIO_MODULE_DIR|GHOZTTY_APPIMAGE_UNSET|GST_PLUGIN_SYSTEM_PATH_1_0)=' | sort | tr '\n' ' ')"
    local pid=${!var}
    kill -TERM "$pid" 2>/dev/null
    [ -n "$app_pid" ] && kill -TERM "$app_pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}

view MD "$fx/doc.md" "(function(){var h=document.querySelector('#content h1'),b=document.querySelector('#content strong');return [h?h.textContent:'NOH1',b?b.textContent:'NOB'].join('|')})()" \
    XDG_DATA_DIRS=/orig/share:/usr/share GST_PLUGIN_SYSTEM_PATH_1_0=/orig/gst
[ "$MD_OUT" = "OK AppImage Heading|bold" ]
hl_check "H3 a markdown viewer renders with the host's WebKit hidden" $? "got: $MD_OUT"
case "$MD_MAP" in /tmp/.mount_*/usr/lib/libwebkitgtk-6.0.so.4) true ;; *) false ;; esac
hl_check "H4 the app maps the AppImage's libwebkitgtk-6.0, from its mount" $? "map=$MD_MAP"
echo "$MD_PROCS" | grep -q 'WebKitWebProcess@' && echo "$MD_PROCS" | grep -q 'WebKitNetworkProcess@' && ! echo "$MD_PROCS" | grep -qF "@$ORIG_WEBKIT"
hl_check "H5 its web and network processes run from the AppImage, never $ORIG_WEBKIT" $? "procs:$MD_PROCS"
[ "${MD_BWRAP:-0}" -ge 1 ] && ! grep -q 'bwrap: ' "$MD_LOG" && ! grep -q 'WEBKIT_DISABLE_SANDBOX' "$ad/AppRun"
hl_check "H6 WebKit's bubblewrap sandbox stays on (bwrap running, no bwrap error, AppRun never disables it)" $? "bwrap=$MD_BWRAP $(grep -m2 'bwrap' "$MD_LOG" | tr '\n' ' ')"

view WEB "http://127.0.0.1:$port/" "document.querySelector('h1').textContent+'|'+location.href"
[ "$WEB_OUT" = "OK Site Up|http://127.0.0.1:$port/" ]
hl_check "H7 a website loads through the AppImage's network process" $? "got: $WEB_OUT"

grep -hE 'panic|reached unreachable|Failed to spawn' "$MD_LOG" "$WEB_LOG" > /dev/null 2>&1
[ $? != 0 ]
hl_check "H8 no app log carries a panic or a failed helper spawn" $? "$(grep -h -m3 -E 'panic|unreachable|Failed to spawn' "$MD_LOG" "$WEB_LOG" 2>/dev/null | tr '\n' ' ')"

# --- E: the pane's shell environment -------------------------------------------

pe=$MD_ENV
# Positive control: the app itself DID run with AppRun's variables, so their
# absence below is the restore at work and not a launch that never set them.
echo "$MD_APPENV" | grep -q 'LD_LIBRARY_PATH=/tmp/.mount_' && echo "$MD_APPENV" | grep -q 'GIO_MODULE_DIR=/tmp/.mount_' &&
    echo "$MD_APPENV" | grep -q 'GHOZTTY_APPIMAGE_UNSET=' && echo "$MD_APPENV" | grep -q 'GST_PLUGIN_SYSTEM_PATH_1_0=/tmp/.mount_'
hl_check "E0 control: the app's own environment carries AppRun's LD_LIBRARY_PATH, GIO and GStreamer paths" $? "app env: $MD_APPENV"
leaked=$(grep -E '^(APPDIR|APPIMAGE|ARGV0|OWD|LD_LIBRARY_PATH|GIO_MODULE_DIR|GST_PLUGIN_SCANNER_1_0|GST_REGISTRY_1_0|GDK_PIXBUF_MODULE_FILE|GHOZTTY_APPIMAGE_[A-Z_0-9]*)=' "$pe" 2>/dev/null)
[ -s "$pe" ] && [ -z "$leaked" ]
hl_check "E1 the pane's shell inherits none of AppRun's or the AppImage runtime's variables" $? "env=$( [ -s "$pe" ] && echo present || echo MISSING) leaked: $(echo "$leaked" | tr '\n' ' ')"
grep -qx 'GST_PLUGIN_SYSTEM_PATH_1_0=/orig/gst' "$pe" && grep -q '^XDG_DATA_DIRS=/orig/share:/usr/share' "$pe"
hl_check "E2 a variable AppRun overrode comes back to the shell with its original value" $? "$(grep -E '^(GST_PLUGIN_SYSTEM_PATH_1_0|XDG_DATA_DIRS)=' "$pe" 2>&1 | tr '\n' ' ')"

# --- L: the /tmp link ------------------------------------------------------------

[ -L "$LINK" ] && [ "$(stat -c %u "$LINK")" = "$(id -u)" ]
hl_check "L1 the GUI launches left $LINK as this user's symlink" $? "$(ls -ld "$LINK" 2>&1)"
rm -rf "$LINK"; mkdir "$LINK"
out=$(cd / && "$img" --gtk-single-instance=false 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q 'is not this user'
hl_check "L2 a directory at $LINK stops the launch" $? "rc=$rc $(echo "$out" | head -2 | tr '\n' ' ')"
rm -rf "$LINK"; ln -s /nonexistent "$LINK"; chown -h nobody "$LINK"
out=$(cd / && "$img" --gtk-single-instance=false 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q 'is not this user'
hl_check "L3 a symlink at $LINK owned by another user stops the launch" $? "rc=$rc $(echo "$out" | head -2 | tr '\n' ' ')"
rm -f "$LINK"; ln -s /verb-marker "$LINK"
out=$(cd / && "$img" +version 2>&1); rc=$?
[ $rc = 0 ] && [ "$(readlink "$LINK")" = /verb-marker ]
hl_check "L4 a CLI verb (+version) runs and leaves the link alone" $? "rc=$rc link=$(readlink "$LINK")"
rm -f "$LINK"

# --- X: no FUSE ---------------------------------------------------------------------

out=$(cd / && APPIMAGE_EXTRACT_AND_RUN=1 "$img" +version 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'build mode *: \.Debug'
hl_check "X1 APPIMAGE_EXTRACT_AND_RUN=1 runs it without FUSE" $? "rc=$rc $(echo "$out" | tail -2 | tr '\n' ' ')"

# --- R: the release AppImage ----------------------------------------------------------

out=$(PKG_OUT="$work/rout" bash scripts/linux/package-appimage.sh 2>&1); rc=$?
rimg=$(echo "$out" | sed -n 's/^APPIMAGE OK //p')
[ $rc = 0 ] && [ -x "$rimg" ] && case "$rimg" in *-release-"$arch".AppImage) true ;; *) false ;; esac
hl_check "R1 package-appimage.sh with no tarball builds a release AppImage" $? "rc=$rc $(echo "$out" | tail -3 | tr '\n' ' ')"
if [ -x "$rimg" ]; then
    out=$(cd / && hidden "$rimg" +version 2>&1); rc=$?
    [ $rc = 0 ] && echo "$out" | grep -q 'build mode *: \.ReleaseFast'
    hl_check "R2 it is a ReleaseFast build and runs with the host's libraries hidden" $? "rc=$rc $(echo "$out" | grep -E 'error|build mode' | head -2 | tr '\n' ' ')"
    (cd "$work" && mkdir -p rex && cd rex && "$rimg" --appimage-extract '*.desktop' > /dev/null 2>&1)
    ls "$work/rex/squashfs-root/com.dzearing.ghoztty.desktop" > /dev/null 2>&1 &&
        grep -q '^MimeType=x-scheme-handler/ghoztty;' "$work/rex/squashfs-root/com.dzearing.ghoztty.desktop"
    hl_check "R3 its entry is the release app id and the ghoztty:// scheme" $? "$(ls "$work/rex/squashfs-root" 2>&1 | tr '\n' ' ')"

    hl_launch REL hidden "$rimg" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'sleep 120'
    sock="$XDG_RUNTIME_DIR/ghostty-$(id -u).sock"
    hl_wait_for 60 test -S "$sock"
    out=$(cd "$fx" && "$rimg" +split --view=doc.md --name=doc 2>&1); rc=$?
    procs=""
    hl_wait_for 30 pgrep -f WebKitWebProcess > /dev/null
    for p in $(pgrep -f 'WebKit(Web|Network)Process'); do procs="$procs $(readlink "/proc/$p/exe" 2>/dev/null)"; done
    [ $rc = 0 ] && echo "$procs" | grep -q WebKitWebProcess && ! echo "$procs" | grep -qF "$ORIG_WEBKIT" &&
        ! grep -qE 'panic|Failed to spawn' "$REL_LOG"
    hl_check "R4 a +split --view through the same AppImage opens a viewer pane whose web process is the AppImage's" $? "rc=$rc out=$(echo "$out" | head -2 | tr '\n' ' ') procs:$procs $(grep -m2 -E 'panic|Failed to spawn' "$REL_LOG" | tr '\n' ' ')"
    kill -TERM "$REL" 2>/dev/null
    pkill -TERM -f '\.mount_Ghoz.*/usr/bin/ghoztty' 2>/dev/null
    wait "$REL" 2>/dev/null
fi

if [ "$HL_FAILS" != 0 ]; then
    for v in MD WEB; do
        lv="${v}_LOG"
        echo "---- $v log (viewer lines) ----"
        grep -iE 'viewer|webkit|bwrap|sandbox|critical|error|spawn' "${!lv}" 2>/dev/null | grep -v 'Portal not found' | head -20
    done
fi

hl_finish "$L"
