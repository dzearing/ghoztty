#!/usr/bin/env bash
# package-deb.sh - turn a Linux release tarball into a .deb (T3578, Linux
# L14b). The .deb is the same tree package.sh built, laid out under /usr:
#
#   /usr/bin/ghoztty, /usr/bin/ghoztty-agent
#   /usr/lib/ghoztty/libgtk4-layer-shell.so   (the binary's $ORIGIN/../lib/ghoztty)
#   /usr/share/...                            (desktop entry, D-Bus service,
#                                              systemd user unit, icons, resources)
#
# with the desktop entry's Exec/TryExec, the D-Bus service's Exec and the
# systemd unit's ExecStart pointed at /usr/bin/ghoztty (the build bakes in its
# staging prefix). Run it through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile scripts\linux\package-deb.sh
#
#   package-deb.sh [TARBALL]   TARBALL defaults to a fresh `package.sh` build.
#   PKG_OUT                    where the .deb goes (default: zig-out/dist).
#
# Only a release tarball is accepted: a Debug package answers on the debug app
# id, socket and ghoztty-debug:// scheme - a dev build's names - and a .deb
# would put that system-wide, so it is refused (exit 3).
#
# Depends comes from dpkg-shlibdeps over the binaries. There are no maintainer
# scripts: the desktop database, icon cache and MIME cache are refreshed by the
# dpkg file triggers desktop-file-utils, hicolor-icon-theme and
# shared-mime-info already declare on /usr/share/applications and
# /usr/share/icons, which is what Debian policy asks of a package that only
# ships those files. The scheme needs no default either: the entry's MimeType
# is what makes it the x-scheme-handler/ghoztty application system-wide.
#
# Version: <build.zig.zon version>+<commit count>.g<sha>, so a later commit of
# the same branch always upgrades an earlier one.
#
# Last line: 'DEB OK <path>' or 'DEB FAILED <why>' / 'DEB REFUSED <why>';
# exit 0 only on OK, 3 refused.
set -u

out=${PKG_OUT:-$PWD/zig-out/dist}
mkdir -p "$out" || { echo "DEB FAILED cannot create $out"; exit 1; }
for t in dpkg-deb dpkg-shlibdeps fakeroot; do
    command -v "$t" > /dev/null || { echo "DEB FAILED $t is not installed (scripts/linux/setup-distro.sh installs it)"; exit 1; }
done

tarball=${1:-}
if [ -z "$tarball" ]; then
    res=$(PKG_OPTIMIZE=ReleaseFast PKG_OUT="$out" bash scripts/linux/package.sh 2>&1)
    tarball=$(printf '%s\n' "$res" | sed -n 's/^PACKAGE OK //p')
    [ -n "$tarball" ] || { printf '%s\n' "$res" | tail -5; echo "DEB FAILED package.sh did not build a tarball"; exit 1; }
fi
[ -f "$tarball" ] || { echo "DEB FAILED no tarball at $tarball"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -C "$work" -xzf "$tarball" || { echo "DEB FAILED cannot unpack $tarball"; exit 1; }
tree="$work/ghoztty"
info="$tree/.package-info"
[ -f "$info" ] || { echo "DEB FAILED $tarball has no .package-info (built before T3578?)"; exit 1; }
field() { sed -n "s/^$1=//p" "$info" | head -1; }
mode=$(field mode)
[ "$mode" = release ] || { echo "DEB REFUSED $tarball is a $mode package: a .deb would install the dev build's app id, socket and scheme system-wide"; exit 3; }
staged=$(field staged)
version="$(field version)+$(field count).g$(field commit)"
arch=$(dpkg --print-architecture)

root="$work/root"
usr="$root/usr"
mkdir -p "$usr/bin" "$usr/lib" "$root/DEBIAN"
cp -a "$tree/bin/." "$usr/bin/"
cp -a "$tree/lib/ghoztty" "$usr/lib/ghoztty"
cp -a "$tree/share" "$usr/share"

# Exec lines: the staging prefix's bin/ghoztty -> /usr/bin/ghoztty. Any other
# file still naming the staging prefix is a path the .deb would ship broken.
for f in "$usr"/share/applications/com.dzearing.ghoztty*.desktop \
         "$usr"/share/dbus-1/services/com.dzearing.ghoztty*.service \
         "$usr"/share/systemd/user/app-com.dzearing.ghoztty*.service; do
    [ -f "$f" ] && sed -i -E "s#^((Try)?Exec(Start)?=)[^ ]*/bin/ghoztty#\\1/usr/bin/ghoztty#" "$f"
done
left=$(grep -rlI -- "$staged" "$root" 2>/dev/null | sed "s#^$root##")
[ -z "$left" ] || { echo "DEB FAILED files still name the build's staging prefix: $left"; exit 1; }

# Depends, from the binaries' NEEDED libraries. The private layer-shell library
# is found through -l, and is ours, so it adds nothing.
mkdir -p "$work/src/debian"
printf 'Source: ghoztty\n\nPackage: ghoztty\nArchitecture: any\n' > "$work/src/debian/control"
elves=$(cd "$root" && for f in usr/bin/* usr/lib/ghoztty/*.so; do file -b "$f" | grep -q '^ELF' && printf '%s ' "$root/$f"; done)
deps=$(cd "$work/src" && dpkg-shlibdeps -O -l"$usr/lib/ghoztty" $elves 2> "$work/shlibdeps.err" | sed -n 's/^shlibs:Depends=//p')
[ -n "$deps" ] || { cat "$work/shlibdeps.err"; echo "DEB FAILED dpkg-shlibdeps found no dependencies"; exit 1; }

size=$(du -sk "$usr" | cut -f1)
cat > "$root/DEBIAN/control" <<CONTROL
Package: ghoztty
Version: $version
Architecture: $arch
Maintainer: Ghoztty <ghoztty@users.noreply.github.com>
Installed-Size: $size
Depends: $deps
Section: x11
Priority: optional
Homepage: https://github.com/dzearing/ghoztty
Description: terminal emulator with CLI-driven window management
 Ghoztty is a fork of the Ghostty terminal that adds a command-line
 interface for opening, splitting, naming, reading and driving terminal
 windows and panes, for AI agents and automation, plus viewer panes for
 markdown, HTML, websites and diffs.
CONTROL

deb="$out/ghoztty_${version}_${arch}.deb"
fakeroot dpkg-deb --root-owner-group -Zxz --build "$root" "$deb" > "$work/deb.log" 2>&1 \
    || { cat "$work/deb.log"; echo "DEB FAILED dpkg-deb"; exit 1; }
echo "DEB OK $deb"
