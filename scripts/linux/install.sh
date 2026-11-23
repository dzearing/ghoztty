#!/usr/bin/env bash
# install.sh - install an unpacked Ghoztty Linux tarball for this user
# (T3343, Linux L14). Shipped inside the tarball as ghoztty/install.sh by
# scripts/linux/package.sh; run it from there:
#
#   ./ghoztty/install.sh              install (or update in place)
#   ./ghoztty/install.sh --uninstall  remove what an install put down
#
# Options: --prefix DIR (default ~/.local), --dev (allow a Debug package).
#
# What it puts where (nothing outside $HOME, never sudo):
#   $PREFIX/opt/ghoztty/      the whole tree, as packaged
#   $PREFIX/bin/ghoztty       a symlink to it
#   $XDG_DATA_HOME/applications/<app-id>.desktop   (Exec rewritten to the
#   $XDG_DATA_HOME/dbus-1/services/<app-id>.service  installed binary)
#   $XDG_DATA_HOME/systemd/user/app-<app-id>.service
#   $XDG_DATA_HOME/icons/hicolor/...                the app icons
# and makes <app-id>.desktop the default handler for its scheme
# (x-scheme-handler/ghoztty) with xdg-mime, or by writing
# $XDG_CONFIG_HOME/mimeapps.list itself when xdg-mime is not installed.
# Every file it puts outside opt/ is listed in opt/ghoztty/.install-manifest,
# which is what --uninstall removes.
#
# A Debug package answers on the debug app id, IPC socket and
# `ghoztty-debug://` scheme - the names a dev build (zig-out) uses - so it is
# refused without --dev: an installed copy must never collide with a dev
# build's endpoints. A release package uses the release names, which no
# debug build ever answers on.
#
# Last line: 'INSTALL OK ...', 'UNINSTALL OK ...' or 'INSTALL REFUSED <why>'
# / 'INSTALL FAILED <why>'. Exit 0 only on OK; 3 refused.
set -u

prefix="$HOME/.local"
dev=0
action=install
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) prefix=$2; shift 2 ;;
        --prefix=*) prefix=${1#--prefix=}; shift ;;
        --dev) dev=1; shift ;;
        --uninstall) action=uninstall; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "INSTALL FAILED unknown argument '$1' (see --help)"; exit 2 ;;
    esac
done

data=${XDG_DATA_HOME:-$HOME/.local/share}
conf=${XDG_CONFIG_HOME:-$HOME/.config}
dest="$prefix/opt/ghoztty"
manifest="$dest/.install-manifest"

# mimeapps_set <type> <desktop-id>: the [Default Applications] line, without
# xdg-mime. Replaces an existing line for the type, keeps everything else.
mimeapps_set() {
    local f="$conf/mimeapps.list" type=$1 id=$2
    mkdir -p "$conf"
    [ -f "$f" ] || printf '[Default Applications]\n' > "$f"
    grep -q '^\[Default Applications\]' "$f" || printf '\n[Default Applications]\n' >> "$f"
    local tmp="$f.ghoztty.$$"
    awk -v t="$type" -v id="$id" '
        /^\[/ { if (sec && !done) { print t "=" id ";"; done = 1 } sec = ($0 == "[Default Applications]") }
        sec && index($0, t "=") == 1 { if (!done) { print t "=" id ";"; done = 1 } next }
        { print }
        END { if (sec && !done) print t "=" id ";" }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# mimeapps_clear <type> <desktop-id>: drop the default only if it is ours.
mimeapps_clear() {
    local f="$conf/mimeapps.list" type=$1 id=$2
    [ -f "$f" ] || return 0
    local tmp="$f.ghoztty.$$"
    grep -vx "$type=$id;\?" "$f" > "$tmp"; mv "$tmp" "$f"
}

if [ "$action" = uninstall ]; then
    [ -f "$manifest" ] || { echo "INSTALL FAILED nothing installed at $dest (no manifest)"; exit 1; }
    scheme=$(sed -n 's/^scheme=//p' "$manifest")
    app_id=$(sed -n 's/^app-id=//p' "$manifest")
    sed -n 's/^file=//p' "$manifest" | while IFS= read -r f; do rm -f -- "$f"; done
    [ -n "$scheme" ] && mimeapps_clear "x-scheme-handler/$scheme" "$app_id.desktop"
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$data/applications" 2>/dev/null
    case "$dest" in */opt/ghoztty) rm -rf -- "$dest" ;; esac
    echo "UNINSTALL OK $app_id removed from $prefix"
    exit 0
fi

# --- install ---------------------------------------------------------------

src=$(cd "$(dirname "$0")" && pwd)
[ -x "$src/bin/ghoztty" ] || { echo "INSTALL FAILED $src/bin/ghoztty is missing - run install.sh from an unpacked tarball"; exit 1; }

desktop=$(ls "$src"/share/applications/com.dzearing.ghoztty*.desktop 2>/dev/null | head -1)
[ -n "$desktop" ] || { echo "INSTALL FAILED the package has no desktop entry"; exit 1; }
app_id=$(basename "$desktop" .desktop)
scheme=$(sed -n 's#^MimeType=.*x-scheme-handler/\([^;]*\);.*#\1#p' "$desktop" | head -1)
[ -n "$scheme" ] || { echo "INSTALL FAILED the desktop entry registers no x-scheme-handler"; exit 1; }

case "$app_id" in
    *-debug)
        if [ $dev = 0 ]; then
            echo "INSTALL REFUSED this is a Debug package ($app_id, $scheme://): it answers on the same app id, IPC socket and scheme as a dev build. Install a release package, or pass --dev to install it anyway."
            exit 3
        fi ;;
