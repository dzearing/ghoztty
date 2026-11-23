#!/usr/bin/env bash
# package-install.sh - L14 (T3343) acceptance for the Linux tarball and its
# install script: package.sh builds a relocatable tarball, install.sh puts it
# under a home directory, rewrites the desktop entry / D-Bus service / systemd
# unit to the installed binary, and makes it the ghoztty:// handler; a Debug
# package is refused without --dev; --uninstall removes all of it. Run it ONLY
# through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\package-install.sh
#
# It packages a DEBUG build (the release build is the same template with the
# release names; building it here would double the run for no new path) and
# installs only into a private, throwaway HOME - never the distro user's.
#
# Output: one PASS/FAIL line per check, then 'PACKAGE INSTALL: ALL PASS' or
# 'PACKAGE INSTALL: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PACKAGE INSTALL"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app_id=com.dzearing.ghoztty-debug
scheme=ghoztty-debug

out=$(PKG_OPTIMIZE=Debug PKG_OUT="$work/out" bash scripts/linux/package.sh 2>&1); rc=$?
tarball=$(echo "$out" | sed -n 's/^PACKAGE OK //p')
[ $rc = 0 ] && [ -f "$tarball" ]
hl_check "P1 package.sh builds a Debug tarball" $? "rc=$rc $(echo "$out" | tail -3 | tr '\n' ' ')"
[ -f "$tarball" ] || hl_finish "$L"
case "$tarball" in *ghoztty-linux-*-debug-*.tar.gz) true ;; *) false ;; esac
hl_check "P2 the tarball is named for its arch, mode and commit" $? "$tarball"

mkdir -p "$work/unpack" && tar -C "$work/unpack" -xzf "$tarball"
pkg="$work/unpack/ghoztty"
[ -x "$pkg/bin/ghoztty" ] && [ -x "$pkg/install.sh" ] && [ -d "$pkg/share/ghostty" ]
hl_check "P3 it unpacks to ghoztty/ with bin/ghoztty, install.sh and the resources" $? "$(ls "$pkg" 2>&1 | tr '\n' ' ')"

d="$pkg/share/applications/$app_id.desktop"
grep -q "^MimeType=x-scheme-handler/$scheme;" "$d" &&
    grep -q '^Exec=[^ ]*/bin/ghoztty --gtk-single-instance=true %u$' "$d" &&
    grep -q '^TryExec=[^ ]*/bin/ghoztty$' "$d" &&
    grep -q '^Name=Ghoztty (Debug)$' "$d"
hl_check "P4 the desktop entry names bin/ghoztty, takes %u and registers x-scheme-handler/$scheme" $? "$(grep -E '^(Name|Exec|TryExec|MimeType)=' "$d" 2>&1 | tr '\n' ' ')"
grep -q '^Exec=[^ ]*/bin/ghoztty ' "$pkg/share/dbus-1/services/$app_id.service" &&
    grep -q '^ExecStart=[^ ]*/bin/ghoztty ' "$pkg/share/systemd/user/app-$app_id.service"
hl_check "P5 the D-Bus service and systemd unit name bin/ghoztty (not upstream's ghostty)" $? \
    "$(grep -h -E '^Exec(Start)?=' "$pkg/share/dbus-1/services/$app_id.service" "$pkg/share/systemd/user/app-$app_id.service" 2>&1 | tr '\n' ' ')"
out=$(desktop-file-validate "$d" 2>&1); rc=$?
[ $rc = 0 ]
hl_check "P6 desktop-file-validate accepts the entry" $? "$out"

# --- install into a private HOME --------------------------------------------

inst() { env -i PATH="$PATH" HOME="$work/home" "$@"; }
mkdir -p "$work/home"
out=$(inst "$pkg/install.sh" 2>&1); rc=$?
[ $rc = 3 ] && echo "$out" | grep -q "INSTALL REFUSED" && [ ! -e "$work/home/.local/opt/ghoztty" ]
hl_check "I1 a Debug package is refused without --dev, and nothing is installed" $? "rc=$rc out=$out"

