#!/usr/bin/env bash
# install-msitools.sh -- build and install msitools (wixl, msiinfo, msibuild)
# from source on an ubuntu-latest GitHub runner.
#
# ONE definition, TWO callers (T578):
#   * .github/workflows/release-windows.yml -- the release build
#   * .github/workflows/fork-ci.yml         -- the per-commit Windows CI job
# The CI job exists so a broken release path is red on the commit instead of
# at the tag; that only holds if CI installs the packaging toolchain the SAME
# way the release does, which is why this lives in a script rather than being
# pasted into both workflows.
#
# msitools is BUILT, not apt-installed, and that is load-bearing (T577).
# ubuntu-latest ships msitools 0.103, whose wixl does not know the
# <Environment> element at all -- it aborts with "unhandled child Component
# node Environment" (wix.vala:232) on the component that puts ghoztty on the
# user PATH (T70). The other two paths that build this MSI are both on 0.106:
# `brew install msitools` on the Mac seat and the msitools-local Debian image
# the on-box publish script runs. Pinning the same version here is what makes
# "CI and a hand publish cannot drift apart" true of the TOOL as well as the
# script.
#
# 0.106 is also the version build-msi.sh's post-compile patches are written
# against -- it parses <Environment> but ignores Permanent="no", which is why
# the Environment table gets patched from =PATH to =-PATH afterwards. That
# patch has a guard that fails loudly if the behavior changes, so a future
# bump announces itself rather than silently shipping an MSI that leaves a
# PATH entry behind on uninstall.
#
# Needs sudo (apt + install to /usr/local); it is a CI helper, not something
# to run on a dev box.
set -euo pipefail

MSITOOLS_TAG="${MSITOOLS_TAG:-v0.106}"

# Everything we install comes from ubuntu's own archives. The runner image
# also ships third-party apt sources -- Google Chrome, Microsoft, and whatever
# the next image adds -- that we never fetch a byte from, and `apt-get update`
# exits 100 when ANY configured index fails to download. Under `set -e` that
# is fatal, so an unrelated vendor's broken mirror kills this script before it
# has fetched a single package of ours: on 2026-09-09 dl.google.com served a
# chrome-stable Packages.gz whose hash did not match its own Release file, and
# fork-ci's windows-cross job died right here on every push afterwards
# (T1481) -- before it compiled anything, so the one signal that says "the
# branch builds" said nothing for three days.
#
# So move them out of the way rather than hoping they stay healthy. Guarded on
# ubuntu.sources actually being there: if a future image moves the distro
# archives somewhere else, disabling everything would leave apt with no
# sources at all, which is a worse failure than the one this prevents.
APT_SOURCES_DIR=/etc/apt/sources.list.d
if [ -f "$APT_SOURCES_DIR/ubuntu.sources" ]; then
  sudo mkdir -p /tmp/apt-sources-disabled
  for src in "$APT_SOURCES_DIR"/*; do
    [ -e "$src" ] || continue
    if [ "$(basename "$src")" != "ubuntu.sources" ]; then
      echo "disabling third-party apt source: $src"
      sudo mv "$src" /tmp/apt-sources-disabled/
    fi
  done
fi

# Ask apt for msitools' OWN declared build dependencies rather than naming
# -dev packages one at a time. Hand-listing them found libgsf/libgcab and
# then still missed gobject-introspection, and each miss costs a round trip;
# the distro already maintains the correct list for its 0.103 of this same
# source package, and 0.106 needs the same libraries. deb-src is not enabled
# on the runner image, hence the sed. Best-effort: the explicit list below is
# a complete set on its own, so a sources-format change degrades to today's
# behavior instead of failing the run.
sudo sed -i 's/^Types: deb$/Types: deb deb-src/' \
  /etc/apt/sources.list.d/ubuntu.sources || true
# Retried, and NOT the gate. A mirror that is briefly out of sync is the
# commonest failure here and a second attempt clears it; a stubborn one must
# not fail the run on its own, because `update` refreshing an index is not the
# thing we need -- installing the packages is, and the install below says so
# loudly and specifically when an index we actually depend on never arrived.
# The old unconditional `sudo apt-get update` turned every flake in every
# configured repo into a red build.
apt_update_retried() {
  for attempt in 1 2 3; do
    if sudo apt-get update; then return 0; fi
    echo "apt-get update failed (attempt $attempt); retrying"
    sleep $((attempt * 5))
  done
  echo "::warning::apt-get update still failing after 3 attempts; continuing --" \
    "the package installs below are what decide"
  return 0
}
apt_update_retried
sudo apt-get build-dep -y msitools || echo "build-dep unavailable, relying on the explicit list"

sudo apt-get install -y --no-install-recommends \
  ninja-build valac bison pkg-config gettext \
  libglib2.0-dev libgsf-1-dev libgcab-dev libxml2-dev \
  libgirepository1.0-dev gobject-introspection

# NOT apt's meson: noble ships 1.3.2 and msitools 0.106's meson.build
# requires >= 1.4, so `meson setup` refuses the project outright. pipx is
# preinstalled on the runner image; the pip line is the fallback if that ever
# stops being true.
pipx install 'meson>=1.4' \
  || python3 -m pip install --user --break-system-packages 'meson>=1.4'
export PATH="$HOME/.local/bin:$PATH"
meson --version

# Full clone, submodules included, and neither is incidental:
#   * meson.build calls find_program on subprojects/bats-core/bin/bats
#     unconditionally (it is a git submodule, not a meson wrap), so a plain
#     clone fails configure outright.
#   * the project version comes from `build-aux/git-version-gen`, i.e.
#     git describe -- and a --depth 1 clone of an ANNOTATED tag leaves no tag
#     object to describe against, which would make wixl report a version the
#     assertion below then rejects.
git clone --recurse-submodules --shallow-submodules \
  --branch "$MSITOOLS_TAG" \
  https://gitlab.gnome.org/GNOME/msitools.git /tmp/msitools
meson setup /tmp/msitools/_build /tmp/msitools --prefix=/usr/local
ninja -C /tmp/msitools/_build
sudo ninja -C /tmp/msitools/_build install
sudo ldconfig

# Assert the version we actually got. Without this a fallback to a distro
# wixl earlier on PATH would only show up as the same inscrutable vala abort
# this script exists to prevent.
for tool in wixl msiinfo msibuild; do
  echo "$tool -> $(command -v "$tool")"
done
got="$( { wixl --version || true; } 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
want="${MSITOOLS_TAG#v}"
echo "wixl reports $got (want $want)"
[ "$got" = "$want" ] || { echo "::error::wixl is $got, expected $want"; exit 1; }
