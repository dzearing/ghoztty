#!/usr/bin/env bash
# package-appimage.sh - turn a package.sh tarball into an AppImage (T3658,
# Linux L14c). Run it through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile scripts\linux\package-appimage.sh
#
#   package-appimage.sh [TARBALL]   default: a fresh release package.sh build
#
#   PKG_OUT          where the AppImage goes (default: zig-out/dist)
#   APPIMAGE_DEV=1   allow a Debug tarball (the acceptance test uses one for
#                    its debug-only probes); a release AppImage is the product
#
# The AppDir is the tarball's tree under usr/, plus everything the app loads
# that is not part of the base system, so it runs where GTK4, libadwaita and
# WebKitGTK 6 are not installed:
#
# - Shared libraries: every library `ldd` resolves for the app, WebKit's
#   helpers, and the bundled modules, minus scripts/linux/appimage/excludelist
#   (glibc, the GL/EGL/DRM stack, X11/xcb, Wayland, fontconfig/freetype and
#   libstdc++/libgcc_s - the host's own, matched to its drivers and kernel).
#   Each bundled ELF gets a RUNPATH relative to $ORIGIN. AppRun still sets
#   LD_LIBRARY_PATH, because WebKit's bubblewrap sandbox shows the web
#   process only the directories named there; the app gives a shell back the
#   value it had (src/apprt/gtk/appimage_env.zig).
# - WebKitGTK's helper processes and injected bundle, in usr/lib/webkitgtk-6.0.
#   libwebkitgtk-6.0 spawns them from a directory compiled into it
#   ($ORIG_WEBKIT below) and a distro build reads no variable to move it, so
#   the bundled copy has that string rewritten, same length, to WEBKIT_LINK -
#   a symlink AppRun points at the AppDir. Measured this turn (T3658): an
#   absolute path survives WebKit's bubblewrap sandbox, a cwd-relative one
#   ('././/lib/...', what other AppImages use) fails with `bwrap: execvp`.
# - GIO's TLS module (glib-networking: https in a website pane), the
#   gdk-pixbuf SVG loader (icons), a GStreamer plugin subset (media in a
#   page; GST_PLUGINS below) and its plugin scanner, and the GTK 4 GSettings
#   schemas compiled into usr/share/glib-2.0/schemas.
#
# The image is the pinned AppImage type2 runtime (setup-distro.sh fetches it
# and checks its sha256) followed by a zstd squashfs of the AppDir, which is
# what appimagetool writes, minus update info and signing.
#
# Last line: 'APPIMAGE OK <path>' or 'APPIMAGE FAILED <why>'; exit 0 only on OK.
# Exit 3: a Debug tarball without APPIMAGE_DEV=1.
set -u

fail() { echo "APPIMAGE FAILED $*"; exit 1; }

arch=$(uname -m)
L=/usr/lib/$arch-linux-gnu

# The runtime and its pin live in setup-distro.sh, which fetches it.
runtime=${APPIMAGE_RUNTIME:-$HOME/.local/ghoztty-tools/appimage-runtime-$arch}
runtime_sha=$(sed -n "s/^appimage_runtime_sha256_$arch=//p" scripts/linux/setup-distro.sh | head -1)
[ -f "$runtime" ] || fail "no AppImage runtime at $runtime (scripts/linux/setup-distro.sh fetches it)"
[ -n "$runtime_sha" ] && [ "$(sha256sum "$runtime" | cut -d' ' -f1)" = "$runtime_sha" ] ||
    fail "$runtime does not match the sha256 pinned in setup-distro.sh (${runtime_sha:-none for $arch})"
for t in patchelf mksquashfs python3 glib-compile-schemas readelf realpath; do
    command -v "$t" > /dev/null || fail "$t is not installed (scripts/linux/setup-distro.sh installs it)"