out=$(inst "$pkg/install.sh" --dev 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | tail -1 | grep -q "^INSTALL OK"
hl_check "I2 install.sh --dev installs" $? "rc=$rc out=$out"
bin="$work/home/.local/opt/ghoztty/bin/ghoztty"
ad="$work/home/.local/share/applications/$app_id.desktop"
[ -x "$bin" ] && [ "$(readlink "$work/home/.local/bin/ghoztty")" = "$bin" ]
hl_check "I3 the tree is under ~/.local/opt/ghoztty and ~/.local/bin/ghoztty links to it" $? "$(ls -l "$work/home/.local/bin" 2>&1)"
grep -q "^Exec=$bin --gtk-single-instance=true %u$" "$ad" && grep -q "^TryExec=$bin$" "$ad" &&
    grep -q "^Exec=$bin " "$work/home/.local/share/dbus-1/services/$app_id.service" &&
    grep -q "^ExecStart=$bin " "$work/home/.local/share/systemd/user/app-$app_id.service"
hl_check "I4 the installed entry, service and unit run the installed binary" $? "$(grep -h -E '^(Try)?Exec(Start)?=' "$ad" "$work/home/.local/share/dbus-1/services/$app_id.service" 2>&1 | tr '\n' ' ')"
ls "$work/home/.local/share/icons/hicolor/"*/apps/com.dzearing.ghoztty.png > /dev/null 2>&1
hl_check "I5 the icons are installed" $?
out=$(inst env XDG_DATA_DIRS="$work/home/.local/share:/usr/share" xdg-mime query default "x-scheme-handler/$scheme" 2>&1)
[ "$out" = "$app_id.desktop" ]
hl_check "I6 xdg-mime reports $app_id.desktop as the $scheme:// handler" $? "out=$out mimeapps=$(cat "$work/home/.config/mimeapps.list" 2>&1 | tr '\n' ' ')"
out=$(inst env XDG_DATA_DIRS="$work/home/.local/share:/usr/share" gio mime "x-scheme-handler/$scheme" 2>&1)
echo "$out" | grep -q "Default application for .x-scheme-handler/$scheme.: $app_id.desktop"
hl_check "I7 GIO (what a DBusActivatable launch asks) agrees" $? "out=$(echo "$out" | head -3 | tr '\n' ' ')"
out=$("$bin" +version 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -qi "ghoztty\|version"
hl_check "I8 the installed binary runs (+version)" $? "rc=$rc $(echo "$out" | head -2 | tr '\n' ' ')"

out=$(inst "$pkg/install.sh" --dev 2>&1); rc=$?
n=$(grep -c "^x-scheme-handler/$scheme=" "$work/home/.config/mimeapps.list")
[ $rc = 0 ] && [ "$n" = 1 ]
hl_check "I9 a second install updates in place (one handler line)" $? "rc=$rc lines=$n"

# --- uninstall ---------------------------------------------------------------

out=$(inst "$work/home/.local/opt/ghoztty/install.sh" --uninstall 2>&1); rc=$?
left=$(cd "$work/home" && find . -name '*ghoztty*' | tr '\n' ' ')
[ $rc = 0 ] && [ -z "$left" ] && ! grep -q "$scheme" "$work/home/.config/mimeapps.list"
hl_check "U1 --uninstall removes the tree, every file it put down and the handler line" $? "rc=$rc out=$out left=$left"

# --- the fallback when xdg-mime is not installed -----------------------------

rm -rf "$work/home2"; mkdir -p "$work/home2/.config"
printf '[Default Applications]\ntext/html=firefox.desktop;\n\n[Added Associations]\ntext/plain=gedit.desktop;\n' > "$work/home2/.config/mimeapps.list"
out=$(env -i PATH="$PATH" HOME="$work/home2" GHOZTTY_INSTALL_NO_XDG_MIME=1 "$pkg/install.sh" --dev 2>&1); rc=$?
m="$work/home2/.config/mimeapps.list"
[ $rc = 0 ] && grep -q "^x-scheme-handler/$scheme=$app_id.desktop;$" "$m" &&
    grep -q '^text/html=firefox.desktop;$' "$m" && grep -q '^text/plain=gedit.desktop;$' "$m" &&
    [ "$(awk '/^\[/{s=$0} /^x-scheme-handler/{print s}' "$m")" = "[Default Applications]" ]
hl_check "X1 without xdg-mime it writes the default into [Default Applications] and keeps the user's lines" $? "rc=$rc $(tr '\n' '~' < "$m")"
env -i PATH="$PATH" HOME="$work/home2" "$work/home2/.local/opt/ghoztty/install.sh" --uninstall > /dev/null 2>&1
grep -q '^text/html=firefox.desktop;$' "$m" && ! grep -q "$scheme" "$m"
hl_check "X2 ...and uninstall removes only its own line" $? "$(tr '\n' '~' < "$m")"

hl_finish "$L"
