#!/usr/bin/env bash
# setup-distro.sh - one-time, idempotent dev setup of the WSL distro for the
# Linux (GTK) build (T3330, docs/claude/linux.md "Distro setup").
#
# Run it ONLY through the wrapper, from this box:
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Repo mnt -CommandFile scripts\linux\setup-distro.sh
#
# What it installs, and where:
#   - apt: the GTK4 + libadwaita dev packages the gtk apprt links, the GObject
#     introspection data blueprint-compiler reads, gettext/xml tools the build
#     runs, mesa-utils (glxinfo) and weston (a headless compositor for tests),
#     and webkitgtk-6.0 (the GTK4 WebKit, for viewer panes - T3410).
#   - zig at build.zig.zon's minimum_zig_version, under ~/.local/zig-<ver>.
#   - blueprint-compiler 0.16.0 (src/apprt/gtk/build/blueprint.zig requires
#     0.16; Ubuntu 24.04 ships 0.12), a source checkout under
#     ~/.local/blueprint-compiler-<ver>.
#   - go at relay/go.mod's `go` version, under ~/.local/go-<ver>: the Linux
#     relay acceptance builds the local rendezvous relay (T3670).
#   - the AppImage type2 runtime, a pinned release checked against its sha256,
#     as ~/.local/ghoztty-tools/appimage-runtime-<arch>: package-appimage.sh
#     prepends it to the squashfs (T3658).
#   - ~/.local/ghoztty-tools/bin holds a link to each, and wsl-run.ps1 puts that
#     dir on PATH. Nothing else in ~ is touched: the user runs other work here.
set -euo pipefail

ZIG_VER=0.15.2
BLP_VER=0.16.0
GO_VER=1.26.0   # relay/go.mod says `go 1.26`; the Windows box resolves that to 1.26.0 too
# T3658: github.com/AppImage/type2-runtime release 20251108 (static, FUSE 3
# built in, zstd squashfs). package-appimage.sh reads the pin from this line.
APPIMAGE_RUNTIME_TAG=20251108
appimage_runtime_sha256_x86_64=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
TOOLS="$HOME/.local/ghoztty-tools/bin"

APT_PKGS=(
    libgtk-4-dev libadwaita-1-dev
    libwebkitgtk-6.0-dev
    gettext libxml2-utils
    python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
    mesa-utils weston
    git curl xz-utils
    # T3343: install.sh registers the ghoztty:// handler with xdg-mime, and
    # the packaging test validates the desktop entry.
    desktop-file-utils xdg-utils
    # T3578: package.sh points the binary's RUNPATH at its private lib, and
    # package-deb.sh builds the .deb (dpkg-deb, dpkg-shlibdeps for Depends).
    patchelf dpkg-dev
    # T3620: the harness's seat compositor (hl_start_seat - a headless sway,
    # since Weston headless has no wl_seat), wtype for the one key serial a
    # selection needs, and wl-clipboard (wl-paste) as the outside client.
    sway wtype wl-clipboard
    # T3658: package-appimage.sh packs the AppDir (mksquashfs), and the
    # AppImage test mounts it through FUSE 3.
    squashfs-tools fuse3
)

missing=()
for p in "${APT_PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "SETUP apt installing: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
else
    echo "SETUP apt: all ${#APT_PKGS[@]} packages present"
fi

mkdir -p "$TOOLS"

zdir="$HOME/.local/zig-$ZIG_VER"
if [ ! -x "$zdir/zig" ]; then
    echo "SETUP zig $ZIG_VER -> $zdir"
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/zig.tar.xz" "https://ziglang.org/download/$ZIG_VER/zig-x86_64-linux-$ZIG_VER.tar.xz"
    tar -xJf "$tmp/zig.tar.xz" -C "$tmp"
    mv "$tmp/zig-x86_64-linux-$ZIG_VER" "$zdir"
    rm -rf "$tmp"
fi
ln -sfn "$zdir/zig" "$TOOLS/zig"

gdir="$HOME/.local/go-$GO_VER"
if [ ! -x "$gdir/bin/go" ]; then
    echo "SETUP go $GO_VER -> $gdir"
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/go.tar.gz" "https://go.dev/dl/go$GO_VER.linux-amd64.tar.gz"
    tar -xzf "$tmp/go.tar.gz" -C "$tmp"
    mv "$tmp/go" "$gdir"
    rm -rf "$tmp"
fi
# cmd/go follows its own symlink to find GOROOT, so a link is enough.
ln -sfn "$gdir/bin/go" "$TOOLS/go"

rt="$TOOLS/../appimage-runtime-x86_64"
if [ "$(sha256sum "$rt" 2>/dev/null | cut -d' ' -f1)" != "$appimage_runtime_sha256_x86_64" ]; then
    echo "SETUP AppImage runtime $APPIMAGE_RUNTIME_TAG -> $rt"
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/runtime" "https://github.com/AppImage/type2-runtime/releases/download/$APPIMAGE_RUNTIME_TAG/runtime-x86_64"
    got=$(sha256sum "$tmp/runtime" | cut -d' ' -f1)
    if [ "$got" != "$appimage_runtime_sha256_x86_64" ]; then
        echo "SETUP FAILED the AppImage runtime's sha256 is $got, not the pinned $appimage_runtime_sha256_x86_64"
        rm -rf "$tmp"
        exit 1
    fi
    mv "$tmp/runtime" "$rt"
    rm -rf "$tmp"
fi

bdir="$HOME/.local/blueprint-compiler-$BLP_VER"
if [ ! -f "$bdir/blueprint-compiler.py" ]; then
    echo "SETUP blueprint-compiler $BLP_VER -> $bdir"
    # -Repo mnt exports GIT_DIR/GIT_WORK_TREE at our worktree; a clone under
    # them refuses ("working tree ... already exists").
    env -u GIT_DIR -u GIT_WORK_TREE git clone --quiet --depth 1 --branch "v$BLP_VER" https://github.com/GNOME/blueprint-compiler.git "$bdir"
    # (GNOME's own gitlab answers an automated clone with HTTP 406, 2026-11-21;
    # github.com/GNOME is GNOME's official read-only mirror of the same tags.)
fi
# A source checkout answers --version with "uninstalled" (meson fills the real
# number in at install time), which blueprint.zig's SemanticVersion check
# rejects; the checkout IS the v$BLP_VER tag, so the wrapper says so.
cat > "$TOOLS/blueprint-compiler" <<EOF
#!/bin/sh
if [ "\$1" = --version ]; then echo $BLP_VER; exit 0; fi
exec python3 "$bdir/blueprint-compiler.py" "\$@"
EOF
chmod +x "$TOOLS/blueprint-compiler"

echo "SETUP zig: $("$TOOLS/zig" version)"
echo "SETUP blueprint-compiler: $("$TOOLS/blueprint-compiler" --version)"
echo "SETUP go: $(GOTOOLCHAIN=local "$TOOLS/go" version)"
echo "SETUP gtk4: $(pkg-config --modversion gtk4)  libadwaita: $(pkg-config --modversion libadwaita-1)  webkitgtk-6.0: $(pkg-config --modversion webkitgtk-6.0)"
echo "SETUP AppImage runtime: $APPIMAGE_RUNTIME_TAG ($(sha256sum "$rt" | cut -c1-12))"
echo "SETUP OK"