done
qpl=$(command -v gdk-pixbuf-query-loaders || echo "$L/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders")
[ -x "$qpl" ] || fail "no gdk-pixbuf-query-loaders"
ORIG_WEBKIT=$L/webkitgtk-6.0
[ -d "$ORIG_WEBKIT" ] || fail "no $ORIG_WEBKIT (libwebkitgtk-6.0-dev is not installed?)"
# Same length as ORIG_WEBKIT, padded with slashes (a path's repeated '/'
# mean one). AppRun gets the unpadded spelling; both name one inode.
link_base=/tmp/.ghoztty-appimage-webkit
[ ${#link_base} -le ${#ORIG_WEBKIT} ] || fail "the link path is longer than $ORIG_WEBKIT"
pad=$(printf '%*s' $(( ${#ORIG_WEBKIT} - ${#link_base} )) '' | tr ' ' '/')
WEBKIT_LINK="$link_base$pad"

out=${PKG_OUT:-$PWD/zig-out/dist}
mkdir -p "$out" || fail "cannot create $out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tarball=${1:-}
if [ -z "$tarball" ]; then
    o=$(PKG_OUT="$work/tar" bash scripts/linux/package.sh 2>&1) || { echo "$o" | tail -5; fail "package.sh"; }
    tarball=$(echo "$o" | sed -n 's/^PACKAGE OK //p')
fi
[ -f "$tarball" ] || fail "no tarball at '$tarball'"
mkdir -p "$work/unpack" && tar -C "$work/unpack" -xzf "$tarball" || fail "cannot unpack $tarball"
pkg="$work/unpack/ghoztty"
info="$pkg/.package-info"
[ -f "$info" ] || fail "$tarball has no ghoztty/.package-info (not a package.sh tarball?)"
mode=$(sed -n 's/^mode=//p' "$info")
version=$(sed -n 's/^version=//p' "$info")
sha=$(sed -n 's/^commit=//p' "$info")
count=$(sed -n 's/^count=//p' "$info")
if [ "$mode" != release ] && [ "${APPIMAGE_DEV:-}" != 1 ]; then
    echo "APPIMAGE FAILED $tarball is a $mode package; an AppImage is built from a release one (APPIMAGE_DEV=1 for a test build)"
    exit 3
fi

app="$work/AppDir"
usr="$app/usr"
mkdir -p "$usr" && cp -a "$pkg/bin" "$pkg/lib" "$pkg/share" "$usr/" || fail "cannot lay out $usr"

# --- the desktop entry and icon at the AppDir root ---------------------------
entries=$(ls "$usr"/share/applications/*.desktop 2>/dev/null)
[ "$(echo "$entries" | grep -c .)" = 1 ] || fail "expected one desktop entry in share/applications, found: $entries"
app_id=$(basename "$entries" .desktop)
icon=$(sed -n 's/^Icon=//p' "$entries" | head -1)
[ -n "$icon" ] || fail "$entries has no Icon="
png=$(ls -S "$usr"/share/icons/hicolor/*/apps/"$icon".png 2>/dev/null | head -1)
[ -f "$png" ] || fail "no hicolor PNG for Icon=$icon"
cp "$png" "$app/$icon.png" && ln -s "$icon.png" "$app/.DirIcon"
# The tarball's Exec lines name its staging prefix. In an AppImage the entry
# runs the image itself; integrators (appimaged, AppImageLauncher) rewrite
# Exec to its path. There is no D-Bus service file to activate, so the entry
# is not DBusActivatable, and TryExec would name a file that is not there.
sed -e 's|^Exec=[^ ]*/bin/ghoztty|Exec=ghoztty|' -e '/^TryExec=/d' -e '/^DBusActivatable=/d' \
    "$entries" > "$app/$app_id.desktop"
grep -q '^Exec=ghoztty ' "$app/$app_id.desktop" || fail "could not rewrite Exec in $app/$app_id.desktop"

sed "s|@WEBKIT_LINK@|$link_base|g" scripts/linux/appimage/AppRun > "$app/AppRun" && chmod 755 "$app/AppRun" ||
    fail "cannot write AppRun"

# --- modules: WebKit's helpers, GIO TLS, the SVG pixbuf loader, GStreamer ----
wk="$usr/lib/webkitgtk-6.0"
mkdir -p "$wk/injected-bundle"
for h in WebKitWebProcess WebKitNetworkProcess WebKitGPUProcess; do
    [ -f "$ORIG_WEBKIT/$h" ] && cp "$ORIG_WEBKIT/$h" "$wk/"
done
[ -x "$wk/WebKitWebProcess" ] && [ -x "$wk/WebKitNetworkProcess" ] || fail "no WebKit helpers in $ORIG_WEBKIT"
cp "$ORIG_WEBKIT"/injected-bundle/*.so "$wk/injected-bundle/" || fail "no WebKit injected bundle"

mkdir -p "$usr/lib/gio/modules"
cp "$L/gio/modules/libgiognutls.so" "$usr/lib/gio/modules/" || fail "no glib-networking TLS module ($L/gio/modules/libgiognutls.so)"

pb="$usr/lib/gdk-pixbuf-2.0/2.10.0"
mkdir -p "$pb/loaders"
cp "$L/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so" "$pb/loaders/" || fail "no gdk-pixbuf SVG loader"

GST_PLUGINS="coreelements app playback typefindfunctions audioconvert audioresample volume autodetect
    videoconvertscale videofilter opengl isomp4 matroska vpx opus dav1d audioparsers
    pulseaudio pipewire alsa"
gst="$usr/lib/gstreamer-1.0"
mkdir -p "$gst" "$usr/lib/gstreamer1.0/gstreamer-1.0"
for p in $GST_PLUGINS; do
    [ -f "$L/gstreamer-1.0/libgst$p.so" ] && cp "$L/gstreamer-1.0/libgst$p.so" "$gst/"
done
[ -f "$gst/libgstcoreelements.so" ] || fail "no GStreamer core elements"
cp "$L/gstreamer1.0/gstreamer-1.0/gst-plugin-scanner" "$usr/lib/gstreamer1.0/gstreamer-1.0/" || fail "no gst-plugin-scanner"

# --- shared libraries ----------------------------------------------------------
exclude=scripts/linux/appimage/excludelist
[ -f "$exclude" ] || fail "no $exclude"
excluded() { grep -qxF "$1" <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$exclude"); }

elfs() {
    find "$usr" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print0 |
        while IFS= read -r -d '' f; do
            [ "$(head -c4 "$f" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ] && printf '%s\n' "$f"
        done
}
# Iterate to a fixed point: a library copied in may need one not yet seen.
for pass in 1 2 3 4 5 6; do
    added=0
    while IFS= read -r f; do
        while IFS= read -r line; do
            name=$(echo "$line" | awk '{print $1}')
            path=$(echo "$line" | awk '$2 == "=>" {print $3}')
            case "$line" in *"not found"*) fail "$f needs $name, which ldd cannot find" ;; esac
            [ -n "$path" ] || continue
            excluded "$name" && continue
            case "$path" in "$app"/*) continue ;; esac
            [ -e "$usr/lib/$name" ] && continue
            cp -L "$path" "$usr/lib/$name" || fail "cannot copy $path"
            added=$((added + 1))
        done < <(LD_LIBRARY_PATH="$usr/lib" ldd "$f" 2>/dev/null)
    done < <(elfs)
    [ $added = 0 ] && break
done
[ $added = 0 ] || fail "library closure did not settle in 6 passes"
[ -f "$usr/lib/libwebkitgtk-6.0.so.4" ] && [ -f "$usr/lib/libgtk-4.so.1" ] && [ -f "$usr/lib/libadwaita-1.so.0" ] ||
    fail "the closure is missing libwebkitgtk-6.0, libgtk-4 or libadwaita-1"

# RUNPATHs relative to each file's own directory: usr/lib from wherever the
# file sits ($ORIGIN for usr/lib itself, $ORIGIN/.. for the WebKit helpers,
# $ORIGIN/../../.. for a pixbuf loader).
while IFS= read -r f; do
    readelf -d "$f" 2>/dev/null | grep -q '(NEEDED)' || continue
    up=$(realpath -m --relative-to="$(dirname "$f")" "$usr/lib")
    case "$f" in
        "$usr/bin/ghoztty") rp='$ORIGIN/../lib/ghoztty:$ORIGIN/../lib' ;;
        *) [ "$up" = . ] && rp='$ORIGIN' || rp="\$ORIGIN/$up" ;;
    esac
    patchelf --set-rpath "$rp" "$f" 2>/dev/null || fail "patchelf on $f"
done < <(elfs)

# The one string that moves WebKit's helpers.
python3 - "$usr/lib/libwebkitgtk-6.0.so.4" "$ORIG_WEBKIT" "$WEBKIT_LINK" <<'PY' || fail "could not relocate WebKit's helper path"
import sys
path, old, new = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
assert len(old) == len(new), (old, new)
data = open(path, 'rb').read()
n = data.count(old)
if n == 0:
    sys.exit("no %s in %s" % (old.decode(), path))
open(path, 'wb').write(data.replace(old, new))
print("APPIMAGE relocated %d reference(s) to %s" % (n, old.decode()))
PY

# --- data: GSettings schemas, the pixbuf loader cache template ----------------
schemas="$usr/share/glib-2.0/schemas"
mkdir -p "$schemas"
cp /usr/share/glib-2.0/schemas/org.gtk.gtk4.*.gschema.xml "$schemas/" 2>/dev/null
glib-compile-schemas "$schemas" || fail "glib-compile-schemas"
LD_LIBRARY_PATH="$usr/lib" "$qpl" "$pb"/loaders/*.so 2>/dev/null | sed "s|$app|@APPDIR@|g" > "$pb/loaders.cache.in"
grep -q '@APPDIR@/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so' "$pb/loaders.cache.in" ||
    fail "the pixbuf loader cache does not name the bundled SVG loader"

printf '%s\n' "version=$version" "commit=$sha" "count=$count" "mode=$mode" "arch=$arch" \
    "webkit_link=$link_base" > "$app/.package-info"

# --- the image ------------------------------------------------------------------
img="$out/Ghoztty-$version+$count.g$sha-$mode-$arch.AppImage"
mksquashfs "$app" "$work/fs.squashfs" -root-owned -noappend -comp zstd -quiet > "$work/mksquashfs.log" 2>&1 ||
    { tail -5 "$work/mksquashfs.log"; fail "mksquashfs"; }
cat "$runtime" "$work/fs.squashfs" > "$img" && chmod 755 "$img" || fail "cannot write $img"
echo "APPIMAGE $(du -h "$img" | cut -f1) $(find "$usr/lib" -maxdepth 1 -name '*.so*' | wc -l) bundled libraries"
echo "APPIMAGE OK $img"
