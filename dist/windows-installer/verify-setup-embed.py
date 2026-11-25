#!/usr/bin/env python3
"""verify-setup-embed.py -- prove Ghoztty-Setup.exe carries THE published MSI (T2198).

Usage: python3 verify-setup-embed.py <setup.exe> <published.msi>

Ghoztty-Setup-<version>-x64.exe embeds the MSI it installs (@embedFile in
src/build/GhosttySetup.zig) and is published beside it. The two are one
install, so they must be one package: a setup that embedded an earlier build,
or the MSI from before it was signed, would install bytes nobody can download
and compare. This asserts the published MSI's bytes appear in the exe exactly
once, contiguous and unaltered. Run by build-release-artifacts.sh on every
release and every fork-ci run, and against a fixture by section H of
test/win32/release-artifacts.ps1, which also proves it fails.

Exit 0 = embedded exactly once; 1 = not embedded (or more than once);
2 = usage or an unreadable/empty input.
"""
import hashlib
import sys


def main(argv):
    if len(argv) != 3:
        print("usage: verify-setup-embed.py <setup.exe> <published.msi>", file=sys.stderr)
        return 2
    exe_path, msi_path = argv[1], argv[2]
    try:
        exe = open(exe_path, "rb").read()
        msi = open(msi_path, "rb").read()
    except OSError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if not msi:
        print(f"error: {msi_path} is empty", file=sys.stderr)
        return 2
    digest = hashlib.sha256(msi).hexdigest()
    found = exe.count(msi)
    if found != 1:
        print(f"error: {exe_path} embeds {msi_path} (sha256 {digest}, {len(msi)} bytes) "
              f"{found} time(s), not once -- the setup would install a package "
              "that is not the published one", file=sys.stderr)
        return 1
    print(f"==> {exe_path} embeds the published MSI byte for byte "
          f"(sha256 {digest}, {len(msi)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
