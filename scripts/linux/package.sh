#!/usr/bin/env bash
# package.sh - build the Linux (GTK) app into a relocatable tarball
# (T3343, Linux L14). The tarball holds the installed tree (bin/, share/)
# under one top-level `ghoztty/` directory, plus `ghoztty/install.sh`, which
# puts it under ~/.local and registers the desktop entry and the ghoztty://
# handler. Run it through the wrapper, from this box:
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
# Last line: 'PACKAGE OK <path>' or 'PACKAGE FAILED <why>'; exit 0 only on OK.
set -u

opt=${PKG_OPTIMIZE:-ReleaseFast}
case "$opt" in
    ReleaseFast) mode=release ;;
    Debug) mode=debug ;;
    *) echo "PACKAGE FAILED PKG_OPTIMIZE must be ReleaseFast or Debug, not '$opt'"; exit 2 ;;
esac
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

cp scripts/linux/install.sh "$prefix/install.sh" && chmod 755 "$prefix/install.sh"

sha=$(git rev-parse --short=9 HEAD 2>/dev/null || echo unknown)
tarball="$out/ghoztty-linux-$(uname -m)-$mode-$sha.tar.gz"
tar -C "$stage" -czf "$tarball" ghoztty || { echo "PACKAGE FAILED tar"; exit 1; }
echo "PACKAGE OK $tarball"