esac

if [ "$src" != "$dest" ]; then
    mkdir -p "$dest" || { echo "INSTALL FAILED cannot create $dest"; exit 1; }
    # Update in place: replace the tree, keep nothing stale from an older one.
    find "$dest" -mindepth 1 -maxdepth 1 ! -name .install-manifest -exec rm -rf -- {} +
    cp -a "$src"/. "$dest"/ || { echo "INSTALL FAILED copying to $dest"; exit 1; }
fi
bin="$dest/bin/ghoztty"

: > "$manifest.new"
printf 'app-id=%s\nscheme=%s\n' "$app_id" "$scheme" >> "$manifest.new"

# put <source> <target>: copy one file out of the tree, record it.
put() {
    mkdir -p "$(dirname "$2")" && cp -f "$1" "$2" && printf 'file=%s\n' "$2" >> "$manifest.new"
}
# rewrite <file>: point Exec/TryExec/ExecStart at the installed binary (the
# build baked in its own staging prefix).
rewrite() {
    sed -i -E "s#^((Try)?Exec(Start)?=)[^ ]*/bin/ghoztty#\\1$bin#" "$1"
}

mkdir -p "$prefix/bin"
ln -sfn "$bin" "$prefix/bin/ghoztty" && printf 'file=%s\n' "$prefix/bin/ghoztty" >> "$manifest.new"

put "$dest/share/applications/$app_id.desktop" "$data/applications/$app_id.desktop"
rewrite "$data/applications/$app_id.desktop"
if [ -f "$dest/share/dbus-1/services/$app_id.service" ]; then
    put "$dest/share/dbus-1/services/$app_id.service" "$data/dbus-1/services/$app_id.service"
    rewrite "$data/dbus-1/services/$app_id.service"
fi
if [ -f "$dest/share/systemd/user/app-$app_id.service" ]; then
    put "$dest/share/systemd/user/app-$app_id.service" "$data/systemd/user/app-$app_id.service"
    rewrite "$data/systemd/user/app-$app_id.service"
fi
if [ -d "$dest/share/icons" ]; then
    (cd "$dest/share" && find icons -type f) | while IFS= read -r f; do
        put "$dest/share/$f" "$data/$f"
    done
fi
mv "$manifest.new" "$manifest"

command -v update-desktop-database >/dev/null && update-desktop-database -q "$data/applications" 2>/dev/null
if command -v xdg-mime >/dev/null && [ -z "${GHOZTTY_INSTALL_NO_XDG_MIME:-}" ]; then
    XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$conf" xdg-mime default "$app_id.desktop" "x-scheme-handler/$scheme" \
        || mimeapps_set "x-scheme-handler/$scheme" "$app_id.desktop"
else
    mimeapps_set "x-scheme-handler/$scheme" "$app_id.desktop"
fi

echo "INSTALL OK $app_id -> $bin; $scheme:// links open in it"
