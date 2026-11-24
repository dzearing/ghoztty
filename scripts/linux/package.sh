#!/usr/bin/env bash
# package.sh - build the Linux (GTK) app into a relocatable tarball
# (T3343, Linux L14; T3578). The tarball holds the installed tree (bin/,
# lib/ghoztty/, share/) under one top-level `ghoztty/` directory, plus
# `ghoztty/install.sh`, which puts it under ~/.local and registers the desktop
# entry and the ghoztty:// handler, and `ghoztty/.package-info`, which
# package-deb.sh reads. Run it through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile scripts\linux\package.sh
#
# (-Repo clone, the default: it packages the committed HEAD.)
#
#   PKG_OPTIMIZE  ReleaseFast (default) or Debug. A Debug package carries the
#                 debug app id, socket and `ghoztty-debug://` scheme - the
#                 names a dev build answers on - so install.sh refuses one
#                 unless given --dev.
#   PKG_OUT       where the tarball goes (default: zig-out/dist).
#
# The one library the app needs that Ubuntu does not package,
# libgtk4-layer-shell.so, is built from source (-fno-sys=gtk4-layer-shell) and
# ships in lib/ghoztty/. The link step leaves the binary a RUNPATH of
# `.zig-cache/o/<hash>` - relative to the CURRENT directory, so an installed
# copy only started from inside the build tree (T3578). It is replaced with
# `$ORIGIN/../lib/ghoztty`, which holds for the tarball, ~/.local/opt and the
# .deb's /usr alike. The build's developer artifacts (include/, libghostty-vt,
# pkg-config files) are not part of the app and are left out.
#
# Last line: 'PACKAGE OK <path>' or 'PACKAGE FAILED <why>'; exit 0 only on OK.
set -u

opt=${PKG_OPTIMIZE:-ReleaseFast}
case "$opt" in
    ReleaseFast) mode=release ;;
    Debug) mode=debug ;;
    *) echo "PACKAGE FAILED PKG_OPTIMIZE must be ReleaseFast or Debug, not '$opt'"; exit 2 ;;
esac
command -v patchelf > /dev/null || { echo "PACKAGE FAILED patchelf is not installed (scripts/linux/setup-distro.sh installs it)"; exit 1; }
out=${PKG_OUT:-$PWD/zig-out/dist}
mkdir -p "$out" || { echo "PACKAGE FAILED cannot create $out"; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
prefix="$stage/ghoztty"

log=/tmp/ghoztty-package-$mode.log
echo "PACKAGE building $opt into $prefix (log: $log)"
if ! zig build -Dapp-runtime=gtk -Doptimize="$opt" -fno-sys=gtk4-layer-shell -p "$prefix" > "$log" 2>&1; then
    grep -m5 'error' "$log"
    echo "PACKAGE FAILED zig build (see $log)"
    exit 1
fi
[ -x "$prefix/bin/ghoztty" ] || { echo "PACKAGE FAILED no bin/ghoztty in the build"; exit 1; }
[ -f "$prefix/lib/libgtk4-layer-shell.so" ] || { echo "PACKAGE FAILED the build installed no lib/libgtk4-layer-shell.so"; exit 1; }

# The app's private library, and nothing else, under lib/ghoztty/.
mkdir -p "$prefix/lib/ghoztty"
mv "$prefix/lib/libgtk4-layer-shell.so" "$prefix/lib/ghoztty/"
find "$prefix/lib" -mindepth 1 -maxdepth 1 ! -name ghoztty -exec rm -rf -- {} +
rm -rf -- "$prefix/include" "$prefix/share/pkgconfig"

for f in "$prefix"/bin/*; do
    readelf -d "$f" 2>/dev/null | grep -q 'NEEDED.*libgtk4-layer-shell' || continue
    patchelf --set-rpath '$ORIGIN/../lib/ghoztty' "$f" || { echo "PACKAGE FAILED patchelf on $f"; exit 1; }
done
rp=$(readelf -d "$prefix/bin/ghoztty" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')
[ "$rp" = '$ORIGIN/../lib/ghoztty' ] || { echo "PACKAGE FAILED bin/ghoztty RUNPATH is '$rp', not \$ORIGIN/../lib/ghoztty"; exit 1; }

cp scripts/linux/install.sh "$prefix/install.sh" && chmod 755 "$prefix/install.sh"

sha=$(git rev-parse --short=9 HEAD 2>/dev/null || echo unknown)
count=$(git rev-list --count HEAD 2>/dev/null || echo 0)
version=$(sed -n 's/^ *\.version *= *"\([^"]*\)".*/\1/p' build.zig.zon | head -1)
arch=$(uname -m)
staged=$prefix
printf 'version=%s\ncommit=%s\ncount=%s\nmode=%s\narch=%s\nstaged=%s\n' \
    "${version:-0.0.0}" "$sha" "$count" "$mode" "$arch" "$staged" > "$prefix/.package-info"

tarball="$out/ghoztty-linux-$arch-$mode-$sha.tar.gz"
tar -C "$stage" -czf "$tarball" ghoztty || { echo "PACKAGE FAILED tar"; exit 1; }
echo "PACKAGE OK $tarball"
